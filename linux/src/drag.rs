use super::*;
use std::rc::Weak;
mod implementation {
    use super::*;
    use gtk::gdk::subclass::prelude::*;
    #[derive(Default)]
    pub struct Provider {
        pub(super) ui: RefCell<Option<Weak<Ui>>>,
        pub(super) hits: RefCell<Vec<Value>>,
    }
    #[glib::object_subclass]
    impl ObjectSubclass for Provider {
        const NAME: &'static str = "FavenioFileDrag";
        type Type = super::Provider;
        type ParentType = gdk::ContentProvider;
    }
    impl ObjectImpl for Provider {}
    impl ContentProviderImpl for Provider {
        fn formats(&self) -> gdk::ContentFormats {
            gdk::ContentFormats::new(&["text/uri-list"])
        }
        fn write_mime_type_future(
            &self,
            mime: &str,
            stream: &gio::OutputStream,
            priority: glib::Priority,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), glib::Error>> + 'static>>
        {
            let weak = self.ui.borrow().clone();
            let hits = self.hits.borrow().clone();
            let stream = stream.clone();
            let supported = mime == "text/uri-list";
            Box::pin(async move {
                let failure = |message: &str| glib::Error::new(gio::IOErrorEnum::Failed, message);
                if !supported {
                    return Err(failure("Unbekanntes Dateitransferformat."));
                }
                let ui = weak
                    .and_then(|w| w.upgrade())
                    .ok_or_else(|| failure("Favenio-Fenster geschlossen."))?;
                let started = std::time::Instant::now();
                let mut uris = String::new();
                for hit in hits {
                    if hit["openable"] != true {
                        return Err(failure(
                            "Ordner in Archiven können nicht als Dateien gezogen werden.",
                        ));
                    }
                    let response = ui
                        .model
                        .call(json!({"operation":"materialize","raw":hit["raw"],"ephemeral":false}))
                        .map_err(|e| failure(&e))?;
                    let id = response["actionID"]
                        .as_str()
                        .ok_or_else(|| failure("Materialisierungsauftrag fehlt."))?
                        .to_owned();
                    ui.drag_waiting.borrow_mut().insert(id.clone());
                    let lease = Lease {
                        ui: Rc::downgrade(&ui),
                        id: id.clone(),
                    };
                    let event = loop {
                        if !ui.window.is_visible() || started.elapsed() > Duration::from_secs(30) {
                            return Err(failure(
                                "Dateitransfer abgebrochen oder Zeitgrenze erreicht.",
                            ));
                        }
                        let result = ui.drag_results.borrow_mut().remove(&id);
                        if let Some(value) = result {
                            break value;
                        }
                        glib::timeout_future(Duration::from_millis(20)).await;
                    };
                    let path = event["path"]
                        .as_str()
                        .map(PathBuf::from)
                        .or_else(|| {
                            event["pathBytes"]
                                .as_str()
                                .and_then(|s| {
                                    base64::engine::general_purpose::STANDARD.decode(s).ok()
                                })
                                .map(|b| PathBuf::from(std::ffi::OsString::from_vec(b)))
                        })
                        .ok_or_else(|| {
                            failure(
                                event["error"]
                                    .as_str()
                                    .unwrap_or("Datei konnte nicht bereitgestellt werden."),
                            )
                        })?;
                    uris.push_str(&gio::File::for_path(path).uri());
                    uris.push_str("\r\n");
                    drop(lease);
                }
                stream
                    .write_all_future(uris.into_bytes(), priority)
                    .await
                    .map_err(|(_, e)| e)?;
                Ok(())
            })
        }
    }
}
glib::wrapper! {pub struct Provider(ObjectSubclass<implementation::Provider>) @extends gdk::ContentProvider;}
struct Lease {
    ui: Weak<Ui>,
    id: String,
}
impl Drop for Lease {
    fn drop(&mut self) {
        if let Some(ui) = self.ui.upgrade() {
            ui.drag_waiting.borrow_mut().remove(&self.id);
            ui.drag_results.borrow_mut().remove(&self.id);
            let _ = ui
                .model
                .call(json!({"operation":"release","actionID":self.id}));
        }
    }
}
impl Provider {
    pub(super) fn new(ui: &Rc<Ui>) -> Option<Self> {
        use gtk::glib::subclass::types::ObjectSubclassIsExt;
        let hits = ui.selected();
        if hits.is_empty() {
            return None;
        }
        let object: Self = glib::Object::new();
        *object.imp().ui.borrow_mut() = Some(Rc::downgrade(ui));
        *object.imp().hits.borrow_mut() = hits;
        Some(object)
    }
}
