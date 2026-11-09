use super::*;
use std::os::unix::ffi::OsStrExt;

pub(super) type NativeRoots = Rc<RefCell<Option<(String, Vec<PathBuf>)>>>;
pub(super) fn paths(editor: &gtk::TextView, native: &NativeRoots) -> Vec<PathBuf> {
    native
        .borrow()
        .as_ref()
        .filter(|(display, _)| *display == text(editor))
        .map(|(_, paths)| paths.clone())
        .unwrap_or_else(|| lines(editor).into_iter().map(PathBuf::from).collect())
}
pub(super) fn append(editor: &gtk::TextView, native: &NativeRoots, incoming: Vec<PathBuf>) {
    let mut paths = paths(editor, native);
    for path in incoming {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    let display = paths
        .iter()
        .map(|path| path.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("\n");
    editor.buffer().set_text(&display);
    *native.borrow_mut() = Some((display, paths));
}
pub(super) fn valid(paths: &[PathBuf]) -> bool {
    !paths.is_empty()
        && paths.len() <= 16
        && paths.iter().all(|path| {
            path.is_absolute()
                && path.as_os_str().as_bytes().len() <= 4096
                && !path.as_os_str().as_bytes().contains(&0)
        })
        && paths.iter().collect::<std::collections::HashSet<_>>().len() == paths.len()
}
pub(super) fn populate(body: &gtk::Box, editor: &gtk::TextView, native: &NativeRoots) {
    let rows = column();
    let state = label("Ordnerliste wird abgefragt …");
    state.set_wrap(true);
    rows.append(&state);
    let expander = gtk::Expander::builder()
        .label("Offene Ordner im Dateimanager")
        .child(
            &gtk::ScrolledWindow::builder()
                .child(&rows)
                .max_content_height(120)
                .propagate_natural_height(true)
                .build(),
        )
        .build();
    body.append(&expander);
    let weak = rows.downgrade();
    let editor = editor.clone();
    let native = native.clone();
    gio::bus_get(
        gio::BusType::Session,
        None::<&gio::Cancellable>,
        move |result| {
            let Ok(bus) = result else {
                state.set_text(
                    "Keine Dateimanager-Verbindung. Bereiche über die Dateiauswahl hinzufügen.",
                );
                return;
            };
            glib::MainContext::default().spawn_local(async move {
                let locations = collect_locations(&bus).await;
                let Some(rows) = weak.upgrade() else { return; };
                let Some(locations) = locations else {
                    state.set_text("Der Dateimanager liefert keine unterstützte Liste offener Ordner. Bereiche über die Dateiauswahl hinzufügen."); return;
                };
                let mut seen = std::collections::HashSet::new();
                for uri in locations {
                    if !(uri.starts_with("file:///") || uri.starts_with("file://localhost/")) || uri.to_ascii_lowercase().contains("%00") { continue; }
                    let Some(path) = gio::File::for_uri(&uri).path().filter(|path| path.is_absolute()) else { continue; };
                    if !seen.insert(path.clone()) { continue; }
                    let button = gtk::Button::with_label(&path.to_string_lossy());
                    if let Some(label) = button.child().and_downcast::<gtk::Label>() { label.set_xalign(0.0); label.set_ellipsize(gtk::pango::EllipsizeMode::Middle); }
                    let editor = editor.clone(); let native = native.clone();
                    button.connect_clicked(move |_| append(&editor, &native, vec![path.clone()]));
                    rows.append(&button);
                }
                state.set_text(if seen.is_empty() { "Keine lokalen offenen Ordner gemeldet." } else { "Anklicken fügt einen Ordner zur Bereichsliste hinzu." });
            });
        },
    );
}

async fn collect_locations(bus: &gio::DBusConnection) -> Option<Vec<String>> {
    let names = bus
        .call_future(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            None,
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            1000,
        )
        .await
        .ok()
        .and_then(|reply| reply.try_child_value(0))
        .and_then(|value| value.get::<Vec<String>>())
        .unwrap_or_default();
    let providers: Vec<_> = names
        .into_iter()
        .filter(|name| {
            name.strip_prefix("org.favenio.NemoLocations1.p")
                .is_some_and(|pid| pid.parse::<u32>().is_ok())
        })
        .take(16)
        .collect();
    let mut locations = Vec::new();
    let mut available = false;
    for provider in providers {
        if let Some(values) = read_locations(
            bus,
            &provider,
            "/org/favenio/NemoLocations1",
            "org.favenio.NemoLocations1",
        )
        .await
        {
            available = true;
            locations.extend(values);
        }
    }
    if !available {
        locations = read_locations(
            bus,
            "org.freedesktop.FileManager1",
            "/org/freedesktop/FileManager1",
            "org.freedesktop.FileManager1",
        )
        .await?;
    }
    locations.sort();
    locations.dedup();
    (locations.len() <= 128 && locations.iter().map(String::len).sum::<usize>() <= 65536)
        .then_some(locations)
}

async fn read_locations(
    bus: &gio::DBusConnection,
    provider: &str,
    path: &str,
    interface: &str,
) -> Option<Vec<String>> {
    let parameters = (interface, "OpenLocations").to_variant();
    let reply = bus
        .call_future(
            Some(provider),
            path,
            "org.freedesktop.DBus.Properties",
            "Get",
            Some(&parameters),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            500,
        )
        .await
        .ok()?;
    let locations = reply
        .try_child_value(0)?
        .as_variant()?
        .get::<Vec<String>>()?;
    (locations.len() <= 128 && locations.iter().map(String::len).sum::<usize>() <= 65536)
        .then_some(locations)
}
