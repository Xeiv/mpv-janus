# Janus

Playback history, smart resume, YouTube-style speed hold, and seek undo/redo for [mpv](https://mpv.io).

Works out of the box with standard mpv, and automatically integrates with [uosc](https://github.com/darsain/uosc) if installed.

---

## Why Janus?

In Roman mythology, Janus is the two-faced god of beginnings, transitions, and time, looking both to the past and the future.

The name mirrors what the script does:
- **Looking back**: Watch history, relative timestamps, and undoing accidental seeks (`Ctrl+Z`).
- **Looking forward**: Smart resume prompts, redoing seeks (`Ctrl+X`), and launching your last video directly from an empty window.
- **Controlling time**: YouTube-style speedup by holding `Space` or `Right-Click` for 2x speed with pitch correction.

---

## Features

- **Watch history**: Automatically logs recent videos to a local JSONL file. Replaying a video updates its progress and moves it to the top. Short clips or quick misclicks under 5 seconds are ignored.
- **Smart resume**: Reopening an unfinished video shows a quick prompt. Press `Enter` to resume, or `r` to start from the beginning (`00:00`). Auto-resumes after 10 seconds if untouched.
- **Direct resume in menu**: Selecting a video from the history menu resumes immediately without prompting. Hovering over the item reveals a `replay` action (or press `r`) to start from `00:00`.
- **Completion cutoff (95%)**: If you stop near the end of a video (past 95% or within the last 15 seconds), Janus treats it as completed and starts from `00:00` next time without prompting.
- **Resume from idle**: Press `Space` in an empty mpv window to immediately load and resume your last watched video.
- **Seek undo & redo (`Ctrl+Z` / `Ctrl+X`)**: Revert accidental timeline seeks or chapter jumps with jump delta and destination feedback (e.g. `↩ -0:45 (to 14:20)`). Rapid seeks within 1 second are grouped so one press reverts the entire sequence.
- **Hold to speed up (2.0x)**: Press and hold `Space` or `Right-Click` to temporarily play at 2x speed. Release to return to 1x. Quick taps play or pause as normal. Toggle 2x anytime with `Alt+n`.
- **Now playing indicator**: Highlights and marks the currently active video in both uosc and vanilla history menus.
- **Missing file detection**: Videos that were moved, deleted, or located on disconnected drives are marked with `[Deleted or Moved]`.
- **Prune & clear**: Remove all dead/missing files from history with **Prune Missing Files** (`p`), or wipe history completely with **Clear All History** (`c`). Both require confirmation.
- **uosc & vanilla OSD**: Native uosc menu with real-time full-history search and hover actions. Automatically falls back to a clean vanilla mpv OSD menu if uosc is not detected.
- **Unified keyboard navigation**: Both uosc and vanilla menus support arrow-key pagination (`←` / `→` or `h` / `l`), delete (`Del`), prune (`p`), clear (`c`), and restart (`r`).
- **Folder blacklist**: Exclude specific directories (downloads, temp folders, etc.) from history tracking via `ignore_paths`.
- **Universal stream & URL metadata**: Formats online streams and video URLs (YouTube, Twitch, Kick, Rumble, and direct media links) as `Author/Creator: Video Title (YYYY-MM-DD)` for mpv OSD and playback history. Universal resolver canonicalizes raw CDN links and queries metadata asynchronously via yt-dlp and platform APIs in the background without interrupting playback.
- **Instant discard (`Alt+d` / `Alt+DEL`)**: Remove the currently playing video from history immediately and disable tracking for the remainder of the session without interrupting playback.
- **Graceful shutdown hook**: Automatically commits playback position on player quit or shutdown even if mpv exits abruptly.

---

## Installation

Janus is a single-file Lua script with no external dependencies.

### 1. Copy `janus.lua` to your mpv scripts folder

```bash
# Linux / macOS
cp janus.lua ~/.config/mpv/scripts/

# Windows
# Copy janus.lua to %APPDATA%/mpv/scripts/
```

> **Note**: If you have `save-position-on-quit=yes` in your `mpv.conf`, you can disable or remove it. Janus saves timestamps automatically (every 15s, on pause, and on quit) and handles resuming without conflicts.

### 2. (Optional) Configuration file
To customize settings, copy `janus.conf` to your `script-opts` directory:

```bash
# Linux / macOS
cp janus.conf ~/.config/mpv/script-opts/

# Windows
# Copy janus.conf to %APPDATA%/mpv/script-opts/
```

---

## Keybindings

### Default Shortcuts

| Key | Binding | Action |
| :--- | :--- | :--- |
| **`h`** | `janus/open` | Open history menu (auto-detects uosc or vanilla OSD) |
| **`Alt+h`** | `janus/toggle-tracking` | Toggle history tracking on / off |
| **`Alt+d`** / **`Alt+DEL`** | `janus/forget-current` | Remove current file from history and stop tracking it |
| **`Ctrl+z`** | `janus/seek-undo` | Undo seek (jump back to previous position) |
| **`Ctrl+x`** | `janus/seek-redo` | Redo seek |
| **`Space`** | `janus/speed-hold` | Tap to play/pause (or resume last video when idle), hold for 2x speed |
| **`Right Click`** | `janus/speed-hold` | Tap to play/pause, hold for 2x speed |
| **`Alt+n`** | `janus/speed-toggle` | Toggle 2x speed on / off |
| **`Ctrl+r`** | `janus/play-last` | Resume most recently played video |
| **`H`** | `janus/history-vanilla` | Force open vanilla OSD menu |
| **`Ctrl+h`** | `janus/history-uosc` | Force open uosc menu |

### Customizing Keybindings (`input.conf`)

Add these lines to `~/.config/mpv/input.conf` to customize keys or add uosc menu entries:

```conf
# Open history menu
h               script-binding janus/open                       #! History > Playback History

# Toggle history recording
Alt+h           script-binding janus/toggle-tracking            #! History > Toggle History

# Forget current file (remove from history and stop tracking this session)
Alt+d           script-binding janus/forget-current             #! History > Forget Current File

# Seek undo and redo
ctrl+z          script-binding janus/seek-undo
ctrl+x          script-binding janus/seek-redo

# Hold for 2x speed (tap to play/pause, resumes last video on idle)
SPACE           script-binding janus/speed-hold
MBTN_RIGHT      script-binding janus/speed-hold

# Resume last played video
ctrl+r          script-binding janus/play-last

# Toggle 2x speed
Alt+n           script-binding janus/speed-toggle

# Open specific menu styles directly
H               script-binding janus/history-vanilla
ctrl+h          script-binding janus/history-uosc
```

### Adding a button to the uosc controls bar
If you use uosc and want a history button on the timeline control bar, add `command:history:script-binding janus/open?History` to `controls` in `~/.config/mpv/script-opts/uosc.conf`:

```conf
controls=menu,subtitles,<has_many_audio>audio,<has_many_video>video,items,command:history:script-binding janus/open?History,gap,space,speed,space,prev,items,next,gap,fullscreen
```

---

## Navigation & Controls

### Resume Prompt
When opening an unfinished video, a prompt appears:
- **`Enter`**: Resume from saved timestamp.
- **`r`** / **`b`** / **`Home`**: Play from the beginning (`00:00`).
- **`Esc`** / **`q`**: Dismiss prompt and continue playback from start.
- Seeking manually or pressing playback keys dismisses the prompt immediately.
- If left alone, it automatically resumes after 10 seconds.

### History Menu (uosc & Vanilla)
Both menu interfaces support the same navigation shortcuts:
- **`↑` / `↓`** (or **`k` / `j`**): Move selection up / down.
- **`Enter`** (or Click): Directly resume playback from saved timestamp.
- **`r`** (or **`replay`** icon): Restart playback from the beginning (`00:00`).
- **`y`** (or **`content_copy`** icon): Copy file path or stream URL to system clipboard.
- **`←` / `→`** (or **`h` / `l`**): Previous / next page.
- **`Del`** (or **`delete`** icon / **`Backspace`**): Remove selected item from history.
- **`p`**: Prune all missing/deleted files from history (with confirmation).
- **`c`**: Clear all history (with confirmation).
- **`Esc`** / **`q`**: Close menu (or cancel confirmation).

---

## Configuration (`janus.conf`)

Adjust options in `~/.config/mpv/script-opts/janus.conf`:

| Option | Default | Description |
| :--- | :--- | :--- |
| `enabled` | `yes` | Enable history logging |
| `history_file` | `~~/janus_history.jsonl` | History file location (`~~/` expands to mpv config dir) |
| `max_history` | `5000` | Maximum number of entries kept during compaction |
| `compaction_threshold` | `10000` | Log line count before pruning duplicate entries |
| `watch_threshold` | `5` | Seconds watched before a video is logged |
| `update_interval` | `15` | How often (in seconds) progress is saved while watching |
| `save_on_pause` | `yes` | Save timestamp when pausing |
| `log_urls` | `yes` | Log web streams (YouTube, Twitch, etc.) |
| `format_url_titles` | `yes` | Format URL titles as `Author: Title (YYYY-MM-DD)` |
| `fetch_url_metadata` | `yes` | Query yt-dlp asynchronously for missing URL metadata |
| `ytdl_path` | `yt-dlp` | Executable path for yt-dlp |
| `ignore_paths` | `""` | Comma- or semicolon-separated folders to ignore |
| `resume_offset` | `0` | Rewind offset in seconds when resuming |
| `ask_resume` | `yes` | Prompt to resume unfinished files |
| `resume_threshold` | `10` | Minimum saved seconds required before prompting to resume |
| `resume_end_threshold` | `15` | Seconds from end of file to consider video completed |
| `resume_end_percent` | `95` | Percent watched to consider video completed |
| `resume_skip_playlist` | `no` | Skip resume prompt when playlist auto-advances |
| `resume_timeout` | `10` | Seconds before auto-resuming (set `0` to wait indefinitely) |
| `resume_timeout_action` | `resume` | Action on timeout: `"resume"` or `"beginning"` |
| `resume_pause_on_prompt` | `yes` | Pause video while the resume prompt is visible |
| `play_last_on_idle` | `yes` | Resume last played video by pressing Space in an empty window |
| `seek_history_enabled` | `yes` | Enable `Ctrl+z` and `Ctrl+x` seek undo/redo |
| `seek_history_size` | `5` | Number of previous seek positions to store |
| `ui_mode` | `auto` | UI style: `"auto"` (uosc if available, else vanilla), `"uosc"`, or `"vanilla"` |
| `page_size` | `20` | History entries per page |
| `speed_enabled` | `yes` | Enable hold-to-speed on Space and Right Click |
| `speed_target` | `2.0` | Target playback speed multiplier while holding |
| `speed_delay` | `0.3` | Hold duration in seconds before speed activates |

---

## License

MIT
