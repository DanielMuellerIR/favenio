use super::*;
use std::path::Path;

pub(super) struct PreviewJob {
    task: render::RenderTask,
    window: gtk::Window,
    content: gtk::Box,
}
impl Ui {
    pub(super) fn file_action(self: &Rc<Self>, action: &str, hit: &Value, path: &Path) {
        let file = gio::File::for_path(path);
        match action {
            "open" => {
                if let Err(error) = gio::AppInfo::launch_default_for_uri(
                    &file.uri(),
                    None::<&gio::AppLaunchContext>,
                ) {
                    self.status.set_text(&error.to_string());
                }
            }
            "reveal" => {
                if let Ok(bus) = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
                {
                    let status = self.status.clone();
                    bus.call(
                        Some("org.freedesktop.FileManager1"),
                        "/org/freedesktop/FileManager1",
                        "org.freedesktop.FileManager1",
                        "ShowItems",
                        Some(&(vec![file.uri().to_string()], String::new()).to_variant()),
                        None,
                        gio::DBusCallFlags::NONE,
                        5000,
                        None::<&gio::Cancellable>,
                        move |result| {
                            if let Err(e) = result {
                                status.set_text(&format!(
                                    "Dateimanager konnte die Datei nicht anzeigen: {e}"
                                ));
                            }
                        },
                    );
                } else {
                    self.status
                        .set_text("Die Dateimanager-Schnittstelle ist nicht erreichbar.");
                }
            }
            "preview" => self.show_preview(hit, path),
            "open-with" => {
                let dialog = gtk::AppChooserDialog::for_content_type(
                    Some(&self.window),
                    gtk::DialogFlags::MODAL,
                    &file
                        .query_info(
                            "standard::content-type",
                            gio::FileQueryInfoFlags::NONE,
                            None::<&gio::Cancellable>,
                        )
                        .ok()
                        .and_then(|i| i.content_type())
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| "application/octet-stream".into()),
                );
                let status = self.status.clone();
                dialog.connect_response(move |dialog, response| {
                    if response == gtk::ResponseType::Ok {
                        if let Some(app) = dialog.app_info() {
                            if let Err(e) =
                                app.launch(&[file.clone()], None::<&gio::AppLaunchContext>)
                            {
                                status.set_text(&e.to_string());
                            }
                        }
                    }
                    dialog.close();
                });
                dialog.present();
            }
            _ => {}
        }
    }
    pub(super) fn trash(self: &Rc<Self>) {
        let selected = self.selected();
        if selected.is_empty() {
            return;
        }
        if selected.iter().any(|h| {
            h["raw"]
                .as_str()
                .and_then(|s| serde_json::from_str::<Value>(s).ok())
                .is_some_and(|v| {
                    v.get("hit").unwrap_or(&v)["archiveMembers"]
                        .as_array()
                        .is_some_and(|a| !a.is_empty())
                })
        }) {
            self.status.set_text(
                "Archivmitglieder können nicht einzeln in den Papierkorb verschoben werden.",
            );
            return;
        }
        let dialog = gtk::MessageDialog::builder()
            .transient_for(&self.window)
            .modal(true)
            .message_type(gtk::MessageType::Question)
            .buttons(gtk::ButtonsType::OkCancel)
            .text(format!(
                "{} ausgewählte Dateien oder Ordner in den Papierkorb verschieben?",
                selected.len()
            ))
            .build();
        let weak = Rc::downgrade(self);
        dialog.connect_response(move |dialog, response| {
            if response == gtk::ResponseType::Ok {
                if let Some(ui) = weak.upgrade() {
                    for hit in &selected {
                        let Some(path) = hit["pathBytes"]
                            .as_str()
                            .and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
                            .map(|b| PathBuf::from(std::ffi::OsString::from_vec(b)))
                        else {
                            continue;
                        };
                        let file = gio::File::for_path(path);
                        let weak = Rc::downgrade(&ui);
                        let index = hit["index"].clone();
                        let run = ui.run.borrow().clone();
                        file.trash_async(
                            glib::Priority::DEFAULT,
                            None::<&gio::Cancellable>,
                            move |result| {
                                if let Some(ui) = weak.upgrade() {
                                    match result {
                                        Ok(()) if *ui.run.borrow() == run => {
                                            let _ = ui.model.call(
                                                json!({"operation":"remove","indices":[index]}),
                                            );
                                            ui.refresh_projection();
                                        }
                                        Ok(()) => {}
                                        Err(e) => ui.status.set_text(&format!("Papierkorb: {e}")),
                                    }
                                }
                            },
                        );
                    }
                }
            }
            dialog.close();
        });
        dialog.present();
    }
    pub(super) fn show_preview(self: &Rc<Self>, hit: &Value, path: &Path) {
        if let Some(window) = self.preview_window.borrow_mut().take() {
            window.close();
        }
        if let Some(id) = self.preview_lease.borrow_mut().take() {
            let _ = self
                .model
                .call(json!({"operation":"release","actionID":id}));
        }
        let window = gtk::Window::builder()
            .title(hit["name"].as_str().unwrap_or("Vorschau"))
            .transient_for(&self.window)
            .default_width(800)
            .default_height(650)
            .build();
        let body = column();
        for set in [
            gtk::Widget::set_margin_top,
            gtk::Widget::set_margin_bottom,
            gtk::Widget::set_margin_start,
            gtk::Widget::set_margin_end,
        ] {
            set(body.upcast_ref(), 12);
        }
        let header = label(hit["path"].as_str().unwrap_or(""));
        header.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        body.append(&header);
        let content = column();
        content.set_vexpand(true);
        content.append(&label("Vorschau wird geladen …"));
        body.append(&content);
        let open = gtk::Button::with_label("In Standardanwendung öffnen");
        let uri = gio::File::for_path(path).uri();
        open.connect_clicked(move |_| {
            let _ = gio::AppInfo::launch_default_for_uri(&uri, None::<&gio::AppLaunchContext>);
        });
        body.append(&open);
        if hit["name"]
            .as_str()
            .is_some_and(|s| s.to_ascii_lowercase().ends_with(".pdf"))
        {
            let page = hit["documentPosition"]["page"].as_u64().unwrap_or(1);
            let navigation = row();
            let previous = gtk::Button::with_label("Vorherige Seite");
            previous.set_sensitive(page > 1);
            let next = gtk::Button::with_label("Nächste Seite");
            next.set_sensitive(page < 512);
            navigation.append(&previous);
            navigation.append(&label(&format!("Seite {page}")));
            navigation.append(&next);
            body.append(&navigation);
            for (button, target) in [(previous, page.saturating_sub(1)), (next, page + 1)] {
                let weak = Rc::downgrade(self);
                button.connect_clicked(move |_| {
                    if let Some(ui) = weak.upgrade() {
                        ui.preview_page.set(target);
                        ui.act("preview");
                    }
                });
            }
        }

        let key = gtk::EventControllerKey::new();
        key.set_propagation_phase(gtk::PropagationPhase::Capture);
        let w = window.clone();
        let weak = Rc::downgrade(self);
        key.connect_key_pressed(move |_, key, _, _| {
            if key == gdk::Key::Down
                || key == gdk::Key::Up
                || key == gdk::Key::Right
                || key == gdk::Key::Left
            {
                if let Some(ui) = weak.upgrade() {
                    let current = (0..ui.store.n_items())
                        .find(|i| ui.selection.is_selected(*i))
                        .unwrap_or(0);
                    let direction = if key == gdk::Key::Down || key == gdk::Key::Right {
                        1
                    } else {
                        -1
                    };
                    let mut next = current as i32 + direction;
                    while next >= 0 && (next as u32) < ui.store.n_items() {
                        if let Some(object) = ui
                            .store
                            .item(next as u32)
                            .and_downcast::<glib::BoxedAnyObject>()
                        {
                            if object.borrow::<Value>()["kind"] != "group" {
                                ui.selection.select_item(next as u32, true);
                                ui.act("preview");
                                break;
                            }
                        }
                        next += direction;
                    }
                }
                return glib::Propagation::Stop;
            }

            if key == gdk::Key::Escape || key == gdk::Key::space {
                w.close();
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        window.add_controller(key);
        window.set_child(Some(&body));
        window.present();
        *self.preview_window.borrow_mut() = Some(window.clone());
        let encoding = &self.encodings[self.encoding.selected() as usize];
        let page = hit["documentPosition"]["page"].as_u64().unwrap_or(1);
        self.preview_jobs
            .borrow_mut()
            .retain(|job| job.window.is_visible());
        match render::RenderTask::start(path, encoding, page, 1800) {
            Ok(task) => self.preview_jobs.borrow_mut().push(PreviewJob {
                task,
                window,
                content,
            }),
            Err(error) => self.status.set_text(&error),
        }
    }
    pub(super) fn poll_previews(&self) {
        self.preview_jobs.borrow_mut().retain(|job| {
            if !job.window.is_visible() {
                return false;
            }
            if let Ok(result) = job.task.receiver.try_recv() {
                while let Some(child) = job.content.first_child() {
                    job.content.remove(&child);
                }
                match result {
                    Ok(value) if value["kind"] == "image" => {
                        if let Some(path) = value["path"].as_str() {
                            let picture = gtk::Picture::for_filename(path);
                            picture.set_can_shrink(true);
                            picture.set_vexpand(true);
                            job.content.append(&picture);
                        }
                    }
                    Ok(value) => {
                        let view = gtk::TextView::builder()
                            .editable(false)
                            .monospace(true)
                            .wrap_mode(gtk::WrapMode::WordChar)
                            .build();
                        view.buffer().set_text(
                            value["text"]
                                .as_str()
                                .unwrap_or("Keine Vorschau verfügbar."),
                        );
                        job.content.append(
                            &gtk::ScrolledWindow::builder()
                                .vexpand(true)
                                .child(&view)
                                .build(),
                        );
                        if value["truncated"] == true {
                            job.content.append(&label("Vorschau auf 256 KiB begrenzt."));
                        }
                    }
                    Err(error) => job.content.append(&label(&error)),
                }
            }
            true
        });
        if self
            .preview_window
            .borrow()
            .as_ref()
            .is_some_and(|w| !w.is_visible())
        {
            self.preview_window.borrow_mut().take();
            if let Some(id) = self.preview_lease.borrow_mut().take() {
                let _ = self
                    .model
                    .call(json!({"operation":"release","actionID":id}));
            }
        }
    }
}
