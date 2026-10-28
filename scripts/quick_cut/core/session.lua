local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local U = require "util"

local M = {}
local MAX_SESSIONS = 20

local corrupted = false

local function legacy_path()
    local ok, path = pcall(mp.command_native, {"expand-path", "~~state/quick_cut_sessions.json"})
    if not ok or not path or path == "" then return nil end
    return path
end

function M.store_path()
    local dir = _G.QUICK_CUT_BOOTSTRAP and _G.QUICK_CUT_BOOTSTRAP.module_dir
    if type(dir) == "string" and dir ~= "" then
        return (dir:gsub("[/\\]+$", "")) .. "/quick_cut_sessions.json"
    end
    return legacy_path()
end

local function read_db()
    local path = M.store_path()
    if not path then
        msg.warn("quick_cut: session store unavailable (module_dir and legacy path both failed)")
        return {}, nil
    end
    local f = io.open(path, "r")
    if not f then
        local lp = legacy_path()
        if lp and lp ~= path then f = io.open(lp, "r") end
    end
    if not f then corrupted = false; return {}, nil end
    local content = f:read("*a")
    local closed, cerr = f:close()
    if not closed then
        msg.warn("quick_cut: session read close failed: " .. tostring(cerr))
    end
    -- 文件不存在/空文件 = 正常的"没有存档"，必须顺带解除损坏保护，
    -- 否则"删掉坏文件"这条恢复指引永远不生效（要重启 mpv 才行）。
    if not content or content == "" then corrupted = false; return {}, nil end
    local data = utils.parse_json(content)
    if type(data) ~= "table" then
        corrupted = true
        msg.warn("quick_cut: session file corrupted or unreadable, writes are refused until it is fixed: " .. tostring(path))
        return nil, "corrupted"
    end
    corrupted = false
    return data, nil
end

local function write_db(db)
    local path = M.store_path()
    if not path then
        msg.warn("quick_cut: session store unavailable, progress not saved this time")
        return false
    end
    if corrupted then
        msg.warn("quick_cut: session write skipped to protect existing data; delete the file manually to reset: " .. tostring(path))
        return false
    end
    -- 原子提交：先写临时文件再 rename。半截 JSON 落盘会让下一轮读取判为损坏，
    -- 触发写入保护，因此必须保证要么整库写入成功、要么保持旧库不动。
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        msg.warn("quick_cut: cannot write session file: " .. tostring(path))
        return false
    end
    local wrote, werr = f:write(utils.format_json(db) or "{}")
    local closed = f:close()
    if not wrote or not closed then
        msg.warn("quick_cut: session write failed: " .. tostring(werr) .. " (" .. tostring(tmp) .. ")")
        os.remove(tmp)
        return false
    end
    local renamed, rerr = U.replace_file(tmp, path)
    if not renamed then
        msg.warn("quick_cut: session replace failed: " .. tostring(tmp) .. " -> " .. tostring(path) .. " (" .. tostring(rerr) .. ")")
        os.remove(tmp)
        return false
    end
    return true
end

local function prune(db)
    local entries = {}
    for k, v in pairs(db) do entries[#entries + 1] = {key = k, at = tonumber(v and v.saved_at) or 0} end
    table.sort(entries, function(a, b) return a.at < b.at end)
    while #entries > MAX_SESSIONS do
        db[table.remove(entries, 1).key] = nil
    end
end

function M.save(key, data)
    if not key or key == "" or type(data) ~= "table" then return false end
    local db = read_db()
    if not db then return false end
    db[key] = {saved_at = os.time(), data = data}
    prune(db)
    return write_db(db)
end

function M.load(key)
    if not key or key == "" then return nil end
    local db = read_db()
    if not db then return nil end
    local entry = db[key]
    return entry and entry.data or nil
end

function M.clear(key)
    if not key or key == "" then return false end
    local db = read_db()
    if not db then return false end
    if db[key] == nil then return true end
    db[key] = nil
    return write_db(db)
end

return M
