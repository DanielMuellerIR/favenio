use super::*;

impl Ui {
    pub(super) fn utility(self: &Rc<Self>, action: &str) {
        match action {
            "fastra" => {
                let selected = self.selected();
                if selected.len() != 1 {
                    self.status
                        .set_text("Für Fastra genau einen Treffer auswählen.");
                    return;
                }
                match self
                    .model
                    .call(json!({"operation":"fastra","index":selected[0]["index"]}))
                {
                    Ok(_) => {}
                    Err(e) => self.status.set_text(&e),
                }
            }
            "templates" => self.templates(),
            "regex-templates" => self.regex_templates(),
            "export" => self.export_dialog(),
            "duplicates" => {
                if !self.ended.get() {
                    self.status
                        .set_text("Suche vor der Dublettenprüfung beenden oder abbrechen.");
                    return;
                }
                let selected = self.selected();
                let scope = if selected.is_empty() {
                    self.visible_hits()
                } else {
                    selected
                };
                match self.model.call(json!({"operation":"duplicates","indices":scope.iter().filter_map(|h|h["index"].as_u64()).collect::<Vec<_>>()})){Ok(_)=>self.status.set_text("Dublettenprüfung läuft …"),Err(e)=>self.status.set_text(&e)}
            }
            "filter" => {
                if !self.ended.get() {
                    self.status
                        .set_text("Suche vor dem Ansichtsfilter beenden oder abbrechen.");
                    return;
                }
                criteria::open_filter(self);
            }
            "reset-filter" => {
                let _ = self.model.call(json!({"operation":"resetFilter"}));
                self.refresh_projection();
            }
            "save-recording" => self.save_recording(),
            "load-recording" => self.load_recording(),
            "update" => self.update_dialog(),
            _ => {}
        }
    }
    fn visible_hits(&self) -> Vec<Value> {
        let response=self.model.call(json!({"operation":"projection","runID":self.run.borrow().as_deref().unwrap_or(""),"mode":"none","sort":(SORT_KEYS[self.sorting.selected()as usize]),"ascending":self.ascending.is_active()}));
        let Ok(response) = response else {
            return Vec::new();
        };
        let hits = self.all_hits.borrow();
        response["rows"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| {
                v["index"]
                    .as_u64()
                    .and_then(|i| hits.get(i as usize))
                    .cloned()
            })
            .collect()
    }
    fn regex_templates(self: &Rc<Self>) {
        let catalog = match self.model.call(json!({"operation":"catalog"})) {
            Ok(value) => value,
            Err(error) => {
                self.status.set_text(&error);
                return;
            }
        };
        let window = gtk::Window::builder()
            .title("Regex-Vorlagen")
            .transient_for(&self.window)
            .default_width(600)
            .default_height(500)
            .build();
        let list = gtk::ListBox::new();
        for value in catalog["regexTemplates"].as_array().into_iter().flatten() {
            let button = gtk::Button::with_label(&format!(
                "{} · {}",
                value["category"].as_str().unwrap_or(""),
                value["name"].as_str().unwrap_or("")
            ));
            button.set_tooltip_text(Some(&format!(
                "{}\nBeispiel: {}",
                value["regex"].as_str().unwrap_or(""),
                value["example"].as_str().unwrap_or("")
            )));
            let regex = value["regex"].as_str().unwrap_or("").to_owned();
            let weak = Rc::downgrade(self);
            let dialog = window.clone();
            button.connect_clicked(move |_| {
                if let Some(ui) = weak.upgrade() {
                    ui.query.set_text(&regex);
                    if let Some((_, check)) = ui.checks.iter().find(|(name, _)| *name == "regex") {
                        check.set_active(true);
                    }
                    dialog.close();
                    ui.query.grab_focus();
                }
            });
            list.append(&button);
        }
        window.set_child(Some(&gtk::ScrolledWindow::builder().child(&list).build()));
        window.present();
    }
    fn templates(self: &Rc<Self>) {
        let window = gtk::Window::builder()
            .title("Suchvorlagen")
            .transient_for(&self.window)
            .default_width(600)
            .default_height(420)
            .build();
        let body = column();
        body.set_margin_top(12);
        body.set_margin_bottom(12);
        body.set_margin_start(12);
        body.set_margin_end(12);
        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::Single);
        let initial = self
            .model
            .call(json!({"operation":"templates"}))
            .unwrap_or(Value::Null);
        let templates = initial["templates"].as_array().cloned().unwrap_or_default();
        for template in &templates {
            list.append(&label(template["name"].as_str().unwrap_or("")));
        }
        body.append(
            &gtk::ScrolledWindow::builder()
                .child(&list)
                .vexpand(true)
                .build(),
        );
        let name = gtk::Entry::builder()
            .placeholder_text("Name der neuen Vorlage")
            .build();
        body.append(&name);
        let actions = row();
        let load = gtk::Button::with_label("Laden");
        let save = gtk::Button::with_label("Aktuelle Suche sichern");
        let delete = gtk::Button::with_label("Löschen");
        let rename = gtk::Button::with_label("Umbenennen");
        actions.append(&load);
        actions.append(&save);
        actions.append(&delete);
        actions.append(&rename);
        body.append(&actions);
        let issue = label("");
        issue.set_wrap(true);
        body.append(&issue);
        let weak = Rc::downgrade(self);
        let l = list.clone();
        let t = templates.clone();
        let w = window.clone();
        load.connect_clicked(move |_| {
            if let (Some(ui), Some(row)) = (weak.upgrade(), l.selected_row()) {
                if let Some(template) = t.get(row.index() as usize) {
                    ui.apply_configuration(template);
                    w.close();
                }
            }
        });
        let weak = Rc::downgrade(self);
        let i = issue.clone();
        let w = window.clone();
        let save_name = name.clone();
        save.connect_clicked(move |_| {
            let name = &save_name;
            if name.text().trim().is_empty() {
                i.set_text("Eine Vorlage braucht einen Namen.");
                return;
            }
            if let Some(ui) = weak.upgrade() {
                let mut request = ui.configuration();
                request["operation"] = json!("templates");
                request["name"] = json!(name.text().to_string());
                match ui.model.call(request) {
                    Ok(_) => w.close(),
                    Err(e) => i.set_text(&e),
                }
            }
        });
        let weak = Rc::downgrade(self);
        let l = list.clone();
        let t = templates.clone();
        let i = issue.clone();
        let field = name.clone();
        let w = window.clone();
        rename.connect_clicked(move |_| {
            if let (Some(ui), Some(row)) = (weak.upgrade(), l.selected_row()) {
                if let Some(template) = t.get(row.index() as usize) {
                    match ui.model.call(json!({"operation":"templates", "rename":template["name"], "newName":field.text().to_string()})) {
                        Ok(_) => w.close(), Err(error) => i.set_text(&error),
                    }
                }
            }
        });
        let weak = Rc::downgrade(self);
        let i = issue;
        let w = window.clone();
        delete.connect_clicked(move |_| {
            if let (Some(ui), Some(row)) = (weak.upgrade(), list.selected_row()) {
                if let Some(template) = templates.get(row.index() as usize) {
                    match ui
                        .model
                        .call(json!({"operation":"templates","delete":template["name"]}))
                    {
                        Ok(_) => w.close(),
                        Err(e) => i.set_text(&e),
                    }
                }
            }
        });
        window.set_child(Some(&body));
        window.present();
    }
    fn export_dialog(self: &Rc<Self>) {
        let window = gtk::Window::builder()
            .title("Treffer exportieren")
            .transient_for(&self.window)
            .default_width(450)
            .build();
        let body = column();
        let format = gtk::DropDown::from_strings(&[
            "Pfade (Text)",
            "Pfade (NUL-getrennt)",
            "JSON Lines",
            "CSV",
        ]);
        let selected = gtk::CheckButton::with_label("Nur Auswahl");
        selected.set_active(!self.selected().is_empty());
        let save = gtk::Button::with_label("Sichern …");
        body.append(&format);
        body.append(&selected);
        body.append(&save);
        let weak = Rc::downgrade(self);
        let w = window.clone();
        save.connect_clicked(move |_| {
            let Some(ui)=weak.upgrade() else{return};
            let mut request=json!({"operation":"exportCurrent","runID":ui.run.borrow().as_deref().unwrap_or(""),"format":(["paths","pathsNUL","jsonl","csv"][format.selected()as usize]),"sort":(SORT_KEYS[ui.sorting.selected()as usize]),"ascending":ui.ascending.is_active()});
            if selected.is_active(){request["indices"]=json!(ui.selected().iter().filter_map(|v|v["index"].as_u64()).collect::<Vec<_>>());}
            match ui.model.call(request){
                Ok(value)=>{if let Some(data)=value["data"].as_str().and_then(|s|base64::engine::general_purpose::STANDARD.decode(s).ok()){
                    let name=["favenio-treffer.txt","favenio-treffer-nul.txt","favenio-treffer.jsonl","favenio-treffer.csv"][format.selected()as usize];
                    ui.save_bytes("Treffer exportieren",name,data);w.close();
                }},
                Err(error)=>ui.status.set_text(&error)
            }
        });
        window.set_child(Some(&body));
        window.present();
    }
    fn save_bytes(self: &Rc<Self>, title: &str, name: &str, data: Vec<u8>) {
        let weak = Rc::downgrade(self);
        gtk::FileDialog::builder()
            .title(title)
            .initial_name(name)
            .build()
            .save(
                Some(&self.window),
                None::<&gio::Cancellable>,
                move |result| {
                    if let (Some(ui), Ok(file)) = (weak.upgrade(), result) {
                        let status = ui.status.clone();
                        file.replace_contents_async(
                            data,
                            None,
                            false,
                            gio::FileCreateFlags::PRIVATE,
                            None::<&gio::Cancellable>,
                            move |result| match result {
                                Ok(_) => status.set_text("Datei gesichert."),
                                Err((_, e)) => status.set_text(&e.to_string()),
                            },
                        );
                    }
                },
            );
    }
    fn save_recording(self: &Rc<Self>) {
        match self.model.call(json!({"operation":"captureRecording","indices":self.selected().iter().filter_map(|v|v["index"].as_u64()).collect::<Vec<_>>()})){Ok(value)=>if let Some(data)=value["data"].as_str().and_then(|s|base64::engine::general_purpose::STANDARD.decode(s).ok()){self.save_bytes("Suchstand aufzeichnen","suche.favenio.json",data);},Err(e)=>self.status.set_text(&e)}
    }
    fn load_recording(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        gtk::FileDialog::builder().title("Aufzeichnung öffnen").build().open(Some(&self.window),None::<&gio::Cancellable>,move|result|{if let (Some(ui),Ok(file))=(weak.upgrade(),result){let Some(path)=file.path()else{return};use std::io::Read;let data=std::fs::File::open(path).and_then(|f|{let mut data=Vec::new();f.take(196609).read_to_end(&mut data)?;Ok(data)});match data{Ok(data)if data.len()<=196608=>match ui.model.call(json!({"operation":"openRecording","data":base64::engine::general_purpose::STANDARD.encode(data)})){Ok(value)=>{ui.install_recording(&value);},Err(e)=>ui.status.set_text(&e)},Ok(_)=>ui.status.set_text("Aufzeichnung überschreitet 192 KiB."),Err(e)=>ui.status.set_text(&e.to_string())}}});
    }
    fn update_dialog(self: &Rc<Self>) {
        // Der getrennte Koordinator verifiziert Pakete und ändert erst nach Zustimmung den Versionsverweis.
        let program = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("helpers/favenio-update");
        match std::process::Command::new(program).arg("--gui").spawn() {
            Ok(_) => self.status.set_text("Updateprüfung geöffnet."),
            Err(e) => self
                .status
                .set_text(&format!("Updateprüfung konnte nicht starten: {e}")),
        }
    }
}
