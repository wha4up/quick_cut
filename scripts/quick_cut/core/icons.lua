-- quick_cut 图标库（**字体字形**）
-- 图标 = 一个码位，用字体 Quickcut_icons 绘制；字形名与设计源一一对应。
-- 码位：按文件名编号序第 i 个 = U+E900+i（i 从 0 起）；编号由 tools/icons_renumber.py 维护。

local utils = require "mp.utils"

local glyph = {
    ["add"] = "\238\164\128",                   -- U+E900
    ["alert"] = "\238\164\129",                 -- U+E901
    ["audio"] = "\238\164\130",                 -- U+E902
    ["audio_bitrate"] = "\238\164\131",         -- U+E903
    ["audio_codec"] = "\238\164\132",           -- U+E904
    ["auto_fix"] = "\238\164\133",              -- U+E905
    ["cancel"] = "\238\164\134",                -- U+E906
    ["channels"] = "\238\164\135",              -- U+E907
    ["check"] = "\238\164\136",                 -- U+E908
    ["chevron"] = "\238\164\137",               -- U+E909
    ["clear"] = "\238\164\138",                 -- U+E90A
    ["codec_format"] = "\238\164\139",          -- U+E90B
    ["coding"] = "\238\164\140",                -- U+E90C
    ["container"] = "\238\164\141",             -- U+E90D
    ["copy"] = "\238\164\142",                  -- U+E90E
    ["crop"] = "\238\164\143",                  -- U+E90F
    ["del"] = "\238\164\144",                   -- U+E910
    ["down"] = "\238\164\145",                  -- U+E911
    ["edit"] = "\238\164\146",                  -- U+E912
    ["exit"] = "\238\164\147",                  -- U+E913
    ["export"] = "\238\164\148",                -- U+E914
    ["export_kind"] = "\238\164\149",           -- U+E915
    ["extra_processing"] = "\238\164\150",      -- U+E916
    ["fast_start"] = "\238\164\151",            -- U+E917
    ["gif"] = "\238\164\152",                   -- U+E918
    ["goal_lossless"] = "\238\164\153",         -- U+E919
    ["goal_quality"] = "\238\164\154",          -- U+E91A
    ["goal_size"] = "\238\164\155",             -- U+E91B
    ["goal_speed"] = "\238\164\156",            -- U+E91C
    ["images"] = "\238\164\157",                -- U+E91D
    ["in"] = "\238\164\158",                    -- U+E91E
    ["info"] = "\238\164\159",                  -- U+E91F
    ["manage"] = "\238\164\160",                -- U+E920
    ["merge"] = "\238\164\161",                 -- U+E921
    ["mine"] = "\238\164\162",                  -- U+E922
    ["modified"] = "\238\164\163",              -- U+E923
    ["optimize"] = "\238\164\164",              -- U+E924
    ["out"] = "\238\164\165",                   -- U+E925
    ["output_mode"] = "\238\164\166",           -- U+E926
    ["param_item"] = "\238\164\167",            -- U+E927
    ["parts"] = "\238\164\168",                 -- U+E928
    ["pixel_format"] = "\238\164\169",          -- U+E929
    ["position"] = "\238\164\170",              -- U+E92A
    ["preset"] = "\238\164\171",                -- U+E92B
    ["quality"] = "\238\164\172",               -- U+E92C
    ["revert"] = "\238\164\173",                -- U+E92D
    ["sample_rate"] = "\238\164\174",           -- U+E92E
    ["save"] = "\238\164\175",                  -- U+E92F
    ["segments"] = "\238\164\176",              -- U+E930
    ["session_restore"] = "\238\164\177",       -- U+E931
    ["settings_suggest"] = "\238\164\178",      -- U+E932
    ["size"] = "\238\164\179",                  -- U+E933
    ["source_codec"] = "\238\164\180",          -- U+E934
    ["split"] = "\238\164\181",                 -- U+E935
    ["stop"] = "\238\164\182",                  -- U+E936
    ["subtitle"] = "\238\164\183",              -- U+E937
    ["unsaved"] = "\238\164\184",               -- U+E938
    ["up"] = "\238\164\185",                    -- U+E939
    ["video"] = "\238\164\186",                 -- U+E93A
    ["video_codec"] = "\238\164\187",           -- U+E93B
    ["wave"] = "\238\164\188",                  -- U+E93C
    ["wysiwyg"] = "\238\164\189",               -- U+E93D
    ["animated_format"] = "\238\164\190",       -- U+E93E
    ["animated_fps"] = "\238\164\191",          -- U+E93F
    ["animated_loop"] = "\238\165\128",         -- U+E940
    ["animated_width"] = "\238\165\129",        -- U+E941
    ["image_mode"] = "\238\165\130",            -- U+E942
    ["keyframe_limit"] = "\238\165\131",        -- U+E943
    ["keyframe_stride"] = "\238\165\132",       -- U+E944
    ["scale_mode"] = "\238\165\133",            -- U+E945
    ["tile_grid"] = "\238\165\134",             -- U+E946
}

local function file_exists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end
local function expand(p)
    local ok, out = pcall(function() return mp.command_native({ "expand-path", p }) end)
    return ok and out or p
end

local ICON_FONT = "Quickcut_icons.ttf"
local FONT_DIR = "~~/scripts/quick_cut/fonts"
local FONT_EXTS = { ttf = true, otf = true, ttc = true, otc = true, pfb = true }

local function has_icon_font(dir)
    if not dir or dir == "" then return false end
    local base = expand(dir)
    return base ~= "" and file_exists(base .. "/" .. ICON_FONT)
end
local function dir_has_fonts(dir)
    if not dir or dir == "" then return false end
    local base = expand(dir)
    if base == "" then return false end
    local ok, items = pcall(utils.readdir, base)
    if not ok or type(items) ~= "table" then return false end
    for _, it in ipairs(items) do
        local name = type(it) == "table" and it.name or tostring(it)
        local ext = tostring(name):match("%.([%w]+)$")
        if ext and FONT_EXTS[ext:lower()] then return true end
    end
    return false
end

local FONT_OK = false
local overridden = false
local osd_dir = mp.get_property("options/osd-fonts-dir") or ""
if osd_dir ~= "" then
    if has_icon_font(osd_dir) then
        FONT_OK = true
    elseif not dir_has_fonts(osd_dir) then
        if pcall(function() mp.set_property("options/osd-fonts-dir", FONT_DIR) end) then
            FONT_OK = has_icon_font(FONT_DIR)
            overridden = FONT_OK
        end
    end
else
    if has_icon_font("~~/fonts") then
        FONT_OK = true
    elseif not dir_has_fonts("~~/fonts") then
        if pcall(function() mp.set_property("options/osd-fonts-dir", FONT_DIR) end) then
            FONT_OK = has_icon_font(FONT_DIR)
            overridden = FONT_OK
        end
    end
end
if not FONT_OK then
    mp.msg.warn("quick_cut: libass 扫不到图标字体 Quickcut_icons.ttf ⇒ 自动回退纯文本主题（图标全部隐藏）。"
        .. "修复：把 scripts/quick_cut/fonts/Quickcut_icons.ttf 复制到 portable_config/fonts/，"
        .. "或在 mpv.conf 里写 osd-fonts-dir=~~/scripts/quick_cut/fonts")
    for k in pairs(glyph) do glyph[k] = "" end
elseif overridden then
    mp.msg.info("quick_cut: osd-fonts-dir 原目录里没有可用字体，已临时指向 " .. FONT_DIR .. "（不改 mpv.conf）")
end

return glyph
