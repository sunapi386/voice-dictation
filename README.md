# Voice Dictation for Ubuntu

Offline, real-time voice dictation for Ubuntu 24.04+. Press a hotkey to start talking, press again to stop. Text appears phrase-by-phrase as you speak — works in any app.

Uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (OpenAI Whisper) for transcription. No cloud, no API keys, no subscriptions.

- Works on both **X11** and **Wayland**
- **System tray icon** — status, model, sensitivity, and hotkey all configurable from the dropdown
- **Model stays loaded in RAM** — no startup delay when you press the hotkey
- **Auto-starts on login** via systemd user service
- **Configurable hotkey** — keyboard shortcuts, mouse thumb buttons, or any mouse button

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sunapi386/voice-dictation/main/install.sh | bash
```

The installer auto-detects your RAM and picks the best model. Override with:

```bash
# Best accuracy (needs 10GB+ RAM)
curl -fsSL ... | bash -s -- --model large-v3

# Best speed/accuracy tradeoff (needs 5GB+ RAM)
curl -fsSL ... | bash -s -- --model distil-large-v3

# Realtime speed (needs 2GB+ RAM)
curl -fsSL ... | bash -s -- --model distil-small.en
```

## Usage

| Action | What happens |
|---|---|
| **Ctrl+Space** (default) | Toggle recording on/off |
| **Right-click tray icon** | Change model, sensitivity, hotkey, or quit |
| `dictate-model` | Show/change model from terminal |

## Tray Menu

Right-click the microphone icon in your system tray:

```
Ready (distil-large-v3)
──────────────────────────
Start Recording
──────────────────────────
Model
  tiny             — realtime, lower accuracy
  base             — realtime, decent
  distil-small.en  — realtime, good (English)
  small            — fast, good
  distil-medium.en — fast, great (English)
* distil-large-v3  — moderate, near-best
  medium           — slow, great
  large-v3         — slowest, best accuracy
──────────────────────────
Mic Sensitivity
  Low (quiet mic)
* Medium
  High (loud mic)
──────────────────────────
Hotkey
* Ctrl+Space (keyboard)
  Mouse Thumb Back
  Mouse Thumb Forward
  Mouse Middle Click
  F6 / F7 / F8
  Custom... (press any button)
──────────────────────────
Quit
```

## Models

Models labeled **realtime** transcribe fast enough that text appears almost instantly after you pause. Others have a brief delay.

| Model | Size | RAM | Speed | Accuracy |
|---|---|---|---|---|
| `tiny` | 75 MB | ~1 GB | Realtime | Lower |
| `base` | 142 MB | ~1 GB | Realtime | Decent |
| `distil-small.en` | 466 MB | ~2 GB | Realtime | Good (English) |
| `small` | 466 MB | ~2 GB | Fast | Good |
| `distil-medium.en` | 1.5 GB | ~5 GB | Fast | Great (English) |
| `distil-large-v3` | 2 GB | ~5 GB | Moderate | Near-best |
| `medium` | 1.5 GB | ~5 GB | Slow | Great |
| `large-v3` | 3 GB | ~10 GB | Slowest | Best |

**Auto-selected by RAM:** >=16GB gets `distil-large-v3`, >=8GB gets `small`, >=4GB gets `base`, <4GB gets `tiny`.

## How it works

```
┌──────────────────────────────────────────────────────┐
│  Daemon (always running, model loaded in RAM)        │
│                                                      │
│  Hotkey → toggle recording                           │
│                                                      │
│  Recording → VAD detects pause → transcribe phrase   │
│           → type text at cursor → keep listening     │
│                                                      │
│  Tray icon: idle / recording / transcribing          │
└──────────────────────────────────────────────────────┘
```

1. A daemon loads the Whisper model once and stays resident (~300MB-1.5GB RAM depending on model)
2. Pressing the hotkey signals the daemon to start/stop recording — instant response
3. While recording, it detects natural pauses (VAD-based chunking) and transcribes each phrase
4. Text is typed at your cursor using `xdotool` (X11) or `ydotool` (Wayland)
5. The tray icon reflects current state

## Project Structure

```
voice-dictation/
├── install.sh                      # One-line installer (curl | bash)
├── scripts/
│   ├── dictate-daemon.py           # Main daemon: tray icon, recording, transcription
│   ├── dictate-start               # Start the daemon
│   ├── dictate-stop                # Stop the daemon
│   ├── dictate-toggle              # Toggle recording (sends SIGUSR1 to daemon)
│   ├── dictate-model               # CLI tool to switch models
│   └── voice-dictation.service     # Systemd user service for auto-start
├── README.md
└── LICENSE
```

## Managing the daemon

```bash
# Check status
systemctl --user status voice-dictation

# Restart
systemctl --user restart voice-dictation

# Stop
systemctl --user stop voice-dictation

# Disable auto-start
systemctl --user disable voice-dictation
```

## Config files

All config is in `~/.config/`:

| File | Purpose | Default |
|---|---|---|
| `dictation-model` | Whisper model name | `distil-large-v3` |
| `dictation-threshold` | Mic sensitivity (RMS) | `0.005` |
| `dictation-hotkey` | Hotkey binding | `ctrl+space` |

## Requirements

- Ubuntu 24.04 or later
- 2GB+ RAM (more = better model options)
- Working microphone
- GNOME desktop (for tray icon and keyboard shortcuts)

## Troubleshooting

**Ctrl+Space doesn't work**
- IBus may still be capturing it: `gsettings set org.freedesktop.ibus.general.hotkey triggers "[]"`
- Log out and back in

**No tray icon visible**
- Ensure the AppIndicator GNOME extension is enabled: `gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com`

**No speech detected**
- Test your mic: `parecord --channels=1 /tmp/test.wav` then `aplay /tmp/test.wav`
- Right-click tray icon → Mic Sensitivity → try "Low (quiet mic)"

**Transcription is slow**
- Switch to a realtime model from the tray menu: `distil-small.en`, `base`, or `tiny`

**Wayland: ydotool not typing**
- Log out and back in after install (for `input` group)
- Check: `groups | grep input`

## Uninstall

```bash
systemctl --user stop voice-dictation
systemctl --user disable voice-dictation
rm -f ~/.config/systemd/user/voice-dictation.service
rm -rf ~/.local/share/voice-dictation
rm -f ~/.local/bin/dictate-{daemon.py,start,stop,toggle,model}
rm -f ~/.config/dictation-{model,threshold,hotkey}
systemctl --user daemon-reload
```

## License

MIT
