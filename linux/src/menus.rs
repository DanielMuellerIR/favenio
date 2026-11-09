use super::*;

impl Ui {
    pub(super) fn install_result_menu(self: &Rc<Self>, factory: &gtk::SignalListItemFactory) {
        let weak = Rc::downgrade(self);
        factory.connect_setup(move |_, object| {
            let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(child) = item.child() else {
                return;
            };
            let gesture = gtk::GestureClick::new();
            gesture.set_button(3);
            let weak = weak.clone();
            let item = item.downgrade();
            gesture.connect_pressed(move |gesture, _, x, y| {
                let (Some(ui), Some(item)) = (weak.upgrade(), item.upgrade()) else {
                    return;
                };
                let position = item.position();
                let Some(value) = item.item().and_downcast::<glib::BoxedAnyObject>() else {
                    return;
                };
                if value.borrow::<Value>()["kind"] == "group" {
                    return;
                }
                if !ui.selection.is_selected(position) {
                    ui.selection.select_item(position, true);
                }
                if let Some(child) = item.child() {
                    ui.result_menu(&child, x, y);
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                }
            });
            child.add_controller(gesture);
        });
    }
    fn result_menu(self: &Rc<Self>, widget: &gtk::Widget, x: f64, y: f64) {
        let popup = gtk::Popover::builder()
            .autohide(true)
            .has_arrow(false)
            .build();
        popup.set_parent(widget);
        popup.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        let body = column();
        body.set_spacing(2);
        for (action, title) in [
            ("open", "Öffnen"),
            ("open-with", "Öffnen mit …"),
            ("preview", "Vorschau"),
            ("reveal", "Im Dateimanager zeigen"),
            ("reveal-source", "Äußere Quelldatei zeigen"),
            ("copy", "Pfad kopieren"),
            ("remove", "Aus Trefferliste entfernen"),
            ("trash", "In den Papierkorb …"),
        ] {
            let button = gtk::Button::with_label(title);
            button.add_css_class("flat");
            if let Some(label) = button.child().and_downcast::<gtk::Label>() {
                label.set_xalign(0.0);
            }
            let weak = Rc::downgrade(self);
            let popup = popup.clone();
            button.connect_clicked(move |_| {
                popup.popdown();
                if let Some(ui) = weak.upgrade() {
                    if action == "trash" {
                        ui.trash();
                    } else {
                        ui.act(action);
                    }
                }
            });
            body.append(&button);
        }
        popup.set_child(Some(&body));
        popup.connect_closed(|popup| popup.unparent());
        popup.popup();
    }
}
