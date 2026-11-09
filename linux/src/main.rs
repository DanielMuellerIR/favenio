mod control;
mod criteria;
mod decoder;
mod drag;
mod evidence;
mod files;
mod handoff;
mod locations;
mod menus;
mod model;
mod render;
mod results;
mod thumbnails;
mod tools;
use base64::Engine;
use gtk::{gdk, gio, glib, prelude::*};
use model::Model;
use serde_json::{json, Value};
use std::os::unix::ffi::OsStringExt;
use std::{cell::RefCell, path::PathBuf, rc::Rc, time::Duration};

const SORT_KEYS: [&str; 9] = [
    "name",
    "size",
    "path",
    "type",
    "modified",
    "created",
    "dims",
    "finderTags",
    "finderComment",
];

struct Ui {
    window: gtk::ApplicationWindow,
    model: Model,
    quick: bool,
    root_confirmed: std::cell::Cell<bool>,
    query: gtk::SearchEntry,
    roots: gtk::TextView,
    roots_button: gtk::Button,
    filters_expander: gtk::Expander,
    mode: gtk::DropDown,
    only: gtk::DropDown,
    checks: Vec<(&'static str, gtk::CheckButton)>,
    encoding: gtk::DropDown,
    encodings: Vec<String>,
    metadata_field: gtk::DropDown,
    metadata_fields: Vec<String>,
    filters: Vec<(&'static str, gtk::Entry)>,
    date_values: std::collections::BTreeMap<String, Rc<RefCell<Option<Value>>>>,
    date_labels: std::collections::BTreeMap<String, gtk::Entry>,
    date_signature: RefCell<String>,
    terms: gtk::TextView,
    excludes: gtk::TextView,
    criteria: RefCell<Option<Value>>,
    criteria_enabled: gtk::CheckButton,
    store: gio::ListStore,
    selection: gtk::MultiSelection,
    status: gtk::Label,
    preview: gtk::TextView,
    preview_enabled: gtk::CheckButton,
    evidence_query: gtk::DropDown,
    evidence_identity: RefCell<Option<String>>,
    evidence_occurrence: std::cell::Cell<u64>,
    evidence_load: RefCell<Option<String>>,
    evidence_at_end: std::cell::Cell<bool>,
    last_evidence_check: RefCell<std::time::Instant>,
    rebuilding: std::cell::Cell<bool>,
    run: RefCell<Option<String>>,
    report: RefCell<Option<Value>>,
    report_text: RefCell<String>,
    actions: RefCell<std::collections::HashMap<String, (String, Value)>>,
    preview_window: RefCell<Option<gtk::Window>>,
    all_hits: RefCell<Vec<Value>>,
    grouping: gtk::DropDown,
    sorting: gtk::DropDown,
    ascending: gtk::CheckButton,
    collapsed: RefCell<std::collections::HashSet<String>>,
    grid: gtk::GridView,
    result_stack: gtk::Stack,
    projection_dirty: std::cell::Cell<bool>,
    last_projection: RefCell<std::time::Instant>,
    ended: std::cell::Cell<bool>,
    run_state: RefCell<String>,
    warning_count: std::cell::Cell<u64>,
    result_generation: std::cell::Cell<u64>,
    result_count: std::cell::Cell<u64>,
    control: RefCell<Option<control::Server>>,
    retained_options: RefCell<Vec<Value>>,
    root_identity: RefCell<Option<(String, Vec<PathBuf>)>>,
    preview_jobs: RefCell<Vec<files::PreviewJob>>,
    preview_lease: RefCell<Option<String>>,
    thumbnails: RefCell<thumbnails::Thumbnails>,
    preview_epoch: std::cell::Cell<u64>,
    preview_page: std::cell::Cell<u64>,
    drag_waiting: RefCell<std::collections::HashSet<String>>,
    drag_results: RefCell<std::collections::HashMap<String, Value>>,
    suppress_quick: std::cell::Cell<bool>,
    quick_epoch: std::cell::Cell<u64>,
    last_configuration: RefCell<Option<Value>>,
    initial_selection: RefCell<std::collections::HashSet<String>>,
}
fn text(view: &gtk::TextView) -> String {
    let b = view.buffer();
    b.text(&b.start_iter(), &b.end_iter(), false).to_string()
}
fn lines(view: &gtk::TextView) -> Vec<String> {
    text(view)
        .lines()
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}
fn label(value: &str) -> gtk::Label {
    gtk::Label::builder().label(value).xalign(0.0).build()
}
fn row() -> gtk::Box {
    gtk::Box::new(gtk::Orientation::Horizontal, 8)
}
fn column() -> gtk::Box {
    gtk::Box::new(gtk::Orientation::Vertical, 8)
}
fn editor(height: i32) -> (gtk::ScrolledWindow, gtk::TextView) {
    let view = gtk::TextView::builder()
        .monospace(true)
        .wrap_mode(gtk::WrapMode::WordChar)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .min_content_height(height)
        .child(&view)
        .hexpand(true)
        .build();
    (scroll, view)
}
fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}
impl Ui {
    fn options(&self) -> Vec<Value> {
        let modes = ["name", "content", "metadata", "document"];
        let mut out = vec![
            json!({"name":"mode","value":modes[self.mode.selected() as usize]}),
            json!({"name":"only","value":(["both","files","dirs"][self.only.selected() as usize])}),
            json!({"name":"encoding","value":self.encodings[self.encoding.selected() as usize]}),
        ];
        for (key, control) in &self.checks {
            out.push(json!({"name":key,"value":if control.is_active(){"1"}else{"0"}}));
        }
        for (key, control) in &self.filters {
            if self.date_values.iter().any(|(field, value)| {
                key.starts_with(&(field.to_owned() + "-")) && value.borrow().is_some()
            }) {
                continue;
            }
            if !control.text().is_empty() {
                out.push(json!({"name":key,"value":control.text().to_string()}));
            }
        }
        for value in lines(&self.terms) {
            out.push(json!({"name":"term","value":value}));
        }
        for value in lines(&self.excludes) {
            out.push(json!({"name":"exclude","value":value}));
        }
        if self.criteria_enabled.is_active() {
            if let Some(tree) = self.criteria.borrow().as_ref() {
                out.push(json!({"name":"criteria","value":tree.to_string()}));
            }
        }
        let dates: std::collections::BTreeMap<_, _> = self
            .date_values
            .iter()
            .filter_map(|(field, value)| value.borrow().clone().map(|value| (field.clone(), value)))
            .collect();
        if !dates.is_empty() {
            out.push(json!({"name":"date-ranges","value":json!({"schemaVersion":1,"ranges":dates}).to_string()}));
        }
        let continuation = self
            .retained_options
            .borrow()
            .iter()
            .any(|v| v["name"] == "__continuation");
        out.extend(
            self.retained_options
                .borrow()
                .iter()
                .filter(|v| {
                    ["finder-metadata", "local-only"].contains(&v["name"].as_str().unwrap_or(""))
                        || (v["name"] == "field" && self.mode.selected() == 2)
                        || (continuation && v["name"] == "date-reference-time")
                })
                .cloned(),
        );
        out
    }
    fn quick_changed(self: &Rc<Self>) {
        if !self.quick || self.suppress_quick.get() {
            return;
        }
        let epoch = self.quick_epoch.get() + 1;
        self.quick_epoch.set(epoch);
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(600), move || {
            let Some(ui) = weak.upgrade() else { return };
            if ui.quick_epoch.get() != epoch {
                return;
            }
            let mut config = ui.configuration();
            config.as_object_mut().unwrap().remove("continuation");
            if ui.last_configuration.borrow().as_ref() == Some(&config) {
                return;
            }
            if ui.query.text().trim().is_empty() {
                let mut validation = config.clone();
                validation["pattern"] = json!("");
                validation["operation"] = json!("arguments");
                if ui.model.call(validation).is_err() {
                    let _ = ui.model.call(json!({"operation":"cancel"}));
                    ui.store.remove_all();
                    ui.all_hits.borrow_mut().clear();
                    ui.status
                        .set_text("Suchmuster oder positiven Filter eingeben.");
                    return;
                }
            }
            ui.start();
        });
    }
    fn reset_transient_actions(&self) {
        self.preview_epoch.set(self.preview_epoch.get() + 1);
        if let Some(window) = self.preview_window.borrow_mut().take() {
            window.close();
        }
        self.preview_jobs.borrow_mut().clear();
        self.preview_lease.borrow_mut().take();
        self.actions.borrow_mut().clear();
        *self.thumbnails.borrow_mut() = Default::default();
        self.evidence_load.borrow_mut().take();
        self.evidence_identity.borrow_mut().take();
        self.initial_selection.borrow_mut().clear();
    }
    fn start(&self) {
        let _ = self.start_with_reference(None);
    }
    fn start_with_reference(&self, reference: Option<&Value>) -> Result<(), String> {
        if !self.root_confirmed.get() {
            let error = "Zuerst einen Suchbereich wählen.".to_owned();
            self.status.set_text(&error);
            return Err(error);
        }
        let mut request = self.configuration();
        request["pattern"] = json!(self.query.text().trim().to_owned());
        request["operation"] = json!("start");
        request["quick"] = json!(self.quick);
        request["contentPreview"] = json!(self.preview_enabled.is_active());
        if let Some(reference) = reference {
            request["dateReferenceTime"] = reference.clone();
        }
        self.retained_options
            .borrow_mut()
            .retain(|v| v["name"] != "__continuation");
        match self.model.call(request) {
            Ok(value) => {
                self.reset_transient_actions();
                let mut snapshot = self.configuration();
                snapshot.as_object_mut().unwrap().remove("continuation");
                *self.last_configuration.borrow_mut() = Some(snapshot);
                self.store.remove_all();
                self.all_hits.borrow_mut().clear();
                self.collapsed.borrow_mut().clear();
                self.ended.set(false);
                *self.run_state.borrow_mut() = "running".into();
                self.warning_count.set(0);
                self.preview.buffer().set_text("");
                *self.run.borrow_mut() = value["runID"].as_str().map(str::to_owned);
                *self.report.borrow_mut() = None;
                self.report_text.borrow_mut().clear();
                self.status.set_text("Suche läuft …");
                Ok(())
            }
            Err(error) => {
                self.status.set_text(&error);
                Err(error)
            }
        }
    }
    fn poll(self: &Rc<Self>) {
        let result = self
            .model
            .call(json!({"operation":"poll","runID":self.run.borrow().as_deref().unwrap_or("")}));
        let Ok(result) = result else { return };
        for event in result["events"].as_array().into_iter().flatten() {
            match event["kind"].as_str() {
                Some("batch") => {
                    if let Some(hits) = event["hits"].as_array() {
                        self.all_hits.borrow_mut().extend(hits.iter().cloned());
                        self.projection_dirty.set(true);
                    }
                    self.status.set_text(&format!(
                        "{} Treffer · {}",
                        self.store.n_items(),
                        event["progress"].as_str().unwrap_or("Suche läuft …")
                    ));
                }
                Some("finish") => {
                    self.ended.set(true);
                    self.projection_dirty.set(true);
                    let state = event["state"].as_str().unwrap_or("failed");
                    self.warning_count
                        .set(event["warnings"].as_u64().unwrap_or(0));
                    *self.run_state.borrow_mut() = match state {
                        "finished" => {
                            if self.warning_count.get() == 0 {
                                "completed"
                            } else {
                                "warnings"
                            }
                        }
                        "limitReached" => "cancelled",
                        other => other,
                    }
                    .to_owned();
                    let description = match state {
                        "finished" => "Suche beendet",
                        "cancelled" => "Abgebrochen · unvollständig",
                        "limitReached" => "20-Treffer-Grenze · Alle in Favenio öffnen",
                        _ => event["error"].as_str().unwrap_or("Suche fehlgeschlagen"),
                    };
                    self.status.set_text(&format!(
                        "{} Treffer · {} · {} Warnungen",
                        event["count"]
                            .as_u64()
                            .unwrap_or(self.all_hits.borrow().len() as u64),
                        description,
                        event["warnings"]
                    ));
                    *self.report.borrow_mut() = event.get("report").cloned();
                    *self.report_text.borrow_mut() = event["reportText"]
                        .as_str()
                        .unwrap_or(description)
                        .to_owned();
                }
                Some("materialized") => {
                    if let Some(id) = event["actionID"].as_str() {
                        if self.drag_waiting.borrow().contains(id) {
                            self.drag_results
                                .borrow_mut()
                                .insert(id.to_owned(), event.clone());
                            continue;
                        }
                    }
                    if self.thumbnail_ready(event) {
                        continue;
                    }
                    let id = event["actionID"].as_str().unwrap_or("");
                    if let Some((action, hit)) = self.actions.borrow_mut().remove(id) {
                        if action == "preview"
                            && hit["_epoch"].as_u64() != Some(self.preview_epoch.get())
                        {
                            let _ = self
                                .model
                                .call(json!({"operation":"release","actionID":id}));
                            continue;
                        }
                        let path = event["path"].as_str().map(PathBuf::from).or_else(|| {
                            event["pathBytes"]
                                .as_str()
                                .and_then(|s| {
                                    base64::engine::general_purpose::STANDARD.decode(s).ok()
                                })
                                .map(|b| PathBuf::from(std::ffi::OsString::from_vec(b)))
                        });
                        if let Some(path) = path {
                            self.file_action(&action, &hit, &path);
                        } else {
                            self.status.set_text(
                                event["error"]
                                    .as_str()
                                    .unwrap_or("Dateiaktion abgebrochen."),
                            );
                        }
                        if action == "preview" {
                            *self.preview_lease.borrow_mut() = Some(id.to_owned());
                        } else {
                            let _ = self
                                .model
                                .call(json!({"operation":"release","actionID":id}));
                        }
                    }
                }
                Some("preview") => self.preview_event(event),
                Some("handoffIssue") => self.status.set_text(event["text"].as_str().unwrap_or("")),
                Some("filtered") => {
                    self.projection_dirty.set(true);
                    if let Some(e) = event["error"].as_str() {
                        self.status.set_text(e);
                    }
                }
                Some("duplicateProgress") => self.status.set_text(&format!(
                    "Dubletten: {} / {} · {} Bytes gelesen",
                    event["done"], event["total"], event["readBytes"]
                )),
                Some("duplicateResult") => self.show_duplicates(event),
                Some("duplicateError") => self.status.set_text(
                    event["error"]
                        .as_str()
                        .unwrap_or("Dublettenprüfung fehlgeschlagen."),
                ),
                _ => {}
            }
        }
        if self.projection_dirty.get()
            && (self.ended.get()
                || self.last_projection.borrow().elapsed() >= Duration::from_millis(500))
        {
            self.projection_dirty.set(false);
            self.refresh_projection();
            *self.last_projection.borrow_mut() = std::time::Instant::now();
        }
        self.refresh_scope_caption();
        self.poll_previews();
        self.poll_thumbnails();
        let dates: std::collections::BTreeMap<_, _> = self
            .date_values
            .iter()
            .map(|(k, v)| (k.clone(), v.borrow().clone()))
            .collect();
        let signature = json!(dates).to_string();
        if *self.date_signature.borrow() != signature {
            *self.date_signature.borrow_mut() = signature;
            for (field, value) in &self.date_values {
                let value = value.borrow();
                for (key, entry) in &self.filters {
                    if key.starts_with(&(field.to_owned() + "-")) {
                        entry.set_sensitive(value.is_none());
                    }
                }
                if let Some(label) = self.date_labels.get(field) {
                    let caption = value
                        .as_ref()
                        .map(|value| {
                            if value["kind"] == "relative" {
                                format!(
                                    "{} · {}",
                                    value["preset"].as_str().unwrap_or(""),
                                    value["timeZone"].as_str().unwrap_or("")
                                )
                            } else {
                                format!(
                                    "{} bis {}",
                                    value["lower"].as_str().unwrap_or(""),
                                    value["upper"].as_str().unwrap_or("")
                                )
                            }
                        })
                        .unwrap_or_default();
                    if label.text() != caption {
                        label.set_text(&caption);
                    }
                }
            }
            self.quick_changed();
        }
        if self.preview_enabled.is_active()
            && self.last_evidence_check.borrow().elapsed() > Duration::from_secs(1)
        {
            *self.last_evidence_check.borrow_mut() = std::time::Instant::now();
            if let Some(hit) = self.selected().first() {
                if let Err(error) = self
                    .model
                    .call(json!({"operation":"previewStatus","raw":hit["raw"]}))
                {
                    self.preview.buffer().set_text(&error);
                }
            }
        }
    }
    fn filter_count(&self) -> usize {
        self.filters
            .iter()
            .filter(|(_, entry)| !entry.text().is_empty())
            .count()
            + lines(&self.terms).len()
            + lines(&self.excludes).len()
            + self
                .date_values
                .values()
                .filter(|value| value.borrow().is_some())
                .count()
    }
    fn refresh_scope_caption(&self) {
        let root_text = text(&self.roots);
        let roots = self
            .root_identity
            .borrow()
            .as_ref()
            .filter(|(display, _)| *display == root_text)
            .map(|(_, paths)| {
                paths
                    .iter()
                    .map(|path| path.to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|| lines(&self.roots));
        let caption = if roots.len() == 1 {
            let name = std::path::Path::new(&roots[0])
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("/");
            format!("{name} …")
        } else {
            format!("{} Bereiche …", roots.len())
        };
        if self.roots_button.label().as_deref() != Some(&caption) {
            self.roots_button.set_label(&caption);
            if let Some(label) = self.roots_button.child().and_downcast::<gtk::Label>() {
                label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
                label.set_max_width_chars(24);
            }
        }
        let tooltip = roots.join("\n");
        if self.roots_button.tooltip_text().as_deref() != Some(&tooltip) {
            self.roots_button.set_tooltip_text(Some(&tooltip));
        }
        let count = self.filter_count();
        let title = if count == 0 {
            "Weitere Filter: Bildmaße, Größe, Datum, Ausschlüsse und Bereiche".to_owned()
        } else {
            format!("Weitere Filter · {count} gesetzt")
        };
        if self.filters_expander.label().as_deref() != Some(&title) {
            self.filters_expander.set_label(Some(&title));
        }
    }
    fn selected(&self) -> Vec<Value> {
        (0..self.store.n_items())
            .filter(|&i| self.selection.is_selected(i))
            .filter_map(|i| self.store.item(i)?.downcast::<glib::BoxedAnyObject>().ok())
            .map(|o| o.borrow::<Value>().clone())
            .filter(|v| v["kind"] != "group")
            .collect()
    }
    fn act(self: &Rc<Self>, action: &str) {
        let selected = self.selected();
        if selected.is_empty() {
            self.status.set_text("Zuerst einen Treffer auswählen.");
            return;
        }
        if action == "reveal-source" {
            for hit in &selected {
                if let Some(path) = hit["pathBytes"]
                    .as_str()
                    .and_then(|value| base64::engine::general_purpose::STANDARD.decode(value).ok())
                    .map(|bytes| PathBuf::from(std::ffi::OsString::from_vec(bytes)))
                {
                    self.file_action("reveal", hit, &path);
                }
            }
            return;
        }
        if action == "copy" {
            let byte_identity = selected.iter().any(|hit| {
                let raw = serde_json::from_str::<Value>(hit["raw"].as_str().unwrap_or(""))
                    .unwrap_or(Value::Null);
                let hit = raw.get("hit").unwrap_or(&raw);
                std::iter::once(&hit["filesystemPathBytes"])
                    .chain(hit["archiveMemberBytes"].as_array().into_iter().flatten())
                    .filter_map(|value| value.as_str())
                    .filter_map(|value| {
                        base64::engine::general_purpose::STANDARD.decode(value).ok()
                    })
                    .any(|bytes| std::str::from_utf8(&bytes).is_err())
            });
            let key = if byte_identity { "raw" } else { "path" };
            self.window.clipboard().set_text(
                &selected
                    .iter()
                    .filter_map(|hit| hit[key].as_str())
                    .collect::<Vec<_>>()
                    .join(if byte_identity { "" } else { "\n" }),
            );
            if byte_identity {
                self.status.set_text(
                    "Namen mit ungültigem UTF-8 wurden als verlustfreie JSONL-Identitäten kopiert.",
                );
            }
            return;
        }
        if action == "remove" {
            let _=self.model.call(json!({"operation":"remove","indices":selected.iter().filter_map(|v|v["index"].as_u64()).collect::<Vec<_>>()}));
            self.refresh_projection();
            return;
        }
        if action == "preview" {
            self.preview_epoch.set(self.preview_epoch.get() + 1);
        }
        for mut hit in selected
            .into_iter()
            .take(if action == "preview" { 1 } else { usize::MAX })
        {
            if action == "preview" {
                hit["_epoch"] = json!(self.preview_epoch.get());
                if self.preview_page.get() > 0 {
                    hit["documentPosition"]["page"] = json!(self.preview_page.get());
                }
            }
            if hit["openable"] != true {
                self.status
                    .set_text("Ordner innerhalb von Archiven lassen sich nicht als Datei öffnen.");
                continue;
            }
            match self.model.call(
                json!({"operation":"materialize","raw":hit["raw"],"ephemeral":action=="preview"}),
            ) {
                Ok(result) => {
                    if let Some(id) = result["actionID"].as_str() {
                        self.actions
                            .borrow_mut()
                            .insert(id.to_owned(), (action.to_owned(), hit));
                    }
                }
                Err(error) => self.status.set_text(&error),
            }
        }
    }
    fn show_report(&self) {
        let dialog = gtk::Window::builder()
            .title("Suchbericht")
            .transient_for(&self.window)
            .default_width(700)
            .default_height(500)
            .build();
        let view = gtk::TextView::builder()
            .editable(false)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        view.buffer().set_text(&self.report_text.borrow());
        dialog.set_child(Some(&gtk::ScrolledWindow::builder().child(&view).build()));
        dialog.present();
    }
    fn choose_root(self: &Rc<Self>) {
        let dialog = gtk::Window::builder()
            .title("Suchbereiche bearbeiten")
            .modal(true)
            .transient_for(&self.window)
            .default_width(680)
            .default_height(360)
            .build();
        let body = column();
        body.set_margin_top(12);
        body.set_margin_bottom(12);
        body.set_margin_start(12);
        body.set_margin_end(12);
        body.append(&label(
            "Dateien und Ordner · ein absoluter Pfad je Zeile · höchstens 16 Bereiche",
        ));
        let (scroll, editor) = editor(180);
        editor.buffer().set_text(&text(&self.roots));
        body.append(&scroll);
        let native = Rc::new(RefCell::new(self.root_identity.borrow().clone()));
        let actions = row();
        let folder = gtk::Button::with_label("Ordner hinzufügen …");
        let files = gtk::Button::with_label("Dateien hinzufügen …");
        let apply = gtk::Button::with_label("Übernehmen");
        actions.append(&folder);
        actions.append(&files);
        actions.append(&apply);
        body.append(&actions);
        let issue = label("");
        issue.set_wrap(true);
        body.append(&issue);
        locations::populate(&body, &editor, &native);
        for (button, folders) in [(folder, true), (files, false)] {
            let editor = editor.clone();
            let n = native.clone();
            let parent = dialog.clone();
            button.connect_clicked(move |_| {
                let editor = editor.clone();
                let n = n.clone();
                let selected = move |result: Result<gio::ListModel, glib::Error>| {
                    if let Ok(list) = result {
                        let paths = (0..list.n_items())
                            .filter_map(|index| {
                                list.item(index)
                                    .and_downcast::<gio::File>()
                                    .and_then(|file| file.path())
                            })
                            .collect();
                        locations::append(&editor, &n, paths);
                    }
                };
                let chooser = gtk::FileDialog::new();
                if folders {
                    chooser.select_multiple_folders(
                        Some(&parent),
                        None::<&gio::Cancellable>,
                        selected,
                    );
                } else {
                    chooser.open_multiple(Some(&parent), None::<&gio::Cancellable>, selected);
                }
            });
        }
        let weak = Rc::downgrade(self);
        let d = dialog.clone();
        apply.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                let paths = locations::paths(&editor, &native);
                if !locations::valid(&paths) {
                    issue.set_text("Ein bis 16 verschiedene absolute Bereiche angeben, höchstens 4096 Bytes je Pfad."); return;
                }
                ui.roots.buffer().set_text(&text(&editor));
                *ui.root_identity.borrow_mut() = Some((text(&editor), paths));
                ui.root_confirmed.set(true);
                ui.refresh_scope_caption();
                ui.quick_changed();
                d.close();
            }
        });
        dialog.set_child(Some(&body));
        dialog.present();
    }
    fn handoff(&self) {
        let Ok(executable) = std::env::current_exe() else {
            return;
        };
        let config = match self.model.call(json!({"operation":"handoff"})) {
            Ok(value) => value["configuration"].clone(),
            Err(e) => {
                self.status.set_text(&e);
                return;
            }
        };
        let selected = self
            .selected()
            .iter()
            .filter_map(|h| h["id"].as_str().map(str::to_owned))
            .collect::<Vec<_>>();
        let path = match handoff::write(json!({"configuration":config,"selection":selected})) {
            Ok(path) => path,
            Err(error) => {
                self.status.set_text(&error);
                return;
            }
        };
        match std::process::Command::new(executable)
            .arg("--configuration-file")
            .arg(&path)
            .spawn()
        {
            Ok(_) => {}
            Err(e) => {
                let _ = std::fs::remove_file(path);
                self.status.set_text(&e.to_string());
            }
        }
    }
}
fn build(
    app: &gtk::Application,
    model: Model,
    quick: bool,
    directory: PathBuf,
    configuration: Option<Value>,
    needs_scope: bool,
) {
    let icon_name = if quick {
        "org.favenio.Quick"
    } else {
        "org.favenio.Main"
    };
    if let (Some(display), Ok(executable)) = (gdk::Display::default(), std::env::current_exe()) {
        gtk::IconTheme::for_display(&display)
            .add_search_path(executable.parent().unwrap().join("icons"));
    }
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .icon_name(icon_name)
        .title(if quick { "FavenioQuick" } else { "Favenio" })
        .default_width(if quick { 700 } else { 1180 })
        .default_height(if quick { 800 } else { 800 })
        .build();
    let body = column();
    for (edge, set) in [(12, 0)] {
        let _ = set;
        body.set_margin_top(edge);
        body.set_margin_bottom(edge);
        body.set_margin_start(edge);
        body.set_margin_end(edge);
    }
    let top = row();
    let stop = gtk::Button::with_label("Stopp");
    let query = gtk::SearchEntry::builder()
        .placeholder_text("Suchen")
        .hexpand(true)
        .search_delay(if quick { 0 } else { 600 })
        .build();
    let choose = gtk::Button::with_label("Bereiche …");
    top.append(&stop);
    top.append(&query);
    top.append(&choose);
    body.append(&top);
    let controls = gtk::Grid::builder()
        .column_spacing(12)
        .row_spacing(6)
        .build();
    let only = gtk::DropDown::from_strings(&["Dateien & Ordner", "Dateien", "Ordner"]);
    let mode = gtk::DropDown::from_strings(&["Name", "Inhalt", "Metadaten", "Dokumenttext"]);
    controls.attach(&only, 0, 0, 1, 1);
    controls.attach(&mode, 1, 0, 1, 1);
    let mut checks = Vec::new();
    for (index, (key, title, active)) in [
        ("archives", "In Archiven", true),
        ("hidden", "Unsichtbare", false),
        ("exact", "Genauer Name", false),
        ("regex", "Regex", false),
        ("case", "Groß/klein beachten", false),
    ]
    .into_iter()
    .enumerate()
    {
        let c = gtk::CheckButton::with_label(title);
        c.set_active(active);
        let n = index + 2;
        let cols = if quick { 4 } else { 8 };
        controls.attach(&c, (n % cols) as i32, (n / cols) as i32, 1, 1);
        checks.push((key, c));
    }
    body.append(&controls);
    let tools = row();
    let criteria_enabled = gtk::CheckButton::with_label("Zusätzliche Kriterien");
    let edit_criteria = gtk::Button::with_label("Bearbeiten …");
    let report = gtk::Button::with_label("Suchbericht …");
    let handoff = gtk::Button::with_label("Alle in Favenio ↗");
    handoff.set_visible(quick);
    tools.append(&criteria_enabled);
    tools.append(&edit_criteria);
    tools.append(&report);
    tools.append(&handoff);
    body.append(&tools);
    let filters_body = column();
    let (roots_scroll, roots) = editor(50);
    if !needs_scope {
        roots.buffer().set_text(&directory.to_string_lossy());
    }
    filters_body.append(&label(
        "Suchdateien und -ordner · ein absoluter Pfad je Zeile",
    ));
    filters_body.append(&roots_scroll);
    let grid = gtk::Grid::builder()
        .column_spacing(12)
        .row_spacing(8)
        .build();
    let mut filters = Vec::new();
    for (i, (key, title)) in [
        ("minw", "Breite von"),
        ("maxw", "Breite bis"),
        ("minh", "Höhe von"),
        ("maxh", "Höhe bis"),
        ("min-size", "Größe von"),
        ("max-size", "Größe bis"),
        ("modified-from", "Geändert ab (ISO + Zone)"),
        ("modified-to", "Geändert bis (ISO + Zone)"),
        ("created-from", "Erstellt ab (ISO + Zone)"),
        ("created-to", "Erstellt bis (ISO + Zone)"),
    ]
    .into_iter()
    .enumerate()
    {
        let e = gtk::Entry::new();
        let cell = column();
        cell.append(&label(title));
        cell.append(&e);
        let columns = if quick { 2 } else { 4 };
        grid.attach(&cell, (i % columns) as i32, (i / columns) as i32, 1, 1);
        filters.push((key, e));
    }
    filters_body.append(&grid);
    let mut date_values = std::collections::BTreeMap::new();
    let mut date_labels = std::collections::BTreeMap::new();
    for (field, title) in [("modified", "Geändert"), ("created", "Erstellt")] {
        let line = row();
        let value = Rc::new(RefCell::new(None));
        let calendar = gtk::Button::with_label(&format!("{title}: Kalender …"));
        let raw = gtk::Button::with_label("Rohe ISO-Eingabe");
        let caption = gtk::Entry::builder()
            .editable(false)
            .hexpand(true)
            .placeholder_text("Kein Kalenderbereich")
            .build();
        line.append(&calendar);
        line.append(&caption);
        line.append(&raw);
        filters_body.append(&line);
        let v = value.clone();
        let e = caption.clone();
        calendar.connect_clicked(move |_| criteria::date_dialog(&v, &e));
        let v = value.clone();
        let e = caption.clone();
        raw.connect_clicked(move |_| {
            *v.borrow_mut() = None;
            e.set_text("");
        });
        date_values.insert(field.to_owned(), value);
        date_labels.insert(field.to_owned(), caption);
    }
    let encodings = vec![
        "utf-8",
        "auto",
        "utf-16-le",
        "utf-16-be",
        "windows-1252",
        "iso-8859-1",
        "mac-roman",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect::<Vec<_>>();
    let encoding = gtk::DropDown::from_strings(&[
        "UTF-8",
        "BOM-Automatik",
        "UTF-16 LE",
        "UTF-16 BE",
        "Windows-1252",
        "ISO-8859-1",
        "Mac Roman",
    ]);
    let er = row();
    er.append(&label("Textkodierung"));
    er.append(&encoding);
    filters_body.append(&er);
    let (ts, terms) = editor(44);
    filters_body.append(&label("Weitere Begriffe (UND) · ein Begriff je Zeile"));
    filters_body.append(&ts);
    let (es, excludes) = editor(44);
    filters_body.append(&label("Ausschlüsse · ein Muster je Zeile"));
    filters_body.append(&es);
    let extras = row();
    for (key, title) in [
        ("literal-wildcards", "Platzhalter wörtlich"),
        ("ocr", "Bild-OCR (DE/EN)"),
        ("pdf-ocr", "Scan-PDF-OCR"),
    ] {
        let c = gtk::CheckButton::with_label(title);
        extras.append(&c);
        checks.push((key, c));
    }
    filters_body.append(&extras);
    let catalog = model
        .call(json!({"operation":"catalog"}))
        .unwrap_or(Value::Null);
    let metadata_fields = strings(&catalog["metadataFields"]);
    let mut field_names = vec!["Alle Metadatenfelder".to_owned()];
    field_names.extend(metadata_fields.clone());
    let metadata_field =
        gtk::DropDown::from_strings(&field_names.iter().map(String::as_str).collect::<Vec<_>>());
    filters_body.append(&metadata_field);
    let platform_note=label("Finder-Tags/-Kommentare und die garantierte Cloud-Nachladesperre sind unter Linux nicht verfügbar.");
    platform_note.set_wrap(true);
    platform_note.add_css_class("dim-label");
    filters_body.append(&platform_note);
    let expander = gtk::Expander::builder()
        .label("Weitere Filter: Bildmaße, Größe, Datum, Ausschlüsse und Bereiche")
        .child(
            &gtk::ScrolledWindow::builder()
                .child(&filters_body)
                .max_content_height(340)
                .propagate_natural_height(true)
                .hscrollbar_policy(gtk::PolicyType::Automatic)
                .vscrollbar_policy(gtk::PolicyType::Automatic)
                .build(),
        )
        .build();
    body.append(&expander);
    let store = gio::ListStore::new::<glib::BoxedAnyObject>();
    let selection = gtk::MultiSelection::new(Some(store.clone()));
    let table = gtk::ColumnView::new(Some(selection.clone()));
    table.set_hexpand(true);
    table.set_vexpand(true);
    table.add_css_class("data-table");
    let columns = if quick {
        vec![("Name", "name", 260), ("Pfad", "folder", 300)]
    } else {
        vec![
            ("Name", "name", 230),
            ("Größe", "size", 80),
            ("Pfad", "folder", 320),
            ("Typ", "type", 130),
            ("Änderungsdatum", "modified", 150),
            ("Erstellungsdatum", "created", 150),
            ("Fundstelle", "location", 160),
            ("Maße", "dimensions", 120),
            ("Finder-Tags", "finderTags", 180),
            ("Finder-Kommentar", "finderComment", 220),
        ]
    };
    let mut table_factories = Vec::new();
    for (title, key, width) in columns {
        let factory = gtk::SignalListItemFactory::new();
        factory.connect_setup(|_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let l = label("");
            l.set_ellipsize(gtk::pango::EllipsizeMode::End);
            item.set_child(Some(&l));
        });
        factory.connect_bind(move |_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let object = item.item().and_downcast::<glib::BoxedAnyObject>().unwrap();
            let value = object.borrow::<Value>();
            let l = item.child().and_downcast::<gtk::Label>().unwrap();
            let cell = if ["modified", "created"].contains(&key) && value[key].is_number() {
                value[key]
                    .as_f64()
                    .and_then(|v| glib::DateTime::from_unix_local(v.floor() as i64).ok())
                    .and_then(|v| v.format("%x %H:%M").ok())
                    .map(|s| s.to_string())
                    .unwrap_or_default()
            } else if key == "size" && value[key].is_number() {
                glib::format_size(value[key].as_u64().unwrap_or(0)).to_string()
            } else if let Some(s) = value[key].as_str() {
                s.to_owned()
            } else if value[key].is_number() {
                value[key].to_string()
            } else {
                String::new()
            };
            l.set_text(&cell);
            l.set_tooltip_text(Some(value["path"].as_str().unwrap_or("")));
        });
        table_factories.push(factory.clone());
        let c = gtk::ColumnViewColumn::new(Some(title), Some(factory));
        if key != "location" {
            c.set_sorter(Some(&gtk::CustomSorter::new(|_, _| gtk::Ordering::Equal)));
        }
        c.set_resizable(true);
        c.set_fixed_width(width);
        table.append_column(&c);
    }
    let grouping = gtk::DropDown::from_strings(&[
        "Keine Gruppierung",
        "Nach Ordner",
        "Nach Endung",
        "Nach Quellarchiv",
    ]);
    let sorting = gtk::DropDown::from_strings(&[
        "Name",
        "Größe",
        "Pfad",
        "Typ",
        "Geändert",
        "Erstellt",
        "Bildmaße",
        "Finder-Tags",
        "Finder-Kommentar",
    ]);
    let ascending = gtk::CheckButton::with_label("Aufsteigend");
    ascending.set_active(true);
    let group_controls = row();
    group_controls.append(&grouping);
    group_controls.append(&sorting);
    group_controls.append(&ascending);
    let collapse = gtk::Button::with_label("Alle einklappen");
    let expand = gtk::Button::with_label("Alle ausklappen");
    group_controls.append(&collapse);
    group_controls.append(&expand);
    let view_mode = gtk::DropDown::from_strings(&["Liste", "Miniaturen"]);
    group_controls.append(&view_mode);
    if quick {
        filters_body.append(
            &gtk::ScrolledWindow::builder()
                .hscrollbar_policy(gtk::PolicyType::Automatic)
                .vscrollbar_policy(gtk::PolicyType::Never)
                .child(&group_controls)
                .build(),
        );
    } else {
        body.append(&group_controls);
    }
    let grid_factory = gtk::SignalListItemFactory::new();
    grid_factory.connect_setup(|_, item| {
        let i = item.downcast_ref::<gtk::ListItem>().unwrap();
        let b = column();
        let icon = gtk::Image::from_icon_name("text-x-generic-symbolic");
        icon.set_pixel_size(64);
        b.append(&icon);
        let l = label("");
        l.set_wrap(true);
        l.set_max_width_chars(22);
        b.append(&l);
        b.set_size_request(160, 110);
        i.set_child(Some(&b));
    });
    grid_factory.connect_bind(|_, item| {
        let i = item.downcast_ref::<gtk::ListItem>().unwrap();
        let o = i.item().and_downcast::<glib::BoxedAnyObject>().unwrap();
        let v = o.borrow::<Value>();
        let b = i.child().and_downcast::<gtk::Box>().unwrap();
        let icon = b.first_child().and_downcast::<gtk::Image>().unwrap();
        icon.set_icon_name(Some(if v["isDirectory"] == true {
            "folder-symbolic"
        } else {
            "text-x-generic-symbolic"
        }));
        let l = b.last_child().and_downcast::<gtk::Label>().unwrap();
        l.set_text(v["name"].as_str().or(v["title"].as_str()).unwrap_or(""));
        b.set_tooltip_text(v["path"].as_str());
    });
    let grid = gtk::GridView::new(Some(selection.clone()), Some(grid_factory.clone()));
    grid.set_min_columns(1);
    grid.set_max_columns(12);
    let result_stack = gtk::Stack::new();
    result_stack.add_named(
        &gtk::ScrolledWindow::builder()
            .child(&table)
            .vexpand(true)
            .min_content_height(180)
            .build(),
        Some("list"),
    );
    result_stack.add_named(
        &gtk::ScrolledWindow::builder()
            .child(&grid)
            .vexpand(true)
            .build(),
        Some("grid"),
    );
    result_stack.set_vexpand(true);
    body.append(&result_stack);
    let action_row = gtk::Grid::builder()
        .column_spacing(6)
        .row_spacing(6)
        .build();
    let mut action_buttons = Vec::new();
    for (index, (action, title)) in [
        ("open", "Öffnen"),
        ("preview", "Vorschau · Leertaste"),
        ("reveal", "Im Dateimanager zeigen"),
        ("copy", "Pfad kopieren"),
        ("remove", "Aus Liste entfernen"),
        ("trash", "Papierkorb"),
        ("open-with", "Öffnen mit …"),
    ]
    .into_iter()
    .enumerate()
    {
        let b = gtk::Button::with_label(title);
        let cols = 4;
        action_row.attach(&b, (index % cols) as i32, (index / cols) as i32, 1, 1);
        action_buttons.push((action, b));
    }
    body.append(&action_row);
    let utility_row = gtk::Grid::builder()
        .column_spacing(6)
        .row_spacing(6)
        .build();
    let mut utilities = Vec::new();
    for (index, (action, title)) in [
        ("templates", "Vorlagen …"),
        ("export", "Export …"),
        ("duplicates", "Dubletten …"),
        ("filter", "Ansichtsfilter …"),
        ("reset-filter", "Filter zurücksetzen"),
        ("save-recording", "Aufzeichnung sichern …"),
        ("load-recording", "Aufzeichnung öffnen …"),
        ("update", "Updates …"),
        ("fastra", "In Fastra zeigen"),
        ("regex-templates", "Regex-Vorlagen …"),
    ]
    .into_iter()
    .enumerate()
    {
        let b = gtk::Button::with_label(title);
        let columns = if quick { 3 } else { 5 };
        utility_row.attach(&b, (index % columns) as i32, (index / columns) as i32, 1, 1);
        utilities.push((action, b));
    }
    if quick {
        filters_body.append(&utility_row);
    } else {
        body.append(&utility_row);
    }
    let preview_enabled = gtk::CheckButton::with_label("Fundstellenvorschau");
    preview_enabled.set_active(false);
    body.append(&preview_enabled);
    let navigation = row();
    let evidence_query = gtk::DropDown::from_strings(&["Fundstelle"]);
    let previous_evidence = gtk::Button::with_label("Vorherige");
    let next_evidence = gtk::Button::with_label("Nächste");
    let context_evidence = gtk::Button::with_label("Mehr Kontext");
    let cancel_evidence = gtk::Button::with_label("Abbrechen");
    for widget in [
        evidence_query.clone().upcast::<gtk::Widget>(),
        previous_evidence.clone().upcast(),
        next_evidence.clone().upcast(),
        context_evidence.clone().upcast(),
        cancel_evidence.clone().upcast(),
    ] {
        navigation.append(&widget);
    }
    body.append(&navigation);
    navigation.set_visible(false);
    let (ps, preview) = editor(100);
    preview.set_editable(false);
    body.append(&ps);
    ps.set_visible(false);
    let preview_restart = gtk::Button::with_label("Mit Vorschau neu suchen");
    body.append(&preview_restart);
    preview_restart.set_visible(false);
    let status = label("Return startet die Suche");
    body.append(&status);
    window.set_child(Some(&body));
    let preview_restart_action = preview_restart.clone();
    let ui = Rc::new(Ui {
        window,
        model,
        quick,
        root_confirmed: std::cell::Cell::new(!needs_scope),
        query,
        roots,
        roots_button: choose.clone(),
        filters_expander: expander.clone(),
        mode,
        only,
        checks,
        encoding,
        encodings,
        metadata_field: metadata_field.clone(),
        metadata_fields: metadata_fields.clone(),
        filters,
        date_values,
        date_labels,
        date_signature: RefCell::new(String::new()),
        terms,
        excludes,
        criteria: RefCell::new(None),
        criteria_enabled,
        store,
        selection,
        status,
        preview,
        preview_enabled,
        evidence_query,
        evidence_identity: RefCell::new(None),
        evidence_occurrence: std::cell::Cell::new(0),
        evidence_load: RefCell::new(None),
        evidence_at_end: std::cell::Cell::new(false),
        last_evidence_check: RefCell::new(std::time::Instant::now()),
        rebuilding: std::cell::Cell::new(false),
        run: RefCell::new(None),
        report: RefCell::new(None),
        report_text: RefCell::new(String::new()),
        actions: RefCell::new(Default::default()),
        preview_window: RefCell::new(None),
        all_hits: RefCell::new(Vec::new()),
        grouping,
        sorting,
        ascending,
        collapsed: RefCell::new(Default::default()),
        grid,
        result_stack,
        projection_dirty: std::cell::Cell::new(false),
        last_projection: RefCell::new(std::time::Instant::now()),
        ended: std::cell::Cell::new(true),
        run_state: RefCell::new("idle".into()),
        warning_count: std::cell::Cell::new(0),
        result_generation: std::cell::Cell::new(0),
        result_count: std::cell::Cell::new(0),
        control: RefCell::new(if quick {
            None
        } else {
            control::Server::start().ok()
        }),
        retained_options: RefCell::new(Vec::new()),
        root_identity: RefCell::new(None),
        preview_jobs: RefCell::new(Vec::new()),
        preview_lease: RefCell::new(None),
        thumbnails: RefCell::new(Default::default()),
        preview_epoch: std::cell::Cell::new(0),
        preview_page: std::cell::Cell::new(0),
        drag_waiting: RefCell::new(Default::default()),
        drag_results: RefCell::new(Default::default()),
        suppress_quick: std::cell::Cell::new(false),
        quick_epoch: std::cell::Cell::new(0),
        last_configuration: RefCell::new(None),
        initial_selection: RefCell::new(std::collections::HashSet::new()),
    });
    for factory in &table_factories {
        ui.install_result_menu(factory);
    }
    ui.install_result_menu(&grid_factory);
    let weak = Rc::downgrade(&ui);
    preview_restart_action.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.start();
        }
    });
    if !needs_scope {
        *ui.root_identity.borrow_mut() = Some((
            directory.to_string_lossy().into_owned(),
            vec![directory.clone()],
        ));
    }
    let weak = Rc::downgrade(&ui);
    grid_factory.connect_bind(move |_, item| {
        if let Some(ui) = weak.upgrade() {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            if let (Some(object), Some(container)) = (
                item.item().and_downcast::<glib::BoxedAnyObject>(),
                item.child().and_downcast::<gtk::Box>(),
            ) {
                if let Some(image) = container.first_child().and_downcast::<gtk::Image>() {
                    ui.queue_thumbnail(item, &image, &object.borrow::<Value>());
                }
            }
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.query.connect_activate(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.start();
        }
    });
    if quick {
        let weak = Rc::downgrade(&ui);
        ui.query.connect_search_changed(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.quick_changed();
            }
        });
        for (_, check) in &ui.checks {
            let weak = Rc::downgrade(&ui);
            check.connect_toggled(move |_| {
                if let Some(ui) = weak.upgrade() {
                    ui.quick_changed();
                }
            });
        }
        for control in [&ui.mode, &ui.only, &ui.encoding] {
            let weak = Rc::downgrade(&ui);
            control.connect_selected_notify(move |_| {
                if let Some(ui) = weak.upgrade() {
                    ui.quick_changed();
                }
            });
        }
        for (_, entry) in &ui.filters {
            let weak = Rc::downgrade(&ui);
            entry.connect_changed(move |_| {
                if let Some(ui) = weak.upgrade() {
                    ui.quick_changed();
                }
            });
        }
        for editor in [&ui.roots, &ui.terms, &ui.excludes] {
            let weak = Rc::downgrade(&ui);
            editor.buffer().connect_changed(move |_| {
                if let Some(ui) = weak.upgrade() {
                    ui.quick_changed();
                }
            });
        }
        let weak = Rc::downgrade(&ui);
        ui.criteria_enabled.connect_toggled(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.quick_changed();
            }
        });
    }
    let weak = Rc::downgrade(&ui);
    stop.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            let _ = ui.model.call(json!({"operation":"cancel"}));
        }
    });
    let weak = Rc::downgrade(&ui);
    choose.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.choose_root();
        }
    });
    let weak = Rc::downgrade(&ui);
    report.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.show_report();
        }
    });
    let weak = Rc::downgrade(&ui);
    handoff.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.handoff();
        }
    });
    for (action, button) in action_buttons {
        let weak = Rc::downgrade(&ui);
        button.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                if action == "trash" {
                    ui.trash();
                } else {
                    ui.act(action);
                }
            }
        });
    }
    let weak = Rc::downgrade(&ui);
    ui.selection.connect_selection_changed(move |_, _, _| {
        if let Some(ui) = weak.upgrade() {
            if !ui.rebuilding.get() {
                ui.preview_page.set(0);
                ui.update_preview();
            }
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.preview_enabled.connect_toggled(move |_| {
        if let Some(ui) = weak.upgrade() {
            ps.set_visible(ui.preview_enabled.is_active());
            navigation.set_visible(ui.preview_enabled.is_active());
            preview_restart.set_visible(ui.preview_enabled.is_active());
            ui.update_preview();
        }
    });
    let weak = Rc::downgrade(&ui);
    table.connect_activate(move |_, position| {
        if let Some(ui) = weak.upgrade() {
            ui.activate_row(position);
        }
    });
    let weak = Rc::downgrade(&ui);
    edit_criteria.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            criteria::open(&ui);
        }
    });
    let key = gtk::EventControllerKey::new();
    key.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&ui);
    key.connect_key_pressed(move |_, key, _, modifiers| {
        let Some(ui) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if modifiers == gdk::ModifierType::CONTROL_MASK && key == gdk::Key::c {
            ui.act("copy");
            return glib::Propagation::Stop;
        }
        if modifiers.is_empty() && key == gdk::Key::Escape {
            if let Some(p) = ui.preview_window.borrow_mut().take() {
                p.close();
            } else if ui.quick {
                ui.window.close();
            }
            return glib::Propagation::Stop;
        }
        if modifiers.is_empty() && key == gdk::Key::space && !ui.query.has_focus() {
            ui.act("preview");
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    ui.result_stack.add_controller(key);
    let weak = Rc::downgrade(&ui);
    ui.window.connect_close_request(move |_| {
        if let Some(ui) = weak.upgrade() {
            let _ = ui.model.call(json!({"operation":"cleanup"}));
        }
        glib::Propagation::Proceed
    });
    if let Some(config) = configuration {
        let input = config.get("configuration").unwrap_or(&config);
        ui.apply_configuration(input);
        ui.start();
        *ui.initial_selection.borrow_mut() = strings(&config["selection"]).into_iter().collect();
    }
    if let Some(sorter) = table.sorter().and_downcast::<gtk::ColumnViewSorter>() {
        let weak = Rc::downgrade(&ui);
        sorter.connect_changed(move |sorter, _| {
            let Some(ui) = weak.upgrade() else {
                return;
            };
            let title = sorter
                .primary_sort_column()
                .and_then(|column| column.title());
            let index = match title.as_deref() {
                Some("Name") => 0,
                Some("Größe") => 1,
                Some("Pfad") => 2,
                Some("Typ") => 3,
                Some("Änderungsdatum") => 4,
                Some("Erstellungsdatum") => 5,
                Some("Maße") => 6,
                Some("Finder-Tags") => 7,
                Some("Finder-Kommentar") => 8,
                _ => return,
            };
            ui.sorting.set_selected(index);
            ui.ascending
                .set_active(sorter.primary_sort_order() == gtk::SortType::Ascending);
            ui.refresh_projection();
        });
    }
    let weak = Rc::downgrade(&ui);
    ui.grouping.connect_selected_notify(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.sorting.connect_selected_notify(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.ascending.connect_toggled(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(&ui);
    collapse.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.collapse_all();
        }
    });
    let weak = Rc::downgrade(&ui);
    expand.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.collapsed.borrow_mut().clear();
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(&ui);
    view_mode.connect_selected_notify(move |v| {
        if let Some(ui) = weak.upgrade() {
            ui.result_stack
                .set_visible_child_name(if v.selected() == 1 { "grid" } else { "list" });
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.grid.connect_activate(move |_, position| {
        if let Some(ui) = weak.upgrade() {
            ui.activate_row(position);
        }
    });
    for (action, button) in utilities {
        let weak = Rc::downgrade(&ui);
        button.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.utility(action);
            }
        });
    }
    let weak = Rc::downgrade(&ui);
    metadata_field.connect_selected_notify(move |f| {
        if let Some(ui) = weak.upgrade() {
            ui.retained_options
                .borrow_mut()
                .retain(|v| v["name"] != "field");
            if f.selected() > 0 {
                ui.retained_options.borrow_mut().push(
                    json!({"name":"field","value":metadata_fields[(f.selected()-1)as usize]}),
                );
            }
        }
    });
    let global_key = gtk::EventControllerKey::new();
    global_key.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = Rc::downgrade(&ui);
    global_key.connect_key_pressed(move |_, key, _, modifiers| {
        let Some(ui) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if key == gdk::Key::Escape && modifiers.is_empty() {
            if let Some(window) = ui.preview_window.borrow_mut().take() {
                ui.preview_epoch.set(ui.preview_epoch.get() + 1);
                window.close();
                return glib::Propagation::Stop;
            }
            if ui.quick {
                ui.window.close();
                return glib::Propagation::Stop;
            }
        }
        if ui.quick
            && modifiers == gdk::ModifierType::CONTROL_MASK
            && (key == gdk::Key::Return || key == gdk::Key::KP_Enter)
        {
            ui.handoff();
            return glib::Propagation::Stop;
        }
        if modifiers == gdk::ModifierType::CONTROL_MASK && key == gdk::Key::f {
            ui.query.grab_focus();
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    ui.window.add_controller(global_key);
    for widget in [
        table.clone().upcast::<gtk::Widget>(),
        ui.grid.clone().upcast::<gtk::Widget>(),
    ] {
        let source = gtk::DragSource::new();
        source.set_actions(gdk::DragAction::COPY);
        let weak = Rc::downgrade(&ui);
        source.connect_prepare(move |_, _, _| {
            let ui = weak.upgrade()?;
            drag::Provider::new(&ui).map(|provider| provider.upcast())
        });
        widget.add_controller(source);
    }
    for (button, delta, context) in [
        (previous_evidence, -1, false),
        (next_evidence, 1, false),
        (context_evidence, 0, true),
    ] {
        let weak = Rc::downgrade(&ui);
        button.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.navigate_evidence(delta, context);
            }
        });
    }
    let weak = Rc::downgrade(&ui);
    cancel_evidence.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            let _ = ui.model.call(json!({"operation":"cancelPreview"}));
            ui.evidence_load.borrow_mut().take();
            ui.status
                .set_text("Nachladen abgebrochen. Bisheriger Beleg bleibt erhalten.");
        }
    });
    let weak = Rc::downgrade(&ui);
    ui.evidence_query.connect_selected_notify(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.evidence_occurrence.set(0);
            ui.evidence_at_end.set(false);
            let _ = ui.model.call(json!({"operation":"cancelPreview"}));
            ui.evidence_load.borrow_mut().take();
            if let Some(hit) = ui.selected().first() {
                ui.render_evidence(&hit["preview"]);
            }
        }
    });
    ui.window.present();
    if needs_scope {
        ui.status.set_text("Zuerst einen Suchbereich wählen.");
        ui.choose_root();
    }
    ui.query.grab_focus();
    glib::timeout_add_local_once(Duration::from_secs(15), || {
        if let Ok(executable) = std::env::current_exe() {
            let _ = std::process::Command::new(
                executable.parent().unwrap().join("helpers/favenio-update"),
            )
            .args(["--check", "--notify"])
            .spawn();
        }
    });
    glib::timeout_add_local(Duration::from_millis(40), move || {
        if !ui.window.is_visible() {
            return glib::ControlFlow::Break;
        }
        ui.poll();
        ui.poll_control();
        glib::ControlFlow::Continue
    });
}
fn installation_lease() -> Result<Option<std::fs::File>, String> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let Some(versions) = executable.parent().and_then(|folder| folder.parent()) else {
        return Ok(None);
    };
    if versions.file_name().and_then(|name| name.to_str()) != Some("versions") {
        return Ok(None);
    }
    let root = versions.parent().ok_or("Installationsordner fehlt")?;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(root.join("lifecycle.lock"))
        .map_err(|error| error.to_string())?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
        return Err("Die Favenio-Installation wird gerade entfernt. Danach erneut starten.".into());
    }
    Ok(Some(file))
}
fn main() {
    let _installation = match installation_lease() {
        Ok(lease) => lease,
        Err(error) => {
            eprintln!("favenio: {error}");
            std::process::exit(2);
        }
    };

    let native_arguments: Vec<_> = std::env::args_os().collect();
    let arguments: Vec<String> = native_arguments
        .iter()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    let quick = arguments.iter().any(|s| s == "--quick")
        || arguments
            .first()
            .is_some_and(|s| s.ends_with("favenio-quick"));
    let directory = native_arguments
        .windows(2)
        .find(|p| p[0] == "--directory")
        .map(|p| PathBuf::from(&p[1]))
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")));
    if native_arguments
        .get(1)
        .is_some_and(|s| s == "--render-image" || s == "--normalize-ocr")
    {
        if let Err(e) = decoder::run(&native_arguments) {
            eprintln!("{e}");
            std::process::exit(2)
        }
        return;
    }
    let mut config = arguments
        .windows(2)
        .find(|p| p[0] == "--configuration")
        .and_then(|p| serde_json::from_str::<Value>(&p[1]).ok());
    if let Some(pair) = native_arguments
        .windows(2)
        .find(|p| p[0] == "--configuration-file")
    {
        match handoff::read(&PathBuf::from(&pair[1])) {
            Ok(value) => config = Some(value),
            Err(error) => {
                eprintln!("favenio: {error}");
                std::process::exit(2)
            }
        }
    }
    let executable = std::env::current_exe().expect("Programmdatei fehlt");
    let folder = executable.parent().unwrap().to_path_buf();
    let engine = folder.join("favenio.py");
    std::env::set_var("FAVENIO_ENGINE", engine);
    if arguments.iter().any(|s| s == "--control-capabilities") {
        match Model::load(&folder).and_then(|m| m.call(json!({"operation":"capabilities"}))) {
            Ok(value) => println!("{}", value["capabilities"]),
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(2)
            }
        }
        return;
    }
    if arguments.iter().any(|s| s == "--self-test") {
        match Model::load(&folder).and_then(|m| m.call(json!({"operation":"catalog"}))) {
            Ok(_) => {
                println!("FAVENIO RUNTIME OK");
                return;
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(2)
            }
        }
    }
    let needs_scope = quick
        && config.is_none()
        && !native_arguments
            .windows(2)
            .any(|pair| pair[0] == "--directory");
    let app = gtk::Application::builder()
        .application_id(if quick {
            "org.favenio.Quick"
        } else {
            "org.favenio.Main"
        })
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.connect_activate(move |app| match Model::load(&folder) {
        Ok(model) => build(
            app,
            model,
            quick,
            directory.clone(),
            config.clone(),
            needs_scope,
        ),
        Err(error) => {
            eprintln!("favenio: {error}");
            app.quit();
        }
    });
    let _ = app.run_with_args::<&str>(&[]);
}
