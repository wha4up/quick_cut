local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local M = {}

M.DEFAULT_LOCALE = "zh_CN"
M.FALLBACK_LOCALE = "en_US"

local packs = {}
local available = {}
local current = M.DEFAULT_LOCALE
local subdir = "i18n"

local function i18n_dir()
    local base = mp.get_script_directory and mp.get_script_directory() or nil
    if not base then return nil end
    return utils.join_path(base, subdir)
end

function M.scan()
    local dir = i18n_dir()
    if not dir then return end
    local files = utils.readdir(dir, "files")
    if not files then return end
    local found = {}
    for _, name in ipairs(files) do
        local locale = name:match("^(.+)%.lua$")
        if locale and locale ~= "i18n" then found[locale] = true end
    end
    available = found
end

function M.load(locale)
    locale = tostring(locale or "")
    if locale == "" then return nil end
    if packs[locale] then return packs[locale] end
    local ok, pack = pcall(require, subdir .. "." .. locale)
    if ok and type(pack) == "table" then
        packs[locale] = pack
        available[locale] = true
        return pack
    end
    if available[locale] then
        msg.warn(string.format("quick_cut i18n: locale '%s' failed to load: %s", locale, tostring(pack)))
    end
    return nil
end

function M.has(locale)
    locale = tostring(locale or "")
    if packs[locale] then return true end
    return available[locale] == true
end

function M.list()
    local out = {}
    for locale in pairs(available) do out[#out + 1] = locale end
    table.sort(out)
    return out
end

local loaded = false
function M.ensure_loaded()
    if loaded then return end
    loaded = true
    M.scan()
    M.load(M.FALLBACK_LOCALE)
end

function M.current() return current end

function M.set(locale)
    M.ensure_loaded()
    locale = tostring(locale or "")
    if locale == "" or locale == "auto" then locale = M.detect() end
    local pack = M.load(locale)
    if not pack then
        if locale ~= M.FALLBACK_LOCALE then
            msg.warn(string.format("quick_cut i18n: locale '%s' unavailable; using %s", locale, M.FALLBACK_LOCALE))
        end
        locale = M.FALLBACK_LOCALE
        M.load(locale)
    end
    current = locale
    return current
end

function M.detect()
    local raw = tostring(mp.get_property("osd-lang") or "")
    if raw == "" then raw = tostring(mp.get_property("options/language") or "") end
    if raw == "" then return M.DEFAULT_LOCALE end
    local candidates = {}
    local lang, region = raw:match("^([%a]+)[%-%_]([%a]+)")
    if lang then
        candidates[#candidates + 1] = lang .. "_" .. region:upper()
        candidates[#candidates + 1] = lang .. "_" .. region
        candidates[#candidates + 1] = lang
    else
        candidates[#candidates + 1] = raw
    end
    M.ensure_loaded()
    for _, c in ipairs(candidates) do
        if M.has(c) then return c end
    end
    return M.DEFAULT_LOCALE
end

function M.t(key, ...)
    M.ensure_loaded()
    local pack = packs[current]
    local s = pack and pack[key]
    if s == nil and current ~= M.FALLBACK_LOCALE then
        local fallback = packs[M.FALLBACK_LOCALE]
        s = fallback and fallback[key]
    end
    if s == nil then
        s = key
    end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, s, ...)
        if ok then return formatted end
        return s
    end
    return s
end

setmetatable(M, {__call = function(_, key, ...) return M.t(key, ...) end})

return M
