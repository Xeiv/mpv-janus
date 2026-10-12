local mp = require("mp")
local msg = require("mp.msg")
local opt = require("mp.options")
local utils = require("mp.utils")

local config = {
    history_file = "~~/janus_history.jsonl",
    max_history = 5000,
    compaction_threshold = 10000,
    page_size = 20,
    watch_threshold = 5,
    update_interval = 30,
    save_on_pause = true,
    log_urls = true,
    resume_offset = 0,
}

opt.read_options(config, "janus")
local history_path = mp.command_native({"expand-path", config.history_file})

local function format_duration(seconds)
    if not seconds or seconds < 0 or seconds ~= seconds then return "00:00" end
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

local function escape_ass(text)
    if not text then return "" end
    local escaped = tostring(text)
    escaped = escaped:gsub("\\", "\\\239\187\191")
    escaped = escaped:gsub("{", "\\{")
    escaped = escaped:gsub("}", "\\}")
    return escaped
end

local function truncate_string(str, max_len)
    if not str then return "" end
    if #str <= max_len then return str end
    return str:sub(1, max_len - 3) .. "..."
end

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

local function play_history_item(item)
    if not item or not item.path then return end
    local pos = item.pos or 0
    local start_pos = math.max(0, pos - config.resume_offset)

    if item.duration and item.duration > 30 and (item.duration - start_pos) < 10 then
        start_pos = 0
    end

    if start_pos > 0 then
        mp.commandv("loadfile", item.path, "replace", "start=" .. tostring(start_pos))
    else
        mp.commandv("loadfile", item.path, "replace")
    end
end

-- Playback Tracker
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

local function tracker_save()
    if not tracker.current.path or not tracker.current.qualified then
        return
    end

    tracker.current.pos = mp.get_property_number("time-pos", tracker.current.pos) or tracker.current.pos
    tracker.current.duration = mp.get_property_number("duration", tracker.current.duration) or tracker.current.duration
    local title = mp.get_property("media-title")
    if title and title ~= "" then
        tracker.current.title = title
    end

    storage.append({
        path = tracker.current.path,
        title = tracker.current.title,
        pos = math.floor((tracker.current.pos or 0) * 10) / 10,
        duration = math.floor(tracker.current.duration or 0),
        time = os.time(),
    })
end

local function tracker_on_tick()
    if tracker.is_paused or not tracker.current.path then
        return
    end

    tracker.current.watch_time = tracker.current.watch_time + 1

    if not tracker.current.qualified and tracker.current.watch_time >= config.watch_threshold then
        tracker.current.qualified = true
        tracker_save()
    elseif tracker.current.qualified and (tracker.current.watch_time % config.update_interval == 0) then
        tracker_save()
    end
end

-- Vanilla OSD Menu
local vanilla_menu = {
    is_open = false,
    current_page = 1,
    page_data = nil,
    selected_index = 1,
    overlay = nil,
    key_bindings = {},
}

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

            local pos_str = format_duration(item.pos or 0)
            local dur_str = format_duration(item.duration or 0)
            local rel_time = format_relative_time(item.time, now)
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
        local items = vanilla_menu.page_data and vanilla_menu.page_data.items or {}
        local item = items[vanilla_menu.selected_index]
        if item then
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

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path or path == "" then
        tracker.current.path = nil
        return
    end

    if not config.log_urls and is_url(path) then
        tracker.current.path = nil
        return
    end

    tracker.current = {
        path = path,
        title = mp.get_property("media-title") or get_filename(path),
        pos = mp.get_property_number("time-pos", 0) or 0,
        duration = mp.get_property_number("duration", 0) or 0,
        watch_time = 0,
        qualified = false,
    }

    tracker.is_paused = mp.get_property_bool("pause", false)

    if config.watch_threshold <= 0 then
        tracker.current.qualified = true
        tracker_save()
    end
end)

mp.observe_property("pause", "bool", function(_, paused)
    tracker.is_paused = paused
    if paused and config.save_on_pause and tracker.current.qualified then
        tracker_save()
    end
end)

mp.register_event("end-file", function()
    if tracker.current.qualified then
        tracker_save()
    end
    tracker.current.path = nil
    tracker.current.qualified = false
    tracker.current.watch_time = 0
end)

tracker.timer = mp.add_periodic_timer(1, tracker_on_tick)

mp.add_key_binding(nil, "open", vanilla_menu.open)
mp.add_key_binding(nil, "history", vanilla_menu.open)
msg.info("Janus initialized successfully")
