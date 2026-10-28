local mp = require "mp"
local msg = require "mp.msg"
local sep = package.config:sub(1,1)
local function dirname(path) path = tostring(path or ""):gsub("^@",""); return path:match("^(.*[/\\])") or "" end
local function join(...)
    local parts = {...}
    local out = ""
    for i = 1, #parts do
        local p = parts[i]
        if p == nil then p = "" end
        p = tostring(p)
        if p == "" then
        elseif out == "" then
            out = p
        elseif out:sub(-1) == "/" or out:sub(-1) == "\\" then
            out = out .. p
        else
            out = out .. sep .. p
        end
    end
    out = out:gsub("[/\\]", sep)
    return out
end

local module_dir = dirname(debug.getinfo(1,"S").source or "")

package.path = join(module_dir,"core"..sep.."?.lua")..";"
    .. join(module_dir,"i18n"..sep.."?.lua")..";"
    .. join(module_dir,"?.lua")..";"
    .. join(module_dir,"?"..sep.."init.lua")..";"
    .. package.path

local ok_config, config = pcall(require, "config")
-- require 失败时 VERSION 会静默降级成 unknown，日志里只留下"vunknown bootstrap"这一行，
-- 看起来像正常启动 —— 必须把真正的错误打出来（脚本放错目录/path 拼错都是这个现象）。
if not ok_config then msg.error("quick_cut: cannot load config.lua: " .. tostring(config)) end
local VERSION = (ok_config and config and config.VERSION) and config.VERSION or "unknown"
_G.QUICK_CUT_BOOTSTRAP = {version="v"..VERSION, channel="ui-interaction", module_dir=module_dir, entry_source=debug.getinfo(1,"S").source or ""}
msg.info("quick_cut v"..VERSION.." bootstrap: module_dir="..module_dir)

local run_ok, run_err = pcall(dofile, join(module_dir, "core", "core.lua"))
if not run_ok then
    msg.error("quick_cut core load failed: "..tostring(run_err) .. " | module_dir=" .. tostring(module_dir))
    mp.osd_message("quick_cut bootstrap failed; see the mpv log for details", 7)
end
