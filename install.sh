#!/usr/bin/env bash
set -euo pipefail

# Voice Dictation Installer for Ubuntu 24.04+ (X11 & Wayland)
# https://github.com/sunapi386/voice-dictation
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sunapi386/voice-dictation/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --model distil-large-v3
#   curl -fsSL ... | bash -s -- --model large-v3

INSTALL_DIR="$HOME/.local/share/voice-dictation"
BIN_DIR="$HOME/.local/bin"
MODEL=""
SKIP_SHORTCUT=false

# ─── Parse args ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --skip-shortcut) SKIP_SHORTCUT=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m→\033[0m $*"; }
ok()    { echo -e "\033[1;32m✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m!\033[0m $*"; }
fail()  { echo -e "\033[1;31m✗\033[0m $*"; exit 1; }

# ─── Preflight checks ───────────────────────────────────────────────────────

info "Checking system..."

[[ -f /etc/os-release ]] || fail "Cannot detect OS — expected Ubuntu 24.04+"
source /etc/os-release
if [[ "$ID" != "ubuntu" ]] || [[ "${VERSION_ID%%.*}" -lt 24 ]]; then
    fail "Requires Ubuntu 24.04 or later (detected: $PRETTY_NAME)"
fi
ok "Ubuntu $VERSION_ID"

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
ok "${RAM_GB}GB RAM"

SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"
ok "Display server: $SESSION_TYPE"

# ─── Model selection ─────────────────────────────────────────────────────────

recommend_model() {
    if [[ $RAM_GB -ge 16 ]]; then
        echo "distil-large-v3"
    elif [[ $RAM_GB -ge 8 ]]; then
        echo "small"
    elif [[ $RAM_GB -ge 4 ]]; then
        echo "base"
    else
        echo "tiny"
    fi
}

VALID_MODELS="tiny base small medium large-v3 distil-large-v3 distil-medium.en distil-small.en"
RECOMMENDED=$(recommend_model)

if [[ -z "$MODEL" ]]; then
    MODEL="$RECOMMENDED"
fi

echo "$VALID_MODELS" | tr ' ' '\n' | grep -qx "$MODEL" || \
    fail "Unknown model: $MODEL\nAvailable: $VALID_MODELS"

case "$MODEL" in
    large-v3)
        [[ $RAM_GB -lt 12 ]] && warn "large-v3 needs ~10GB RAM. You have ${RAM_GB}GB — may be slow or OOM."
        ;;
    distil-large-v3|medium)
        [[ $RAM_GB -lt 6 ]] && warn "$MODEL needs ~5GB RAM. You have ${RAM_GB}GB — may be tight."
        ;;
esac

info "Model: $MODEL (recommended for ${RAM_GB}GB RAM: $RECOMMENDED)"

# ─── Install system packages ────────────────────────────────────────────────

info "Installing system dependencies..."

sudo apt-get update -qq 2>/dev/null || true
sudo apt-get install -y -qq \
    portaudio19-dev python3-venv python3-dev git \
    pulseaudio-utils libnotify-bin \
    gir1.2-ayatanaappindicator3-0.1 \
    > /dev/null 2>&1

if [[ "$SESSION_TYPE" == "wayland" ]]; then
    sudo apt-get install -y -qq ydotool > /dev/null 2>&1
    ok "Installed ydotool (Wayland)"
else
    sudo apt-get install -y -qq xdotool > /dev/null 2>&1
    ok "Installed xdotool (X11)"
fi

ok "System dependencies installed"

# ─── Wayland-specific setup ─────────────────────────────────────────────────

if [[ "$SESSION_TYPE" == "wayland" ]]; then
    info "Configuring ydotool for Wayland..."

    if ! groups | grep -q '\binput\b'; then
        sudo usermod -aG input "$USER"
        warn "Added $USER to 'input' group — you must log out and back in for this to take effect"
    fi

    if [[ ! -f /etc/udev/rules.d/60-uinput.rules ]]; then
        sudo tee /etc/udev/rules.d/60-uinput.rules > /dev/null << 'UDEV'
KERNEL=="uinput", MODE="0660", GROUP="input"
UDEV
        sudo udevadm control --reload-rules && sudo udevadm trigger
    fi

    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ydotool.service" << 'UNIT'
[Unit]
Description=ydotool daemon

[Service]
ExecStart=/usr/bin/ydotoold

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now ydotool 2>/dev/null || true
    ok "ydotool configured"
fi

# ─── Python environment ─────────────────────────────────────────────────────

info "Setting up Python environment..."
mkdir -p "$INSTALL_DIR"

if [[ -d "$INSTALL_DIR/venv" ]]; then
    rm -rf "$INSTALL_DIR/venv"
fi
python3 -m venv --system-site-packages "$INSTALL_DIR/venv"

"$INSTALL_DIR/venv/bin/pip" install --upgrade pip -q 2>/dev/null
"$INSTALL_DIR/venv/bin/pip" install -q \
    faster-whisper numpy sounddevice soundfile 2>/dev/null

ok "Python environment ready"

# ─── Download model ──────────────────────────────────────────────────────────

info "Downloading $MODEL model (this may take a minute)..."

"$INSTALL_DIR/venv/bin/python" -c "
from faster_whisper import WhisperModel
WhisperModel('$MODEL', device='cpu', compute_type='int8')
print('done')
" 2>/dev/null

ok "Model $MODEL downloaded and cached"

# ─── Install scripts ────────────────────────────────────────────────────────

info "Installing scripts to $BIN_DIR..."
mkdir -p "$BIN_DIR"

# ── dictate-daemon.py ──

cat > "$BIN_DIR/dictate-daemon.py" << 'PYEOF'
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

SAMPLE_RATE = 16000
STATE_FILE = "/tmp/dictation-state.json"
CONFIG_FILE = os.path.expanduser("~/.config/dictation-model")
SESSION_TYPE = os.environ.get("XDG_SESSION_TYPE", "x11")

MODELS = ["tiny", "base", "small", "medium", "large-v3",
          "distil-large-v3", "distil-medium.en", "distil-small.en"]

ICONS = {
    "idle": "microphone-sensitivity-muted-symbolic",
    "recording": "microphone-sensitivity-high-symbolic",
    "transcribing": "microphone-sensitivity-medium-symbolic",
}


def get_configured_model():
    if os.path.exists(CONFIG_FILE):
        return open(CONFIG_FILE).read().strip()
    return "small"


def type_text(text):
    if SESSION_TYPE == "wayland":
        subprocess.run(["ydotool", "type", "--", text], check=False)
    else:
        subprocess.run(["xdotool", "type", "--delay", "12", "--", text], check=False)


def notify(message):
    subprocess.run(["notify-send", "-t", "2000", "Dictation", message], check=False)


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
        self.recording = True
        GLib.idle_add(self._set_icon, "recording")
        GLib.idle_add(self._update_toggle_label)
        GLib.idle_add(self._update_status_label)
        self.record_thread = threading.Thread(target=self._record_loop, daemon=True)
        self.record_thread.start()

    def stop_recording(self):
        self.recording = False
        GLib.idle_add(self._set_icon, "idle")
        GLib.idle_add(self._update_toggle_label)
        GLib.idle_add(self._update_status_label)

    def _record_loop(self):
        chunk_ms = 100
        chunk_size = SAMPLE_RATE * chunk_ms // 1000
        pause_chunks = int(0.7 / (chunk_ms / 1000))
        min_speech_chunks = int(0.4 / (chunk_ms / 1000))

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

                    if rms > 0.012:
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
        for name, item in self.model_items.items():
            label = f"  {name}"
            if name == self.model_name:
                label = f"* {name}"
            item.set_label(label)

    def _on_toggle(self, _):
        self.toggle()

    def _on_model_select(self, item, name):
        self.switch_model(name)

    def _on_quit(self, _):
        self.recording = False
        self.running = False
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

        model_label = Gtk.MenuItem(label="Model")
        model_label.set_sensitive(False)
        menu.append(model_label)

        for name in MODELS:
            prefix = "* " if name == self.model_name else "  "
            item = Gtk.MenuItem(label=f"{prefix}{name}")
            item.connect("activate", self._on_model_select, name)
            menu.append(item)
            self.model_items[name] = item

        menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self._on_quit)
        menu.append(quit_item)

        menu.show_all()
        self.indicator.set_menu(menu)

    def run(self):
        self.build_tray()

        threading.Thread(target=self.load_model, daemon=True).start()

        signal.signal(signal.SIGUSR1, lambda s, f: GLib.idle_add(self.toggle))
        signal.signal(signal.SIGTERM, lambda s, f: GLib.idle_add(self._on_quit, None))
        signal.signal(signal.SIGINT, lambda s, f: GLib.idle_add(self._on_quit, None))

        with open(STATE_FILE, "w") as f:
            json.dump({"pid": os.getpid()}, f)

        Gtk.main()


if __name__ == "__main__":
    DictationDaemon().run()
PYEOF

# ── dictate-toggle ──

cat > "$BIN_DIR/dictate-toggle" << TOGGLEEOF
#!/bin/bash
STATE_FILE="/tmp/dictation-state.json"

if [ ! -f "\$STATE_FILE" ]; then
    notify-send -t 2000 "Dictation" "Daemon not running — starting it..."
    $BIN_DIR/dictate-start &
    exit 0
fi

PID=\$(python3 -c "import json; print(json.load(open('\$STATE_FILE'))['pid'])" 2>/dev/null)

if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
    kill -USR1 "\$PID"
else
    rm -f "\$STATE_FILE"
    notify-send -t 2000 "Dictation" "Daemon not running — starting it..."
    $BIN_DIR/dictate-start &
fi
TOGGLEEOF

# ── dictate-start ──

cat > "$BIN_DIR/dictate-start" << STARTEOF
#!/bin/bash
STATE_FILE="/tmp/dictation-state.json"

if [ -f "\$STATE_FILE" ]; then
    PID=\$(python3 -c "import json; print(json.load(open('\$STATE_FILE'))['pid'])" 2>/dev/null)
    if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
        notify-send -t 2000 "Dictation" "Already running"
        exit 0
    fi
    rm -f "\$STATE_FILE"
fi

$INSTALL_DIR/venv/bin/python $BIN_DIR/dictate-daemon.py &
disown
STARTEOF

# ── dictate-stop ──

cat > "$BIN_DIR/dictate-stop" << STOPEOF
#!/bin/bash
STATE_FILE="/tmp/dictation-state.json"

if [ ! -f "\$STATE_FILE" ]; then
    exit 0
fi

PID=\$(python3 -c "import json; print(json.load(open('\$STATE_FILE'))['pid'])" 2>/dev/null)
if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then
    kill "\$PID" 2>/dev/null
fi
rm -f "\$STATE_FILE"
STOPEOF

# ── dictate-model ──

cat > "$BIN_DIR/dictate-model" << 'MODELEOF'
#!/bin/bash
MODEL_FILE="$HOME/.config/dictation-model"
MODELS="tiny base small medium large-v3 distil-large-v3 distil-medium.en distil-small.en"

if [ -z "$1" ]; then
    CURRENT="small"
    [ -f "$MODEL_FILE" ] && CURRENT=$(cat "$MODEL_FILE")
    echo "Current model: $CURRENT"
    echo ""
    echo "  tiny              75MB   ~1GB RAM   Fastest, lower accuracy"
    echo "  base             142MB   ~1GB RAM   Fast, decent accuracy"
    echo "  small            466MB   ~2GB RAM   Good balance (default)"
    echo "  medium           1.5GB   ~5GB RAM   Better accuracy, slower"
    echo "  distil-medium.en 1.5GB   ~5GB RAM   Fast + accurate (English)"
    echo "  distil-large-v3    2GB   ~5GB RAM   Near-best accuracy, fast"
    echo "  large-v3           3GB  ~10GB RAM   Best accuracy, slowest"
    echo "  distil-small.en  466MB   ~2GB RAM   Fast (English only)"
    echo ""
    echo "Usage: dictate-model <model>"
    echo "Change takes effect immediately if the daemon is running."
    exit 0
fi

for m in $MODELS; do
    if [ "$1" = "$m" ]; then
        echo "$1" > "$MODEL_FILE"
        echo "Model set to: $1"

        # Signal daemon to reload if running
        STATE_FILE="/tmp/dictation-state.json"
        if [ -f "$STATE_FILE" ]; then
            echo "Restarting daemon with new model..."
            PID=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['pid'])" 2>/dev/null)
            if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
                kill "$PID" 2>/dev/null
                sleep 1
            fi
            rm -f "$STATE_FILE"
            ~/.local/bin/dictate-start
        fi
        exit 0
    fi
done

echo "Unknown model: $1"
echo "Available: $MODELS"
exit 1
MODELEOF

chmod +x "$BIN_DIR"/dictate-{daemon.py,start,stop,toggle,model}

ok "Scripts installed"

# ─── Systemd service ────────────────────────────────────────────────────────

info "Setting up auto-start service..."
mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/voice-dictation.service" << SVCEOF
[Unit]
Description=Voice Dictation Daemon
After=graphical-session.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/venv/bin/python $BIN_DIR/dictate-daemon.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable voice-dictation 2>/dev/null
systemctl --user restart voice-dictation 2>/dev/null || true

ok "Daemon enabled (auto-starts on login)"

# ─── Keyboard shortcut ──────────────────────────────────────────────────────

if [[ "$SKIP_SHORTCUT" == true ]]; then
    warn "Skipping keyboard shortcut setup (--skip-shortcut)"
else
    info "Setting up Ctrl+Space shortcut..."

    gsettings set org.freedesktop.ibus.general.hotkey triggers "[]" 2>/dev/null || true

    EXISTING=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")

    SLOT=""
    for i in $(seq 0 9); do
        NAME=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/ name 2>/dev/null || echo "''")
        if [[ "$NAME" == "'Dictation Toggle'" ]]; then
            SLOT=$i
            break
        fi
    done

    if [[ -z "$SLOT" ]]; then
        for i in $(seq 0 9); do
            NAME=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/ name 2>/dev/null || echo "''")
            if [[ "$NAME" == "''" ]]; then
                SLOT=$i
                break
            fi
        done
    fi

    [[ -z "$SLOT" ]] && SLOT=0

    SLOT_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${SLOT}/"

    if ! echo "$EXISTING" | grep -q "custom${SLOT}"; then
        if [[ "$EXISTING" == "@as []" ]]; then
            NEW_LIST="['$SLOT_PATH']"
        else
            NEW_LIST=$(echo "$EXISTING" | sed "s/]$/, '$SLOT_PATH']/")
        fi
        gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$NEW_LIST"
    fi

    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${SLOT_PATH} name 'Dictation Toggle'
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${SLOT_PATH} command "$BIN_DIR/dictate-toggle"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${SLOT_PATH} binding '<Ctrl>space'

    ok "Ctrl+Space bound to dictation toggle"
fi

# ─── PATH check ──────────────────────────────────────────────────────────────

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    warn "$BIN_DIR is not in your PATH"
    warn "Add this to your shell config (~/.bashrc or ~/.config/fish/config.fish):"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Voice dictation installed!"
echo ""
echo "  Ctrl+Space          Toggle recording"
echo "  dictate-model       Show/change whisper model"
echo "  dictate-stop        Stop the daemon"
echo "  dictate-start       Start the daemon"
echo ""
echo "  Model: $MODEL"
echo "  Display: $SESSION_TYPE"
echo "  Tray icon: microphone in system tray"
echo "  Auto-start: enabled (starts on login)"
echo ""
if [[ "$SESSION_TYPE" == "wayland" ]] && ! groups | grep -q '\binput\b'; then
    warn "Log out and back in for Wayland input permissions to take effect."
    echo ""
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
