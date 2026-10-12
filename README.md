# Janus — History Plugin for mpv

**Janus** is a lightweight, modern, and high-performance playback history logger for [mpv](https://mpv.io).
Janus is a single-file script, making installation effortless:

InstallDrop`janus.lua```#Linux macOS
cp lua

# Windows
# Copy .lua to: %APPDATA%/mpv/scripts/dropintodirectory# Linux / macOS


# Windows
# Copy  to: %APPDATA%/mpv/script-opts/to```

### 4. uosc Menu & Controls

If you use **uosc**, you can pin Janus to your uosc menu or timeline controls:

#### Add to uosc Menu
Append `#! History` to your keybinding in `~/.config/mpv/input.conf`:

```conf
# Opens history and creates an entry in uosc's menu
h script-binding janus/open #! History

# Or add to uosc menu without binding a shortcut key:
# script-binding janus/open #! History
```

#### Add a Button Above Timeline
Add `command:history:script-binding janus/open?History` to your `controls` option in `~/.config/mpv/script-opts/uosc.conf`:

```conf
controls=menu,subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,items,command:history:script-binding janus/open?History,gap,space,speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen

## Features

- **Fast & Lightweight**: Keeps track of recently watched videos without slowing down mpv. It uses pagination so it only loads a small page of items at a time instead of reading your whole history into memory.
- **Resume Where You Left Off**: When you open a video you've watched before, Janus pops up a quick prompt asking if you want to resume where you left off or start from the beginning.
- **Works with Vanilla mpv & uosc**: Automatically detects if you're using [uosc](https://github.com/darsain/uosc) and shows a native menu. If you're on standard mpv, it displays a clean, built-in on-screen menu with full keyboard controls.
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

### 2. Configuration (Optional)
If you want to customize settings, drop `janus.conf` into your `script-opts` directory:

```bash
# Linux / macOS
cp janus.conf ~/.config/mpv/script-opts/

# Windows
# Copy janus.conf to: %APPDATA%/mpv/script-opts/
```

### 3. Keybindings
Add a keybinding to your `~/.config/mpv/input.conf`:

```conf
# Open history (auto-detects uosc or vanilla OSD)
h script-binding janus/open

# Or pick a specific menu style:
H script-binding janus/history-vanilla
ctrl+h script-binding janus/history-uosc
```

---

## How to Use

### Resume Prompt
When you open a video you've already started:
- **Enter**: Resume from your saved time
- **r** / **b** / **Home**: Start from the beginning (`00:00`)
- **Esc** / **q**: Dismiss the prompt

If you don't press anything within 10 seconds, it will automatically resume for you.

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
| `history_file` | `~~/janus_history.jsonl` | Where your history log is saved |
| `page_size` | `20` | Number of videos displayed per page |
| `watch_threshold` | `5` | Minimum seconds watched before saving to history |
| `ask_resume` | `yes` | Ask to resume when loading a previous video |
| `resume_timeout` | `10` | Seconds to wait before auto-resuming (0 to disable) |
| `resume_pause_on_prompt` | `yes` | Pause playback while asking to resume |
| `ui_mode` | `auto` | `auto`, `uosc`, or `vanilla` |

---

## License

MIT License.
