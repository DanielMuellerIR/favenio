"""Nemo-Adapter: Der Ordner stammt aus der Ansicht, niemals aus der Auswahl."""
import os
from pathlib import Path
import subprocess
import urllib.parse
import gi

gi.require_version('Nemo', '3.0')
gi.require_version('Gtk', '3.0')
from gi.repository import GObject, Nemo, Gtk, Gio, GLib


class OpenLocations:
    def __init__(self):
        self.views = {}
        self.owner = None
        self.connection = None
        self.registration = None

    def track(self, widget, uri):
        identity = id(widget)
        self.views[identity] = uri
        widget.connect('destroy', lambda *_: self.views.pop(identity, None))
        if self.owner is None:
            self.owner = Gio.bus_own_name(Gio.BusType.SESSION,
                                         'org.favenio.NemoLocations1.p' + str(os.getpid()),
                                         Gio.BusNameOwnerFlags.NONE, self._connected, None, None)

    def _connected(self, connection, name):
        self.connection = connection
        interface = Gio.DBusNodeInfo.new_for_xml('''<node><interface name="org.favenio.NemoLocations1">
            <property name="OpenLocations" type="as" access="read"/>
            </interface></node>''').interfaces[0]
        self.registration = connection.register_object('/org/favenio/NemoLocations1', interface,
                                                      None, self._property, None)

    def _property(self, connection, sender, path, interface, name):
        values = list(dict.fromkeys(self.views.values()))[:128]
        if sum(len(value.encode('utf-8')) for value in values) > 65536:
            values = []
        return GLib.Variant('as', values)


open_locations = OpenLocations()


class FavenioQuickLocation(GObject.GObject, Nemo.LocationWidgetProvider):
    def get_widget(self, uri, window):
        location = Gio.File.new_for_uri(uri)
        if not location.is_native():
            return None
        parsed = urllib.parse.urlsplit(uri)
        if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
            return None
        raw = urllib.parse.unquote_to_bytes(parsed.path)
        if not raw.startswith(b'/') or b'\0' in raw:
            return None
        path = os.fsdecode(raw)
        launcher = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'favenio' / 'bin' / 'favenio-quick'
        if not launcher.is_file():
            return None
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        box.set_margin_start(8)
        box.set_margin_end(8)
        box.set_margin_top(4)
        box.set_margin_bottom(4)
        button = Gtk.Button.new_with_label('Mit FavenioQuick hier suchen')
        button.set_tooltip_text(raw.decode('utf-8', 'replace'))
        button.connect('clicked', self._open, launcher, path)
        box.pack_start(button, False, False, 0)
        box.show_all()
        if window is not None:
            open_locations.track(box, uri)
        return box

    @staticmethod
    def _open(button, launcher, path):
        try:
            subprocess.Popen([os.fspath(launcher), '--directory', path], close_fds=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError as error:
            dialog = Gtk.MessageDialog(transient_for=button.get_toplevel(), modal=True,
                                       message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE,
                                       text='FavenioQuick konnte nicht gestartet werden.')
            dialog.format_secondary_text(str(error))
            dialog.connect('response', lambda dialog, response: dialog.destroy())
            dialog.show()
