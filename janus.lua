-- ============================================================================
-- Janus: History & Resume Plugin for mpv
--
-- Features:
--   - Fast and lightweight history log saved as json lines
--   - Loads history in pages from the end of the file so it stays fast
--   - Prompts to resume playback or start from the beginning
--   - Works with uosc menus or default mpv on-screen display
--   - Ignores short clips or skipped files to keep history tidy
--   - Toggle history tracking on or off anytime with Alt+h
-- ============================================================================

local mp = require("mp")
local msg = require("mp.msg")
local opt = require("mp.options")
local utils = require("mp.utils")

-- ============================================================================
-- 1. Configuration & Options
-- ============================================================================

local config = {
    -- State
    enabled = true,            -- Whether history tracking is enabled

    -- Storage
    history_file = "~~/janus_history.jsonl",
    max_history = 5000,
    compaction_threshold = 10000,

    -- Logging rules
    watch_threshold = 5,       -- Minimum seconds played before saving to history
    update_interval = 15,      -- Seconds between periodic progress updates
    save_on_pause = true,      -- Save current position when pausing
    log_urls = true,           -- Whether to record web URLs/streams
    resume_offset = 0,         -- Seconds before saved position when resuming
    ignore_paths = "",           -- Paths or folders to ignore (semicolon or comma separated)

    -- Resume prompt
    ask_resume = true,                 -- Ask to resume playback when loading a file
    resume_threshold = 10,             -- Minimum saved position (seconds) to trigger prompt
    resume_end_threshold = 15,         -- Ignore if within this many seconds from duration end
    resume_end_percent = 95,           -- Ignore if progress is past this percentage (95% rule)
    resume_skip_playlist = false,      -- Skip resume prompt on playlist auto-advance
    resume_timeout = 10,               -- Countdown timeout in seconds (0 to disable)
    resume_timeout_action = "resume",  -- Action on timeout: "resume" or "beginning"
    resume_pause_on_prompt = true,     -- Pause playback while resume prompt is active

    -- Interface
    ui_mode = "auto",          -- "auto", "uosc", or "vanilla"
    page_size = 20,            -- Number of items per history page

    -- Hold to speed up (YouTube style)
    speed_enabled = true,      -- Hold Spacebar to temporarily speed up
    speed_target = 2.0,        -- Playback speed multiplier while holding
    speed_delay = 0.3,         -- Seconds to hold before speeding up activates

    -- Playback on idle
    play_last_on_idle = true,  -- Play last video from history when pressing play while idle
}

opt.read_options(config, "janus")
local history_path = mp.command_native({"expand-path", config.history_file})
local tracking_enabled = config.enabled

-- ============================================================================
-- 2. Helpers
-- ============================================================================

-- Format seconds into MM:SS or HH:MM:SS
local function format_duration(seconds)
    if not seconds or seconds < 0 or seconds ~= seconds then
        return "00:00"
    end
    seconds = math.floor(seconds + 0.5)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

-- Convert timestamp to friendly relative time (e.g. 5 mins ago, 2 hrs ago)
local function format_relative_time(epoch, now)
    if not epoch or epoch <= 0 then return "" end
    now = now or os.time()
    local diff = now - epoch
    if diff < 0 then diff = 0 end

    if diff < 60 then
        return "Just now"
    elseif diff < 3600 then
        local mins = math.floor(diff / 60)
        return mins .. (mins == 1 and " min ago" or " mins ago")
    elseif diff < 86400 then
        local hours = math.floor(diff / 3600)
        return hours .. (hours == 1 and " hr ago" or " hrs ago")
    elseif diff < 604800 then
        local days = math.floor(diff / 86400)
        return days .. (days == 1 and " day ago" or " days ago")
    else
        return os.date("%b %d, %Y", epoch)
    end
end

-- Get file name from full path
local function get_filename(path)
    if not path or path == "" then return "Unknown" end
    local cleaned = path:gsub("[/\\]+$", "")
    local name = cleaned:match("([^/\\]+)$")
    return name or path
end

-- Check if path is a web stream or URL
local function is_url(path)
    if not path then return false end
    return path:match("^%a[%w+.-]*://") ~= nil
end

-- Check if a local file exists on disk
local function file_exists(path)
    if not path or path == "" then return false end
    if is_url(path) then return true end
    local expanded = mp.command_native({"expand-path", path})
    local info = utils.file_info(expanded)
    return info ~= nil
end

-- Add unicode strikethrough to a string (for uosc rendering)
local function strikethrough(str)
    if not str or str == "" then return "" end
    local res = {}
    local combining = string.char(204, 182)
    local char_pat = "[%z" .. string.char(1) .. "-" .. string.char(127) .. string.char(194) .. "-" .. string.char(244) .. "][" .. string.char(128) .. "-" .. string.char(191) .. "]*"
    for uchar in str:gmatch(char_pat) do
        table.insert(res, uchar .. combining)
    end
    return table.concat(res)
end

-- Check if a path matches ignored folder or directory patterns
local function should_ignore_path(path)
    if not path or path == "" then return true end
    if config.ignore_paths and config.ignore_paths ~= "" then
        local lower_path = path:lower()
        for pattern in string.gmatch(config.ignore_paths, "[^;,]+") do
            local trimmed = pattern:match("^%s*(.-)%s*$"):lower()
            if trimmed ~= "" and lower_path:find(trimmed, 1, true) then
                return true
            end
        end
    end
    return false
end

-- Escape characters for safe ASS text rendering
local function escape_ass(text)
    if not text then return "" end
    local escaped = tostring(text)
    escaped = escaped:gsub("\\", "\\\239\187\191")
    escaped = escaped:gsub("{", "\\{")
    escaped = escaped:gsub("}", "\\}")
    return escaped
end

-- Shorten long titles with an ellipsis
local function truncate_string(str, max_len)
    if not str then return "" end
    if #str <= max_len then return str end
    return str:sub(1, max_len - 3) .. "..."
end

-- Toggle history tracking on or off
local function toggle_tracking()
    tracking_enabled = not tracking_enabled
    local status = tracking_enabled and "enabled" or "disabled"
    mp.osd_message(string.format("Janus: History tracking %s", status), 2)
    msg.info(string.format("Janus: History tracking %s", status))
end

-- ============================================================================
-- 3. History Storage (JSON Lines File)
-- ============================================================================

local storage = {
    append_count = 0,
}

-- Create folder if it doesn't exist yet
local function ensure_dir(path)
    local dir = path:match("^(.*)[/\\]")
    if not dir or dir == "" then return end
    mp.command_native({
        name = "subprocess",
        args = {"mkdir", "-p", dir},
        playback_only = false,
        capture_stdout = false,
        capture_stderr = false,
    })
end

-- Append a video entry to the history file
function storage.append(entry)
    if not entry or not entry.path then return false end
    ensure_dir(history_path)

    local f, err = io.open(history_path, "a")
    if not f then
        msg.error("Janus: Failed to open history file: " .. tostring(err))
        return false
    end

    f:write(utils.format_json(entry) .. "\n")
    f:close()

    storage.append_count = storage.append_count + 1
    if storage.append_count >= 500 then
        storage.check_compaction()
    end
    return true
end

-- Read lines from the end of the file backwards to load pages quickly
local function reverse_scan_lines(chunk_size, callback)
    local f = io.open(history_path, "rb")
    if not f then return end

    local file_size = f:seek("end")
    if not file_size or file_size == 0 then
        f:close()
        return
    end

    chunk_size = chunk_size or 8192
    local pos = file_size
    local buffer = ""

    while pos > 0 do
        local read_len = math.min(pos, chunk_size)
        pos = pos - read_len
        f:seek("set", pos)
        local chunk = f:read(read_len)
        if not chunk then break end
        buffer = chunk .. buffer

        while true do
            local nl_pos = buffer:match("^.*()\n")
            if not nl_pos then break end
            local line = buffer:sub(nl_pos + 1)
            buffer = buffer:sub(1, nl_pos - 1)

            if line:sub(-1) == "\r" then line = line:sub(1, -2) end
            if line ~= "" and not line:match("^%s*$") then
                if callback(line) then
                    f:close()
                    return
                end
            end
        end
    end

    if #buffer > 0 then
        if buffer:sub(-1) == "\r" then buffer = buffer:sub(1, -2) end
        if buffer ~= "" and not buffer:match("^%s*$") then
            callback(buffer)
        end
    end

    f:close()
end

-- Load a single page of history entries
function storage.get_page(page, page_size)
    page = math.max(1, tonumber(page) or 1)
    page_size = math.max(1, tonumber(page_size) or config.page_size)

    local start_idx = (page - 1) * page_size + 1
    local end_idx = page * page_size

    local items = {}
    local seen = {}
    local unique_count = 0
    local has_next = false

    reverse_scan_lines(8192, function(line)
        local ok_json, entry = pcall(utils.parse_json, line)
        if ok_json and type(entry) == "table" and entry.path then
            if not seen[entry.path] then
                seen[entry.path] = true
                if not entry.deleted then
                    unique_count = unique_count + 1
                    if unique_count >= start_idx and unique_count <= end_idx then
                        table.insert(items, entry)
                    elseif unique_count > end_idx then
                        has_next = true
                        return true
                    end
                end
            end
        end
    end)

    return {
        items = items,
        page = page,
        page_size = page_size,
        has_prev = (page > 1),
        has_next = has_next,
    }
end

-- Find the most recent record for a specific video
function storage.get_entry(target_path)
    if not target_path or target_path == "" then return nil end
    local result = nil

    reverse_scan_lines(8192, function(line)
        local ok_json, entry = pcall(utils.parse_json, line)
        if ok_json and type(entry) == "table" and entry.path == target_path then
            if not entry.deleted then
                result = entry
            end
            return true
        end
    end)

    return result
end

-- Mark an item as deleted in the log
function storage.remove(target_path)
    if not target_path or target_path == "" then return false end
    return storage.append({
        path = target_path,
        deleted = true,
        time = os.time(),
    })
end

-- Clear all history
function storage.clear()
    local f = io.open(history_path, "w")
    if f then
        f:close()
        storage.append_count = 0
        return true
    end
    return false
end

-- Clean up duplicate entries and keep the history file tidy
function storage.compact()
    local entries = {}
    local seen = {}

    reverse_scan_lines(8192, function(line)
        local ok_json, entry = pcall(utils.parse_json, line)
        if ok_json and type(entry) == "table" and entry.path then
            if not seen[entry.path] then
                seen[entry.path] = true
                if not entry.deleted then
                    table.insert(entries, entry)
                    if #entries >= config.max_history then
                        return true
                    end
                end
            end
        end
    end)

    local count = #entries
    for i = 1, math.floor(count / 2) do
        entries[i], entries[count - i + 1] = entries[count - i + 1], entries[i]
    end

    local tmp_path = history_path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then return false end

    for _, item in ipairs(entries) do
        f:write(utils.format_json(item) .. "\n")
    end
    f:close()

    if not os.rename(tmp_path, history_path) then
        mp.command_native({
            name = "subprocess",
            args = {"mv", "-f", tmp_path, history_path},
            playback_only = false,
        })
    end

    storage.append_count = 0
    return true, count
end

-- Check if history has grown large enough to need cleanup
function storage.check_compaction()
    local f = io.open(history_path, "r")
    if not f then return end
    local lines = 0
    for _ in f:lines() do lines = lines + 1 end
    f:close()

    if lines >= config.compaction_threshold then
        storage.compact()
    end
end

-- ============================================================================
-- 4. Playback Tracking
-- ============================================================================

---@class Tracker
---@field current table
---@field timer? any
---@field is_paused boolean
local tracker = {
    current = {
        path = nil,
        title = nil,
        pos = 0,
        duration = 0,
        watch_time = 0,
        qualified = false,
    },
    timer = nil,
    is_paused = false,
}

---@class ResumePrompter
---@field is_active boolean
---@field target_pos number
---@field original_paused boolean
---@field remaining_seconds number
---@field timer? any
---@field overlay? any
---@field key_bindings table<string, boolean>
---@field handle_action? fun(action: string)
---@field check? fun(path: string)
---@field cancel? fun()
local resume_prompter

-- Save current video info to history
local function record_history(entry)
    if not tracking_enabled or not entry or not entry.path or should_ignore_path(entry.path) then return false end
    if not entry.title or entry.title == "" then
        entry.title = get_filename(entry.path)
    end
    entry.time = entry.time or os.time()
    entry.pos = math.floor((entry.pos or 0) * 10) / 10
    entry.duration = math.floor(entry.duration or 0)

    return storage.append(entry)
end

-- Load and play a file from history
local function play_history_item(item)
    if not item or not item.path then return end

    if not is_url(item.path) and not file_exists(item.path) then
        mp.osd_message("Janus: File has been moved or deleted", 3)
        msg.warn("Janus: Cannot play, file has been moved or deleted: " .. item.path)
        return
    end
    local pos = item.pos or 0
    local start_pos = math.max(0, pos - config.resume_offset)

    -- If position is right near the end (15s or 95% finished), start from beginning instead
    if item.duration and item.duration > 0 then
        local remaining = item.duration - start_pos
        local percent = (start_pos / item.duration) * 100
        if remaining < config.resume_end_threshold or percent >= config.resume_end_percent then
            start_pos = 0
        end
    end

    local current_path = mp.get_property("path")
    if current_path and (current_path == item.path or current_path == mp.command_native({"expand-path", item.path})) then
        if start_pos > 0 then
            mp.commandv("seek", tostring(start_pos), "absolute", "exact")
        else
            mp.commandv("seek", "0", "absolute", "exact")
        end
        return
    end

    if start_pos > 0 then
        mp.commandv("loadfile", item.path, "replace", "-1", "start=" .. tostring(start_pos))
    else
        mp.commandv("loadfile", item.path, "replace")
    end
end

-- Resume the most recent valid video from history
local function play_last_played()
    local page = storage.get_page(1, 10)
    if not page or not page.items or #page.items == 0 then
        mp.osd_message("Janus: No history entries found", 2)
        return
    end

    local item = nil
    for _, candidate in ipairs(page.items) do
        if is_url(candidate.path) or file_exists(candidate.path) then
            item = candidate
            break
        end
    end

    if not item then
        mp.osd_message("Janus: Recent videos were moved or deleted", 3)
        return
    end

    local name = item.title or get_filename(item.path)
    mp.osd_message("Janus: Resuming " .. name, 2)
    play_history_item(item)
end

-- Save current playback position
local function tracker_save()
    if not tracking_enabled or resume_prompter.is_active or not tracker.current.path or not tracker.current.qualified or should_ignore_path(tracker.current.path) then
        return
    end

    tracker.current.pos = mp.get_property_number("time-pos", tracker.current.pos) or tracker.current.pos
    tracker.current.duration = mp.get_property_number("duration", tracker.current.duration) or tracker.current.duration
    local title = mp.get_property("media-title")
    if title and title ~= "" then
        tracker.current.title = title
    end

    record_history({
        path = tracker.current.path,
        title = tracker.current.title,
        pos = tracker.current.pos,
        duration = tracker.current.duration,
        time = os.time(),
    })
end

-- Heartbeat timer: counts active watch time
local function tracker_on_tick()
    if not tracking_enabled or resume_prompter.is_active or tracker.is_paused or not tracker.current.path or should_ignore_path(tracker.current.path) then
        return
    end

    tracker.current.watch_time = tracker.current.watch_time + 1

    -- Qualify for history once minimum threshold is met
    if not tracker.current.qualified and tracker.current.watch_time >= config.watch_threshold then
        tracker.current.qualified = true
        tracker_save()
    elseif tracker.current.qualified and (tracker.current.watch_time % config.update_interval == 0) then
        tracker_save()
    end
end

-- ============================================================================
-- 5. Resume Prompt (uosc & Vanilla OSD)
-- ============================================================================

local ui = { has_uosc = false } -- Forward declaration

resume_prompter = {
    is_active = false,
    target_pos = 0,
    original_paused = false,
    remaining_seconds = 10,
    timer = nil,
    overlay = nil,
    key_bindings = {},
}

local function resume_remove_keys()
    for name, _ in pairs(resume_prompter.key_bindings) do
        mp.remove_key_binding(name)
    end
    resume_prompter.key_bindings = {}
end

-- Close prompt and clean up timer / keys
local function resume_close_ui()
    if resume_prompter.timer then
        resume_prompter.timer:kill()
        resume_prompter.timer = nil
    end

    if ui.has_uosc and config.ui_mode ~= "vanilla" then
        mp.commandv("script-message-to", "uosc", "close-menu", "janus_resume")
    end

    resume_remove_keys()
    if resume_prompter.overlay then
        resume_prompter.overlay:remove()
    end

    resume_prompter.is_active = false
end

-- Show centered resume prompt on screen for vanilla mpv
local function resume_render_vanilla()
    if not resume_prompter.is_active then return end
    if not resume_prompter.overlay then
        resume_prompter.overlay = mp.create_osd_overlay("ass-events")
    end

    local pos_str = format_duration(resume_prompter.target_pos)
    local timeout_text = ""
    if resume_prompter.remaining_seconds > 0 then
        local action_name = config.resume_timeout_action == "beginning" and "starting from beginning" or "resuming"
        timeout_text = string.format("{\\fs14\\c&H888888&}Auto-%s in %ds...\\N", action_name, resume_prompter.remaining_seconds)
    end

    resume_prompter.overlay.data = string.format(
        "{\\an5\\bord2\\shad2\\fs20\\c&HFFFFFF&}"
        .. "{\\b1\\fs26\\c&H00D7FF&}RESUME PLAYBACK?{\\c&HFFFFFF&\\b0}\\N\\N"
        .. "{\\fs18\\c&HD0D0D0&}Saved position: {\\b1\\c&H00FFFF&}%s{\\c&HD0D0D0&\\b0}\\N\\N"
        .. "{\\fs16\\c&HFFFFFF&}[Enter] {\\b1}Resume{\\b0}      [r] {\\b1}Beginning{\\b0}      [Esc] {\\b1}Dismiss{\\b0}\\N\\N"
        .. "%s",
        pos_str,
        timeout_text
    )
    resume_prompter.overlay:update()
end

-- Build prompt menu items for uosc
local function resume_build_uosc_menu()
    local pos_str = format_duration(resume_prompter.target_pos)
    local action_name = config.resume_timeout_action == "beginning" and "beginning" or "resuming"
    local footnote = resume_prompter.remaining_seconds > 0
        and string.format("Auto-%s in %ds  •  Esc to dismiss", action_name, resume_prompter.remaining_seconds)
        or "Esc to dismiss"

    return {
        type = "janus_resume",
        title = "Resume Playback?",
        footnote = footnote,
        items = {
            {
                title = "Resume at " .. pos_str,
                hint = "Saved position",
                icon = "play_arrow",
                bold = true,
                value = {"script-message-to", "janus", "resume-action", "resume"},
            },
            {
                title = "Start from beginning",
                hint = "00:00",
                icon = "replay",
                value = {"script-message-to", "janus", "resume-action", "beginning"},
            },
        },
    }
end

-- Handle resume action chosen by user or timeout
function resume_prompter.handle_action(action)
    if not resume_prompter.is_active then return end

    local target = resume_prompter.target_pos
    local orig_paused = resume_prompter.original_paused
    local paused_by_prompt = config.resume_pause_on_prompt

    resume_close_ui()

    if action == "resume" then
        local seek_pos = math.max(0, target - config.resume_offset)
        mp.commandv("seek", tostring(seek_pos), "absolute", "exact")
        if paused_by_prompt then mp.set_property_bool("pause", false) end
    elseif action == "beginning" then
        mp.commandv("seek", "0", "absolute", "exact")
        if paused_by_prompt then mp.set_property_bool("pause", false) end
    elseif action == "dismiss" then
        if paused_by_prompt then mp.set_property_bool("pause", orig_paused) end
    end
end

-- Countdown timer tick for resume prompt
local function resume_on_tick()
    if not resume_prompter.is_active then return end
    resume_prompter.remaining_seconds = resume_prompter.remaining_seconds - 1

    if resume_prompter.remaining_seconds <= 0 then
        resume_prompter.handle_action(config.resume_timeout_action)
        return
    end

    if ui.has_uosc and config.ui_mode ~= "vanilla" then
        mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(resume_build_uosc_menu()))
    else
        resume_render_vanilla()
    end
end

-- Check if opened video has saved progress and show prompt if so
function resume_prompter.check(path)
    if not config.ask_resume or not path or path == "" or should_ignore_path(path) then return end
    if not config.log_urls and is_url(path) then return end

    if config.resume_skip_playlist then
        local playlist_pos = mp.get_property_number("playlist-pos", 0)
        if playlist_pos > 0 then return end
    end

    local entry = storage.get_entry(path)
    if not entry or not entry.pos then return end

    local pos = tonumber(entry.pos) or 0
    if pos < config.resume_threshold then return end

    local duration = tonumber(entry.duration) or 0
    if duration > 0 then
        local remaining = duration - pos
        local percent = (pos / duration) * 100
        if remaining < config.resume_end_threshold or percent >= config.resume_end_percent then
            return
        end
    end

    local current_pos = mp.get_property_number("time-pos", 0)
    if math.abs(current_pos - pos) < 2 then return end

    resume_prompter.is_active = true
    resume_prompter.target_pos = pos
    resume_prompter.original_paused = mp.get_property_bool("pause", false)
    resume_prompter.remaining_seconds = config.resume_timeout

    if config.resume_pause_on_prompt then
        mp.set_property_bool("pause", true)
    end

    if resume_prompter.remaining_seconds > 0 then
        resume_prompter.timer = mp.add_periodic_timer(1, resume_on_tick)
    end

    if ui.has_uosc and config.ui_mode ~= "vanilla" then
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(resume_build_uosc_menu()))
    else
        local function bind(key, name, fn)
            resume_prompter.key_bindings[name] = true
            mp.add_forced_key_binding(key, name, fn)
        end
        bind("ENTER", "janus_prompt_enter", function() resume_prompter.handle_action("resume") end)
        bind("r", "janus_prompt_r", function() resume_prompter.handle_action("beginning") end)
        bind("b", "janus_prompt_b", function() resume_prompter.handle_action("beginning") end)
        bind("HOME", "janus_prompt_home", function() resume_prompter.handle_action("beginning") end)
        bind("ESC", "janus_prompt_esc", function() resume_prompter.handle_action("dismiss") end)
        bind("q", "janus_prompt_q", function() resume_prompter.handle_action("dismiss") end)

        resume_render_vanilla()
    end
end

-- Cancel prompt if file ends or changes
function resume_prompter.cancel()
    if resume_prompter.is_active then
        resume_close_ui()
    end
end

-- ============================================================================
-- 6. History Menus (uosc & Vanilla OSD)
-- ============================================================================

---@class VanillaMenu
---@field is_open boolean
---@field current_page number
---@field page_data? any
---@field selected_index number
---@field overlay? any
---@field key_bindings table<string, boolean>
---@field open? fun()
---@field close? fun()
local vanilla_menu = {
    is_open = false,
    current_page = 1,
    page_data = nil,
    selected_index = 1,
    overlay = nil,
    key_bindings = {},
}

-- Render history list on screen
local function vanilla_render()
    if not vanilla_menu.is_open then return end
    if not vanilla_menu.overlay then
        vanilla_menu.overlay = mp.create_osd_overlay("ass-events")
    end

    local page = vanilla_menu.page_data or { items = {}, page = 1, has_prev = false, has_next = false }
    local items = page.items
    local now = os.time()

    local lines = {"{\\an7\\fs16\\bord1.5\\shad1}"}
    local header = string.format(
        "{\\b1\\fs22\\c&H00D7FF&}JANUS HISTORY{\\c&HFFFFFF&\\b0\\fs16}  —  Page %d %s%s\n\\N",
        vanilla_menu.current_page,
        page.has_prev and "{\\c&H00D7FF&}◀ [Left]{\\c&HFFFFFF&} " or "   ",
        page.has_next and "{\\c&H00D7FF&}[Right] ▶{\\c&HFFFFFF&}" or ""
    )
    table.insert(lines, header)

    if #items == 0 then
        table.insert(lines, "{\\c&H888888&}   (No history entries found)\\N\\N")
    else
        for i, item in ipairs(items) do
            local is_selected = (i == vanilla_menu.selected_index)
            local prefix = is_selected and "{\\b1\\c&H00FFFF&} ▶ " or "{\\c&H888888&}   "
            local title = escape_ass(truncate_string(item.title or get_filename(item.path), 55))
            local title_color = is_selected and "{\\c&HFFFFFF&\\b1}" or "{\\c&HD0D0D0&\\b0}"

            local exists = file_exists(item.path)
            local pos_str = format_duration(item.pos or 0)
            local dur_str = format_duration(item.duration or 0)
            local rel_time = format_relative_time(item.time, now)

            if not exists then
                title = string.format("{\\s1}%s{\\s0} {\\c&HFF6666&}[Deleted or Moved]", title)
                title_color = "{\\c&H888888&}"
            end
            local meta = string.format("{\\c&H999999&\\fs14}  [%s / %s]  •  %s", pos_str, dur_str, rel_time)

            table.insert(lines, string.format("%s%s%s%s\\N", prefix, title_color, title, meta))
        end
        table.insert(lines, "\\N")
    end

    local footer = "{\\fs14\\c&H777777&}------------------------------------------------------------\\N"
        .. "{\\fs14\\c&HAAAAAA&}[↑/↓] Select   [Enter] Play   [←/→] Page   [Del] Delete   [Esc/q] Close"
    table.insert(lines, footer)

    vanilla_menu.overlay.data = table.concat(lines)
    vanilla_menu.overlay:update()
end

-- Refresh current page contents
local function vanilla_refresh()
    vanilla_menu.page_data = storage.get_page(vanilla_menu.current_page)
    local items = vanilla_menu.page_data.items
    if #items > 0 then
        if vanilla_menu.selected_index > #items then
            vanilla_menu.selected_index = #items
        elseif vanilla_menu.selected_index < 1 then
            vanilla_menu.selected_index = 1
        end
    else
        vanilla_menu.selected_index = 1
    end
    vanilla_render()
end

-- Close the on-screen menu
function vanilla_menu.close()
    if not vanilla_menu.is_open then return end
    vanilla_menu.is_open = false
    for name, _ in pairs(vanilla_menu.key_bindings) do
        mp.remove_key_binding(name)
    end
    vanilla_menu.key_bindings = {}
    if vanilla_menu.overlay then
        vanilla_menu.overlay:remove()
    end
end

-- Open the on-screen menu
function vanilla_menu.open()
    if vanilla_menu.is_open then
        vanilla_menu.close()
        return
    end

    vanilla_menu.is_open = true
    vanilla_menu.current_page = 1
    vanilla_menu.selected_index = 1

    local function bind(key, name, fn)
        vanilla_menu.key_bindings[name] = true
        mp.add_forced_key_binding(key, name, fn)
    end

    bind("UP", "janus_v_up", function()
        local count = vanilla_menu.page_data and #vanilla_menu.page_data.items or 0
        if count > 0 then
            vanilla_menu.selected_index = math.max(1, vanilla_menu.selected_index - 1)
            vanilla_render()
        end
    end)
    bind("DOWN", "janus_v_down", function()
        local count = vanilla_menu.page_data and #vanilla_menu.page_data.items or 0
        if count > 0 then
            vanilla_menu.selected_index = math.min(count, vanilla_menu.selected_index + 1)
            vanilla_render()
        end
    end)
    bind("k", "janus_v_k", function() mp.commandv("keypress", "UP") end)
    bind("j", "janus_v_j", function() mp.commandv("keypress", "DOWN") end)
    bind("LEFT", "janus_v_left", function()
        if vanilla_menu.current_page > 1 then
            vanilla_menu.current_page = vanilla_menu.current_page - 1
            vanilla_menu.selected_index = 1
            vanilla_refresh()
        end
    end)
    bind("RIGHT", "janus_v_right", function()
        if vanilla_menu.page_data and vanilla_menu.page_data.has_next then
            vanilla_menu.current_page = vanilla_menu.current_page + 1
            vanilla_menu.selected_index = 1
            vanilla_refresh()
        end
    end)
    bind("h", "janus_v_h", function() mp.commandv("keypress", "LEFT") end)
    bind("l", "janus_v_l", function() mp.commandv("keypress", "RIGHT") end)
    bind("ENTER", "janus_v_enter", function()
        local items = vanilla_menu.page_data and vanilla_menu.page_data.items or {}
        local item = items[vanilla_menu.selected_index]
        if item then
            if not is_url(item.path) and not file_exists(item.path) then
                mp.osd_message("Janus: File has been moved or deleted", 3)
                return
            end
            vanilla_menu.close()
            play_history_item(item)
        end
    end)
    bind("DEL", "janus_v_del", function()
        local items = vanilla_menu.page_data and vanilla_menu.page_data.items or {}
        local item = items[vanilla_menu.selected_index]
        if item then
            storage.remove(item.path)
            vanilla_refresh()
        end
    end)
    bind("BS", "janus_v_bs", function() mp.commandv("keypress", "DEL") end)
    bind("ESC", "janus_v_esc", vanilla_menu.close)
    bind("q", "janus_v_q", vanilla_menu.close)

    vanilla_refresh()
end

-- uosc menu integration
local uosc_menu = {
    current_page = 1,
}

-- Build menu structure for uosc
local function uosc_build_menu(page_num)
    uosc_menu.current_page = page_num
    local page_data = storage.get_page(page_num)
    local items = page_data.items
    local now = os.time()
    local menu_items = {}

    if #items == 0 then
        table.insert(menu_items, {
            title = "No history entries found",
            italic = true,
            align = "center",
            selectable = false,
        })
    else
        for _, item in ipairs(items) do
            local title = item.title or get_filename(item.path)
            local exists = file_exists(item.path)
            local pos_str = format_duration(item.pos or 0)
            local dur_str = format_duration(item.duration or 0)
            local rel_time = format_relative_time(item.time, now)

            local display_title = exists and title or strikethrough(title)
            local hint_str = exists
                and string.format("%s / %s  •  %s", pos_str, dur_str, rel_time)
                title = string.format("{\\s1}%s{\\s0} {\\c&HFF6666&}[Deleted or Moved]", title)
                title_color = "{\\c&H888888&}"
            table.insert(menu_items, {
                title = display_title,
                hint = hint_str,
                icon = exists and "history" or "error",
                muted = not exists,
                value = {
                    action = "play",
                    path = item.path,
                    pos = tonumber(item.pos) or 0,
                    duration = tonumber(item.duration) or 0,
                    missing = not exists,
                },
                actions = {
                    {
                        name = "delete",
                        icon = "delete",
                        label = "Delete from history",
                    },
                },
            })
        end
    end

    if page_data.has_prev then
        table.insert(menu_items, {
            title = string.format("◀ Previous Page (Page %d)", page_num - 1),
            icon = "navigate_before",
            align = "center",
            bold = true,
            keep_open = true,
            value = {
                action = "page",
                page = page_num - 1,
            },
        })
    end

    if page_data.has_next then
        table.insert(menu_items, {
            title = string.format("Next Page ▶ (Page %d)", page_num + 1),
            icon = "navigate_next",
            align = "center",
            bold = true,
            keep_open = true,
            value = {
                action = "page",
                page = page_num + 1,
            },
        })
    end

    return {
        type = "janus_history",
        title = string.format("History — Page %d", page_num),
        callback = {"janus", "uosc-event"},
        items = menu_items,
    }
end

function uosc_menu.open(page_num)
    page_num = page_num or 1
    uosc_menu.current_page = page_num
    local json = utils.format_json(uosc_build_menu(page_num))
    mp.commandv("script-message-to", "uosc", "open-menu", json)
end

function uosc_menu.update(page_num)
    page_num = page_num or uosc_menu.current_page or 1
    uosc_menu.current_page = page_num
    local json = utils.format_json(uosc_build_menu(page_num))
    mp.commandv("script-message-to", "uosc", "update-menu", json)
end

-- Open history using uosc if available or vanilla OSD as fallback
function ui.open(page_num)
    local mode = config.ui_mode or "auto"
    if mode == "vanilla" then
        vanilla_menu.open()
    elseif mode == "uosc" then
        uosc_menu.open(page_num or 1)
    else
        if ui.has_uosc then
            uosc_menu.open(page_num or 1)
        else
            vanilla_menu.open()
        end
    end
end

-- Toggle history menu
function ui.toggle()
    local mode = config.ui_mode or "auto"
    if mode == "vanilla" or (mode == "auto" and not ui.has_uosc) then
        if vanilla_menu.is_open then
            vanilla_menu.close()
        else
            vanilla_menu.open()
        end
    else
        uosc_menu.open(1)
    end
end

-- ============================================================================
-- 7. mpv Events
-- ============================================================================

mp.register_script_message("uosc-version", function()
    ui.has_uosc = true
end)

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path or path == "" or should_ignore_path(path) then
        tracker.current.path = nil
        return
    end

    if not config.log_urls and is_url(path) then
        tracker.current.path = nil
        return
    end

    local title = mp.get_property("media-title") or get_filename(path)
    local duration = mp.get_property_number("duration", 0) or 0
    local pos = mp.get_property_number("time-pos", 0) or 0

    tracker.current = {
        path = path,
        title = title,
        pos = pos,
        duration = duration,
        watch_time = 0,
        qualified = false,
    }

    tracker.is_paused = mp.get_property_bool("pause", false)

    resume_prompter.check(path)

    if config.watch_threshold <= 0 and not resume_prompter.is_active then
        tracker.current.qualified = true
        tracker_save()
    end
end)

mp.observe_property("pause", "bool", function(_, paused)
    tracker.is_paused = paused
    if not resume_prompter.is_active and paused and config.save_on_pause and tracker.current.qualified then
        tracker_save()
    end
end)

mp.register_event("end-file", function()
    if speed_state and speed_state.is_speeding then
        speed_deactivate()
    end
    resume_prompter.cancel()
    if tracker.current.qualified then
        tracker_save()
    end
    tracker.current.path = nil
    tracker.current.qualified = false
    tracker.current.watch_time = 0
end)

tracker.timer = mp.add_periodic_timer(1, tracker_on_tick)

-- ============================================================================
-- 8. Hold to Speed Up (YouTube Style)
-- ============================================================================

---@class SpeedState
---@field is_speeding boolean
---@field was_paused boolean
---@field normal_speed number
---@field timer any
---@field orig_pitch_correction? boolean
local speed_state = {
    is_speeding = false,
    was_paused = false,
    normal_speed = 1.0,
    timer = nil,
    orig_pitch_correction = nil,
}

local is_speed_toggled = false

local function speed_activate(is_toggle)
    speed_state.is_speeding = true
    speed_state.normal_speed = mp.get_property_native("speed") or 1.0
    speed_state.was_paused = mp.get_property_native("pause") or false

    -- Safeguard: ensure audio pitch correction is enabled during speed-up
    speed_state.orig_pitch_correction = mp.get_property_native("audio-pitch-correction")
    if speed_state.orig_pitch_correction == false then
        mp.set_property_native("audio-pitch-correction", true)
    end

    if speed_state.was_paused then
        mp.set_property_native("pause", false)
    end

    mp.set_property("speed", config.speed_target)
    if is_toggle then
        mp.osd_message(string.format("⏩ %.1fx Speed (Toggled)", config.speed_target), 99999)
        is_speed_toggled = true
    else
        mp.osd_message(string.format("⏩ %.1fx Speed", config.speed_target), 99999)
    end
end

local function speed_deactivate()
    if speed_state.timer then
        speed_state.timer:kill()
        speed_state.timer = nil
    end

    if speed_state.is_speeding then
        mp.set_property("speed", speed_state.normal_speed)
        if speed_state.orig_pitch_correction == false then
            mp.set_property_native("audio-pitch-correction", false)
        end
        if speed_state.was_paused then
            mp.set_property_native("pause", true)
        end
        mp.osd_message("▶️ Normal Speed", 1)
        speed_state.is_speeding = false
    end
    is_speed_toggled = false
end

local is_idle_resuming = false

local function handle_speed_key(event)
    if not config.speed_enabled then return end
    if resume_prompter.is_active or vanilla_menu.is_open then return end

    if is_idle_resuming then
        if event.event == "up" then
            is_idle_resuming = false
        end
        return
    end

    local current_path = mp.get_property("path")
    if not current_path or current_path == "" then
        if event.event == "down" and config.play_last_on_idle then
            is_idle_resuming = true
            play_last_played()
        end
        return
    end

    if event.event == "down" then
        if not speed_state.timer and not speed_state.is_speeding then
            speed_state.timer = mp.add_timeout(config.speed_delay, speed_activate)
        end
    elseif event.event == "up" then
        if speed_state.timer then
            speed_state.timer:kill()
            speed_state.timer = nil
        end

        if speed_state.is_speeding then
            speed_deactivate()
        else
            -- Quick tap (under speed_delay): toggle play/pause
            local paused = mp.get_property_native("pause")
            mp.set_property_native("pause", not paused)
        end
    end
end

local function toggle_speed()
    if is_speed_toggled or speed_state.is_speeding then
        speed_deactivate()
    else
        speed_activate(true)
    end
end

-- ============================================================================
-- 9. Keybindings & Script Messages
-- ============================================================================

-- Keybindings (defaults: 'h' opens history, 'Alt+h' toggles tracking, Space/Right-Click hold to speed, Alt+n toggle)
mp.add_key_binding("h", "open", function() ui.open() end)
mp.add_key_binding("Alt+h", "toggle-tracking", toggle_tracking)
if config.speed_enabled then
    mp.add_forced_key_binding("SPACE", "speed-hold-space", handle_speed_key, {complex = true})
    mp.add_forced_key_binding("MBTN_RIGHT", "speed-hold-mouse", handle_speed_key, {complex = true})
    mp.add_forced_key_binding("Alt+n", "speed-toggle-key", toggle_speed)
end
mp.add_key_binding(nil, "speed-hold", handle_speed_key, {complex = true})
mp.add_key_binding(nil, "speed-toggle", toggle_speed)
mp.add_key_binding(nil, "play-last", play_last_played)
mp.add_key_binding(nil, "toggle", function() ui.toggle() end)
mp.add_key_binding(nil, "history", function() ui.open() end)
mp.add_key_binding(nil, "history-vanilla", function() vanilla_menu.open() end)
mp.add_key_binding(nil, "history-uosc", function() uosc_menu.open(1) end)

-- Script Messages
mp.register_script_message("open", function() ui.open() end)
mp.register_script_message("toggle", function() ui.toggle() end)
mp.register_script_message("toggle-tracking", toggle_tracking)
mp.register_script_message("open-vanilla", function() vanilla_menu.open() end)
mp.register_script_message("open-uosc", function(page) uosc_menu.open(tonumber(page) or 1) end)
mp.register_script_message("uosc-page", function(page) uosc_menu.update(tonumber(page) or 1) end)

mp.register_script_message("uosc-event", function(json_str)
    local event = utils.parse_json(json_str)
    if not event or event.type ~= "activate" then return end

    local val = event.value
    if event.action == "delete" then
        local path = val and val.path
        if path then
            storage.remove(path)
            msg.info("Janus: removed from history: " .. path)
            uosc_menu.update(uosc_menu.current_page or 1)
        end
    elseif val and type(val) == "table" then
        if val.action == "page" then
            uosc_menu.update(val.page)
        elseif val.action == "play" then
            if val.missing or (not is_url(val.path) and not file_exists(val.path)) then
                mp.osd_message("Janus: File has been moved or deleted", 3)
                return
            end
            mp.commandv("script-message-to", "uosc", "close-menu", "janus_history")
            play_history_item({
                path = val.path,
                pos = val.pos,
                duration = val.duration,
            })
        end
    end
end)

mp.register_script_message("resume-action", function(action)
    resume_prompter.handle_action(action)
end)

mp.register_script_message("play", function(path, pos, duration)
    play_history_item({
        path = path,
        pos = tonumber(pos) or 0,
        duration = tonumber(duration) or 0,
    })
end)

mp.register_script_message("delete", function(path)
    if path and path ~= "" then
        storage.remove(path)
        msg.info("Janus: removed from history: " .. path)
    end
end)

mp.register_script_message("clear", function()
    storage.clear()
    msg.info("Janus: history cleared")
end)

mp.register_script_message("compact", function()
    local ok, count = storage.compact()
    if ok then
        msg.info(string.format("Janus: history compacted (%d items retained)", count or 0))
    end
end)

mp.register_script_message("speed-toggle", toggle_speed)
mp.register_script_message("play-last", play_last_played)

msg.info("Janus initialized successfully")
