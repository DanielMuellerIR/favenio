use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
struct Node {
    widget: gtk::Box,
    value: Rc<dyn Fn() -> Value>,
}
fn new_id() -> String {
    format!(
        "linux_{}_{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    )
}
fn choice(values: &[String], selected: &str) -> gtk::DropDown {
    let references: Vec<_> = values.iter().map(String::as_str).collect();
    let control = gtk::DropDown::from_strings(&references);
    if let Some(i) = values.iter().position(|v| v == selected) {
        control.set_selected(i as u32);
    }
    control
}
fn node(value: Value, catalog: &Value, depth: usize) -> Node {
    let container = column();
    container.add_css_class("criteria-node");
    let id = value["id"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(new_id);
    if value.get("children").is_some() {
        let head = row();
        let op = gtk::DropDown::from_strings(&[
            "Alle Bedingungen (UND)",
            "Mindestens eine Bedingung (ODER)",
        ]);
        op.set_selected(if value["op"] == "or" { 1 } else { 0 });
        head.append(&op);
        container.append(&head);
        let children_box = column();
        children_box.set_margin_start(20);
        container.append(&children_box);
        let children: Rc<RefCell<Vec<Node>>> = Rc::new(RefCell::new(Vec::new()));
        for child in value["children"].as_array().into_iter().flatten() {
            append_child(
                &children_box,
                &children,
                node(child.clone(), catalog, depth + 1),
            );
        }
        let add = gtk::Button::with_label("+ Bedingung");
        let group = gtk::Button::with_label("+ Gruppe");
        head.append(&add);
        head.append(&group);
        group.set_sensitive(depth < 15);
        let c = children.clone();
        let box_ = children_box.clone();
        let cat = catalog.clone();
        add.connect_clicked(move |_| {
            append_child(
                &box_,
                &c,
                node(
                    json!({"field":"name","operator":"contains","value":""}),
                    &cat,
                    depth + 1,
                ),
            )
        });
        let c = children.clone();
        let box_ = children_box;
        let cat = catalog.clone();
        group.connect_clicked(move |_| {
            append_child(
                &box_,
                &c,
                node(json!({"op":"and","children":[]}), &cat, depth + 1),
            )
        });
        Node {
            widget: container,
            value: Rc::new(
                move || json!({"id":id,"op":if op.selected()==1{"or"}else{"and"},"children":children.borrow().iter().map(|n|(n.value)()).collect::<Vec<_>>()}),
            ),
        }
    } else {
        let controls = row();
        let fields = strings(&catalog["fields"]);
        let names: Vec<String> = fields
            .iter()
            .map(|f| catalog["labels"][f].as_str().unwrap_or(f).to_owned())
            .collect();
        let field = choice(&names, "");
        let selected = value["field"].as_str().unwrap_or("name");
        field.set_selected(fields.iter().position(|f| f == selected).unwrap_or(0) as u32);
        let operators = strings(&catalog["operators"][selected]);
        let titles = operators
            .iter()
            .map(|key| {
                catalog["operatorTitles"][selected][key]
                    .as_str()
                    .unwrap_or(key)
                    .to_owned()
            })
            .collect::<Vec<_>>();
        let operator = choice(&titles, "");
        operator.set_selected(
            operators
                .iter()
                .position(|key| Some(key.as_str()) == value["operator"].as_str())
                .unwrap_or(0) as u32,
        );
        let entry = gtk::Entry::builder()
            .hexpand(true)
            .placeholder_text("Wert")
            .build();
        entry.set_text(value["value"].as_str().unwrap_or(""));
        let negate = gtk::CheckButton::with_label("Nicht");
        negate.set_active(value["negate"] == true);
        let case = gtk::CheckButton::with_label("Groß/klein");
        case.set_active(value["caseSensitive"] == true);
        case.set_sensitive(!["size", "modified", "created", "width", "height"].contains(&selected));
        controls.append(&negate);
        controls.append(&field);
        controls.append(&operator);
        controls.append(&entry);
        controls.append(&case);
        container.append(&controls);
        let mut metadata_fields = vec![String::new()];
        metadata_fields.extend(strings(&catalog["metadataFields"]));
        let metadata_titles: Vec<_> = metadata_fields.iter().map(|field| {
            if field.is_empty() { "Alle Textfelder" } else { field.as_str() }
        }).collect();
        let metadata = gtk::DropDown::from_strings(&metadata_titles);
        metadata.set_visible(selected == "metadata");
        if let Some(i) = metadata_fields
            .iter()
            .position(|f| Some(f.as_str()) == value["metadataField"].as_str())
        {
            metadata.set_selected(i as u32);
        }
        container.append(&metadata);
        let cat = catalog.clone();
        let field_names = fields.clone();
        let o = operator.clone();
        let m = metadata.clone();
        let e = entry.clone();
        let case_control = case.clone();
        field.connect_selected_notify(move |f| {
            let name = &field_names[f.selected() as usize];
            let operators = strings(&cat["operators"][name])
                .iter()
                .map(|key| {
                    cat["operatorTitles"][name][key]
                        .as_str()
                        .unwrap_or(key)
                        .to_owned()
                })
                .collect::<Vec<_>>();
            let numeric =
                ["size", "modified", "created", "width", "height"].contains(&name.as_str());
            case_control.set_sensitive(!numeric);
            if numeric {
                case_control.set_active(false);
            }
            o.set_model(Some(&gtk::StringList::new(
                &operators.iter().map(String::as_str).collect::<Vec<_>>(),
            )));
            o.set_selected(0);
            m.set_visible(name == "metadata");
            e.set_placeholder_text(Some(if ["modified", "created"].contains(&name.as_str()) {
                "ISO-Zeitpunkt mit Z/Offset oder Kalenderbereich"
            } else {
                "Wert"
            }));
        });
        let date_value = Rc::new(RefCell::new(if value["value"].is_object() {
            Some(value["value"].clone())
        } else {
            None
        }));
        if value["value"].is_object() {
            entry.set_text(&value["value"].to_string());
        }
        let date_button = gtk::Button::with_label("Kalenderbereich …");
        date_button.set_visible(["modified", "created"].contains(&selected));
        let date_control = date_button.clone();
        let date_fields = fields.clone();
        field.connect_selected_notify(move |field| {
            date_control.set_visible(
                ["modified", "created"].contains(&date_fields[field.selected() as usize].as_str()),
            )
        });
        container.append(&date_button);
        let changed_date = date_value.clone();
        entry.connect_changed(move |_| {
            *changed_date.borrow_mut() = None;
        });
        let date = date_value.clone();
        let f = field.clone();
        let field_names = fields.clone();
        let e = entry.clone();
        date_button.connect_clicked(move |_| {
            if ["modified", "created"].contains(&field_names[f.selected() as usize].as_str()) {
                date_dialog(&date, &e);
            }
        });
        let catalog = catalog.clone();
        Node {
            widget: container,
            value: Rc::new(move || {
                let f = &fields[field.selected() as usize];
                let op = strings(&catalog["operators"][f])
                    .get(operator.selected() as usize)
                    .cloned()
                    .unwrap_or_default();
                let mut result =
                    json!({"id":id,"field":f,"operator":op,"value":entry.text().to_string()});
                if ["modified", "created"].contains(&f.as_str()) {
                    if let Some(date) = date_value.borrow().as_ref() {
                        result["value"] = date.clone();
                    }
                }
                if negate.is_active() {
                    result["negate"] = json!(true);
                }
                if case.is_active() {
                    result["caseSensitive"] = json!(true);
                }
                if f == "metadata" {
                    if let Some(v) = metadata_fields.get(metadata.selected() as usize).filter(|v| !v.is_empty()) {
                        result["metadataField"] = json!(v);
                    }
                }
                result
            }),
        }
    }
}
fn append_child(container: &gtk::Box, children: &Rc<RefCell<Vec<Node>>>, child: Node) {
    let line = row();
    let remove = gtk::Button::with_label("−");
    line.append(&child.widget);
    child.widget.set_hexpand(true);
    line.append(&remove);
    container.append(&line);
    let widget = child.widget.clone();
    let c = children.clone();
    let parent = container.clone();
    let l = line.clone();
    remove.connect_clicked(move |_| {
        c.borrow_mut().retain(|n| n.widget != widget);
        parent.remove(&l);
    });
    children.borrow_mut().push(child);
}
fn resolve_date_query(question: Value, reference: String) -> Result<Value, String> {
    use std::io::Read;
    use std::process::Stdio;
    let query = question.to_string();
    if query.len() > 4096 {
        return Err("Datumsangabe ist zu groß.".into());
    }
    let engine = std::env::current_exe()
        .map_err(|e| e.to_string())?
        .parent()
        .unwrap()
        .join("favenio.py");
    let mut child = std::process::Command::new("/usr/bin/python3")
        .arg("-B")
        .arg(engine)
        .arg(format!("--resolve-date-range={query}"))
        .arg(format!("--date-reference-time={reference}"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let output = child.stdout.take().unwrap();
    let errors = child.stderr.take().unwrap();
    let read = |stream: Box<dyn Read + Send>| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stream.take(65537).read_to_end(&mut bytes).map(|_| bytes)
        })
    };
    let output = read(Box::new(output));
    let errors = read(Box::new(errors));
    let start = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if start.elapsed() < Duration::from_secs(8) => {
                std::thread::sleep(Duration::from_millis(40))
            }
            result => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(result
                    .err()
                    .map(|e| e.to_string())
                    .unwrap_or_else(|| "Zeitgrenze der Datumsprüfung erreicht.".into()));
            }
        }
    };
    let output = output
        .join()
        .map_err(|_| "Datumsantwort abgebrochen")?
        .map_err(|e| e.to_string())?;
    let errors = errors
        .join()
        .map_err(|_| "Datumsdiagnose abgebrochen")?
        .map_err(|e| e.to_string())?;
    if output.len() > 65536 || errors.len() > 65536 {
        return Err("Datumsantwort zu groß.".into());
    }
    if !status.success() {
        return Err(String::from_utf8_lossy(&errors).into_owned());
    }
    serde_json::from_slice(&output).map_err(|e| e.to_string())
}
pub(super) fn date_dialog(value: &Rc<RefCell<Option<Value>>>, entry: &gtk::Entry) {
    let window = gtk::Window::builder()
        .title("Kalenderbereich")
        .default_width(500)
        .build();
    if let Some(parent) = entry.root().and_downcast::<gtk::Window>() {
        window.set_transient_for(Some(&parent));
        window.set_modal(true);
    }
    let body = column();
    body.set_margin_top(12);
    body.set_margin_bottom(12);
    body.set_margin_start(12);
    body.set_margin_end(12);
    let preset = gtk::DropDown::from_strings(&[
        "Heute",
        "Letzte sieben Kalendertage",
        "Dieser Monat",
        "Fester Kalenderbereich",
    ]);
    body.append(&preset);
    let calendars = row();
    let lower = gtk::Calendar::new();
    let upper = gtk::Calendar::new();
    calendars.append(&lower);
    calendars.append(&upper);
    body.append(&calendars);
    let lower_time = gtk::Entry::builder()
        .text("00:00:00")
        .placeholder_text("Uhrzeit ab")
        .build();
    let upper_time = gtk::Entry::builder()
        .text("23:59:59")
        .placeholder_text("Uhrzeit bis")
        .build();
    let times = row();
    times.append(&lower_time);
    times.append(&upper_time);
    body.append(&times);
    let from_fold =
        gtk::DropDown::from_strings(&["Doppelte Zeit: nachfragen", "Frühere Zeit", "Spätere Zeit"]);
    let to_fold =
        gtk::DropDown::from_strings(&["Doppelte Zeit: nachfragen", "Frühere Zeit", "Spätere Zeit"]);
    let folds = row();
    folds.append(&from_fold);
    folds.append(&to_fold);
    body.append(&folds);
    let zone = gtk::Entry::builder()
        .text(glib::TimeZone::local().identifier())
        .placeholder_text("IANA-Zeitzone")
        .build();
    body.append(&zone);
    let freeze = gtk::CheckButton::with_label("Aufgelöste Grenzen als festen Zeitraum übernehmen");
    body.append(&freeze);
    if let Some(initial) = value.borrow().as_ref() {
        if let Some(name) = initial["timeZone"].as_str() {
            zone.set_text(name);
        }
        if initial["kind"] == "relative" {
            preset.set_selected(
                ["today", "last7CalendarDays", "thisMonth"]
                    .iter()
                    .position(|name| initial["preset"] == *name)
                    .unwrap_or(0) as u32,
            );
        } else {
            preset.set_selected(3);
            {
                let time_zone = glib::TimeZone::new(Some(&zone.text()));
                for (key, calendar, entry) in [
                    ("lower", &lower, &lower_time),
                    ("upper", &upper, &upper_time),
                ] {
                    if let Some(date) = initial[key]
                        .as_str()
                        .and_then(|text| glib::DateTime::from_iso8601(text, None).ok())
                        .and_then(|date| date.to_timezone(&time_zone).ok())
                    {
                        calendar.select_day(&date);
                        if let Ok(time) = date.format("%H:%M:%S") {
                            entry.set_text(&time);
                        }
                    }
                }
            }
        }
    }
    let issue = label("");
    issue.set_wrap(true);
    body.append(&issue);
    let save = gtk::Button::with_label("Prüfen und übernehmen");
    body.append(&save);
    let v = value.clone();
    let e = entry.clone();
    let w = window.clone();
    save.connect_clicked(move |button| {
        let zone = zone.text().to_string();
        let selected = preset.selected();
        let fixed = selected == 3 || freeze.is_active();
        let mut question = if selected < 3 {
            json!({"kind":"relative", "timeZone":zone, "preset":(["today","last7CalendarDays","thisMonth"][selected as usize])})
        } else {
            json!({"kind":"calendar", "timeZone":zone,
                "fromLocal":format!("{}T{}",lower.date().format("%Y-%m-%d").unwrap(),lower_time.text()),
                "toLocal":format!("{}T{}",upper.date().format("%Y-%m-%d").unwrap(),upper_time.text())})
        };
        if selected == 3 {
            if from_fold.selected() > 0 { question["fromFold"] = json!(from_fold.selected()-1); }
            if to_fold.selected() > 0 { question["toFold"] = json!(to_fold.selected()-1); }
        }
        let reference = glib::DateTime::now_utc().unwrap().format("%Y-%m-%dT%H:%M:%SZ").unwrap().to_string();
        let (sender, receiver) = std::sync::mpsc::channel();
        let query = question.clone();
        button.set_sensitive(false);
        issue.set_text("Kalendergrenzen werden im Suchkern geprüft …");
        std::thread::spawn(move || { let _ = sender.send(resolve_date_query(query, reference)); });
        let value = v.clone(); let entry = e.clone(); let window = w.clone();
        let button = button.clone(); let issue = issue.clone();
        glib::timeout_add_local(Duration::from_millis(40), move || {
            if !window.is_visible() { return glib::ControlFlow::Break; }
            match receiver.try_recv() {
                Ok(Ok(answer)) => {
                    let proof = &answer["value"]["entries"][0];
                    let spec = if fixed { json!({"kind":"fixed", "timeZone":zone, "lower":proof["lowerISO"], "upper":proof["upperISO"]}) } else { question.clone() };
                    entry.set_text(&format!("{} bis {}",proof["lowerISO"].as_str().unwrap_or(""),proof["upperISO"].as_str().unwrap_or("")));
                    *value.borrow_mut() = Some(spec);
                    window.close();
                    glib::ControlFlow::Break
                },
                Ok(Err(error)) => { issue.set_text(&error); button.set_sensitive(true); glib::ControlFlow::Break },
                Err(std::sync::mpsc::TryRecvError::Disconnected) => { issue.set_text("Datumsprüfung abgebrochen."); button.set_sensitive(true); glib::ControlFlow::Break },
                Err(_) => glib::ControlFlow::Continue,
            }
        });
    });
    window.set_child(Some(&body));
    window.present();
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_field_roundtrip() {
        gtk::init().expect("GTK-Test benötigt eine private Anzeige (z. B. Xvfb)");
        let catalog = json!({"fields":["metadata"], "labels":{"metadata":"Metadaten"},
            "operators":{"metadata":["contains"]},
            "operatorTitles":{"metadata":{"contains":"enthält"}},
            "metadataFields":["Title","Comment"]});
        for explicit in [None, Some("Title"), Some("Comment")] {
            let mut input = json!({"id":"meta","field":"metadata","operator":"contains","value":"needle"});
            if let Some(field) = explicit { input["metadataField"] = json!(field); }
            let tree = node(input.clone(), &catalog, 0);
            assert_eq!((tree.value)(), input);
            let menu = tree.widget.first_child().unwrap().next_sibling().unwrap()
                .downcast::<gtk::DropDown>().unwrap();
            assert_eq!(menu.model().unwrap().n_items(), 3);
            menu.set_selected(2);
            assert_eq!((tree.value)()["metadataField"], "Comment");
            menu.set_selected(0);
            assert!((tree.value)().get("metadataField").is_none());
        }
    }
}

pub(super) fn open(ui: &Rc<Ui>) {
    edit(ui, false)
}
pub(super) fn open_filter(ui: &Rc<Ui>) {
    edit(ui, true)
}
fn edit(ui: &Rc<Ui>, filter: bool) {
    let Ok(catalog) = ui.model.call(json!({"operation":"catalog"})) else {
        return;
    };
    let initial = ui
        .criteria
        .borrow()
        .as_ref()
        .map(|v| v["root"].clone())
        .unwrap_or_else(|| json!({"op":"and","children":[]}));
    let tree = node(initial, &catalog, 0);
    let dialog = gtk::Window::builder()
        .title("Zusätzliche Kriterien")
        .modal(true)
        .transient_for(&ui.window)
        .default_width(900)
        .default_height(550)
        .build();
    let body = column();
    body.set_margin_top(12);
    body.set_margin_bottom(12);
    body.set_margin_start(12);
    body.set_margin_end(12);
    body.append(
        &gtk::ScrolledWindow::builder()
            .vexpand(true)
            .child(&tree.widget)
            .build(),
    );
    let issue = label("");
    issue.set_wrap(true);
    body.append(&issue);
    let apply = gtk::Button::with_label("Übernehmen");
    body.append(&apply);
    let weak = Rc::downgrade(ui);
    let d = dialog.clone();
    apply.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            match ui
                .model
                .call(json!({"operation":"criteria","root":(tree.value)()}))
            {
                Ok(value) => {
                    if filter {
                        match ui.model.call(
                            json!({"operation":"filter","criteria":value["criteria"].to_string()}),
                        ) {
                            Ok(_) => {
                                ui.status.set_text("Ansichtsfilter wird geprüft …");
                                d.close();
                            }
                            Err(e) => issue.set_text(&e),
                        }
                    } else {
                        *ui.criteria.borrow_mut() = value.get("criteria").cloned();
                        ui.criteria_enabled.set_active(true);
                        ui.quick_changed();
                        d.close();
                    }
                }
                Err(e) => issue.set_text(&e),
            }
        }
    });
    dialog.set_child(Some(&body));
    dialog.present();
}
