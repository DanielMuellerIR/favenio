use super::*;
use std::collections::{HashMap, VecDeque};

struct Target {
    item: glib::WeakRef<gtk::ListItem>,
    image: glib::WeakRef<gtk::Image>,
    id: String,
    hit: Value,
}
impl Target {
    fn current(&self) -> Option<gtk::Image> {
        let item = self.item.upgrade()?;
        let object = item.item().and_downcast::<glib::BoxedAnyObject>()?;
        if object.borrow::<Value>()["id"] != self.id {
            return None;
        }
        self.image.upgrade()
    }
}
struct Active {
    target: Target,
    action: String,
    task: Option<render::RenderTask>,
}
#[derive(Default)]
pub(super) struct Thumbnails {
    waiting: VecDeque<Target>,
    active: HashMap<String, Active>,
}
impl Ui {
    pub(super) fn queue_thumbnail(&self, item: &gtk::ListItem, image: &gtk::Image, hit: &Value) {
        let name = hit["name"].as_str().unwrap_or("").to_ascii_lowercase();
        let Some(extension) = name.rsplit('.').next() else {
            return;
        };
        if hit["isDirectory"] == true
            || ![
                "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "pdf", "webp", "heic", "heif",
            ]
            .contains(&extension)
        {
            return;
        }
        let Some(id) = hit["id"].as_str() else { return };
        let mut state = self.thumbnails.borrow_mut();
        state.waiting.retain(|target| target.current().is_some());
        if state.waiting.len() >= 64 {
            return;
        }
        state.waiting.push_back(Target {
            item: item.downgrade(),
            image: image.downgrade(),
            id: id.to_owned(),
            hit: hit.clone(),
        });
    }
    pub(super) fn thumbnail_ready(&self, event: &Value) -> bool {
        let id = event["actionID"].as_str().unwrap_or("");
        let mut state = self.thumbnails.borrow_mut();
        let Some(active) = state.active.get_mut(id) else {
            return false;
        };
        let path = event["path"].as_str().map(PathBuf::from).or_else(|| {
            event["pathBytes"]
                .as_str()
                .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
                .map(|b| PathBuf::from(std::ffi::OsString::from_vec(b)))
        });
        if active.target.current().is_some() {
            if let Some(path) = path {
                active.task = render::RenderTask::start(&path, "utf-8", 1, 256).ok();
            }
        }
        if active.task.is_none() {
            let action = active.action.clone();
            state.active.remove(id);
            drop(state);
            let _ = self
                .model
                .call(json!({"operation":"release","actionID":action}));
        }
        true
    }
    pub(super) fn poll_thumbnails(&self) {
        let mut state = self.thumbnails.borrow_mut();
        let mut finished = Vec::new();
        for (id, active) in &state.active {
            if active.target.current().is_none() {
                finished.push(id.clone());
                continue;
            }
            if let Some(task) = &active.task {
                if let Ok(value) = task.receiver.try_recv() {
                    if let Ok(value) = value {
                        if value["kind"] == "image" {
                            if let (Some(image), Some(path)) =
                                (active.target.current(), value["path"].as_str())
                            {
                                image.set_from_file(Some(path));
                                image.set_pixel_size(112);
                            }
                        }
                    }
                    finished.push(id.clone());
                }
            }
        }
        for id in finished {
            state.active.remove(&id);
            let _ = self
                .model
                .call(json!({"operation":"release","actionID":id}));
        }
        while state.active.len() < 2 {
            let Some(target) = state.waiting.pop_front() else {
                break;
            };
            if target.current().is_none() {
                continue;
            }
            if let Ok(value) = self
                .model
                .call(json!({"operation":"materialize","raw":target.hit["raw"],"ephemeral":true}))
            {
                if let Some(id) = value["actionID"].as_str() {
                    state.active.insert(
                        id.to_owned(),
                        Active {
                            target,
                            action: id.to_owned(),
                            task: None,
                        },
                    );
                }
            }
        }
    }
}
