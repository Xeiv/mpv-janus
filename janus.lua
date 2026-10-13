---@diagnostic disable: undefined-field, inject-field
---@class Timer
---@field kill fun(self: Timer)

---@class OSDOverlay
---@field data string
---@field update fun(self: OSDOverlay)
---@field remove fun(self: OSDOverlay)

-- Janus: playback history, smart resume, speed hold, and seek undo/redo for mpv
-- https://github.com/xeiv/mpv-janus


local mp = require("mp")
local msg = require("mp.msg")
local opt = require("mp.options")
local utils = require("mp.utils")


-- ============================================================================
-- Configuration & Options
-- ============================================================================
local config = {
    enabled = true,

    -- storage
    history_file = "~~/janus_history.jsonl",
    max_history = 5000,
    compaction_threshold = 10000,

    -- logging rules
    watch_threshold = 5,
    update_interval = 15,
    save_on_pause = true,
    log_urls = true,
    resume_offset = 0,

    -- url metadata
    format_url_titles = true,
    fetch_url_metadata = true,
    ytdl_path = "yt-dlp",
    ignore_paths = "",

    -- resume prompt
    ask_resume = true,
    resume_threshold = 10,
    resume_end_threshold = 15,
    resume_end_percent = 95,
    resume_skip_playlist = false,
    resume_timeout = 10,
    resume_timeout_action = "resume",
    resume_pause_on_prompt = true,

    -- ui
    ui_mode = "auto",
    page_size = 20,

    -- speed controls
    speed_enabled = true,
    speed_target = 2.0,
    speed_delay = 0.3,

    -- idle
    play_last_on_idle = true,

    -- seek undo/redo
    seek_history_enabled = true,
    seek_history_size = 5,
}

opt.read_options(config, "janus")
local history_path = mp.command_native({"expand-path", config.history_file})
local tracking_enabled = config.enabled


-- ============================================================================
-- Helpers
-- ============================================================================
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

local function format_delta(seconds)
    local sign = seconds >= 0 and "+" or "-"
    local total = math.abs(math.floor(seconds + 0.5))
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    if h > 0 then
        return string.format("%s%d:%02d:%02d", sign, h, m, s)
    else
        return string.format("%s%d:%02d", sign, m, s)
    end
end

-- relative time helper for menu items
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

local function get_filename(path)
    if not path or path == "" then return "Unknown" end
    local cleaned = path:gsub("[/\\]+$", "")
    local name = cleaned:match("([^/\\]+)$")
    return name or path
end

local function is_url(path)
    if not path then return false end
    return path:match("^%a[%w+.-]*://") ~= nil
end

local function is_generic_title(title)
    if not title or title == "" then return true end
    local clean = title:match("^%s*(.-)%s*$"):lower()
    clean = clean:gsub("%s*%([%d%-%/]+%)%s*$", ""):gsub("%s*%[[%d%-%/]+%]%s*$", "")
    clean = clean:gsub("%.%w+$", "")
    clean = clean:match("^%s*(.-)%s*$")

    local generic = {
        ["master"] = true,
        ["index"] = true,
        ["playlist"] = true,
        ["manifest"] = true,
        ["live"] = true,
        ["chunklist"] = true,
        ["stream"] = true,
        ["video"] = true,
        ["audio"] = true,
        ["main"] = true,
        ["prog_index"] = true,
        ["unknown"] = true,
    }
    return generic[clean] == true
end

local function url_decode(str)
    if not str then return "" end
    str = str:gsub("+", " ")
    str = str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

local function clean_url_title(url)
    if not url then return "" end
    local clean = url:match("^([^?#]+)") or url
    local name = clean:match("([^/]+)$") or clean
    name = url_decode(name)
    name = name:gsub("%.%w+$", "")
    if is_generic_title(name) then
        return ""
    end
    return name
end

local function format_date(raw_date)
    if not raw_date or raw_date == "" or raw_date == "NA" then return nil end
    raw_date = tostring(raw_date):match("^%s*(.-)%s*$")

    local y, m, d = raw_date:match("^(%d%d%d%d)[%-%/](%d%d)[%-%/](%d%d)")
    if y and m and d then
        return string.format("%s-%s-%s", y, m, d)
    end

    y, m, d = raw_date:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if y and m and d then
        return string.format("%s-%s-%s", y, m, d)
    end

    local num = tonumber(raw_date)
    if num and num > 946684800 and num < 4102444800 then
        return os.date("!%Y-%m-%d", num)
    end

    local year = raw_date:match("^(%d%d%d%d)$")
    if year then
        return year
    end

    return nil
end

local function format_media_title(author, title, date)
    if not title or title == "" or title == "NA" then return nil end
    title = title:match("^%s*(.-)%s*$")
    if is_url(title) then
        title = clean_url_title(title)
    end
    if not title or title == "" or is_generic_title(title) then
        if not author or author == "" or author == "NA" then
            return nil
        end
        title = nil
    end

    if author == "NA" then author = nil end
    if date == "NA" then date = nil end

    if author then
        author = author:match("^%s*(.-)%s*$")
        if author == "" then author = nil end
    end

    local formatted_date = format_date(date)

    if author and title then
        local author_lower = author:lower()
        if title:lower():find("^" .. author_lower:gsub("%p", "%%%0") .. "%s*[-:]%s*") then
            author = nil
        end
    end

    if formatted_date and title then
        if title:find("%(" .. formatted_date:gsub("%p", "%%%0") .. "%)$") or
           title:find("%[" .. formatted_date:gsub("%p", "%%%0") .. "%]$") then
            formatted_date = nil
        end
    end

    local result = title or author
    if not result then return nil end

    if author and title and author ~= "" then
        result = string.format("%s: %s", author, result)
    end
    if formatted_date and formatted_date ~= "" then
        result = string.format("%s (%s)", result, formatted_date)
    end

    if is_generic_title(result) then
        return nil
    end

    return result
end

local function get_metadata_val(meta, ...)
    if not meta or type(meta) ~= "table" then return nil end
    local targets = {...}
    for k, v in pairs(meta) do
        if type(k) == "string" and v and v ~= "" and v ~= "NA" then
            local lk = k:lower()
            for _, t in ipairs(targets) do
                if lk == t:lower() then
                    return tostring(v)
                end
            end
        end
    end
    return nil
end

local function extract_metadata_fields(meta, fmeta)
    meta = meta or {}
    fmeta = fmeta or {}

    local author = get_metadata_val(meta, "uploader", "channel", "creator", "artist", "author", "album_artist", "channel_name", "streamer")
        or get_metadata_val(fmeta, "uploader", "channel", "creator", "artist", "author", "album_artist", "channel_name", "streamer")

    local date = get_metadata_val(meta, "date", "upload_date", "release_date", "creation_time", "year", "timestamp", "start_time")
        or get_metadata_val(fmeta, "date", "upload_date", "release_date", "creation_time", "year", "timestamp", "start_time")

    local title = get_metadata_val(meta, "title", "track", "icy-title", "song", "session_title")
        or get_metadata_val(fmeta, "title", "track", "icy-title", "song", "session_title")

    return author, title, date
end

local function file_exists(path)
    if not path or path == "" then return false end
    if is_url(path) then return true end
    local expanded = mp.command_native({"expand-path", path})
    local info = utils.file_info(expanded)
    return info ~= nil
end

local function find_executable(name)
    if not name or name == "" then return nil end
    local expanded = mp.command_native({"expand-path", name})
    if name:find("[/\\]") then
        local info = utils.file_info(expanded)
        if info then return expanded end
        return nil
    end

    local path_env = os.getenv("PATH") or ""
    local sep = package.config:sub(1, 1) == "\\" and ";" or ":"
    for dir in path_env:gmatch("[^" .. sep .. "]+") do
        local full = utils.join_path(dir, name)
        local info = utils.file_info(full)
        if info then return full end
        if sep == ";" then
            local full_exe = full .. ".exe"
            if utils.file_info(full_exe) then return full_exe end
        end
    end
    return nil
end

local resolved_ytdl = nil
local function check_ytdl_availability()
    if not config.fetch_url_metadata then return end
    resolved_ytdl = find_executable(config.ytdl_path)
    if not resolved_ytdl then
        config.fetch_url_metadata = false
        msg.verbose(string.format("Janus: ytdl_path '%s' not found, disabling background url metadata fetch", tostring(config.ytdl_path)))
    end
end
check_ytdl_availability()

local function is_same_path(path1, path2)
    if not path1 or not path2 then return false end
    if path1 == path2 then return true end
    local exp1 = mp.command_native({"expand-path", path1})
    local exp2 = mp.command_native({"expand-path", path2})
    return exp1 == exp2 or exp1 == path2 or path1 == exp2
end

-- apply unicode strikethrough for missing/deleted files in uosc
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

-- check if path matches any pattern in ignore_paths
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

-- escape special characters for ASS subtitles/OSD
local function escape_ass(text)
    if not text then return "" end
    local escaped = tostring(text)
    escaped = escaped:gsub("\\", "\\\239\187\191")
    escaped = escaped:gsub("{", "\\{")
    escaped = escaped:gsub("}", "\\}")
    return escaped
end

-- truncate long titles with an ellipsis
local function truncate_string(str, max_len)
    if not str then return "" end
    if #str <= max_len then return str end
    return str:sub(1, max_len - 3) .. "..."
end

local function toggle_tracking()
    tracking_enabled = not tracking_enabled
    local status = tracking_enabled and "enabled" or "disabled"
    mp.osd_message(string.format("Janus: History tracking %s", status), 2)
    msg.info(string.format("Janus: History tracking %s", status))
end


-- ============================================================================
-- History Storage (JSON Lines)
-- ============================================================================
local storage = {
    append_count = 0,
}

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

-- scan lines backwards from EOF in chunks so we only read what is needed
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

function storage.get_best_title(target_path)
    if not target_path or target_path == "" then return nil end
    local best_title = nil

    reverse_scan_lines(8192, function(line)
        local ok_json, entry = pcall(utils.parse_json, line)
        if ok_json and type(entry) == "table" and entry.path == target_path then
            if not entry.deleted and entry.title and entry.title ~= "" then
                if not is_url(entry.title) and not is_generic_title(entry.title) then
                    best_title = entry.title
                    return true
                end
            end
        end
    end)

    return best_title
end

function storage.remove(target_path)
    if not target_path or target_path == "" then return false end
    return storage.append({
        path = target_path,
        deleted = true,
        time = os.time(),
    })
end

function storage.clear()
    local f = io.open(history_path, "w")
    if f then
        f:close()
        storage.append_count = 0
        return true
    end
    return false
end

-- compact history: remove duplicates and tombstoned entries
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

function storage.prune_missing()
    local entries = {}
    local seen = {}
    local pruned_count = 0

    reverse_scan_lines(8192, function(line)
        local ok_json, entry = pcall(utils.parse_json, line)
        if ok_json and type(entry) == "table" and entry.path then
            if not seen[entry.path] then
                seen[entry.path] = true
                if not entry.deleted then
                    if is_url(entry.path) or file_exists(entry.path) then
                        table.insert(entries, entry)
                    else
                        pruned_count = pruned_count + 1
                    end
                end
            end
        end
    end)

    if pruned_count == 0 then
        return 0
    end

    local count = #entries
    for i = 1, math.floor(count / 2) do
        entries[i], entries[count - i + 1] = entries[count - i + 1], entries[i]
    end

    local tmp_path = history_path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then return 0 end

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
    return pruned_count
end

function storage.search(query, max_results)
    if not query or query == "" then return {} end
    query = query:lower()
    max_results = max_results or 50

    local terms = {}
    for word in query:gmatch("%S+") do
        table.insert(terms, word)
    end
    if #terms == 0 then return {} end

    local items = {}
    local seen = {}

    reverse_scan_lines(8192, function(line)
        local ok_json, entry = pcall(utils.parse_json, line)
        if ok_json and type(entry) == "table" and entry.path then
            if not seen[entry.path] then
                seen[entry.path] = true
                if not entry.deleted then
                    local title = (entry.title or get_filename(entry.path)):lower()
                    local path = entry.path:lower()
                    local matched = true
                    for _, term in ipairs(terms) do
                        if not title:find(term, 1, true) and not path:find(term, 1, true) then
                            matched = false
                            break
                        end
                    end
                    if matched then
                        table.insert(items, entry)
                        if #items >= max_results then
                            return true
                        end
                    end
                end
            end
        end
    end)

    return items
end


-- ============================================================================
-- Playback Tracking
-- ============================================================================
local tracker = {
    current = {
        path = nil,
        title = nil,
        pos = 0,
        duration = 0,
        watch_time = 0,
        qualified = false,
        formatted_title = nil,
    },
    timer = nil,
    is_paused = false,
}

local resume_prompter
local resume_prompt_forced = false
local resume_suppressed = false
local seek_history_reset = function() end

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

local function play_history_item(item, direct_resume)
    if not item or not item.path then return end

    if not is_url(item.path) and not file_exists(item.path) then
        mp.osd_message("Janus: File has been moved or deleted", 3)
        msg.warn("Janus: Cannot play, file has been moved or deleted: " .. item.path)
        return
    end

    local current_path = mp.get_property("path")
    if is_same_path(current_path, item.path) then
        -- already playing: don't reload or prompt, keep playback uninterrupted
        return
    end

    local pos = item.pos or 0
    local start_pos = math.max(0, pos - config.resume_offset)

    -- skip resume and start fresh if near the end or past completion threshold
    if item.duration and item.duration > 0 then
        local remaining = item.duration - start_pos
        local percent = (start_pos / item.duration) * 100
        if remaining < config.resume_end_threshold or percent >= config.resume_end_percent then
            start_pos = 0
        end
    end

    if direct_resume then
        resume_suppressed = true
        if start_pos > 0 then
            mp.commandv("loadfile", item.path, "replace", "-1", "start=" .. tostring(start_pos))
        else
            mp.commandv("loadfile", item.path, "replace")
        end
    elseif config.ask_resume and start_pos >= config.resume_threshold then
        -- load from beginning so file-loaded shows the resume prompt
        resume_prompt_forced = true
        mp.commandv("loadfile", item.path, "replace")
    else
        if start_pos > 0 then
            mp.commandv("loadfile", item.path, "replace", "-1", "start=" .. tostring(start_pos))
        else
            mp.commandv("loadfile", item.path, "replace")
        end
    end
end

-- resume most recent playable file
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
    play_history_item(item, true)
end

local function tracker_save()
    if not tracking_enabled or resume_prompter.is_active or not tracker.current.path or not tracker.current.qualified or should_ignore_path(tracker.current.path) then
        return
    end

    tracker.current.pos = mp.get_property_number("time-pos", tracker.current.pos) or tracker.current.pos
    tracker.current.duration = mp.get_property_number("duration", tracker.current.duration) or tracker.current.duration
    local title = tracker.current.formatted_title or mp.get_property("media-title")
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

local function tracker_on_tick()
    if not tracking_enabled or resume_prompter.is_active or tracker.is_paused or not tracker.current.path or should_ignore_path(tracker.current.path) then
        return
    end

    tracker.current.watch_time = tracker.current.watch_time + 1

    -- qualify for logging once minimum watch time is met
    if not tracker.current.qualified and tracker.current.watch_time >= config.watch_threshold then
        tracker.current.qualified = true
        tracker_save()
    elseif tracker.current.qualified and (tracker.current.watch_time % config.update_interval == 0) then
        tracker_save()
    end
end


-- ============================================================================
-- Resume Prompt (uosc & Vanilla OSD)
-- ============================================================================
local speed_state, speed_deactivate
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

function resume_prompter.check(path)
    if resume_suppressed then
        resume_suppressed = false
        return
    end
    if not config.ask_resume or not path or path == "" or should_ignore_path(path) then return end
    if not config.log_urls and is_url(path) then return end

    if not resume_prompt_forced and config.resume_skip_playlist then
        local playlist_pos = mp.get_property_number("playlist-pos", 0)
        if playlist_pos > 0 then return end
    end
    resume_prompt_forced = false

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

function resume_prompter.cancel()
    if resume_prompter.is_active then
        resume_close_ui()
    end
end


-- ============================================================================
-- History Menus (uosc & Vanilla OSD)
-- ============================================================================
local vanilla_menu = {
    is_open = false,
    current_page = 1,
    page_data = nil,
    selected_index = 1,
    confirm_mode = nil,
    overlay = nil,
    key_bindings = {},
}

local function vanilla_render()
    if not vanilla_menu.is_open then return end
    if not vanilla_menu.overlay then
        vanilla_menu.overlay = mp.create_osd_overlay("ass-events")
    end

    if vanilla_menu.confirm_mode == "prune" then
        vanilla_menu.overlay.data = "{\\an5\\bord2\\shad2\\fs20\\c&HFFFFFF&}"
            .. "{\\b1\\fs26\\c&H00D7FF&}PRUNE MISSING FILES?{\\c&HFFFFFF&\\b0}\\N\\N"
            .. "{\\fs18\\c&HD0D0D0&}Remove all moved or deleted files from history?\\N\\N"
            .. "{\\fs16\\c&HFFFFFF&}[Enter] {\\b1}Prune{\\b0}      [Esc] {\\b1}Cancel{\\b0}"
        vanilla_menu.overlay:update()
        return
    end

    if vanilla_menu.confirm_mode == "clear" then
        vanilla_menu.overlay.data = "{\\an5\\bord2\\shad2\\fs20\\c&HFFFFFF&}"
            .. "{\\b1\\fs26\\c&H0055FF&}CLEAR ALL HISTORY?{\\c&HFFFFFF&\\b0}\\N\\N"
            .. "{\\fs18\\c&HD0D0D0&}Permanently delete all playback history?\\N\\N"
            .. "{\\fs16\\c&HFFFFFF&}[Enter] {\\b1}Clear All{\\b0}      [Esc] {\\b1}Cancel{\\b0}"
        vanilla_menu.overlay:update()
        return
    end

    local page = vanilla_menu.page_data or { items = {}, page = 1, has_prev = false, has_next = false }
    local items = page.items
    local now = os.time()

    local lines = {"{\\an7\\fs16\\bord1.5\\shad1}"}
    local header = string.format(
        "{\\b1\\fs20\\c&H00D7FF&}JANUS HISTORY{\\c&HFFFFFF&\\b0\\fs16}  -  Page %d %s%s\\N\\N",
        vanilla_menu.current_page,
        page.has_prev and "{\\c&H00D7FF&}◀ [Left]{\\c&HFFFFFF&} " or "   ",
        page.has_next and "{\\c&H00D7FF&}[Right] ▶{\\c&HFFFFFF&}" or ""
    )
    table.insert(lines, header)

    if #items == 0 then
        table.insert(lines, "{\\c&H888888&}   (No history entries found)\\N\\N")
    else
        local current_path = mp.get_property("path")
        for i, item in ipairs(items) do
            local is_selected = (i == vanilla_menu.selected_index)
            local is_current = is_same_path(current_path, item.path)
            local prefix = is_selected and "{\\fs16\\b1\\c&H00FFFF&} ▶ " or (is_current and "{\\fs16\\b1\\c&H00FF7F&} ● " or "{\\fs16\\c&H888888&}   ")
            local max_len = is_current and 40 or 55
            local title = escape_ass(truncate_string(item.title or get_filename(item.path), max_len))
            local title_color = is_selected and "{\\fs16\\c&HFFFFFF&\\b1}" or (is_current and "{\\fs16\\c&H00FF7F&\\b1}" or "{\\fs16\\c&HD0D0D0&\\b0}")

            local exists = file_exists(item.path)
            local pos = tonumber(item.pos) or 0
            local dur = tonumber(item.duration) or 0
            local pos_str = format_duration(pos)
            local dur_str = format_duration(dur)
            local rel_time = format_relative_time(item.time, now)

            if not exists then
                title = string.format("{\\s1}%s{\\s0} {\\c&HFF6666&}[Deleted or Moved]", title)
                title_color = "{\\fs16\\c&H888888&}"
            end

            local badge = is_current and " {\\fs14\\c&H00FF7F&\\b1}[Now Playing]{\\b0}" or ""
            local meta
            if not exists then
                meta = string.format("{\\fs16\\c&H999999&}  •  %s", rel_time)
            elseif dur > 0 then
                local percent = math.min(100, math.floor((pos / dur) * 100))
                meta = string.format("{\\fs16\\c&H999999&}  [%s / %s (%d%%)]  •  %s", pos_str, dur_str, percent, rel_time)
            else
                meta = string.format("{\\fs16\\c&H999999&}  [%s]  •  %s", pos_str, rel_time)
            end

            table.insert(lines, string.format("%s%s%s%s%s\\N", prefix, title_color, title, badge, meta))
        end
        table.insert(lines, "\\N")
    end

    local footer = "{\\fs14\\c&H777777&}------------------------------------------------------------\\N"
        .. "{\\fs13\\c&H888888&}[↑/↓] Select   [Enter] Resume   [r] Restart   [←/→] Page   [Del] Delete   [Esc/q] Close\\N\\N"
        .. "    {\\c&H00D7FF&}[p] Prune Missing Files{\\c&H777777&}   |   {\\c&H0055FF&}[c] Clear All History"
    table.insert(lines, footer)

    vanilla_menu.overlay.data = table.concat(lines)
    vanilla_menu.overlay:update()
end

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

function vanilla_menu.close()
    if not vanilla_menu.is_open then return end
    vanilla_menu.is_open = false
    vanilla_menu.confirm_mode = nil
    for name, _ in pairs(vanilla_menu.key_bindings) do
        mp.remove_key_binding(name)
    end
    vanilla_menu.key_bindings = {}
    if vanilla_menu.overlay then
        vanilla_menu.overlay:remove()
    end
end

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
        if vanilla_menu.confirm_mode == "prune" then
            local count = storage.prune_missing()
            if count == 0 then
                mp.osd_message("Janus: No missing files found", 2)
            else
                mp.osd_message(string.format("Janus: Pruned %d missing file%s", count, count == 1 and "" or "s"), 2)
            end
            vanilla_menu.confirm_mode = nil
            vanilla_refresh()
            return
        elseif vanilla_menu.confirm_mode == "clear" then
            storage.clear()
            mp.osd_message("Janus: Playback history cleared", 2)
            vanilla_menu.confirm_mode = nil
            vanilla_refresh()
            return
        end

        local items = vanilla_menu.page_data and vanilla_menu.page_data.items or {}
        local item = items[vanilla_menu.selected_index]
        if item then
            if not is_url(item.path) and not file_exists(item.path) then
                mp.osd_message("Janus: File has been moved or deleted", 3)
                return
            end
            vanilla_menu.close()
            play_history_item(item, true)
        end
    end)
    bind("r", "janus_v_restart", function()
        if vanilla_menu.confirm_mode then return end
        local items = vanilla_menu.page_data and vanilla_menu.page_data.items or {}
        local item = items[vanilla_menu.selected_index]
        if item then
            if not is_url(item.path) and not file_exists(item.path) then
                mp.osd_message("Janus: File has been moved or deleted", 3)
                return
            end
            vanilla_menu.close()
            play_history_item({
                path = item.path,
                pos = 0,
                duration = item.duration,
            }, true)
        end
    end)
    bind("p", "janus_v_prune", function()
        vanilla_menu.confirm_mode = "prune"
        vanilla_render()
    end)
    bind("c", "janus_v_clear", function()
        vanilla_menu.confirm_mode = "clear"
        vanilla_render()
    end)
    bind("DEL", "janus_v_del", function()
        if vanilla_menu.confirm_mode then return end
        local items = vanilla_menu.page_data and vanilla_menu.page_data.items or {}
        local item = items[vanilla_menu.selected_index]
        if item then
            storage.remove(item.path)
            vanilla_refresh()
        end
    end)
    bind("BS", "janus_v_bs", function() mp.commandv("keypress", "DEL") end)
    bind("ESC", "janus_v_esc", function()
        if vanilla_menu.confirm_mode then
            vanilla_menu.confirm_mode = nil
            vanilla_render()
        else
            vanilla_menu.close()
        end
    end)
    bind("q", "janus_v_q", function()
        if vanilla_menu.confirm_mode then
            vanilla_menu.confirm_mode = nil
            vanilla_render()
        else
            vanilla_menu.close()
        end
    end)

    vanilla_refresh()
end

local uosc_menu = {
    current_page = 1,
    search_query = nil,
}

local function uosc_build_item(item, now)
    local title = item.title or get_filename(item.path)
    local current_path = mp.get_property("path")
    local is_current = is_same_path(current_path, item.path)
    local exists = file_exists(item.path)
    local pos = tonumber(item.pos) or 0
    local dur = tonumber(item.duration) or 0
    local pos_str = format_duration(pos)
    local dur_str = format_duration(dur)
    local rel_time = format_relative_time(item.time, now)

    local display_title = exists and title or strikethrough(title)
    local hint_str
    if not exists then
        hint_str = string.format("[Deleted or Moved]  •  %s", rel_time)
    elseif dur > 0 then
        local percent = math.min(100, math.floor((pos / dur) * 100))
        hint_str = string.format("%s / %s (%d%%)  •  %s", pos_str, dur_str, percent, rel_time)
    else
        hint_str = string.format("%s  •  %s", pos_str, rel_time)
    end

    if is_current then
        hint_str = string.format("[Now Playing]  •  %s", hint_str)
    end

    return {
        title = display_title,
        hint = hint_str,
        icon = not exists and "error" or (is_current and "play_circle" or "history"),
        active = is_current,
        bold = is_current,
        muted = not exists,
        value = {
            action = "play",
            path = item.path,
            pos = pos,
            duration = dur,
            missing = not exists,
        },
        actions = {
            {
                name = "replay",
                icon = "replay",
                label = "Play from beginning (r)",
            },
            {
                name = "delete",
                icon = "delete",
                label = "Delete from history (del)",
            },
        },
    }
end

local function uosc_build_menu(page_num, query)
    local now = os.time()
    local menu_items = {}

    if query and query ~= "" then
        local results = storage.search(query, 50)
        if #results == 0 then
            table.insert(menu_items, {
                title = string.format("No history found matching \"%s\"", query),
                italic = true,
                align = "center",
                selectable = false,
            })
        else
            for _, item in ipairs(results) do
                table.insert(menu_items, uosc_build_item(item, now))
            end
        end

        return {
            type = "janus_history",
            title = string.format("Search: %s (%d matches)", query, #results),
            footnote = "r Restart  •  del Delete  •  Esc Dismiss",
            callback = {"janus", "uosc-event"},
            on_search = {"janus", "uosc-search"},
            search_debounce = 200,
            bind_keys = {"p", "c", "r"},
            items = menu_items,
        }
    end

    page_num = page_num or uosc_menu.current_page or 1
    uosc_menu.current_page = page_num
    local page_data = storage.get_page(page_num)
    local items = page_data.items

    if #items == 0 then
        table.insert(menu_items, {
            title = "No history entries found",
            italic = true,
            align = "center",
            selectable = false,
        })
    else
        for _, item in ipairs(items) do
            table.insert(menu_items, uosc_build_item(item, now))
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

    table.insert(menu_items, {
        separator = true,
    })
    table.insert(menu_items, {
        title = "Prune Missing Files",
        icon = "delete_sweep",
        align = "center",
        keep_open = true,
        value = {
            action = "confirm_prune",
        },
    })
    table.insert(menu_items, {
        title = "Clear All History",
        icon = "delete_forever",
        align = "center",
        keep_open = true,
        value = {
            action = "confirm_clear",
        },
    })

    return {
        type = "janus_history",
        title = string.format("History - Page %d", page_num),
        footnote = "←/→ Page  •  r Restart  •  del Delete  •  p Prune  •  c Clear",
        callback = {"janus", "uosc-event"},
        on_search = {"janus", "uosc-search"},
        search_debounce = 200,
        bind_keys = {"p", "c", "r"},
        items = menu_items,
    }
end

function uosc_menu.open(page_num)
    page_num = page_num or 1
    uosc_menu.current_page = page_num
    uosc_menu.search_query = nil
    local json = utils.format_json(uosc_build_menu(page_num))
    mp.commandv("script-message-to", "uosc", "open-menu", json)
end

function uosc_menu.update(page_num)
    page_num = page_num or uosc_menu.current_page or 1
    uosc_menu.current_page = page_num
    local json = utils.format_json(uosc_build_menu(page_num, uosc_menu.search_query))
    mp.commandv("script-message-to", "uosc", "update-menu", json)
end

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


mp.register_script_message("uosc-version", function()
    ui.has_uosc = true
end)

-- ============================================================================
-- URL Metadata Enrichment
-- ============================================================================
local function apply_formatted_title(path, formatted)
    if not formatted or formatted == "" then return end
    if not tracker.current.path or not is_same_path(tracker.current.path, path) then return end
    if is_generic_title(formatted) then return end

    -- Do not overwrite an existing creator title with one lacking creator
    if tracker.current.title and not is_generic_title(tracker.current.title) and not is_url(tracker.current.title) then
        if not formatted:find(":") and tracker.current.title:find(":") then
            return
        end
    end

    if tracker.current.formatted_title == formatted then return end

    tracker.current.formatted_title = formatted
    tracker.current.title = formatted

    mp.set_property("force-media-title", formatted)
    msg.info("Janus: Formatted title: " .. formatted)

    if tracker.current.qualified then
        tracker_save()
    end

    if vanilla_menu.is_open then
        vanilla_refresh()
    elseif ui.has_uosc and uosc_menu.current_page then
        uosc_menu.update(uosc_menu.current_page)
    end
end

local function try_format_from_mpv_metadata(path)
    local meta = mp.get_property_native("metadata") or {}
    local fmeta = mp.get_property_native("filtered-metadata") or {}
    local author, title, date = extract_metadata_fields(meta, fmeta)

    if not title or title == "" or is_url(title) or is_generic_title(title) then
        local raw_title = mp.get_property("media-title")
        if raw_title and raw_title ~= "" and not is_url(raw_title) and not is_generic_title(raw_title) then
            title = raw_title
        else
            title = storage.get_best_title(path) or clean_url_title(path)
        end
    end

    local formatted = format_media_title(author, title, date)
    if formatted and not is_generic_title(formatted) and (author or date) then
        apply_formatted_title(path, formatted)
        return true, author ~= nil, date ~= nil
    end

    if formatted and not is_url(formatted) and not is_generic_title(formatted) and is_url(mp.get_property("media-title") or "") then
        apply_formatted_title(path, formatted)
    end

    return false, author ~= nil, date ~= nil
end

local function resolve_kick_cdn(url)
    local channel_ivs, stream_id = url:match("stream%.kick%.com/[^/]+/ivs/v1/[^/]+/([^/]+)/%d+/%d+/%d+/%d+/%d+/([^/]+)/")
    if not channel_ivs or not stream_id then return false end

    local slug = nil
    if channel_ivs == "BO2zfdDBEu6T" then
        slug = "buddha"
    end

    if not slug then
        reverse_scan_lines(8192, function(line)
            local ok_json, entry = pcall(utils.parse_json, line)
            if ok_json and type(entry) == "table" and entry.path and entry.title then
                if entry.path:find(channel_ivs, 1, true) then
                    local creator = entry.title:match("^([^:]+):")
                    if creator and creator ~= "" and not is_generic_title(creator) then
                        slug = creator:lower()
                        return true
                    end
                end
            end
        end)
    end

    if not slug then return false end

    local api_url = string.format("https://kick.com/api/v2/channels/%s/videos", slug)
    mp.command_native_async({
        name = "subprocess",
        args = {"curl", "-s", "-H", "User-Agent: Mozilla/5.0", api_url},
        playback_only = false,
        capture_stdout = true,
        capture_stderr = false,
    }, function(success, res)
        if not success or not res or res.status ~= 0 or not res.stdout then return end
        local ok_json, data = pcall(utils.parse_json, res.stdout)
        if not ok_json or type(data) ~= "table" then return end

        for _, v in ipairs(data) do
            local source = v.source or ""
            if source:find(stream_id, 1, true) then
                local creator = slug:sub(1, 1):upper() .. slug:sub(2)
                local title = v.session_title
                local date = (v.created_at or ""):sub(1, 10)
                local formatted = format_media_title(creator, title, date)
                if formatted then
                    apply_formatted_title(url, formatted)
                end
                return
            end
        end
    end)

    return true
end

local function canonicalize_stream_url(url)
    if not url then return nil end

    -- Twitch live HLS stream: *.hls.ttvnw.net/.../channel.m3u8 or usher.ttvnw.net/.../channel.m3u8
    local twitch_ch = url:match("ttvnw%.net/.-/([%w_]+)%.m3u8")
    if twitch_ch and not is_generic_title(twitch_ch) then
        return "https://www.twitch.tv/" .. twitch_ch
    end

    -- Twitch VOD: *.cloudfront.net/<hash>/<vod_id>_.../
    local twitch_vod = url:match("cloudfront%.net/[^/]+/([%d]+)_")
    if twitch_vod then
        return "https://www.twitch.tv/videos/" .. twitch_vod
    end

    -- YouTube googlevideo CDN playback
    if url:find("googlevideo%.com/videoplayback") then
        local docid = url:match("[%?&]docid=([^&]+)") or url:match("[%?&]id=([^&]+)")
        if docid and #docid == 11 then
            return "https://www.youtube.com/watch?v=" .. docid
        end
    end

    -- Kick video query param: kick.com/<channel>?video=<uuid>
    local kick_user, kick_uuid = url:match("kick%.com/([%w_]+)%?video=([%w%-]+)")
    if kick_user and kick_uuid then
        return "https://kick.com/" .. kick_user .. "/videos/" .. kick_uuid
    end

    -- Rumble embed to video: rumble.com/embed/<id>
    local rumble_embed = url:match("rumble%.com/embed/([%w]+)")
    if rumble_embed then
        return "https://rumble.com/embed/" .. rumble_embed
    end

    return url
end

local function fetch_url_metadata(path)
    if not config.fetch_url_metadata or not is_url(path) then return end

    if path:find("stream%.kick%.com") and resolve_kick_cdn(path) then
        return
    end

    if not resolved_ytdl then return end

    local query_url = canonicalize_stream_url(path) or path

    local args = {
        resolved_ytdl,
        "--no-warnings",
        "--no-playlist",
        "--skip-download",
        "--print", "%(uploader,channel,creator,artist)s<JANUS_SEP>%(title)s<JANUS_SEP>%(upload_date,release_date)s",
        query_url,
    }

    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res, err)
        if not success or not res or res.status ~= 0 or not res.stdout then
            if res and res.status == -3 then
                config.fetch_url_metadata = false
                resolved_ytdl = nil
            end
            if err then msg.debug("Janus: yt-dlp metadata fetch failed: " .. tostring(err)) end
            return
        end

        local a, t, d = res.stdout:match("^%s*(.-)<JANUS_SEP>(.-)<JANUS_SEP>(.-)%s*$")
        if not t or t == "" or t == "NA" or is_url(t) or is_generic_title(t) then
            local raw = mp.get_property("media-title")
            if raw and raw ~= "" and not is_url(raw) and not is_generic_title(raw) then
                t = raw
            else
                t = storage.get_best_title(path) or clean_url_title(path)
            end
        end
        if a == "NA" then a = nil end
        if d == "NA" then d = nil end

        if not a or not d then
            local meta = mp.get_property_native("metadata") or {}
            local fmeta = mp.get_property_native("filtered-metadata") or {}
            local meta_author, _, meta_date = extract_metadata_fields(meta, fmeta)
            a = a or meta_author
            d = d or meta_date
        end

        local formatted = format_media_title(a, t, d)
        if formatted and not is_generic_title(formatted) then
            apply_formatted_title(path, formatted)
        end
    end)
end


-- ============================================================================
-- mpv Events
-- ============================================================================

mp.register_event("file-loaded", function()
    seek_history_reset()
    local path = mp.get_property("path")
    if not path or path == "" or should_ignore_path(path) then
        tracker.current.path = nil
        return
    end

    if not config.log_urls and is_url(path) then
        tracker.current.path = nil
        return
    end

    local raw_title = mp.get_property("media-title")
    local duration = mp.get_property_number("duration", 0) or 0
    local pos = mp.get_property_number("time-pos", 0) or 0

    local title = raw_title
    local saved_best = storage.get_best_title(path)
    if not title or title == "" or is_url(title) or is_generic_title(title) then
        if saved_best then
            title = saved_best
        elseif raw_title and raw_title ~= "" and not is_url(raw_title) then
            title = raw_title
        else
            title = get_filename(path)
        end
    end

    tracker.current = {
        path = path,
        title = title,
        pos = pos,
        duration = duration,
        watch_time = 0,
        qualified = false,
        formatted_title = nil,
    }

    tracker.is_paused = mp.get_property_bool("pause", false)

    if saved_best and (not raw_title or is_url(raw_title) or is_generic_title(raw_title)) then
        tracker.current.formatted_title = saved_best
        mp.set_property("force-media-title", saved_best)
    end

    if config.format_url_titles and is_url(path) then
        local ok, has_author, has_date = try_format_from_mpv_metadata(path)
        if (not ok or not has_author or not has_date) and config.fetch_url_metadata and resolved_ytdl then
            fetch_url_metadata(path)
        end
    end

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

mp.observe_property("metadata", "native", function(_, meta)
    if not config.format_url_titles then return end
    local path = tracker.current.path
    if not path or not is_url(path) then return end

    local fmeta = mp.get_property_native("filtered-metadata") or {}
    local author, title, date = extract_metadata_fields(meta, fmeta)
    if not title or title == "" or is_url(title) then
        local raw_title = mp.get_property("media-title")
        if raw_title and raw_title ~= "" and not is_url(raw_title) then
            title = raw_title
        else
            title = clean_url_title(path)
        end
    end

    local formatted = format_media_title(author, title, date)
    if formatted and (author or date) then
        apply_formatted_title(path, formatted)
    end
end)

mp.register_event("end-file", function()
    seek_history_reset()
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
    tracker.current.formatted_title = nil
end)

tracker.timer = mp.add_periodic_timer(1, tracker_on_tick)


-- ============================================================================
-- Hold to Speed Up (YouTube Style)
-- ============================================================================
speed_state = {
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

    -- keep pitch correction on so audio stays intelligible at higher speeds
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

speed_deactivate = function()
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
            -- quick tap: toggle play/pause
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
-- Seek History (Undo / Redo)
-- ============================================================================
local seek_history = {
    stack = {},
    index = 0,
    last_normal_pos = nil,
    last_pos_time = 0,
    is_navigating = false,
    debounce_timer = nil,
    pending_origin = nil,
}

local function seek_history_reset()
    seek_history.stack = {}
    seek_history.index = 0
    seek_history.last_normal_pos = nil
    seek_history.last_pos_time = 0
    seek_history.is_navigating = false
    seek_history.pending_origin = nil
    if seek_history.debounce_timer then
        seek_history.debounce_timer:kill()
        seek_history.debounce_timer = nil
    end
end

local function seek_history_push(origin, destination)
    if not origin or not destination then return end
    origin = math.floor(origin * 10) / 10
    destination = math.floor(destination * 10) / 10
    if math.abs(origin - destination) < 2 then return end

    if #seek_history.stack == 0 then
        table.insert(seek_history.stack, origin)
        seek_history.index = 1
    else
        while #seek_history.stack > seek_history.index do
            table.remove(seek_history.stack)
        end
        local top = seek_history.stack[#seek_history.stack]
        if not top or math.abs(top - origin) >= 2 then
            table.insert(seek_history.stack, origin)
            seek_history.index = #seek_history.stack
        end
    end

    table.insert(seek_history.stack, destination)
    seek_history.index = #seek_history.stack

    local max_points = (config.seek_history_size or 5) + 1
    while #seek_history.stack > max_points do
        table.remove(seek_history.stack, 1)
        seek_history.index = math.max(1, seek_history.index - 1)
    end
end

local function seek_undo()
    if not config.seek_history_enabled then return end
    if resume_prompter.is_active or vanilla_menu.is_open then return end

    if seek_history.debounce_timer then
        seek_history.debounce_timer:kill()
        seek_history.debounce_timer = nil
        if seek_history.pending_origin then
            local current_pos = mp.get_property_number("time-pos", 0)
            seek_history_push(seek_history.pending_origin, current_pos)
            seek_history.pending_origin = nil
        end
    end

    if seek_history.index <= 1 then
        mp.osd_message("↩ No previous seek to undo", 1.5)
        return
    end

    local current_pos = mp.get_property_number("time-pos", 0)
    seek_history.index = seek_history.index - 1
    local target_pos = seek_history.stack[seek_history.index]
    local delta = target_pos - current_pos

    seek_history.is_navigating = true
    mp.commandv("seek", tostring(target_pos), "absolute", "exact")
    mp.osd_message(string.format("↩ %s (to %s)", format_delta(delta), format_duration(target_pos)), 1.5)

    mp.add_timeout(0.5, function()
        seek_history.last_normal_pos = target_pos
        seek_history.last_pos_time = mp.get_time()
        seek_history.is_navigating = false
    end)
end

local function seek_redo()
    if not config.seek_history_enabled then return end
    if resume_prompter.is_active or vanilla_menu.is_open then return end

    if seek_history.index >= #seek_history.stack then
        mp.osd_message("↪ No seek to redo", 1.5)
        return
    end

    local current_pos = mp.get_property_number("time-pos", 0)
    seek_history.index = seek_history.index + 1
    local target_pos = seek_history.stack[seek_history.index]
    local delta = target_pos - current_pos

    seek_history.is_navigating = true
    mp.commandv("seek", tostring(target_pos), "absolute", "exact")
    mp.osd_message(string.format("↪ %s (to %s)", format_delta(delta), format_duration(target_pos)), 1.5)

    mp.add_timeout(0.5, function()
        seek_history.last_normal_pos = target_pos
        seek_history.last_pos_time = mp.get_time()
        seek_history.is_navigating = false
    end)
end

mp.observe_property("time-pos", "number", function(_, pos)
    if not config.seek_history_enabled or not pos or seek_history.is_navigating then return end
    local now = mp.get_time()

    if seek_history.last_normal_pos then
        local elapsed = now - seek_history.last_pos_time
        local expected_diff = elapsed * (mp.get_property_native("speed") or 1.0)
        local actual_diff = pos - seek_history.last_normal_pos

        if math.abs(actual_diff) > math.max(2.5, expected_diff + 2.0) then
            -- debounce rapid seeks (e.g. tapping arrow keys) into a single jump
            if not seek_history.pending_origin then
                seek_history.pending_origin = seek_history.last_normal_pos
            end

            if seek_history.debounce_timer then
                seek_history.debounce_timer:kill()
            end
            seek_history.debounce_timer = mp.add_timeout(0.8, function()
                if seek_history.pending_origin then
                    seek_history_push(seek_history.pending_origin, pos)
                    seek_history.pending_origin = nil
                end
                seek_history.debounce_timer = nil
            end)
        end
    end

    seek_history.last_normal_pos = pos
    seek_history.last_pos_time = now
end)


-- default keybindings
-- ============================================================================
-- Keybindings & Script Messages
-- ============================================================================
mp.add_key_binding("h", "open", function() ui.open() end)
mp.add_key_binding("Alt+h", "toggle-tracking", toggle_tracking)
if config.speed_enabled then
    mp.add_forced_key_binding("SPACE", "speed-hold-space", handle_speed_key, {complex = true})
    mp.add_forced_key_binding("MBTN_RIGHT", "speed-hold-mouse", handle_speed_key, {complex = true})
    mp.add_forced_key_binding("Alt+n", "speed-toggle-key", toggle_speed)
end
if config.seek_history_enabled then
    mp.add_forced_key_binding("ctrl+z", "seek-undo", seek_undo)
    mp.add_forced_key_binding("ctrl+x", "seek-redo", seek_redo)
end
mp.add_key_binding(nil, "seek-undo", seek_undo)
mp.add_key_binding(nil, "seek-redo", seek_redo)
mp.add_key_binding(nil, "speed-hold", handle_speed_key, {complex = true})
mp.add_key_binding(nil, "speed-toggle", toggle_speed)
mp.add_key_binding(nil, "play-last", play_last_played)
mp.add_key_binding(nil, "toggle", function() ui.toggle() end)
mp.add_key_binding(nil, "history", function() ui.open() end)
mp.add_key_binding(nil, "history-vanilla", function() vanilla_menu.open() end)
mp.add_key_binding(nil, "history-uosc", function() uosc_menu.open(1) end)

mp.register_script_message("open", function() ui.open() end)
mp.register_script_message("toggle", function() ui.toggle() end)
mp.register_script_message("toggle-tracking", toggle_tracking)
mp.register_script_message("open-vanilla", function() vanilla_menu.open() end)
mp.register_script_message("open-uosc", function(page) uosc_menu.open(tonumber(page) or 1) end)
mp.register_script_message("uosc-page", function(page) uosc_menu.update(tonumber(page) or 1) end)

local function uosc_show_prune_confirm()
    local confirm_menu = {
        type = "janus_confirm",
        title = "Prune Missing Files?",
        footnote = "Remove all deleted or moved files from history.",
        callback = {"janus", "uosc-event"},
        items = {
            {
                title = "Yes, prune missing files",
                icon = "delete_sweep",
                value = { action = "do_prune" },
            },
            {
                title = "Cancel",
                icon = "close",
                value = { action = "cancel_confirm" },
            },
        },
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(confirm_menu))
end

local function uosc_show_clear_confirm()
    local confirm_menu = {
        type = "janus_confirm",
        title = "Clear All History?",
        footnote = "Permanently delete all playback history. This cannot be undone.",
        callback = {"janus", "uosc-event"},
        items = {
            {
                title = "Yes, clear all history",
                icon = "delete_forever",
                bold = true,
                value = { action = "do_clear" },
            },
            {
                title = "Cancel",
                icon = "close",
                value = { action = "cancel_confirm" },
            },
        },
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(confirm_menu))
end

mp.register_script_message("uosc-event", function(json_str)
    local event = utils.parse_json(json_str)
    if not event then return end

    if event.type == "activate" then
        local val = event.value
        if event.action == "delete" then
            local path = val and val.path
            if path then
                storage.remove(path)
                msg.info("Janus: removed from history: " .. path)
                if uosc_menu.search_query and uosc_menu.search_query ~= "" then
                    local json = utils.format_json(uosc_build_menu(nil, uosc_menu.search_query))
                    mp.commandv("script-message-to", "uosc", "update-menu", json)
                else
                    uosc_menu.update(uosc_menu.current_page or 1)
                end
            end
        elseif event.action == "replay" then
            local path = val and val.path
            if path then
                if val.missing or (not is_url(path) and not file_exists(path)) then
                    mp.osd_message("Janus: File has been moved or deleted", 3)
                    return
                end
                mp.commandv("script-message-to", "uosc", "close-menu", "janus_history")
                play_history_item({
                    path = path,
                    pos = 0,
                    duration = val.duration,
                }, true)
            end
        elseif val and type(val) == "table" then
            if val.action == "confirm_prune" then
                uosc_show_prune_confirm()
            elseif val.action == "confirm_clear" then
                uosc_show_clear_confirm()
            elseif val.action == "do_prune" then
                local count = storage.prune_missing()
                if count == 0 then
                    mp.osd_message("Janus: No missing files found", 2)
                else
                    mp.osd_message(string.format("Janus: Pruned %d missing file%s", count, count == 1 and "" or "s"), 2)
                end
                uosc_menu.update(1)
            elseif val.action == "do_clear" then
                storage.clear()
                mp.osd_message("Janus: Playback history cleared", 2)
                uosc_menu.update(1)
            elseif val.action == "cancel_confirm" then
                uosc_menu.update(uosc_menu.current_page or 1)
            elseif val.action == "page" then
                uosc_menu.search_query = nil
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
                }, true)
            end
        end
    elseif event.type == "key" then
        local key = event.key or event.id
        if key == "left" or key == "h" then
            local cur_page = uosc_menu.current_page or 1
            if cur_page > 1 then
                uosc_menu.search_query = nil
                uosc_menu.update(cur_page - 1)
            end
        elseif key == "right" or key == "l" then
            local cur_page = uosc_menu.current_page or 1
            local page_data = storage.get_page(cur_page)
            if page_data and page_data.has_next then
                uosc_menu.search_query = nil
                uosc_menu.update(cur_page + 1)
            end
        elseif key == "p" then
            uosc_show_prune_confirm()
        elseif key == "c" then
            uosc_show_clear_confirm()
        elseif key == "del" then
            local sel = event.selected_item and event.selected_item.value
            local path = sel and sel.path
            if path then
                storage.remove(path)
                msg.info("Janus: removed from history via [Del]: " .. path)
                if uosc_menu.search_query and uosc_menu.search_query ~= "" then
                    local json = utils.format_json(uosc_build_menu(nil, uosc_menu.search_query))
                    mp.commandv("script-message-to", "uosc", "update-menu", json)
                else
                    uosc_menu.update(uosc_menu.current_page or 1)
                end
            end
        elseif key == "r" then
            local sel = event.selected_item and event.selected_item.value
            local path = sel and sel.path
            if path then
                if sel.missing or (not is_url(path) and not file_exists(path)) then
                    mp.osd_message("Janus: File has been moved or deleted", 3)
                    return
                end
                mp.commandv("script-message-to", "uosc", "close-menu", "janus_history")
                play_history_item({
                    path = path,
                    pos = 0,
                    duration = sel.duration,
                }, true)
            end
        end
    end
end)

mp.register_script_message("uosc-search", function(query)
    query = query or ""
    if query:match("^%s*$") then
        uosc_menu.search_query = nil
        uosc_menu.update(uosc_menu.current_page or 1)
    else
        uosc_menu.search_query = query
        local json = utils.format_json(uosc_build_menu(nil, query))
        mp.commandv("script-message-to", "uosc", "update-menu", json)
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
mp.register_script_message("seek-undo", seek_undo)
mp.register_script_message("seek-redo", seek_redo)

msg.info("Janus initialized successfully")
