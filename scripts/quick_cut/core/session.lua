-- quick_cut session persistence
-- 以媒体路径为键，把剪辑进度（片段、模式）存到 mpv 状态目录，跨会话恢复。
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

local M = {}
local MAX_SESSIONS = 20

-- 库文件存在但无法解析时置位：此后拒绝任何写入，防止"损坏 → 读到空表 →
-- 下一次 save 用单条记录整库覆盖"，把其余媒体的剪辑进度无痕清掉。
local corrupted = false

-- 旧位置（mpv 状态目录）。只在迁移时读一次：老用户的剪辑进度不能因为换位置丢掉。
local function legacy_path()
    local ok, path = pcall(mp.command_native, {"expand-path", "~~state/quick_cut_sessions.json"})
    if not ok or not path or path == "" then return nil end
    return path
end

-- 会话库默认放**脚本目录**（`~~/scripts/quick_cut/quick_cut_sessions.json`）：
-- 与脚本同生命周期，卸载/搬移脚本时状态一起走，也不会把文件留在 mpv 状态目录里。
-- 脚本目录由 main.lua 启动时写进 QUICK_CUT_BOOTSTRAP.module_dir（core 也从这里取）。
function M.store_path()
    local dir = _G.QUICK_CUT_BOOTSTRAP and _G.QUICK_CUT_BOOTSTRAP.module_dir
    if type(dir) == "string" and dir ~= "" then
        return (dir:gsub("[/\\]+$", "")) .. "/quick_cut_sessions.json"
    end
    return legacy_path()
end

-- 成功返回 db 表；文件不存在/为空视为首次运行（返回空表，不算损坏）。
-- 损坏时返回 nil，置位 corrupted 并告警，交由调用方中止写操作。
local function read_db()
    local path = M.store_path()
    if not path then
        -- 脚本目录与旧位置都取不到（极罕见）：读会静默当"首次运行"，写会静默失败 —— 必须留痕
        msg.warn("quick_cut: session store unavailable (module_dir and legacy path both failed)")
        return {}, nil
    end
    local f = io.open(path, "r")
    if not f then
        -- 新位置还没有这个文件：读一次旧位置（迁移），下次保存就落到脚本目录
        local lp = legacy_path()
        if lp and lp ~= path then f = io.open(lp, "r") end
    end
    if not f then return {}, nil end
    local content = f:read("*a")
    local closed, cerr = f:close()
    if not closed then
        -- 读路径的 close 失败不致命，但必须留痕（与写侧一致；静默失败是历史事故的温床）
        msg.warn("quick_cut: session read close failed: " .. tostring(cerr))
    end
    if not content or content == "" then return {}, nil end
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
        -- 同 read_db：没有这一行，用户会以为"进度一直在存"，直到下次打开发现全丢
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
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then
        -- Windows 的 C rename 在目标已存在时直接失败（"File exists"），不是 POSIX 的原子替换。
        -- 故先删掉旧文件再重试一次；仍失败才放弃。
        os.remove(path)
        renamed, rerr = os.rename(tmp, path)
    end
    if not renamed then
        msg.warn("quick_cut: session atomic rename failed: " .. tostring(tmp) .. " -> " .. tostring(path) .. " (" .. tostring(rerr) .. ")")
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
    if not db then return false end -- 库损坏：拒绝写入，保护其余会话
    db[key] = {saved_at = os.time(), data = data}
    prune(db)
    return write_db(db)
end

function M.load(key)
    if not key or key == "" then return nil end
    local db = read_db()
    if not db then return nil end -- 库损坏：当作无会话处理
    local entry = db[key]
    return entry and entry.data or nil
end

function M.clear(key)
    if not key or key == "" then return false end
    local db = read_db()
    if not db then return false end -- 库损坏：拒绝写入
    if db[key] == nil then return true end
    db[key] = nil
    return write_db(db)
end

return M
