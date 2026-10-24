-- quick_cut 选项、校验与令牌初始化
local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"
local utils = require "mp.utils"   -- 预设库读写（JSON）
-- 必须用短名 "i18n"（与 core.lua 一致）：package.path 中 i18n/?.lua 与 ./?.lua 都能把
-- "i18n" 与 "i18n.i18n" 解析到同一个文件，但 package.loaded 按模块名缓存，两个名字会
-- 产生两个状态独立的实例（语言设置只对其中一个生效）。
local I18n = require "i18n"

local M = {}

-- 版本单一来源：bootstrap、core 日志、失败诊断均引用此值。
M.VERSION = "1.0"

-- 导出编码预设：见下方 M.EXPORT_PRESETS。`original`（原始参数）＝跟随源文件（容器取源扩展名、
-- 视音频直接复制）；其余预设整体覆盖编码相关选项。"default" 是它的旧名（见 apply_export_preset）。
-- 内置预设的 label 存 i18n 键（preset.*），显示时经语言包翻译；用户自定义预设的 label 保持原样。
M.EXPORT_PRESETS = {
-- "原始参数"＝跟随源文件：容器取源文件扩展名，视音频直接复制（无损、秒级）。
-- 具体写入值由 M.source_preset_values() 现算（源文件随时可能换）。
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

-- 自定义预设字段：conf 键后缀 -> 预设字段
local PRESET_FIELDS = {
    container = "encode_container", video_codec = "video_codec", preset = "preset",
    quality_mode = "video_quality_mode", quality = "video_quality", bitrate = "video_bitrate",
    audio_codec = "audio_codec", audio_bitrate = "audio_bitrate",
    pixel_format = "pixel_format", faststart = "faststart",
    args = "args", extra_args = "extra_args",
}

-- 从 quick_cut.conf 读取自定义预设（不依赖 read_options 对未知键的行为）：
--   export_preset_list=名称1,名称2
--   export_preset_1_container=mp4 / _video_codec / _preset / _quality_mode / _quality
--   export_preset_1_bitrate / _audio_codec / _audio_bitrate / _pixel_format / _faststart
--   export_preset_1_args=（可选）完整编码参数，填写后脚本不再注入滤镜与编码参数
--   export_preset_1_extra_args=（可选）附加参数，追加在脚本生成的参数之后
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

-- ============================================================================
-- 自定义预设（可编辑）：存成**脚本目录**下的 quick_cut_presets.json
-- ----------------------------------------------------------------------------
-- 与 conf 的 export_preset_list 分开：conf 那批是"配置里的预设"，界面只读；
-- 这里的是"界面里存下来的预设"，可以改名 / 删除 / 设为启动默认。
-- 文件与脚本同目录（main.lua 写进 QUICK_CUT_BOOTSTRAP.module_dir），搬家时一起走。
-- ============================================================================
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

-- 成功返回 store；文件不存在/为空视为首次运行。损坏时置位并告警，此后拒绝写入，
-- 避免"读到空表 → 下一次保存把其余预设整库覆盖"（与 session.lua 同一套保护）。
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
    local renamed = os.rename(tmp, path)
    if not renamed then
        -- Windows 的 C rename 不覆盖已存在文件，先删旧再试一次
        os.remove(path)
        renamed = os.rename(tmp, path)
    end
    if not renamed then
        msg.warn("quick_cut: preset rename failed: " .. tostring(tmp) .. " -> " .. tostring(path))
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

-- 名字校验：非空、不太长、不与内置键/conf 预设键冲突
local function valid_preset_name(name)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil, "empty" end
    if #name > 40 then return nil, "long" end
    if M.PRESET_RESERVED[name] or name:match("^[uU]%d+$") then return nil, "taken" end
    return name, nil
end

-- 把 store 并进预设索引：内置 → conf 预设(u*) → 我的。自定义项标 custom=true，
-- 供界面区分"可编辑"（conf 那批标 from_conf）。
function M.apply_preset_store(store)
    M.preset_store = store or M.load_preset_store()
    M.CUSTOM_PRESET_NAMES = {}
    for _, p in ipairs(M.preset_store.presets) do
        if p and type(p.name) == "string" and p.name ~= "" then
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

-- 当前页参数的"值快照"：这一页控件实际管的字段都记下来（resolution/quality 这类
-- 一个控件管两个字段的按当前模式展开，否则存下来的值回不去）
function M.export_presets_values(opts, kind)
    local values = {}
    for _, spec in ipairs(M.params_for_kind(kind) or {}) do
        if spec.type == "resolution" then
            values.video_width = opts.video_width
            values.video_height = opts.video_height
        elseif spec.type == "quality" then
            if opts.video_quality_mode == "bitrate" then values.video_bitrate = opts.video_bitrate
            else values.video_quality = opts.video_quality end
        elseif spec.field then
            values[spec.field] = opts[spec.field]
        end
    end
    return values
end

-- 保存（同名覆盖）。kind 决定它出现在哪一页；返回 名称 / nil + 原因
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

-- 启动默认：优先于 conf 的 export_preset（下次启动生效）
function M.export_presets_set_default(name)
    local store = M.load_preset_store()
    store.default = tostring(name or "")
    if not write_preset_store(store) then return nil, "write" end
    M.preset_store = store
    return true
end

-- 预设覆盖的字段；切回 default 时据此恢复 conf 原值。
local ENC_FIELDS = {
    "encode_container", "video_codec", "audio_codec", "preset",
    "video_quality_mode", "video_quality", "video_bitrate",
    "audio_bitrate", "pixel_format", "faststart",
    -- 预设可注入的自定义参数段；纳入快照后，切回 default 预设能恢复 conf 直配值
    "export_preset_args", "export_preset_extra",
}
M.enc_defaults = nil

local function snapshot_enc(opts)
    local t = {}
    for _, k in ipairs(ENC_FIELDS) do t[k] = opts[k] end
    M.enc_defaults = t
end

-- 参数"基线"专用快照：参数集里出现的**所有** field 在解析 conf 后的初值。
-- 与 enc_defaults 分开是有意的：enc_defaults 参与"切预设时恢复 conf 原值"，
-- 随手扩充它会让切预设把分辨率/帧率这类非预设字段一起重置。
M.param_base = nil

-- 一个 spec 实际会写哪些 opts 字段。**不能只看 spec.field**：resolution / fps / quality
-- 这几类在参数表里没有 field（它们分别写 video_width+video_height / output_fps /
-- video_quality|video_bitrate），只看 field 会让基线里缺这几个字段，
-- 于是"当前值 0 vs 基线空"会被误判成已修改。
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

-- ============================================================================
-- 源文件信息：整个脚本读 mv 源参数**只有这一处**。确认面板的"源文件"参照行与
-- "原始参数"预设都从这里取，避免两处各写一套"源"规则（两边不一致过）。
-- 返回 nil 表示没有可用源（未加载文件 / 纯音频等，字段缺省为 nil 由调用方兜底）。
-- ============================================================================
-- mpv 的 video-codec/audio-codec 会给一长串别名（"H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"），
-- 与编码参数里的 libx264 完全不是一套说法。这里统一取第一段并去掉括号补充，
-- 源文件行与"原始参数"预设都走这一处，表述自然一致。
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
        -- 括号不能省：mpv 的 mp.get_property 在属性不可用时会**返回第二个值（错误串）**，
        -- 直接当实参传进 tonumber 就变成"进制参数"→ bad argument #2 to 'tonumber'。
        -- 启动时还没有文件（container-fps 不可用），这条路径一定会踩到，故显式截断为单值。
        fps = tonumber((mp.get_property("container-fps")))
            or tonumber((mp.get_property("estimated-vf-fps"))) or 0,
        channels = mp.get_property_number("audio-params/channel-count", 0) or 0,
        -- 源能力：没有文件时一律 nil（=未知），此时**不隐藏**任何参数，
        -- 免得"还没加载文件"就被判成"没有音轨"而把整组参数藏空。
        has_video = (f ~= "") and (w > 0 and h > 0) or nil,
        has_audio = (f ~= "") and ((mp.get_property("audio-codec") or "") ~= "") or nil,
        samplerate = mp.get_property_number("audio-params/samplerate", 0) or 0,
    }
end

-- 源扩展名 → 目标容器（只认参数表里允许的那几个；其余一律 mkv，它几乎装得下任何编码）
local CONTAINER_BY_EXT = {mp4 = "mp4", m4v = "mp4", mov = "mov", mkv = "mkv", webm = "webm",
    ts = "ts", m2ts = "ts", mts = "ts"}

-- "原始参数"预设实际要写入的值（apply 与 encode_baseline 共用，保证两者永远一致）。
function M.source_preset_values()
    local src = M.source_info()
    -- 不开 smart_cut：它为了逐帧入点会把头部一小段重编码，与"无损"这个名不符。
    -- 要逐帧入点就在面板里自己打开（见 param.smart_cut）。
    local t = {video_codec = "copy", audio_codec = "copy",
        video_quality_mode = "crf", pixel_format = "auto",
        -- 能读到源值的走"原**"那一档，读不到的用 copy/auto：0=原尺寸、0=原帧率，
        -- 正是参数表里那两个"原"选项的值；缩放保持 fit。
        video_width = 0, video_height = 0, output_fps = 0, scale_mode = "fit",
        -- 会强制重新编码的滤镜全关：否则选了"跟随源文件"也走不到纯复制，界面还判成需重编码。
        remove_silence = false, normalize_audio = false,
        auto_deinterlace = false, auto_crop_black = false}
    local c = CONTAINER_BY_EXT[(src and src.ext) or ""] or "mkv"
    t.encode_container = c
    -- 没有 ffmpeg 时导出走 mpv 编码模式，而它压根没有 copy 编码器（--ovc=copy 报
    -- codec 'copy' not found）——"原始参数"在这里的真实含义就是"按容器重新编码"。
    -- 基线也这么算，否则面板一打开就把 libx264/AAC 标成"已修改"（用户什么都没动）。
    if M.ffmpeg_missing() then
        t.video_codec = M.real_video_codec_for(c)
        t.audio_codec = M.lossy_audio_for(c)
    end
    return t
end

-- 参数基线 = **「原始参数」（跟随源文件）的值**，与当前选中的预设无关。
-- 语义：凡是相对「原始参数」有改变的参数都要标记 —— 无论改动来自
-- 切换预设、应用优化目标，还是手动调整。
-- 与 apply 用同一份 source_preset_values：容器的值随源文件而变，写死会让参数格显示成"已修改"。
function M.encode_baseline()
    local out = {}
    for k, v in pairs(M.param_base or {}) do out[k] = v end
    for k, v in pairs(M.source_preset_values()) do out[k] = v end
    return out
end

-- 归一化比较：nil / true / false / 数字 / 字符串 在参数系统里混着用（下拉给的是字符串，
-- 预设给的是数字/布尔），不归一化会把"18"和18 判成不同。
local function same_val(a, b)
    if a == nil then a = "" elseif a == true then a = "true" elseif a == false then a = "false" else a = tostring(a) end
    if b == nil then b = "" elseif b == true then b = "true" elseif b == false then b = "false" else b = tostring(b) end
    return a == b
end

-- 该参数是否偏离基线。resolution 管两个字段、quality 在 bitrate 模式下值存在 video_bitrate，
-- 这两类要单独判，否则会误报/漏报。
function M.param_is_modified(spec, opts, base)
    if spec.type == "resolution" then
        return not (same_val(opts.video_width, base.video_width) and same_val(opts.video_height, base.video_height))
    elseif spec.type == "quality" and opts.video_quality_mode == "bitrate" then
        return not same_val(opts.video_bitrate, base.video_bitrate)
    elseif spec.type == "quality" then
        return not same_val(opts.video_quality, base.video_quality)
    elseif spec.field then
        return not same_val(opts[spec.field], base[spec.field])
    end
    return false
end

-- 回退时该写入的值（字符串；apply_param_value 统一按字符串入口处理）。
function M.param_baseline_value(spec, opts, base)
    if spec.type == "resolution" then
        return string.format("%dx%d", tonumber(base.video_width) or 0, tonumber(base.video_height) or 0)
    elseif spec.type == "quality" and opts.video_quality_mode == "bitrate" then
        return base.video_bitrate
    elseif spec.type == "quality" then
        return base.video_quality
    end
    return base[spec.field]
end


-- 应用预设到 opts（总是先回滚到 conf 原值再套用预设）。返回预设显示名；"default" 是 "original" 的旧名。
function M.apply_export_preset(opts, name)
    if not M.enc_defaults then snapshot_enc(opts) end
    name = tostring(name or "original")
    -- "default" 曾表示"恢复 conf 初值"，与"原始参数"（跟随源文件）是两个条目；
    -- 现在合并成一个：老 conf 里的 export_preset=default、以及任何未知名字，都落到原始参数。
    if name == "default" or name == "" or not M.EXPORT_PRESETS[name] then name = "original" end
    local preset = M.EXPORT_PRESETS[name]
    -- 先恢复 conf 原值，避免上一预设字段残留（export_preset_args/extra 已在快照内，
    -- 因此未定义这两个字段的预设下 conf 直配值保持生效）
    for k, v in pairs(M.enc_defaults) do opts[k] = v end
    if preset.from_source then
        -- 跟随源文件：容器取源扩展名对映的目标容器，视音频直接复制；
        -- 顺带把"智能精确切割"打开（切点不齐时只重编码头部一小段，保持无损）。
        for k, v in pairs(M.source_preset_values()) do opts[k] = v end
        opts.faststart = M.parse_bool(opts.faststart, true)
        M.current_preset = name
        return M.preset_label()
    end
    if preset.args and preset.args ~= "" then
        -- 完全自定义模式：仅保留容器/轨道映射等结构参数，编码参数交给用户
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
    -- 内置预设的 label 是 i18n 键，必须经语言包翻译；I18n 对未知键原样返回，自定义预设名不受影响
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
    subtitle_codec = "srt",   -- 字幕抽取格式：srt, ass, webvtt, copy（copy 走 mkv 容器，可含图形字幕）
    pixel_format = "yuv420p",
    faststart = true,
    render_fps = 30,
    timeline_fps = 10,
    max_visible_segments = 7,
    draft_mode = "strict", -- strict: 必须同时有 IN+OUT；smart: 缺 IN/OUT 时用起点/终点
    min_segment_duration = 0, -- 0 = 按帧（1/fps，默认）；>0 = 额外的人工下限（秒）
    show_export_progress = true,
    progress_interval = 0.25,
    export_confirmation = true,
    timeline_edge_snap = 5,
    timeline_handle_hit_radius = 16,
    timeline_drag_seek_fps = 20,
    timeline_drag_threshold = 4,
    timeline_drag_pause = true,
    timeline_drag_resume = true,
    diagnostic_location = "output", -- output, off（诊断信息位置）
    cleanup_stale_tasks = true,
    stale_task_days = 7,
    resume_session = true, -- 进入操作台时自动恢复上次剪辑进度
    waveform = false,      -- 时间轴背景显示音频波形（默认关：主面板「波形」按钮按需生成，避免打开视频即扫描）
    merge_validation = "basic", -- off, basic, strict（合并校验强度）
    auto_sort_segments = true,
    video_width = 0,
    video_height = 0,
    scale_mode = "fit", -- fit, pad, stretch（缩放模式）
    video_quality_mode = "crf", -- crf, cq, global_quality, bitrate, none（质量模式）
    video_quality = 18,
    video_bitrate = "",
    output_fps = 0,
    -- 变速导出：1.0 = 原速。视频靠 setpts 缩放时间戳，音频用 atempo 链保持音调
    -- （ffmpeg < 0.5 / > 2.0 时自动串联多级 atempo）。0 或 1 都视为原速、不注入滤镜。
    play_speed = 1.0,
    -- 动图导出：output_kind="animated" 时生效，与视频编码参数互不干扰
    output_kind = "video",      -- video, animated（输出类型）
    animated_format = "gif",    -- gif, webp, apng（动图格式）
    animated_fps = 12,
    animated_width = 640,       -- 0 = 保持原尺寸
    animated_loop = 0,          -- 0 = 无限循环
    -- 图片导出模式：sequence（按帧率逐帧，序列）
    --               keyframes（每个关键帧一张，只解码关键帧，快）
    --               tile（等间隔抽帧拼成一张总览图，单文件）
    image_mode = "sequence",
    tile_grid = "5x5",          -- 仅 tile 模式：网格边长，总帧数 = 边长²
    keyframe_stride = "1",      -- 仅 keyframes 模式：每 N 个关键帧取一张（1 = 全取）
    keyframe_limit = "0",       -- 仅 keyframes 模式：总张数上限，0 = 不限制（按关键帧总数自动加大步长）
    -- 自动分析类功能：导出前异步探测（结果按源文件缓存），失败只记警告并降级，绝不阻塞导出
    auto_deinterlace = false,   -- 检测到隔行就插入 bwdif/yadif（要求重新编码）
    auto_crop_black = false,    -- 采样片头检测黑边并自动裁剪（要求重新编码；手动裁剪优先）
    normalize_audio = false,    -- 响度归一化：loudnorm 两遍（第一遍测量、第二遍应用）；视频可继续流复制
    -- 去除静音段：把标记片段里的静音区间挖掉，只保留有声部分（要求重新编码，见 crop.lua）
    remove_silence = false,
    silence_db = -30,           -- silencedetect 阈值（dB）：低于它的算静音（口播 -30，噪声大可放宽到 -20）
    silence_min = 0.5,          -- 最短静音时长（秒）：短于它的停顿不算静音，避免把换气切碎
    silence_pad = 0.1,          -- 静音两侧各保留多少秒：避免掐掉起音/尾音
    loudness_target_i = -16,    -- loudnorm 目标响度（LUFS）
    loudness_target_tp = -1.5,  -- loudnorm 目标真峰值（dBTP）
    loudness_target_lra = 11,   -- loudnorm 目标响度范围（LU）
    analysis_sample_seconds = 600, -- 黑边/响度分析最多采样多少秒（长片按此截断，避免全片扫描）
    -- 智能精确切割：快速复制下只把「入点 → 下一个关键帧」这一小段重编码，其余仍流复制，
    -- 于是入点精确、无损范围也不再受关键帧约束（代价是多一次短重编码 + 一次 concat）
    smart_cut = true,   -- 默认开启：切点不齐时局部重编码消除偏移
    smart_cut_max_head = 15,    -- 头部重编码段的上限（秒）：超过就放弃智能切割（源关键帧过疏）
    animated_quality = 80,      -- WebP/AVIF 动图质量 0-100（越大越好；gif/apng 忽略）
    -- 图片序列
    image_format = "png",       -- png, jpg, webp（图片格式）
    image_quality = 3,          -- jpg/webp/avif/jxl 有损编码使用：数值越小质量越高。方向各异——
                                -- jpg 同向直传 -q:v；webp 映射为 libwebp 0-100（方向相反）；
                                -- avif 直传为 -crf；jxl 映射为 -distance
    audio_sample_rate = 0,
    audio_channels = 0,
    crop_mode = "none", -- none, aspect, custom（裁剪模式）
    crop_aspect = "source", -- source, 16:9, 9:16, 4:3, 3:4, 1:1, 21:9（裁剪比例）
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
    -- 外观已是内置常量：不再有 ui_theme 选项，
    -- 颜色/透明度/尺寸改走下面的 ui_color_* / ui_alpha_* / ui_radius_* / 几何选项。
    -- 片段预览与连播已并入「选择」：范围 = 勾选的片段（未勾选时 = 当前聚焦段），
    -- 1 段走 mpv 原生 A-B 循环、≥2 段依次连播、0 段自由播放。点时间轴空白即清空范围。
    -- 因此不再有 segment_preview 选项（原「预览」「连播」两个开关按钮已移除）。
    -- 界面语言：语言包名（如 zh_CN / en_US），auto 按 mpv 的 osd-lang 自动选择。
    -- 语言包放在 scripts/quick_cut/i18n/<locale>.lua，放入新文件即被自动发现。
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
    -- 令牌的 conf 入口。默认空串 = "未设置"，此时用内置令牌值
    -- （CONFIG_TOKENS 只在值非 nil/非空/非 auto 时覆盖令牌）。
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
    -- 置灰（不可用）按钮的表达方式：strike 删除线 / slash 斜杠 / strike_slash 两者 / dim 只压暗
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
    -- 可配置的主编辑器快捷键（逗号分隔；留空则禁用该动作）
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
    -- 直接以「动图」类型打开导出面板（同类入口见 key_export / key_merge）。默认留空 = 不占键。
    key_export_animated = "",
    key_clear = "x,X",
    key_segments = "l,L",
    key_split = "s,S,KP_DIVIDE",
    key_delete = "DEL,KP_DEC",
    key_segment_prev = "UP",
    key_segment_next = "DOWN",
    key_close = "q,Q,ESC",
    key_edit_time = "t,T",
    -- 跳到指定时间码（精确标点用：跳过去后按 [ / ] 即入/出点）
    key_seek_time = "g,G",
    key_help = "?,K",
    -- 画面辅助与播放范围
    key_crop = "c,C",
    key_wave = "w,W",
    -- 保存当前帧为图片（套用当前裁剪与图片格式，直接落盘，不走导出面板）
    key_frame_save = "f,F",
    -- 主剪辑台：收起 / 展开按钮面板（只收按钮面板，时间轴保留）
    key_panel = "h,H",
    -- 播放范围的加入/移出。**不能写 Shift+SPACE**：mpv 对单字符键（含 SPACE）会忽略
    -- Shift 修饰，Shift+SPACE 与 SPACE 是同一个键，后定义者会把「播放/暂停」整条覆盖掉。
    -- 这类键请用「字母大小写」（r,R）或「修饰键 + 命名键」（Ctrl+ENTER）表达。
    key_range_toggle = "r,R",
    key_deselect = "Ctrl+SPACE",
    key_kf_prev = "Alt+LEFT",
    key_kf_next = "Alt+RIGHT",
    key_frame_back = "Ctrl+LEFT",
    key_frame_fwd = "Ctrl+RIGHT",
    -- 导出确认面板的键盘流程（仅面板打开时生效）
    key_activate = "ENTER,KP_ENTER",
    key_focus_next = "TAB",
    key_focus_prev = "SHIFT+TAB",
    -- 调整"当前聚焦参数"的值；下拉浮层展开时改为在选项间移动高亮。
    -- 与主面板的 nudge 用同样的键，但两个上下文是互斥 section，不会互相影响。
    key_param_prev = "UP,KP8",
    key_param_next = "DOWN,KP2",
-- 把"当前聚焦参数"恢复为「原始参数」的值（下拉展开时等价于取消本次修改）
key_param_reset = "BS",

    -- 可配置的裁剪编辑器快捷键
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
    -- 同理：Shift+- / Shift+= 会被 mpv 归并成 - / =，把正常缩放覆盖掉；快速缩放用 Ctrl+±
    crop_key_smaller_fast = "Ctrl+-",
    crop_key_larger_fast = "Ctrl+=",
    crop_key_center = "c,C,KP5",
    crop_key_hud = "h,H",
    crop_key_help = "?",
    crop_key_undo = "z,Z",
    crop_key_redo = "y,Y",
    crop_key_done = "ENTER,KP_ENTER",
    crop_key_cancel = "q,Q,ESC",

    -- 剪辑模式下"额外放行"的按键。
    -- 背景：三个编辑上下文都把输入 section 以 exclusive 方式启用（除脚本自身绑定外，mpv 原绑定
    -- 与用户 input.conf 全部失效，连 SPACE/方向键/F1-F12 等都被显式写成 ignore 影子）。
    -- 想保留少量 mpv 原生操作（最典型的是滚轮调音量）就得往 section 里显式加行。
    -- 语法 = input.conf 原生语法，分号分行，`#` 开头的行可当注释；追加在影子 ignore 之后，故能覆盖影子。
    -- 例：extra_bindings=WHEEL_UP add volume 5;WHEEL_DOWN add volume -5
    -- 例：extra_bindings=MBTN_MID cycle mute;MBTN_BACK playlist-prev
    extra_bindings = "",
    -- OSC 接管配置
    takeover_osc = true,
    takeover_uosc = true,
    flash_osc_on_restore = true,
    uosc_takeover_elements = "timeline,controls,volume,speed",
    -- 按钮文字/高亮色（13 个）
    btn_mode_color = "", btn_seg_color = "", btn_in_color = "",
    btn_out_color = "", btn_indec_color = "", btn_ininc_color = "",
    btn_add_color = "", btn_cut_color = "", btn_mrg_color = "",
    btn_rst_color = "", btn_exit_color = "", btn_close_color = "", btn_del_color = "", btn_folder_color = "",
    export_preset = "original",
    export_preset_list = "",
    export_preset_args = "",
    export_preset_extra = "",
    ffmpeg_extra_args = "",
    -- 输出命名模板（空 = 默认规则）。必须列在这里：mpv 的 read_options 只读本表已有的键，
    -- 漏写会让 conf 里同名项被静默忽略、功能整条不生效（util.apply_name_template 支持
    -- {name}/{index}/{in}/{out}，见 conf 注释）。
    output_name_template = "",
}

-- 布局参数默认值快照：用于判断 conf 是否显式设置了某布局参数
-- （opts 值 != 默认值即视为显式设置，此时布局令牌不覆盖）。
M.opts_defaults = {}
for _k, _v in pairs(M.opts) do M.opts_defaults[_k] = _v end

-- UI 尺寸预设：只覆盖"用户没在 conf 里显式设置过"的项（见 init_theme）。
-- comfortable 的语义是「跟随令牌自己的几何」（由 ui.lua 的令牌决定），
-- 因此它不是一组数值而是"不改动"；compact / ultra_compact 才是显式压紧。
M.UI_PRESETS = {
    comfortable={button_font_size=16,tooltip_font_size=14,menu_font_size=15,menu_title_font_size=18,timeline_height=32,button_height=42,button_gap=6,button_group_gap=12,controls_margin_x=14,tooltip_gap=7},
    compact={button_font_size=12,tooltip_font_size=12,menu_font_size=12,menu_title_font_size=14,timeline_height=26,button_height=32,button_gap=4,button_group_gap=8,controls_margin_x=10,tooltip_gap=5},
    ultra_compact={button_font_size=11,tooltip_font_size=12,menu_font_size=12,menu_title_font_size=14,timeline_height=24,button_height=30,button_gap=4,button_group_gap=8,controls_margin_x=10,tooltip_gap=5},
}

-- 导出确认面板中的可调参数（两列排布，每项可左右循环切换）
-- 下拉列表末尾"自定义…"选项的哨兵值：选中它不直接赋值，而是打开 mp.input 输入框。
-- 只有标记了 custom=true 的参数才会追加该选项。
M.CUSTOM_PARAM_VALUE = "__custom__"

-- 动图模式下的参数集。output_kind=="animated" 时，确认面板改用它替代 ENCODE_PARAMS。
-- labels 用于把取值显示得更易读（如宽度 0 显示为"原尺寸"）。
M.ANIMATED_PARAMS = {
    {id="animated_format", label="param.animated_format", type="list", field="animated_format",
        values={"gif","webp","apng","avif"},
        -- value_requires：选项按 ffmpeg 能力探测过滤（core 的 filter_values 消费）
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

-- 动图格式 → 输出扩展名
M.ANIMATED_EXT = {gif="gif", webp="webp", apng="png", avif="avif"}

-- ============================================================================
-- 导出类型与参数集
-- export_kind 决定确认面板显示哪套参数。每套参数内部 id 唯一；部分字段跨集共享
-- （encode_container、audio_codec、animated_fps 等），语义一致，因此过滤、赋值、
-- 格式联动、自定义输入全部按 active_params() 的当前激活集共用同一套逻辑。
-- ============================================================================

M.EXPORT_KINDS = {
    {id="video",    label="confirm.kind_video"},
    {id="audio",    label="confirm.kind_audio"},
    {id="animated", label="confirm.kind_animated"},
    {id="image",    label="confirm.kind_image"},
    {id="subtitle", label="confirm.kind_subtitle"},
}
M.DEFAULT_EXPORT_KIND = "video"

-- 仅导出音频：屏蔽所有视频相关参数
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

-- 图片序列：每帧（或按帧率抽取）输出为一张图
M.IMAGE_PARAMS = {
    {id="image_mode", label="param.image_mode", type="list", field="image_mode",
        values={"sequence","keyframes","tile","single"},
        labels={["sequence"]="value.img_sequence",["keyframes"]="value.img_keyframes",["tile"]="value.img_tile",["single"]="value.img_single"}},
    {id="image_format", label="param.image_format", type="list", field="image_format",
        values={"png","jpg","webp","avif","jxl","tiff"},
        -- avif 需 avif muxer（每帧独立容器）+ libaom-av1，jxl 需 libjxl 编码器：两者都是 ffmpeg 5.1
        -- 引入，且都还要构建时启用对应外部库 —— 所以只按能力探测，不看版本号（5.1 也可能缺库）。
        value_requires={
            avif={encoder="libaom-av1",muxer="avif"},
            jxl={encoder="libjxl"},
        }},
    {id="image_quality", label="param.image_quality", type="list", field="image_quality",
        values={"2","3","5","10","20","31"}, labels={["2"]="value.best",["31"]="value.worst"}, custom=true},
    {id="animated_fps", label="param.animated_fps", type="list", field="animated_fps",
        values={"1","2","5","10","12","24"}, custom=true},
    {id="animated_width", label="param.animated_width", type="list", field="animated_width",
        values={"0","320","480","640","854","1280"}, labels={["0"]="value.original_size"}, custom=true},
    -- 拼图网格（仅 tile 模式生效）：等间隔抽 边长² 帧拼成一张总览图
    {id="tile_grid", label="param.tile_grid", type="list", field="tile_grid",
        values={"3x3","4x4","5x5","6x6","8x8"}, custom=true},
    -- 关键帧模式：跳采步长（每 N 个关键帧取一张）与张数上限（按关键帧总数自动加大步长）
    {id="keyframe_stride", label="param.keyframe_stride", type="list", field="keyframe_stride",
        values={"1","2","3","5","10","20"}, labels={["1"]="value.all_keyframes"}, custom=true},
    {id="keyframe_limit", label="param.keyframe_limit", type="list", field="keyframe_limit",
        values={"0","20","50","100","200","500"}, labels={["0"]="value.no_limit"}, custom=true},
}

M.IMAGE_EXT = {png="png", jpg="jpg", webp="webp", avif="avif", jxl="jxl", tiff="tiff"}

-- 字幕抽取：只导出当前选中字幕轨（内嵌或外挂），不带视频/音频。
-- 文本格式需要源轨道本身是文本字幕（PGS/VobSub 等图形字幕转不了文本，用 copy 到 mkv）。
M.SUBTITLE_PARAMS = {
    {id="subtitle_codec", label="param.subtitle_codec", type="list", field="subtitle_codec",
        values={"srt","ass","webvtt","copy"},
        labels={["copy"]="value.copy_raw"}},
}

-- 字幕格式 → 输出扩展名（copy 落到 mkv：能容纳任何字幕流编码）
M.SUBTITLE_EXT = {srt="srt", ass="ass", webvtt="vtt", copy="mkv"}

-- 优化目标（确认面板预设下拉的第二组）：一键把编码参数调到某个取向。
-- 数值按 x264 系经验设定，应用后由调用方做格式联动纠正（coerce_all）；
-- 不改动当前编码预设（current_preset 不变），仅覆盖 opts 字段。
M.OPTIMIZE_GOALS = {
    quality  = {preset="veryslow", video_quality_mode="crf", video_quality=16, audio_bitrate="256k"},
    speed    = {preset="veryfast", video_quality_mode="crf", video_quality=23, audio_bitrate="128k"},
    lossless = {encode_container="mkv", preset="veryslow", video_quality_mode="crf",
                video_quality=12, audio_codec="flac", audio_bitrate=""},
}
M.OPTIMIZE_GOAL_ORDER = {"quality", "speed", "lossless", "size"}

-- 应用优化目标；未知 goal 返回 false。
-- profile（core 传入的源画质画像 {bpp=...}）驱动源自适应：
--   bpp = 视频码率/(fps×宽×高)，H.264 经验值 ≈0.07 为常见质量，<0.04 视为过度压缩的低质源——
--   重编码无法还原源里没有的细节，盲目高画质投入只会膨胀体积，自动下调并提示流复制。
-- 返回 applied(bool), note(已本地化的自适应说明，nil 表示无)。
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

-- 导出类型 → 参数集。用函数而非静态表：静态表在定义时取值，
-- 会受模块内各 M.* 定义先后顺序影响而拿到 nil。
function M.params_for_kind(kind)
    if kind == "audio" then return M.AUDIO_PARAMS end
    if kind == "animated" then return M.ANIMATED_PARAMS end
    if kind == "image" then return M.IMAGE_PARAMS end
    if kind == "subtitle" then return M.SUBTITLE_PARAMS end
    return M.ENCODE_PARAMS
end

-- label 存 i18n 键而非字面文本，渲染时经 L() 翻译；labels 是取值→显示文本的映射，同样可翻译。
-- 编码器 → 编码格式名。参数格与下拉显示"格式名 (编码器)"，与"源文件"行（mpv 给的格式名，
-- 如 H.264）说同一套话，避免一边 H.264 一边 libx264 看起来像两回事。
M.CODEC_DISPLAY = {
    libx264 = "H.264", h264_nvenc = "H.264", h264_qsv = "H.264", libopenh264 = "H.264",
    libx265 = "H.265", hevc_nvenc = "H.265", hevc_qsv = "H.265",
    ["libvpx-vp9"] = "VP9", libvpx_vp9 = "VP9", libsvtav1 = "AV1", av1_nvenc = "AV1",
    aac = "AAC", libmp3lame = "MP3", libopus = "Opus", flac = "FLAC", ac3 = "AC3",
}
-- 编码器 id 集合：下拉里出现的都是这些（选择列表给的就是编码器名）。它们的名字已自带产出
-- 格式（libx264→H.264、hevc_nvenc→H.265、libsvtav1→AV1），再冠 "H.264 (…)" 前缀只是白白
-- 占掉格子宽度。只有"纯格式名"（h264 / hevc / aac …，源文件行显示的那种）才需要美化。
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

-- 编码名的**显示文本**。copy 在参数表里是"复制"（不重编码），但 CODEC_DISPLAY 里没有它，
-- 摘要行/下拉兜底若直接用 codec_label 就会漏出英文原文 copy —— 用户看到的"copy"就是这个。
function M.codec_text(v)
    v = tostring(v or "")
    if v == "copy" then return I18n("value.copy") end
    return M.codec_label(v) or v
end

-- ============================================================================
-- 参数可见性 × 当前模式
--   智能精确切割（快速）= 视音频流复制 + 头部小段重编码；重新编码 = 整片重编码。
--   于是"当前模式下到底哪些参数在起作用"是确定的，界面必须跟着走，否则一堆参数看着可用
--   其实什么都不做，界面必须跟着当前模式走。
-- 只对 video 导出类型收紧：动图/图片/字幕不做流复制，一律不藏参数（防"空面板"）。
-- ============================================================================
M.PARAM_FAST_ONLY = {           -- 只在快速复制（流复制）显示
    smart_cut = true,
}
M.PARAM_PRECISE_ONLY = {        -- 只在重新编码显示（流复制下不生效）
    video = {
        video_codec = true, preset = true, quality_mode = true, quality = true,
        pixel_format = true, resolution = true, fps = true, play_speed = true,
        normalize_audio = true, auto_deinterlace = true, auto_crop_black = true, remove_silence = true,
    },
}

-- ffmpeg 缺失时（core.lua 启动探测失败 → 导出走 mpv 编码模式兜底）**整类做不了**的参数。
-- 这类参数不是"当前模式下不生效"（那种直接藏起来更干净），而是"装了 ffmpeg 就生效"：
-- 留着位置但置灰 + tooltip 说原因，用户才知道自己失去了什么、怎么补回来。
-- 只在 ffmpeg 真缺失时才返回 true，装了 ffmpeg 的机器上界面与以前完全一致。
M.MPV_MISSING_PARAM_TIPS = {
    smart_cut = "tip.needs_ffmpeg_smart",
}

-- 当前是否处于"没有 ffmpeg"的运行态。core.lua 在启动探测后写入 _G.QUICK_CUT_RUNTIME；
-- 该表缺失（单测/预览桩）时按"有 ffmpeg"处理，避免预览与环境不一致。
function M.ffmpeg_missing()
    local rt = _G.QUICK_CUT_RUNTIME
    if type(rt) ~= "table" then return false end
    return rt.ffmpeg_found == false
end

-- 该参数在"没有 ffmpeg"时是否整类不可用（str 为 tooltip 键，nil 表示可用）。
function M.missing_ffmpeg_tip(spec)
    if not M.ffmpeg_missing() then return nil end
    local key = spec.id or spec.field or ""
    return M.MPV_MISSING_PARAM_TIPS[key]
        or (spec.field and M.MPV_MISSING_PARAM_TIPS[spec.field]) or nil
end

-- 参数对"源能力"的要求：源没有对应轨道时这些参数无意义（无声视频的音频编码等）。
M.PARAM_NEEDS = {
    audio_codec = "audio", audio_bitrate = "audio", audio_sample_rate = "audio", audio_channels = "audio",
    normalize_audio = "audio", remove_silence = "audio",
    video_codec = "video", preset = "video", quality_mode = "video", quality = "video",
    pixel_format = "video", resolution = "video", fps = "video",
    scale_mode = "video", auto_deinterlace = "video", auto_crop_black = "video",
}

-- 该参数在当前导出类型 + 当前模式下是否显示。accurate=false 即快速复制（流复制）。

-- -movflags +faststart 是 mp4/mov 封装器的选项，导出层也只在容器是这两个时才加
-- （export.lua: container == "mp4" or "mov"）→ 其它容器下这个开关什么也不做，别显示。
M.FASTSTART_CONTAINERS = {mp4 = true, mov = true}

function M.param_visible(spec, kind, accurate)
    local key = spec.id or spec.field or ""
    -- 没有 ffmpeg 时不藏、只置灰（见 missing_ffmpeg_tip）：先于所有"按模式隐藏"的规则返回，
    -- 否则智能切割会因"快速复制才显示"这条而被藏掉，用户永远看不到它为什么不可用。
    if M.missing_ffmpeg_tip(spec) then return true end
    if key == "faststart" then
        local c = tostring((M.opts or {}).encode_container or ""):gsub("^%.", "")
        if not M.FASTSTART_CONTAINERS[c] then return false end
    end
    -- 源能力：源没有音轨/视频轨时把对应参数收起来（未知则不收）
    local needs = M.PARAM_NEEDS[key] or (spec.field and M.PARAM_NEEDS[spec.field])
    if needs then
        local src = M.source_info()
        if src then
            if needs == "audio" and src.has_audio == false then return false end
            if needs == "video" and src.has_video == false then return false end
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
    -- 顺序有意义：容器变更后的自动纠正取"第一个合法值"（coerce_dependents），下拉也是这个顺序。
    -- libvpx-vp9 排在 libsvtav1 之前：webm 的合法集只有这两个，AV1 软件编码比 VP9 慢得多。
    -- copy 与"原始参数"预设一致：直接复制源视频流；labels 只给需要翻译的那项
    {id="video_codec", label="param.video_codec", type="list", field="video_codec",
        values={"libx264","libx265","libvpx-vp9","libsvtav1","h264_nvenc","hevc_nvenc","av1_nvenc","copy"},
        labels={copy="value.copy"}},
    {id="preset", label="param.preset", type="list", field="preset", dyn="preset"},
    {id="quality_mode", label="param.quality_mode", type="list", field="video_quality_mode",
        values={"crf","cq","global_quality","bitrate"}},
    -- custom=true：下拉末尾追加"自定义…"，点击后用 mp.input 手动输入
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
    -- 变速：ffmpeg 用 setpts + atempo（保持音调），要求重新编码
    {id="play_speed", label="param.play_speed", type="list", field="play_speed",
        values={"0.25","0.5","0.75","1","1.25","1.5","2","4"}, custom=true,
        desc="param.play_speed_desc"},
    {id="faststart", label="param.faststart", type="bool", field="faststart", desc="param.faststart_desc"},
    -- 智能精确切割（仅快速复制生效：入点前一小段重编码 + 其余流复制 + concat 缝合）
    {id="smart_cut", label="param.smart_cut", type="bool", field="smart_cut", desc="param.smart_cut_desc"},
    -- 自动处理（导出前异步探测源；开关即全部交互，参数细节在 conf 里）
    {id="auto_deinterlace", label="param.auto_deinterlace", type="bool", field="auto_deinterlace", desc="param.auto_deinterlace_desc"},
    {id="auto_crop_black", label="param.auto_crop_black", type="bool", field="auto_crop_black", desc="param.auto_crop_black_desc"},
    {id="normalize_audio", label="param.normalize_audio", type="bool", field="normalize_audio", desc="param.normalize_audio_desc"},
    -- 去静音段（细节参数在 conf 里：silence_db / silence_min / silence_pad，与响度归一化同款）
    {id="remove_silence", label="param.remove_silence", type="bool", field="remove_silence", desc="param.remove_silence_desc"},
}

-- 各编码器族对应的 preset 取值
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

-- label 存 i18n 键（原尺寸）；数值型档位（2160p 等）语言无关，直接用字面值
M.RESOLUTIONS = {
    {label="value.original_size", w=0, h=0}, {label="2160p", w=3840, h=2160}, {label="1080p", w=1920, h=1080},
    {label="720p", w=1280, h=720}, {label="480p", w=854, h=480},
}
M.FPS_OPTIONS = {0, 24, 25, 30, 60}
M.BITRATE_OPTIONS = {"1M","2M","5M","8M","12M","20M","35M","50M"}

-- ============================================================================
-- 格式兼容矩阵
-- 用于动态过滤下拉选项，避免出现 ffmpeg 直接报错或生成的文件不可播放的组合。
-- 表中未列出的容器/编码器表示不做限制（Matroska 几乎通吃）。
-- 约束只针对"规范层面不合法"，不追求覆盖所有 ffmpeg 勉强能跑的边缘组合。
-- ============================================================================

-- 容器 → 允许的视频编码
--   WebM 规范只承载 VP8/VP9/AV1；MPEG-TS 不承载 VP9/AV1
--   copy（直接复制源流）对所有容器都合法：能不能装进去要看到时候的**源编码**，
--   那是导出层的 fast_remux_ext 在判断（装不进会退回重编码并说明原因），
--   不在这里一刀切——否则"原始参数"预设写入的 copy 会被格式联动改写成第一个编码器，
--   于是 64 位无损复制变成全片重编码。
M.CONTAINER_VIDEO_CODECS = {
    webm = {["libvpx-vp9"]=true, ["libsvtav1"]=true, copy=true},
    ts   = {libx264=true, libx265=true, h264_nvenc=true, hevc_nvenc=true, copy=true},
    mp4  = {libx264=true, libx265=true, libsvtav1=true,
            h264_nvenc=true, hevc_nvenc=true, av1_nvenc=true, copy=true},
    mov  = {libx264=true, libx265=true, libsvtav1=true,
            h264_nvenc=true, hevc_nvenc=true, av1_nvenc=true, copy=true},
}

-- 容器 → 允许的音频编码。**这张表以实测为准**（逐个容器×编码组合真跑过），因为"常识"在这个领域已经过时：
--   · mp4 能装 flac（实测可写）与 opus（实测可写，报错原文都写着 opus only supported in MP4）
--   · mov 装不了 opus / flac（`opus only supported in MP4` / `flac only supported in MP4`）
--   · webm 只认 opus（aac/mp3 直接报 Only VP8 or VP9 or AV1 video and Vorbis or Opus audio）
--   · wav 只放无损 PCM 家族（opus 报 Codec opus not supported in WAVE format；aac 虽被 muxer
--     容忍，但aac-in-wav 不是可播放的标准文件，故不列）
--   · 音频导出专用的 6 个容器（m4a/mp3/opus/flac/wav/ogg）若不加约束，
--     下拉里能选出 m4a+libopus 这种必失败组合 —— 这就是补这张表的原因。
--   copy 一律保留：能不能原样装进去由导出层的 container_copy_ok / fast_remux_ext 按源编码判断，
--   配置层只回答"这个容器的编码器选单里有哪些"。
M.CONTAINER_AUDIO_CODECS = {
    -- 视频容器额外允许 none（无声视频）。下面 6 个音频导出专用容器**刻意不加**：
    -- 那样切到「音频」类型后 none 会被判为非法并被自动纠正，不会导出成空文件。
    webm = {libopus=true, copy=true, none=true},
    ts   = {aac=true, libmp3lame=true, copy=true, none=true},
    mp4  = {aac=true, libmp3lame=true, libopus=true, flac=true, copy=true, none=true},
    mov  = {aac=true, libmp3lame=true, copy=true, none=true},
    -- 音频导出（AUDIO_PARAMS.container 的候选值）
    m4a  = {aac=true, copy=true},
    mp3  = {libmp3lame=true, copy=true},
    opus = {libopus=true, copy=true},
    flac = {flac=true, copy=true},
    wav  = {libmp3lame=true, copy=true},
    ogg  = {libopus=true, copy=true},
}

-- 编码器 → 允许的质量模式。NVENC 系列不支持 crf，只能用 cq / global_quality / bitrate
M.CODEC_QUALITY_MODES = {
    h264_nvenc = {cq=true, global_quality=true, bitrate=true},
    hevc_nvenc = {cq=true, global_quality=true, bitrate=true},
    av1_nvenc  = {cq=true, global_quality=true, bitrate=true},
}

-- 依赖链：某个配置项变更后，需要重新校验合法性的下游参数（按 field 名索引）
M.PARAM_DEPENDENTS = {
    encode_container = {"video_codec", "audio_codec"},
    video_codec      = {"quality_mode", "preset"},
}

function M.container_video_codecs(container) return M.CONTAINER_VIDEO_CODECS[tostring(container or "")] end
-- 容器 → 一个"真实"视频编码器（必须重编码时用：限体积、响度归一化等场景要替掉 copy）。
-- 偏好序只影响"挑哪个"，能不能用由容器表决定；表里没有该容器时不限制，退回 libx264。
M.VIDEO_ENCODER_PREFERENCE = {"libx264", "libx265", "libvpx-vp9", "libsvtav1",
                              "h264_nvenc", "hevc_nvenc", "mpeg4"}
function M.real_video_codec_for(container)
    local allow = M.container_video_codecs(container) or {}
    for _, cand in ipairs(M.VIDEO_ENCODER_PREFERENCE) do
        if allow[cand] then return cand end
    end
    return "libx264"
end

-- 容器 → 一个有损音频编码器（同上场景）。webm/ogg 只收 opus，ts/mp4/mov 收 aac；
-- 表里没有该容器（如 mkv）= 不限制，aac 通吃。
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

-- 确认面板参数/预设下拉浮层最多同时显示的选项行数，超出部分用滚轮滚动
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

-- 颜色顺序管线（改颜色前必读）：ui 设计令牌与 config 的 theme.* 一律是 **RGB**
-- （"RRGGBB"）；转成 ASS 的 &HBBGGRR& 是 ui.lua 的 ass_color() 在写入时的唯一职责。
-- 曾出现过双重交换：此处（color_or / apply_ui_tokens）先转了一次 ASS 顺序，
-- ui.lua 再按 RGB 转一次 → R/B 反向，把蓝色写成 0A84FF 会渲染成橙 FF840A，
-- match / danger / warning / timeline 配色全错；因白灰近对称而长期未暴露。
-- 结论：颜色值在本模块内只做「归一化」，不做换序。
function M.normalize_rgb(value)
    value = tostring(value or ""):gsub("^#", ""):gsub("%s.*$", "")
    if not value:match("^%x%x%x%x%x%x%x?%x?$") or (#value ~= 6 and #value ~= 8) then return nil end
    return value:upper()
end

-- 仅当确实需要 ASS 顺序（如直接拼 &H...& 字符串）时使用；UI 颜色不要用它。
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
    if opts.merge_validation ~= "off" and opts.merge_validation ~= "basic" and opts.merge_validation ~= "strict" then opts.merge_validation = "basic" end
    opts.video_width = math.floor(clamped_number(opts.video_width, 0, 0, 16384))
    opts.video_height = math.floor(clamped_number(opts.video_height, 0, 0, 16384))
    opts.video_quality = clamped_number(opts.video_quality, opts.crf, 0, 63)
    opts.output_fps = clamped_number(opts.output_fps, 0, 0, 240)
    -- 变速：0 与 1 都归一到 1.0（=原速），避免 0.999 这类值制造无意义的 setpts 滤镜
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
    -- 预设只填"用户没显式设置过"的项：conf 里写过的值优先（与「conf 显式 > 预设 > 默认」一致），
    -- 否则同时写了 ui_preset 与具体项的用户会发现自己的值静默失效。
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
    -- 动图/图片导出参数钳制：非法值（如 animated_quality=200、animated_fps=999）直接进 ffmpeg
    -- 会报错或产生怪异输出。
    opts.animated_fps = math.floor(clamped_number(opts.animated_fps, 12, 1, 60))
    opts.animated_quality = math.floor(clamped_number(opts.animated_quality, 80, 0, 100))
    opts.animated_width = math.floor(clamped_number(opts.animated_width, 0, 0, 16384))
    opts.animated_loop = math.floor(clamped_number(opts.animated_loop, 0, 0, 1000))
    opts.image_quality = math.floor(clamped_number(opts.image_quality, 3, 0, 31))
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
    -- encode_container 置空 + default 预设会让导出扩展名退化为 "."：小写化、去前导点、
    -- 空串兜底 mp4。不做白名单校验（任意字符串都会透传给 ffmpeg 作 -f/扩展名）。
    opts.encode_container = tostring(opts.encode_container or "mp4"):lower():gsub("^%.", "")
    if opts.encode_container == "" then opts.encode_container = "mp4" end
    opts.action_hint_font_size = clamped_number(opts.action_hint_font_size, 14, 8, 32)
    opts.action_hint_duration = clamped_number(opts.action_hint_duration, 1.25, 0.3, 10)
    opts.action_hint_long_duration = clamped_number(opts.action_hint_long_duration, 2.0, 0.5, 15)
    opts.action_hint_max_width = math.floor(clamped_number(opts.action_hint_max_width, 720, 240, 1920))
    opts.action_hint_line_gap=math.floor(clamped_number(opts.action_hint_line_gap,5,0,24))
    opts.job_card_width=math.floor(clamped_number(opts.job_card_width,230,180,420))
    -- 0 是合法值 = "自然高度"（卡片高度只由内容决定，见 task card 的 ch=max(job_card_height, content_h)）
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
    -- uosc 的 color= 也是 RGB 顺序：原样归一化即可（消费端与强调色共用 ass_color 管线）
    for k, v in pairs(raw_colors) do colors[k] = M.normalize_rgb(v) end
    local op = M.parse_kv(uosc.opacity)

    theme.scale = clamped_number(opts.scale, 1, 0.5, 3)
    theme.scale_fs = clamped_number(opts.scale_fullscreen, theme.scale, 0.5, 3)
    theme.radius = opts.radius ~= "auto" and clamped_number(opts.radius, 4, 0, 30) or (tonumber(uosc.border_radius) or 4)
    theme.text_border = opts.text_border ~= "auto" and clamped_number(opts.text_border, 1.2, 0, 10) or (tonumber(uosc.text_border) or 1.2)
    -- fg/bg/match/success/error/heatmap 由 apply_ui_tokens 依据当前令牌统一赋值。
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
    -- 按钮语义色在 apply_ui_tokens 之后解析，保证回退色来自当前令牌。
    theme.font = opts.font ~= "auto" and opts.font ~= "" and opts.font or nil
    theme.button_radius = opts.button_radius ~= "auto" and clamped_number(opts.button_radius, theme.radius, 0, 30) or theme.radius
    theme.menu_radius = opts.menu_radius ~= "auto" and clamped_number(opts.menu_radius, theme.radius + 3, 0, 40) or (theme.radius + 3)
    theme.tooltip_radius = opts.tooltip_radius ~= "auto" and clamped_number(opts.tooltip_radius, theme.radius, 0, 30) or theme.radius
    theme.deck_border=color_or(opts.deck_border_color,"FFFFFF")
    -- 时间轴配色统一由 ui_tokens 决定（见 apply_ui_tokens）。
    -- 回退色用正文白：框线本身带半透明黑描边，在任何画面上对比度最高
    theme.crop_frame = color_or(opts.crop_frame_color, theme.fg)
    theme.crop_mask = color_or(opts.crop_mask_color, theme.curtain)
end

-- 可由 conf 覆盖的布局参数：在 tokens 中声明这些键即可改变对应布局。
-- 键名 = opts 布局参数名；值 = 令牌键名（同名时省略）。
-- 优先级：conf 显式设置 > 预设 > 默认。
M.LAYOUT_MAP = {
    -- 字体（token 键 → opts 键）
    font_button = "button_font_size",
    font_tooltip = "tooltip_font_size",
    font_menu = "menu_font_size",
    font_menu_title = "menu_title_font_size",
    -- 同名键（token 键 == opts 键）
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
    -- 记录 conf 显式设置的布局参数（opts 值 != 默认值即视为显式设置），
    -- 供 apply_ui_tokens 判断布局令牌是否可覆盖（conf 显式优先）。
    M.explicit_layout = {}
    for token_key, opt_key in pairs(M.LAYOUT_MAP) do
        if M.opts[opt_key] ~= M.opts_defaults[opt_key] then M.explicit_layout[opt_key] = true end
    end
    -- 显式选定的 ui_preset 同样视为"用户显式设置"：否则预设之外的几何（button_height
    -- / timeline_height / 字号…）会静默压掉预设 —— ui_preset 退化成"只影响预设没声明的项"，
    -- 用户看到的就是"预设失效"。加上这一步后优先级为：conf 单项 > 显式预设 > 默认。
    -- comfortable 是默认值（语义 = 跟随令牌尺寸），不参与；用户显式写 comfortable 与不写
    -- 无法区分（mpv 不告诉我们哪些键来自 conf 文件），语义上也不需要区分。
    if M.opts.ui_preset ~= M.opts_defaults.ui_preset and M.UI_PRESETS[M.opts.ui_preset] then
        for key in pairs(M.UI_PRESETS[M.opts.ui_preset]) do M.explicit_layout[key] = true end
    end
    -- 自定义预设：解析 conf 后并入预设表与循环顺序
    M.custom_presets = M.load_custom_presets()
    for i, p in ipairs(M.custom_presets) do p.from_conf = true; M.EXPORT_PRESETS["u" .. i] = p end
    -- 界面里存下来的预设（可编辑）并进索引；启动默认预设优先于 conf 的 export_preset
    M.apply_preset_store(M.load_preset_store())
    if M.preset_store.default ~= "" and M.EXPORT_PRESETS[M.preset_store.default] then
        M.opts.export_preset = M.preset_store.default
    end
    snapshot_params(M.opts)   -- 必须在应用预设**之前**：这里拿到的是 conf 初值
    M.apply_export_preset(M.opts, M.opts.export_preset)
    init_theme()
    return M.opts, M.theme
end

-- UI 模块解析出设计令牌后，覆盖 theme 与部分 opts（原 core.lua 的令牌同步段）。
function M.apply_ui_tokens(ui_tokens)
    local opts, theme = M.opts, M.theme
    -- 颜色顺序（勿改）：theme.* 与 ui 令牌同为 RGB，只有 ui.lua 的 ass_color() 在写 ASS
    -- 时才换序。这里绝不能再调 rgb_to_ass —— 与 ass_color 叠加就是双重交换，
    -- 把蓝色写成 0A84FF 会渲染成橙 FF840A（强调/危险/警告色 R/B 全反）。
    theme.fg=ui_tokens.color_text; theme.bg=ui_tokens.color_panel; theme.fgt=ui_tokens.color_text_inverse; theme.bgt=theme.fg
    theme.match=ui_tokens.color_primary; theme.success=ui_tokens.color_success; theme.error=ui_tokens.color_danger; theme.heatmap=ui_tokens.color_warning
    theme.timeline_bg=ui_tokens.color_timeline; theme.timeline_segment=ui_tokens.color_segment; theme.timeline_disabled=ui_tokens.color_segment_disabled; theme.timeline_playhead=ui_tokens.color_playhead; theme.pending=ui_tokens.color_pending
    -- crop_frame/crop_mask 的回退色必须在令牌就绪后按同一优先级（conf 显式设置优先）重新解析，
    -- 否则裁剪框颜色不会跟随令牌。
    theme.crop_frame=color_or(opts.crop_frame_color, theme.fg)
    theme.crop_mask=color_or(opts.crop_mask_color, theme.curtain)
    -- 菜单透明度/圆角、模态幕布透明度同样在令牌就绪后重新解析：可用 tokens 里的
    -- alpha_menu / alpha_curtain / radius_menu 覆盖默认值，conf 显式设置（opts.* 非 auto）优先。
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
    -- 布局令牌写回 opts（conf 显式设置优先，未显式设置才应用令牌值）。
    -- 改 LAYOUT_MAP 里登记的令牌即可改变对应布局。
    for token_key, opt_key in pairs(M.LAYOUT_MAP) do
        if ui_tokens[token_key] ~= nil and not M.explicit_layout[opt_key] then
            opts[opt_key] = ui_tokens[token_key]
        end
    end
    -- 令牌确定后再解析按钮语义色，使 btn_*_color 的回退色跟随当前外观。
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
