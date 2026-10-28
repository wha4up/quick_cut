local mp = require "mp"
local utils = require "mp.utils"
local config = require "config"

local M = {}
local manager = {
    active = false,
    native_visibility = "auto",
    uosc_disabled = false,
}

local BUTTON_NAME = "quick_cut"
local BUTTON_ICON = "cut"
local deps = {}

function M.init(d)
    if d then for k, v in pairs(d) do deps[k] = v end end
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

function M.force_restore()
    mp.commandv("script-message-to", "uosc", "disable-elements", "quick_cut", "")
    set_native_osc_visibility("auto")
    manager.active = false
    manager.uosc_disabled = false
    mp.commandv("script-message-to", "uosc", "flash-ui")
end

return M
