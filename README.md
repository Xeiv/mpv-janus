# Janus

Playback history, smart resume, YouTube-style speed hold, and seek undo/redo for [mpv](https://mpv.io).

Works seamlessly with vanilla mpv out of the box, and automatically hooks into [uosc](https://github.com/darsain/uosc) if you have it installed.

---

## Why Janus?

In Roman mythology, **Janus** is the god of beginnings, transitions, and time—traditionally pictured with two faces: one looking back into the past, and one looking forward into the future.

The name fits the script's core features:
- **Looking back**: Remembering where you've been with watch history, and letting you undo accidental timeline jumps (`Ctrl+Z`).
- **Looking forward**: Picking up right where you left off with smart resume prompts, launching your last video directly from an empty window, and redoing seeks (`Ctrl+X`).
- **Bending time**: YouTube-style hold-to-speed (holding `Space` or `Right-Click` for 2x, releasing for 1x) with audio pitch correction kept intact.

---

## What It Does

- **Watch history**: Keeps track of recent videos without hogging memory or slowing down startup. Replaying an old file updates your progress and bumps it to the top. Quick skips (under 5 seconds) are ignored so misclicks don't clutter your log.
- **Smart resume**: Reopening an unfinished video brings up a quick prompt—hit `Enter` to resume, or `r` to start over. If you don't touch anything, it auto-resumes after 10 seconds.
- **95% completion cutoff**: If you finished a video or quit during the credits (past 95%), Janus assumes you're done and starts fresh from 0:00 next time without nagging.
- **Resume straight from idle**: Launch mpv without opening a file first? Hit `Space` on the empty window and it immediately loads and resumes whatever you were watching last.
- **Seek undo & redo (`Ctrl+Z` / `Ctrl+X`)**: Ever fat-finger an arrow key or jump to the wrong chapter and completely lose your spot? `Ctrl+Z` takes you right back to where you jumped from. If you tapped an arrow key several times in a row, Janus groups them into a single jump so you only have to hit undo once.
- **Hold to speed up (2.0x)**: Hold `Space` or `Right-Click` to temporarily cruise through slow scenes at 2x speed. Releasing it drops right back to normal speed, while a quick tap simply plays or pauses. You can also toggle 2x anytime with `Alt+n`.
- **Dead file detection**: If a video in your history was moved, deleted, or sits on an unplugged drive, Janus strikes through the title (`[Deleted or Moved]`) so you know what happened instead of failing silently.
- **uosc & vanilla OSD support**: Automatically detects if you use uosc and renders a native menu with hover-to-delete and live full-history search. On standard mpv, it opens a clean on-screen display with arrow key navigation and pagination.
- **Progress percentage**: Every entry shows your exact timestamp, total duration, percent watched, and how long ago you watched it (e.g. `14:20 / 28:00 (51%) • 2h ago`).
- **Full-history search (uosc)**: Start typing inside the history menu to instantly search through your entire history log across all past videos (not just the current page).
- **Prune & clear with confirmation**: Clean up all missing/moved files at once with **Prune Missing Files**, or erase your history with **Clear All History**—both guarded by confirmation dialogs so nothing is deleted by accident.
- **Folder blacklist**: Ignore folders you don't want tracked (like downloads, temp directories, or private folders).
- **Distraction-free OSD**: Frequent playback actions (speeding up, undoing seeks) use small, quiet HUD icons (`⏩`, `↩`) so they don't block the video. Script warnings and status changes use `Janus:` so you know where they came from.

---

## Installation

Janus is a single-file script. No external dependencies needed.

### 1. Put `janus.lua` in your mpv scripts directory

```bash
# Linux / macOS
cp janus.lua ~/.config/mpv/scripts/

# Windows
# Copy janus.lua to %APPDATA%/mpv/scripts/
```

> **Note**: If you have `save-position-on-quit=yes` in your `mpv.conf`, you can disable or remove it. Janus saves your position automatically (every 15s, on pause, and on quit) and manages resumes without fighting mpv's internal state.

### 2. (Optional) Custom settings
If you want to tweak defaults, copy `janus.conf` into your `script-opts` folder:

```bash
# Linux / macOS
cp janus.conf ~/.config/mpv/script-opts/

# Windows
# Copy janus.conf to %APPDATA%/mpv/script-opts/
```

---

## Default Controls

| Key | Binding | What it does |
| :--- | :--- | :--- |
| **`h`** | `janus/open` | Open history menu (auto-picks uosc or vanilla OSD) |
| **`Alt+h`** | `janus/toggle-tracking` | Turn history logging on / off |
| **`Ctrl+z`** | `janus/seek-undo` | Undo seek (jump back to where you were) |
| **`Ctrl+x`** | `janus/seek-redo` | Redo seek |
| **`Space`** | `janus/speed-hold` | Tap to play/pause (or resume last video if idle), hold for 2x speed |
| **`Right Click`** | `janus/speed-hold` | Tap to play/pause, hold for 2x speed |
| **`Alt+n`** | `janus/speed-toggle` | Toggle 2x speed on / off |
| **`Ctrl+r`** | `janus/play-last` | Resume last played video |
| **`H`** | `janus/history-vanilla` | Force open vanilla OSD menu |
| **`Ctrl+h`** | `janus/history-uosc` | Force open uosc menu |

---

## Custom Keybindings (`input.conf`)

If you want to customize your shortcuts or add Janus to uosc's menu, put this in `~/.config/mpv/input.conf`:

```conf
# Open history (auto-detects uosc or vanilla OSD)
h               script-binding janus/open                       #! History > Playback History

# Toggle history recording on/off
Alt+h           script-binding janus/toggle-tracking            #! History > Toggle History

# Seek undo & redo
ctrl+z          script-binding janus/seek-undo
ctrl+x          script-binding janus/seek-redo

# Hold for 2x speed / tap to play-pause (also resumes last video when mpv is idle)
SPACE           script-binding janus/speed-hold
MBTN_RIGHT      script-binding janus/speed-hold

# Resume the last played video explicitly
ctrl+r          script-binding janus/play-last

# Toggle 2x speed on/off
Alt+n           script-binding janus/speed-toggle

# Open specific menu styles directly
H               script-binding janus/history-vanilla
ctrl+h          script-binding janus/history-uosc
```

### Adding a button above the uosc timeline
If you use uosc and want a clickable history button on your controls bar, add `command:history:script-binding janus/open?History` to `controls` in `~/.config/mpv/script-opts/uosc.conf`:

```conf
controls=menu,subtitles,<has_many_audio>audio,<has_many_video>video,items,command:history:script-binding janus/open?History,gap,space,speed,space,prev,items,next,gap,fullscreen
```

---

## How It Works

### Seek Undo & Redo
- Whenever you jump (arrow keys, chapter skips, clicking the progress bar), Janus remembers where you started.
- Rapid seeks within 1 second are treated as one continuous jump. If you tap Right Arrow five times to skip ahead 25 seconds, pressing `Ctrl+z` once brings you all the way back to the beginning of the jump.
- Remembers up to 5 seeks by default (`seek_history_size`).

### Speed Controls & Idle Resume
- **While playing**: Press and hold `Space` or `Right-Click`. After 0.3s it speeds up to 2.0x. Release to snap back to 1.0x. A quick tap just pauses or plays like usual.
- **When idle**: If mpv is open with nothing loaded, tapping `Space` will find the most recent playable file from your history and start it right where you left off.

### Resume Prompt Controls
When the resume overlay appears on an unfinished video:
- **`Enter`**: Resume from saved time.
- **`r`** / **`b`** / **`Home`**: Start from the beginning (`00:00`).
- **`Esc`** / **`q`**: Dismiss prompt and keep playing from start.
- If left alone, it automatically resumes after 10 seconds.

### Vanilla Menu Navigation
- **`↑` / `↓`** (or **`k` / `j`**): Move cursor up/down.
- **`Enter`**: Play selected item (or confirm action).
- **`←` / `→`** (or **`h` / `l`**): Previous / next page.
- **`Del`** / **`Backspace`**: Delete single item from history.
- **`p`**: Prune all missing/deleted files from history (with confirmation).
- **`c`**: Clear all history (with confirmation).
- **`Esc`** / **`q`**: Close menu (or cancel confirmation).

---

## Configuration (`janus.conf`)

Options can be customized in `~/.config/mpv/script-opts/janus.conf`:

| Option | Default | What it does |
| :--- | :--- | :--- |
| `enabled` | `yes` | Master switch for history logging |
| `history_file` | `~~/janus_history.jsonl` | Where history is stored (`~~/` expands to your mpv config directory) |
| `max_history` | `5000` | Max entries to preserve during compaction |
| `compaction_threshold` | `10000` | Line count before cleaning up duplicate log entries |
| `watch_threshold` | `5` | Seconds watched before a video is logged |
| `update_interval` | `15` | How often (in seconds) progress is saved while watching |
| `save_on_pause` | `yes` | Always save timestamp when pausing |
| `log_urls` | `yes` | Whether to log web streams (YouTube, Twitch, etc.) |
| `ignore_paths` | `""` | Folders to ignore, separated by commas or semicolons |
| `resume_offset` | `0` | Rewind this many seconds when resuming (e.g. 2s for context) |
| `ask_resume` | `yes` | Show prompt when opening unfinished files |
| `resume_threshold` | `10` | Only ask to resume if saved position is past this many seconds |
| `resume_end_threshold` | `15` | Don't ask to resume if within this many seconds from the end |
| `resume_end_percent` | `95` | Don't ask to resume if watched past this percent (skips credits) |
| `resume_skip_playlist` | `no` | Skip resume prompt when playlist auto-advances (binge mode) |
| `resume_timeout` | `10` | Seconds before auto-resuming (set `0` to wait indefinitely) |
| `resume_timeout_action` | `resume` | Action on timeout: `"resume"` or `"beginning"` |
| `resume_pause_on_prompt` | `yes` | Pause video while the resume prompt is showing |
| `play_last_on_idle` | `yes` | Pressing Space on an idle window resumes the last video |
| `seek_history_enabled` | `yes` | Enable `Ctrl+z` and `Ctrl+x` seek undo/redo |
| `seek_history_size` | `5` | How many seeks to remember in the undo stack |
| `ui_mode` | `auto` | `"auto"` (uosc if present, else vanilla), `"uosc"`, or `"vanilla"` |
| `page_size` | `20` | Number of items shown per page in menus |
| `speed_enabled` | `yes` | Enable hold-to-speed on Space and Right Click |
| `speed_target` | `2.0` | Speed multiplier while holding |
| `speed_delay` | `0.3` | How long (seconds) you need to hold before 2x engages |

---

## License

MIT
