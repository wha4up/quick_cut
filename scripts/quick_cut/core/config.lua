local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"
local utils = require "mp.utils"
-- 必须用短名 "i18n"（与 core.lua 一致）：package.path 中 i18n/?.lua 与 ./?.lua 都能把
-- "i18n" 与 "i18n.i18n" 解析到同一个文件，但 package.loaded 按模块名缓存，两个名字会
-- 产生两个状态独立的实例（语言设置只对其中一个生效）。
local I18n = require "i18n"
local U = require "util"

local M = {}

M.VERSION = "1.1"

M.EXPORT_PRESETS = {
original = {label = "preset.original", from_source = true},
    web = {label = "preset.web", encode_container="mp4", video_codec="libx264", preset="veryfast",
        video_quality_mode="crf", video_quality=23, audio_codec="aac", audio_bitrate="128k",
        pixel_format="yuv420p", faststart=true},
    high = {label = "preset.high", encode_container="mp4", video_codec="libx264", preset="slow",
        video_quality_mode="crf", video_quality=16, audio_codec="aac", audio_bitrate="256k",
        pixel_format="yuv420p", faststart=true},
    archive = {label = "preset.archive", encode_container="mkv", video_codec="libx264", preset="veryslow",
        video_quality_mode="crf", video_quality=14, audio_codec="flac", audio_bitrate="",
        pixel_format="yuv420p", faststart=false},
}
M.PRESET_ORDER = {"original", "web", "high", "archive"}
M.current_preset = "original"
M.custom_presets = {}

local PRESET_FIELDS = {
    container = "encode_container", video_codec = "video_codec", preset = "preset",
    quality_mode = "video_quality_mode", quality = "video_quality", bitrate = "video_bitrate",
    audio_codec = "audio_codec", audio_bitrate = "audio_bitrate",
    pixel_format = "pixel_format", faststart = "faststart",
    args = "args", extra_args = "extra_args",
}

function M.load_custom_presets()
    local path = mp.find_config_file("script-opts/quick_cut.conf")
    if not path then return {} end
    local conf = M.parse_conf(path)
    local names = {}
    for raw_name in tostring(conf.export_preset_list or ""):gmatch("[^,]+") do
        local name = raw_name:match("^%s*(.-)%s*$")
        if name ~= "" then names[#names + 1] = name end
    end
    local presets = {}
    for i, label in ipairs(names) do
        local prefix = "export_preset_" .. i .. "_"
        local p = {label = label}
        for suffix, field in pairs(PRESET_FIELDS) do
            local v = conf[prefix .. suffix]
            if v ~= nil and v ~= "" then p[field] = v end
        end
        presets[#presets + 1] = p
    end
    return presets
end

local PRESET_STORE_VERSION = 1
-- 内置预设的键；自定义预设不许用这些名字（否则会顶掉内置项）
M.PRESET_RESERVED = {original = true, default = true, web = true, high = true, archive = true}
M.preset_store = {version = PRESET_STORE_VERSION, default = "", presets = {}}
M.CUSTOM_PRESET_NAMES = {}
local preset_store_corrupt = false

function M.preset_store_path()
    local dir = _G.QUICK_CUT_BOOTSTRAP and _G.QUICK_CUT_BOOTSTRAP.module_dir
    if type(dir) ~= "string" or dir == "" then return nil end
    return (dir:gsub("[/\\]+$", "")) .. "/quick_cut_presets.json"
end

local function empty_store()
    return {version = PRESET_STORE_VERSION, default = "", presets = {}}
end

function M.load_preset_store()
    local path = M.preset_store_path()
    if not path then return empty_store() end
    local f = io.open(path, "r")
    if not f then return empty_store() end
    local content = f:read("*a"); f:close()
    if not content or content == "" then return empty_store() end
    local data = utils.parse_json(content)
    if type(data) ~= "table" or type(data.presets) ~= "table" then
        preset_store_corrupt = true
        msg.warn("quick_cut: preset file corrupted, writes disabled until fixed: " .. tostring(path))
        return empty_store()
    end
    -- 逐项校验："presets 是 table"不够 —— {"presets":[1]} 这种合法 JSON 会让
    -- apply_preset_store 里的 p.name 直接抛错，整个脚本随之加载失败。
    local clean = {}
    for _, p in ipairs(data.presets) do
        if type(p) == "table" and type(p.name) == "string" and p.name ~= ""
            and (p.values == nil or type(p.values) == "table") then
            clean[#clean + 1] = p
        end
    end
    if #clean ~= #data.presets then
        preset_store_corrupt = true
        msg.warn(string.format(
            "quick_cut: preset file has %d malformed entr%s, writes disabled until fixed: %s",
            #data.presets - #clean, (#data.presets - #clean == 1) and "y" or "ies", tostring(path)))
        return empty_store()
    end
    data.presets = clean
    preset_store_corrupt = false
    data.version = PRESET_STORE_VERSION
    if type(data.default) ~= "string" then data.default = "" end
    return data
end

local function write_preset_store(store)
    local path = M.preset_store_path()
    if not path then return false end
    if preset_store_corrupt then return false end
    store.version = PRESET_STORE_VERSION
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        msg.warn("quick_cut: cannot write preset file: " .. tostring(tmp))
        return false
    end
    local wrote, werr = f:write(utils.format_json(store) or "{}")
    local closed = f:close()
    if not wrote or not closed then
        msg.warn("quick_cut: preset write failed: " .. tostring(werr))
        os.remove(tmp); return false
    end
    local renamed, rerr = U.replace_file(tmp, path)
    if not renamed then
        msg.warn("quick_cut: preset replace failed: " .. tostring(tmp) .. " -> " .. tostring(path) .. " (" .. tostring(rerr) .. ")")
        os.remove(tmp); return false
    end
    return true
end

local function preset_find(store, name)
    for i, p in ipairs(store.presets) do
        if p and p.name == name then return i end
    end
    return nil
end

local function valid_preset_name(name)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil, "empty" end
    if #name > 40 then return nil, "long" end
    if M.PRESET_RESERVED[name] or name:match("^[uU]%d+$") then return nil, "taken" end
    return name, nil
end

function M.apply_preset_store(store)
    M.preset_store = store or M.load_preset_store()
    M.CUSTOM_PRESET_NAMES = {}
    for _, p in ipairs(M.preset_store.presets or {}) do
        -- 双保险：即使 store 是从别处直接塞进来的（跳过 load_preset_store 的校验），
        -- 这里也不能对非 table / 非字符串 name / 非 table values 解引用。
        if type(p) == "table" and type(p.name) == "string" and p.name ~= ""
            and type(p.values or {}) == "table" then
            local t = {label = p.name, kind = p.kind, custom = true}
            for k, v in pairs(p.values or {}) do t[k] = v end
            M.EXPORT_PRESETS[p.name] = t
            M.CUSTOM_PRESET_NAMES[#M.CUSTOM_PRESET_NAMES + 1] = p.name
        end
    end
    M.PRESET_ORDER = {"original", "web", "high", "archive"}
    for i = 1, #(M.custom_presets or {}) do M.PRESET_ORDER[#M.PRESET_ORDER + 1] = "u" .. i end
    for _, name in ipairs(M.CUSTOM_PRESET_NAMES) do M.PRESET_ORDER[#M.PRESET_ORDER + 1] = name end
end

function M.export_presets_values(opts, kind)
    local values = {}
    for _, spec in ipairs(M.params_for_kind(kind) or {}) do
        if spec.type == "resolution" then
            values.video_width = opts.video_width
            values.video_height = opts.video_height
        elseif spec.type == "fps" then
            values.output_fps = opts.output_fps
        elseif spec.type == "quality" then
            if opts.video_quality_mode == "bitrate" then values.video_bitrate = opts.video_bitrate
            else values.video_quality = opts.video_quality end
        elseif spec.field then
            values[spec.field] = opts[spec.field]
        end
    end
    return values
end

function M.export_presets_save(name, kind, values)
    local store = M.load_preset_store()
    local clean, err = valid_preset_name(name)
    if not clean then return nil, err end
    local at = preset_find(store, clean)
    local entry = {name = clean, kind = tostring(kind or "video"), values = values or {}}
    if at then store.presets[at] = entry else store.presets[#store.presets + 1] = entry end
    if not write_preset_store(store) then return nil, "write" end
    M.apply_preset_store(store)
    return clean
end

function M.export_presets_rename(old, new)
    local store = M.load_preset_store()
    local at = preset_find(store, old)
    if not at then return nil, "missing" end
    local clean, err = valid_preset_name(new)
    if not clean then return nil, err end
    if clean ~= old and preset_find(store, clean) then return nil, "taken" end
    store.presets[at].name = clean
    if store.default == old then store.default = clean end
    if not write_preset_store(store) then return nil, "write" end
    M.apply_preset_store(store)
    return clean
end

function M.export_presets_delete(name)
    local store = M.load_preset_store()
    local at = preset_find(store, name)
    if not at then return nil, "missing" end
    table.remove(store.presets, at)
    if store.default == name then store.default = "" end
    if not write_preset_store(store) then return nil, "write" end
    M.apply_preset_store(store)
    return true
end

function M.export_presets_set_default(name)
    local store = M.load_preset_store()
    store.default = tostring(name or "")
    if not write_preset_store(store) then return nil, "write" end
    M.preset_store = store
    return true
end

local ENC_FIELDS = {
    "encode_container", "video_codec", "audio_codec", "preset",
    "video_quality_mode", "video_quality", "video_bitrate",
    "audio_bitrate", "pixel_format", "faststart",
    "export_preset_args", "export_preset_extra",
}
M.enc_defaults = nil

local function snapshot_enc(opts)
    local t = {}
    for _, k in ipairs(ENC_FIELDS) do t[k] = opts[k] end
    M.enc_defaults = t
end

M.param_base = nil

local function spec_fields(spec)
    if spec.field then return {spec.field} end
    if spec.type == "resolution" then return {"video_width", "video_height"} end
    if spec.type == "fps" then return {"output_fps"} end
    if spec.type == "quality" then return {"video_quality", "video_bitrate"} end
    return {}
end

local function snapshot_params(opts)
    local t = {}
    for _, set in ipairs({M.ENCODE_PARAMS, M.AUDIO_PARAMS, M.ANIMATED_PARAMS, M.IMAGE_PARAMS, M.SUBTITLE_PARAMS}) do
        for _, spec in ipairs(set or {}) do
            for _, f in ipairs(spec_fields(spec)) do t[f] = opts[f] end
        end
    end
    M.param_base = t
end

local function short_codec(s)
    s = tostring(s or "")
    s = s:match("^([^/]+)") or s
    s = s:gsub("%s*%b()", "")
    return (s:gsub("%s+$", ""))
end

function M.source_info()
    local f = mp.get_property("filename") or ""
    local ext = tostring(f):match("%.([%w]+)$")
    local w = mp.get_property_number("video-params/dw", 0) or 0
    local h = mp.get_property_number("video-params/dh", 0) or 0
    if w <= 0 or h <= 0 then
        w = mp.get_property_number("video-params/w", 0) or 0
        h = mp.get_property_number("video-params/h", 0) or 0
    end
    return {
        ext = ext and tostring(ext):lower() or "",
        video_codec = short_codec(mp.get_property("video-codec")),
        audio_codec = short_codec(mp.get_property("audio-codec")),
        width = w, height = h,
        fps = tonumber((mp.get_property("container-fps")))
            or tonumber((mp.get_property("estimated-vf-fps"))) or 0,
        channels = mp.get_property_number("audio-params/channel-count", 0) or 0,
        has_video = (f ~= "") and (w > 0 and h > 0) or nil,
        has_audio = (f ~= "") and ((mp.get_property("audio-codec") or "") ~= "") or nil,
        samplerate = mp.get_property_number("audio-params/samplerate", 0) or 0,
    }
end

local CONTAINER_BY_EXT = {mp4 = "mp4", m4v = "mp4", mov = "mov", mkv = "mkv", webm = "webm",
    ts = "ts", m2ts = "ts", mts = "ts"}

function M.source_preset_values()
    local src = M.source_info()
    -- 只放"从源推出来的编码参数"。remove_silence / normalize_audio / auto_deinterlace /
    -- auto_crop_black / video_quality_mode 是**用户开关**，不是源的属性：写在这里会被
    -- 启动时的"原始参数"预设强制改回 false/crf，conf 里配的开关就等于没写。
    local t = {video_codec = "copy", audio_codec = "copy", pixel_format = "auto",
        video_width = 0, video_height = 0, output_fps = 0, scale_mode = "fit"}
    local c = CONTAINER_BY_EXT[(src and src.ext) or ""] or "mkv"
    t.encode_container = c
    if M.ffmpeg_missing() then
        t.video_codec = M.real_video_codec_for(c)
        t.audio_codec = M.lossy_audio_for(c)
    end
    return t
end

function M.encode_baseline()
    local out = {}
    for k, v in pairs(M.param_base or {}) do out[k] = v end
    for k, v in pairs(M.source_preset_values()) do out[k] = v end
    return out
end

local function same_val(a, b)
    if a == nil then a = "" elseif a == true then a = "true" elseif a == false then a = "false" else a = tostring(a) end
    if b == nil then b = "" elseif b == true then b = "true" elseif b == false then b = "false" else b = tostring(b) end
    return a == b
end

function M.param_is_modified(spec, opts, base)
    if spec.type == "resolution" then
        return not (same_val(opts.video_width, base.video_width) and same_val(opts.video_height, base.video_height))
    elseif spec.type == "fps" then
        return not same_val(opts.output_fps, base.output_fps)
    elseif spec.type == "quality" and opts.video_quality_mode == "bitrate" then
        return not same_val(opts.video_bitrate, base.video_bitrate)
    elseif spec.type == "quality" then
        return not same_val(opts.video_quality, base.video_quality)
    elseif spec.field then
        return not same_val(opts[spec.field], base[spec.field])
    end
    return false
end

function M.param_baseline_value(spec, opts, base)
    if spec.type == "resolution" then
        return string.format("%dx%d", tonumber(base.video_width) or 0, tonumber(base.video_height) or 0)
    elseif spec.type == "fps" then
        return base.output_fps
    elseif spec.type == "quality" and opts.video_quality_mode == "bitrate" then
        return base.video_bitrate
    elseif spec.type == "quality" then
        return base.video_quality
    end
    return base[spec.field]
end

function M.apply_export_preset(opts, name)
    if not M.enc_defaults then snapshot_enc(opts) end
    name = tostring(name or "original")
    if name == "default" or name == "" or not M.EXPORT_PRESETS[name] then name = "original" end
    local preset = M.EXPORT_PRESETS[name]
    for k, v in pairs(M.enc_defaults) do opts[k] = v end
    if preset.from_source then
        for k, v in pairs(M.source_preset_values()) do opts[k] = v end
        opts.faststart = M.parse_bool(opts.faststart, true)
        M.current_preset = name
        return M.preset_label()
    end
    if preset.args and preset.args ~= "" then
        if preset.encode_container then
            opts.encode_container = tostring(preset.encode_container):lower():gsub("^%.", "")
        end
        opts.export_preset_args = tostring(preset.args)
    else
        for k, v in pairs(preset) do
            if k ~= "label" and k ~= "args" and k ~= "extra_args" and k ~= "kind" and k ~= "custom" and k ~= "from_conf" then opts[k] = v end
        end
        opts.encode_container = tostring(opts.encode_container or "mp4"):lower():gsub("^%.", "")
        if opts.encode_container == "" then opts.encode_container = "mp4" end
        opts.video_quality = tonumber(opts.video_quality) or 18
        opts.faststart = M.parse_bool(opts.faststart, true)
        opts.pixel_format = tostring(opts.pixel_format or "")
    end
    if preset.extra_args then opts.export_preset_extra = tostring(preset.extra_args) end
    M.current_preset = name
    return M.preset_label()
end

function M.preset_label()
    local preset = M.EXPORT_PRESETS[M.current_preset]
    local label = preset and preset.label or M.EXPORT_PRESETS.original.label
    return I18n(label)
end

M.opts = {
    ffmpeg = "ffmpeg",
    ffprobe = "ffprobe",
    output_directory = "",
    encode_container = "mp4",
    video_codec = "libx264",
    audio_codec = "aac",
    preset = "fast",
    crf = 18,
    audio_bitrate = "192k",
    subtitle_codec = "srt",
    pixel_format = "yuv420p",
    faststart = true,
    render_fps = 30,
    timeline_fps = 10,
    max_visible_segments = 7,
    draft_mode = "strict",
    min_segment_duration = 0,
    show_export_progress = true,
    progress_interval = 0.25,
    export_confirmation = true,
    timeline_edge_snap = 5,
    timeline_handle_hit_radius = 16,
    timeline_drag_seek_fps = 20,
    timeline_drag_threshold = 4,
    timeline_drag_pause = true,
    timeline_drag_resume = true,
    diagnostic_location = "output",
    cleanup_stale_tasks = true,
    stale_task_days = 7,
    resume_session = true,
    waveform = false,
    merge_validation = "basic",
    auto_sort_segments = true,
    video_width = 0,
    video_height = 0,
    scale_mode = "fit",
    video_quality_mode = "crf",
    video_quality = 18,
    video_bitrate = "",
    output_fps = 0,
    play_speed = 1.0,
    output_kind = "video",
    animated_format = "gif",
    animated_fps = 12,
    animated_width = 640,
    image_width = 0,
    animated_loop = 0,
    image_mode = "sequence",
    tile_grid = "5x5",
    keyframe_stride = "1",
    keyframe_limit = "0",
    auto_deinterlace = false,
    auto_crop_black = false,
    normalize_audio = false,
    remove_silence = false,
    silence_db = -30,
    silence_min = 0.5,
    silence_pad = 0.1,
    loudness_target_i = -16,
    loudness_target_tp = -1.5,
    loudness_target_lra = 11,
    analysis_sample_seconds = 600,
    smart_cut = true,
    smart_cut_max_head = 15,
    animated_quality = 80,
    image_format = "png",
    image_quality = 2,
    audio_sample_rate = 0,
    audio_channels = 0,
    crop_mode = "none",
    crop_aspect = "source",
    crop_x = 0,
    crop_y = 0,
    crop_width = 0,
    crop_height = 0,
    crop_move_step = 8,
    crop_move_step_fast = 64,
    crop_resize_step = 16,
    crop_resize_step_fast = 128,
    show_crop_frame = true,
    ui_preset = "comfortable",
    ui_language = "auto",
    ui_color_panel = "", ui_color_text = "", ui_color_text_inverse = "",
    ui_color_primary = "", ui_color_selection = "", ui_color_warning = "",
    ui_color_success = "", ui_color_danger = "", ui_color_timeline = "",
    ui_color_segment = "", ui_color_segment_disabled = "", ui_color_playhead = "",
    ui_alpha_panel = "auto", ui_alpha_button_idle = "auto", ui_alpha_button_hover = "auto",
    ui_alpha_button_active = "auto", ui_alpha_timeline = "auto",
    ui_radius_button = "auto", ui_radius_panel = "auto", ui_radius_timeline = "auto",
    ui_button_width = "auto", ui_status_button_width = "auto",
    ui_panel_padding_x = "auto", ui_panel_padding_y = "auto",
    ui_button_timeline_gap = "auto", ui_timeline_inset = "auto",
    ui_playhead_diamond_size = "auto",
    ui_color_segment_divider = "",
    ui_alpha_segment_divider = "",
    ui_layout_segment_divider_w = "",
    ui_layout_segment_inset_y = "",
    ui_color_panel_highlight = "",
    ui_alpha_panel_highlight = "",
    ui_alpha_card_outline = "",
    ui_timeline_ruler = "",
    ui_layout_card_edge = "",
    ui_timeline_boundaries = "",
    ui_color_pending = "",
    ui_alpha_pending = "",
    ui_button_height = "",
    ui_font_button = "",
    ui_layout_icon_ratio = "",
    ui_alpha_segment = "",
    ui_layout_selected_border = "",
    ui_layout_confirm_width = "",
    ui_layout_confirm_cols = "",
    ui_layout_grid_min_cell_w = "",
    ui_dialog_cell_height = "",
    ui_dialog_cell_gap = "",
    ui_dialog_column_gap = "",
    ui_radius_tooltip = "",
    ui_alpha_hint = "",
    ui_alpha_job_card = "",
    ui_card_match_panel = "",
    ui_card_alpha_floor = "",
    ui_hint_compact = "",
    ui_hint_icon = "",
    ui_job_card_max_width = "",
    ui_alpha_group_bg = "",
    ui_alpha_group_divider = "",
    ui_layout_card_shadow_ratio = "",
    ui_layout_card_row_gap = "",
    ui_layout_hint_font_ratio = "",
    ui_layout_hint_zone_gap = "",
    ui_layout_hint_max_ratio = "",
    ui_layout_hint_row_ratio = "",
    ui_layout_hint_icon_ratio = "",
    ui_layout_hint_pad_x = "",
    ui_layout_hint_pad_y = "",
    ui_layout_timeline_collapsed_margin_x = "",
    ui_layout_timeline_collapsed_margin_bottom = "",
    ui_button_disabled_style = "strike",
    ui_alpha_button_disabled = "auto",
    ui_layout_button_disabled_strike = "auto",
    font = "auto",
    font_bold = true,
    button_font_size = 11.5,
    tooltip_font_size = 14,
    menu_font_size = 11,
    menu_title_font_size = 14,
    button_radius = "auto",
    menu_radius = "auto",
    tooltip_radius = "auto",
    timeline_height = 30,
    button_height = 38,
    button_gap = 5,
    button_group_gap = 10,
    controls_margin_x = 12,
    tooltip_gap = 6,
    crop_frame_color = "",
    crop_frame_width = 2,
    crop_mask_color = "",
    crop_edit_mask_alpha = 0.14,
    crop_preview_mask_alpha = 0.72,
    crop_preview_style = "corners",
    action_hint_font_size = 14,
    action_hint_duration = 1.25,
    action_hint_long_duration = 2.0,
    action_hint_max_width = 720,
    action_hint_line_gap = 5,
    job_card_width = 230,
    job_card_height = 76,
    deck_margin_x = 20,
    deck_margin_bottom = 0,
    deck_padding = 12,
    button_uniform_width = 66,
    button_status_width = 92,
    button_panel_padding_x = 12,
    button_panel_padding_y = 10,
    button_timeline_gap = 10,
    deck_corner_radius = 16,
    deck_border_color = "FFFFFF",
    deck_border_alpha = 0.16,
    button_idle_alpha = 0.14,
    button_active_alpha = 0.92,
    timeline_inner_margin = 10,
    timeline_track_radius = 8,
    playhead_diamond_size = 12,
    btn_crop_color = "",
    scale = 1.0,
    scale_fullscreen = 1.0,
    radius = "auto",
    text_border = "auto",
    button_alpha = "auto",
    tooltip_alpha = "auto",
    menu_alpha = "auto",
    curtain_alpha = "auto",
    key_pause = "SPACE,KP5",
    key_set_in = "[",
    key_set_out = "]",
    key_add = "ENTER,KP_ENTER",
    key_undo = "z,Z",
    key_redo = "y,Y",
    key_nudge_back = "LEFT,KP4",
    key_nudge_forward = "RIGHT,KP6",
    key_export = "e,E",
    key_merge = "m,M",
    key_export_animated = "",
    key_clear = "x,X",
    key_segments = "l,L",
    key_split = "s,S,KP_DIVIDE",
    key_delete = "DEL,KP_DEC",
    key_segment_prev = "UP",
    key_segment_next = "DOWN",
    key_close = "q,Q,ESC",
    key_edit_time = "t,T",
    key_seek_time = "g,G",
    key_help = "?,K",
    key_crop = "c,C",
    key_wave = "w,W",
    key_frame_save = "f,F",
    key_panel = "h,H",
    key_range_toggle = "r,R",
    key_deselect = "Ctrl+SPACE",
    key_kf_prev = "Alt+LEFT",
    key_kf_next = "Alt+RIGHT",
    key_frame_back = "Ctrl+LEFT",
    key_frame_fwd = "Ctrl+RIGHT",
    key_activate = "ENTER,KP_ENTER",
    key_focus_next = "TAB",
    key_focus_prev = "SHIFT+TAB",
    key_param_prev = "UP,KP8",
    key_param_next = "DOWN,KP2",
key_param_reset = "BS",

    crop_key_pause = "SPACE,KP0",
    crop_key_left = "LEFT,KP4",
    crop_key_right = "RIGHT,KP6",
    crop_key_up = "UP,KP8",
    crop_key_down = "DOWN,KP2",
    crop_key_left_fast = "Shift+LEFT",
    crop_key_right_fast = "Shift+RIGHT",
    crop_key_up_fast = "Shift+UP",
    crop_key_down_fast = "Shift+DOWN",
    crop_key_smaller = "-,KP_SUBTRACT",
    crop_key_larger = "+,=,KP_ADD",
    crop_key_smaller_fast = "Ctrl+-",
    crop_key_larger_fast = "Ctrl+=",
    crop_key_center = "c,C,KP5",
    crop_key_hud = "h,H",
    crop_key_help = "?",
    crop_key_undo = "z,Z",
    crop_key_redo = "y,Y",
    crop_key_done = "ENTER,KP_ENTER",
    crop_key_cancel = "q,Q,ESC",

    extra_bindings = "",
    takeover_osc = true,
    takeover_uosc = true,
    flash_osc_on_restore = true,
    uosc_takeover_elements = "timeline,controls,volume,speed",
    btn_mode_color = "", btn_seg_color = "", btn_in_color = "",
    btn_out_color = "", btn_indec_color = "", btn_ininc_color = "",
    btn_add_color = "", btn_cut_color = "", btn_mrg_color = "",
    btn_rst_color = "", btn_exit_color = "", btn_close_color = "", btn_del_color = "", btn_folder_color = "",
    export_preset = "original",
    export_preset_list = "",
    export_preset_args = "",
    export_preset_extra = "",
    ffmpeg_extra_args = "",
    output_name_template = "",
}

M.opts_defaults = {}
for _k, _v in pairs(M.opts) do M.opts_defaults[_k] = _v end

M.UI_PRESETS = {
    comfortable={button_font_size=16,tooltip_font_size=14,menu_font_size=15,menu_title_font_size=18,timeline_height=32,button_height=42,button_gap=6,button_group_gap=12,controls_margin_x=14,tooltip_gap=7},
    compact={button_font_size=12,tooltip_font_size=12,menu_font_size=12,menu_title_font_size=14,timeline_height=26,button_height=32,button_gap=4,button_group_gap=8,controls_margin_x=10,tooltip_gap=5},
    ultra_compact={button_font_size=11,tooltip_font_size=12,menu_font_size=12,menu_title_font_size=14,timeline_height=24,button_height=30,button_gap=4,button_group_gap=8,controls_margin_x=10,tooltip_gap=5},
}

M.CUSTOM_PARAM_VALUE = "__custom__"

M.ANIMATED_PARAMS = {
    {id="animated_format", label="param.animated_format", type="list", field="animated_format",
        values={"gif","webp","apng","avif"},
        value_requires={avif={encoder="libaom-av1",muxer="avif"}}},
    {id="animated_fps", label="param.animated_fps", type="list", field="animated_fps",
        values={"8","12","15","20","24","30"}, custom=true},
    {id="animated_width", label="param.animated_width", type="list", field="animated_width",
        values={"0","320","480","640","854","1280"}, labels={["0"]="value.original_size"}, custom=true},
    {id="animated_loop", label="param.animated_loop", type="list", field="animated_loop",
        values={"0","1","3","5","10"}, labels={["0"]="value.infinite"}},
    {id="animated_quality", label="param.animated_quality", type="list", field="animated_quality",
        values={"50","60","70","80","90","100"}, custom=true},
}

M.ANIMATED_EXT = {gif="gif", webp="webp", apng="png", avif="avif"}

M.EXPORT_KINDS = {
    {id="video",    label="confirm.kind_video"},
    {id="audio",    label="confirm.kind_audio"},
    {id="animated", label="confirm.kind_animated"},
    {id="image",    label="confirm.kind_image"},
    {id="subtitle", label="confirm.kind_subtitle"},
}
M.DEFAULT_EXPORT_KIND = "video"

M.AUDIO_PARAMS = {
    {id="container", label="param.container", type="list", field="encode_container",
        values={"m4a","mp3","opus","flac","wav","ogg"}},
    {id="audio_codec", label="param.audio_codec", type="list", field="audio_codec",
        values={"aac","libmp3lame","libopus","flac","copy"}, labels={copy="value.copy"}},
    {id="audio_bitrate", label="param.audio_bitrate", type="list", field="audio_bitrate",
        values={"96k","128k","192k","256k","320k"}, custom=true},
    {id="audio_sample_rate", label="param.audio_sample_rate", type="list", field="audio_sample_rate",
        values={"0","22050","44100","48000","96000"}, labels={["0"]="value.follow_source"}},
    {id="audio_channels", label="param.audio_channels", type="list", field="audio_channels",
        values={"0","1","2","6"}, labels={["0"]="value.follow_source",["1"]="value.mono",["2"]="value.stereo",["6"]="value.surround_51"}},
}

M.IMAGE_PARAMS = {
    {id="image_mode", label="param.image_mode", type="list", field="image_mode",
        values={"sequence","keyframes","tile","single","current"},
        labels={["sequence"]="value.img_sequence",["keyframes"]="value.img_keyframes",["tile"]="value.img_tile",["single"]="value.img_single",["current"]="value.img_current"},
        desc="param.image_mode.desc"},
    {id="image_format", label="param.image_format", type="list", field="image_format",
        values={"png","jpg","webp","avif","jxl","tiff"},
        value_requires={
            avif={encoder="libaom-av1",muxer="avif"},
            jxl={encoder="libjxl"},
        }},
    {id="image_quality", label="param.image_quality", type="list", field="image_quality",
        values={"2","3","5","10","20","31"}, labels={["2"]="value.best",["31"]="value.worst"}, custom=true,
        desc="param.image_quality.desc"},
    {id="animated_fps", label="param.animated_fps", type="list", field="animated_fps",
        values={"1","2","5","10","12","24"}, custom=true, desc="param.animated_fps.desc"},
    {id="image_width", label="param.image_width", type="list", field="image_width", kind="number",
        values={"0","320","480","640","854","1280"}, labels={["0"]="value.original_size"}, custom=true,
        desc="param.image_width.desc"},
    {id="tile_grid", label="param.tile_grid", type="list", field="tile_grid",
        values={"3x3","4x4","5x5","6x6","8x8"}, custom=true, desc="param.tile_grid.desc"},
    {id="keyframe_stride", label="param.keyframe_stride", type="list", field="keyframe_stride",
        values={"1","2","3","5","10","20"}, labels={["1"]="value.all_keyframes"}, custom=true,
        desc="param.keyframe_stride.desc"},
    {id="keyframe_limit", label="param.keyframe_limit", type="list", field="keyframe_limit",
        values={"0","20","50","100","200","500"}, labels={["0"]="value.no_limit"}, custom=true},
}

M.IMAGE_EXT = {png="png", jpg="jpg", webp="webp", avif="avif", jxl="jxl", tiff="tiff"}

M.SUBTITLE_PARAMS = {
    {id="subtitle_codec", label="param.subtitle_codec", type="list", field="subtitle_codec",
        values={"srt","ass","webvtt","copy"},
        labels={["copy"]="value.copy_raw"}},
}

M.SUBTITLE_EXT = {srt="srt", ass="ass", webvtt="vtt", copy="mkv"}

M.OPTIMIZE_GOALS = {
    quality  = {preset="veryslow", video_quality_mode="crf", video_quality=16, audio_bitrate="256k"},
    speed    = {preset="veryfast", video_quality_mode="crf", video_quality=23, audio_bitrate="128k"},
    lossless = {encode_container="mkv", preset="veryslow", video_quality_mode="crf",
                video_quality=12, audio_codec="flac", audio_bitrate=""},
}
M.OPTIMIZE_GOAL_ORDER = {"quality", "speed", "lossless", "size"}

function M.apply_optimize_goal(opts, goal, profile)
    local g = M.OPTIMIZE_GOALS[goal]
    if not g then return false, nil end
    for k, v in pairs(g) do opts[k] = v end
    local note
    local bpp = profile and tonumber(profile.bpp) or nil
    if bpp and bpp < 0.04 then
        if goal == "quality" then
            opts.preset, opts.video_quality = "slow", 20
            note = I18n("goal.note_low_source", string.format("%.2f", bpp))
        elseif goal == "lossless" then
            opts.video_quality = 18
            note = I18n("goal.note_low_source", string.format("%.2f", bpp))
        end
    elseif bpp and bpp > 0.15 and goal == "quality" then
        note = I18n("goal.note_high_source")
    end
    return true, note
end

function M.params_for_kind(kind)
    if kind == "audio" then return M.AUDIO_PARAMS end
    if kind == "animated" then return M.ANIMATED_PARAMS end
    if kind == "image" then return M.IMAGE_PARAMS end
    if kind == "subtitle" then return M.SUBTITLE_PARAMS end
    return M.ENCODE_PARAMS
end

M.CODEC_DISPLAY = {
    libx264 = "H.264", h264_nvenc = "H.264", h264_qsv = "H.264", libopenh264 = "H.264",
    libx265 = "H.265", hevc_nvenc = "H.265", hevc_qsv = "H.265",
    ["libvpx-vp9"] = "VP9", libvpx_vp9 = "VP9", libsvtav1 = "AV1", av1_nvenc = "AV1",
    aac = "AAC", libmp3lame = "MP3", libopus = "Opus", flac = "FLAC", ac3 = "AC3",
}
M.ENCODER_IDS = {
    libx264 = true, libx265 = true, ["libvpx-vp9"] = true, libvpx_vp9 = true, libsvtav1 = true,
    h264_nvenc = true, hevc_nvenc = true, av1_nvenc = true, h264_qsv = true, hevc_qsv = true,
    libopenh264 = true, libmp3lame = true, libopus = true,
}

function M.codec_label(v)
    v = tostring(v or "")
    if M.ENCODER_IDS[v] then return v end
    local name = M.CODEC_DISPLAY[v]
    if not name then return nil end
    if name:lower() == v:lower() then return name end
    return string.format("%s (%s)", name, v)
end

function M.codec_text(v)
    v = tostring(v or "")
    if v == "copy" then return I18n("value.copy") end
    return M.codec_label(v) or v
end

M.PARAM_FAST_ONLY = {
    smart_cut = true,
}
M.IMAGE_MODE_ONLY = {
    animated_fps    = { sequence = true },
    tile_grid       = { tile = true },
    keyframe_stride = { keyframes = true },
    keyframe_limit  = { keyframes = true },
}
M.PARAM_PRECISE_ONLY = {
    video = {
        video_codec = true, preset = true, quality_mode = true, quality = true,
        pixel_format = true, resolution = true, fps = true, play_speed = true,
        normalize_audio = true, auto_deinterlace = true, auto_crop_black = true, remove_silence = true,
    },
}

M.MPV_MISSING_PARAM_TIPS = {
    smart_cut = "tip.needs_ffmpeg_smart",
}

function M.ffmpeg_missing()
    local rt = _G.QUICK_CUT_RUNTIME
    if type(rt) ~= "table" then return false end
    return rt.ffmpeg_found == false
end

function M.missing_ffmpeg_tip(spec)
    if not M.ffmpeg_missing() then return nil end
    local key = spec.id or spec.field or ""
    return M.MPV_MISSING_PARAM_TIPS[key]
        or (spec.field and M.MPV_MISSING_PARAM_TIPS[spec.field]) or nil
end

M.PARAM_NEEDS = {
    audio_codec = "audio", audio_bitrate = "audio", audio_sample_rate = "audio", audio_channels = "audio",
    normalize_audio = "audio", remove_silence = "audio",
    video_codec = "video", preset = "video", quality_mode = "video", quality = "video",
    pixel_format = "video", resolution = "video", fps = "video",
    scale_mode = "video", auto_deinterlace = "video", auto_crop_black = "video",
}

M.FASTSTART_CONTAINERS = {mp4 = true, mov = true}

-- settings：可选的设置快照（ui.lua 传 opts）。图片页要按当前 image_mode 过滤，
-- 不能读 M.opts（那是编码参数表，不含 image_mode）。
function M.param_visible(spec, kind, accurate, settings)
    local key = spec.id or spec.field or ""
    local avail = settings or M.opts
    if M.missing_ffmpeg_tip(spec) then return true end
    if key == "faststart" then
        local c = tostring((M.opts or {}).encode_container or ""):gsub("^%.", "")
        if not M.FASTSTART_CONTAINERS[c] then return false end
    end
    local needs = M.PARAM_NEEDS[key] or (spec.field and M.PARAM_NEEDS[spec.field])
    if needs then
        local src = M.source_info()
        if src then
            if needs == "audio" and src.has_audio == false then return false end
            if needs == "video" and src.has_video == false then return false end
        end
    end
    if kind == "image" then
        local only = M.IMAGE_MODE_ONLY[key] or (spec.field and M.IMAGE_MODE_ONLY[spec.field])
        if only and not only[tostring((avail or {}).image_mode or "sequence"):lower()] then
            return false
        end
    end
    if M.PARAM_FAST_ONLY[key] or (spec.field and M.PARAM_FAST_ONLY[spec.field]) then
        return accurate == false
    end
    local prec = M.PARAM_PRECISE_ONLY[kind or "video"]
    if prec and accurate == false and (prec[key] or (spec.field and prec[spec.field])) then
        return false
    end
    return true
end

M.ENCODE_PARAMS = {
    {id="container", label="param.container", type="list", field="encode_container", values={"mp4","mkv","mov","webm","ts"}},
    {id="video_codec", label="param.video_codec", type="list", field="video_codec",
        values={"libx264","libx265","libvpx-vp9","libsvtav1","h264_nvenc","hevc_nvenc","av1_nvenc","copy"},
        labels={copy="value.copy"}},
    {id="preset", label="param.preset", type="list", field="preset", dyn="preset"},
    {id="quality_mode", label="param.quality_mode", type="list", field="video_quality_mode",
        values={"crf","cq","global_quality","bitrate"}},
    {id="quality", label="param.quality", type="quality", custom=true},
    -- "none" = 不输出音频轨（无声视频）。只加在**视频**参数集：音频导出类型必须带音轨。
    {id="audio_codec", label="param.audio_codec", type="list", field="audio_codec",
        values={"aac","libmp3lame","libopus","flac","copy","none"},
        labels={copy="value.copy", none="value.no_audio"}},
    {id="audio_bitrate", label="param.audio_bitrate", type="list", field="audio_bitrate",
        values={"96k","128k","192k","256k","320k"}, custom=true},
    {id="pixel_format", label="param.pixel_format", type="list", field="pixel_format",
        values={"yuv420p","yuv420p10le","yuv422p","yuv444p","auto"}},
    {id="resolution", label="param.resolution", type="resolution", custom=true},
    {id="scale_mode", label="param.scale_mode", type="list", field="scale_mode", values={"fit","pad","stretch"}},
    {id="fps", label="param.fps", type="fps", custom=true},
    {id="play_speed", label="param.play_speed", type="list", field="play_speed",
        values={"0.25","0.5","0.75","1","1.25","1.5","2","4"}, custom=true,
        desc="param.play_speed_desc"},
    {id="faststart", label="param.faststart", type="bool", field="faststart", desc="param.faststart_desc"},
    {id="smart_cut", label="param.smart_cut", type="bool", field="smart_cut", desc="param.smart_cut_desc"},
    {id="auto_deinterlace", label="param.auto_deinterlace", type="bool", field="auto_deinterlace", desc="param.auto_deinterlace_desc"},
    {id="auto_crop_black", label="param.auto_crop_black", type="bool", field="auto_crop_black", desc="param.auto_crop_black_desc"},
    {id="normalize_audio", label="param.normalize_audio", type="bool", field="normalize_audio", desc="param.normalize_audio_desc"},
    {id="remove_silence", label="param.remove_silence", type="bool", field="remove_silence", desc="param.remove_silence_desc"},
}

M.PRESET_OPTIONS = {
    x264 = {"ultrafast","superfast","veryfast","faster","fast","medium","slow","slower","veryslow"},
    svtav1 = {"0","1","2","3","4","5","6","7","8","9","10","11","12","13"},
    vpx = {"good","best","realtime"},
    nvenc = {"p1","p2","p3","p4","p5","p6","p7"},
    default = {"fast","medium","slow"},
}
function M.preset_options(codec)
    codec = tostring(codec or "")
    if codec:find("nvenc") then return M.PRESET_OPTIONS.nvenc end
    if codec:find("svtav1") then return M.PRESET_OPTIONS.svtav1 end
    if codec:find("vpx") then return M.PRESET_OPTIONS.vpx end
    if codec:find("264") or codec:find("265") then return M.PRESET_OPTIONS.x264 end
    return M.PRESET_OPTIONS.default
end

M.RESOLUTIONS = {
    {label="value.original_size", w=0, h=0}, {label="2160p", w=3840, h=2160}, {label="1080p", w=1920, h=1080},
    {label="720p", w=1280, h=720}, {label="480p", w=854, h=480},
}
M.FPS_OPTIONS = {0, 24, 25, 30, 60}
M.BITRATE_OPTIONS = {"1M","2M","5M","8M","12M","20M","35M","50M"}

M.CONTAINER_VIDEO_CODECS = {
    webm = {["libvpx-vp9"]=true, ["libsvtav1"]=true, copy=true},
    ts   = {libx264=true, libx265=true, h264_nvenc=true, hevc_nvenc=true, copy=true},
    mp4  = {libx264=true, libx265=true, libsvtav1=true,
            h264_nvenc=true, hevc_nvenc=true, av1_nvenc=true, copy=true},
    mov  = {libx264=true, libx265=true, libsvtav1=true,
            h264_nvenc=true, hevc_nvenc=true, av1_nvenc=true, copy=true},
}

M.CONTAINER_AUDIO_CODECS = {
    webm = {libopus=true, copy=true, none=true},
    ts   = {aac=true, libmp3lame=true, copy=true, none=true},
    mp4  = {aac=true, libmp3lame=true, libopus=true, flac=true, copy=true, none=true},
    mov  = {aac=true, libmp3lame=true, copy=true, none=true},
    m4a  = {aac=true, copy=true},
    mp3  = {libmp3lame=true, copy=true},
    opus = {libopus=true, copy=true},
    flac = {flac=true, copy=true},
    wav  = {libmp3lame=true, copy=true},
    ogg  = {libopus=true, copy=true},
}

M.CODEC_QUALITY_MODES = {
    h264_nvenc = {cq=true, global_quality=true, bitrate=true},
    hevc_nvenc = {cq=true, global_quality=true, bitrate=true},
    av1_nvenc  = {cq=true, global_quality=true, bitrate=true},
}

M.PARAM_DEPENDENTS = {
    encode_container = {"video_codec", "audio_codec"},
    video_codec      = {"quality_mode", "preset"},
}

function M.container_video_codecs(container) return M.CONTAINER_VIDEO_CODECS[tostring(container or "")] end
M.VIDEO_ENCODER_PREFERENCE = {"libx264", "libx265", "libvpx-vp9", "libsvtav1",
                              "h264_nvenc", "hevc_nvenc", "mpeg4"}
function M.real_video_codec_for(container)
    local allow = M.container_video_codecs(container) or {}
    for _, cand in ipairs(M.VIDEO_ENCODER_PREFERENCE) do
        if allow[cand] then return cand end
    end
    return "libx264"
end

M.LOSSY_AUDIO_PREFERENCE = {"aac", "libopus", "libmp3lame", "flac"}
function M.lossy_audio_for(container)
    local allow = M.container_audio_codecs(container) or {}
    for _, cand in ipairs(M.LOSSY_AUDIO_PREFERENCE) do
        if allow[cand] then return cand end
    end
    return "aac"
end

function M.container_audio_codecs(container) return M.CONTAINER_AUDIO_CODECS[tostring(container or "")] end
function M.codec_quality_modes(codec) return M.CODEC_QUALITY_MODES[tostring(codec or "")] end

M.DROPDOWN_MAX_ROWS = 10

M.UOSC_DEFAULTS = {
    scale = "1", scale_fullscreen = "1.3", border_radius = "4",
    text_border = "1.2", controls_size = "32",
    color = "foreground=ffffff,foreground_text=000000,background=000000,background_text=ffffff,window_border=000000,curtain=111111,success=a5e075,error=ff616e,match=69c5ff,heatmap=00adee",
    opacity = "timeline=0.9,position=1,chapters=0.8,slider=0.9,slider_gauge=1,controls=0,speed=0.6,menu=1,submenu=0.4,border=1,title=1,tooltip=1,thumbnail=1,curtain=0.8",
}

local BTN_KEYS = {"mode", "seg", "in", "out", "indec", "ininc", "add", "split", "crop", "cut", "mrg", "rst", "exit", "close", "del", "folder"}

M.theme = {
    scale = 1, scale_fs = 1.3, radius = 4, text_border = 1.2,
    fg = "FFFFFF", bg = "000000", fgt = "000000", bgt = "FFFFFF",
    match = "FFC569", success = "75E0A5", error = "6E61FF", heatmap = "EEAD00",
    curtain = "111111", opacity = {}, btn = {},
}

function M.copy_table(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function M.parse_conf(path)
    local out, f = {}, io.open(path, "r")
    if not f then return out end
    for raw_line in f:lines() do
        local line = raw_line:gsub("%s+#.*$", ""):match("^%s*(.-)%s*$")
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)$")
        if k and v and v ~= "" then out[k] = v end
    end
    f:close()
    return out
end

function M.parse_kv(str)
    local out = {}
    for k, v in tostring(str or ""):gmatch("([%w_]+)%s*=%s*([^,%s]+)") do out[k] = v end
    return out
end

function M.normalize_rgb(value)
    value = tostring(value or ""):gsub("^#", ""):gsub("%s.*$", "")
    if not value:match("^%x%x%x%x%x%x%x?%x?$") or (#value ~= 6 and #value ~= 8) then return nil end
    return value:upper()
end

function M.rgb_to_ass(value)
    local rgb = M.normalize_rgb(value)
    return rgb and (rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)) or nil
end

local function color_or(value, fallback)
    if value and value ~= "" then
        local c = M.normalize_rgb(value)
        if c then return c end
        msg.warn("Invalid color in quick_cut.conf: " .. tostring(value))
    end
    return fallback
end

local function clamped_number(value, fallback, lo, hi)
    local n = tonumber(value)
    if not n then return fallback end
    return math.max(lo, math.min(hi, n))
end

M.clamped_number = clamped_number

function M.parse_bool(value, fallback)
    if type(value) == "boolean" then return value end
    if value == nil or value == "" then return fallback end
    value = tostring(value):lower()
    if value == "yes" or value == "true" or value == "1" or value == "on" then return true end
    if value == "no" or value == "false" or value == "0" or value == "off" then return false end
    return fallback
end

local function init_theme()
    local opts, theme = M.opts, M.theme
    opts.takeover_osc = M.parse_bool(opts.takeover_osc, true)
    opts.takeover_uosc = M.parse_bool(opts.takeover_uosc, true)
    opts.flash_osc_on_restore = M.parse_bool(opts.flash_osc_on_restore, true)
    opts.faststart = M.parse_bool(opts.faststart, true)
    opts.crf = clamped_number(opts.crf, 18, 0, 51)
    opts.render_fps = clamped_number(opts.render_fps, 30, 10, 60)
    opts.timeline_fps = clamped_number(opts.timeline_fps, 10, 2, 30)
    opts.max_visible_segments = math.floor(clamped_number(opts.max_visible_segments, 7, 1, 30))
    opts.min_segment_duration = clamped_number(opts.min_segment_duration, 0, 0, 60)
    opts.show_export_progress = M.parse_bool(opts.show_export_progress, true)
    opts.auto_sort_segments = M.parse_bool(opts.auto_sort_segments, true)
    opts.export_confirmation = M.parse_bool(opts.export_confirmation, true)
    opts.timeline_edge_snap = math.floor(clamped_number(opts.timeline_edge_snap, 5, 0, 30))
    opts.timeline_handle_hit_radius=math.floor(clamped_number(opts.timeline_handle_hit_radius,10,4,30))
    opts.timeline_drag_seek_fps=clamped_number(opts.timeline_drag_seek_fps,20,5,60)
    opts.timeline_drag_threshold=clamped_number(opts.timeline_drag_threshold,4,1,20)
    opts.timeline_drag_pause=M.parse_bool(opts.timeline_drag_pause,true)
    opts.timeline_drag_resume=M.parse_bool(opts.timeline_drag_resume,true)
    opts.diagnostic_location = tostring(opts.diagnostic_location or "output"):lower()
    if opts.diagnostic_location ~= "output" and opts.diagnostic_location ~= "off" then opts.diagnostic_location = "output" end
    opts.cleanup_stale_tasks = M.parse_bool(opts.cleanup_stale_tasks, true)
    opts.stale_task_days = math.floor(clamped_number(opts.stale_task_days, 7, 1, 365))
    opts.resume_session = M.parse_bool(opts.resume_session, true)
    opts.waveform = M.parse_bool(opts.waveform, false)
    opts.merge_validation = tostring(opts.merge_validation or "basic"):lower()
    -- strict 档已移除：它按"源里的每条选中流"要求产物，音频/动图/无音轨产物必然被判失败。
    if opts.merge_validation == "strict" then
        msg.warn("quick_cut: merge_validation=strict 已移除，按 basic 处理（strict 会把音频/动图产物误判为缺少视频流）")
    end
    if opts.merge_validation ~= "off" and opts.merge_validation ~= "basic" then opts.merge_validation = "basic" end
    opts.video_width = math.floor(clamped_number(opts.video_width, 0, 0, 16384))
    opts.video_height = math.floor(clamped_number(opts.video_height, 0, 0, 16384))
    opts.video_quality = clamped_number(opts.video_quality, opts.crf, 0, 63)
    opts.output_fps = clamped_number(opts.output_fps, 0, 0, 240)
    local speed = clamped_number(opts.play_speed, 1.0, 0.25, 4.0)
    opts.play_speed = (speed > 0.995 and speed < 1.005) and 1.0 or speed
    opts.audio_sample_rate = math.floor(clamped_number(opts.audio_sample_rate, 0, 0, 384000))
    opts.audio_channels = math.floor(clamped_number(opts.audio_channels, 0, 0, 32))
    opts.crop_x = math.floor(clamped_number(opts.crop_x, 0, 0, 16384))
    opts.crop_y = math.floor(clamped_number(opts.crop_y, 0, 0, 16384))
    opts.crop_width = math.floor(clamped_number(opts.crop_width, 0, 0, 16384))
    opts.crop_height = math.floor(clamped_number(opts.crop_height, 0, 0, 16384))
    opts.crop_move_step = math.floor(clamped_number(opts.crop_move_step, 8, 2, 256))
    opts.crop_move_step_fast = math.floor(clamped_number(opts.crop_move_step_fast, 64, 4, 1024))
    opts.crop_resize_step = math.floor(clamped_number(opts.crop_resize_step, 16, 2, 512))
    opts.crop_resize_step_fast = math.floor(clamped_number(opts.crop_resize_step_fast, 128, 4, 2048))
    opts.show_crop_frame = M.parse_bool(opts.show_crop_frame, true)
    opts.font_bold=M.parse_bool(opts.font_bold,true)
    opts.ui_preset=tostring(opts.ui_preset or "comfortable"):lower()
    local presets=M.UI_PRESETS
    if opts.ui_preset~="custom" and not presets[opts.ui_preset] then opts.ui_preset="comfortable" end
    local preset=presets[opts.ui_preset]
    if preset then
        for key,value in pairs(preset) do
            if opts[key]==M.opts_defaults[key] then opts[key]=value end
        end
    end
    opts.button_font_size = clamped_number(opts.button_font_size, 11.5, 8, 24)
    opts.tooltip_font_size = clamped_number(opts.tooltip_font_size, 14, 8, 28)
    opts.menu_font_size = clamped_number(opts.menu_font_size, 11, 8, 24)
    opts.menu_title_font_size = clamped_number(opts.menu_title_font_size, 14, 9, 30)
    opts.timeline_height = math.floor(clamped_number(opts.timeline_height, 30, 12, 80))

    opts.button_height = clamped_number(opts.button_height, 38, 28, 64)
    opts.button_gap = clamped_number(opts.button_gap, 5, 1, 24)
    opts.button_group_gap = clamped_number(opts.button_group_gap, 10, 2, 48)
    opts.controls_margin_x = clamped_number(opts.controls_margin_x, 12, 0, 100)
    opts.tooltip_gap = clamped_number(opts.tooltip_gap, 6, 0, 40)
    opts.crop_frame_width = clamped_number(opts.crop_frame_width, 2, 1, 8)

    opts.crop_edit_mask_alpha = clamped_number(opts.crop_edit_mask_alpha, 0.14, 0, 0.9)
    opts.crop_preview_mask_alpha = clamped_number(opts.crop_preview_mask_alpha, 0.72, 0, 0.95)
    opts.crop_preview_style = tostring(opts.crop_preview_style or "corners"):lower()
    if opts.crop_preview_style ~= "corners" then opts.crop_preview_style = "corners" end
    opts.animated_fps = math.floor(clamped_number(opts.animated_fps, 12, 1, 60))
    opts.animated_quality = math.floor(clamped_number(opts.animated_quality, 80, 0, 100))
    opts.animated_width = math.floor(clamped_number(opts.animated_width, 0, 0, 16384))
    opts.image_width = math.floor(clamped_number(opts.image_width, 0, 0, 16384))
    opts.animated_loop = math.floor(clamped_number(opts.animated_loop, 0, 0, 1000))
    opts.image_quality = math.floor(clamped_number(opts.image_quality, 2, 0, 31))
    opts.animated_format = tostring(opts.animated_format or "gif"):lower()
    if not M.ANIMATED_EXT[opts.animated_format] then
        msg.warn("Invalid animated_format; using gif")
        opts.animated_format = "gif"
    end
    opts.image_format = tostring(opts.image_format or "png"):lower()
    if not M.IMAGE_EXT[opts.image_format] then
        msg.warn("Invalid image_format; using png")
        opts.image_format = "png"
    end
    opts.encode_container = tostring(opts.encode_container or "mp4"):lower():gsub("^%.", "")
    if opts.encode_container == "" then opts.encode_container = "mp4" end
    opts.action_hint_font_size = clamped_number(opts.action_hint_font_size, 14, 8, 32)
    opts.action_hint_duration = clamped_number(opts.action_hint_duration, 1.25, 0.3, 10)
    opts.action_hint_long_duration = clamped_number(opts.action_hint_long_duration, 2.0, 0.5, 15)
    opts.action_hint_max_width = math.floor(clamped_number(opts.action_hint_max_width, 720, 240, 1920))
    opts.action_hint_line_gap=math.floor(clamped_number(opts.action_hint_line_gap,5,0,24))
    opts.job_card_width=math.floor(clamped_number(opts.job_card_width,230,180,420))
    opts.job_card_height=math.floor(clamped_number(opts.job_card_height,76,0,150))
    opts.deck_margin_x=math.floor(clamped_number(opts.deck_margin_x,20,0,100))
    opts.deck_margin_bottom=math.floor(clamped_number(opts.deck_margin_bottom,14,0,100))
    opts.deck_padding=math.floor(clamped_number(opts.deck_padding,12,4,40))
    opts.button_uniform_width=math.floor(clamped_number(opts.button_uniform_width,66,36,160))
    opts.button_status_width=math.floor(clamped_number(opts.button_status_width,92,48,200))
    opts.button_panel_padding_x=math.floor(clamped_number(opts.button_panel_padding_x,12,4,40))
    opts.button_panel_padding_y=math.floor(clamped_number(opts.button_panel_padding_y,10,4,30))
    opts.button_timeline_gap=math.floor(clamped_number(opts.button_timeline_gap,10,0,40))
    opts.deck_corner_radius=math.floor(clamped_number(opts.deck_corner_radius,16,0,40))
    opts.deck_border_alpha=clamped_number(opts.deck_border_alpha,0.16,0,1)
    opts.button_idle_alpha=clamped_number(opts.button_idle_alpha,0.14,0,1)
    opts.button_active_alpha=clamped_number(opts.button_active_alpha,0.92,0,1)
    opts.timeline_inner_margin=math.floor(clamped_number(opts.timeline_inner_margin,10,0,40))
    opts.timeline_track_radius=math.floor(clamped_number(opts.timeline_track_radius,8,0,30))
    opts.playhead_diamond_size=math.floor(clamped_number(opts.playhead_diamond_size,12,6,24))
    opts.scale_mode = tostring(opts.scale_mode or "fit"):lower()
    if opts.scale_mode ~= "fit" and opts.scale_mode ~= "pad" and opts.scale_mode ~= "stretch" then opts.scale_mode = "fit" end
    opts.video_quality_mode = tostring(opts.video_quality_mode or "crf"):lower()
    local quality_modes = {crf=true, cq=true, global_quality=true, bitrate=true, none=true}
    if not quality_modes[opts.video_quality_mode] then opts.video_quality_mode = "crf" end
    opts.crop_mode = tostring(opts.crop_mode or "none"):lower()
    if opts.crop_mode ~= "none" and opts.crop_mode ~= "aspect" and opts.crop_mode ~= "custom" then opts.crop_mode = "none" end
    opts.crop_aspect = tostring(opts.crop_aspect or "source"):lower()
    opts.progress_interval = clamped_number(opts.progress_interval, 0.25, 0.1, 2)
    opts.draft_mode = tostring(opts.draft_mode or "strict"):lower()
    if opts.draft_mode ~= "strict" and opts.draft_mode ~= "smart" then
        msg.warn("Invalid draft_mode; using strict")
        opts.draft_mode = "strict"
    end

    local uosc = M.copy_table(M.UOSC_DEFAULTS)
    local path = mp.find_config_file("script-opts/uosc.conf")
    if path then
        for k, v in pairs(M.parse_conf(path)) do if uosc[k] ~= nil then uosc[k] = v end end
    end
    local raw_colors, colors = M.parse_kv(uosc.color), {}
    for k, v in pairs(raw_colors) do colors[k] = M.normalize_rgb(v) end
    local op = M.parse_kv(uosc.opacity)

    theme.scale = clamped_number(opts.scale, 1, 0.5, 3)
    theme.scale_fs = clamped_number(opts.scale_fullscreen, theme.scale, 0.5, 3)
    theme.radius = opts.radius ~= "auto" and clamped_number(opts.radius, 4, 0, 30) or (tonumber(uosc.border_radius) or 4)
    theme.text_border = opts.text_border ~= "auto" and clamped_number(opts.text_border, 1.2, 0, 10) or (tonumber(uosc.text_border) or 1.2)
    theme.curtain = colors.curtain or "111111"

    local function alpha(option_value, fallback)
        if option_value ~= "auto" and option_value ~= "" then
            return clamped_number(option_value, fallback, 0, 1)
        end
        return fallback
    end
    theme.opacity.controls = alpha(opts.button_alpha, tonumber(op.controls) or 0)
    theme.opacity.tooltip = alpha(opts.tooltip_alpha, tonumber(op.tooltip) or 1)
    theme.opacity.menu = alpha(opts.menu_alpha, tonumber(op.menu) or 1)
    theme.opacity.curtain = alpha(opts.curtain_alpha, tonumber(op.curtain) or 0.8)
    theme.font = opts.font ~= "auto" and opts.font ~= "" and opts.font or nil
    theme.button_radius = opts.button_radius ~= "auto" and clamped_number(opts.button_radius, theme.radius, 0, 30) or theme.radius
    theme.menu_radius = opts.menu_radius ~= "auto" and clamped_number(opts.menu_radius, theme.radius + 3, 0, 40) or (theme.radius + 3)
    theme.tooltip_radius = opts.tooltip_radius ~= "auto" and clamped_number(opts.tooltip_radius, theme.radius, 0, 30) or theme.radius
    theme.deck_border=color_or(opts.deck_border_color,"FFFFFF")
    theme.crop_frame = color_or(opts.crop_frame_color, theme.fg)
    theme.crop_mask = color_or(opts.crop_mask_color, theme.curtain)
end

M.LAYOUT_MAP = {
    font_button = "button_font_size",
    font_tooltip = "tooltip_font_size",
    font_menu = "menu_font_size",
    font_menu_title = "menu_title_font_size",
    timeline_height = "timeline_height", button_height = "button_height",
    button_gap = "button_gap", button_group_gap = "button_group_gap",
    deck_margin_x = "deck_margin_x", deck_margin_bottom = "deck_margin_bottom",
    deck_padding = "deck_padding",
    deck_corner_radius = "deck_corner_radius", deck_border_alpha = "deck_border_alpha",
    timeline_inner_margin = "timeline_inner_margin", timeline_track_radius = "timeline_track_radius",
    tooltip_gap = "tooltip_gap", job_card_width = "job_card_width", job_card_height = "job_card_height",
    action_hint_font_size = "action_hint_font_size", action_hint_max_width = "action_hint_max_width",
    action_hint_line_gap = "action_hint_line_gap", controls_margin_x = "controls_margin_x",
}

-- 读取 quick_cut.conf 并完成全部校验；必须最先调用。
function M.load()
    options.read_options(M.opts, "quick_cut")
    M.explicit_layout = {}
    for token_key, opt_key in pairs(M.LAYOUT_MAP) do
        if M.opts[opt_key] ~= M.opts_defaults[opt_key] then M.explicit_layout[opt_key] = true end
    end
    -- init_theme 会把 ui_preset 小写化后再查表，这里必须用同一规则：
    -- 否则 ui_preset=Compact 查不到 → 布局令牌在 apply_ui_tokens 里把 compact 的值覆盖掉
    local ui_preset_name = tostring(M.opts.ui_preset or ""):lower()
    if ui_preset_name ~= M.opts_defaults.ui_preset and M.UI_PRESETS[ui_preset_name] then
        for key in pairs(M.UI_PRESETS[ui_preset_name]) do M.explicit_layout[key] = true end
    end
    M.custom_presets = M.load_custom_presets()
    for i, p in ipairs(M.custom_presets) do p.from_conf = true; M.EXPORT_PRESETS["u" .. i] = p end
    M.apply_preset_store(M.load_preset_store())
    if M.preset_store.default ~= "" and M.EXPORT_PRESETS[M.preset_store.default] then
        M.opts.export_preset = M.preset_store.default
    end
    snapshot_params(M.opts)
    M.apply_export_preset(M.opts, M.opts.export_preset)
    init_theme()
    return M.opts, M.theme
end

function M.apply_ui_tokens(ui_tokens)
    local opts, theme = M.opts, M.theme
    theme.fg=ui_tokens.color_text; theme.bg=ui_tokens.color_panel; theme.fgt=ui_tokens.color_text_inverse; theme.bgt=theme.fg
    theme.match=ui_tokens.color_primary; theme.success=ui_tokens.color_success; theme.error=ui_tokens.color_danger; theme.heatmap=ui_tokens.color_warning
    theme.timeline_bg=ui_tokens.color_timeline; theme.timeline_segment=ui_tokens.color_segment; theme.timeline_disabled=ui_tokens.color_segment_disabled; theme.timeline_playhead=ui_tokens.color_playhead; theme.pending=ui_tokens.color_pending
    theme.crop_frame=color_or(opts.crop_frame_color, theme.fg)
    theme.crop_mask=color_or(opts.crop_mask_color, theme.curtain)
    if opts.menu_alpha == "auto" or opts.menu_alpha == "" then
        theme.opacity.menu = tonumber(ui_tokens.alpha_menu) or theme.opacity.menu
    end
    if opts.menu_radius == "auto" or opts.menu_radius == "" then
        theme.menu_radius = tonumber(ui_tokens.radius_menu) or theme.menu_radius
    end
    if opts.curtain_alpha == "auto" or opts.curtain_alpha == "" then
        theme.opacity.curtain = tonumber(ui_tokens.alpha_curtain) or theme.opacity.curtain
    end
    -- tooltip 的透明度与圆角：提示条与悬停气泡都吃这两个值，按与 menu/curtain 相同的优先级取值
    -- （令牌 alpha_tooltip / radius_tooltip 无人消费，不能只认 conf/uosc）
    if opts.tooltip_alpha == "auto" or opts.tooltip_alpha == "" then
        theme.opacity.tooltip = tonumber(ui_tokens.alpha_tooltip) or theme.opacity.tooltip
    end
    if opts.tooltip_radius == "auto" or opts.tooltip_radius == "" then
        theme.tooltip_radius = tonumber(ui_tokens.radius_tooltip) or theme.tooltip_radius
    end
    theme.deck_alpha=ui_tokens.alpha_panel; theme.hover_alpha=ui_tokens.alpha_button_hover; theme.opacity.timeline=ui_tokens.alpha_timeline
    opts.button_idle_alpha=ui_tokens.alpha_button_idle; opts.button_active_alpha=ui_tokens.alpha_button_active; opts.button_uniform_width=ui_tokens.button_width; opts.button_status_width=ui_tokens.status_button_width
    opts.button_panel_padding_x=ui_tokens.panel_padding_x; opts.button_panel_padding_y=ui_tokens.panel_padding_y; opts.button_timeline_gap=ui_tokens.button_timeline_gap; opts.timeline_inner_margin=ui_tokens.timeline_inset; opts.playhead_diamond_size=ui_tokens.playhead_diamond_size
    for token_key, opt_key in pairs(M.LAYOUT_MAP) do
        if ui_tokens[token_key] ~= nil and not M.explicit_layout[opt_key] then
            opts[opt_key] = ui_tokens[token_key]
        end
    end
    local semantic = {
        mode = theme.match, seg = theme.match, ["in"] = theme.heatmap,
        out = theme.heatmap, indec = theme.fg, ininc = theme.fg,
        add = theme.match, split = theme.match, crop = theme.heatmap, cut = theme.success, mrg = theme.match,
        rst = theme.error, exit = theme.error, close = theme.error, del = theme.error, folder = theme.success,
    }
    for _, key in ipairs(BTN_KEYS) do
        theme.btn[key] = color_or(opts["btn_" .. key .. "_color"], semantic[key])
    end
end

return M
