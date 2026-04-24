#!/usr/bin/env python3
"""Persistent voice dictation daemon with system tray icon.

Loads the Whisper model once and stays resident. SIGUSR1 toggles recording.
A tray icon shows status: idle, recording, or transcribing.
"""

import json
import os
import signal
import subprocess
import sys
import threading

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator3
from gi.repository import GLib, Gtk

import numpy as np
import sounddevice as sd
from pynput import mouse as pynput_mouse

SAMPLE_RATE = 16000
STATE_FILE = "/tmp/dictation-state.json"
CONFIG_FILE = os.path.expanduser("~/.config/dictation-model")
THRESHOLD_FILE = os.path.expanduser("~/.config/dictation-threshold")
HOTKEY_FILE = os.path.expanduser("~/.config/dictation-hotkey")
SESSION_TYPE = os.environ.get("XDG_SESSION_TYPE", "x11")

MODELS = [
    ("tiny",             "realtime, lower accuracy"),
    ("base",             "realtime, decent"),
    ("distil-small.en",  "realtime, good (English)"),
    ("small",            "fast, good"),
    ("distil-medium.en", "fast, great (English)"),
    ("distil-large-v3",  "moderate, near-best"),
    ("medium",           "slow, great"),
    ("large-v3",         "slowest, best accuracy"),
]
MODEL_NAMES = [name for name, _ in MODELS]

THRESHOLDS = [
    ("Low (quiet mic)", 0.002),
    ("Medium", 0.005),
    ("High (loud mic)", 0.012),
]

HOTKEYS = [
    ("Ctrl+Space (keyboard)", "ctrl+space"),
    ("Mouse Thumb Back", "mouse:8"),
    ("Mouse Thumb Forward", "mouse:9"),
    ("Mouse Middle Click", "mouse:2"),
    ("F6", "f6"),
    ("F7", "f7"),
    ("F8", "f8"),
    ("Custom... (press any key/button)", "custom"),
]

ICONS = {
    "idle": "microphone-sensitivity-muted-symbolic",
    "recording": "microphone-sensitivity-high-symbolic",
    "transcribing": "microphone-sensitivity-medium-symbolic",
}


def get_configured_model():
    if os.path.exists(CONFIG_FILE):
        return open(CONFIG_FILE).read().strip()
    return "distil-large-v3"


def get_threshold():
    if os.path.exists(THRESHOLD_FILE):
        try:
            return float(open(THRESHOLD_FILE).read().strip())
        except ValueError:
            pass
    return 0.005


def set_threshold(value):
    with open(THRESHOLD_FILE, "w") as f:
        f.write(str(value))


def get_hotkey():
    if os.path.exists(HOTKEY_FILE):
        return open(HOTKEY_FILE).read().strip()
    return "ctrl+space"


def set_hotkey(value):
    with open(HOTKEY_FILE, "w") as f:
        f.write(value)


def type_text(text):
    if SESSION_TYPE == "wayland":
        subprocess.run(["ydotool", "type", "--", text], check=False)
    else:
        subprocess.run(["xdotool", "type", "--delay", "12", "--", text], check=False)


def notify(message):
    subprocess.run(["notify-send", "-t", "2000", "Dictation", message], check=False)


def hotkey_display_name(key):
    for label, value in HOTKEYS:
        if value == key:
            return label
    if key.startswith("mouse:"):
        return f"Mouse Button {key.split(':')[1]}"
    return key


class DictationDaemon:
    def __init__(self):
        self.model_name = get_configured_model()
        self.model = None
        self.recording = False
        self.running = True
        self.record_thread = None
        self.indicator = None
        self.status_item = None
        self.toggle_item = None
        self.model_items = {}
        self.threshold_items = {}
        self.hotkey_items = {}
        self.mouse_listener = None
        self.capture_next_click = False

    def load_model(self):
        from faster_whisper import WhisperModel
        notify(f"Loading {self.model_name}...")
        self.model = WhisperModel(self.model_name, device="cpu", compute_type="int8")
        notify("Ready — press Ctrl+Space to dictate")
        GLib.idle_add(self._update_status_label)

    def switch_model(self, name):
        if name == self.model_name and self.model is not None:
            return
        self.model_name = name
        with open(CONFIG_FILE, "w") as f:
            f.write(name)
        was_recording = self.recording
        if was_recording:
            self.stop_recording()
        self.model = None
        GLib.idle_add(self._set_icon, "idle")
        GLib.idle_add(self._update_status_label)
        threading.Thread(target=self._reload_model_and_resume,
                         args=(was_recording,), daemon=True).start()

    def _reload_model_and_resume(self, resume):
        self.load_model()
        GLib.idle_add(self._rebuild_model_menu)
        if resume:
            GLib.idle_add(self.start_recording)

    def toggle(self):
        if self.model is None:
            notify("Model still loading...")
            return
        if self.recording:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        if self.recording:
            return
        if self.record_thread and self.record_thread.is_alive():
            self.record_thread.join(timeout=2)
        self.recording = True
        self._set_icon("recording")
        self._update_toggle_label()
        self._update_status_label()
        self.record_thread = threading.Thread(target=self._record_loop, daemon=True)
        self.record_thread.start()

    def stop_recording(self):
        self.recording = False
        self._set_icon("idle")
        self._update_toggle_label()
        self._update_status_label()

    def _record_loop(self):
        chunk_ms = 100
        chunk_size = SAMPLE_RATE * chunk_ms // 1000
        pause_chunks = int(0.7 / (chunk_ms / 1000))
        min_speech_chunks = int(0.4 / (chunk_ms / 1000))
        threshold = get_threshold()

        buf = []
        silence = 0
        speech = 0
        active = False

        try:
            with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                                blocksize=chunk_size) as stream:
                while self.recording:
                    data, _ = stream.read(chunk_size)
                    chunk = data[:, 0]
                    rms = np.sqrt(np.mean(chunk ** 2))

                    if rms > threshold:
                        buf.append(chunk)
                        speech += 1
                        silence = 0
                        active = True
                    elif active:
                        buf.append(chunk)
                        silence += 1

                        if silence >= pause_chunks:
                            if speech >= min_speech_chunks:
                                GLib.idle_add(self._set_icon, "transcribing")
                                audio = np.concatenate(buf)
                                segs, _ = self.model.transcribe(
                                    audio, beam_size=5, language="en",
                                    vad_filter=True,
                                )
                                text = " ".join(s.text.strip() for s in segs)
                                if text.strip():
                                    type_text(text + " ")
                                if self.recording:
                                    GLib.idle_add(self._set_icon, "recording")
                            buf.clear()
                            silence = 0
                            speech = 0
                            active = False
        except Exception as e:
            notify(f"Recording error: {e}")
            self.recording = False
            GLib.idle_add(self._set_icon, "idle")
            GLib.idle_add(self._update_toggle_label)
            GLib.idle_add(self._update_status_label)

    # ── Mouse listener ──

    def _setup_mouse_listener(self):
        if self.mouse_listener:
            self.mouse_listener.stop()
            self.mouse_listener = None

        hotkey = get_hotkey()
        if not hotkey.startswith("mouse:"):
            return

        button_num = int(hotkey.split(":")[1])
        target_button = pynput_mouse.Button.middle
        if button_num == 8:
            target_button = pynput_mouse.Button.x1
        elif button_num == 9:
            target_button = pynput_mouse.Button.x2
        elif button_num == 2:
            target_button = pynput_mouse.Button.middle

        def on_click(x, y, button, pressed):
            if not pressed:
                return
            if self.capture_next_click:
                btn_num = 2
                if button == pynput_mouse.Button.x1:
                    btn_num = 8
                elif button == pynput_mouse.Button.x2:
                    btn_num = 9
                elif button == pynput_mouse.Button.middle:
                    btn_num = 2
                else:
                    btn_num = getattr(button, 'value', 2)
                self.capture_next_click = False
                new_key = f"mouse:{btn_num}"
                set_hotkey(new_key)
                GLib.idle_add(self._rebuild_hotkey_menu)
                GLib.idle_add(self._setup_mouse_listener)
                notify(f"Hotkey set to {hotkey_display_name(new_key)}")
                return
            if button == target_button:
                GLib.idle_add(self.toggle)

        self.mouse_listener = pynput_mouse.Listener(on_click=on_click)
        self.mouse_listener.daemon = True
        self.mouse_listener.start()

    def _setup_keyboard_hotkey(self, key_name):
        """Set up a GNOME keyboard shortcut for the given key."""
        if key_name == "ctrl+space":
            binding = "<Ctrl>space"
        elif key_name.startswith("f") and key_name[1:].isdigit():
            binding = key_name.upper()
        else:
            return

        bin_dir = os.path.expanduser("~/.local/bin")
        toggle_cmd = f"{bin_dir}/dictate-toggle"

        existing = subprocess.run(
            ["gsettings", "get", "org.gnome.settings-daemon.plugins.media-keys", "custom-keybindings"],
            capture_output=True, text=True
        ).stdout.strip()

        slot = None
        for i in range(10):
            name = subprocess.run(
                ["gsettings", "get",
                 f"org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"
                 f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom{i}/",
                 "name"],
                capture_output=True, text=True
            ).stdout.strip()
            if name == "'Dictation Toggle'":
                slot = i
                break

        if slot is None:
            for i in range(10):
                name = subprocess.run(
                    ["gsettings", "get",
                     f"org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"
                     f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom{i}/",
                     "name"],
                    capture_output=True, text=True
                ).stdout.strip()
                if name == "''":
                    slot = i
                    break

        if slot is None:
            slot = 0

        path = f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom{slot}/"

        if f"custom{slot}" not in existing:
            if existing == "@as []":
                new_list = f"['{path}']"
            else:
                new_list = existing.rstrip("]") + f", '{path}']"
            subprocess.run(["gsettings", "set",
                            "org.gnome.settings-daemon.plugins.media-keys",
                            "custom-keybindings", new_list], check=False)

        subprocess.run(["gsettings", "set",
                        f"org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:{path}",
                        "name", "Dictation Toggle"], check=False)
        subprocess.run(["gsettings", "set",
                        f"org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:{path}",
                        "command", toggle_cmd], check=False)
        subprocess.run(["gsettings", "set",
                        f"org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:{path}",
                        "binding", binding], check=False)

    def _remove_keyboard_hotkey(self):
        """Remove the GNOME keyboard shortcut."""
        for i in range(10):
            name = subprocess.run(
                ["gsettings", "get",
                 f"org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"
                 f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom{i}/",
                 "name"],
                capture_output=True, text=True
            ).stdout.strip()
            if name == "'Dictation Toggle'":
                subprocess.run(["gsettings", "set",
                    f"org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"
                    f"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom{i}/",
                    "binding", ""], check=False)
                break

    # ── UI ──

    def _set_icon(self, state):
        if self.indicator:
            self.indicator.set_icon_full(ICONS[state], state)

    def _update_toggle_label(self):
        if self.toggle_item:
            self.toggle_item.set_label("Stop Recording" if self.recording else "Start Recording")

    def _update_status_label(self):
        if self.status_item:
            if self.model is None:
                status = f"Loading {self.model_name}..."
            elif self.recording:
                status = f"Recording ({self.model_name})"
            else:
                status = f"Ready ({self.model_name})"
            self.status_item.set_label(status)

    def _rebuild_model_menu(self):
        for name, desc in MODELS:
            item = self.model_items.get(name)
            if item:
                prefix = "* " if name == self.model_name else "  "
                item.set_label(f"{prefix}{name} — {desc}")

    def _rebuild_threshold_menu(self):
        current = get_threshold()
        for value, item in self.threshold_items.items():
            label = next(name for name, v in THRESHOLDS if v == value)
            prefix = "* " if value == current else "  "
            item.set_label(f"{prefix}{label}")

    def _rebuild_hotkey_menu(self):
        current = get_hotkey()
        for value, item in self.hotkey_items.items():
            label = hotkey_display_name(value)
            if value == "custom":
                is_preset = any(current == v for _, v in HOTKEYS if v != "custom")
                if not is_preset and current != "custom":
                    label = f"Custom: {hotkey_display_name(current)}"
            prefix = "* " if value == current else "  "
            if value == "custom" and not any(current == v for _, v in HOTKEYS if v != "custom"):
                prefix = "* "
            item.set_label(f"{prefix}{label}")

    def _on_toggle(self, _):
        self.toggle()

    def _on_model_select(self, item, name):
        self.switch_model(name)

    def _on_threshold_select(self, item, value):
        set_threshold(value)
        self._rebuild_threshold_menu()
        notify("Mic sensitivity updated")

    def _on_hotkey_select(self, item, value):
        if value == "custom":
            notify("Click any mouse button to set as hotkey...")
            self.capture_next_click = True
            if not self.mouse_listener:
                self._setup_mouse_listener_for_capture()
            return

        old = get_hotkey()
        set_hotkey(value)

        if value.startswith("mouse:"):
            self._remove_keyboard_hotkey()
            self._setup_mouse_listener()
        else:
            if self.mouse_listener:
                self.mouse_listener.stop()
                self.mouse_listener = None
            self._setup_keyboard_hotkey(value)

        self._rebuild_hotkey_menu()
        notify(f"Hotkey: {hotkey_display_name(value)}")

    def _setup_mouse_listener_for_capture(self):
        """Start a temporary mouse listener just for capturing a custom button."""
        if self.mouse_listener:
            self.mouse_listener.stop()

        def on_click(x, y, button, pressed):
            if not pressed or not self.capture_next_click:
                return
            self.capture_next_click = False
            btn_num = 2
            if button == pynput_mouse.Button.x1:
                btn_num = 8
            elif button == pynput_mouse.Button.x2:
                btn_num = 9
            elif button == pynput_mouse.Button.middle:
                btn_num = 2
            else:
                try:
                    btn_num = button.value.vk if hasattr(button.value, 'vk') else 2
                except Exception:
                    btn_num = 2

            new_key = f"mouse:{btn_num}"
            set_hotkey(new_key)
            self._remove_keyboard_hotkey()
            GLib.idle_add(self._rebuild_hotkey_menu)
            GLib.idle_add(self._setup_mouse_listener)
            notify(f"Hotkey set to {hotkey_display_name(new_key)}")

        self.mouse_listener = pynput_mouse.Listener(on_click=on_click)
        self.mouse_listener.daemon = True
        self.mouse_listener.start()

    def _on_quit(self, _):
        self.recording = False
        self.running = False
        if self.mouse_listener:
            self.mouse_listener.stop()
        try:
            os.unlink(STATE_FILE)
        except OSError:
            pass
        Gtk.main_quit()

    def build_tray(self):
        self.indicator = AppIndicator3.Indicator.new(
            "voice-dictation",
            ICONS["idle"],
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Voice Dictation")

        menu = Gtk.Menu()

        self.status_item = Gtk.MenuItem(label="Loading...")
        self.status_item.set_sensitive(False)
        menu.append(self.status_item)

        menu.append(Gtk.SeparatorMenuItem())

        self.toggle_item = Gtk.MenuItem(label="Start Recording")
        self.toggle_item.connect("activate", self._on_toggle)
        menu.append(self.toggle_item)

        menu.append(Gtk.SeparatorMenuItem())

        # Model section
        model_label = Gtk.MenuItem(label="Model")
        model_label.set_sensitive(False)
        menu.append(model_label)

        for name, desc in MODELS:
            prefix = "* " if name == self.model_name else "  "
            item = Gtk.MenuItem(label=f"{prefix}{name} — {desc}")
            item.connect("activate", self._on_model_select, name)
            menu.append(item)
            self.model_items[name] = item

        menu.append(Gtk.SeparatorMenuItem())

        # Mic sensitivity section
        sens_label = Gtk.MenuItem(label="Mic Sensitivity")
        sens_label.set_sensitive(False)
        menu.append(sens_label)

        current_threshold = get_threshold()
        for label, value in THRESHOLDS:
            prefix = "* " if value == current_threshold else "  "
            item = Gtk.MenuItem(label=f"{prefix}{label}")
            item.connect("activate", self._on_threshold_select, value)
            menu.append(item)
            self.threshold_items[value] = item

        menu.append(Gtk.SeparatorMenuItem())

        # Hotkey section
        hotkey_label = Gtk.MenuItem(label="Hotkey")
        hotkey_label.set_sensitive(False)
        menu.append(hotkey_label)

        current_hotkey = get_hotkey()
        for label, value in HOTKEYS:
            prefix = "* " if value == current_hotkey else "  "
            if value == "custom":
                is_preset = any(current_hotkey == v for _, v in HOTKEYS if v != "custom")
                if not is_preset:
                    prefix = "* "
                    label = f"Custom: {hotkey_display_name(current_hotkey)}"
            item = Gtk.MenuItem(label=f"{prefix}{label}")
            item.connect("activate", self._on_hotkey_select, value)
            menu.append(item)
            self.hotkey_items[value] = item

        menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self._on_quit)
        menu.append(quit_item)

        menu.show_all()
        self.indicator.set_menu(menu)

    def _on_sigusr1(self):
        self.toggle()
        return GLib.SOURCE_CONTINUE

    def _on_sigterm(self):
        self._on_quit(None)
        return GLib.SOURCE_REMOVE

    def run(self):
        self.build_tray()

        threading.Thread(target=self.load_model, daemon=True).start()

        GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGUSR1, self._on_sigusr1)
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, self._on_sigterm)
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGINT, self._on_sigterm)

        # Set up mouse listener if hotkey is a mouse button
        hotkey = get_hotkey()
        if hotkey.startswith("mouse:"):
            self._setup_mouse_listener()

        with open(STATE_FILE, "w") as f:
            json.dump({"pid": os.getpid()}, f)

        Gtk.main()


if __name__ == "__main__":
    DictationDaemon().run()
