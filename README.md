# Janus — History Plugin for mpv

**Janus** is a lightweight, modern playback history and resume plugin for [mpv](https://mpv.io).

It keeps track of recently watched videos, lets you resume where you left off, and offers both native [uosc](https://github.com/darsain/uosc) menu integration and a clean built-in on-screen display for vanilla mpv setups.

---

## Features

- **Fast & Lightweight**: Keeps track of recently watched videos without slowing down mpv. It uses pagination so it only loads a small page of items at a time instead of reading your whole history into memory.
- **Resume Where You Left Off**: When you open a video you've watched before, Janus pops up a quick prompt asking if you want to resume where you left off or start from the beginning. If a video was finished or has no saved position, it starts normally from 0:00 without nagging.
- **Resume Last Played on Idle**: When opening mpv with no file playing (idle window), pressing `Space` immediately opens and resumes your most recently played video.
- **Smart 95% Completion Rule**: Automatically skips the resume prompt and restarts from the beginning if you previously finished the video or left during the end credits (configurable threshold and 95% rule).
- **Hold to Speed Up (YouTube Style)**: Press and hold `Space` or `Right Click` to temporarily speed up playback to 2.0x with audio pitch correction kept intact. Releasing it smoothly restores normal speed, while a quick tap plays/pauses. You can also toggle 2.0x speed anytime with `Alt+n`.
- **Missing & Deleted File Detection**: If a video in your history was moved, deleted, or is on an unmounted drive, Janus strikes through its title and marks it `[Deleted or Moved]`. Clicking it gives a clear on-screen notice instead of failing.
- **Hover to Delete (uosc)**: In uosc, hover over any item in your history menu to reveal a delete button to remove it instantly.
- **Folder Blacklist**: Exclude specific directories or temporary download folders from ever being saved to history.
- **Toggle History Anytime**: Quickly turn history logging on or off on the fly by pressing `Alt+h`.
- **Works with Vanilla mpv & uosc**: Automatically detects if you're using uosc and displays a native menu. If you're on standard mpv, it opens an on-screen menu with full keyboard controls.
- **Smart History Tracking**: Ignores videos you open and quickly skip past (configurable, 5 seconds by default) so your history stays tidy.
- **Replaying Bumps to the Top**: Whenever you rewatch a video, it smoothly updates your progress and moves it back to the top of the list.

---

## Installation

Janus is a single-file script, making installation effortless:

### 1. Install Plugin
Drop `janus.lua` into your mpv `scripts` directory:

```bash
# Linux / macOS
cp janus.lua ~/.config/mpv/scripts/

# Windows
# Copy janus.lua to: %APPDATA%/mpv/scripts/
```

> **Tip**: If you have `save-position-on-quit=yes` in your `mpv.conf`, you can safely disable or remove it. Janus saves your playback progress continuously (every 15 seconds and on pause) and handles resume prompts without conflicts.

### 2. Configuration (Optional)
If you want to customize settings, drop `janus.conf` into your `script-opts` directory:

```bash
# Linux / macOS
cp janus.conf ~/.config/mpv/script-opts/

# Windows
# Copy janus.conf to: %APPDATA%/mpv/script-opts/
```

---

## Keybindings

Janus provides built-in default shortcuts:
- **`h`**: Open the Janus history menu
- **`Alt+h`**: Toggle history tracking on or off
- **`Space`**: Tap to play/pause (or resume last video when idle), hold to speed up to 2.0x
- **Right Click (`MBTN_RIGHT`)**: Tap to play/pause, hold to speed up to 2.0x
- **`Alt+n`**: Toggle 2.0x speed on or off

If you want to customize them in `~/.config/mpv/input.conf`:

```conf
# Open history (auto-detects uosc or vanilla OSD)
h script-binding janus/open

# Toggle tracking on/off
Alt+h script-binding janus/toggle-tracking

# Hold to speed up / tap to pause (resumes last video when idle)
SPACE script-binding janus/speed-hold
MBTN_RIGHT script-binding janus/speed-hold

# Resume the last played video explicitly
ctrl+r script-binding janus/play-last

# Toggle 2x speed on/off
Alt+n script-binding janus/speed-toggle

# Open specific menu styles
H script-binding janus/history-vanilla
ctrl+h script-binding janus/history-uosc
```

---

## uosc Menus & Controls

If you use **uosc**, you can integrate Janus directly into your menus and timeline buttons:

### Adding to uosc Menu
Append `#! History` to your keybinding in `~/.config/mpv/input.conf`:

```conf
# Opens history and creates an entry in uosc's menu
h script-binding janus/open #! History

# Or add to uosc menu without binding a shortcut key:
# script-binding janus/open #! History
```

### Adding a Button Above Timeline
Add `command:history:script-binding janus/open?History` to your `controls` option in `~/.config/mpv/script-opts/uosc.conf`:

```conf
controls=menu,subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,items,command:history:script-binding janus/open?History,gap,space,speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen
```

---

## How to Use

### Resume Prompt
When you open a video you've already started:
- **Enter**: Resume from your saved time
- **r** / **b** / **Home**: Start from the beginning (`00:00`)
- **Esc** / **q**: Dismiss the prompt

If you don't press anything within 10 seconds, it will automatically resume for you. If a video was finished or never watched before, it plays normally from `00:00` without showing any prompt.

### History Menu (Vanilla OSD)
- **↑ / ↓** (or **k / j**): Move up and down
- **Enter**: Play selected video
- **← / →** (or **h / l**): Previous / next page
- **Del** / **Backspace**: Remove video from history
- **Esc** / **q**: Close menu

---

## Configuration

You can tweak options in `~/.config/mpv/script-opts/janus.conf`:

| Option | Default | Description |
| :--- | :--- | :--- |
| `enabled` | `yes` | Master switch: enable or disable history tracking |
| `history_file` | `~~/janus_history.jsonl` | Where your history log is saved |
| `ignore_paths` | `""` | Folders to ignore (semicolon or comma separated) |
| `page_size` | `20` | Number of videos displayed per page |
| `watch_threshold` | `5` | Minimum seconds watched before saving to history |
| `update_interval` | `15` | Seconds between periodic progress updates |
| `ask_resume` | `yes` | Ask to resume when loading a previous video |
| `resume_threshold` | `10` | Minimum saved position (in seconds) to show resume prompt |
| `resume_end_threshold` | `15` | Ignore resume prompt if within this many seconds from the end |
| `resume_end_percent` | `95` | Ignore resume prompt if watched past this percent (95% rule) |
| `resume_skip_playlist` | `no` | Skip resume prompt on playlist auto-advance (binge mode) |
| `resume_timeout` | `10` | Seconds to wait before auto-resuming (0 to disable) |
| `resume_pause_on_prompt` | `yes` | Pause playback while asking to resume |
| `play_last_on_idle` | `yes` | Pressing play while idle resumes the most recent video |
| `ui_mode` | `auto` | `auto`, `uosc`, or `vanilla` |
| `speed_enabled` | `yes` | Hold Spacebar or Right Click to temporarily speed up |
| `speed_target` | `2.0` | Playback speed multiplier while holding |
| `speed_delay` | `0.3` | Seconds to hold before speeding up activates |

---

## License

MIT License.
