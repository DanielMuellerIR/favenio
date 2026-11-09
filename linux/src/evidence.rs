use super::*;
impl Ui {
    pub(super) fn update_preview(&self) {
        if !self.preview_enabled.is_active() {
            self.preview.buffer().set_text("");
            return;
        }
        let selected = self.selected();
        let Some(hit) = selected.first() else {
            self.preview.buffer().set_text("Treffer auswählen.");
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
            self.evidence_query.set_model(Some(&gtk::StringList::new(
                &labels.iter().map(String::as_str).collect::<Vec<_>>(),
            )));
            self.evidence_query.set_selected(0);
        }
        match self
            .model
            .call(json!({"operation":"previewStatus","raw":hit["raw"]}))
        {
            Ok(value) => self.render_evidence(&value["preview"]),
            Err(error) => self.preview.buffer().set_text(&error),
        }
    }
    pub(super) fn render_evidence(&self, preview: &Value) {
        let snippets = preview["snippets"].as_array().cloned().unwrap_or_default();
        let buffer = self.preview.buffer();
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
            buffer.insert(
                &mut end,
                &format!(
                    "{} · Zeile {}\n",
                    snippet["label"].as_str().unwrap_or("Fundstelle"),
                    snippet["line"]
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
        match self.model.call(json!({"operation":"loadPreview","raw":hit["raw"],"queryIndex":self.evidence_query.selected(),"occurrence":occurrence,"context":context})){
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
