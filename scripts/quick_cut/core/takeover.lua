-- quick_cut 原生 OSC / uosc 接管
local mp = require "mp"
local utils = require "mp.utils"
local config = require "config"

local M = {}
local manager = {
    active = false,
    native_visibility = "auto",
    uosc_disabled = false,
}

-- 只向 uosc 注册按钮的外形与动作，绝不改写用户的 uosc.conf。
-- 用户自己在 controls= 里加 button:quick_cut 即可，位置完全由用户决定——
-- 自动插入无法知道该放左组还是右组（uosc 的 controls= 是扁平列表，左右分组
-- 靠 space 撑开），硬插只会打乱用户已排好的布局。
local BUTTON_NAME = "quick_cut"
local BUTTON_ICON = "cut"
local deps = {}

function M.init(d)
    if d then for k, v in pairs(d) do deps[k] = v end end
    -- 定义按钮（外观与点击行为）。用户没在 controls= 里加这个按钮时，
    -- 这条 set-button 只是把定义挂在 uosc 里，不会凭空显示任何东西。
    local tooltip = (deps.L and deps.L("hint.studio_button_tooltip")) or "Quick Cut"
    mp.commandv("script-message-to", "uosc", "set-button", BUTTON_NAME, utils.format_json({
        icon = BUTTON_ICON,
        tooltip = tooltip,
        command = "script-message-to " .. mp.get_script_name() .. " toggle_studio_mode",
    }))
end

local function normalize_osc_visibility(value)
    value = tostring(value or ""):lower()
    if value == "auto" or value == "always" or value == "never" then return value end
    return nil
end

function M.read_native_osc_visibility()
    local value = normalize_osc_visibility(mp.get_property("options/osc-visibility"))
    if value then return value end
    local path = mp.find_config_file("script-opts/osc.conf")
    if path then
        local conf = config.parse_conf(path)
        value = normalize_osc_visibility(conf.visibility)
        if value then return value end
    end
    return "auto"
end

local function set_native_osc_visibility(value)
    value = normalize_osc_visibility(value) or "auto"
    pcall(mp.set_property, "options/osc-visibility", value)
    mp.commandv("script-message", "osc-visibility", value)
    mp.commandv("script-message-to", "osc", "osc-visibility", value)
end

function M.hide()
    local opts = config.opts
    if manager.active or not opts.takeover_osc then return end
    manager.active = true
    manager.native_visibility = M.read_native_osc_visibility()
    set_native_osc_visibility("never")

    if opts.takeover_uosc then
        -- uosc 支持的 API：在指定 owner 名下禁用元素。
        -- 用同一 owner 发送空列表即可可靠地恢复这些元素。
        mp.commandv("script-message-to", "uosc", "disable-elements",
            "quick_cut", opts.uosc_takeover_elements)
        manager.uosc_disabled = true
    end
end

function M.restore()
    local opts = config.opts
    if not manager.active then return end

    if opts.takeover_uosc and manager.uosc_disabled then
        mp.commandv("script-message-to", "uosc", "disable-elements", "quick_cut", "")
        manager.uosc_disabled = false
        if opts.flash_osc_on_restore then
            mp.add_timeout(0.05, function()
                mp.commandv("script-message-to", "uosc", "flash-ui")
            end)
        end
    end

    set_native_osc_visibility(manager.native_visibility)
    manager.active = false
    manager.native_visibility = "auto"
end

-- restore_player_osc 脚本消息：无条件恢复，不依赖接管状态。
function M.force_restore()
    mp.commandv("script-message-to", "uosc", "disable-elements", "quick_cut", "")
    set_native_osc_visibility("auto")
    manager.active = false
    manager.uosc_disabled = false
    mp.commandv("script-message-to", "uosc", "flash-ui")
end

return M
