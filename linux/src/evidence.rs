use super::*;

pub(super) struct EvidencePane {
    pub enabled: gtk::CheckButton,
    navigation: gtk::Box,
    query: gtk::DropDown,
    previous: gtk::Button,
    next: gtk::Button,
    context: gtk::Button,
    cancel: gtk::Button,
    scroll: gtk::ScrolledWindow,
    pub text: gtk::TextView,
    pub restart: gtk::Button,
}

impl EvidencePane {
    pub fn new(body: &gtk::Box) -> Self {
        let preview_enabled = gtk::CheckButton::with_label("Fundstellenvorschau");
        preview_enabled.set_active(false);
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
        let (scroll, preview) = editor(100);
        preview.set_editable(false);
        let preview_restart = gtk::Button::with_label("Mit Vorschau neu suchen");

        body.append(&preview_enabled);
        body.append(&navigation);
        body.append(&scroll);
        body.append(&preview_restart);
        let pane = Self {
            enabled: preview_enabled,
            navigation,
            query: evidence_query,
            previous: previous_evidence,
            next: next_evidence,
            context: context_evidence,
            cancel: cancel_evidence,
            scroll,
            text: preview,
            restart: preview_restart,
        };
        pane.show_controls(false);
        pane
    }

    pub fn show_controls(&self, visible: bool) {
        self.scroll.set_visible(visible);
        self.navigation.set_visible(visible);
        self.restart.set_visible(visible);
    }
}

pub(super) fn connect_navigation(ui: &Rc<Ui>) {
    for (button, delta, context) in [
        (&ui.evidence.previous, -1, false),
        (&ui.evidence.next, 1, false),
        (&ui.evidence.context, 0, true),
    ] {
        let weak = Rc::downgrade(ui);
        button.connect_clicked(move |_| {
            if let Some(ui) = weak.upgrade() {
                ui.navigate_evidence(delta, context);
            }
        });
    }
    let weak = Rc::downgrade(ui);
    ui.evidence.cancel.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            let _ = ui.model.call(json!({"operation":"cancelPreview"}));
            ui.evidence_load.borrow_mut().take();
            ui.status
                .set_text("Nachladen abgebrochen. Bisheriger Beleg bleibt erhalten.");
        }
    });
    let weak = Rc::downgrade(ui);
    ui.evidence.query.connect_selected_notify(move |_| {
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
}

impl Ui {
    pub(super) fn update_preview(&self) {
        if !self.evidence.enabled.is_active() {
            self.evidence.text.buffer().set_text("");
            return;
        }
        let selected = self.selected();
        let Some(hit) = selected.first() else {
            self.evidence.text.buffer().set_text("Treffer auswählen.");
            return;
        };
        let id = hit["id"].as_str().unwrap_or("").to_owned();
        if self.evidence_identity.borrow().as_ref() != Some(&id) {
            let _ = self.model.call(json!({"operation":"cancelPreview"}));
            self.evidence_load.borrow_mut().take();
            self.evidence_occurrence.set(0);
            self.evidence_at_end.set(false);
            *self.evidence_identity.borrow_mut() = Some(id);
            let labels = hit["preview"]["snippets"]
                .as_array()
                .map(|values| {
                    values
                        .iter()
                        .enumerate()
                        .map(|(index, s)| {
                            format!(
                                "{} · {}",
                                index + 1,
                                s["label"].as_str().unwrap_or("Fundstelle")
                            )
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            self.evidence.query.set_model(Some(&gtk::StringList::new(
                &labels.iter().map(String::as_str).collect::<Vec<_>>(),
            )));
            self.evidence.query.set_selected(0);
        }
        match self
            .model
            .call(json!({"operation":"previewStatus","raw":hit["raw"]}))
        {
            Ok(value) => self.render_evidence(&value["preview"]),
            Err(error) => self.evidence.text.buffer().set_text(&error),
        }
    }
    pub(super) fn render_evidence(&self, preview: &Value) {
        let snippets = preview["snippets"].as_array().cloned().unwrap_or_default();
        let buffer = self.evidence.text.buffer();
        buffer.set_text("");
        let tag = buffer.tag_table().lookup("evidence").unwrap_or_else(|| {
            let tag = gtk::TextTag::builder()
                .name("evidence")
                .background("#f5cc61")
                .foreground("#241e00")
                .build();
            buffer.tag_table().add(&tag);
            tag
        });
        let context = preview["navigation"]["contextLines"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let append_context = |line: &Value| {
            let mut end = buffer.end_iter();
            buffer.insert(
                &mut end,
                &format!(
                    "Kontext · Zeile {}\n{}\n\n",
                    line["line"],
                    line["text"].as_str().unwrap_or("")
                ),
            );
        };
        let first = snippets
            .first()
            .and_then(|s| s["line"].as_u64())
            .unwrap_or(0);
        for line in &context {
            if line["line"].as_u64().unwrap_or(0) < first {
                append_context(line)
            }
        }
        for snippet in &snippets {
            let mut end = buffer.end_iter();
            let position = snippet["positionTitle"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| format!("Zeile {}", snippet["line"]));
            buffer.insert(
                &mut end,
                &format!(
                    "{} · {}\n",
                    snippet["label"].as_str().unwrap_or("Fundstelle"),
                    position
                ),
            );
            if snippet["documentPosition"]["confidence"].is_number() {
                let mut end = buffer.end_iter();
                buffer.insert(
                    &mut end,
                    &format!(
                        "OCR · Modellwert {} · ungefähre Region {}\n",
                        snippet["documentPosition"]["confidence"],
                        snippet["documentPosition"]["region"]
                    ),
                );
            }
            let base = buffer.end_iter().offset();
            let value = snippet["text"].as_str().unwrap_or("");
            let mut end = buffer.end_iter();
            buffer.insert(&mut end, value);
            let utf16_to_char = |offset: u64| {
                let mut units = 0;
                let mut chars = 0;
                for character in value.chars() {
                    if units >= offset {
                        break;
                    }
                    units += character.len_utf16() as u64;
                    chars += 1;
                }
                chars
            };
            if let (Some(location), Some(length)) =
                (snippet["location"].as_u64(), snippet["length"].as_u64())
            {
                buffer.apply_tag(
                    &tag,
                    &buffer.iter_at_offset(base + utf16_to_char(location)),
                    &buffer.iter_at_offset(base + utf16_to_char(location + length)),
                );
            }
            let mut end = buffer.end_iter();
            buffer.insert(&mut end, "\n\n");
        }
        let last = snippets
            .last()
            .and_then(|s| s["line"].as_u64())
            .unwrap_or(u64::MAX);
        for line in &context {
            if line["line"].as_u64().unwrap_or(0) > last {
                append_context(line)
            }
        }
        if preview["status"] != "ready" {
            buffer.set_text("Kein positiver Inhaltsbeleg für diesen Treffer.");
        }
    }
    pub(super) fn navigate_evidence(&self, delta: i32, context: bool) {
        if self.evidence_load.borrow().is_some() || (delta > 0 && self.evidence_at_end.get()) {
            return;
        }
        let selected = self.selected();
        let Some(hit) = selected.first() else { return };
        let occurrence = (self.evidence_occurrence.get() as i64 + i64::from(delta)).max(0) as u64;
        match self.model.call(json!({"operation":"loadPreview","raw":hit["raw"],"queryIndex":self.evidence.query.selected(),"occurrence":occurrence,"context":context})){
            Ok(value)=>{*self.evidence_load.borrow_mut()=value["loadID"].as_str().map(str::to_owned);self.status.set_text("Fundstelle wird geladen …");},Err(error)=>self.status.set_text(&error)
        }
    }
    pub(super) fn preview_event(&self, event: &Value) {
        if self.evidence_load.borrow().as_deref() != event["loadID"].as_str()
            || self.selected().first().map(|h| &h["id"]) != Some(&event["identity"])
        {
            return;
        }
        self.evidence_load.borrow_mut().take();
        if let Some(error) = event["error"].as_str() {
            self.status.set_text(error);
            return;
        }
        let preview = &event["preview"];
        let reason = preview["navigation"]["reason"].as_str().unwrap_or("");
        if preview["status"] == "ready" {
            self.evidence_occurrence
                .set(preview["navigation"]["occurrence"].as_u64().unwrap_or(0));
            self.render_evidence(preview);
        }
        self.evidence_at_end.set(reason == "end");
        self.status.set_text(&match reason {
            "ready" => format!(
                "Fundstelle {} · Quellstand geprüft",
                self.evidence_occurrence.get() + 1
            ),
            "end" => "Keine weitere Fundstelle.".into(),
            "readLimit" => {
                "Nachladegrenze erreicht · höchstens 64 MiB / drei Sekunden im Leser".into()
            }
            "documentUnavailable" => format!(
                "Dokument nicht nachladbar: {}",
                preview["navigation"]["documentMessage"]
                    .as_str()
                    .unwrap_or("Leser nicht verfügbar")
            ),
            other => format!("Nachladen: {other}"),
        });
    }
}
