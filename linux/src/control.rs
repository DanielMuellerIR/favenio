use super::*;
use std::{
    io::{Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
};

pub(super) struct Request {
    value: Value,
    raw: String,
    reply: mpsc::SyncSender<Value>,
}
pub(super) struct Server {
    receiver: mpsc::Receiver<Request>,
    stop: Arc<AtomicBool>,
    path: PathBuf,
    pub runtime: String,
    pub window: String,
    replay: RefCell<std::collections::VecDeque<(String, Value, Value)>>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = std::fs::remove_file(&self.path);
    }
}
fn endpoint() -> std::io::Result<PathBuf> {
    let uid = unsafe { libc::getuid() };
    let root = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join(format!("favenio-control-{uid}")));
    use std::os::unix::fs::DirBuilderExt;
    match std::fs::DirBuilder::new().mode(0o700).create(&root) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    };
    let info = std::fs::symlink_metadata(&root)?;
    if !root.is_absolute() || !info.is_dir() || info.uid() != uid || info.mode() & 0o077 != 0 {
        return Err(std::io::ErrorKind::PermissionDenied.into());
    }
    Ok(root.join("org.favenio.Main.search-control.v1.sock"))
}
fn read_until(
    stream: &mut UnixStream,
    bytes: &mut [u8],
    deadline: std::time::Instant,
) -> std::io::Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err(std::io::ErrorKind::TimedOut.into());
        }
        stream.set_read_timeout(Some(remaining))?;
        match stream.read(&mut bytes[offset..]) {
            Ok(0) => return Err(std::io::ErrorKind::UnexpectedEof.into()),
            Ok(count) => offset += count,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
fn peer(stream: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut size,
        ) == 0
            && credentials.uid == libc::getuid()
    }
}
impl Server {
    pub fn start() -> std::io::Result<Self> {
        let path = endpoint()?;
        if path.exists() {
            let info = std::fs::symlink_metadata(&path)?;
            if !info.file_type().is_socket() || info.uid() != unsafe { libc::getuid() } {
                return Err(std::io::ErrorKind::PermissionDenied.into());
            }
            if UnixStream::connect(&path).is_ok() {
                return Err(std::io::ErrorKind::AddrInUse.into());
            }
            std::fs::remove_file(&path)?;
        }
        let listener = UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        let (sender, receiver) = mpsc::sync_channel(8);
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        std::thread::spawn(move || {
            while !stopping.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        if !peer(&stream) {
                            continue;
                        }
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                        let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
                        let deadline = std::time::Instant::now() + Duration::from_secs(2);
                        let mut header = [0u8; 4];
                        if read_until(&mut stream, &mut header, deadline).is_err() {
                            continue;
                        }
                        let count = u32::from_be_bytes(header) as usize;
                        if count == 0 || count > 262144 {
                            continue;
                        }
                        let mut bytes = vec![0; count];
                        if read_until(&mut stream, &mut bytes, deadline).is_err() {
                            continue;
                        }
                        let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
                            continue;
                        };
                        let (reply, response) = mpsc::sync_channel(1);
                        if sender
                            .try_send(Request {
                                value,
                                raw: String::from_utf8_lossy(&bytes).into_owned(),
                                reply,
                            })
                            .is_err()
                        {
                            continue;
                        }
                        if let Ok(value) = response.recv_timeout(Duration::from_secs(9)) {
                            if let Ok(bytes) = serde_json::to_vec(&value) {
                                if bytes.len() <= 1048576 {
                                    let _ = stream.write_all(&(bytes.len() as u32).to_be_bytes());
                                    let _ = stream.write_all(&bytes);
                                }
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(20))
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            receiver,
            stop,
            path,
            runtime: glib::uuid_string_random().to_string(),
            window: glib::uuid_string_random().to_string(),
            replay: RefCell::new(Default::default()),
        })
    }
}
impl Ui {
    pub(super) fn poll_control(self: &Rc<Self>) {
        let binding = self.control.borrow();
        let Some(server) = binding.as_ref() else {
            return;
        };
        while let Ok(request) = server.receiver.try_recv() {
            let response = self.control_request(server, &request.value, &request.raw);
            let _ = request.reply.send(response);
        }
    }
    fn control_request(self: &Rc<Self>, server: &Server, request: &Value, raw: &str) -> Value {
        let mut reply = json!({"protocolVersion":1,"runtimeID":server.runtime,"windowID":server.window,"requestID":request["id"]});
        let result = (|| -> Result<(), String> {
            self.model
                .call(json!({"operation":"controlValidate","requestRaw":raw}))?;
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs_f64();
            let deadline = request["deadline"].as_f64().ok_or("invalidRequest")?;
            if !(now..=now + 10.0).contains(&deadline) {
                return Err("expired".into());
            }
            let op = request["operation"].as_str().ok_or("invalidRequest")?;
            let mutations = [
                "configure",
                "start",
                "replace",
                "cancel",
                "select",
                "openRecording",
                "handoff",
                "cancelHandoff",
            ];
            if (request.get("runtimeID").is_some() && request["runtimeID"] != server.runtime)
                || (request.get("windowID").is_some() && request["windowID"] != server.window)
            {
                return Err("stale".into());
            }
            if mutations.contains(&op) {
                if request["runtimeID"] != server.runtime || request["windowID"] != server.window {
                    return Err("stale".into());
                }
                if gtk::Window::list_toplevels().iter().any(|widget| {
                    widget
                        .downcast_ref::<gtk::Window>()
                        .is_some_and(|window| window.is_visible() && window.is_modal())
                }) {
                    return Err("busy".into());
                }
                if let Some((_, previous, response)) = server
                    .replay
                    .borrow()
                    .iter()
                    .find(|(id, _, _)| Some(id.as_str()) == request["id"].as_str())
                {
                    if previous != request {
                        return Err("invalidRequest".into());
                    }
                    reply = response.clone();
                    return Ok(());
                }
            }
            if [
                "cancel",
                "report",
                "results",
                "select",
                "captureRecording",
                "handoff",
            ]
            .contains(&op)
                && request["runID"].as_str() != self.run.borrow().as_deref()
            {
                return Err("stale".into());
            }
            match op {
                "capabilities" => {
                    reply["capabilities"] = self.model.call(json!({"operation":"capabilities"}))?
                        ["capabilities"]
                        .clone();
                }
                "configuration" => {
                    reply["configuration"]=self.model.call(json!({"operation":"configurationValidate","configuration":self.wire_configuration()}))?["configuration"].clone();
                }
                "configure" => {
                    let value=self.model.call(json!({"operation":"configurationValidate","configuration":request["configuration"]}))?;
                    let mut configuration = value["configuration"].clone();
                    if let Some(root) = configuration.get("root").cloned() {
                        configuration["roots"] = json!([root]);
                    }
                    self.apply_configuration(&configuration);
                    reply["configuration"] = value["configuration"].clone();
                }
                "start" | "replace" => {
                    if op == "start" && !self.ended.get() {
                        return Err("busy".into());
                    }
                    self.start_with_reference(request.get("dateReferenceTime"))?;
                    reply["status"] = self.control_status();
                }
                "cancel" => {
                    self.model.call(json!({"operation":"cancel"}))?;
                    reply["status"] = self.control_status();
                }
                "status" => {
                    reply["status"] = self.control_status();
                }
                "report" => {
                    reply["report"] =
                        self.report.borrow().clone().unwrap_or_else(
                            || json!({"state":"unavailable","coverage":"incomplete"}),
                        );
                    reply["runID"] = json!(self.run.borrow().clone());
                }
                "results" => {
                    let offset = request["offset"].as_u64().ok_or("invalidRequest")? as usize;
                    let limit = request["limit"]
                        .as_u64()
                        .filter(|n| (1..=128).contains(n))
                        .ok_or("invalidRequest")? as usize;
                    let generation = self.result_generation.get();
                    if (offset != 0 && request.get("generation").is_none())
                        || request
                            .get("generation")
                            .is_some_and(|v| v.as_u64() != Some(generation))
                    {
                        return Err("stale".into());
                    }
                    let page=self.model.call(json!({"operation":"page","runID":self.run.borrow().as_deref().unwrap_or(""),"offset":offset,"limit":limit,"sort":(SORT_KEYS[self.sorting.selected()as usize]),"ascending":self.ascending.is_active()}))?;
                    for key in ["hits", "count", "nextOffset", "hasMore"] {
                        reply[key] = page[key].clone();
                    }
                    reply["generation"] = json!(generation);
                    reply["runID"] = json!(self.run.borrow().clone());
                    reply["state"] = json!(self.run_state.borrow().clone());
                }
                "select" | "handoff" => {
                    let identity = self
                        .model
                        .call(json!({"operation":"identity","identity":request["identity"]}))?;
                    let hits = self.all_hits.borrow();
                    let target = hits
                        .iter()
                        .position(|hit| hit["id"] == identity["id"])
                        .ok_or("missingHit")?;
                    drop(hits);
                    if op == "handoff" {
                        reply["handoff"] = self
                            .model
                            .call(json!({"operation":"fastra","index":target}))?["handoff"]
                            .clone();
                    } else {
                        self.collapsed.borrow_mut().clear();
                        self.refresh_projection();
                        for i in 0..self.store.n_items() {
                            if let Some(object) =
                                self.store.item(i).and_downcast::<glib::BoxedAnyObject>()
                            {
                                if object.borrow::<Value>()["index"] == target {
                                    self.selection.select_item(i, true);
                                    break;
                                }
                            }
                        }
                        reply["identity"] = identity["identity"].clone();
                        reply["runID"] = json!(self.run.borrow().clone());
                    }
                }
                "handoffStatus" | "cancelHandoff" => {
                    reply["handoff"]=self.model.call(json!({"operation":if op=="handoffStatus"{"fastraStatus"}else{"cancelFastra"},"jobID":request["jobID"]}))?["handoff"].clone();
                }
                "captureRecording" => {
                    let response=self.model.call(json!({"operation":"captureRecording","indices":self.selected().iter().filter_map(|v|v["index"].as_u64()).collect::<Vec<_>>()}))?;
                    let data = base64::engine::general_purpose::STANDARD
                        .decode(response["data"].as_str().ok_or("invalidRequest")?)
                        .map_err(|e| e.to_string())?;
                    reply["recording"] =
                        serde_json::from_slice(&data).map_err(|e| e.to_string())?;
                }
                "openRecording" => {
                    let value=self.model.call(json!({"operation":"openRecording","data":base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&request["recording"]).map_err(|e|e.to_string())?)}))?;
                    self.install_recording(&value);
                    reply["status"] = self.control_status();
                }
                _ => return Err("unsupported".into()),
            }
            if mutations.contains(&op) {
                let mut replay = server.replay.borrow_mut();
                replay.push_back((
                    request["id"].as_str().unwrap_or("").to_owned(),
                    request.clone(),
                    reply.clone(),
                ));
                while replay.len() > 128 {
                    replay.pop_front();
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            reply["error"] = json!({"code":if ["expired","stale","busy","missingHit","unsupported"].contains(&error.as_str()){&error}else{"invalidRequest"},"message":error});
        }
        reply
    }
    fn wire_configuration(&self) -> Value {
        let mut value = self.configuration();
        value.as_object_mut().unwrap().remove("continuation");
        if value.get("rootBytes").is_some() {
            value["schemaVersion"] = json!(8)
        } else {
            value["schemaVersion"] = json!(7)
        }
        value
    }
    fn control_status(&self) -> Value {
        json!({"state":self.run_state.borrow().clone(),"complete":*self.run_state.borrow()=="completed","runID":self.run.borrow().clone(),"count":self.result_count.get(),"warningCount":self.warning_count.get(),"generation":self.result_generation.get(),"selectionCount":self.selected().len(),"selectionTruncated":self.selected().len()>128,"selection":self.selected().iter().take(128).map(|v|v["identity"].clone()).collect::<Vec<_>>()})
    }
}
