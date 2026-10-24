-- quick_cut i18n：轻量语言包管理
-- 语言包放在 scripts/quick_cut/i18n/<locale>.lua，每个文件返回一个 {key=文本} 表。
-- 放置新的语言包文件即可被自动发现，无需改动脚本；缺失的键会回落到英语，再缺失则显示键名本身。
local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local M = {}

M.DEFAULT_LOCALE = "zh_CN"
M.FALLBACK_LOCALE = "en_US"

local packs = {}        -- locale -> table
local available = {}    -- locale -> true
local current = M.DEFAULT_LOCALE
local subdir = "i18n"

-- 取脚本所在目录下的 i18n/ 路径
local function i18n_dir()
    local base = mp.get_script_directory and mp.get_script_directory() or nil
    if not base then return nil end
    return utils.join_path(base, subdir)
end

-- 扫描 i18n 目录，登记所有可用的语言包
function M.scan()
    local dir = i18n_dir()
    if not dir then return end
    local files = utils.readdir(dir, "files")
    if not files then return end
    local found = {}
    for _, name in ipairs(files) do
        local locale = name:match("^(.+)%.lua$")
        -- 排除 i18n.lua 自身，避免其被登记为假语言包（误入 M.list / M.has）
        if locale and locale ~= "i18n" then found[locale] = true end
    end
    available = found
end

-- 载入指定语言（幂等，已载入则直接复用）
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
    -- 语言包存在但内容有错：记日志并回落到默认语言，不让脚本挂掉
    if available[locale] then
        msg.warn(string.format("quick_cut i18n: locale '%s' failed to load: %s", locale, tostring(pack)))
    end
    return nil
end

-- 语言包是否存在（含尚未载入、仅目录扫描发现的）
function M.has(locale)
    locale = tostring(locale or "")
    if packs[locale] then return true end
    return available[locale] == true
end

-- 所有可用语言（排序后）
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
    -- 默认语言作为最终兜底，先载入
    M.load(M.FALLBACK_LOCALE)
end

-- 当前语言
function M.current() return current end

-- 设置语言。返回实际生效的语言（请求的语言不可用时回落到默认语言）。
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

-- 按 mpv 的语言属性猜测：osd-lang 形如 "zh-CN" / "en"，转成 zh_CN / en 再匹配已安装包
function M.detect()
    local raw = tostring(mp.get_property("osd-lang") or "")
    if raw == "" then raw = tostring(mp.get_property("options/language") or "") end
    if raw == "" then return M.DEFAULT_LOCALE end
    local candidates = {}
    -- zh-CN / zh_CN / zh_Hans_CN
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

-- 取文本。支持 string.format 占位符；键缺失时依次回落英语包、再回落键名。
function M.t(key, ...)
    M.ensure_loaded()
    local pack = packs[current]
    local s = pack and pack[key]
    if s == nil and current ~= M.FALLBACK_LOCALE then
        local fallback = packs[M.FALLBACK_LOCALE]
        s = fallback and fallback[key]
    end
    if s == nil then
        -- 键缺失不应中断渲染，直接显示键名便于定位未翻译项
        s = key
    end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, s, ...)
        if ok then return formatted end
        return s
    end
    return s
end

-- 便捷别名：L("key")
setmetatable(M, {__call = function(_, key, ...) return M.t(key, ...) end})

return M
