local mp = require("mp")
local msg = require("mp.msg")
local opt = require("mp.options")
local utils = require("mp.utils")

local config = {
    history_file = "~~/janus_history.jsonl",
    max_history = 5000,
    compaction_threshold = 10000,
    page_size = 20,
}

opt.read_options(config, "janus")
local history_path = mp.command_native({"expand-path", config.history_file})

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

msg.info("Janus: storage initialized")
