-- quick_cut 导出/合并流水线：ffmpeg 参数、进度、诊断
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

local U = require "util"
local Editor = require "editor"
local Crop = require "crop"
local config = require "config"

local M = {}

local opts, state, show_hint, request_render, get_queue, L, choice_label, choice_name

-- deps（由 core 注入）:
--   opts, state, show_hint, request_render, get_queue, L, choice_label
-- 注意：这里**只拷贝需要的字段**，不保留 d 本身（所以别在别的函数里写 d.xxx / deps.xxx）
function M.init(d)
    opts = d.opts
    state = d.state
    show_hint = d.show_hint
    request_render = d.request_render
    get_queue = d.get_queue
    L = d.L
    choice_label = d.choice_label
    choice_name = d.choice_name
end

M.job = {
    preparing = false,   -- 准备窗口（分析/数关键帧/探测 ffmpeg）内也要排他，见 run_cut
    running = false, cancel_requested = false, async_id = nil,
    current_output = nil, current_temp = nil,
    progress_file = nil, progress_timer = nil,
    progress = 0, overall_progress = 0, speed = "", segment_length = 0,
    current = 0, total = 0, succeeded = 0, failed = 0,
    completed_duration = 0, total_duration = 0, source_path = nil,
    status = "idle", started_at = 0, progress_samples = 0, animation_frame = 0,
    operation = nil, work_files = {}, work_durations = {}, concat_list = nil,
    plan = nil, stage = nil, current_range = nil, failure = nil,
    -- 快速复制下智能切割没生效的原因（见 finish_job：挂到完成通知正文上）
    smart_skip = nil,
    last_output = nil, last_output_dir = nil,
}
local job = M.job

local environment = {checked = false, ffmpeg = false, ffmpeg_ver = nil, caps = nil, caps_pending = {}, probing = false}

-- ffmpeg 能力探测：解析 -encoders / -muxers 输出，缓存编码器与封装器名称集合。
-- config.lua 的格式条目用 value_requires={encoder=...,muxer=...} 声明依赖，
-- core 的 filter_values 借此把当前 ffmpeg 不支持的格式从下拉中剔除。
-- 惰性触发一次并缓存；探测完成前相关格式按"不可用"处理（完成回调触发重渲染）。
function M.probe_capabilities(callback)
    if environment.caps then
        -- 回调抛错不能吞：它是「探测完成后刷新 UI」的唯一入口，吞掉就只剩「下拉不刷新」、日志无痕
        if callback then
            local ok, err = pcall(callback, environment.caps)
            if not ok then msg.warn("quick_cut: caps callback failed: " .. tostring(err)) end
        end
        return
    end
    if callback then environment.caps_pending[#environment.caps_pending + 1] = callback end
    if environment.probing then return end
    environment.probing = true
    local caps = {encoders = {}, muxers = {}, filters = {}}
    local remaining = 3
    local function finish()
        remaining = remaining - 1
        if remaining > 0 then return end
        environment.caps = caps
        environment.probing = false
        for _, cb in ipairs(environment.caps_pending) do
            local ok, err = pcall(cb, caps)
            if not ok then msg.warn("quick_cut: caps callback failed: " .. tostring(err)) end
        end
        environment.caps_pending = {}
    end
    local args_plan = {
        {kind = "encoders"},
        {kind = "muxers"},
        -- 滤镜清单：给去隔行等自动处理挑可用的滤镜（bwdif / yadif）
        {kind = "filters"},
    }
    for _, plan in ipairs(args_plan) do
        local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stdout=true,
            args={opts.ffmpeg,"-hide_banner","-"..plan.kind}},function(success,res)
            if success and res and res.stdout then
                for line in (res.stdout .. "\n"):gmatch("([^\r\n]*)\r?\n") do
                    -- 编码器行：" V....D libaom-av1    ..."；封装器行："  E avif   ..."
                    local name = line:match("^%s*[A-Z%.]+%s+([%w_]+)%s")
                    if name then caps[plan.kind][name] = true end
                end
            end
            finish()
        end)
        -- 异步启动失败时回调不会触发：finish() 必须照样计数，否则 probing 永久为 true、
        -- caps 永不产出，value_requires 声明的格式（avif/jxl 等）在本次会话内从下拉中
        -- 永久消失且不可重试、全程无日志。
        if not ok_start then
            msg.warn("quick_cut: capability probe async start failed ("..plan.kind.."): "..tostring(start_err))
            finish()
        end
    end
end

-- 判断某个 value_requires 声明是否被当前 ffmpeg 满足；能力未探测到时返回 false。
function M.value_available(req, caps)
    caps = caps or environment.caps
    if not caps or type(req) ~= "table" then return false end
    if req.encoder and not caps.encoders[req.encoder] then return false end
    if req.muxer and not caps.muxers[req.muxer] then return false end
    return true
end

-- 两遍编码第一遍的输出目标（丢弃）
local NULL_OUT = (package.config:sub(1,1) == "\\") and "NUL" or "/dev/null"

-- 限体积：由目标体积（MiB）与总时长推导视频/音频码率（kbps）。
-- 目标体积按**上限**处理（宁可略小也不能超）：除 2% 比例余量外，再预留 0.5 MiB 等量的固定开销
-- —— 实测超发近乎固定（10MB→+0.4MB、50MB→+0.5MB），只有固定项才能同时压住大/小目标。
-- 音频取预算的 10%（钳制 32-320k）；预算推不出有效视频码率时返回 nil。
function M.size_bitrates(target_mb, total_duration)
    local mb = tonumber(target_mb) or 0
    local dur = tonumber(total_duration) or 0
    if mb <= 0 or dur <= 0 then return nil end
    local total_kbps = mb * 8388.608 / dur  -- MiB → kbit/s（8×1024×1024/1000）
    local budget_kbps = total_kbps - (total_kbps * 0.02 + 4194 / dur)   -- 2% + 0.5 MiB（4194 kbit）
    if budget_kbps <= 0 then return nil end
    local audio_kbps = math.floor(math.min(320, math.max(32, budget_kbps * 0.1)))
    local video_kbps = math.floor(budget_kbps - audio_kbps)
    if video_kbps < 1 then return nil end
    return video_kbps, audio_kbps
end

local function check_ffmpeg(callback)
    if environment.checked then callback(environment.ffmpeg); return end
    -- 启动失败（进程创建失败等瞬时原因）不永久缓存否定结论，否则一次失败令本会话
    -- 导出永久不可用；但加 5 秒节流，避免失败后每次交互都重新发起探测
    local now = mp.get_time()
    if environment.check_failed_at and now - environment.check_failed_at < 5 then
        callback(false); return
    end
    local ok_start, start_err = mp.command_native_async({name="subprocess", playback_only=false, capture_stdout=true, capture_stderr=true, args={opts.ffmpeg,"-version"}}, function(success, res)
        environment.checked = true
        environment.ffmpeg = success and res and res.status == 0
        -- 版本号只出现在 stdout（原来只抓 stderr ⇒ 从来没读到过）。git/nightly 构建报的是
        -- "N-xxxxx" 而非数字版本，解析不到就保持 nil：调用方按"新版"处理，绝不因解析失败退化功能。
        local maj, min = tostring(environment.ffmpeg and res and res.stdout or ""):match("ffmpeg version n?(%d+)%.(%d+)")
        if maj then environment.ffmpeg_ver = {tonumber(maj), tonumber(min)} end
        callback(environment.ffmpeg)
    end)
    -- 异步启动失败时回调不会触发：必须在这里兜底，否则导出入口永久无响应
    if not ok_start then
        environment.check_failed_at = now
        msg.warn("quick_cut: ffmpeg probe async start failed: " .. tostring(start_err))
        callback(false)
    end
end

-- 需要 ffmpeg 最低版本的参数用它判定（目前只有 -fps_mode）。版本未知 ⇒ true：
-- 宁可沿用新写法（当前行为），也不能因为解析失败把老用户的导出悄悄改坏。
local function ffmpeg_at_least(major, minor)
    local v = environment.ffmpeg_ver
    if not v then return true end
    return v[1] > major or (v[1] == major and v[2] >= minor)
end

-- mpv 兜底后端：没装 ffmpeg 时用 mpv 自己的编码模式（--o=）顶上。
-- mpv 编译时静态链了 libavcodec/libavformat，编码模式不需要 ffmpeg.exe。
-- 但它没有 copy 编码器（codec 'copy' not found）、没有 -pass、没有 concat、没有
-- 字幕轨导出，所以只能兜"全部重新编码"这一条路：其余能力必须在入口处明确拒绝，
-- 而不是让用户拿到一个静默失败或半成品。
local MPV_ENCODERS = {
    video = {
        mp4 = "libx264", mkv = "libx264", mov = "libx264", ts = "libx264",
        webm = "libvpx-vp9", gif = "gif", apng = "apng", webp_anim = "libwebp_anim",
    },
    audio = {
        m4a = "aac", mp3 = "libmp3lame", flac = "flac", wav = "pcm_s16le",
        opus = "libopus", ogg = "libvorbis",
        -- 视频容器内嵌音轨时用同一张表（mp4/mkv/mov/ts 装 aac，webm 只能装 opus）
        mp4 = "aac", mkv = "aac", mov = "aac", ts = "aac", webm = "libopus",
    },
    image = { png = "png", jpg = "mjpeg", jpeg = "mjpeg", webp = "libwebp" },
}

local function mpv_encoder(key, container)
    local table_ = MPV_ENCODERS[key]
    if not table_ then return nil end
    return table_[tostring(container or ""):lower():gsub("^%.", "")]
end

-- mpv 二进制位置：mpv 不暴露自身可执行文件路径（--list-properties 里没有 exe 类属性，
-- expand-path 也不解析相对路径），只能按安装布局推。真实布局只有两种：
--   <mpv.exe 目录>\scripts\quick_cut\            ← 直接放 scripts/（.conf 在 script-opts/）
--   <mpv.exe 目录>\portable_config\scripts\quick_cut\  ← 便携版（scripts/ 在 portable_config 下）
-- 两者都让 module_dir 向上 2~3 级落在 mpv.exe 所在目录，所以把 module_dir 的每一级祖先
-- 都当候选目录找 mpv / mpv.exe 即可（U.resolve_executable 会补 .exe 后缀）。
-- 找不到就返回 nil：调用方退回"未找到 ffmpeg"的原提示，不猜硬编码路径。
local function resolve_mpv_binary()
    local dirs, dir = {}, (_G.QUICK_CUT_BOOTSTRAP and _G.QUICK_CUT_BOOTSTRAP.module_dir) or ""
    for _ = 1, 4 do
        if not dir or dir == "" then break end
        dirs[#dirs + 1] = dir
        dir = dir:gsub("[/\\]+$", ""):match("^(.-)[/\\][^/\\]+$")
    end
    local found = U.resolve_executable("mpv", dirs)
    if found then return found end
    return nil
end

-- ============================================================================
-- 分析任务：导出前置的异步探测
-- 需要"先看一眼源"才能定参数的功能都挂在这里（去隔行 / 自动去黑边 / 音量归一化）。
-- 约定：
--   · 结果按「源路径 + 分析器」缓存；false 表示"已探测过、无结果"，避免重复探测；
--   · 每个分析器失败只记警告并降级（返回 nil），绝不阻塞导出；
--   · 新增一个分析 = 写一个 run() 并登记到 ANALYZERS，消费端读 cached_analysis()。
-- 分析耗时用 analysis_sample_seconds 截断（长片只取前 N 秒），避免"为了分析扫一遍全片"。
-- ============================================================================
local analysis_cache = {}

local function cached_analysis(key, source)
    local per_source = analysis_cache[source]
    if not per_source then return nil end
    return per_source[key]
end

local function store_analysis(key, source, value)
    local per_source = analysis_cache[source]
    if not per_source then per_source = {}; analysis_cache[source] = per_source end
    per_source[key] = value
end

-- 当前源路径：分析结果按源缓存，消费端（滤镜/音频参数）要拿它查缓存
local function current_source()
    return mp.get_property("path")
end

-- 通用异步子进程：回调统一成 (ok, stdout, stderr)
local function run_probe(args, want_stdout, callback)
    local ok_start, start_err = mp.command_native_async(
        {name="subprocess", playback_only=false, capture_stdout=want_stdout, capture_stderr=true, args=args},
        function(success, res)
            job.async_id = nil
            local ok = (success and res and res.status == 0) and true or false
            callback(ok, (res and res.stdout) or "", (res and res.stderr) or "")
        end)
    -- 异步启动失败时回调不会触发：必须兜底，否则前置步骤永久卡住
    if not ok_start then
        job.async_id = nil
        callback(false, "", tostring(start_err))
    end
    job.async_id = ok_start
end

local function source_duration()
    local ok, value = pcall(mp.get_property_number, "duration")
    if not ok then
        -- 失败返回 0 → sample_seconds 会走"按上限扫描"分支（分析耗时异常），
        -- 却完全没有解释。至少留一条日志。
        msg.warn("quick_cut: cannot read duration, sampling falls back to cap: " .. tostring(value))
        return 0
    end
    return tonumber(value) or 0
end

-- 采样秒数：0 = 不截断；长片按 analysis_sample_seconds 截断
local function sample_seconds(settings, total)
    local cap = tonumber((settings or opts).analysis_sample_seconds) or 0
    if cap <= 0 then return total end
    if total <= 0 then return cap end
    return math.min(cap, total)
end

-- 去隔行：ffprobe 读 field_order（纯元数据，几乎零成本）
local function analyze_field_order(source, settings, done)
    run_probe({settings.ffprobe,"-v","error","-select_streams","v:0","-show_entries","stream=field_order",
        "-of","csv=p=0",source}, true, function(ok, stdout)
        if not ok then return done(nil) end
        local order = (tostring(stdout):match("([%a]+)") or ""):lower()
        -- tt/bb/tb/bt 表示隔行；progressive / unknown 一律不处理
        done(order == "tt" or order == "bb" or order == "tb" or order == "bt")
    end)
end

-- 自动去黑边：片头采样 cropdetect，取出现次数最多的矩形
-- （比"取最后一帧"抗渐入渐出/单帧杂讯；round=2 保证宽高为偶数，避免 yuv420p 报错）
local function analyze_crop_black(source, settings, done)
    local seconds = sample_seconds(settings, source_duration())
    local args = {settings.ffmpeg,"-hide_banner","-nostats"}
    if seconds > 0 then table.insert(args,"-t"); table.insert(args,string.format("%.3f", seconds)) end
    for _, opt in ipairs({"-i",source,"-map","0:v:0","-vf","cropdetect=limit=24:round=2:reset=0","-f","null","-"}) do
        table.insert(args, opt)
    end
    run_probe(args, false, function(ok, _, stderr)
        if not ok then return done(nil) end
        local counts, best, best_count = {}, nil, 0
        for line in tostring(stderr):gmatch("[^\r\n]+") do
            local w, h, x, y = line:match("crop=(%d+):(%d+):(%d+):(%d+)")
            if not w then
                local lw, lh = line:match("w:(%d+) h:(%d+)")
                local lx, ly = line:match("x:(%d+) y:(%d+)")
                if lw and lh and lx and ly then w, h, x, y = lw, lh, lx, ly end
            end
            if w then
                local key = string.format("%s:%s:%s:%s", w, h, x, y)
                counts[key] = (counts[key] or 0) + 1
                if counts[key] > best_count then
                    best_count = counts[key]
                    best = {w = tonumber(w), h = tonumber(h), x = tonumber(x), y = tonumber(y)}
                end
            end
        end
        if best then
            -- 满幅结果说明本来就没有黑边（cropdetect 在无黑边时会给出等于源尺寸的矩形）
            local sw = tonumber((mp.get_property_number("video-params/w", 0))) or 0
            local sh = tonumber((mp.get_property_number("video-params/h", 0))) or 0
            if sw > 0 and sh > 0 and best.w >= sw and best.h >= sh then best = nil end
            if best and (best.w < 16 or best.h < 16) then best = nil end
        end
        done(best)
    end)
end

-- 音量归一化第一遍：loudnorm + print_format=json 测量源响度/真峰值/范围/阈值/偏移
local function analyze_loudness(source, settings, done)
    local i = tostring(settings.loudness_target_i or -16)
    local tp = tostring(settings.loudness_target_tp or -1.5)
    local lra = tostring(settings.loudness_target_lra or 11)
    local seconds = sample_seconds(settings, source_duration())
    local args = {settings.ffmpeg,"-hide_banner","-nostats"}
    if seconds > 0 then table.insert(args,"-t"); table.insert(args,string.format("%.3f", seconds)) end
    local filter = string.format("loudnorm=I=%s:TP=%s:LRA=%s:print_format=json", i, tp, lra)
    for _, opt in ipairs({"-i",source,"-map","0:a:0","-af",filter,"-f","null","-"}) do
        table.insert(args, opt)
    end
    run_probe(args, false, function(ok, _, stderr)
        if not ok then return done(nil) end
        local json = tostring(stderr):match("({[^{}]*})")
        if not json then return done(nil) end
        local data = utils.parse_json(json)
        if type(data) ~= "table" then return done(nil) end
        -- 静音轨会给出 "-inf"：tonumber 得到 nil，此时无法归一化，视为本次无结果
        local measured = {
            i = tonumber(data.input_i), tp = tonumber(data.input_tp), lra = tonumber(data.input_lra),
            thresh = tonumber(data.input_thresh), offset = tonumber(data.target_offset) or 0,
        }
        if not (measured.i and measured.tp and measured.lra and measured.thresh) then return done(nil) end
        done(measured)
    end)
end

-- 关键帧位置表（智能切割要"入点之后的下一个关键帧"）：全片 demux 扫描，结果按源缓存
local function analyze_keyframes(source, settings, done)
    run_probe({settings.ffprobe,"-v","error","-select_streams","v:0","-skip_frame","nokey",
        "-show_entries","frame=pts_time","-of","csv=p=0",source}, true, function(ok, stdout)
        if not ok then return done(nil) end
        local times = {}
        for value in tostring(stdout):gmatch("[%d%.]+") do
            local t = tonumber(value)
            if t then times[#times + 1] = t end
        end
        table.sort(times)
        if #times == 0 then return done(nil) end
        done(times)
    end)
end

-- 源流参数（智能切割的重编码必须与源一致：视频的编码器/像素格式/档次，音频的编码器）
local function analyze_source_streams(source, settings, done)
    run_probe({settings.ffprobe,"-v","error","-show_entries",
        "stream=codec_type,codec_name,pix_fmt,profile,width,height,bit_rate,channels,sample_rate",
        "-of","json",source}, true, function(ok, stdout)
        if not ok then return done(nil) end
        local data = utils.parse_json(stdout)
        if type(data) ~= "table" or type(data.streams) ~= "table" then return done(nil) end
        local video, audio
        for _, s in ipairs(data.streams) do
            if s.codec_type == "video" and not video then video = s
            elseif s.codec_type == "audio" and not audio then audio = s end
        end
        if not (video and video.codec_name) then return done(nil) end
        done({
            codec = tostring(video.codec_name):lower(),
            pix_fmt = tostring(video.pix_fmt or ""):lower(),
            profile = video.profile,
            width = tonumber(video.width) or 0, height = tonumber(video.height) or 0,
            audio_codec = audio and tostring(audio.codec_name or ""):lower() or nil,
            audio_bitrate = audio and tonumber(audio.bit_rate) or nil,
            audio_channels = audio and tonumber(audio.channels) or nil,
            audio_sample_rate = audio and tonumber(audio.sample_rate) or nil,
        })
    end)
end

-- 去除静音段：silencedetect 把静音区间打到 stderr（silence_start / silence_end）。
-- 只解码音频，比视频分析便宜得多。这是唯一**不按 analysis_sample_seconds 截断**的分析——
-- 静音图必须覆盖用户标记的范围，截断会让后面的片段"看起来全是正常声音"，静音一个都去不掉。
-- 解析 silencedetect 的 stderr → 静音区间表。纯函数：ffmpeg 的输出格式是这里唯一的假设，
function M.parse_silence_stderr(text)
    local ranges, pending = {}, nil
    for line in tostring(text):gmatch("[^\r\n]+") do
        local start = line:match("silence_start:%s*([%-%d%.]+)")
        if start then
            pending = math.max(0, tonumber(start) or 0)
        else
            local stop = line:match("silence_end:%s*([%-%d%.]+)")
            if stop and pending then
                local stop_time = tonumber(stop) or 0
                if stop_time > pending then ranges[#ranges + 1] = {start = pending, stop = stop_time} end
                pending = nil
            end
        end
    end
    -- 结尾处的静音只有 silence_start（一直静到文件结束）：用 math.huge 表示，
    -- 消费端会把它裁剪到片段边界，所以这里不需要知道总时长。
    if pending then ranges[#ranges + 1] = {start = pending, stop = math.huge} end
    table.sort(ranges, function(a, b) return a.start < b.start end)
    return ranges
end

local function analyze_silence(source, settings, done)
    local db = tostring(tonumber(settings.silence_db) or -30)
    local min_len = tostring(tonumber(settings.silence_min) or 0.5)
    local filter = string.format("silencedetect=noise=%sdB:d=%s", db, min_len)
    run_probe({settings.ffmpeg,"-hide_banner","-nostats",
        "-i",source,"-map","0:a:0","-af",filter,"-f","null","-"}, false, function(ok, _, stderr)
        if not ok then return done(nil) end
        done(M.parse_silence_stderr(stderr))
    end)
end

local ANALYZERS = {
    source_streams = {hint = "hint.analyzing_video_stream", label = "param.smart_cut",    run = analyze_source_streams},
    keyframes    = {hint = "hint.analyzing_keyframes",    label = "param.smart_cut",       run = analyze_keyframes},
    field_order  = {hint = "hint.analyzing_field_order",  label = "param.auto_deinterlace", run = analyze_field_order},
    crop_black   = {hint = "hint.analyzing_crop_black",   label = "param.auto_crop_black",  run = analyze_crop_black},
    loudness     = {hint = "hint.analyzing_loudness",     label = "param.normalize_audio",  run = analyze_loudness},
    silence      = {hint = "hint.analyzing_silence",      label = "param.remove_silence",   run = analyze_silence},
}
local ANALYSIS_ORDER = {"source_streams", "keyframes", "field_order", "crop_black", "loudness", "silence"}

-- ── 换容器（remux）：能不能把流原样装进另一个容器，取决于**源编码**（流复制不重编码），
--   mkv ：视频 / 音频都任意（万能兜底）
--         很多硬件 / 移动端播放器会忽略或无声 → 这里**判为不可用**（宁可退回重新编码，也不交出"可能没声音"的文件）
--   mov ：只收 h264 / hevc（+mpeg4）+ aac / mp3 / ac3 / eac3；opus / flac / vp9 / av1 直接封装失败
--   ts  ：收 h264 / hevc / av1 / vp9 + aac / mp3 / ac3 / eac3；**flac 会被封装成私有流**、
--         播放器读不出音轨（ffprobe 里看不到 a:0）→ 同样判为不可用
--   webm：只收 vp8 / vp9 / av1 + vorbis / opus
-- true 表示"任意都收"。
local CONTAINER_VIDEO_OK = {
    mkv = true, ts = true,
    mp4 = {h264 = true, hevc = true, mpeg4 = true, av1 = true, vp9 = true, vp8 = true},
    mov = {h264 = true, hevc = true, mpeg4 = true},
    webm = {vp8 = true, vp9 = true, av1 = true},
}
local CONTAINER_AUDIO_OK = {
    mkv = true,
    mp4 = {aac = true, mp3 = true, ac3 = true, eac3 = true},   -- 不含 opus / flac，见上
    ts = {aac = true, mp3 = true, ac3 = true, eac3 = true},    -- 不含 flac，见上
    mov = {aac = true, mp3 = true, ac3 = true, eac3 = true},
    webm = {opus = true, vorbis = true},
}
local CONTAINER_MUX_EXT = {mp4 = ".mp4", mkv = ".mkv", mov = ".mov", webm = ".webm", ts = ".ts"}
-- 用户设置里的音频编码取值 → **容器/ffprobe 层面认的编码名**。
-- 一份表两用：① 重编码时查容器收不收；② 智能切割判断"源编码与设置是否同一编码"（见下）。
-- 新增音频编码只改这一处。
local SETTING_AUDIO_CODEC = {aac = "aac", libmp3lame = "mp3", libopus = "opus", flac = "flac"}

local function table_accepts(t, codec)
    if t == true then return true end
    if type(t) ~= "table" then return false end
    return t[codec] == true
end

-- 源的这两路编码能否原样装进目标容器。返回 (ok, 细节点串)；细节用于日志与提示。
function M.container_copy_ok(vcodec, acodec, container)
    container = tostring(container or ""):lower():gsub("^%.", "")
    local vok, aok = CONTAINER_VIDEO_OK[container], CONTAINER_AUDIO_OK[container]
    if vok == nil and aok == nil then return false, tostring(container) .. " (未知容器)" end
    vcodec, acodec = tostring(vcodec or ""):lower(), tostring(acodec or ""):lower()
    if vcodec ~= "" and not table_accepts(vok, vcodec) then return false, vcodec .. " → " .. container end
    if acodec ~= "" and not table_accepts(aok, acodec) then return false, acodec .. " → " .. container end
    return true, nil
end

-- 源路径的容器（按扩展名判断；源容器与目标相同就不需要换，沿用源扩展名即可）
local function source_container_of(source)
    local _, filename = utils.split_path(tostring(source or ""))
    local ext = tostring(filename or ""):match("%.([%w]+)$")
    return tostring(ext or ""):lower()
end

-- 快速复制下"换容器"的决策：
--   返回 (ext, nil)  → 可以流复制进目标容器，用这个扩展名（含点）
--   返回 (nil, nil)  → 目标容器与源相同（或没设置），调用方沿用源扩展名
--   返回 (nil, 细节) → 装不进去（或源编码未知）：调用方**退回重新编码**并说明原因
local function fast_remux_ext(source, settings)
    local want = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
    if want == "" or CONTAINER_MUX_EXT[want] == nil then return nil, nil end
    if want == source_container_of(source) then return nil, nil end
    local stream = cached_analysis("source_streams", source)
    if type(stream) ~= "table" then return nil, "源编码未知（前置分析未跑到）" end
    -- 快速复制下音频也可能被重编码（音量归一化）：那时按设置里的编码查表，而不是源编码
    local acodec = tostring(stream.audio_codec or "")
    if tostring(settings.audio_codec or ""):lower() == "none" then
        acodec = ""    -- 不输出音频 ⇒ 容器对音频编码的限制不适用（否则 webm + none 会被误判装不下）
    elseif settings.normalize_audio == true then
        local set_codec = SETTING_AUDIO_CODEC[tostring(settings.audio_codec or ""):lower()]
        if set_codec then acodec = set_codec end
    end
    local ok, detail = M.container_copy_ok(stream.codec, acodec, want)
    if not ok then return nil, detail end
    return CONTAINER_MUX_EXT[want], nil
end

local function analysis_enabled(key, settings)
    settings = settings or opts
    -- 智能切割需要"源参数 + 关键帧位置"这两项
    if key == "keyframes" then return settings.smart_cut == true end
    -- 源流参数：智能切割要用，换容器（快速复制下的 remux）也要用它判断"装不装得进去"
    if key == "source_streams" then
        if settings.smart_cut == true then return true end
        local want = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
        return want ~= "" and want ~= source_container_of(current_source())
    end
    if key == "field_order" then return settings.auto_deinterlace == true end
    if key == "crop_black" then return settings.auto_crop_black == true end
    if key == "loudness" then return settings.normalize_audio == true end
    if key == "silence" then return settings.remove_silence == true end
    return false
end

-- 日志里把结果描述成稳定字符串（table 按键排序，便于比对）
local function describe_result(result)
    if result == nil then return "nil" end
    if type(result) ~= "table" then return tostring(result) end
    -- 关键帧位置表可能有几千项：日志里只记数量与首尾，避免把日志刷爆
    if #result > 8 then
        return string.format("%d items, first=%s, last=%s", #result, tostring(result[1]), tostring(result[#result]))
    end
    local parts = {}
    for k, v in pairs(result) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- 依序跑完所有启用且未缓存的分析，然后回调（失败降级，永不阻塞）
local function run_pending_analyses(source, callback)
    local pending = {}
    for _, key in ipairs(ANALYSIS_ORDER) do
        if analysis_enabled(key) and cached_analysis(key, source) == nil then pending[#pending + 1] = key end
    end
    local index = 0
    local function step()
        index = index + 1
        local key = pending[index]
        if not key then callback(); return end
        local analyzer = ANALYZERS[key]
        show_hint(L(analyzer.hint), 3)
        analyzer.run(source, opts, function(result)
            if result == nil then
                show_hint(L("hint.analysis_failed", L(analyzer.label)), 4, "error")
                store_analysis(key, source, false)
            else
                store_analysis(key, source, result)
            end
            msg.info(string.format("quick_cut analysis %s: %s", key, describe_result(result)))
            step()
        end)
    end
    step()
end

-- ============================================================================
-- 智能无损切割（Smart cut）的落点判定
-- 快速复制的入点会被吸附到前一个关键帧（最多多出一个 GOP 的内容）；开启后改为：
--   [入点, 下一个关键帧] 用与源一致的编码参数重编码（短），[下一个关键帧, 出点] 流复制，
--   两段 concat 缝合（-c copy，不二次编码）。于是入点精确、无损范围不再受关键帧约束。
-- 匹配重编码是硬要求：编码器/像素格式与源不一致会让缝合后的流解不出来。
-- 任何前提不满足都返回 nil（调用方退回常规方式），绝不硬着头皮试。
-- ============================================================================
-- 只支持 h264：HEVC 的「重编码头 + 复制尾」拼不出可解码的文件。
-- 源本身 1500 帧 0 错误，但两者 concat -c copy 后只读出 23 帧、827 行解码错误
-- （offset_len / chroma_log2_weight_denom / Could not find ref with POC = 按第一片参数集解析第二片）。
-- mp4 与 mkv 结果一致（827 / 828 行），所以不是容器问题，也无法靠换容器绕过。
local HEAD_ENCODERS = {h264 = "libx264"}
local HEAD_PIX_FMTS = {yuv420p = "yuv420p", yuvj420p = "yuv420p", yuv422p = "yuv422p", yuv444p = "yuv444p"}
-- 头部音频也要重编码，因此源的音频编码必须能再编出来
local HEAD_AUDIO_ENCODERS = {aac = "aac", mp3 = "libmp3lame", opus = "libopus",
                             flac = "flac", ac3 = "ac3", eac3 = "eac3"}
local HEAD_AUDIO_LOSSLESS = {flac = true}
-- 用户设置 audio_codec 的取值 → 实际编码器名，用于与 HEAD_AUDIO_ENCODERS 的输出比较：
-- 设置里写的是 libmp3lame / libopus，源编码名是 mp3 / opus，直接比字符串会误判
-- （不能用 gsub("^lib","") 粗暴归一：libmp3lame → mp3lame ≠ mp3，mp3 源会被误判为不匹配）
-- 流复制只要求**编码相同**，与用了哪个编码器无关 → 直接复用上面那份映射。
local AUDIO_SETTING_ENCODERS = SETTING_AUDIO_CODEC
-- ffprobe 的 profile 写法带空格（"Constrained Baseline"、"High 10"），查表前统一去掉空格
local HEAD_PROFILES = {
    constrainedbaseline = "baseline", baseline = "baseline", main = "main",
    high = "high", high10 = "high10", high422 = "high422", high444 = "high444",
}

-- 返回 (plan, reason)：plan 为 nil 时 reason 是 i18n 键，"off"/"aligned" 表示无需提示
local function smart_cut_segment_plan(source, seg, settings, tracks)
    settings = settings or opts
    if settings.smart_cut ~= true then return nil, "off" end
    -- 智能切割只对视频有效：它的做法是"头部重编码 + 尾部流复制再 concat"，产出的是
    -- 视频片段。图片/动图/音频导出若也走这条路，中间文件会改变关键帧结构——
    -- 图片的关键帧模式会从 5 张变成 253 张（整段被重写成关键帧密集的视频），
    -- 动图/音频则是白跑一遍 concat。这里直接按导出类型挡掉（只在 UI 里提示
    -- hint.smart_cut_video_only 并不够，提示与实际行为会不符）。
    local kind = tostring(settings.output_kind or "video"):lower()
    if kind ~= "video" then return nil, "smart.reason_non_video" end
    local stream = cached_analysis("source_streams", source)
    if type(stream) ~= "table" then return nil, "smart.reason_no_codec" end
    if tostring(stream.codec or ""):lower() == "hevc" then return nil, "smart.reason_hevc" end
    local encoder = HEAD_ENCODERS[tostring(stream.codec or ""):lower()]
    if not encoder then return nil, "smart.reason_no_codec" end
    local pix_fmt = HEAD_PIX_FMTS[tostring(stream.pix_fmt or ""):lower()]
    if not pix_fmt then return nil, "smart.reason_pix_fmt" end
    -- 头部按源的像素格式重编码，尾部是原样复制：用户若指定了别的格式，智能切割给不出这个格式
    -- （尾部改不了），宁可退回常规重编码也不静默忽略设置。
    -- "auto" / 空 = 保持源格式（重新编码里 auto 同样不注入 -pix_fmt），此时与尾部一致，不算冲突。
    local wanted_pix_fmt = tostring(settings.pixel_format or ""):lower()
    if wanted_pix_fmt ~= "" and wanted_pix_fmt ~= "auto" and wanted_pix_fmt ~= pix_fmt then
        return nil, "smart.reason_pix_fmt"
    end
    -- 头部音频必须重编码，且必须用**源的音频编码**才能与
    -- 原样复制的尾部缝在同一个文件里。查表而不是写死 aac：源是 opus/flac 时编成 aac 会拼不起来。
    local audio_encoder
    -- 「无音频」时头部不需要音频编码器，也不该让音频检查否决智能切割
    if (tracks == nil or tracks.audio ~= nil) and tostring(settings.audio_codec or ""):lower() ~= "none" then
        local source_audio = tostring(stream.audio_codec or ""):lower()
        audio_encoder = HEAD_AUDIO_ENCODERS[source_audio]
        if not audio_encoder then return nil, "smart.reason_audio_codec" end
        -- 用户指定了别的音频编码时头部满足不了，硬做等于静默忽略这个设置。
        -- 用"编码器名"比较而不是编码名字符串。
        local wanted_audio = tostring(settings.audio_codec or "copy"):lower()
        if wanted_audio ~= "copy" then
            if AUDIO_SETTING_ENCODERS[wanted_audio] ~= audio_encoder then
                return nil, "smart.reason_audio_mismatch"
            end
        end
    end
    local times = cached_analysis("keyframes", source)
    if type(times) ~= "table" or #times == 0 then return nil, "smart.reason_no_keyframes" end
    -- 入点之后（含）的第一个关键帧：关键帧表可能几千项，用二分
    local lo, hi, next_kf = 1, #times, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if times[mid] >= seg.start_time - 0.001 then next_kf = times[mid]; hi = mid - 1 else lo = mid + 1 end
    end
    if not next_kf or next_kf >= seg.end_time - 0.001 then
        -- 整段落在同一个 GOP 里：没有可复制的尾部，智能切割没有意义。
        -- 注意这不是"入点到关键帧太远"（那是下面 :608 的分支）：这里曾复用
        -- smart.reason_head_too_long，提示语对不上真实原因，用户看到"超过上限"
        -- 却不知道其实是"整段没跨关键帧 ⇒ 快速复制会整体错位"。
        return nil, "smart.reason_single_gop"
    end
    if next_kf - seg.start_time < 0.02 then return nil, "aligned" end   -- 入点本来就贴关键帧：纯复制即可
    if next_kf - seg.start_time > (tonumber(settings.smart_cut_max_head) or 15) then
        return nil, "smart.reason_head_too_long"
    end
    return {head_start = seg.start_time, head_end = next_kf, tail_end = seg.end_time,
            encoder = encoder, pix_fmt = pix_fmt,
            profile = HEAD_PROFILES[(tostring(stream.profile or ""):lower():gsub("%s+", ""))],
            audio_encoder = audio_encoder,
            audio_lossless = audio_encoder and HEAD_AUDIO_LOSSLESS[audio_encoder] or false,
            audio_bitrate = stream.audio_bitrate}
end

-- 合并导出里的智能切割：整个队列一次性判定，**全有或全无**。
-- 为什么不能逐段各自决定：合并后的文件要求所有分片编码参数一致，而头部重编码固定用
-- 源的编码器 / 像素格式 / 档次 + crf18；只要有一段退回"用户参数重编码"，两种分片就缝不到一起。
-- 返回 (plans, reason_key, index)：plans 与 queue 一一对应；失败时 reason_key 是 i18n 键，
-- index 指明是第几段（"off" 表示开关没开，调用方不必提示）。
local function smart_cut_merge_plans(source, queue, settings, tracks)
    if settings.smart_cut ~= true then return nil, "off" end
    local plans = {}
    for i, seg in ipairs(queue) do
        local plan, reason = smart_cut_segment_plan(source, seg, settings, tracks)
        if not plan then return nil, reason or "smart.reason_no_keyframes", i end
        plans[i] = plan
    end
    return plans, nil
end

-- 合并 + 智能切割的前置否决：尾部是原样流复制，任何"整段加工"它都吃不到，只能整段重编码。
-- 返回 i18n 键或 nil。
local function smart_cut_merge_blocker(settings)
    if (settings.output_kind or "video") ~= "video" then return "hint.smart_cut_video_only" end
    if Crop.crop_is_active(settings) then return "hint.smart_cut_merge_crop" end
    if (tonumber(settings.video_width) or 0) > 0 or (tonumber(settings.video_height) or 0) > 0
        or (tonumber(settings.output_fps) or 0) > 0 then return "hint.smart_cut_merge_transform" end
    if settings.auto_deinterlace == true or settings.auto_crop_black == true then
        return "hint.smart_cut_merge_auto"
    end
    if settings.normalize_audio == true then return "hint.smart_cut_merge_loudness" end
    -- 码率模式（含"限定体积"）：尾部照抄源码率，给不出目标码率，整份文件的体积目标必然落空
    if tostring(settings.video_quality_mode or "") == "bitrate" then return "hint.smart_cut_merge_bitrate" end
    return nil
end

-- ============================================================================
-- 关键帧跳采（keyframes 模式的"每 N 个取一张"与"张数上限"）
-- 步长本身纯靠滤镜实现（select 按解码器吐出的帧序号计数，零额外开销）；
-- 但"张数上限"必须先知道总关键帧数才能算步长，而数关键帧要完整扫描一遍（demux 全片），
-- 同步做会冻住界面，因此作为导出前置异步执行，结果按源文件路径缓存（同一文件只数一次）。
-- ============================================================================
local kf_total_cache = {}

local function count_keyframes_async(path, callback)
    if kf_total_cache[path] ~= nil then callback(kf_total_cache[path]); return end
    local args = {opts.ffprobe,"-v","error","-select_streams","v:0","-skip_frame","nokey",
        "-show_entries","frame=pts_time","-of","csv=p=0",path}
    local ok_start, start_err = mp.command_native_async(
        {name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,args=args},
        function(success, res)
            job.async_id = nil
            local total = 0
            if success and res and res.status == 0 and res.stdout then
                for _ in res.stdout:gmatch("[^\r\n]+") do total = total + 1 end
            else
                msg.warn("quick_cut: keyframe count failed; keyframe_limit ignored for this export: "
                    .. tostring((res and res.stderr) or "unknown"))
            end
            kf_total_cache[path] = total
            msg.info(string.format("quick_cut keyframe count: %d keyframe(s)", total))
            callback(total)
        end)
    -- 异步启动失败时回调不会触发：必须兜底，否则导出入口永久无响应
    if not ok_start then
        job.async_id = nil
        msg.warn("quick_cut: keyframe count async start failed: " .. tostring(start_err))
        callback(0)
    end
    job.async_id = ok_start
end

-- 导出前置：先跑启用的分析任务（去隔行/去黑边/音量），再按需数关键帧，最后进 check_ffmpeg。
-- 每一步都失败降级，绝不会把导出卡住；未启用任何前置时几乎零开销。
local function check_ffmpeg_prepared(path, kind, callback)
    local function after_analyses()
        local mode = tostring(opts.image_mode or ""):lower()
        local limit = math.floor(tonumber(opts.keyframe_limit) or 0)
        if kind ~= "image" or mode ~= "keyframes" or limit <= 0 or kf_total_cache[path] ~= nil then
            return check_ffmpeg(callback)
        end
        show_hint(L("hint.counting_keyframes"), 3)
        count_keyframes_async(path, function() check_ffmpeg(callback) end)
    end
    run_pending_analyses(path, after_analyses)
end

-- 实际跳采步长 = max(用户步长, 由张数上限推得的步长)。
-- 上限值只有 count_keyframes_async 数过之后才可用（缓存命中）；没有总数时忽略上限。
-- 定义位置必须在 encode_summary 之前：摘要行要用它显示生效步长。
local function image_keyframe_stride(path, settings)
    settings = settings or opts
    local stride = math.max(1, math.floor(tonumber(settings.keyframe_stride) or 1))
    local limit = math.floor(tonumber(settings.keyframe_limit) or 0)
    if limit <= 0 or not path then return stride end
    local total = kf_total_cache[path]
    if total and total > limit then
        local need = math.ceil(total / limit)
        if need > stride then stride = need end
    end
    return stride
end

local function stop_progress_monitor(cleanup)
    if job.progress_timer then job.progress_timer:kill(); job.progress_timer=nil end
    local path=job.progress_file
    job.progress_file,job.progress,job.speed,job.segment_length=nil,0,"",0; job.progress_open_warned=nil
    if cleanup and path then U.remove_file_later(path,1) end
end

local function last_capture(raw,pattern)
    local last=nil; for value in raw:gmatch(pattern) do last=value end; return last
end

local function read_progress_file()
    if not job.progress_file then return end
    local f = io.open(job.progress_file, "rb")
    if not f then
        -- Windows 下进度文件被独占很常见。这个函数每 0.25s 跑一次，只提示一次即可。
        if not job.progress_open_warned then
            job.progress_open_warned = true
            msg.warn("quick_cut: cannot open progress file: " .. tostring(job.progress_file))
        end
        return
    end
    local size = f:seek("end")
    if not size then
        msg.warn("quick_cut: progress file seek failed: " .. tostring(job.progress_file))
        f:close()
        return
    end
    if not f:seek("set", math.max(0, size - 65536)) then
        f:seek("set", 0)   -- 退化从头读：丢弃的只是精确位置，绝不按错误位置算进度
        msg.warn("quick_cut: progress file rewind failed, reading from start")
    end
    local raw = f:read("*a") or ""
    f:close()
    -- 下方 ms/1000000 是正确换算；不要按字面改成 /1000，否则进度会放大 1000 倍。
    local us=tonumber(last_capture(raw,"out_time_us=(%d+)")); local ms=tonumber(last_capture(raw,"out_time_ms=(%d+)"))
    local seconds=us and us/1000000 or (ms and ms/1000000 or nil)
    if seconds then
        job.progress_samples=job.progress_samples+1
        if job.segment_length>0 then job.progress=math.max(0,math.min(1,seconds/job.segment_length)) end
        if job.total_duration>0 then job.overall_progress=math.max(0,math.min(1,(job.completed_duration+math.min(seconds,job.segment_length))/job.total_duration)) end
    end
    job.speed=last_capture(raw,"speed=([^%s]+)") or job.speed or ""; request_render(true)
end

local function start_progress_monitor(temp_output,length)
    stop_progress_monitor(false); job.progress_samples=0
    if not opts.show_export_progress then return nil end
    job.progress_file=temp_output..".progress"; job.segment_length=math.max(0.001,tonumber(length) or 0.001)
    job.progress_timer=mp.add_periodic_timer(opts.progress_interval,read_progress_file); return job.progress_file
end

local function add_progress_args(args,progress_file)
    if not progress_file then return end
    local output=table.remove(args)
    table.insert(args,"-nostats"); table.insert(args,"-progress"); table.insert(args,progress_file); table.insert(args,output)
end

local function cleanup_job_files()
    for _,path in ipairs(job.work_files or {}) do U.remove_file_later(path,1) end
    if job.concat_list then U.remove_file_later(job.concat_list,1) end
    job.work_files,job.concat_list={},nil
end

local animation_timer=nil
local function ensure_animation_timer()
    if animation_timer then return end
    animation_timer=mp.add_periodic_timer(0.25,function()
        if not job.running then animation_timer:kill(); animation_timer=nil; return end
        job.animation_frame=(job.animation_frame+1)%3; request_render(false)
    end)
end

function M.cancel_export()
    if not job.running and not job.preparing then return end
    -- 准备阶段还没有 ffmpeg 进程可 abort：清掉准备态 + 置 cancel_requested，回调进来会照常收尾
    job.preparing = nil
    job.cancel_requested,job.status=true,"stopping"
    -- stop_progress_monitor 会把 job.progress_file 置空，而取消后 ffmpeg 可能仍在写这个文件、
    -- 此刻删它也是白删（进程会重建）。把路径挪到 job.cancel_progress_file，交给进程退出后的
    job.cancel_progress_file = job.progress_file
    if job.async_id then pcall(mp.abort_async_command,job.async_id) end
    stop_progress_monitor(false); show_hint(L("hint.stopping_export"),2); request_render(true)
end

local function finish_job(title, body, success)
    stop_progress_monitor(true)
    job.cancel_progress_file = nil
    job.running, job.async_id = false, nil
    job.current_output, job.current_temp = nil, nil
    job.source_path,job.status,job.operation=nil,"idle",nil
    job.plan,job.stage,job.current_range,job.failure=nil,nil,nil,nil
    job.progress_samples,job.animation_frame=0,0
    -- 智能切割没生效时（快速复制会退回 -c copy，起点被回退到关键帧、画面整体前移），
    -- 那条 4 秒的 error 提示在导出完成的一瞬间就被"导出完成"覆盖掉了——实测导出一段
    -- 3 秒片段只要 0.07 秒，用户根本来不及看。所以把结论挂到完成通知的正文上，
    -- 让"拿到了错位文件"这件事至少有一处留痕。
    if success and job.smart_skip then
        body = tostring(body or "") .. "\n" .. L("hint.smart_cut_shift_note")
    end
    job.smart_skip = nil
    -- 完成汇总卡（ui 渲染）只在成功路径展示，15 秒后自动消失
    job.finish_ok = success and true or nil
    job.finished_at = success and mp.get_time() or nil
    request_render(true)
    -- tostring 兜底：收尾路径上崩一次就是"任务永远不结束"，不值得为省一次转换冒险
    U.notify(title, tostring(body or ""))
end

-- 当前导出任务的类型名（视频/音频/动图/图片序列），用于通知标题具体到任务。
local function task_kind_label()
    local kind = (job.plan and job.plan.settings and job.plan.settings.output_kind) or state.export_kind or "video"
    local key = "confirm.kind_" .. tostring(kind)
    local label = L(key)
    if label and label ~= key then return label end
    return L("confirm.kind_video")
end

-- 去隔行滤镜名：优先 bwdif，退回 yadif；能力清单里都没有则返回 nil。
-- 注释原本写"调用方跳过并提示"，但唯一的调用方是 `if name then insert end` —— 什么都不说：
-- 用户开了自动去隔行，拿到的是**仍是梳齿**的输出，日志里也没有一行。改在这里收口
-- （i18n 键 hint.deinterlace_unavailable 早就存在，却从未被调用过）。
local function deinterlace_filter()
    local caps = environment.caps
    if caps and caps.filters then
        if caps.filters["bwdif"] then return "bwdif" end
        if caps.filters["yadif"] then return "yadif" end
        msg.warn("quick_cut: auto deinterlace requested but no bwdif/yadif in this ffmpeg")
        show_hint(L("hint.deinterlace_unavailable"), 5, "error")
        return nil
    end
    return "bwdif"   -- 能力清单未就绪（罕见）：现代 ffmpeg 都有 bwdif
end

-- 音量归一化滤镜串（第二遍）：把第一遍测得的参数显式回填，linear=true 让增益是线性而非动态压缩
local function loudnorm_af(settings)
    local measured = cached_analysis("loudness", current_source())
    if type(measured) ~= "table" then return nil end
    return string.format(
        "loudnorm=I=%s:TP=%s:LRA=%s:measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true",
        tostring(settings.loudness_target_i or -16), tostring(settings.loudness_target_tp or -1.5),
        tostring(settings.loudness_target_lra or 11),
        measured.i, measured.tp, measured.lra, measured.thresh, measured.offset or 0)
end

-- 音量归一化前置：copy 无法套滤镜（会直接报错），改成 aac；
-- 返回测得的响度（有则说明本次导出会归一化），供调用方提示"源 x → 目标 y LUFS"
local function apply_audio_normalization(settings)
    if settings.normalize_audio ~= true then return nil end
    local measured = cached_analysis("loudness", current_source())
    if type(measured) ~= "table" then return nil end
    if tostring(settings.audio_codec or "") == "copy" then
        -- 归一化必然要重编码，但目标容器未必收 aac（webm 只认 opus，ogg/opus/mp3/flac 各有各的）：
        -- 无条件写 aac 会产出装不进容器的文件。按容器挑一个合法编码器（表里没有该容器 = 不限制，
        -- 比如 mkv，aac 通吃）。
        settings.audio_codec = config.lossy_audio_for(settings.encode_container)
        show_hint(L("hint.loudness_needs_recoding"), 4)
    end
    return measured
end

-- 重新编码 + audio_codec=copy：源音频若装不进目标容器，就会交出"播放器读不出音轨"的文件
-- 没有源参数分析结果时**不动**（不猜）；用户显式选了具体编码器（如 libopus）也不会被改。
local function coerce_audio_copy_for_container(settings)
    if tostring(settings.audio_codec or "") ~= "copy" then return end
    local container = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
    if container == "" then return end
    local stream = cached_analysis("source_streams", current_source())
    local src_audio = type(stream) == "table" and tostring(stream.audio_codec or "") or ""
    if src_audio == "" then return end
    if M.container_copy_ok(nil, src_audio, container) then return end
    local allow = config.container_audio_codecs(container) or {}
    local pick
    for _, cand in ipairs({"aac", "libopus", "libmp3lame"}) do
        if allow[cand] then pick = cand break end
    end
    if not pick then return end
    settings.audio_codec = pick
    show_hint(L("hint.audio_copy_needs_recoding", src_audio, container, pick), 5)
    msg.info(string.format("quick_cut audio: copy -> %s (source %s cannot go into %s)", pick, src_audio, container))
end
M.coerce_audio_copy_for_container = coerce_audio_copy_for_container

-- 重新编码 + video_codec=copy：源视频编码若装不进目标容器，ffmpeg 会在**写文件头**时直接失败
-- （例如 mp4(H.264) 源 + webm + libopus → "Only VP8 or VP9 or AV1 video ... are supported for WebM"，
--   因为 -c:v copy 把 H.264 往 webm 里塞）。音频侧本来就有这道纠正，视频侧同样需要。
-- 没有源参数分析结果时**不动**（不猜）；用户显式选了具体编码器也不会被改。
local function coerce_video_copy_for_container(settings)
    if tostring(settings.video_codec or "") ~= "copy" then return end
    local container = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
    if container == "" then return end
    local stream = cached_analysis("source_streams", current_source())
    local src_video = type(stream) == "table" and tostring(stream.codec or "") or ""
    if src_video == "" then return end
    if M.container_copy_ok(src_video, nil, container) then return end
    local pick = config.real_video_codec_for(container)
    if not pick then return end
    settings.video_codec = pick
    show_hint(L("hint.video_copy_needs_recoding", src_video, container, pick), 5)
    msg.info(string.format("quick_cut video: copy -> %s (source %s cannot go into %s)", pick, src_video, container))
end
M.coerce_video_copy_for_container = coerce_video_copy_for_container

-- ============================================================================
-- 变速：play_speed ≠ 1 时，视频靠 setpts 缩放时间戳、音频靠 atempo 链保音调。
-- atempo 单级只接受 0.5–2.0，超出范围必须串联多级（4x = atempo=2,atempo=2），
-- 0.25x = atempo=0.5,atempo=0.5。视频侧 setpts 用倒数：倍数 S 的播放速度意味着
-- 时间轴压缩到 1/S，所以写 setpts=PTS/S。
-- 注意顺序：setpts 必须排在 fps 之前，否则帧率会被按"原速时间轴"重采样。
-- ============================================================================
local function speed_factor(settings)
    local s = tonumber((settings or opts).play_speed) or 1
    if s <= 0 then s = 1 end
    return s
end

local function speed_active(settings)
    return math.abs(speed_factor(settings) - 1) > 0.005
end

-- 返回 atempo 滤镜串（单级或串联）；速度为 1 时返回 nil
local function atempo_chain(speed)
    local s = tonumber(speed) or 1
    if math.abs(s - 1) <= 0.005 then return nil end
    local parts = {}
    local left = s
    -- 每级最多吃 2x / 最少吃 0.5x，逐级剥到 1 附近
    while left > 2.0 + 1e-9 do parts[#parts + 1] = "atempo=2"; left = left / 2 end
    while left < 0.5 - 1e-9 do parts[#parts + 1] = "atempo=0.5"; left = left / 0.5 end
    parts[#parts + 1] = string.format("atempo=%.6g", left)
    return table.concat(parts, ",")
end
M.atempo_chain = atempo_chain

local function build_video_filters(settings)
    settings = settings or opts
    local filters = {}
    -- 去隔行必须排在裁剪/缩放之前：先把隔行内容插值成逐行，再缩放才不会有梳齿
    if settings.auto_deinterlace == true and cached_analysis("field_order", current_source()) == true then
        local name = deinterlace_filter()
        if name then table.insert(filters, name) end
    end
    local crop, crop_err = Crop.rect_for(settings)
    if crop_err then return nil, crop_err end
    if crop then
        table.insert(filters, string.format("crop=%d:%d:%d:%d", crop.w, crop.h, crop.x, crop.y))
    elseif settings.auto_crop_black == true then
        -- 手动裁剪优先：自动去黑边只在没有手动裁剪时套用检测结果
        local rect = cached_analysis("crop_black", current_source())
        if type(rect) == "table" then
            table.insert(filters, string.format("crop=%d:%d:%d:%d", rect.w, rect.h, rect.x, rect.y))
        end
    end

    local w, h = settings.video_width, settings.video_height
    if w > 0 or h > 0 then
        if w > 0 and h > 0 then
            if settings.scale_mode == "stretch" then
                table.insert(filters, string.format("scale=%d:%d", U.even_floor(w), U.even_floor(h)))
            elseif settings.scale_mode == "pad" then
                w, h = U.even_floor(w), U.even_floor(h)
                table.insert(filters, string.format("scale=%d:%d:force_original_aspect_ratio=decrease", w, h))
                table.insert(filters, string.format("pad=%d:%d:(ow-iw)/2:(oh-ih)/2", w, h))
            else
                -- fit：等比缩放适配。目标框已偶化，但实际输出仍可能因取整出现奇数宽/高，
                -- 再偶化一次，否则 yuv420p 等格式会报 "not divisible by 2"
                table.insert(filters, string.format("scale=%d:%d:force_original_aspect_ratio=decrease", U.even_floor(w), U.even_floor(h)))
                table.insert(filters, "scale=trunc(iw/2)*2:trunc(ih/2)*2")
            end
        elseif w > 0 then
            table.insert(filters, string.format("scale=%d:-2", U.even_floor(w)))
        else
            table.insert(filters, string.format("scale=-2:%d", U.even_floor(h)))
        end
        table.insert(filters, "setsar=1")
    end
    -- 变速放在 fps 之前：先改时间轴，再按新时间轴重采样帧率
    if speed_active(settings) then
        table.insert(filters, string.format("setpts=%.6f*PTS", 1 / speed_factor(settings)))
    end
    if settings.output_fps > 0 then table.insert(filters, string.format("fps=%.3f", settings.output_fps)) end
    return filters
end

-- 校验 preset 是否对当前编码器合法；不合法则纠正为合法值（优先 medium，否则取中位）。
-- 返回纠正后的 preset 值。用于兜底：预设/编码器联动可能因自定义预设或历史状态残留非法组合。
local function coerce_preset(codec, preset)
    local cur = tostring(preset or "")
    if cur == "" then return preset end  -- 显式留空：不注入 -preset
    local options = config.preset_options(codec)
    if not options or #options == 0 then return preset end
    for _, v in ipairs(options) do if tostring(v) == cur then return preset end end
    local pick = 1
    for i, v in ipairs(options) do if tostring(v) == "medium" then pick = i break end end
    if tostring(options[pick]) ~= "medium" then pick = math.floor(#options / 2) + 1 end
    return options[pick]
end

local function append_video_encode_args(args, settings)
    settings = settings or opts
    table.insert(args,"-c:v"); table.insert(args,settings.video_codec)
    local preset = coerce_preset(settings.video_codec, settings.preset)
    if preset and preset ~= "" then table.insert(args,"-preset"); table.insert(args,preset) end
    if settings.video_quality_mode == "crf" then
        table.insert(args,"-crf"); table.insert(args,tostring(settings.video_quality))
    elseif settings.video_quality_mode == "cq" then
        table.insert(args,"-cq"); table.insert(args,tostring(settings.video_quality))
    elseif settings.video_quality_mode == "global_quality" then
        table.insert(args,"-global_quality"); table.insert(args,tostring(settings.video_quality))
    elseif settings.video_quality_mode == "bitrate" and settings.video_bitrate ~= "" then
        table.insert(args,"-b:v"); table.insert(args,settings.video_bitrate)
    end
    if settings.pixel_format and settings.pixel_format ~= "" and settings.pixel_format ~= "auto" then
        table.insert(args,"-pix_fmt"); table.insert(args,settings.pixel_format)
    end
end

local function append_audio_encode_args(args, settings)
    settings = settings or opts
    table.insert(args,"-c:a"); table.insert(args,settings.audio_codec)
    if settings.audio_bitrate and settings.audio_bitrate ~= "" then table.insert(args,"-b:a"); table.insert(args,settings.audio_bitrate) end
    if settings.audio_sample_rate > 0 then table.insert(args,"-ar"); table.insert(args,tostring(settings.audio_sample_rate)) end
    if settings.audio_channels > 0 then table.insert(args,"-ac"); table.insert(args,tostring(settings.audio_channels)) end
    -- -af 只能出现一次：响度归一化与变速都是音频滤镜，必须串成一条链。
    -- 顺序上 atempo 在后——loudnorm 按原速测得的响度在变速后依然成立，
    -- 反过来（先 atempo 再 loudnorm）会让测量窗口与源不一致。
    local af_parts = {}
    if settings.normalize_audio == true and settings.audio_codec ~= "copy" then
        local af = loudnorm_af(settings)
        if af then af_parts[#af_parts + 1] = af end
    end
    if speed_active(settings) then
        local chain = atempo_chain(speed_factor(settings))
        if chain then
            -- 与视频侧同理：-af 与 -c:a copy 互斥。变速要求音频重编码，
            -- 音频编码选"复制"时换成容器支持的编码器（兜底 aac）。
            if tostring(settings.audio_codec) == "copy" then
                local container = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
                settings.audio_codec = config.lossy_audio_for(container)
                msg.info("quick_cut audio: 'copy' cannot carry filters, using "
                    .. tostring(settings.audio_codec))
                -- 上面已写入 -c:a，这里就地改正
                for i = #args - 1, 1, -1 do
                    if args[i] == "-c:a" then args[i + 1] = settings.audio_codec; break end
                end
            end
            af_parts[#af_parts + 1] = chain
        end
    end
    if #af_parts > 0 then table.insert(args,"-af"); table.insert(args,table.concat(af_parts,",")) end
end

-- 源视频实际分辨率文本（如 "1920×1080"）；源信息不可用时返回"原尺寸"。
local function source_size_text()
    local dw = mp.get_property_number("video-params/dw", 0)
    local dh = mp.get_property_number("video-params/dh", 0)
    if dw > 0 and dh > 0 then return string.format("%s×%s", dw, dh) end
    return L("summary.original_size")
end

-- 拼图网格：接受 "5x5" 这类取值（自定义可写 "4x6"，列×行各自生效）。
-- 必须定义在 encode_summary 之前：图片摘要里要用它算总帧数。
local function tile_grid_size(settings)
    local value = tostring((settings or opts).tile_grid or "5x5")
    local a, b = value:match("^(%d+)%s*[xX×]%s*(%d+)$")
    a = math.max(1, math.min(20, tonumber(a) or 5))
    b = math.max(1, math.min(20, tonumber(b) or a))
    return a, b
end

function M.encode_summary()
    -- 摘要首项必须与确认面板那个选单**显示同一个东西**：设了优化目标就显示目标，
    -- 否则会出现"选单写着优化目标、摘要还写原始参数"的自相矛盾
    local label = (choice_name and choice_name()) or config.preset_label()
    -- 摘要按导出类型走：非视频类型下视频编码参数信息不参与，混在一起会误导
    local kind = state.export_kind or "video"
    if kind == "animated" then
        local fmt = tostring(opts.animated_format or "gif"):upper()
        local fps = tostring(opts.animated_fps or 12)
        local w = math.floor(tonumber(opts.animated_width) or 0)
        local size = w > 0 and (tostring(w) .. "px") or source_size_text()
        local loop = (tonumber(opts.animated_loop) or 0) == 0 and L("summary.loop_infinite")
                     or L("summary.loop_times", tostring(opts.animated_loop))
        return L("summary.animated", fmt, fps, size, loop)
    elseif kind == "audio" then
        local codec = ((config.codec_label and config.codec_text(opts.audio_codec)) or tostring(opts.audio_codec or ""))
        local br = tostring(opts.audio_bitrate or "")
        local sr = math.floor(tonumber(opts.audio_sample_rate) or 0)
        local ch = math.floor(tonumber(opts.audio_channels) or 0)
        return L("summary.audio", codec, br ~= "" and br or L("value.follow_source"),
            sr > 0 and (" · " .. sr .. "Hz") or "",
            ch > 0 and (" · " .. ch .. "ch") or "")
    elseif kind == "subtitle" then
        local codec = tostring(opts.subtitle_codec or "srt"):lower()
        return L("summary.subtitle", codec == "copy" and L("value.copy_raw") or codec:upper())
    elseif kind == "image" then
        local fmt = tostring(opts.image_format or "png"):upper()
        local w = math.floor(tonumber(opts.animated_width) or 0)
        local size = w > 0 and (tostring(w) .. "px") or source_size_text()
        local mode = tostring(opts.image_mode or "sequence"):lower()
        if mode == "tile" then
            local cols, rows = tile_grid_size(opts)
            return L("summary.image_tile", fmt, cols, rows, size)
        elseif mode == "keyframes" then
            -- 关键帧模式带上跳采信息：总数（已数过才有）与生效步长
            local text = L("summary.image_keyframes", fmt, size)
            local source = mp.get_property("path")
            local total = source and kf_total_cache[source]
            if total and total > 0 then text = text .. " · " .. L("summary.kf_total", total) end
            local stride = image_keyframe_stride(source, opts)
            if stride > 1 then text = text .. " · " .. L("summary.kf_stride", stride) end
            return text
        elseif mode == "single" then
            return L("summary.image_single", fmt, size)
        end
        return L("summary.image", fmt, tostring(opts.animated_fps or 1), size)
    end
    -- 自定义裁剪带比例锁时显示锁定的比例，比笼统的"自定义裁剪"更有信息量
    local crop = opts.crop_mode == "none" and L("summary.no_crop")
        or (opts.crop_mode == "custom" and (state.crop_ratio_lock or L("summary.custom_crop")) or opts.crop_aspect)
    if opts.export_preset_args and opts.export_preset_args ~= "" then
        return string.format("%s · %s · %s", label, L("summary.custom_args"), crop)
    end
    local size
    if opts.video_width > 0 or opts.video_height > 0 then
        size = string.format("%s×%s", opts.video_width > 0 and opts.video_width or L("value.auto"), opts.video_height > 0 and opts.video_height or L("value.auto"))
    else
        -- 未缩放时显示源视频实际分辨率，而非笼统的"原尺寸"
        size = source_size_text()
    end
    local quality = opts.video_quality_mode == "bitrate" and (opts.video_bitrate ~= "" and opts.video_bitrate or L("value.no_bitrate")) or (opts.video_quality_mode .. " " .. tostring(opts.video_quality))
    -- 限体积目标：摘要显示推导出的码率，替代笼统的 bitrate 档
    if state.optimize_goal == "size" and tonumber(state.size_target) then
        local total = 0
        for _, s in ipairs(get_queue()) do total = total + (s.end_time - s.start_time) end
        -- 无片段（整片转码）时队列为空、total 为 0 → size_bitrates 直接返回 nil →
        -- 摘要一直停在旧文案（用户看到的就是"选限定体积没有任何变化"）。退回源时长。
        if total <= 0 then total = tonumber((mp.get_property_number("duration"))) or 0 end
        local vk = M.size_bitrates(tonumber(state.size_target), total)
        if vk then quality = string.format(L("value.size_goal"), tonumber(state.size_target), vk) end
    end
    -- 编码名统一：格式名 (编码器)，与参数格、源文件行同一套话
        local vcodec = (config.codec_label and config.codec_text(opts.video_codec)) or tostring(opts.video_codec or "")
        local line = string.format("%s · %s · %s · %s · %s", label, vcodec, size, quality, crop)
        -- 变速只在非原速时追加，原速下摘要保持原样（避免满屏 "1x" 噪音）
        if speed_active(opts) then line = line .. " · " .. L("summary.speed", string.format("%g", speed_factor(opts))) end
        return line
end

-- 动图导出命令：GIF 需两遍调色板（palettegen → paletteuse），WebP/APNG 单遍即可。
-- 与视频链路的差异：不带音频、不套用 encode_container、帧率与缩放由动图参数决定。
local function build_animated_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local length = seg.end_time - seg.start_time
    -- 变速后时间轴被缩放，-t 要跟着走（见 build_trim_args 的说明）
    if speed_active(settings) then length = length / speed_factor(settings) end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    -- 显式选中视频流，避免多视频流/含封面源时依赖 ffmpeg 默认选择
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    table.insert(args,"-an")  -- 动图不带音频

    local fmt = tostring(settings.animated_format or "gif"):lower()
    local fps = tonumber(settings.animated_fps) or 12
    local width = math.floor(tonumber(settings.animated_width) or 0)
    local loop = math.floor(tonumber(settings.animated_loop) or 0)
    local quality = math.floor(tonumber(settings.animated_quality) or 80)

    -- 裁剪必须参与，否则动图导出的是未裁剪画面。顺序：crop → fps → scale，
    -- 每一步都先削减数据量，比反过来省不少处理量。
    local crop, crop_err = Crop.rect_for(settings)
    if crop_err then return nil, crop_err end
    local parts = {}
    if crop then parts[#parts+1] = string.format("crop=%d:%d:%d:%d", crop.w, crop.h, crop.x, crop.y) end
    -- 变速在 fps 之前：先改时间轴再抽帧，动图的采样点才跟着速度走
    if speed_active(settings) then
        parts[#parts+1] = string.format("setpts=%.6f*PTS", 1 / speed_factor(settings))
    end
    parts[#parts+1] = string.format("fps=%.3f", fps)
    if width > 0 then
        -- 已裁剪时宽度按裁剪后的画面算；未裁剪则按原尺寸
        parts[#parts+1] = string.format("scale=%d:-2:flags=lanczos", U.even_floor(width))
    end
    local chain = table.concat(parts, ",")

    if fmt == "gif" then
        -- GIF 只有 256 色，必须先生成调色板再套用，否则画质严重劣化
        table.insert(args,"-vf")
        table.insert(args, string.format(
            "%s,split[s0][s1];[s0]palettegen=max_colors=256:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3",
            chain))
        table.insert(args,"-loop"); table.insert(args,tostring(loop))
    elseif fmt == "webp" then
        if chain ~= "" then table.insert(args,"-vf"); table.insert(args,chain) end
        table.insert(args,"-c:v"); table.insert(args,"libwebp")
        table.insert(args,"-loop"); table.insert(args,tostring(loop))
        table.insert(args,"-quality"); table.insert(args,tostring(quality))
        table.insert(args,"-lossless"); table.insert(args,"0")
    elseif fmt == "avif" then
        -- AVIF 动图：avif muxer（ffmpeg ≥5.1，同一补丁即支持多帧）+ libaom-av1；
        -- aom 编码慢，cpu-used 取可用档
        if chain ~= "" then table.insert(args,"-vf"); table.insert(args,chain) end
        table.insert(args,"-f"); table.insert(args,"avif")
        table.insert(args,"-c:v"); table.insert(args,"libaom-av1")
        -- animated_quality 0-100（越大越好）→ aom crf 0-63（越小越好）
        local crf = math.max(0, math.min(63, math.floor((100 - quality) * 63 / 100 + 0.5)))
        table.insert(args,"-crf"); table.insert(args,tostring(crf))
        table.insert(args,"-cpu-used"); table.insert(args,"6")
        table.insert(args,"-pix_fmt"); table.insert(args,"yuv420p")
        table.insert(args,"-loop"); table.insert(args,tostring(loop))
    else  -- apng
        if chain ~= "" then table.insert(args,"-vf"); table.insert(args,chain) end
        table.insert(args,"-f"); table.insert(args,"apng")
        table.insert(args,"-plays"); table.insert(args,tostring(loop))
    end

    table.insert(args,output)
    return args
end

-- 仅音频导出：丢掉视频流，音频按 audio_* 参数编码。
-- 注意 codec=copy 时不能带 -b:a，否则 ffmpeg 会直接报错。
-- 字幕抽取：只映射一条字幕轨，不带视频/音频。
-- 内嵌轨用 0:s:N；外挂字幕文件另作一个输入（mpv 的轨道序号与 FFmpeg 的 0:s:N 不通用，
-- 直接拿 mpv 的序号去 0:s:N 会抽到错误的轨）。
local function build_subtitle_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local external = tracks.subtitle_external
    local index = tracks.subtitle
    -- 没选中任何字幕轨（常见于 sid=no）时退到第一条内嵌轨：抽字幕的目标通常是
    -- "把这条轨拿出来"，为此直接报错不划算
    if external == nil and index == nil then index = tracks.subtitle_first end
    if external == nil and index == nil then return nil, L("hint.no_subtitle_track") end
    local length = seg.end_time - seg.start_time
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    local stream_ref = "0:s:" .. tostring(index)
    if external ~= nil then
        -- 外挂字幕同样按区间裁剪：-ss 是针对紧随其后的那个输入的选项
        table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
        table.insert(args,"-i"); table.insert(args,external)
        stream_ref = "1:s:0"
    end
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    table.insert(args,"-map"); table.insert(args,stream_ref)
    local codec = tostring(settings.subtitle_codec or "srt"):lower()
    table.insert(args,"-c:s"); table.insert(args,codec)
    if codec == "copy" then
        -- 流复制 + 输入 -ss：不归零会让部分容器产出负时间戳
        table.insert(args,"-avoid_negative_ts"); table.insert(args,"make_zero")
    end
    table.insert(args,output)
    return args
end

local function build_audio_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local length = seg.end_time - seg.start_time
    -- 变速后时间轴被缩放，-t 要跟着走（见 build_trim_args 的说明）。
    -- 音频侧只有"会重编码"时才挂 atempo，copy 时变速不生效，此时 -t 保持原时长。
    if speed_active(settings) and tostring(settings.audio_codec or "") ~= "copy" then
        length = length / speed_factor(settings)
    end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    -- 显式选中音频轨，多音轨源不再取 ffmpeg "best" 轨；带 ? 允许轨不存在时忽略
    if tracks.audio ~= nil then table.insert(args,"-map"); table.insert(args,"0:a:" .. tracks.audio .. "?") end
    table.insert(args,"-vn")

    local codec = tostring(settings.audio_codec or "aac")
    -- 音频导出必须带音轨：万一 opts.audio_codec 还留着视频那边的 "none"（两套参数集共享该字段），
    -- 这里兜底成 copy —— 切类型时 coerce 通常已纠正，这是最后一道保险。
    if codec == "none" then codec = "copy" end
    table.insert(args,"-c:a"); table.insert(args,codec)
    local br = tostring(settings.audio_bitrate or "")
    if br ~= "" and codec ~= "copy" then
        table.insert(args,"-b:a"); table.insert(args,br)
    end
    local sr = math.floor(tonumber(settings.audio_sample_rate) or 0)
    if sr > 0 then table.insert(args,"-ar"); table.insert(args,tostring(sr)) end
    local ch = math.floor(tonumber(settings.audio_channels) or 0)
    if ch > 0 then table.insert(args,"-ac"); table.insert(args,tostring(ch)) end
    -- 变速：纯音频导出同样要改时长（atempo 保音调）；copy 时无法变速，只能跳过
    if speed_active(settings) and codec ~= "copy" then
        local chain = atempo_chain(speed_factor(settings))
        if chain then table.insert(args,"-af"); table.insert(args,chain) end
    end

    table.insert(args,output)
    return args
end

-- 图片导出的产物形态：序列（每帧一张图，路径必须带 %04d 模板）vs 单图（tile 拼图）。
-- 命名、提交、清理三处都依赖它，因此集中判定一次。
local function image_output_is_sequence(settings)
    settings = settings or opts
    if tostring(settings.output_kind or "") ~= "image" then return false end
    local mode = tostring(settings.image_mode or "sequence"):lower()
    -- tile 与 single 都是"单文件"产物：tile 是拼图，single 是每个片段一张单图
    return mode ~= "tile" and mode ~= "single"
end

--   整片解码 + fps 过滤器            2.6s   代价随区间线性增长（2 小时 4K 可达几十分钟）
--   逐点输入定位（每个采样点一次 -ss）1.1s   代价只与采样点数有关、与片长无关（约 45ms/点）
--   只解关键帧 + fps 采样            0.8s   代价只与文件体积有关（约 2ms/MB），但采样点被吸附到关键帧
-- 所以按"区间长度 + 采样点数"分档：
--   区间 ≤ 30s      → 一次解码（最准、最省；且不占用多输入）
--   区间更长、≤ 64 点 → 逐点定位（长片上比解码快一两个量级）
local TILE_DECODE_MAX_SECONDS = 30
local TILE_MAX_INPUTS = 64
local TILE_SEEK_MS_PER_POINT = 45
local TILE_DECODE_MS_PER_MB = 2.5

-- 拼图：至少有一个输入总得"读"到采样点。
-- 长区间用逐点定位：对 N 个采样点各做一次输入定位（-ss），每个点只取 1 帧，再 concat + tile。
-- 用 fps 过滤器采样的问题在于 fps 是"解码之后"丢帧——等于把整片逐帧解完才凑出 N 张，
-- 代价随时长线性增长（5 分钟源 2.6s；2 小时 4K 几十分钟），而定位采样与片长无关。
local function build_tile_args(input, output, seg, tracks, settings)
    settings = settings or opts
    local cols, rows = tile_grid_size(settings)
    local total = cols * rows
    local length = math.max(0.001, seg.end_time - seg.start_time)
    local crop, crop_err = Crop.rect_for(settings)
    if crop_err then return nil, crop_err end
    local width = math.floor(tonumber(settings.animated_width) or 0)

    -- 裁剪/缩放片段：单输入与多输入两条路径共用
    local function visual_chain()
        local parts = {}
        if crop then parts[#parts+1] = string.format("crop=%d:%d:%d:%d", crop.w, crop.h, crop.x, crop.y) end
        if width > 0 then parts[#parts+1] = string.format("scale=%d:-2:flags=lanczos", U.even_floor(width)) end
        return parts
    end
    local grid = string.format("tile=%dx%d:padding=2:margin=2", cols, rows)

    -- 单输入版本：一次解码，用 fps 取 N 帧后 tile。extra_opts 可加 -skip_frame 等输入选项。
    local function single_input_tile(extra_input_opts)
        local parts = visual_chain()
        parts[#parts+1] = string.format("fps=%.6f", total / length)
        parts[#parts+1] = grid
        local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
        for _, opt in ipairs(extra_input_opts or {}) do table.insert(args, opt) end
        table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
        table.insert(args,"-i"); table.insert(args,input)
        table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
        if tracks and tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:"..tracks.video) end
        table.insert(args,"-an")
        table.insert(args,"-vf"); table.insert(args,table.concat(parts,","))
        table.insert(args,"-frames:v"); table.insert(args,"1")
        table.insert(args,output)
        return args
    end

    -- 区间体积估算（容器不给区间体积，按整片体积×区间占比推）：据此判断解码是否比定位更省
    local use_seek = length > TILE_DECODE_MAX_SECONDS
    if use_seek and total <= TILE_MAX_INPUTS then
        local info = utils.file_info(input)
        local whole = tonumber((mp.get_property_number("duration"))) or 0
        if info and tonumber(info.size) and whole > length then
            local range_mb = (tonumber(info.size) / 1048576) * (length / whole)
            -- 区间很轻（如低码率短片）时解码仍更划算；拿不准就保持定位采样（长片上的收益大得多）
            use_seek = range_mb * TILE_DECODE_MS_PER_MB > total * TILE_SEEK_MS_PER_POINT
        end
    end

    if not use_seek then return single_input_tile(nil) end
    if total > TILE_MAX_INPUTS then
        -- 采样点太多（多输入会超命令行长度）：退回只解关键帧 + 等间隔采样
        return single_input_tile({"-skip_frame","nokey"})
    end

    local step = length / total
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    for i = 1, total do
        -- 每格取区间中点：避开片头黑场，采样点也均匀落在各自格内
        local at = seg.start_time + (i - 0.5) * step
        if at > seg.end_time then at = seg.end_time end
        table.insert(args,"-ss"); table.insert(args,string.format("%.6f", math.max(0, at)))
        table.insert(args,"-i"); table.insert(args,input)
    end

    local chains = {}
    for i = 1, total do
        -- trim 只留定位点那一帧；setpts 归零是 concat 的硬要求（各输入时间戳须从 0 起）。
        -- 注意：输入标签与第一个滤镜之间不能有逗号——写成 "[0:v],trim=..." 会被当成空滤镜。
        local filters = { "trim=end_frame=1", "setpts=PTS-STARTPTS" }
        for _, extra in ipairs(visual_chain()) do filters[#filters+1] = extra end
        -- 标签与下面的 concat 引用同为 0 基，避免两处编号不一致
        chains[#chains+1] = string.format("[%d:v]%s[v%d]", i - 1, table.concat(filters, ","), i - 1)
    end
    local refs = {}
    for i = 0, total - 1 do refs[#refs+1] = string.format("[v%d]", i) end
    -- 先 concat 成一条帧序列，再用 tile 摆成网格（tile 本身按输入顺序取帧）
    chains[#chains+1] = string.format("%sconcat=n=%d:v=1:a=0[cat]", table.concat(refs), total)
    chains[#chains+1] = string.format("[cat]tile=%dx%d:padding=2:margin=2[out]", cols, rows)
    table.insert(args,"-filter_complex"); table.insert(args,table.concat(chains, ";"))
    table.insert(args,"-map"); table.insert(args,"[out]")
    table.insert(args,"-frames:v"); table.insert(args,"1")
    table.insert(args,output)
    return args
end

-- 图片导出：三种模式共用一个 builder。
--   sequence  按帧率抽帧后逐帧输出（输出路径须带 %04d 序号模板）
--   keyframes 只解码关键帧（-skip_frame nokey 是解码器选项，必须在 -i 之前），每个关键帧一张
--   tile      等间隔抽 列×行 帧拼成一张总览图（单文件输出）
local function build_image_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local length = math.max(0.001, seg.end_time - seg.start_time)
    local mode = tostring(settings.image_mode or "sequence"):lower()
    -- 序列模式按 fps 抽帧、且挂了 setpts，-t 要按缩放后的时间轴算
    -- （keyframes 与 single 不挂 setpts，保持原时长）
    if mode ~= "keyframes" and mode ~= "single" and mode ~= "tile" and speed_active(settings) then
        length = length / speed_factor(settings)
    end    -- 拼图有独立实现：定位采样而不是整片解码
    if mode == "tile" then return build_tile_args(input, output, seg, tracks, settings) end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    if mode == "keyframes" then table.insert(args,"-skip_frame"); table.insert(args,"nokey") end
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    -- 显式选中视频流，避免多视频流/含封面源时依赖 ffmpeg 默认选择
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    table.insert(args,"-an")

    local crop, crop_err = Crop.rect_for(settings)
    if crop_err then return nil, crop_err end
    local width = math.floor(tonumber(settings.animated_width) or 0)
    local parts = {}
    if crop then parts[#parts+1] = string.format("crop=%d:%d:%d:%d", crop.w, crop.h, crop.x, crop.y) end
    if mode == "keyframes" then
        -- 跳采用 select 按"解码器吐出的第几个关键帧"计数（-skip_frame nokey 之后 n 就只数关键帧），
        -- 放在 scale 之前：被丢掉的帧不必再缩放
        local stride = image_keyframe_stride(input, settings)
        if stride > 1 then parts[#parts+1] = string.format("select=not(mod(n\\,%d))", stride) end
    elseif mode == "single" then
        -- 单帧只取片段起始那一帧：不加 fps 滤镜（否则会退化成"截取一段序列"）
    else
        -- 变速在 fps 之前：序列抽帧的间隔要跟着速度走
        if speed_active(settings) then
            parts[#parts+1] = string.format("setpts=%.6f*PTS", 1 / speed_factor(settings))
        end
        parts[#parts+1] = string.format("fps=%.3f", tonumber(settings.animated_fps) or 1)
    end
    if width > 0 then
        parts[#parts+1] = string.format("scale=%d:-2:flags=lanczos", U.even_floor(width))
    end
    -- parts 可能为空（单帧且未裁剪/未缩放）：空 -vf 会让 ffmpeg 报错
    if #parts > 0 then table.insert(args,"-vf"); table.insert(args,table.concat(parts,",")) end
    if mode == "single" then table.insert(args,"-frames:v"); table.insert(args,"1") end
    if mode == "keyframes" then
        -- 关键帧时间戳不规律：禁止帧率转换，否则 ffmpeg 会按 CFR 复制/丢帧。
        -- ffmpeg < 5.1 没有 -fps_mode，退到语义等效的
        -- -vsync 0 —— 它在 4.x 上仍有效（否则 4.x 会报 "Unrecognized option 'fps_mode'"）。
        if ffmpeg_at_least(5, 1) then
            table.insert(args,"-fps_mode"); table.insert(args,"passthrough")
        else
            table.insert(args,"-vsync"); table.insert(args,"0")
        end
    end

    local fmt = tostring(settings.image_format or "png"):lower()
    local q = math.floor(tonumber(settings.image_quality) or 3)
    if fmt == "jpg" then
        table.insert(args,"-q:v"); table.insert(args,tostring(q))
    elseif fmt == "webp" then
        table.insert(args,"-c:v"); table.insert(args,"libwebp")
        -- image_quality 沿用 jpg -q:v 的语义（2 最好、31 最差）；libwebp -quality 相反
        -- （0-100，越大越好）。线性映射 2→100、31→0，保证同一质量选项两种格式体感一致。
        local wq = math.floor(100 - (math.max(2, math.min(31, q)) - 2) * 100 / 29)
        table.insert(args,"-quality"); table.insert(args,tostring(wq))
    elseif fmt == "avif" then
        -- AVIF 静帧：libaom-av1 + crf（0-63，越小越好），image_quality 同向直传
        table.insert(args,"-c:v"); table.insert(args,"libaom-av1")
        table.insert(args,"-crf"); table.insert(args,tostring(math.max(0, math.min(63, q))))
        table.insert(args,"-cpu-used"); table.insert(args,"6")
        table.insert(args,"-pix_fmt"); table.insert(args,"yuv420p")
    elseif fmt == "jxl" then
        -- JXL：libjxl distance（0=无损，越大越差）；image_quality 2-31 线性映射到 0-15
        table.insert(args,"-c:v"); table.insert(args,"libjxl")
        local dist = (math.max(2, math.min(31, q)) - 2) * 15 / 29
        table.insert(args,"-distance"); table.insert(args,string.format("%.2f", dist))
    end

    table.insert(args,output)
    return args
end

-- 音频流映射（三处单段输出与智能切割头/尾共用）：audio_codec=="none" ⇒ 输出无音轨（-an）；
-- 否则按当前选中轨映射，带 ? 允许轨不存在时忽略。
local function add_audio_stream(args, tracks, settings)
    if tostring(settings.audio_codec or ""):lower() == "none" then
        table.insert(args, "-an")
        return
    end
    if tracks and tracks.audio ~= nil then
        table.insert(args, "-map")
        table.insert(args, "0:a:" .. tracks.audio .. "?")
    end
end

-- 智能切割的头部：视频按源的编码器/像素格式/档次重编码（不一致会让 concat 后的流解不出来），
-- 质量取 crf 18（视觉无损档）；音频重编码。
--   * -ss 必须放**输入侧**（-i 之前）：输出侧 -ss 要求解码器从文件开头逐帧丢掉，
--   * 不加 -avoid_negative_ts make_zero：它按"最早的时间戳"整体平移，而 aac 编码器延迟
--     让音频起点为负，于是视频被推到 +0.080、容器时长 0.846 远大于视频实际 0.720；
--     concat 正是按容器时长排下一片，多出来的这一截就落在接缝上。去掉后视频从 0 起算。
local function build_smart_head_args(input, output, from_time, to_time, tracks, settings, plan_smart)
    local length = math.max(0.001, to_time - from_time)
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",from_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    add_audio_stream(args, tracks, settings)
    table.insert(args,"-map_metadata"); table.insert(args,"0")
    table.insert(args,"-map_chapters"); table.insert(args,"-1")
    table.insert(args,"-c:v"); table.insert(args,plan_smart.encoder)
    if plan_smart.profile then table.insert(args,"-profile:v"); table.insert(args,plan_smart.profile) end
    table.insert(args,"-pix_fmt"); table.insert(args,plan_smart.pix_fmt)
    table.insert(args,"-crf"); table.insert(args,"18")
    table.insert(args,"-preset"); table.insert(args,"veryfast")
    -- 头片禁用 B 帧：头最长 smart_cut_max_head 秒，代价可忽略；而 B 帧的排序延迟会让头片
    -- （752 帧/30.171s → 752 帧/30.099s，接缝包序恢复单调）。这只能消掉"头侧"的贡献：
    table.insert(args,"-bf"); table.insert(args,"0")
    if tracks.audio ~= nil and tostring(settings.audio_codec or ""):lower() ~= "none" then
        -- 音频也重编码：对复制流 -ss 只能从前一个关键帧开始，会让头部多带一截
        table.insert(args,"-c:a"); table.insert(args, plan_smart.audio_encoder or "aac")
        if not plan_smart.audio_lossless then
            table.insert(args,"-b:a"); table.insert(args, tostring(plan_smart.audio_bitrate or 192000))
        end
    end
    -- 这里**不加** -avoid_negative_ts make_zero：它按最早时间戳整体平移，而 aac 编码延迟
    -- 让音频起点为负，于是视频被推到 +0.080、容器时长 0.846 远大于视频实际 0.720。
    table.insert(args,output)
    return args
end

-- 智能切割的尾部：从关键帧到处点，整条流复制（无损）。-ss 落在关键帧上，复制就从该帧开始；
-- 复制流的 -ss 必须放**输入侧**，这样尾部自身从 0 起算，concat 才能正确排布。
local function build_smart_tail_args(input, output, from_time, to_time, tracks, settings)
    local length = math.max(0.001, to_time - from_time)
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",from_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    add_audio_stream(args, tracks, settings)
    table.insert(args,"-map_metadata"); table.insert(args,"0")
    table.insert(args,"-map_chapters"); table.insert(args,"-1")
    table.insert(args,"-c"); table.insert(args,"copy")
    table.insert(args,"-avoid_negative_ts"); table.insert(args,"make_zero")
    table.insert(args,output)
    return args
end

local function build_trim_args(input, output, seg, accurate, tracks, settings)
    settings = settings or opts
    -- 非视频类型走各自的独立链路：参数集与视频编码设置互不干扰
    local ok = settings.output_kind
    if ok == "audio" then return build_audio_args(input, output, seg, tracks, settings) end
    if ok == "animated" then return build_animated_args(input, output, seg, tracks, settings) end
    if ok == "image" then return build_image_args(input, output, seg, tracks, settings) end
    if ok == "subtitle" then return build_subtitle_args(input, output, seg, tracks, settings) end
    if not accurate and Crop.crop_is_active(settings) then
        return nil,L("hint.crop_requires_precise")
    end
    -- 变速与裁剪同理：流复制改不了时间轴，必须走重新编码
    if not accurate and speed_active(settings) then
        return nil, L("hint.speed_requires_precise")
    end
    local length = seg.end_time - seg.start_time
    -- -t 计的是"滤镜之后的时间轴"：变速把时间轴压/拉到 length/speed，
    -- 所以这里必须同步缩放，否则 -t 会按原时长再截一刀，2 倍速出来还是原来的秒数。
    local out_length = length
    if speed_active(settings) then out_length = length / speed_factor(settings) end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    -- -ss 前置（输入选项）：快速跳到切点附近关键帧后精确解码；
    -- 对重编码同样精确，且避免从头解码整段视频。
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",out_length))
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    add_audio_stream(args, tracks, settings)
    table.insert(args,"-map_metadata"); table.insert(args,"0")
    table.insert(args,"-map_chapters"); table.insert(args,"-1")
    local raw_args = tostring(settings.export_preset_args or "")
    if accurate and raw_args ~= "" then
        -- 完全自定义模式：不注入滤镜与编码参数，完全使用预设给定的参数
        for _, a in ipairs(U.safe_extra_args(U.split_args(raw_args))) do table.insert(args, a) end
    elseif accurate then
        if tracks.video ~= nil then
            local filters, filter_err = build_video_filters(settings)
            if filter_err then return nil, filter_err end
            if #filters > 0 then table.insert(args,"-vf"); table.insert(args,table.concat(filters,",")) end
            -- 滤镜链与 -c:v copy 互斥（ffmpeg: "Filtering and streamcopy cannot be
            -- used together"）。重新编码模式下用户仍可能选了"复制"（预设/conf 直填），
            -- 这时必须换成真实编码器，否则整段导出直接失败。容器不支持该编码器时
            -- real_video_codec_for 会兜底到 libx264。
            if #filters > 0 and tostring(settings.video_codec) == "copy" then
                local container = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
                settings.video_codec = config.real_video_codec_for(container)
                msg.info("quick_cut video: 'copy' cannot carry filters, using "
                    .. tostring(settings.video_codec))
            end
            append_video_encode_args(args, settings)
        end
        if tracks.audio ~= nil then append_audio_encode_args(args, settings) end
    else
        -- 快速复制默认整条流复制。例外：只做音量归一化时视频仍复制（画质零损失），
        -- 音频单独重编码——这样"音量不对"不必逼用户走整片重编码。
        -- 变速已在上面被挡下（流复制改不了时间轴），这里不必再考虑 atempo。
        local af = (settings.normalize_audio == true) and loudnorm_af(settings) or nil
        if af and tracks.audio ~= nil then
            if tracks.video ~= nil then table.insert(args,"-c:v"); table.insert(args,"copy") end
            table.insert(args,"-c:a"); table.insert(args, tostring(settings.audio_codec) ~= "copy" and settings.audio_codec or "aac")
            local br = tostring(settings.audio_bitrate or "")
            if br ~= "" then table.insert(args,"-b:a"); table.insert(args,br) end
            table.insert(args,"-af"); table.insert(args,af)
        else
            table.insert(args,"-c"); table.insert(args,"copy")
        end
        table.insert(args,"-avoid_negative_ts"); table.insert(args,"make_zero")
    end
    -- 附加参数（预设 extra_args + 全局 ffmpeg_extra_args），位于输出路径之前
    local extra = {}
    for _, src in ipairs({settings.export_preset_extra, settings.ffmpeg_extra_args}) do
        if src and src ~= "" then
            for _, a in ipairs(U.split_args(src)) do extra[#extra + 1] = a end
        end
    end
    if #extra > 0 then
        for _, a in ipairs(U.safe_extra_args(extra)) do table.insert(args, a) end
    end
    -- 重新编码注入，于是拨动这个开关唯一的效果是把导出顶成整段重编码（参数侧现已不再强制切重新编码）。
    -- 容器按**实际输出**判断：重新编码是 encode_container，快速复制沿用源扩展名。
    local container = accurate and tostring(settings.encode_container or ""):lower():gsub("^%.", "")
        or tostring(output or ""):lower():match("%.([%w]+)$") or ""
    if settings.faststart == true and (container == "mp4" or container == "mov") then
        table.insert(args,"-movflags"); table.insert(args,"+faststart")
    end
    -- 两遍编码（限体积目标）：-pass/-passlogfile 位于输出路径之前；第一遍输出到 null 丢弃
    if settings.two_pass then
        table.insert(args,"-pass"); table.insert(args,tostring(settings.two_pass))
        table.insert(args,"-passlogfile"); table.insert(args,tostring(settings.passlogfile or ""))
        if tonumber(settings.two_pass) == 1 then table.insert(args,"-f"); table.insert(args,"null") end
    end
    table.insert(args,output)
    return args
end

-- ============================================================================
-- mpv 兜底后端：参数构造
--
-- mpv 编码模式（`--o=file`）与 ffmpeg CLI 的参数模型不同：
--   * 没有 -map / -ss 输入选项；裁剪靠 --start/--end（精确到帧）
--   * 滤镜走 --vf（视频）/ --af（音频），值就是 ffmpeg 滤镜链字符串
--   * 编码器/码率走 --ovc/--oac/--ovcopts/--oacopts
-- 因此不能复用 build_trim_args，这里另写一份。能复用的只有滤镜链
-- （build_video_filters 返回的滤镜名在 --vf 里同样合法）与响度参数。
-- ============================================================================

local function mpv_video_filter(settings)
    local filters = build_video_filters(settings)
    if not filters or #filters == 0 then return nil end
    -- 变速在入口就被拒绝（mpv 编码模式做不到），这里顺手把 setpts 剥掉只是防御：
    -- 万一有调用路径漏了检查，也不要把 setpts 拼进来继续出一个静默错误的结果。
    local kept = {}
    for _, f in ipairs(filters) do
        if not f:match("^setpts=") then kept[#kept + 1] = f end
    end
    if #kept == 0 then return nil end
    return table.concat(kept, ",")
end

-- 音频滤镜：与 append_audio_encode_args 同一套顺序（先 loudnorm）。atempo 不追加，
-- 因为变速整体不支持。
local function mpv_audio_filter(settings)
    local parts = {}
    if settings.normalize_audio == true then
        local af = loudnorm_af(settings)
        if af then parts[#parts + 1] = af end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ",")
end

-- --ovcopts / --oacopts 用 "key=value,key=value" 串（值里不能带逗号）
local function mpv_opts_string(pairs_list)
    local out = {}
    for _, kv in ipairs(pairs_list) do
        if kv[1] and kv[2] ~= nil and tostring(kv[2]) ~= "" then
            out[#out + 1] = tostring(kv[1]) .. "=" .. tostring(kv[2])
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, ",")
end

-- ffmpeg 风格码率 "5803k" → mpv 的 b=（bit/s 数值）
local function mpv_bitrate_value(raw)
    raw = tostring(raw or "")
    local num = tonumber(raw:match("^([%d%.]+)"))
    if not num then return nil end
    if raw:match("[kK]$") then num = num * 1000
    elseif raw:match("[mM]$") then num = num * 1000000 end
    return string.format("%d", math.floor(num))
end

-- 视频质量参数：mpv 的 --ovcopts 直通 libavcodec 的 AVOptions，所以 crf 对
-- x264/x265/vp9 都有效。preset 只对自带该 AVOption 的编码器有意义。
local function mpv_video_quality_opts(settings, encoder)
    local out = {}
    local mode = tostring(settings.video_quality_mode or "crf")
    if mode == "bitrate" and tostring(settings.video_bitrate or "") ~= "" then
        out[#out + 1] = { "b", mpv_bitrate_value(settings.video_bitrate) }
    else
        -- crf 模式（cq / global_quality 是硬件编码器的说法，软编统一按 crf 传）
        local q = tonumber(settings.video_quality)
        if q then out[#out + 1] = { "crf", string.format("%g", q) } end
    end
    if encoder == "libx264" or encoder == "libx265" then
        local preset = tostring(settings.preset or "")
        if preset ~= "" and preset ~= "medium" then out[#out + 1] = { "preset", preset } end
    end
    return out
end

-- 单段剪辑的 mpv 编码命令。seg/tracks/settings 语义与 build_trim_args 一致。
-- 返回 args, err。err 非 nil 时调用方按"该段失败"处理（不重试）。
local function build_mpv_trim_args(input, output, seg, tracks, settings)
    local mpv_bin = resolve_mpv_binary()
    if not mpv_bin then return nil, L("hint.no_mpv_binary") end
    local kind = tostring(settings.output_kind or "video"):lower()
    local container = tostring(settings.encode_container or "mkv"):lower():gsub("^%.", "")

    -- 编码模式绝不能显式指定 --vo：mpv 内置的编码 vo（lavfi）只在 --vo 未设置时自动启用，
    -- 一旦写了 --vo=null/lavfi/gpu-next，视频流就整条丢掉（实测产物只剩音轨）。
    -- 音频走 --oac 直连编码器，同样不要写 --ao。
    local args = { mpv_bin, "--no-config", "--no-terminal",
        "--start=" .. string.format("%.6f", seg.start_time),
        "--end=" .. string.format("%.6f", seg.end_time),
        "--o=" .. output }
    -- 变速无法在 mpv 编码模式下实现，调用方（run_cut）已在入口拒绝；这里再挡一次，
    -- 防止别的调用路径漏掉。
    -- 实测结论（mpv v0.41.0）：--speed=N 在编码模式下对帧数与时长**完全无效**
    -- （2 倍速、0.5 倍速输出帧数都是 90 帧 / 3.65s）；--vf=setpts=0.5*PTS 同样被忽略
    -- （mpv 用自己的时间戳，滤镜侧的 pts 改写会被复位）；fps 滤镜能改帧数但改不了
    -- 音频侧的时间轴，硬凑出来是"画面快了、声音没快"的错文件。
    if speed_active(settings) then return nil, L("hint.mpv_no_speed") end
    -- 源文件必须是位置参数（放在最后）：mpv 用它当播放目标，缺了就只是空跑一小时再退出，
    -- 表现是 exit 0 + 0 字节产物（"输出为空或无法提交正式文件"）。
    local source = tostring(input or "")
    if source == "" then return nil, L("hint.not_local_file") end

    -- 轨道选择：剪辑导出只要主视频 + 第一条音频，不烧字幕。
    -- tracks.* 是 ffmpeg 口径的 0 基序号（-map 0:v:N），mpv 的 --vid/--aid 是 1 基的轨道 id，
    -- 直接传 0 会被 mpv 当成"禁用该轨道"，所以必须 +1。
    if tracks.video ~= nil then args[#args + 1] = "--vid=" .. tostring(tonumber(tracks.video) + 1) end
    if tracks.audio ~= nil then args[#args + 1] = "--aid=" .. tostring(tonumber(tracks.audio) + 1)
    else args[#args + 1] = "--aid=no" end
    args[#args + 1] = "--sid=no"

    local vfilter = mpv_video_filter(settings)
    if vfilter then args[#args + 1] = "--vf=" .. vfilter end

    if kind == "audio" then
        local encoder = mpv_encoder("audio", container)
        if not encoder then return nil, L("hint.mpv_unsupported_container", container) end
        args[#args + 1] = "--no-video"
        args[#args + 1] = "--oac=" .. encoder
        local aopts = { { "b", mpv_bitrate_value(settings.audio_bitrate) } }
        local sr = tonumber(settings.audio_sample_rate)
        if sr and sr > 0 then aopts[#aopts + 1] = { "ar", tostring(sr) } end
        local ch = tonumber(settings.audio_channels)
        if ch and ch > 0 then aopts[#aopts + 1] = { "ac", tostring(ch) } end
        local af = mpv_audio_filter(settings)
        if af then args[#args + 1] = "--af=" .. af end
        local astr = mpv_opts_string(aopts)
        if astr then args[#args + 1] = "--oacopts=" .. astr end
        args[#args + 1] = source
        return args
    end

    if kind == "animated" then
        local fmt = tostring(settings.animated_format or "gif"):lower()
        if fmt == "webp" then fmt = "webp_anim" end
        local encoder = mpv_encoder("video", fmt)
        if not encoder then return nil, L("hint.mpv_unsupported_container", fmt) end
        -- 动图没有音轨：上面按 tracks 挂的 --aid=N 必须撤掉，否则 mpv 会把音频也编进去
        -- （gif/webp 容器装不下音轨，报错或产出坏文件）。
        args[#args + 1] = "--aid=no"
        args[#args + 1] = "--ovc=" .. encoder
        -- --of 必须显式给：mpv 只按输出扩展名猜封/编码，apng 的扩展名是 .png，
        -- 不给 --of=apng 就会被当成单帧静态图（只写第一帧，体积小得离谱还不报错）。
        if fmt == "webp_anim" then args[#args + 1] = "--of=webp"
        elseif fmt == "apng" then args[#args + 1] = "--of=apng" end
        args[#args + 1] = source
        return args
    end

    if kind == "image" then
        local fmt = tostring(settings.image_format or "png"):lower()
        local encoder = mpv_encoder("image", fmt)
        if not encoder then return nil, L("hint.mpv_unsupported_container", fmt) end
        -- 图片同样没有音轨
        args[#args + 1] = "--aid=no"
        args[#args + 1] = "--ovc=" .. encoder
        -- 序列：--o 带 %0Nd 模板，mpv 会按帧号替换；--of 显式给 image2
        args[#args + 1] = "--of=image2"
        -- mjpeg 只收全范围 YUV，源若是有限范围会直接失败并报
        -- "Non full-range YUV is non-standard, set strict_std_compliance to at most unofficial"。
        -- 在滤镜链里先转成全范围，比放宽合规等级更正确（后者写出的 JPEG 是错的）。
        if encoder == "mjpeg" then args[#args + 1] = "--vf-add=scale=out_range=full" end
        args[#args + 1] = source
        return args
    end

    -- 视频（默认）
    local encoder = mpv_encoder("video", container)
    if not encoder then return nil, L("hint.mpv_unsupported_container", container) end
    args[#args + 1] = "--ovc=" .. encoder
    local vstr = mpv_opts_string(mpv_video_quality_opts(settings, encoder))
    if vstr then args[#args + 1] = "--ovcopts=" .. vstr end
    local pix = tostring(settings.pixel_format or "")
    if pix ~= "" and pix ~= "auto" then args[#args + 1] = "--ovcopts-append=pixel_format=" .. pix end

    if tracks.audio ~= nil and tostring(settings.audio_codec or ""):lower() ~= "none" then
        local aenc = mpv_encoder("audio", container)
        if not aenc then return nil, L("hint.mpv_unsupported_container", container) end
        args[#args + 1] = "--oac=" .. aenc
        local astr = mpv_opts_string({ { "b", mpv_bitrate_value(settings.audio_bitrate) } })
        if astr then args[#args + 1] = "--oacopts=" .. astr end
        local af = mpv_audio_filter(settings)
        if af then args[#args + 1] = "--af=" .. af end
    end
    args[#args + 1] = source
    return args
end

local function selected_tracks()
    local list = mp.get_property_native("track-list") or {}
    local out = {video = nil, audio = nil, audio_first = nil, subtitle = nil, subtitle_first = nil, subtitle_external = nil}
    local video_index, audio_index, subtitle_index = 0, 0, 0
    for _, track in ipairs(list) do
        if track.type == "video" then
            -- 计数时包含封面流，以便与 FFmpeg 0:v:N 的序号保持一致。
            if track.selected and not track.albumart and out.video == nil then out.video = video_index end
            video_index = video_index + 1
        elseif track.type == "audio" then
            -- 外挂音轨（--audio-file-auto / --audio-file 加载的）不在源容器里，ffmpeg 的 0:a:N
            -- 索引不到它；跳过且**不占** audio_index，否则其后的内嵌轨序号整体偏一位。
            -- （字幕一侧也是同样处理。）
            local aext = track["external-filename"]
            if aext == nil or aext == "" then
                if track.selected and out.audio == nil then out.audio = audio_index end
                if out.audio_first == nil then out.audio_first = audio_index end
                audio_index = audio_index + 1
            elseif track.selected then
                -- 只有"选中的是被跳过的外挂轨"才允许下面回退；否则 aid=no（用户主动关掉音频）
                -- 也会被回退成带音轨的导出。
                out.audio_external_selected = true
            end
        elseif track.type == "sub" then
            -- 注意：mpv 的 track-list 用 "sub"（ffprobe 的 codec_type 才是 "subtitle"）
            -- 字幕分两类：容器内嵌轨走 FFmpeg 的 0:s:N；外挂字幕文件不在源容器里，
            -- 必须另作一个输入文件（mpv 的轨道序号与 0:s:N 不通用，混用会抽到错误的轨）。
            -- 因此外挂轨不占 subtitle_index。
            local external = track["external-filename"]
            if external == nil or external == "" then
                if out.subtitle_first == nil then out.subtitle_first = subtitle_index end
                if track.selected and out.subtitle == nil then out.subtitle = subtitle_index end
                subtitle_index = subtitle_index + 1
            elseif track.selected and out.subtitle == nil and out.subtitle_external == nil then
                out.subtitle_external = external
            end
        end
    end
    -- 选中的是外挂音轨（已跳过、不占索引）时退回源文件第一条内嵌音轨：
    -- 宁可导出源音轨，也不静默产出一个没有声音的文件。
    -- 仅在确实选过外挂轨时回退：没选任何音频（aid=no）是用户的明确意图，不能替他加回来。
    if out.audio == nil and out.audio_external_selected then out.audio = out.audio_first end
    return out
end

local function validate_media_async(path, tracks, settings, callback)
    settings = settings or opts
    if settings.merge_validation == "off" then callback(true, nil); return end
    if settings.merge_validation == "basic" then
        local info = utils.file_info(path)
        local valid = info and info.is_file and tonumber(info.size or 0) > 0
        callback(valid == true, valid and nil or L("hint.temp_missing"))
        return
    end
    local args={settings.ffprobe,"-v","error","-show_entries","stream=codec_type","-of","json",path}
    local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stdout=true,capture_stderr=true,args=args},function(success,res,err)
        job.async_id = nil
        if job.cancel_requested then callback(false,L("hint.task_cancelled")); return end
        if not (success and res and res.status==0) then callback(false,tostring((res and res.stderr) or err or "ffprobe failed")); return end
        local data=utils.parse_json(res.stdout or "")
        -- 解析失败不能伪装成"流缺失"（那是编码层结论，用户会朝错误方向排查）
        if type(data) ~= "table" then callback(false, "ffprobe output is not valid JSON: " .. tostring((res and res.stdout or ""):sub(1, 120))); return end
        local has_video,has_audio,has_subtitle=false,false,false
        for _,stream in ipairs(data.streams or {}) do
            if stream.codec_type=="video" then has_video=true
            elseif stream.codec_type=="audio" then has_audio=true
            elseif stream.codec_type=="subtitle" then has_subtitle=true end
        end
        if tracks.video~=nil and not has_video then callback(false,L("hint.missing_video_stream")); return end
        if tracks.audio~=nil and not has_audio then callback(false,L("hint.missing_audio_stream")); return end
        -- 外挂字幕不在源容器里，只有内嵌轨（tracks.subtitle）才在这里校验
        if tracks.subtitle~=nil and not has_subtitle then callback(false,L("hint.no_subtitle_track")); return end
        callback(true,nil)
    end)
    -- 异步启动失败时回调不会触发：不兜底会让合并流程卡在 validating
    if not ok_start then job.async_id=nil; callback(false, "subprocess async start failed: " .. tostring(start_err)); return end
    job.async_id = ok_start
end

-- ============================================================================
-- 去静音段：把片段减去静音区间，得到"只保留有声部分"的多段。
-- 纯函数（不碰 mp），可直接用 lupa 单测：输入片段表 + 静音区间表 + 设置，输出保留片段表。
-- 语义：
--   · silence_pad 是"静音两侧各留多少秒"，因此挖掉的是 [静音起点+pad, 静音终点−pad]；
--   · 短于 SILENCE_KEEP_MIN 的保留片段直接丢弃（否则会切出一堆没有意义的碎段）；
--   · 静音区间先裁到片段边界，跨片段的静音不会互相影响；
--   · 除了挖掉的那几段，时间轴端点一律不动，音画对齐不受影响。
-- 返回 (kept_segments, removed_count, removed_seconds)。
-- ============================================================================
local SILENCE_KEEP_MIN = 0.15

function M.knock_out_silence(segments, ranges, settings)
    settings = settings or {}
    local pad = math.max(0, tonumber(settings.silence_pad) or 0)
    local kept, removed, removed_seconds = {}, 0, 0
    for _, seg in ipairs(segments or {}) do
        local seg_start, seg_end = tonumber(seg.start_time), tonumber(seg.end_time)
        if seg_start and seg_end and seg_end > seg_start and seg.enabled ~= false then
            local cuts = {}
            for _, range in ipairs(ranges or {}) do
                local rs, re = tonumber(range.start), tonumber(range.stop)
                if rs and re and re > seg_start and rs < seg_end then
                    local from, to = math.max(rs, seg_start) + pad, math.min(re, seg_end) - pad
                    if to > from then cuts[#cuts + 1] = {from, to} end
                end
            end
            table.sort(cuts, function(a, b) return a[1] < b[1] end)
            local cursor = seg_start
            local function keep(from, to)
                if to - from >= SILENCE_KEEP_MIN then
                    kept[#kept + 1] = {start_time = from, end_time = to, enabled = true}
                end
            end
            for _, cut in ipairs(cuts) do
                local from = math.max(cut[1], cursor)
                if from > cursor then keep(cursor, from) end
                if cut[2] > cursor then
                    removed = removed + 1
                    removed_seconds = removed_seconds + math.min(cut[2], seg_end) - from
                end
                cursor = math.max(cursor, cut[2])
            end
            if seg_end > cursor then keep(cursor, seg_end) end
        end
    end
    return kept, removed, removed_seconds
end

local function make_export_plan(operation, source, queue, tracks, outdir)
    local dir, filename = utils.split_path(source)
    -- 去静音段：在计划层统一裁剪队列，逐段导出与合并导出自动共享同一份结果。
    -- 分析结果按源缓存；没有任何静音时保持原队列不动（silence 为 nil，调用方也不提示）。
    local plan_queue, silence = Editor.clone_segments(queue), nil
    -- 只对 video / audio 生效：图片序列与字幕的多段语义不同（字幕导出本身就禁止多段合并），
    -- 给它们做"挖静音"只会切出一堆无意义的输出
    local sil_kind = tostring(opts.output_kind or "video"):lower()
    if opts.remove_silence == true and (sil_kind == "video" or sil_kind == "audio") then
        local ranges = cached_analysis("silence", source)
        silence = {removed = 0, seconds = 0, kept = #plan_queue}
        if type(ranges) == "table" and #ranges > 0 then
            local kept, removed, removed_seconds = M.knock_out_silence(plan_queue, ranges, opts)
            silence = {removed = removed, seconds = removed_seconds, kept = #kept}
            if removed > 0 and #kept > 0 then plan_queue = kept
            elseif removed > 0 then silence.all = true end
        end
    end
    return {
        operation = operation,
        source_path = source,
        source_name = filename or source,
        source_dir = dir,
        source_duration = mp.get_property_number("duration", 0),
        queue = plan_queue,
        silence = silence,
        tracks = U.copy_value(tracks),
        settings = U.copy_value(opts),
        accurate_mode = Crop.effective_accurate_mode(opts,state.accurate_mode,operation),
        -- async_id 生命周期：command_native_async 的返回值（供 cancel_export 传给
        -- mp.abort_async_command）；回调开始执行时置 nil；各启动失败兜底点不赋值
        -- 请求模式快照：供回调基于 plan.settings 重算有效模式，避免把"有效模式"误当"请求模式"
        requested_accurate_mode = state.accurate_mode == true,
        manual_order = state.manual_order == true,
        output_dir = outdir,
        created_at = os.time(),
    }
end

-- 去除静音段的结果提示（逐段与合并共用）。整段都是静音时返回 false —— 调用方必须中止导出，
-- 否则会产出一个空文件。没有可去的静音时也要提示，避免"开了开关却什么都没发生"。
local function report_silence_plan(plan)
    if not plan.silence then return true end
    if plan.silence.all then show_hint(L("hint.silence_all"), 5, "error"); return false end
    if plan.silence.removed > 0 then
        show_hint(L("hint.silence_removed", plan.silence.removed, plan.silence.seconds,
            plan.silence.kept), 5)
    else
        show_hint(L("hint.silence_none", tostring(plan.settings.silence_db),
            tostring(plan.settings.silence_min)), 5)
    end
    return true
end

-- 无片段时合成"整片"片段：覆盖整个媒体时长，用于不剪辑直接转码。
local function whole_file_segment()
    local duration = mp.get_property_number("duration", 0)
    if duration <= 0 then return nil end
    return {id = "whole", start_time = 0, end_time = duration, enabled = true}
end

-- kind：video / audio / animated / image。四种类型复用同一套队列 / 进度 / 取消 / 诊断逻辑，
-- 只有命令构造与输出扩展名不同。
local function run_cut(kind)
    kind = kind or "video"
    if job.running or job.preparing then M.cancel_export(); return end
    local input = mp.get_property("path")
    if not U.valid_local_file(input) then show_hint(L("hint.not_local_file"),3,"error"); return end
    local queue = get_queue()
    if #queue == 0 and (state.start_time ~= nil or state.end_time ~= nil) then
        show_hint(L("hint.mark_not_added", deps.primary_key and deps.primary_key("add") or "Enter"),3,"error")
        return
    end
    -- 无片段：整片转码（不剪辑直接转码）
    if #queue == 0 then
        local whole = whole_file_segment()
        if not whole then show_hint(L("hint.whole_media_no_duration"),3,"error"); return end
        queue = {whole}
    end
    local source_path_snapshot = input
    -- 重新编码的最终判定在 check_ffmpeg 回调里基于 plan.settings 重算为 accurate_mode_snapshot；
    -- 此处仅声明局部变量供闭包赋值，避免重复计算
    local accurate_mode_snapshot
    local tracks = selected_tracks()
    -- 字幕导出只关心字幕轨：源里可能既没有视频也没有音频
    if kind == "subtitle" then
        if tracks.subtitle == nil and tracks.subtitle_external == nil and tracks.subtitle_first == nil then
            show_hint(L("hint.no_subtitle_track"),3,"error"); return
        end
    elseif tracks.video == nil and tracks.audio == nil then
        show_hint(L("hint.no_tracks"),3,"error"); return
    end
    -- 准备阶段（源流分析 / 响度黑边分析 / 数关键帧 / ffmpeg 能力探测）可达数十秒，
    -- 其间 job.running 还是 false：不置 preparing 的话，按钮仍显示"导出"，连点两下
    -- 会同时跑两条导出链，互相覆盖 job.async_id / temp 文件，且第一条无法停止。
    job.preparing, job.status = true, "preparing"
    check_ffmpeg_prepared(source_path_snapshot, kind, function(ok)
        job.preparing = nil   -- 回调入口就清：后面任何提前 return 都不会把界面锁在准备态
        -- 准备期按过取消（cancel_export 只置了标记，没有 ffmpeg 可 abort）：必须在这里收口，
        -- 否则取消之后照样跑一遍导出，看起来像"取消无效"。
        if job.cancel_requested then
            -- 不另发提示：按下取消时已经发过 hint.stopping_export，这里只需安静收口
            job.cancel_requested = false
            job.status, job.stage = "idle", nil
            request_render(true)
            return
        end
        -- ffmpeg 缺席时不再直接判死：mpv 自带 libavcodec/libavformat，能用它自己的
        -- 编码模式顶上"全部重新编码"这一条路。能力差距（无损复制 / 合并 / 两遍 /
        -- 字幕轨 / 拼图）已在下面逐项拒绝，这里只决定走哪条后端。
        local backend = "ffmpeg"
        if not ok then
            msg.info("quick_cut: ffmpeg unavailable, probing mpv binary for fallback backend")
            if not resolve_mpv_binary() then
                show_hint(L("hint.no_ffmpeg"),5,"error"); return
            end
            backend = "mpv"
            show_hint(L("hint.mpv_fallback"), 5)
            msg.info("quick_cut: ffmpeg not found, using mpv encode mode as fallback backend")
        end
        if mp.get_property("path") ~= source_path_snapshot then
            show_hint(L("hint.media_switched"), 4,"error")
            return
        end
        local dir, filename = utils.split_path(source_path_snapshot)
        local base, ext = filename:match("^(.-)(%.[^.]*)$")
        base, ext = base or filename, ext or ".mkv"
        local outdir = U.output_dir_for(dir)
        if not U.ensure_output_directory(outdir) then
            show_hint(L("hint.cannot_create_dir", tostring(outdir)), 5,"error")
            return
        end
        local plan = make_export_plan("export", source_path_snapshot, queue, tracks, outdir)
        -- 只写进 plan.settings 副本，不污染 opts
        plan.settings.output_kind = kind
        job.plan = plan
        job.last_output_dir = outdir
        queue,tracks=plan.queue,plan.tracks
        -- 用请求模式快照 + plan.settings 重算有效模式，语义正确且保持异步期间防御性
        accurate_mode_snapshot=Crop.effective_accurate_mode(plan.settings,plan.requested_accurate_mode,"export")
        plan.accurate_mode=accurate_mode_snapshot
        -- mpv 的编码模式没有 copy 编码器（--ovc=copy 报 codec 'copy' not found），实际一定
        -- 重新编码。把"复制"换成真实编码器，免得摘要/参数格与实际行为不符。面板打开时
        -- core.lua 已经纠正过一次，这里是绕过面板直接导出（export_confirmation=no）的兜底。
        if backend == "mpv" then
            if tostring(plan.settings.video_codec or "") == "copy" then
                plan.settings.video_codec = config.real_video_codec_for(plan.settings.encode_container)
            end
            if tostring(plan.settings.audio_codec or "") == "copy" then
                plan.settings.audio_codec = config.lossy_audio_for(plan.settings.encode_container)
            end
        end
        local out_ext
        if plan.settings.output_kind == "animated" then
            local afmt = tostring(plan.settings.animated_format or "gif"):lower()
            out_ext = "." .. tostring(config.ANIMATED_EXT[afmt] or afmt)
        elseif plan.settings.output_kind == "image" then
            local ifmt = tostring(plan.settings.image_format or "png"):lower()
            out_ext = "." .. tostring(config.IMAGE_EXT[ifmt] or ifmt)
        elseif plan.settings.output_kind == "subtitle" then
            local scodec = tostring(plan.settings.subtitle_codec or "srt"):lower()
            out_ext = "." .. tostring(config.SUBTITLE_EXT[scodec] or "srt")
        elseif plan.settings.output_kind == "audio" then
            -- 音频导出：扩展名由容器决定（m4a/mp3/opus/flac/wav/ogg）。落进下面的视频分支的话，
            -- fast_remux_ext 只认 mp4/mkv/mov/webm/ts → 返回 nil → 退回**源文件扩展名**，
            -- 用户设的容器被静默忽略（run_merge 侧本来就有这个分支，两条链要一致）。
            out_ext = "." .. tostring(plan.settings.encode_container):gsub("^%.", "")
        else
            -- 快速复制 + 目标容器与源不同：能原样装就 remux 过去，装不下就退回重新编码并说明原因
            -- （不静默忽略设置，也不交出"封装成功但播放器读不出音轨"的文件）。
            local container_ext, container_reason
            if not accurate_mode_snapshot then
                container_ext, container_reason = fast_remux_ext(source_path_snapshot, plan.settings)
                if container_reason then
                    accurate_mode_snapshot, plan.accurate_mode = true, true
                    show_hint(L("hint.container_needs_accurate",
                        tostring(plan.settings.encode_container), container_reason), 6)
                    msg.info("quick_cut container: fallback to precise (" .. tostring(container_reason) .. ")")
                elseif container_ext then
                    msg.info("quick_cut container: remux to " .. tostring(container_ext) .. " (stream copy)")
                end
            end
            out_ext = accurate_mode_snapshot and ("." .. tostring(plan.settings.encode_container):gsub("^%.",""))
                or (container_ext or ext)
        end
        -- 音量归一化：分析前置已测过才生效（copy 编码会被改成 aac），提示"源 x → 目标 y LUFS"
        local loud = apply_audio_normalization(plan.settings)
        if loud then
            show_hint(L("hint.loudness_applied", string.format("%.1f", loud.i),
                tostring(plan.settings.loudness_target_i)), 4)
        end
        -- copy 的音频若装不进目标容器，改成合法编码器（否则产物音轨读不出来）
        coerce_audio_copy_for_container(plan.settings)
        -- 同理，copy 的**视频**装不进目标容器时也必须换编码器（H.264 → webm 会直接写不出文件头）
        coerce_video_copy_for_container(plan.settings)
        -- 去静音段的结果提示（整段都是静音时必须中止，否则会产出空文件）
        if not report_silence_plan(plan) then return end

        -- mpv 兜底后端的能力缺口：逐项明确拒绝，而不是让用户拿到静默失败或半成品。
        --   快速复制 → mpv 没有 copy 编码器，只能重编码（告诉用户"已改用重新编码"）
        --   智能无损切割 → 依赖 concat 与流复制，做不到
        --   字幕导出 → mpv 没有字幕轨导出
        --   拼图 / 单帧 → 靠 ffmpeg 的 tile 滤镜与 -frames:v 1，mpv 侧做不到可靠替代
        --   限体积两遍 → mpv 没有 -pass
        --   变速 → 见下面的专项说明
        if backend == "mpv" then
            if kind == "subtitle" then
                show_hint(L("hint.mpv_no_subtitle_export"), 6, "error")
                request_render(true)
                return
            end
            -- 变速在 mpv 编码模式下做不出来（实测四种写法全部无效，见 build_mpv_trim_args
            -- 附近的说明）。这里直接拒绝：交出一份"画面快了但声音没快"的文件比拒绝更糟。
            if speed_active(plan.settings) then
                show_hint(L("hint.mpv_no_speed"), 6, "error")
                request_render(true)
                return
            end
            if kind == "image" and tostring(plan.settings.image_mode or ""):lower() ~= "sequence" then
                show_hint(L("hint.mpv_image_mode_unsupported"), 6, "error")
                request_render(true)
                return
            end
            if plan.settings.smart_cut == true then plan.settings.smart_cut = false end
            if not accurate_mode_snapshot then
                accurate_mode_snapshot, plan.accurate_mode = true, true
                show_hint(L("hint.mpv_requires_accurate"), 5)
                msg.info("quick_cut: mpv backend cannot stream-copy, switching to re-encode")
            end
        end

        -- 图片导出的产物形态只需判定一次（命名/提交/清理三处共用）
        local image_sequence = image_output_is_sequence(plan.settings)
        local total_duration = 0
        for _, seg in ipairs(queue) do total_duration = total_duration + (seg.end_time - seg.start_time) end
        -- 限体积目标：按总时长推导码率并启用两遍编码（仅视频；强制重新编码）。
        -- 合并导出（run_merge）走单遍 ABR 近似，见其内部同名分支。
        local size_two_pass = false
        if state.optimize_goal == "size" and tonumber(state.size_target) and kind == "video" then
            if not accurate_mode_snapshot then
                accurate_mode_snapshot = true
                plan.accurate_mode = true
            end
            local vkbps, akbps = M.size_bitrates(tonumber(state.size_target), total_duration)
            if not vkbps then
                show_hint(L("hint.size_target_too_small", tostring(state.size_target)), 5, "error")
                request_render(true)
                return
            end
            plan.settings.video_quality_mode = "bitrate"
            plan.settings.video_bitrate = string.format("%dk", vkbps)
            -- 与限体积冲突的组合先纠正：流复制无法控体积（老状态、脚本入口都可能带着 copy 进来）
            if tostring(plan.settings.video_codec or "") == "copy" then
                plan.settings.video_codec = config.real_video_codec_for(plan.settings.encode_container)
            end
            -- flac/copy 无法控体积，限体积下一律转为有损音频并按预算给码率
            local acodec = tostring(plan.settings.audio_codec or "")
            if acodec == "flac" or acodec == "copy" or acodec == "" then
                plan.settings.audio_codec = config.lossy_audio_for(plan.settings.encode_container)
            end
            plan.settings.audio_bitrate = string.format("%dk", akbps)
            size_two_pass = true
            show_hint(L("hint.size_bitrate", string.format("%dk", vkbps), string.format("%dk", akbps)), 5)
        end
        job.running, job.cancel_requested, job.current, job.total, job.succeeded, job.failed = true, false, 1, #queue, 0, 0
        job.smart_skip = nil   -- 上一轮的"智能切割没生效"不许带进这一次导出
        job.completed_duration, job.total_duration, job.overall_progress = 0, total_duration, 0
        job.source_path,job.status,job.operation,job.started_at=source_path_snapshot,"running","export",mp.get_time()
        job.stage,job.current_range,job.failure="exporting",nil,nil
        ensure_animation_timer()
        if accurate_mode_snapshot then show_hint(L("hint.prepare_precise", M.encode_summary()), 5) end
        -- 必须放在 accurate_mode_snapshot 算出来之后（前面读到的是 nil）。
        if plan.settings.smart_cut == true then
            if accurate_mode_snapshot then
                show_hint(L("hint.smart_cut_needs_fast"), 5)
            elseif (plan.settings.output_kind or "video") ~= "video" then
                show_hint(L("hint.smart_cut_video_only"), 5)
            end
        end
        show_hint(L("hint.output_dir", tostring(outdir)), 4)
        msg.info("quick_cut output directory: " .. tostring(outdir))
        request_render(true)
        local function next_one()
            if job.cancel_requested then finish_job(L("hint.task_export_stopped",task_kind_label()), L("hint.export_stopped_stat",job.succeeded,job.total)); return end
            if job.current > job.total then
                -- 收尾必须按"实际成功了几段"分流：无条件传 success=true 时，一段都没导出来
                -- 也会报"导出完成 / 成功 0/1"，还配一张成功样式的完成卡——用户看到"完成"
                -- 也会显示成功（输出目录不可写时就是这个表现）。
                local failed = job.failed or 0
                if failed == 0 then
                    finish_job(L("hint.task_export_done",task_kind_label()),L("hint.export_done_stat",job.succeeded,job.total,outdir),true); return
                elseif job.succeeded > 0 then
                    finish_job(L("hint.task_export_done",task_kind_label()),L("hint.export_partial_stat",job.succeeded,job.total,failed,outdir),true); return
                else
                    finish_job(L("hint.task_export_failed",task_kind_label()),L("hint.export_failed_stat",job.total,outdir),false); return
                end
            end

            local seg=queue[job.current]; job.stage="exporting"; job.current_range={start_time=seg.start_time,end_time=seg.end_time}
            -- 整片转码（无片段）时用源文件名作为基础名，unique_path 会追加 _cut 避免覆盖源文件
            local whole = seg.id == "whole"
            -- 片段被重命名过就用名字代替时间码（"take_1_002.mp4" 比 "_002_00h00m12s345-..." 好认）；
            -- 自定义名做文件名安全化（Windows 非法字符/结尾点/长度），未命名时保持原样
            local seg_name = tostring(seg.label or "")
            local custom_name = (not whole) and seg_name ~= "" and seg_name ~= L("hint.segment_label", seg.id)
            -- 命名模板只接管**未命名**片段（用户主动给的名字优先）；
            -- 模板非空时全项目都不再追加 _cut（否则"模板里没写 cut"自相矛盾）
            local tpl_on = tostring(opts.output_name_template or "") ~= ""
            local tpl_stem = (tpl_on and not custom_name) and U.apply_name_template(opts.output_name_template, {
                name = base, index = job.current,
                in_time = (not whole) and seg.start_time or nil,
                out_time = (not whole) and seg.end_time or nil,
            }) or nil
            local stem
            if tpl_stem then
                stem = tpl_stem
            elseif custom_name then
                stem = base .. string.format("_%03d_%s", job.current, U.safe_filename(seg_name, 40))
            else
                stem = whole and base or (base .. string.format("_%03d_%s-%s", job.current,
                    U.safe_time_token(seg.start_time), U.safe_time_token(seg.end_time)))
            end
            local cut_suffix = tpl_on and "" or nil
            -- 图片序列必须带序号模板，否则每一帧都会覆盖同一张图
            local output
            if kind == "image" then
                -- 序列必须带 %04d 序号模板；拼图/单帧是单文件，不能带模板
                if image_sequence then
                    output = U.unique_path(outdir, stem.."_%04d", out_ext, cut_suffix)
                elseif tostring(plan.settings.image_mode or ""):lower() == "single" then
                    output = U.unique_path(outdir, stem.."_frame", out_ext, cut_suffix)
                else
                    output = U.unique_path(outdir, stem.."_sheet", out_ext, cut_suffix)
                end
            else
                output = U.unique_path(outdir, stem, out_ext, cut_suffix)
            end
            local temp = U.temp_output_path(output)
            U.remove_file(temp)
            job.current_output, job.current_temp = output, temp
            local length = queue[job.current].end_time - queue[job.current].start_time
            -- 限体积目标：两遍编码的 passlog 放在工作目录，提交/失败/取消后清理
            local passlog
            if size_two_pass then
                passlog = utils.join_path(utils.split_path(temp), string.format("qc_pass_%03d", job.current))
            end
            local function cleanup_passlog()
                if not passlog then return end
                for _, suffix in ipairs({"-0.log", "-0.log.mbtree"}) do
                    local ok, err = os.remove(passlog..suffix)
                    if not ok and err and not err:match("No such") then
                        msg.warn("quick_cut: passlog cleanup failed: " .. tostring(passlog..suffix) .. "; " .. tostring(err))
                    end
                end
            end
            -- start_encode(run_pass)：nil=单遍；1/2=两遍的第一/第二遍（第一遍输出到 null 丢弃、不编码音频）。
            -- 成功提交与进度推进只在"单遍成功"或"第二遍成功"后执行。
            local function start_encode(run_pass)
                plan.settings.two_pass = run_pass
                plan.settings.passlogfile = passlog
                -- 兜底后端只用单遍编码（mpv 没有 -pass），两遍的调用不会出现，
                -- 但这里仍按 backend 选构建器，语义更直白。
                local args, build_err
                if backend == "mpv" then
                    args, build_err = build_mpv_trim_args(source_path_snapshot,
                        run_pass == 1 and NULL_OUT or temp, queue[job.current], tracks, plan.settings)
                else
                    args, build_err = build_trim_args(source_path_snapshot, run_pass == 1 and NULL_OUT or temp, queue[job.current], accurate_mode_snapshot, tracks, plan.settings)
                end
                if not args then
                    U.remove_file_later(temp,1)
                    U.log_error(build_err)
                    -- 诊断文件路径必须进提示：用户拿不到它，反馈问题时只能贴一句"导出失败"
                    local diag=U.write_failure_diagnostic("export",source_path_snapshot,output,queue,{},build_err,outdir,{
                        stage="building",index=job.current,total=job.total,
                        segment={start_time=seg.start_time,end_time=seg.end_time}
                    })
                    show_hint(L("hint.export_setting_error", tostring(build_err))..(diag and (L("hint.diag_note")..diag) or ""),5,"error")
                    job.failed = job.failed + 1
                    job.completed_duration=job.completed_duration+length
                    if job.total_duration>0 then job.overall_progress=math.min(1,job.completed_duration/job.total_duration) end
                    job.current_output,job.current_temp=nil,nil
                    job.current=job.current+1
                    request_render(true); next_one(); return
                end
                -- -an 是**输出选项**，必须在输出路径之前：append 到末尾时，
                -- add_progress_args 的 table.remove(args) 会把 -an 当成输出路径取走，
                -- 真正的输出路径被丢弃 → ffmpeg 报 "Trailing option(s)"，限体积导出 100% 失败。
                if run_pass == 1 then table.insert(args, #args, "-an") end  -- 第一遍不编码音频，省时
                -- 进度文件是 ffmpeg 的 -progress 语法，mpv 不认识（传给 mpv 会变成非法选项），
                -- 所以 mpv 后端跳过多余参数：进度只能显示"正在导出"而不能给出百分比。
                if backend ~= "mpv" then
                    add_progress_args(args, start_progress_monitor(temp, length))
                end
                job.stage = run_pass and ("pass"..run_pass) or "exporting"
                show_hint(run_pass and L("hint.exporting_pass",job.current,job.total,run_pass) or L("hint.exporting_segment",job.current,job.total),2)
                local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stderr=true,args=args}, function(success,res,err)
                    job.async_id = nil
                    stop_progress_monitor(true)
                    -- 取消时保存下来的进度文件路径：进程已退出，此刻删除才有效
                    if job.cancel_progress_file then
                        U.remove_file_later(job.cancel_progress_file,1)
                        job.cancel_progress_file = nil
                    end
                    if job.cancel_requested then
                        -- image 的 temp 是模板路径，残留帧必须用序列清理
                        if image_sequence then U.remove_image_sequence(temp) else U.remove_file_later(temp,1) end
                        cleanup_passlog()
                        next_one()
                        return
                    end
                    if not (success and res and res.status == 0) then
                        -- ffmpeg 失败（两遍任一遍）也可能已写出部分帧，image 模板同样需要序列清理
                        if image_sequence then U.remove_image_sequence(temp) else U.remove_file_later(temp,1) end
                        cleanup_passlog()
                        local short = U.truncate_chars(tostring((res and res.stderr) or err or "unknown"):gsub("[\r\n]+", " "), 160, true)
                        U.log_error(string.format("ffmpeg failed; input=%s; output=%s; range=%.6f-%.6f; mode=%s; pass=%s; error=%s",
                            tostring(source_path_snapshot), tostring(output), queue[job.current].start_time, queue[job.current].end_time,
                            accurate_mode_snapshot and "accurate" or "copy", tostring(run_pass or "single"), tostring((res and res.stderr) or err or "unknown")))
                        local diag=U.write_failure_diagnostic("export",source_path_snapshot,output,queue,args,(res and res.stderr) or err,outdir,{
                            stage=run_pass and ("pass"..run_pass) or "exporting", index=job.current, total=job.total,
                            segment={start_time=queue[job.current].start_time,end_time=queue[job.current].end_time}
                        })
                        show_hint((accurate_mode_snapshot and L("hint.precise_failed") or L("hint.export_failed")) .. short
                            .. (diag and (L("hint.diag_note")..diag) or ""), 6,"error")
                        job.failed = job.failed + 1
                        job.completed_duration = job.completed_duration + length
                        if job.total_duration > 0 then job.overall_progress = math.min(1, job.completed_duration / job.total_duration) end
                        job.current_output, job.current_temp = nil, nil
                        job.stage="exporting"
                        job.current = job.current + 1
                        request_render(true)
                        next_one()
                        return
                    end
                    if run_pass == 1 then
                        -- 第一遍完成：接着跑第二遍（进度在该片段第二遍结束后才累计）
                        request_render(true)
                        start_encode(2)
                        return
                    end
                    job.stage="committing"; request_render(true)
                    -- 图片序列的 temp/final 都是 %04d 模板路径，file_info 永远查不到、rename 无法
                    -- 直接作用于模板，必须按帧号逐个提交；其余类型沿用单文件验收。
                    -- commit_why 区分三种收尾：nil=成功，"empty"=产物本身是空的（编码没出帧），
                    -- "commit"=产物有内容但提交（rename/写目标）失败。原来两种失败共用
                    -- hint.output_empty，用户按"产出为空"去查，方向从一开始就是错的。
                    local committed, commit_why
                    if image_sequence then
                        committed = U.commit_image_sequence(temp, output)
                        commit_why = committed and nil or "commit"
                    else
                        local info = utils.file_info(temp)
                        local had_bytes = (info and tonumber(info.size) or 0) > 0
                        committed = had_bytes and U.commit_output(temp, output) or false
                        commit_why = committed and nil or (had_bytes and "commit" or "empty")
                    end
                    if committed then
                        job.succeeded = job.succeeded + 1
                        job.last_output, job.last_output_dir = output, outdir
                    else
                        -- image 模板路径上的残留帧用序列清理；最终位置已提交的帧同样要清，
                        -- 否则残留帧会让下一次提交在同名目标上 rename 失败、误导排查方向；
                        -- 单文件的 .part 延迟删除即可
                        if image_sequence then
                            U.remove_image_sequence(temp)
                            U.remove_image_sequence(output)
                        else U.remove_file_later(temp,1) end
                        local commit_err=L(commit_why == "commit" and "hint.commit_failed" or "hint.output_empty")
                        U.log_error(commit_err..": "..output)
                        local diag=U.write_failure_diagnostic("export",source_path_snapshot,output,queue,args,commit_err,outdir,{
                            stage="committing",index=job.current,total=job.total,
                            segment={start_time=seg.start_time,end_time=seg.end_time}
                        })
                        show_hint(commit_err..(diag and (L("hint.diag_note")..diag) or ""),5,"error")
                        job.failed = job.failed + 1
                    end
                    cleanup_passlog()
                    job.completed_duration = job.completed_duration + length
                    if job.total_duration > 0 then job.overall_progress = math.min(1, job.completed_duration / job.total_duration) end
                    job.current_output, job.current_temp = nil, nil
                    job.stage="exporting"
                    job.current = job.current + 1
                    request_render(true)
                    next_one()
                end)
                -- 异步启动失败时上面的回调永远不会触发：不兜底会让 job.running 永久卡死
                if not ok_start then
                    stop_progress_monitor(true)
                    if image_sequence then U.remove_image_sequence(temp) else U.remove_file_later(temp,1) end
                    cleanup_passlog()
                    local err_text = "subprocess async start failed: " .. tostring(start_err)
                    U.log_error(string.format("ffmpeg async start failed; input=%s; output=%s; error=%s",
                        tostring(source_path_snapshot), tostring(output), err_text))
                    local diag=U.write_failure_diagnostic("export",source_path_snapshot,output,queue,args,err_text,outdir,{
                        stage="starting", index=job.current, total=job.total,
                        segment={start_time=queue[job.current].start_time,end_time=queue[job.current].end_time}
                    })
                    show_hint(L("hint.export_failed") .. err_text .. (diag and (L("hint.diag_note")..diag) or ""), 6, "error")
                    job.failed = job.failed + 1
                    job.completed_duration = job.completed_duration + length
                    if job.total_duration > 0 then job.overall_progress = math.min(1, job.completed_duration / job.total_duration) end
                    job.current_output, job.current_temp = nil, nil
                    job.stage="exporting"
                    job.current = job.current + 1
                    request_render(true); next_one(); return
                end
                job.async_id = ok_start
            end
            -- 智能无损切割：把这一段拆成「头部重编码 → 尾部流复制 → concat」三步。
            -- 任何一步失败都退回常规单次编码（记日志 + 提示），不让"优化"把整次导出搞失败。
            local function run_smart_segment(smart)
                local work = U.work_directory(outdir)
                -- 文件名用 stem（= base + 片段标记，:1938 处算出），与逐段路径同源。
                local head = utils.join_path(work, stem..".smart_head.mkv")
                local tail = utils.join_path(work, stem..".smart_tail.mkv")
                local list_path = utils.join_path(work, stem..".smart.concat.txt")
                U.remove_file(head); U.remove_file(tail)
                job.work_files = job.work_files or {}
                table.insert(job.work_files, head); table.insert(job.work_files, tail)
                job.concat_list = list_path
                local head_length = smart.head_end - smart.head_start
                local tail_length = smart.tail_end - smart.head_end
                local function cleanup_parts()
                    U.remove_file_later(head,1); U.remove_file_later(tail,1); U.remove_file_later(list_path,1)
                end
                local function fallback(reason)
                    msg.warn("quick_cut: smart cut fallback (" .. tostring(reason) .. ")")
                    show_hint(L("hint.smart_cut_fallback", tostring(reason)), 4, "error")
                    cleanup_parts()
                    job.stage = "exporting"; job.current_temp = temp
                    start_encode(size_two_pass and 1 or nil)
                end
                -- 跑一条命令：成功走 on_done，失败/取消走各自分支
                local function run_step(args, progress_length, on_done)
                    add_progress_args(args, start_progress_monitor(job.current_temp or temp, progress_length))
                    local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stderr=true,args=args},
                        function(success, res, err)
                            job.async_id = nil
                            stop_progress_monitor(true)
                            if job.cancel_requested then cleanup_parts(); next_one(); return end
                            if not (success and res and res.status == 0) then
                                local short = U.truncate_chars(tostring((res and res.stderr) or err or "unknown"):gsub("[\r\n]+", " "), 160, true)
                                return fallback(short)
                            end
                            on_done()
                        end)
                    if not ok_start then
                        stop_progress_monitor(true)
                        return fallback("subprocess async start failed: " .. tostring(start_err))
                    end
                    job.async_id = ok_start
                end

                job.stage = "exporting"
                show_hint(L("hint.smart_cut_applied", string.format("%.2f", head_length)), 4)
                msg.info(string.format(
                    "quick_cut smart cut: head=%.3f-%.3f tail=%.3f-%.3f encoder=%s pix_fmt=%s profile=%s",
                    smart.head_start, smart.head_end, smart.head_end, smart.tail_end,
                    tostring(smart.encoder), tostring(smart.pix_fmt), tostring(smart.profile)))
                job.current_temp = head
                run_step(build_smart_head_args(source_path_snapshot, head, smart.head_start, smart.head_end, tracks, plan.settings, smart), head_length, function()
                    job.current_temp = tail
                    run_step(build_smart_tail_args(source_path_snapshot, tail, smart.head_end, smart.tail_end, tracks, plan.settings), tail_length, function()
                        -- concat：与合并导出同一套写法（写盘结果必须检查，磁盘满会生成截断的列表）
                        local f = io.open(list_path, "w")
                        if not f then return fallback("cannot write concat list") end
                        -- duration 指令：告诉 concat 用"我们知道的确切长度"去排下一片。
                        -- 不写时偏移量取自各分片的容器时长，而头片的容器时长由 aac 编码器延迟
                        -- （音频起点 -0.023）与尾帧填充撑大，比视频实际结束点长约 0.04s ——
                        local wrote = f:write("file '", U.escape_concat_path(head), "'\n")
                        wrote = wrote and f:write(string.format("duration %.6f\n", smart.head_end - smart.head_start))
                        wrote = wrote and f:write("file '", U.escape_concat_path(tail), "'\n")
                        wrote = wrote and f:write(string.format("duration %.6f\n", smart.tail_end - smart.head_end))
                        local closed = f:close()
                        -- 写盘结果必须检查：磁盘满/权限问题会生成截断的 concat 列表
                        if not wrote or not closed then return fallback("cannot write concat list") end
                        local args = {plan.settings.ffmpeg,"-y","-hide_banner","-loglevel","error",
                            "-f","concat","-safe","0","-i",list_path,"-c","copy"}
                        local container = tostring(plan.settings.encode_container or ""):lower():gsub("^%.","")
                        if plan.settings.faststart and (container == "mp4" or container == "mov") then
                            table.insert(args,"-movflags"); table.insert(args,"+faststart")
                        end
                        table.insert(args, temp)
                        job.stage = "joining"; job.current_temp = temp
                        run_step(args, length, function()
                            local info = utils.file_info(temp)
                            if not (info and info.size > 0) then return fallback("concat output empty") end
                            if not U.commit_output(temp, output) then return fallback("commit failed") end
                            job.succeeded = job.succeeded + 1
                            job.last_output, job.last_output_dir = output, outdir
                            cleanup_parts()
                            job.completed_duration = job.completed_duration + length
                            if job.total_duration > 0 then job.overall_progress = math.min(1, job.completed_duration / job.total_duration) end
                            job.current_output, job.current_temp = nil, nil
                            job.stage = "exporting"
                            job.current = job.current + 1
                            request_render(true)
                            next_one()
                        end)
                    end)
                end)
            end

            -- 只在快速复制（无重编码、非两遍、非精确）下尝试；不适用就静默走常规方式
            if not size_two_pass and not accurate_mode_snapshot and plan.settings.smart_cut == true then
                local smart, reason = smart_cut_segment_plan(source_path_snapshot, seg, plan.settings, plan.tracks)
                if smart then
                    run_smart_segment(smart)
                    return
                elseif reason and reason ~= "off" and reason ~= "aligned" then
                    -- 智能切割一旦放弃，这条片段就走前置 -ss + -c copy：ffmpeg 会把起点
                    -- 回退到前一个关键帧，成品内容整体前移。记下来给完成通知用
                    -- （"aligned" 表示入点本就贴关键帧，回退幅度为 0，不算风险）。
                    job.smart_skip = job.smart_skip or reason
                    if job.current == 1 then
                        show_hint(L("hint.smart_cut_fallback", L(reason)), 4, "error")
                        msg.info("quick_cut smart cut skipped: " .. tostring(reason))
                    end
                end
            end
            start_encode(size_two_pass and 1 or nil)
        end
        next_one()
    end)
end
M.run_cut = run_cut

local function run_merge(kind)
    kind = kind or "video"
    if job.running or job.preparing then M.cancel_export(); return end
    -- 必须在下面的智能切割判定之前清：合并路径先判 smart cut（:2392 会写 job.smart_skip）、
    -- 之后才把 job.running 置 true，所以重置不能放在那个赋值旁边。
    job.smart_skip = nil
    local input,queue=mp.get_property("path"),get_queue()
    if not U.valid_local_file(input) then show_hint(L("hint.not_local_file"),3,"error"); return end
    -- 无片段：整片转码（不剪辑直接转码）
    if #queue==0 then
        local whole=whole_file_segment()
        if not whole then show_hint(L("hint.whole_media_no_duration"),4,"error"); return end
        queue={whole}
    end
    local source=input; local tracks=selected_tracks()
    if kind == "subtitle" then
        if tracks.subtitle==nil and tracks.subtitle_external==nil and tracks.subtitle_first==nil then
            show_hint(L("hint.no_subtitle_track"),3,"error"); return
        end
        -- 字幕没有可拼接的时间轴语义：concat 会把两段字幕首尾直接相连，时间戳全部错位
        if #queue > 1 then show_hint(L("hint.subtitle_no_merge"),5,"error"); return end
    elseif kind == "image" then
        -- merge 路径写的是普通单文件路径：序列模式会变成"每帧覆盖同一张图"，多段拼接更不成立
        local image_mode = tostring(opts.image_mode or "sequence"):lower()
        if image_mode ~= "tile" or #queue > 1 then
            show_hint(L("hint.image_no_merge"),5,"error"); return
        end
    elseif tracks.video==nil and tracks.audio==nil then
        show_hint(L("hint.no_tracks_merge"),3,"error"); return
    end
    -- 走 prepared 版本：启用智能切割时它会把「源流参数 + 关键帧位置」这两项前置分析先跑完，
    -- 否则合并路径里的落点判定拿不到数据（只会得到"源编码不支持"这种误判）
    job.preparing, job.status = true, "preparing"
    check_ffmpeg_prepared(source, kind, function(ok)
        job.preparing = nil
        if not ok then show_hint(L("hint.no_ffmpeg_short"),4,"error"); return end
        if mp.get_property("path")~=source then show_hint(L("hint.media_switched_merge"),4,"error"); return end
        local dir,filename=utils.split_path(source); local base=filename:match("^(.-)%.[^.]*$") or filename
        local outdir=U.output_dir_for(dir); if not U.ensure_output_directory(outdir) then show_hint(L("hint.cannot_access_output"),4,"error"); return end
        local plan=make_export_plan("merge",source,queue,tracks,outdir); job.plan=plan
        job.last_output_dir=outdir
        plan.settings.output_kind = kind
        -- 合并路径同样支持音量归一化（分析前置已测过才生效）
        local loud = apply_audio_normalization(plan.settings)
        if loud then
            show_hint(L("hint.loudness_applied", string.format("%.1f", loud.i),
                tostring(plan.settings.loudness_target_i)), 4)
        end
        -- 与逐段路径同源：copy 音频装不进目标容器时改成合法编码器
        coerce_audio_copy_for_container(plan.settings)
        coerce_video_copy_for_container(plan.settings)   -- 合并链同理：视频 copy 装不进容器也要换编码器
        -- 去静音段的结果提示（整段都是静音时必须中止，否则会产出空文件）
        if not report_silence_plan(plan) then return end

        queue,tracks=plan.queue,plan.tracks
        -- 非视频类型用各自格式的扩展名，不套 encode_container
        local ext
        if kind == "animated" then
            local afmt=tostring(plan.settings.animated_format or "gif"):lower()
            ext="."..tostring(config.ANIMATED_EXT[afmt] or afmt)
        elseif kind == "image" then
            local ifmt=tostring(plan.settings.image_format or "png"):lower()
            ext="."..tostring(config.IMAGE_EXT[ifmt] or ifmt)
        elseif kind == "subtitle" then
            local scodec=tostring(plan.settings.subtitle_codec or "srt"):lower()
            ext="."..tostring(config.SUBTITLE_EXT[scodec] or "srt")
        else
            ext="."..tostring(plan.settings.encode_container):gsub("^%.","")
        end
        -- 整片转码（无片段）时用源文件名作为基础名，unique_path 会追加 _cut 避免覆盖源文件
        local whole = #queue==1 and queue[1].id=="whole"
        -- 合并也带片段名（与单段导出同一套规则）：有自定义名 → base_名字1+名字2+…；
        -- 全都没命名 → 保持原来的 base_merged_Nclips。（名字与单段一样先做文件名安全化）
        -- 未命名用空串而不是 nil：nil 会在数组里留空洞，Lua 的 ipairs 遇到空洞就停，
        -- 摘要会静默丢掉后面的片段（单测踩到过）
        local merge_names = {}
        for i, seg in ipairs(queue) do
            local lab = tostring(seg.label or "")
            merge_names[i] = (lab ~= "" and lab ~= L("hint.segment_label", seg.id)) and lab or ""
        end
        -- 命名模板启用时同样去掉 _cut（名字主体仍由 merge_output_base 按片段名生成）
        local tpl_on = tostring(opts.output_name_template or "") ~= ""
        local output=U.unique_path(outdir, U.merge_output_base(base, merge_names, whole, 48), ext,
            tpl_on and "" or nil)
        local final_temp=U.temp_output_path(output); U.remove_file(final_temp)
        local work=U.work_directory(outdir); local total=0; for _,seg in ipairs(queue) do total=total+(seg.end_time-seg.start_time) end
        -- 限体积目标（合并路径）：按总时长推导码率，单遍 ABR 近似（分段编码暂不做两遍）
        if state.optimize_goal == "size" and tonumber(state.size_target) and kind == "video" then
            local vkbps, akbps = M.size_bitrates(tonumber(state.size_target), total)
            if not vkbps then
                show_hint(L("hint.size_target_too_small", tostring(state.size_target)), 5, "error")
                request_render(true); return
            end
            plan.settings.video_quality_mode = "bitrate"
            plan.settings.video_bitrate = string.format("%dk", vkbps)
            local acodec = tostring(plan.settings.audio_codec or "")
            if acodec == "flac" or acodec == "copy" or acodec == "" then
                plan.settings.audio_codec = config.lossy_audio_for(plan.settings.encode_container)
            end
            plan.settings.audio_bitrate = string.format("%dk", akbps)
            show_hint(L("hint.size_bitrate", string.format("%dk", vkbps), string.format("%dk", akbps)) .. L("hint.size_merge_singlepass"), 5)
        end
        -- 有效模式：与逐段路径同源，在**限体积分支之后**重算（那一支会把质量模式改成 bitrate，
        -- 而码率目标必须重新编码）。合并走快速复制时逐段流复制、最后 concat，入点会对齐到
        -- 关键帧（与逐段快速复制同一套语义），因此提示里说清楚。
        local merge_accurate = Crop.effective_accurate_mode(plan.settings, plan.requested_accurate_mode, "merge")
        -- 换容器：合并路径的扩展名本来就跟随 encode_container，所以这里只需要判断"源编码装不装得进去"。
        -- 装不下就退回重新编码（否则逐段流复制会直接失败，或产出播放器读不出音轨的文件）。
        local merge_container_reason
        if not merge_accurate then
            local _, reason = fast_remux_ext(source, plan.settings)
            if reason then
                merge_accurate = true
                merge_container_reason = reason
                plan.accurate_mode = true
                show_hint(L("hint.container_needs_accurate", tostring(plan.settings.encode_container), reason), 6)
                msg.info("quick_cut container (merge): fallback to precise (" .. tostring(reason) .. ")")
            end
        end
        plan.accurate_mode = merge_accurate
        if not merge_accurate then
            show_hint(L("hint.merge_copy_mode"), 5)
            msg.info("quick_cut merge: fast mode (stream copy per segment + concat)")
        end
        -- 合并 + 智能切割：每段拆「头重编码 + 尾流复制」两片，交给下面同一套 concat_all 缝合。
        -- 尾部是原样复制，整段加工（裁剪 / 缩放 / 帧率 / 去隔行 / 响度 / 码率）它一概吃不到，
        -- 而合并又要求所有分片参数一致，所以这里做一次**全队列**判定：要么每段都能拆，
        -- 要么整段重编码——并说清是哪个设置挡住的（不再静默忽略开关）。
        local smart_plans, smart_skip_reason, smart_skip_index
        if plan.settings.smart_cut == true and merge_accurate then
            -- 重新编码 + 合并：智能切割是"流复制"技巧，分片（拷贝）与重编码分片缝不到一起。
            -- 于是"重新编码 + 合并 + 智能切割"会把两种分片混进同一个 concat。
            show_hint(L("hint.smart_cut_needs_fast"), 5)
            msg.info("quick_cut smart cut (merge) skipped: precise mode")
        elseif plan.settings.smart_cut == true then
            local blocker = smart_cut_merge_blocker(plan.settings)
            if blocker then
                smart_skip_reason = blocker
            else
                smart_plans, smart_skip_reason, smart_skip_index =
                    smart_cut_merge_plans(source, queue, plan.settings, tracks)
            end
            if smart_skip_reason and smart_skip_reason ~= "off" then
                -- 与单段路径同理：合并段一旦退回流复制，起点同样会回退到关键帧。
                job.smart_skip = job.smart_skip or smart_skip_reason
                if smart_skip_index then
                    show_hint(L("hint.smart_cut_merge_segment", smart_skip_index, L(smart_skip_reason)), 6)
                else
                    show_hint(L("hint.smart_cut_merge_blocked", L(smart_skip_reason)), 6)
                end
                msg.info(string.format("quick_cut smart cut (merge) skipped: %s%s", tostring(smart_skip_reason),
                    smart_skip_index and (" (segment " .. tostring(smart_skip_index) .. ")") or ""))
            elseif smart_plans then
                msg.info(string.format("quick_cut smart cut (merge): %d segment(s) will be split into head+tail",
                    #smart_plans))
            end
        end
        job.running,job.cancel_requested,job.current,job.total,job.succeeded=true,false,1,#queue,0
        job.completed_duration,job.total_duration,job.overall_progress=0,total,0
        job.source_path,job.status,job.operation,job.started_at=source,"preparing","merge",mp.get_time()
        job.stage,job.current_range,job.failure="preparing",nil,nil
        job.current_output,job.current_temp=output,nil; job.work_files={}; job.work_durations={}; job.concat_list=nil
        ensure_animation_timer(); request_render(true)
        local function fail(args,err,stage,index,segment,validation)
            job.failure={stage=stage or job.stage,index=index,total=#queue,segment=segment,validation=validation}
            stop_progress_monitor(true); cleanup_job_files(); U.remove_file_later(final_temp,1)
            local diag=U.write_failure_diagnostic("merge",source,output,queue,args,err,outdir,job.failure)
            local where=index and L("hint.segment_where",index,#queue) or (stage or L("hint.unknown_stage"))
            local range=segment and (" · "..U.format_time(segment.start_time).." → "..U.format_time(segment.end_time)) or ""
            finish_job(L("hint.merge_failed",task_kind_label()),where..range..(diag and (L("hint.diag_note")..diag) or ""))
        end
        local function concat_all()
            if job.cancel_requested then cleanup_job_files(); finish_job(L("hint.merge_stopped",task_kind_label()),L("hint.no_output_generated")); return end
            job.status,job.stage,job.current,job.total="joining","joining",#queue,#queue
            job.current_range=nil
            local list_path=utils.join_path(work,base.."_"..os.date("%H%M%S")..".concat.txt"); job.concat_list=list_path
            local f=io.open(list_path,"w"); if not f then fail({},L("hint.concat_failed"),"joining"); return end
            local wrote = f
            for i,path in ipairs(job.work_files) do
                if wrote then wrote = f:write("file '",U.escape_concat_path(path),"'\n") end
                -- 智能切割分片带上确切时长（原因见 run_cut 侧 concat 列表的说明）。只写我们
                -- 确定边界的分片：普通重编码分片的真实时长与段长可能差一帧，写错反而会造出空洞。
                local known = job.work_durations and job.work_durations[i]
                if wrote and known then wrote = f:write(string.format("duration %.6f\n", known)) end
            end
            -- 写盘结果必须检查：磁盘满/权限问题会生成截断的 concat 列表，ffmpeg 随后
            -- 报出指向不相关方向的错误（对照 session.lua 的写检查范本）
            local closed = f:close()
            if not wrote or not closed then fail({},L("hint.concat_failed"),"joining"); return end
            local args={plan.settings.ffmpeg,"-y","-hide_banner","-loglevel","error","-f","concat","-safe","0","-i",list_path,"-c","copy"}
            local container=tostring(plan.settings.encode_container):lower():gsub("^%.","")
            if plan.settings.faststart and (container=="mp4" or container=="mov") then table.insert(args,"-movflags"); table.insert(args,"+faststart") end
            table.insert(args,final_temp); request_render(true)
            local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stderr=true,args=args},function(success,res,err)
                job.async_id=nil
                if job.cancel_requested then cleanup_job_files(); U.remove_file_later(final_temp,1); finish_job(L("hint.merge_stopped",task_kind_label()),L("hint.no_output_generated")); return end
                local info=utils.file_info(final_temp)
                if success and res and res.status==0 and info and info.size>0 and U.commit_output(final_temp,output) then
                    cleanup_job_files(); job.succeeded=1; job.last_output,job.last_output_dir=output,outdir
                    finish_job(L("hint.merge_done",task_kind_label()),output,true)
                else fail(args,(res and res.stderr) or err,"joining") end
            end)
            -- 异步启动失败时回调不会触发：走统一失败路径，避免 job.running 卡死
            if not ok_start then job.async_id=nil; fail(args, "subprocess async start failed: " .. tostring(start_err), "joining"); return end
            job.async_id = ok_start
        end
        -- 智能切割分片（合并路径）：头重编码 + 尾流复制，两片都进 work_files，由 concat_all 统一缝合。
        -- 单步失败**不**退回本段重编码：合并要求各分片参数一致，前面几段已经是智能分片，
        -- 中途插入一段"用户参数重编码"会让整份文件缝不起来——所以直接说清原因并终止。
        local encode_next   -- 前向声明：本函数收尾时要接着排下一段
        local function smart_encode_segment(seg, smart, segment_index)
            local length = seg.end_time - seg.start_time
            local head_length = smart.head_end - smart.head_start
            local tail_length = smart.tail_end - smart.head_end
            local head = utils.join_path(work, string.format("%s.merge.%03d.head.mkv", base, segment_index))
            local tail = utils.join_path(work, string.format("%s.merge.%03d.tail.mkv", base, segment_index))
            U.remove_file(head); U.remove_file(tail)
            table.insert(job.work_files, head); table.insert(job.work_files, tail)
            -- 与 work_files 一一对应（concat 列表按同索引取时长）；普通分片留空，不写 duration
            job.work_durations = job.work_durations or {}
            table.insert(job.work_durations, head_length); table.insert(job.work_durations, tail_length)
            job.status = "encoding"
            msg.info(string.format("quick_cut smart cut (merge segment %d): head=%.3f-%.3f tail=%.3f-%.3f "
                .. "encoder=%s pix_fmt=%s profile=%s audio=%s", segment_index,
                smart.head_start, smart.head_end, smart.head_end, smart.tail_end,
                tostring(smart.encoder), tostring(smart.pix_fmt), tostring(smart.profile), tostring(smart.audio_encoder)))

            local function abort(args, err)
                msg.warn(string.format("quick_cut: smart cut (merge) failed on segment %d: %s",
                    segment_index, tostring(err)))
                show_hint(L("hint.smart_cut_merge_failed", segment_index), 6, "error")
                fail(args or {}, err, "encoding", segment_index, seg)
            end
            -- 跑一条命令 + 校验产物：与常规分段同等的保证（空文件 / 流缺失都在这拦住）
            local function step(args, path, progress_length, next_step)
                job.current_temp = path
                add_progress_args(args, start_progress_monitor(path, progress_length)); request_render(true)
                local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stderr=true,args=args},
                    function(success, res, err)
                        job.async_id = nil; stop_progress_monitor(true)
                        if job.cancel_requested then
                            cleanup_job_files(); finish_job(L("hint.merge_stopped",task_kind_label()),L("hint.no_output_generated")); return
                        end
                        local info = utils.file_info(path)
                        if not (success and res and res.status == 0 and info and info.size > 0) then
                            U.remove_file_later(path,1); abort(args, (res and res.stderr) or err); return
                        end
                        job.stage = "validating"; request_render(true)
                        validate_media_async(path, tracks, plan.settings, function(valid, validation_err)
                            if job.cancel_requested then
                                cleanup_job_files(); finish_job(L("hint.merge_stopped",task_kind_label()),L("hint.no_output_generated")); return
                            end
                            if not valid then U.remove_file_later(path,1); abort(args, validation_err); return end
                            next_step()
                        end)
                    end)
                -- 异步启动失败时回调不会触发：不兜底会让 job.running 永久卡死
                if not ok_start then
                    stop_progress_monitor(true); U.remove_file_later(path,1)
                    abort(args, "subprocess async start failed: " .. tostring(start_err)); return
                end
                job.async_id = ok_start
            end

            step(build_smart_head_args(source, head, smart.head_start, smart.head_end, tracks, plan.settings, smart),
                head, head_length, function()
                    step(build_smart_tail_args(source, tail, smart.head_end, smart.tail_end, tracks, plan.settings),
                        tail, tail_length, function()
                            job.completed_duration = job.completed_duration + length
                            job.overall_progress = math.min(.98, job.completed_duration / math.max(.001, job.total_duration))
                            job.succeeded = job.succeeded + 1
                            job.current = segment_index + 1
                            job.stage = "encoding"; request_render(true)
                            encode_next()
                        end)
                end)
        end

        encode_next = function()
            if job.cancel_requested then cleanup_job_files(); finish_job(L("hint.merge_stopped",task_kind_label()),L("hint.no_output_generated")); return end
            if job.current>#queue then concat_all(); return end
            local seg=queue[job.current]; local segment_index=job.current; local length=seg.end_time-seg.start_time
            job.stage="encoding"; job.current_range={start_time=seg.start_time,end_time=seg.end_time}
            -- 智能切割分片（判定已在整个队列层面做过，走到这里必然可用）
            local smart = smart_plans and smart_plans[segment_index]
            if smart then return smart_encode_segment(seg, smart, segment_index) end
            local part=utils.join_path(work,string.format("%s.merge.%03d%s",base,job.current,ext)); U.remove_file(part)
            job.current_temp=part; job.status="encoding"
            local args,build_err=build_trim_args(source,part,seg,merge_accurate,tracks,plan.settings); if not args then fail({},build_err,"building",segment_index,seg); return end
            add_progress_args(args,start_progress_monitor(part,length)); request_render(true)
            local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stderr=true,args=args},function(success,res,err)
                job.async_id=nil; stop_progress_monitor(true)
                if job.cancel_requested then U.remove_file_later(part,1); cleanup_job_files(); finish_job(L("hint.merge_stopped",task_kind_label()),L("hint.no_output_generated")); return end
                local info=utils.file_info(part)
                if not (success and res and res.status==0 and info and info.size>0) then
                    U.remove_file_later(part,1); fail(args,(res and res.stderr) or err,"encoding",segment_index,seg); return
                end
                job.status,job.stage="validating","validating"; request_render(true)
                validate_media_async(part,tracks,plan.settings,function(valid,validation_err)
                    if job.cancel_requested then U.remove_file_later(part,1); cleanup_job_files(); finish_job(L("hint.merge_stopped",task_kind_label()),L("hint.no_output_generated")); return end
                    if not valid then U.remove_file_later(part,1); fail(args,validation_err,"validating",segment_index,seg,validation_err); return end
                    table.insert(job.work_files,part); job.completed_duration=job.completed_duration+length
                    job.overall_progress=math.min(.98,job.completed_duration/math.max(.001,job.total_duration)); job.succeeded=job.succeeded+1
                    job.current=segment_index+1; encode_next()
                end)
            end)
            -- 异步启动失败时回调不会触发：走统一失败路径，避免 job.running 卡死
            if not ok_start then
                stop_progress_monitor(true)
                U.remove_file_later(part,1)
                fail(args, "subprocess async start failed: " .. tostring(start_err), "encoding", segment_index, seg)
                return
            end
            job.async_id = ok_start
        end
        encode_next()
    end)
end
M.run_merge = run_merge

-- 剪辑台内「保存当前帧」：单帧导出的轻量直通版，不走确认面板与任务队列。
-- 套用当前裁剪 / 宽度 / 图片格式，直接落到输出目录（唯一文件名，不会覆盖）。
function M.save_current_frame()
    if job.running or job.preparing then show_hint(L("hint.frame_save_busy"), 3, "error"); return end
    local source = mp.get_property("path")
    local pos = mp.get_property_number("time-pos")
    if not (source and source ~= "") or not pos then show_hint(L("hint.frame_save_failed"), 3, "error"); return end
    local dir, filename = utils.split_path(source)
    local base = filename:match("^(.-)%.[^.]*$") or filename
    local outdir = U.output_dir_for(dir)
    if not U.ensure_output_directory(outdir) then show_hint(L("hint.cannot_access_output"), 4, "error"); return end
    local fmt = tostring(opts.image_format or "png"):lower()
    local out_ext = "." .. tostring(config.IMAGE_EXT[fmt] or fmt)
    -- 强制单帧：只覆盖本地设置快照，不改用户 conf
    local settings = {}
    for k, v in pairs(opts) do settings[k] = v end
    settings.image_mode = "single"
    -- 命名模板：单帧没有片段序号（用当前位置充当起止），结果仍带 _frame 功能后缀
    local tpl_stem = U.apply_name_template(opts.output_name_template,
        {name = base, in_time = pos, out_time = pos})
    local output = U.unique_path(outdir, (tpl_stem or base) .. "_frame", out_ext,
        tpl_stem and "" or nil)
    local temp = U.temp_output_path(output)
    U.remove_file(temp)
    -- 选流与其他导出路径同一套：只取"真正的视频流"，不交给 ffmpeg 自己挑 ——
    -- 含封面（attached_pic）的源会被它当成视频流，存帧就存出一张封面。
    -- source_streams 分析未必跑过（它是懒分析），取不到时退回 0:v:0。
    local tracks = cached_analysis("source_streams", source) or {}
    local args = build_image_args(source, temp, {start_time = pos, end_time = pos + 0.05},
        {video = tracks.video or 0}, settings)
    if not args then U.remove_file(temp); show_hint(L("hint.frame_save_failed"), 3, "error"); return end
    -- 必须检查异步启动返回值：启动失败时回调不会触发（否则临时文件泄漏且无任何反馈）
    local ok_start, start_err = mp.command_native_async(
        {name = "subprocess", args = args, playback_only = false, capture_stdout = true, capture_stderr = true},
        function(success, res, err)
            if not success or not res or res.status ~= 0 then
                U.remove_file(temp)
                local short = U.truncate_chars(tostring((res and res.stderr) or err or "unknown"):gsub("[\r\n]+", " "), 160, true)
                U.log_error("save frame failed: " .. short)
                show_hint(L("hint.frame_save_failed") .. short, 5, "error")
                return
            end
            local info = utils.file_info(temp)
            if not (info and info.size > 0) or not U.commit_output(temp, output) then
                U.remove_file(temp)
                show_hint(L("hint.frame_save_failed"), 4, "error")
                return
            end
            show_hint(L("hint.frame_saved", output), 4, "success")
        end)
    if not ok_start then
        U.remove_file(temp)
        U.log_error("save frame async start failed: " .. tostring(start_err))
        show_hint(L("hint.frame_save_failed") .. tostring(start_err), 5, "error")
    end
end

-- mpv shutdown 前的清理：请求取消、停进度、删除临时文件。
-- 注意 shutdown 后事件循环终止，remove_file_later 的定时器不会再触发——这里必须全部
-- 同步删除，否则合并分段、concat 列表、进度文件、图片序列残帧会全部泄漏在磁盘上。
function M.shutdown_cleanup()
    if job.running then M.cancel_export() end
    -- 先取路径、再停监控：stop_progress_monitor 会把 job.progress_file 置空。
    -- 原来是反的 → progress_file 恒为 nil、末尾那句 U.remove_file(job.progress_file) 也是 nil，
    -- 注释写着"残留的进度文件要清掉"，实际一个都没删。
    local progress_file = job.progress_file
    stop_progress_monitor(false)
    local is_image_sequence = job.plan and job.plan.settings and image_output_is_sequence(job.plan.settings)
    if is_image_sequence and job.current_temp then U.remove_image_sequence(job.current_temp) end
    -- 取消后若 mpv 直接退出（回调来不及跑），残留的进度文件同样要清掉
    if job.cancel_progress_file then U.remove_file(job.cancel_progress_file); job.cancel_progress_file = nil end
    if progress_file then U.remove_file(progress_file) end
    U.remove_file(job.current_temp)
    for _,path in ipairs(job.work_files or {}) do U.remove_file(path) end
    if job.concat_list then U.remove_file(job.concat_list) end
    if progress_file then U.remove_file(progress_file) end
end

return M
