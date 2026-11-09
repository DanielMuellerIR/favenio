use super::*;

impl Ui {
    pub(super) fn configuration(&self) -> Value {
        let mut value = json!({"pattern":self.query.text().to_string(),"roots":lines(&self.roots),"options":self.options()});
        if let Some((display, paths)) = self.root_identity.borrow().as_ref() {
            if text(&self.roots) == *display {
                use std::os::unix::ffi::OsStrExt;
                value["roots"] = json!(paths
                    .iter()
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect::<Vec<_>>());
                value["rootBytes"] = json!(paths
                    .iter()
                    .map(|p| base64::engine::general_purpose::STANDARD
                        .encode(p.as_os_str().as_bytes()))
                    .collect::<Vec<_>>());
            }
        }
        if let Some(proof) = self
            .retained_options
            .borrow()
            .iter()
            .find(|v| v["name"] == "__continuation")
        {
            value["continuation"] = proof["value"].clone();
        }
        value
    }
    pub(super) fn apply_configuration(&self, value: &Value) {
        self.suppress_quick.set(true);
        self.query.set_text(value["pattern"].as_str().unwrap_or(""));
        let replace_roots = value["roots"]
            .as_array()
            .is_some_and(|values| !values.is_empty());
        if replace_roots {
            self.root_confirmed.set(true);
            self.roots
                .buffer()
                .set_text(&strings(&value["roots"]).join("\n"));
        }
        let options = value["options"].as_array().cloned().unwrap_or_default();
        *self.retained_options.borrow_mut() = options.clone();
        if let Some(proof) = value.get("continuation") {
            self.retained_options
                .borrow_mut()
                .push(json!({"name":"__continuation","value":proof}));
        }
        let get = |name: &str| {
            options
                .iter()
                .find(|v| v["name"] == name)
                .and_then(|v| v["value"].as_str())
                .unwrap_or("")
        };
        self.mode.set_selected(
            ["name", "content", "metadata", "document"]
                .iter()
                .position(|s| *s == get("mode"))
                .unwrap_or(0) as u32,
        );
        self.only.set_selected(
            ["both", "files", "dirs"]
                .iter()
                .position(|s| *s == get("only"))
                .unwrap_or(0) as u32,
        );
        for (key, control) in &self.checks {
            control.set_active(get(key) == "1");
        }
        for (key, control) in &self.filters {
            control.set_text(get(key));
        }
        self.encoding.set_selected(
            self.encodings
                .iter()
                .position(|s| s == get("encoding"))
                .unwrap_or(0) as u32,
        );
        self.metadata_field.set_selected(
            self.metadata_fields
                .iter()
                .position(|field| field == get("field"))
                .map(|index| index as u32 + 1)
                .unwrap_or(0),
        );
        self.terms.buffer().set_text(
            &options
                .iter()
                .filter(|v| v["name"] == "term")
                .filter_map(|v| v["value"].as_str())
                .collect::<Vec<_>>()
                .join("\n"),
        );
        self.excludes.buffer().set_text(
            &options
                .iter()
                .filter(|v| v["name"] == "exclude")
                .filter_map(|v| v["value"].as_str())
                .collect::<Vec<_>>()
                .join("\n"),
        );
        let dates = serde_json::from_str::<Value>(get("date-ranges")).unwrap_or(Value::Null);
        for (field, value) in &self.date_values {
            *value.borrow_mut() = dates["ranges"].get(field).cloned();
        }
        *self.criteria.borrow_mut() = serde_json::from_str(get("criteria")).ok();
        self.criteria_enabled
            .set_active(self.criteria.borrow().is_some());
        if replace_roots {
            *self.root_identity.borrow_mut() = value["rootBytes"]
                .as_array()
                .and_then(|values| {
                    values
                        .iter()
                        .map(|v| {
                            base64::engine::general_purpose::STANDARD
                                .decode(v.as_str()?)
                                .ok()
                                .map(|b| PathBuf::from(std::ffi::OsString::from_vec(b)))
                        })
                        .collect::<Option<Vec<_>>>()
                })
                .map(|paths| (text(&self.roots), paths));
        }
        if self.filter_count() > 0 {
            self.filters_expander.set_expanded(true);
        }
        self.refresh_scope_caption();
        self.suppress_quick.set(false);
    }
    pub(super) fn install_recording(&self, value: &Value) {
        self.reset_transient_actions();
        self.apply_configuration(&value["configuration"]);
        *self.all_hits.borrow_mut() = value["hits"].as_array().cloned().unwrap_or_default();
        *self.run.borrow_mut() = value["runID"].as_str().map(str::to_owned);
        self.ended.set(true);
        *self.run_state.borrow_mut() = "recorded".into();
        self.warning_count
            .set(value["warningCount"].as_u64().unwrap_or(0));
        self.collapsed.borrow_mut().clear();
        self.selection.unselect_all();
        *self.initial_selection.borrow_mut() = value["selection"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|index| index.as_u64())
            .filter_map(|index| {
                self.all_hits
                    .borrow()
                    .get(index as usize)
                    .and_then(|h| h["id"].as_str().map(str::to_owned))
            })
            .collect();
        self.refresh_projection();
        self.status.set_text(&format!(
            "Aufgezeichneter Stand · {} · {} Warnungen · keine neue Suche ausgeführt",
            value["state"].as_str().unwrap_or(""),
            self.warning_count.get()
        ));
    }
    fn projection(&self, collapse_all: bool) -> Result<Value, String> {
        self.model.call(json!({"operation":"projection","runID":self.run.borrow().as_deref().unwrap_or(""),
            "mode":(["none","folder","fileExtension","archive"][self.grouping.selected()as usize]),
            "sort":(SORT_KEYS[self.sorting.selected()as usize]),
            "ascending":self.ascending.is_active(),"collapsed":self.collapsed.borrow().iter().collect::<Vec<_>>(),"collapseAll":collapse_all}))
    }
    pub(super) fn refresh_projection(&self) {
        let mut selected: std::collections::HashSet<_> = self
            .selected()
            .iter()
            .filter_map(|h| h["id"].as_str().map(str::to_owned))
            .collect();
        selected.extend(self.initial_selection.borrow().iter().cloned());
        let Ok(value) = self.projection(false) else {
            return;
        };
        self.result_count
            .set(value["visible"].as_u64().unwrap_or(0));
        self.result_generation.set(self.result_generation.get() + 1);
        let source = self.all_hits.borrow();
        let mut objects = Vec::new();
        for row in value["rows"].as_array().into_iter().flatten() {
            let item = if row["kind"] == "group" {
                let mut r = row.clone();
                r["name"] = json!(format!(
                    "{} {} ({})",
                    if self
                        .collapsed
                        .borrow()
                        .contains(row["key"].as_str().unwrap_or(""))
                    {
                        "▸"
                    } else {
                        "▾"
                    },
                    row["title"].as_str().unwrap_or(""),
                    row["count"]
                ));
                r
            } else {
                let Some(index) = row["index"].as_u64() else {
                    continue;
                };
                let Some(hit) = source.get(index as usize) else {
                    continue;
                };
                hit.clone()
            };
            objects.push(glib::BoxedAnyObject::new(item));
        }
        self.rebuilding.set(true);
        self.store.splice(0, self.store.n_items(), &objects);
        for (i, item) in objects.iter().enumerate() {
            if item.borrow::<Value>()["id"]
                .as_str()
                .is_some_and(|id| selected.contains(id))
            {
                self.selection.select_item(i as u32, false);
                if let Some(id) = item.borrow::<Value>()["id"].as_str() {
                    self.initial_selection.borrow_mut().remove(id);
                }
            }
        }
        self.rebuilding.set(false);
        self.update_preview();
    }
    pub(super) fn collapse_all(&self) {
        if let Ok(value) = self.projection(true) {
            for row in value["rows"].as_array().into_iter().flatten() {
                if let Some(key) = row["key"].as_str() {
                    self.collapsed.borrow_mut().insert(key.to_owned());
                }
            }
        }
        self.refresh_projection();
    }
    pub(super) fn activate_row(self: &Rc<Self>, position: u32) {
        let Some(item) = self
            .store
            .item(position)
            .and_downcast::<glib::BoxedAnyObject>()
        else {
            return;
        };
        let value = item.borrow::<Value>();
        if let Some(key) = value["key"].as_str() {
            let mut c = self.collapsed.borrow_mut();
            if !c.remove(key) {
                c.insert(key.to_owned());
            }
            drop(c);
            self.refresh_projection();
        } else {
            self.selection.select_item(position, true);
            self.act("open");
        }
    }
    pub(super) fn show_duplicates(&self, event: &Value) {
        let result = &event["result"];
        let indices = event["indices"].as_array().cloned().unwrap_or_default();
        let hits = self.all_hits.borrow();
        let mut output=format!("Zustand: {} · {} Dateien geprüft · {} Bytes gelesen\nDie Übereinstimmung wurde byteweise bestätigt. Hardlinks zählen nicht als zusätzlicher Speicher.\n\n",result["state"].as_str().unwrap_or(""),result["hashedFiles"],result["readBytes"]);
        for (group_number, group) in result["groups"]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            output.push_str(&format!(
                "Gruppe {} · {} Bytes · {} physische Dateien\n",
                group_number + 1,
                group["size"],
                group["physicalFiles"]
            ));
            for id in group["memberIDs"].as_array().into_iter().flatten() {
                if let Some(position) = id
                    .as_str()
                    .and_then(|s| s.parse::<usize>().ok())
                    .and_then(|n| indices.get(n))
                    .and_then(Value::as_u64)
                {
                    if let Some(hit) = hits.get(position as usize) {
                        output.push_str(hit["path"].as_str().unwrap_or(""));
                        output.push('\n');
                    }
                }
            }
            output.push('\n');
        }
        for issue in result["issues"].as_array().into_iter().flatten() {
            output.push_str(issue["message"].as_str().unwrap_or("Nicht geprüft"));
            output.push('\n');
        }
        self.text_window("Dublettenprüfung", &output);
    }
    pub(super) fn text_window(&self, title: &str, content: &str) {
        let window = gtk::Window::builder()
            .title(title)
            .transient_for(&self.window)
            .default_width(760)
            .default_height(550)
            .build();
        let view = gtk::TextView::builder()
            .editable(false)
            .monospace(true)
            .wrap_mode(gtk::WrapMode::WordChar)
            .build();
        view.buffer().set_text(content);
        window.set_child(Some(&gtk::ScrolledWindow::builder().child(&view).build()));
        window.present();
    }
}
