-- quick_cut 模块化引导器（脚本包入口；版本单一来源：core/config.lua 的 M.VERSION）
-- mpv 加载 scripts/quick_cut/ 目录时把 main.lua 作为入口，因此无需再在 scripts/
-- 顶层放置 quick_cut.lua。模块按职责收拢到子目录：
--   core/   核心逻辑与领域模块（core/config/crop/editor/export/session/takeover/util/ui）
--   i18n/   语言包（i18n.lua 加载器 + zh_CN/en_US 语言包）
--   fonts/  图标字体（Quickcut_icons.ttf + 同目录的 Apache-2.0 许可声明）
-- 外观全部由 core/ui.lua 的内置常量决定。
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
            -- 跳过空段
        elseif out == "" then
            out = p
        elseif out:sub(-1) == "/" or out:sub(-1) == "\\" then
            out = out .. p
        else
            out = out .. sep .. p
        end
    end
    -- 统一分隔符，避免 module_dir 以 / 结尾、后续段用 sep 拼接出现混用
    out = out:gsub("[/\\]", sep)
    return out
end

-- 脚本包目录 = 本文件所在目录（scripts/quick_cut/）
local module_dir = dirname(debug.getinfo(1,"S").source or "")

-- package.path 加入核心逻辑目录与语言包目录，使 require "config"/"core"/"i18n" 等短名可解析
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
