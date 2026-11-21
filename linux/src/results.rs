use super::*;

pub(super) struct ResultView {
    pub store: gio::ListStore,
    pub selection: gtk::MultiSelection,
    pub table: gtk::ColumnView,
    pub table_factories: Vec<gtk::SignalListItemFactory>,
    pub grid: gtk::GridView,
    pub grid_factory: gtk::SignalListItemFactory,
    pub stack: gtk::Stack,
    pub grouping: gtk::DropDown,
    pub sorting: gtk::DropDown,
    pub ascending: gtk::CheckButton,
    pub group_controls: gtk::Box,
    pub collapse: gtk::Button,
    pub expand: gtk::Button,
    pub view_mode: gtk::DropDown,
}

impl ResultView {
    pub fn new(quick: bool) -> Self {
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
            "Eingangsreihenfolge",
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
        Self {
            store,
            selection,
            table,
            table_factories,
            grid,
            grid_factory,
            stack: result_stack,
            grouping,
            sorting,
            ascending,
            group_controls,
            collapse,
            expand,
            view_mode,
        }
    }
}

pub(super) fn connect_controls(ui: &Rc<Ui>) {
    if let Some(sorter) = ui
        .results
        .table
        .sorter()
        .and_downcast::<gtk::ColumnViewSorter>()
    {
        let weak = Rc::downgrade(ui);
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
            ui.results.sorting.set_selected(index);
            ui.results
                .ascending
                .set_active(sorter.primary_sort_order() == gtk::SortType::Ascending);
            ui.refresh_projection();
        });
    }
    let weak = Rc::downgrade(ui);
    ui.results.grouping.connect_selected_notify(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(ui);
    ui.results.sorting.connect_selected_notify(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.results
                .ascending
                .set_sensitive(ui.sort_key() != "arrival");
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(ui);
    ui.results.ascending.connect_toggled(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(ui);
    ui.results.collapse.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.collapse_all();
        }
    });
    let weak = Rc::downgrade(ui);
    ui.results.expand.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            ui.collapsed.borrow_mut().clear();
            ui.refresh_projection();
        }
    });
    let weak = Rc::downgrade(ui);
    ui.results.view_mode.connect_selected_notify(move |v| {
        if let Some(ui) = weak.upgrade() {
            ui.results
                .stack
                .set_visible_child_name(if v.selected() == 1 { "grid" } else { "list" });
        }
    });
    let weak = Rc::downgrade(ui);
    ui.results.grid.connect_activate(move |_, position| {
        if let Some(ui) = weak.upgrade() {
            ui.activate_row(position);
        }
    });
}

impl Ui {
    pub(super) fn configuration(&self) -> Configuration {
        let mut configuration = Configuration {
            pattern: self.query.text().to_string(),
            roots: lines(&self.roots),
            options: self.options(),
            root_bytes: None,
            continuation: self
                .retained_options
                .borrow()
                .iter()
                .find(|option| option["name"] == "__continuation")
                .map(|proof| proof["value"].clone()),
        };
        if let Some((display, paths)) = self.root_identity.borrow().as_ref() {
            if text(&self.roots) == *display {
                use std::os::unix::ffi::OsStrExt;
                configuration.roots = paths
                    .iter()
                    .map(|path| path.to_string_lossy().into_owned())
                    .collect();
                configuration.root_bytes = Some(
                    paths
                        .iter()
                        .map(|path| {
                            base64::engine::general_purpose::STANDARD
                                .encode(path.as_os_str().as_bytes())
                        })
                        .collect(),
                );
            }
        }
        configuration
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
            SEARCH_MODES
                .iter()
                .position(|s| *s == get("mode"))
                .unwrap_or(0) as u32,
        );
        self.only.set_selected(
            SEARCH_SCOPES
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
        self.results.selection.unselect_all();
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
    fn projection(&self, collapse_all: bool) -> Result<model_search::Projection, String> {
        let mode = ["none", "folder", "fileExtension", "archive"]
            .get(self.results.grouping.selected() as usize)
            .copied()
            .unwrap_or("none");
        self.model.projection(
            self.result_order(&self.run.borrow()),
            mode,
            self.collapsed.borrow().iter().map(String::as_str).collect(),
            collapse_all,
        )
    }
    pub(super) fn refresh_streaming_results(&self) {
        if !self.arrival_prefix.get()
            || self.results.grouping.selected() != 0
            || self.sort_key() != "arrival"
            || !self.initial_selection.borrow().is_empty()
        {
            self.refresh_projection();
            return;
        }
        let source = self.all_hits.borrow();
        let start = self.results.store.n_items();
        let incoming = &source[start as usize..];
        if incoming.is_empty() {
            return;
        }
        let rows: Vec<_> = incoming
            .iter()
            .cloned()
            .map(glib::BoxedAnyObject::new)
            .collect();
        self.result_count.set(source.len() as u64);
        self.result_generation.set(self.result_generation.get() + 1);
        // Die bisherigen GTK-Objekte bleiben stehen und behalten ihre Auswahl.
        self.results.store.splice(start, 0, &rows);
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
        self.arrival_prefix.set(value.arrival_prefix);
        self.result_count.set(value.visible);
        self.result_generation.set(self.result_generation.get() + 1);
        let source = self.all_hits.borrow();
        let mut objects = Vec::new();
        for row in value.rows {
            let item = match row {
                model_search::ProjectionRow::Group { key, title, count } => {
                    let arrow = if self.collapsed.borrow().contains(&key) {
                        "▸"
                    } else {
                        "▾"
                    };
                    let name = format!("{arrow} {title} ({count})");
                    json!({"kind":"group", "key":key, "title":title, "count":count, "name":name})
                }
                model_search::ProjectionRow::Hit { index } => {
                    let Some(hit) = source.get(index) else {
                        continue;
                    };
                    hit.clone()
                }
            };
            objects.push(glib::BoxedAnyObject::new(item));
        }
        self.rebuilding.set(true);
        self.results
            .store
            .splice(0, self.results.store.n_items(), &objects);
        for (i, item) in objects.iter().enumerate() {
            if item.borrow::<Value>()["id"]
                .as_str()
                .is_some_and(|id| selected.contains(id))
            {
                self.results.selection.select_item(i as u32, false);
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
            let mut collapsed = self.collapsed.borrow_mut();
            for row in value.rows {
                if let model_search::ProjectionRow::Group { key, .. } = row {
                    collapsed.insert(key);
                }
            }
        }
        self.refresh_projection();
    }
    pub(super) fn activate_row(self: &Rc<Self>, position: u32) {
        let Some(item) = self
            .results
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
            self.results.selection.select_item(position, true);
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
