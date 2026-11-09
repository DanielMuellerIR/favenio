use super::*;
use std::{
    io::Read,
    path::Path,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::Instant,
};

pub(super) struct RenderTask {
    pub receiver: mpsc::Receiver<Result<Value, String>>,
    workspace: PathBuf,
    cancelled: Arc<AtomicBool>,
}
impl Drop for RenderTask {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Relaxed);
        let _ = std::fs::remove_dir_all(&self.workspace);
    }
}
impl RenderTask {
    pub fn start(path: &Path, encoding: &str, page: u64, edge: u32) -> Result<Self, String> {
        let workspace =
            std::env::temp_dir().join(format!("favenio-render-{}", glib::uuid_string_random()));
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&workspace)
            .map_err(|e| e.to_string())?;
        let path = path.to_owned();
        let encoding = encoding.to_owned();
        let destination = workspace.clone();
        let helper = std::env::current_exe()
            .map_err(|e| e.to_string())?
            .parent()
            .unwrap()
            .join("helpers/favenio-preview");
        let (sender, receiver) = mpsc::channel();
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel = cancelled.clone();
        std::thread::spawn(move || {
            let result = (|| -> Result<Value, String> {
                let mut child = std::process::Command::new("/usr/bin/python3")
                    .arg("-B")
                    .arg(helper)
                    .arg(path)
                    .arg(&destination)
                    .arg(encoding)
                    .arg(page.to_string())
                    .arg(edge.to_string())
                    .stdin(Stdio::null())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn()
                    .map_err(|e| e.to_string())?;
                let stdout = child.stdout.take().ok_or("Vorschaustrom fehlt.")?;
                let reader = std::thread::spawn(move || {
                    let mut bytes = Vec::new();
                    stdout
                        .take(2_097_153)
                        .read_to_end(&mut bytes)
                        .map(|_| bytes)
                });
                let started = Instant::now();
                let status = loop {
                    if cancel.load(Ordering::Relaxed) || started.elapsed() > Duration::from_secs(15)
                    {
                        let _ = child.kill();
                        let _ = child.wait();
                        let _ = reader.join();
                        return Err("Vorschau abgebrochen oder Zeitgrenze erreicht.".into());
                    }
                    match child.try_wait() {
                        Ok(Some(status)) => break status,
                        Ok(None) => std::thread::sleep(Duration::from_millis(20)),
                        Err(error) => {
                            let _ = child.kill();
                            let _ = child.wait();
                            let _ = reader.join();
                            return Err(error.to_string());
                        }
                    }
                };
                let bytes = reader
                    .join()
                    .map_err(|_| "Vorschauleser abgebrochen.")?
                    .map_err(|e| e.to_string())?;
                if !status.success() || bytes.len() > 2_097_152 {
                    return Err("Vorschau lieferte keine begrenzte Antwort.".into());
                }
                serde_json::from_slice(&bytes).map_err(|e| e.to_string())
            })();
            if cancel.load(Ordering::Relaxed) {
                let _ = std::fs::remove_dir_all(&destination);
            }
            let _ = sender.send(result);
        });
        Ok(Self {
            receiver,
            workspace,
            cancelled,
        })
    }
}
