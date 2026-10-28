local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

local U = require "util"
local Editor = require "editor"
local Crop = require "crop"
local config = require "config"

local M = {}

local opts, state, show_hint, request_render, get_queue, L, choice_label, choice_name, primary_key

function M.init(d)
    opts = d.opts
    state = d.state
    show_hint = d.show_hint
    request_render = d.request_render
    get_queue = d.get_queue
    L = d.L
    choice_label = d.choice_label
    choice_name = d.choice_name
    primary_key = d.primary_key
end

M.job = {
    preparing = false,
    running = false, cancel_requested = false, async_id = nil,
    current_output = nil, current_temp = nil,
    progress_file = nil, progress_timer = nil,
    progress = 0, overall_progress = 0, speed = "", segment_length = 0,
    current = 0, total = 0, succeeded = 0, failed = 0,
    completed_duration = 0, total_duration = 0, source_path = nil,
    status = "idle", started_at = 0, progress_samples = 0, animation_frame = 0,
    operation = nil, work_files = {}, work_durations = {}, concat_list = nil,
    plan = nil, stage = nil, current_range = nil, failure = nil,
    smart_skip = nil,
    last_output = nil, last_output_dir = nil,
}
local job = M.job

local environment = {checked = false, ffmpeg = false, ffmpeg_ver = nil, caps = nil, caps_pending = {}, probing = false}

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
        {kind = "filters"},
    }
    for _, plan in ipairs(args_plan) do
        local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stdout=true,
            args={opts.ffmpeg,"-hide_banner","-"..plan.kind}},function(success,res)
            if success and res and res.stdout then
                for line in (res.stdout .. "\n"):gmatch("([^\r\n]*)\r?\n") do
                    local name = line:match("^%s*[A-Z%.]+%s+([%w_]+)%s")
                    if name then caps[plan.kind][name] = true end
                end
            end
            finish()
        end)
        if not ok_start then
            msg.warn("quick_cut: capability probe async start failed ("..plan.kind.."): "..tostring(start_err))
            finish()
        end
    end
end

function M.value_available(req, caps)
    caps = caps or environment.caps
    if not caps or type(req) ~= "table" then return false end
    if req.encoder and not caps.encoders[req.encoder] then return false end
    if req.muxer and not caps.muxers[req.muxer] then return false end
    return true
end

local NULL_OUT = (package.config:sub(1,1) == "\\") and "NUL" or "/dev/null"

function M.size_bitrates(target_mb, total_duration)
    local mb = tonumber(target_mb) or 0
    local dur = tonumber(total_duration) or 0
    if mb <= 0 or dur <= 0 then return nil end
    local total_kbps = mb * 8388.608 / dur
    local budget_kbps = total_kbps - (total_kbps * 0.02 + 4194 / dur)
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

local function ffmpeg_at_least(major, minor)
    local v = environment.ffmpeg_ver
    if not v then return true end
    return v[1] > major or (v[1] == major and v[2] >= minor)
end

local MPV_ENCODERS = {
    video = {
        mp4 = "libx264", mkv = "libx264", mov = "libx264", ts = "libx264",
        webm = "libvpx-vp9", gif = "gif", apng = "apng", webp_anim = "libwebp_anim",
    },
    audio = {
        m4a = "aac", mp3 = "libmp3lame", flac = "flac", wav = "pcm_s16le",
        opus = "libopus", ogg = "libvorbis",
        mp4 = "aac", mkv = "aac", mov = "aac", ts = "aac", webm = "libopus",
    },
    image = { png = "png", jpg = "mjpeg", jpeg = "mjpeg", webp = "libwebp" },
}

local function mpv_encoder(key, container)
    local table_ = MPV_ENCODERS[key]
    if not table_ then return nil end
    return table_[tostring(container or ""):lower():gsub("^%.", "")]
end

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

local analysis_cache = {}

-- 前置声明：分析器与响度滤镜都要知道"当前选中的是哪条音轨"，而 selected_tracks
-- 的实现在本文件后段（Lua 闭包只捕获已声明的局部变量，后置 local function 看不到）。
local selected_tracks

local function current_audio_index()
    if not selected_tracks then return nil end
    local t = selected_tracks()
    return t and t.audio or nil
end

-- 分析结果必须按音轨分开缓存：同一素材换一条音轨，静音区间与响度完全不同。
local function analysis_key(key, audio)
    if key == "loudness" or key == "silence" then return key .. "#" .. tostring(audio or 0) end
    return key
end

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

local function current_source()
    return mp.get_property("path")
end

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
        msg.warn("quick_cut: cannot read duration, sampling falls back to cap: " .. tostring(value))
        return 0
    end
    return tonumber(value) or 0
end

local function sample_seconds(settings, total)
    local cap = tonumber((settings or opts).analysis_sample_seconds) or 0
    if cap <= 0 then return total end
    if total <= 0 then return cap end
    return math.min(cap, total)
end

local function analyze_field_order(source, settings, done)
    run_probe({settings.ffprobe,"-v","error","-select_streams","v:0","-show_entries","stream=field_order",
        "-of","csv=p=0",source}, true, function(ok, stdout)
        if not ok then return done(nil) end
        local order = (tostring(stdout):match("([%a]+)") or ""):lower()
        done(order == "tt" or order == "bb" or order == "tb" or order == "bt")
    end)
end

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
            local sw = tonumber((mp.get_property_number("video-params/w", 0))) or 0
            local sh = tonumber((mp.get_property_number("video-params/h", 0))) or 0
            if sw > 0 and sh > 0 and best.w >= sw and best.h >= sh then best = nil end
            if best and (best.w < 16 or best.h < 16) then best = nil end
        end
        done(best)
    end)
end

local function analyze_loudness(source, settings, done, audio)
    local i = tostring(settings.loudness_target_i or -16)
    local tp = tostring(settings.loudness_target_tp or -1.5)
    local lra = tostring(settings.loudness_target_lra or 11)
    local seconds = sample_seconds(settings, source_duration())
    local args = {settings.ffmpeg,"-hide_banner","-nostats"}
    if seconds > 0 then table.insert(args,"-t"); table.insert(args,string.format("%.3f", seconds)) end
    local filter = string.format("loudnorm=I=%s:TP=%s:LRA=%s:print_format=json", i, tp, lra)
    for _, opt in ipairs({"-i",source,"-map","0:a:"..tostring(audio or 0),"-af",filter,"-f","null","-"}) do
        table.insert(args, opt)
    end
    run_probe(args, false, function(ok, _, stderr)
        if not ok then return done(nil) end
        local json = tostring(stderr):match("({[^{}]*})")
        if not json then return done(nil) end
        local data = utils.parse_json(json)
        if type(data) ~= "table" then return done(nil) end
        local measured = {
            i = tonumber(data.input_i), tp = tonumber(data.input_tp), lra = tonumber(data.input_lra),
            thresh = tonumber(data.input_thresh), offset = tonumber(data.target_offset) or 0,
        }
        if not (measured.i and measured.tp and measured.lra and measured.thresh) then return done(nil) end
        -- 静音轨实测会给出 ±inf（ffmpeg 打印 -inf）：这种"测不出"的结果必须当失败，
        -- 否则把 inf 拼进 -af 会让 ffmpeg 报 "Error applying option 'measured_I' … Result too large"，
        -- 整条导出直接失败（比"不归一化"更糟）。
        local inf = math.huge
        if measured.i == inf or measured.i == -inf or measured.tp == inf or measured.tp == -inf
            or measured.thresh == inf or measured.thresh == -inf
            or measured.offset == inf or measured.offset == -inf then return done(nil) end
        done(measured)
    end)
end

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

local function analyze_source_streams(source, settings, done, audio)
    run_probe({settings.ffprobe,"-v","error","-show_entries",
        "stream=codec_type,codec_name,pix_fmt,profile,width,height,bit_rate,channels,sample_rate",
        "-of","json",source}, true, function(ok, stdout)
        if not ok then return done(nil) end
        local data = utils.parse_json(stdout)
        if type(data) ~= "table" or type(data.streams) ~= "table" then return done(nil) end
        -- 取"当前选中的那条音轨"而不是第一条：音轨之间的编码/码率可能不同，
        -- 拿错会把智能切割/remux 的音频参数判错。
        local video, picked, ai = nil, nil, 0
        local want = tonumber(audio) or 0
        for _, s in ipairs(data.streams) do
            if s.codec_type == "video" then
                if not video then video = s end
            elseif s.codec_type == "audio" then
                if ai == want then picked = s end
                ai = ai + 1
            end
        end
        if not (video and video.codec_name) then return done(nil) end
        done({
            codec = tostring(video.codec_name):lower(),
            pix_fmt = tostring(video.pix_fmt or ""):lower(),
            profile = video.profile,
            width = tonumber(video.width) or 0, height = tonumber(video.height) or 0,
            audio_codec = picked and tostring(picked.codec_name or ""):lower() or nil,
            audio_bitrate = picked and tonumber(picked.bit_rate) or nil,
            audio_channels = picked and tonumber(picked.channels) or nil,
            audio_sample_rate = picked and tonumber(picked.sample_rate) or nil,
        })
    end)
end

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
    if pending then ranges[#ranges + 1] = {start = pending, stop = math.huge} end
    table.sort(ranges, function(a, b) return a.start < b.start end)
    return ranges
end

local function analyze_silence(source, settings, done, audio)
    local db = tostring(tonumber(settings.silence_db) or -30)
    local min_len = tostring(tonumber(settings.silence_min) or 0.5)
    local filter = string.format("silencedetect=noise=%sdB:d=%s", db, min_len)
    run_probe({settings.ffmpeg,"-hide_banner","-nostats",
        "-i",source,"-map","0:a:"..tostring(audio or 0),"-af",filter,"-f","null","-"}, false, function(ok, _, stderr)
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

local CONTAINER_VIDEO_OK = {
    mkv = true, ts = true,
    mp4 = {h264 = true, hevc = true, mpeg4 = true, av1 = true, vp9 = true, vp8 = true},
    mov = {h264 = true, hevc = true, mpeg4 = true},
    webm = {vp8 = true, vp9 = true, av1 = true},
}
local CONTAINER_AUDIO_OK = {
    mkv = true,
    mp4 = {aac = true, mp3 = true, ac3 = true, eac3 = true},
    ts = {aac = true, mp3 = true, ac3 = true, eac3 = true},
    mov = {aac = true, mp3 = true, ac3 = true, eac3 = true},
    webm = {opus = true, vorbis = true},
}
local CONTAINER_MUX_EXT = {mp4 = ".mp4", mkv = ".mkv", mov = ".mov", webm = ".webm", ts = ".ts"}
local SETTING_AUDIO_CODEC = {aac = "aac", libmp3lame = "mp3", libopus = "opus", flac = "flac"}

local function table_accepts(t, codec)
    if t == true then return true end
    if type(t) ~= "table" then return false end
    return t[codec] == true
end

function M.container_copy_ok(vcodec, acodec, container)
    container = tostring(container or ""):lower():gsub("^%.", "")
    local vok, aok = CONTAINER_VIDEO_OK[container], CONTAINER_AUDIO_OK[container]
    if vok == nil and aok == nil then return false, tostring(container) .. " (未知容器)" end
    vcodec, acodec = tostring(vcodec or ""):lower(), tostring(acodec or ""):lower()
    if vcodec ~= "" and not table_accepts(vok, vcodec) then return false, vcodec .. " → " .. container end
    if acodec ~= "" and not table_accepts(aok, acodec) then return false, acodec .. " → " .. container end
    return true, nil
end

local function source_container_of(source)
    local _, filename = utils.split_path(tostring(source or ""))
    local ext = tostring(filename or ""):match("%.([%w]+)$")
    return tostring(ext or ""):lower()
end

local function fast_remux_ext(source, settings)
    local want = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
    if want == "" or CONTAINER_MUX_EXT[want] == nil then return nil, nil end
    if want == source_container_of(source) then return nil, nil end
    local stream = cached_analysis("source_streams", source)
    if type(stream) ~= "table" then return nil, "源编码未知（前置分析未跑到）" end
    local acodec = tostring(stream.audio_codec or "")
    if tostring(settings.audio_codec or ""):lower() == "none" then
        acodec = ""
    elseif settings.normalize_audio == true then
        local set_codec = SETTING_AUDIO_CODEC[tostring(settings.audio_codec or ""):lower()]
        if set_codec then acodec = set_codec end
    end
    local ok, detail = M.container_copy_ok(stream.codec, acodec, want)
    if not ok then return nil, detail end
    return CONTAINER_MUX_EXT[want], nil
end

local function analysis_enabled(key, settings, kind, accurate)
    settings = settings or opts
    kind = tostring(kind or settings.output_kind or "video"):lower()
    if kind == "image" then return false end
    if (key == "loudness" or key == "silence") and kind ~= "video" and kind ~= "audio" then return false end
    if key == "keyframes" then return settings.smart_cut == true end
    if key == "field_order" and accurate == false then return false end
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

local function describe_result(result)
    if result == nil then return "nil" end
    if type(result) ~= "table" then return tostring(result) end
    if #result > 8 then
        return string.format("%d items, first=%s, last=%s", #result, tostring(result[1]), tostring(result[#result]))
    end
    local parts = {}
    for k, v in pairs(result) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function run_pending_analyses(source, callback, kind, accurate)
    local audio = current_audio_index()
    local pending = {}
    for _, key in ipairs(ANALYSIS_ORDER) do
        if analysis_enabled(key, opts, kind, accurate)
            and cached_analysis(analysis_key(key, audio), source) == nil then pending[#pending + 1] = key end
    end
    local index = 0
    local function step()
        index = index + 1
        local key = pending[index]
        if not key then callback(); return end
        local analyzer = ANALYZERS[key]
        local ckey = analysis_key(key, audio)
        show_hint(L(analyzer.hint), 3)
        analyzer.run(source, opts, function(result)
            if result == nil then
                show_hint(L("hint.analysis_failed", L(analyzer.label)), 4, "error")
                store_analysis(ckey, source, false)
            else
                store_analysis(ckey, source, result)
            end
            msg.info(string.format("quick_cut analysis %s: %s", key, describe_result(result)))
            step()
        end, audio)
    end
    step()
end

local HEAD_ENCODERS = {h264 = "libx264"}
local HEAD_PIX_FMTS = {yuv420p = "yuv420p", yuvj420p = "yuv420p", yuv422p = "yuv422p", yuv444p = "yuv444p"}
local HEAD_AUDIO_ENCODERS = {aac = "aac", mp3 = "libmp3lame", opus = "libopus",
                             flac = "flac", ac3 = "ac3", eac3 = "eac3"}
local HEAD_AUDIO_LOSSLESS = {flac = true}
local AUDIO_SETTING_ENCODERS = SETTING_AUDIO_CODEC
local HEAD_PROFILES = {
    constrainedbaseline = "baseline", baseline = "baseline", main = "main",
    high = "high", high10 = "high10", high422 = "high422", high444 = "high444",
}

local function smart_cut_segment_plan(source, seg, settings, tracks)
    settings = settings or opts
    if settings.smart_cut ~= true then return nil, "off" end
    local kind = tostring(settings.output_kind or "video"):lower()
    if kind ~= "video" then return nil, "smart.reason_non_video" end
    local stream = cached_analysis("source_streams", source)
    if type(stream) ~= "table" then return nil, "smart.reason_no_codec" end
    if tostring(stream.codec or ""):lower() == "hevc" then return nil, "smart.reason_hevc" end
    local encoder = HEAD_ENCODERS[tostring(stream.codec or ""):lower()]
    if not encoder then return nil, "smart.reason_no_codec" end
    local pix_fmt = HEAD_PIX_FMTS[tostring(stream.pix_fmt or ""):lower()]
    if not pix_fmt then return nil, "smart.reason_pix_fmt" end
    local wanted_pix_fmt = tostring(settings.pixel_format or ""):lower()
    if wanted_pix_fmt ~= "" and wanted_pix_fmt ~= "auto" and wanted_pix_fmt ~= pix_fmt then
        return nil, "smart.reason_pix_fmt"
    end
    -- 头部音频必须重编码，且必须用**源的音频编码**才能与
    -- 原样复制的尾部缝在同一个文件里。查表而不是写死 aac：源是 opus/flac 时编成 aac 会拼不起来。
    local audio_encoder
    if (tracks == nil or tracks.audio ~= nil) and tostring(settings.audio_codec or ""):lower() ~= "none" then
        local source_audio = tostring(stream.audio_codec or ""):lower()
        audio_encoder = HEAD_AUDIO_ENCODERS[source_audio]
        if not audio_encoder then return nil, "smart.reason_audio_codec" end
        local wanted_audio = tostring(settings.audio_codec or "copy"):lower()
        if wanted_audio ~= "copy" then
            if AUDIO_SETTING_ENCODERS[wanted_audio] ~= audio_encoder then
                return nil, "smart.reason_audio_mismatch"
            end
        end
    end
    local times = cached_analysis("keyframes", source)
    if type(times) ~= "table" or #times == 0 then return nil, "smart.reason_no_keyframes" end
    local lo, hi, next_kf = 1, #times, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if times[mid] >= seg.start_time - 0.001 then next_kf = times[mid]; hi = mid - 1 else lo = mid + 1 end
    end
    if not next_kf or next_kf >= seg.end_time - 0.001 then
        return nil, "smart.reason_single_gop"
    end
    if next_kf - seg.start_time < 0.02 then return nil, "aligned" end
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

local function smart_cut_merge_blocker(settings)
    if (settings.output_kind or "video") ~= "video" then return "hint.smart_cut_video_only" end
    if Crop.crop_is_active(settings) then return "hint.smart_cut_merge_crop" end
    if (tonumber(settings.video_width) or 0) > 0 or (tonumber(settings.video_height) or 0) > 0
        or (tonumber(settings.output_fps) or 0) > 0 then return "hint.smart_cut_merge_transform" end
    if settings.auto_deinterlace == true or settings.auto_crop_black == true then
        return "hint.smart_cut_merge_auto"
    end
    if settings.normalize_audio == true then return "hint.smart_cut_merge_loudness" end
    if tostring(settings.video_quality_mode or "") == "bitrate" then return "hint.smart_cut_merge_bitrate" end
    return nil
end

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

local function check_ffmpeg_prepared(path, kind, callback, selected_seconds, accurate)
    export_selection_seconds = tonumber(selected_seconds) or 0   -- 供关键帧步长估算
    local function after_analyses()
        local mode = tostring(opts.image_mode or ""):lower()
        local limit = math.floor(tonumber(opts.keyframe_limit) or 0)
        if kind ~= "image" or mode ~= "keyframes" or limit <= 0 or kf_total_cache[path] ~= nil then
            return check_ffmpeg(callback)
        end
        show_hint(L("hint.counting_keyframes"), 3)
        count_keyframes_async(path, function()
            -- 这里**绝不能**给 source_duration 赋值：它是上面的分析器函数名，
            -- 被数字覆盖后 analyze_crop_black / analyze_loudness 再调就会崩，且要重启 mpv
            check_ffmpeg(callback)
        end)
    end
    run_pending_analyses(path, after_analyses, kind, accurate)
end

local export_selection_seconds = 0

local function image_keyframe_stride(path, settings, selected_seconds)
    settings = settings or opts
    local stride = math.max(1, math.floor(tonumber(settings.keyframe_stride) or 1))
    local limit = math.floor(tonumber(settings.keyframe_limit) or 0)
    if limit <= 0 or not path then return stride end
    local total = tonumber(kf_total_cache[path])
    local estimate = not (total and total > 0)
    if estimate then total = math.max(1, math.ceil((tonumber(selected_seconds) or 0) / 10)) end
    local whole = source_duration() or 0
    local seconds = tonumber(selected_seconds) or 0
    if whole > 0 and seconds > 0 and seconds < whole then
        total = math.max(1, math.ceil(total * seconds / whole))
    end
    if estimate and total <= limit then return stride end
    local need = math.ceil(total / limit)
    if need > stride then stride = need end
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
    job.preparing = nil
    job.cancel_requested,job.status=true,"stopping"
    job.cancel_progress_file = job.progress_file
    if job.async_id then pcall(mp.abort_async_command,job.async_id) end
    stop_progress_monitor(false); show_hint(L("hint.stopping_export"),2); request_render(true)
end

local function finish_job(title, body, success)
    stop_progress_monitor(true)
    job.cancel_progress_file = nil
    job.running, job.async_id = false, nil
    -- 取消标记必须在收尾时清掉：否则下一次独立导出会在预备回调里看到它，
    -- 直接静默返回（用户看到的是"按了导出却没反应"）。
    job.cancel_requested = false
    job.current_output, job.current_temp = nil, nil
    job.source_path,job.status,job.operation=nil,"idle",nil
    job.plan,job.stage,job.current_range,job.failure=nil,nil,nil,nil
    job.progress_samples,job.animation_frame=0,0
    if success and job.smart_skip then
        body = tostring(body or "") .. "\n" .. L("hint.smart_cut_shift_note")
    end
    job.smart_skip = nil
    job.finish_ok = success and true or nil
    job.finished_at = success and mp.get_time() or nil
    request_render(true)
    U.notify(title, tostring(body or ""))
end

local function task_kind_label()
    local kind = (job.plan and job.plan.settings and job.plan.settings.output_kind) or state.export_kind or "video"
    local key = "confirm.kind_" .. tostring(kind)
    local label = L(key)
    if label and label ~= key then return label end
    return L("confirm.kind_video")
end

local function deinterlace_filter()
    local caps = environment.caps
    if caps and caps.filters then
        if caps.filters["bwdif"] then return "bwdif" end
        if caps.filters["yadif"] then return "yadif" end
        msg.warn("quick_cut: auto deinterlace requested but no bwdif/yadif in this ffmpeg")
        show_hint(L("hint.deinterlace_unavailable"), 5, "error")
        return nil
    end
    return "bwdif"
end

local function loudnorm_af(settings)
    local measured = cached_analysis(analysis_key("loudness", current_audio_index()), current_source())
    if type(measured) ~= "table" then return nil end
    return string.format(
        "loudnorm=I=%s:TP=%s:LRA=%s:measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true",
        tostring(settings.loudness_target_i or -16), tostring(settings.loudness_target_tp or -1.5),
        tostring(settings.loudness_target_lra or 11),
        measured.i, measured.tp, measured.lra, measured.thresh, measured.offset or 0)
end

local function apply_audio_normalization(settings)
    if settings.normalize_audio ~= true then return nil end
    local measured = cached_analysis(analysis_key("loudness", current_audio_index()), current_source())
    if type(measured) ~= "table" then return nil end
    if tostring(settings.audio_codec or "") == "copy" then
        settings.audio_codec = config.lossy_audio_for(settings.encode_container)
        show_hint(L("hint.loudness_needs_recoding"), 4)
    end
    return measured
end

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

local function speed_factor(settings)
    local s = tonumber((settings or opts).play_speed) or 1
    if s <= 0 then s = 1 end
    return s
end

local function speed_active(settings)
    return math.abs(speed_factor(settings) - 1) > 0.005
end

local function atempo_chain(speed)
    local s = tonumber(speed) or 1
    if math.abs(s - 1) <= 0.005 then return nil end
    local parts = {}
    local left = s
    while left > 2.0 + 1e-9 do parts[#parts + 1] = "atempo=2"; left = left / 2 end
    while left < 0.5 - 1e-9 do parts[#parts + 1] = "atempo=0.5"; left = left / 0.5 end
    parts[#parts + 1] = string.format("atempo=%.6g", left)
    return table.concat(parts, ",")
end
M.atempo_chain = atempo_chain

local function build_video_filters(settings)
    settings = settings or opts
    local filters = {}
    if settings.auto_deinterlace == true and cached_analysis("field_order", current_source()) == true then
        local name = deinterlace_filter()
        if name then table.insert(filters, name) end
    end
    local crop, crop_err = Crop.rect_for(settings)
    if crop_err then return nil, crop_err end
    if crop then
        table.insert(filters, string.format("crop=%d:%d:%d:%d", crop.w, crop.h, crop.x, crop.y))
    elseif settings.auto_crop_black == true then
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
    if speed_active(settings) then
        table.insert(filters, string.format("setpts=%.6f*PTS", 1 / speed_factor(settings)))
    end
    if settings.output_fps > 0 then table.insert(filters, string.format("fps=%.3f", settings.output_fps)) end
    return filters
end

local function coerce_preset(codec, preset)
    local cur = tostring(preset or "")
    if cur == "" then return preset end
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
    local af_parts = {}
    if settings.normalize_audio == true and settings.audio_codec ~= "copy" then
        local af = loudnorm_af(settings)
        if af then af_parts[#af_parts + 1] = af end
    end
    if speed_active(settings) then
        local chain = atempo_chain(speed_factor(settings))
        if chain then
            if tostring(settings.audio_codec) == "copy" then
                local container = tostring(settings.encode_container or ""):lower():gsub("^%.", "")
                settings.audio_codec = config.lossy_audio_for(container)
                msg.info("quick_cut audio: 'copy' cannot carry filters, using "
                    .. tostring(settings.audio_codec))
                for i = #args - 1, 1, -1 do
                    if args[i] == "-c:a" then args[i + 1] = settings.audio_codec; break end
                end
            end
            af_parts[#af_parts + 1] = chain
        end
    end
    if #af_parts > 0 then table.insert(args,"-af"); table.insert(args,table.concat(af_parts,",")) end
end

local function source_size_text()
    local dw = mp.get_property_number("video-params/dw", 0)
    local dh = mp.get_property_number("video-params/dh", 0)
    if dw > 0 and dh > 0 then return string.format("%s×%s", dw, dh) end
    return L("summary.original_size")
end

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
        local w = math.floor(tonumber(opts.image_width) or 0)
        local size = w > 0 and (tostring(w) .. "px") or source_size_text()
        local mode = tostring(opts.image_mode or "sequence"):lower()
        if mode == "tile" then
            local cols, rows = tile_grid_size(opts)
            return L("summary.image_tile", fmt, cols, rows, size)
        elseif mode == "keyframes" then
            local text = L("summary.image_keyframes", fmt, size)
            local source = mp.get_property("path")
            local total = source and kf_total_cache[source]
            if total and total > 0 then text = text .. " · " .. L("summary.kf_total", total) end
            local stride = image_keyframe_stride(source, opts, 0)
            if stride > 1 then text = text .. " · " .. L("summary.kf_stride", stride) end
            return text
        elseif mode == "single" then
            return L("summary.image_single", fmt, size)
        elseif mode == "current" then
            return L("summary.image_current", fmt, size)
        end
        return L("summary.image", fmt, tostring(opts.animated_fps or 1), size)
    end
    local crop = opts.crop_mode == "none" and L("summary.no_crop")
        or (opts.crop_mode == "custom" and (state.crop_ratio_lock or L("summary.custom_crop")) or opts.crop_aspect)
    if opts.export_preset_args and opts.export_preset_args ~= "" then
        return string.format("%s · %s · %s", label, L("summary.custom_args"), crop)
    end
    local size
    if opts.video_width > 0 or opts.video_height > 0 then
        size = string.format("%s×%s", opts.video_width > 0 and opts.video_width or L("value.auto"), opts.video_height > 0 and opts.video_height or L("value.auto"))
    else
        size = source_size_text()
    end
    local quality = opts.video_quality_mode == "bitrate" and (opts.video_bitrate ~= "" and opts.video_bitrate or L("value.no_bitrate")) or (opts.video_quality_mode .. " " .. tostring(opts.video_quality))
    if state.optimize_goal == "size" and tonumber(state.size_target) then
        local total = 0
        for _, s in ipairs(get_queue()) do total = total + (s.end_time - s.start_time) end
        if total <= 0 then total = tonumber((mp.get_property_number("duration"))) or 0 end
        local vk = M.size_bitrates(tonumber(state.size_target), total)
        if vk then quality = string.format(L("value.size_goal"), tonumber(state.size_target), vk) end
    end
        local vcodec = (config.codec_label and config.codec_text(opts.video_codec)) or tostring(opts.video_codec or "")
        local line = string.format("%s · %s · %s · %s · %s", label, vcodec, size, quality, crop)
        if speed_active(opts) then line = line .. " · " .. L("summary.speed", string.format("%g", speed_factor(opts))) end
        return line
end

local function build_animated_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local length = seg.end_time - seg.start_time
    if speed_active(settings) then length = length / speed_factor(settings) end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    table.insert(args,"-an")

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
    if speed_active(settings) then
        parts[#parts+1] = string.format("setpts=%.6f*PTS", 1 / speed_factor(settings))
    end
    parts[#parts+1] = string.format("fps=%.3f", fps)
    if width > 0 then
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
        if chain ~= "" then table.insert(args,"-vf"); table.insert(args,chain) end
        table.insert(args,"-f"); table.insert(args,"avif")
        table.insert(args,"-c:v"); table.insert(args,"libaom-av1")
        local crf = math.max(0, math.min(63, math.floor((100 - quality) * 63 / 100 + 0.5)))
        table.insert(args,"-crf"); table.insert(args,tostring(crf))
        table.insert(args,"-cpu-used"); table.insert(args,"6")
        table.insert(args,"-pix_fmt"); table.insert(args,"yuv420p")
        table.insert(args,"-loop"); table.insert(args,tostring(loop))
    else
        if chain ~= "" then table.insert(args,"-vf"); table.insert(args,chain) end
        table.insert(args,"-f"); table.insert(args,"apng")
        table.insert(args,"-plays"); table.insert(args,tostring(loop))
    end

    table.insert(args,output)
    return args
end

local function build_subtitle_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local external = tracks.subtitle_external
    local index = tracks.subtitle
    if external == nil and index == nil then index = tracks.subtitle_first end
    if external == nil and index == nil then return nil, L("hint.no_subtitle_track") end
    local length = seg.end_time - seg.start_time
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    local stream_ref = "0:s:" .. tostring(index)
    if external ~= nil then
        table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
        table.insert(args,"-i"); table.insert(args,external)
        stream_ref = "1:s:0"
    end
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    table.insert(args,"-map"); table.insert(args,stream_ref)
    local codec = tostring(settings.subtitle_codec or "srt"):lower()
    table.insert(args,"-c:s"); table.insert(args,codec)
    if codec == "copy" then
        table.insert(args,"-avoid_negative_ts"); table.insert(args,"make_zero")
    end
    table.insert(args,output)
    return args
end

local function build_audio_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local length = seg.end_time - seg.start_time
    if speed_active(settings) and tostring(settings.audio_codec or "") ~= "copy" then
        length = length / speed_factor(settings)
    end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
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
    return mode ~= "tile" and mode ~= "single" and mode ~= "current"
end

local TILE_DECODE_MAX_SECONDS = 30
local TILE_MAX_INPUTS = 64
local TILE_SEEK_MS_PER_POINT = 45
local TILE_DECODE_MS_PER_MB = 2.5

local function build_tile_args(input, output, seg, tracks, settings)
    settings = settings or opts
    local cols, rows = tile_grid_size(settings)
    local total = cols * rows
    local length = math.max(0.001, seg.end_time - seg.start_time)
    local crop, crop_err = Crop.rect_for(settings)
    if crop_err then return nil, crop_err end
    local width = math.floor(tonumber(settings.image_width) or 0)

    local function visual_chain()
        local parts = {}
        if crop then parts[#parts+1] = string.format("crop=%d:%d:%d:%d", crop.w, crop.h, crop.x, crop.y) end
        if width > 0 then parts[#parts+1] = string.format("scale=%d:-2:flags=lanczos", U.even_floor(width)) end
        return parts
    end
    local grid = string.format("tile=%dx%d:padding=2:margin=2", cols, rows)

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

    local use_seek = length > TILE_DECODE_MAX_SECONDS
    if use_seek and total <= TILE_MAX_INPUTS then
        local info = utils.file_info(input)
        local whole = tonumber((mp.get_property_number("duration"))) or 0
        if info and tonumber(info.size) and whole > length then
            local range_mb = (tonumber(info.size) / 1048576) * (length / whole)
            use_seek = range_mb * TILE_DECODE_MS_PER_MB > total * TILE_SEEK_MS_PER_POINT
        end
    end

    if not use_seek then return single_input_tile(nil) end
    if total > TILE_MAX_INPUTS then
        return single_input_tile({"-skip_frame","nokey"})
    end

    local step = length / total
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    for i = 1, total do
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
        chains[#chains+1] = string.format("[%d:v]%s[v%d]", i - 1, table.concat(filters, ","), i - 1)
    end
    local refs = {}
    for i = 0, total - 1 do refs[#refs+1] = string.format("[v%d]", i) end
    chains[#chains+1] = string.format("%sconcat=n=%d:v=1:a=0[cat]", table.concat(refs), total)
    chains[#chains+1] = string.format("[cat]tile=%dx%d:padding=2:margin=2[out]", cols, rows)
    table.insert(args,"-filter_complex"); table.insert(args,table.concat(chains, ";"))
    table.insert(args,"-map"); table.insert(args,"[out]")
    table.insert(args,"-frames:v"); table.insert(args,"1")
    table.insert(args,output)
    return args
end

local function build_image_args(input, output, seg, tracks, settings)
    settings = settings or opts
    tracks = tracks or {}
    local length = math.max(0.001, seg.end_time - seg.start_time)
    local mode = tostring(settings.image_mode or "sequence"):lower()
    if mode ~= "keyframes" and mode ~= "single" and mode ~= "current" and mode ~= "tile" and speed_active(settings) then
        length = length / speed_factor(settings)
    end
    if mode == "tile" then return build_tile_args(input, output, seg, tracks, settings) end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    local seek_first = (mode == "single" or mode == "current")
    if mode == "keyframes" then table.insert(args,"-skip_frame"); table.insert(args,"nokey") end
    if seek_first then
        table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
        table.insert(args,"-i"); table.insert(args,input)
    else
        table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
        table.insert(args,"-i"); table.insert(args,input)
        table.insert(args,"-t"); table.insert(args,string.format("%.6f",length))
    end
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    table.insert(args,"-an")

    local crop, crop_err = Crop.rect_for(settings)
    if crop_err then return nil, crop_err end
    local width = math.floor(tonumber(settings.image_width) or 0)
    local parts = {}
    if crop then parts[#parts+1] = string.format("crop=%d:%d:%d:%d", crop.w, crop.h, crop.x, crop.y) end
    if mode == "keyframes" then
        local stride = image_keyframe_stride(input, settings, math.max(export_selection_seconds, length))
        if stride > 1 then parts[#parts+1] = string.format("select=not(mod(n\\,%d))", stride) end
    elseif mode == "single" or mode == "current" then
        -- 单帧/当前帧只取一帧：不加 fps 滤镜（否则会退化成"截取一段序列"）
    else
        if speed_active(settings) then
            parts[#parts+1] = string.format("setpts=%.6f*PTS", 1 / speed_factor(settings))
        end
        parts[#parts+1] = string.format("fps=%.3f", tonumber(settings.animated_fps) or 1)
    end
    if width > 0 then
        parts[#parts+1] = string.format("scale=%d:-2:flags=lanczos", U.even_floor(width))
    end
    if #parts > 0 then table.insert(args,"-vf"); table.insert(args,table.concat(parts,",")) end
    if mode == "single" or mode == "current" then table.insert(args,"-frames:v"); table.insert(args,"1") end
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
        local wq = math.floor(100 - (math.max(2, math.min(31, q)) - 2) * 100 / 29)
        table.insert(args,"-quality"); table.insert(args,tostring(wq))
    elseif fmt == "avif" then
        table.insert(args,"-c:v"); table.insert(args,"libaom-av1")
        table.insert(args,"-crf"); table.insert(args,tostring(math.max(0, math.min(63, q))))
        table.insert(args,"-cpu-used"); table.insert(args,"6")
        table.insert(args,"-pix_fmt"); table.insert(args,"yuv420p")
    elseif fmt == "jxl" then
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
    table.insert(args,"-bf"); table.insert(args,"0")
    if tracks.audio ~= nil and tostring(settings.audio_codec or ""):lower() ~= "none" then
        table.insert(args,"-c:a"); table.insert(args, plan_smart.audio_encoder or "aac")
        if not plan_smart.audio_lossless then
            table.insert(args,"-b:a"); table.insert(args, tostring(plan_smart.audio_bitrate or 192000))
        end
    end
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
    local out_length = length
    if speed_active(settings) then out_length = length / speed_factor(settings) end
    local args = {settings.ffmpeg,"-y","-hide_banner","-loglevel","error"}
    table.insert(args,"-ss"); table.insert(args,string.format("%.6f",seg.start_time))
    table.insert(args,"-i"); table.insert(args,input)
    table.insert(args,"-t"); table.insert(args,string.format("%.6f",out_length))
    if tracks.video ~= nil then table.insert(args,"-map"); table.insert(args,"0:v:" .. tracks.video) end
    add_audio_stream(args, tracks, settings)
    table.insert(args,"-map_metadata"); table.insert(args,"0")
    table.insert(args,"-map_chapters"); table.insert(args,"-1")
    local raw_args = tostring(settings.export_preset_args or "")
    if accurate and raw_args ~= "" then
        for _, a in ipairs(U.safe_extra_args(U.split_args(raw_args))) do table.insert(args, a) end
    elseif accurate then
        if tracks.video ~= nil then
            local filters, filter_err = build_video_filters(settings)
            if filter_err then return nil, filter_err end
            if #filters > 0 then table.insert(args,"-vf"); table.insert(args,table.concat(filters,",")) end
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
    local extra = {}
    for _, src in ipairs({settings.export_preset_extra, settings.ffmpeg_extra_args}) do
        if src and src ~= "" then
            for _, a in ipairs(U.split_args(src)) do extra[#extra + 1] = a end
        end
    end
    if #extra > 0 then
        for _, a in ipairs(U.safe_extra_args(extra)) do table.insert(args, a) end
    end
    local container = accurate and tostring(settings.encode_container or ""):lower():gsub("^%.", "")
        or tostring(output or ""):lower():match("%.([%w]+)$") or ""
    if settings.faststart == true and (container == "mp4" or container == "mov") then
        table.insert(args,"-movflags"); table.insert(args,"+faststart")
    end
    if settings.two_pass then
        table.insert(args,"-pass"); table.insert(args,tostring(settings.two_pass))
        table.insert(args,"-passlogfile"); table.insert(args,tostring(settings.passlogfile or ""))
        if tonumber(settings.two_pass) == 1 then table.insert(args,"-f"); table.insert(args,"null") end
    end
    table.insert(args,output)
    return args
end

local function mpv_video_filter(settings)
    local filters = build_video_filters(settings)
    if not filters or #filters == 0 then return nil end
    local kept = {}
    for _, f in ipairs(filters) do
        if not f:match("^setpts=") then kept[#kept + 1] = f end
    end
    if #kept == 0 then return nil end
    return table.concat(kept, ",")
end

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

local function mpv_bitrate_value(raw)
    raw = tostring(raw or "")
    local num = tonumber(raw:match("^([%d%.]+)"))
    if not num then return nil end
    if raw:match("[kK]$") then num = num * 1000
    elseif raw:match("[mM]$") then num = num * 1000000 end
    return string.format("%d", math.floor(num))
end

local function mpv_video_quality_opts(settings, encoder)
    local out = {}
    local mode = tostring(settings.video_quality_mode or "crf")
    if mode == "bitrate" and tostring(settings.video_bitrate or "") ~= "" then
        out[#out + 1] = { "b", mpv_bitrate_value(settings.video_bitrate) }
    else
        local q = tonumber(settings.video_quality)
        if q then out[#out + 1] = { "crf", string.format("%g", q) } end
    end
    if encoder == "libx264" or encoder == "libx265" then
        local preset = tostring(settings.preset or "")
        if preset ~= "" and preset ~= "medium" then out[#out + 1] = { "preset", preset } end
    end
    return out
end

local function build_mpv_trim_args(input, output, seg, tracks, settings)
    local mpv_bin = resolve_mpv_binary()
    if not mpv_bin then return nil, L("hint.no_mpv_binary") end
    local kind = tostring(settings.output_kind or "video"):lower()
    local container = tostring(settings.encode_container or "mkv"):lower():gsub("^%.", "")

    -- 编码进程不能打扰用户：mpv 的视频编码必须有能出帧的 VO（实测 --vo=null 直接
    -- "Error opening/initializing the selected video_out" + 0 字节），所以视频只能最小化；
    -- 纯音频没有画面，走下面的 --vo=null 做到完全无窗口。
    local args = { mpv_bin, "--no-config", "--no-terminal",
        "--window-minimized=yes", "--border=no", "--osc=no", "--osd-bar=no", "--osd-level=0",
        "--input-default-bindings=no", "--input-cursor=no",
        "--start=" .. string.format("%.6f", seg.start_time),
        "--end=" .. string.format("%.6f", seg.end_time),
        "--o=" .. output }
    if speed_active(settings) then return nil, L("hint.mpv_no_speed") end
    -- 源文件必须是位置参数（放在最后）：mpv 用它当播放目标，缺了就只是空跑一小时再退出，
    -- 表现是 exit 0 + 0 字节产物（"输出为空或无法提交正式文件"）。
    local source = tostring(input or "")
    if source == "" then return nil, L("hint.not_local_file") end

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
        -- 纯音频编码不需要任何 VO：这个真的可以零窗口
        args[#args + 1] = "--vo=null"
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
        args[#args + 1] = "--aid=no"
        args[#args + 1] = "--ovc=" .. encoder
        args[#args + 1] = "--of=image2"
        if encoder == "mjpeg" then args[#args + 1] = "--vf-add=scale=out_range=full" end
        args[#args + 1] = source
        return args
    end

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

selected_tracks = function()
    local list = mp.get_property_native("track-list") or {}
    local out = {video = nil, audio = nil, audio_first = nil, subtitle = nil, subtitle_first = nil, subtitle_external = nil}
    local video_index, audio_index, subtitle_index = 0, 0, 0
    for _, track in ipairs(list) do
        if track.type == "video" then
            if track.selected and not track.albumart and out.video == nil then out.video = video_index end
            video_index = video_index + 1
        elseif track.type == "audio" then
            local aext = track["external-filename"]
            if aext == nil or aext == "" then
                if track.selected and out.audio == nil then out.audio = audio_index end
                if out.audio_first == nil then out.audio_first = audio_index end
                audio_index = audio_index + 1
            elseif track.selected then
                out.audio_external_selected = true
            end
        elseif track.type == "sub" then
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
    if out.audio == nil and out.audio_external_selected then out.audio = out.audio_first end
    return out
end

-- 合并前校验：只做"文件存在且非空"。原先的 strict 档要求产物包含源里所有选中流，
-- 而音频/动图/裁剪后的产物天然缺流（源有视频、产物只有音频）→ 必然误判，已移除。
-- tracks 参数保留只为不改调用点。
local function validate_media_async(path, tracks, settings, callback)
    settings = settings or opts
    if settings.merge_validation == "off" then callback(true, nil); return end
    local info = utils.file_info(path)
    local valid = info and info.is_file and tonumber(info.size or 0) > 0
    callback(valid == true, valid and nil or L("hint.temp_missing"))
end

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
    local plan_queue, silence = Editor.clone_segments(queue), nil
    local sil_kind = tostring(opts.output_kind or "video"):lower()
    if opts.remove_silence == true and (sil_kind == "video" or sil_kind == "audio") then
        local ranges = cached_analysis(analysis_key("silence", current_audio_index()), source)
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

local function whole_file_segment()
    local duration = mp.get_property_number("duration", 0)
    if duration <= 0 then return nil end
    return {id = "whole", start_time = 0, end_time = duration, enabled = true}
end

local function run_cut(kind)
    kind = kind or "video"
    if job.running or job.preparing then M.cancel_export(); return end
    local input = mp.get_property("path")
    if not U.valid_local_file(input) then show_hint(L("hint.not_local_file"),3,"error"); return end
    local queue = get_queue()
    if #queue == 0 and (state.start_time ~= nil or state.end_time ~= nil) then
        show_hint(L("hint.mark_not_added", primary_key and primary_key("add") or "Enter"),3,"error")
        return
    end
    if #queue == 0 then
        if kind == "image" then
            if tostring(opts.image_mode or ""):lower() ~= "current" then
                show_hint(L("hint.image_need_segments"),4,"error"); return
            end
            local pos = mp.get_property_number("time-pos")
            local duration = mp.get_property_number("duration")
            if not pos then show_hint(L("hint.frame_save_failed"),4,"error"); return end
            queue = {{id="current", start_time=pos,
                end_time=math.min(pos + 0.05, duration or (pos + 0.05))}}
        else
            local whole = whole_file_segment()
            if not whole then show_hint(L("hint.whole_media_no_duration"),3,"error"); return end
            queue = {whole}
        end
    end
    local source_path_snapshot = input
    local prepared_accurate = Crop.effective_accurate_mode(opts, state.accurate_mode, "single") == true
    local accurate_mode_snapshot
    local tracks = selected_tracks()
    if kind == "subtitle" then
        if tracks.subtitle == nil and tracks.subtitle_external == nil and tracks.subtitle_first == nil then
            show_hint(L("hint.no_subtitle_track"),3,"error"); return
        end
    elseif tracks.video == nil and tracks.audio == nil then
        show_hint(L("hint.no_tracks"),3,"error"); return
    end
    job.preparing, job.status = true, "preparing"
    local selected_seconds = 0
    do
        for _, s in ipairs(queue) do
            selected_seconds = selected_seconds + math.max(0, (tonumber(s.end_time) or 0) - (tonumber(s.start_time) or 0))
        end
    end
    check_ffmpeg_prepared(source_path_snapshot, kind, function(ok)
        job.preparing = nil
        -- 准备期按过取消（cancel_export 只置了标记，没有 ffmpeg 可 abort）：必须在这里收口，
        -- 否则取消之后照样跑一遍导出，看起来像"取消无效"。
        if job.cancel_requested then
            job.cancel_requested = false
            job.status, job.stage = "idle", nil
            request_render(true)
            return
        end
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
        plan.settings.output_kind = kind
        job.plan = plan
        job.last_output_dir = outdir
        queue,tracks=plan.queue,plan.tracks
        accurate_mode_snapshot=Crop.effective_accurate_mode(plan.settings,plan.requested_accurate_mode,"export")
        plan.accurate_mode=accurate_mode_snapshot
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
            out_ext = "." .. tostring(plan.settings.encode_container):gsub("^%.", "")
        else
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
        local loud = apply_audio_normalization(plan.settings)
        if loud then
            show_hint(L("hint.loudness_applied", string.format("%.1f", loud.i),
                tostring(plan.settings.loudness_target_i)), 4)
        end
        coerce_audio_copy_for_container(plan.settings)
        -- 同理，copy 的**视频**装不进目标容器时也必须换编码器（H.264 → webm 会直接写不出文件头）
        coerce_video_copy_for_container(plan.settings)
        -- 去静音段的结果提示（整段都是静音时必须中止，否则会产出空文件）
        if not report_silence_plan(plan) then return end

        if backend == "mpv" then
            if kind == "subtitle" then
                show_hint(L("hint.mpv_no_subtitle_export"), 6, "error")
                request_render(true)
                return
            end
            if speed_active(plan.settings) then
                show_hint(L("hint.mpv_no_speed"), 6, "error")
                request_render(true)
                return
            end
            local mpv_img_mode = tostring(plan.settings.image_mode or ""):lower()
            if kind == "image" and mpv_img_mode ~= "sequence" and mpv_img_mode ~= "current" then
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

        local image_sequence = image_output_is_sequence(plan.settings)
        local total_duration = 0
        for _, seg in ipairs(queue) do total_duration = total_duration + (seg.end_time - seg.start_time) end
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
            if tostring(plan.settings.video_codec or "") == "copy" then
                plan.settings.video_codec = config.real_video_codec_for(plan.settings.encode_container)
            end
            local acodec = tostring(plan.settings.audio_codec or "")
            if acodec == "flac" or acodec == "copy" or acodec == "" then
                plan.settings.audio_codec = config.lossy_audio_for(plan.settings.encode_container)
            end
            plan.settings.audio_bitrate = string.format("%dk", akbps)
            size_two_pass = true
            show_hint(L("hint.size_bitrate", string.format("%dk", vkbps), string.format("%dk", akbps)), 5)
        end
        job.running, job.cancel_requested, job.current, job.total, job.succeeded, job.failed = true, false, 1, #queue, 0, 0
        if kind == "image" and image_sequence then
            local fps = math.max(1, math.floor(tonumber(plan.settings.animated_fps) or 1))
            local est = math.ceil(total_duration * fps)
            if est > 500 then show_hint(L("hint.image_sequence_many", tostring(est)), 5) end
        end
        job.smart_skip = nil
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
            local whole = seg.id == "whole"
            local seg_name = tostring(seg.label or "")
            local custom_name = (not whole) and seg_name ~= "" and seg_name ~= L("hint.segment_label", seg.id)
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
            -- 单帧/当前帧都只出一张图（单文件，不能带 %04d）
            local img_mode = tostring(plan.settings.image_mode or ""):lower()
            local image_single_frame = (img_mode == "single" or img_mode == "current")
            local output
            if kind == "image" then
                -- 序列必须带 %04d 序号模板；拼图/单帧是单文件，不能带模板
                if image_sequence then
                    output = U.unique_path(outdir, stem.."_%04d", out_ext, cut_suffix)
                elseif image_single_frame then
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
            local function start_encode(run_pass)
                plan.settings.two_pass = run_pass
                plan.settings.passlogfile = passlog
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
                if run_pass == 1 then table.insert(args, #args, "-an") end
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
                    if job.cancel_progress_file then
                        U.remove_file_later(job.cancel_progress_file,1)
                        job.cancel_progress_file = nil
                    end
                    if job.cancel_requested then
                        if image_sequence then U.remove_image_sequence(temp) else U.remove_file_later(temp,1) end
                        cleanup_passlog()
                        next_one()
                        return
                    end
                    if not (success and res and res.status == 0) then
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
                        request_render(true)
                        start_encode(2)
                        return
                    end
                    job.stage="committing"; request_render(true)
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
                        -- 只清自己的临时帧：按 output 模板删除会把上一次导出的整组帧一起抹掉
                        if image_sequence then
                            U.remove_image_sequence(temp)
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
            local function run_smart_segment(smart)
                local work = U.work_directory(outdir)
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
                local function run_step(args, progress_length, on_done)
                    add_progress_args(args, start_progress_monitor(job.current_temp or temp, progress_length))
                    local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stderr=true,args=args},
                        function(success, res, err)
                            job.async_id = nil
                            stop_progress_monitor(true)
                            if job.cancel_requested then
                                local cur = job.current_temp
                                cleanup_parts()
                                -- 智能切割可能已推进到 concat 步骤：此时 current_temp 就是最终 .part，
                                -- 不清掉会在原目录留一个大孤儿文件（finish_job 会把引用置空，之后就找不回来了）
                                U.remove_file_later(cur, 1)
                                next_one(); return
                            end
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

            if not size_two_pass and not accurate_mode_snapshot and plan.settings.smart_cut == true then
                local smart, reason = smart_cut_segment_plan(source_path_snapshot, seg, plan.settings, plan.tracks)
                if smart then
                    run_smart_segment(smart)
                    return
                elseif reason and reason ~= "off" and reason ~= "aligned" then
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
    end, selected_seconds, prepared_accurate)
end
M.run_cut = run_cut

local function run_merge(kind)
    kind = kind or "video"
    if job.running or job.preparing then M.cancel_export(); return end
    job.smart_skip = nil
    local input,queue=mp.get_property("path"),get_queue()
    if not U.valid_local_file(input) then show_hint(L("hint.not_local_file"),3,"error"); return end
    if #queue==0 then
        if kind=="image" then
            if tostring(opts.image_mode or ""):lower() == "current" then
                local pos = mp.get_property_number("time-pos")
                local duration = mp.get_property_number("duration")
                if not pos then show_hint(L("hint.frame_save_failed"),4,"error"); return end
                queue = {{id="current", start_time=pos, end_time=math.min(pos + 0.05, duration or (pos + 0.05))}}
            else
                show_hint(L("hint.image_need_segments"),4,"error"); return
            end
        else
            local whole=whole_file_segment()
            if not whole then show_hint(L("hint.whole_media_no_duration"),4,"error"); return end
            queue={whole}
        end
    end
    local source=input; local tracks=selected_tracks()
    if kind == "subtitle" then
        if tracks.subtitle==nil and tracks.subtitle_external==nil and tracks.subtitle_first==nil then
            show_hint(L("hint.no_subtitle_track"),3,"error"); return
        end
        if #queue > 1 then show_hint(L("hint.subtitle_no_merge"),5,"error"); return end
    elseif kind == "image" then
        local image_mode = tostring(opts.image_mode or "sequence"):lower()
        if image_mode ~= "tile" or #queue > 1 then
            show_hint(L("hint.image_no_merge"),5,"error"); return
        end
    elseif tracks.video==nil and tracks.audio==nil then
        show_hint(L("hint.no_tracks_merge"),3,"error"); return
    end
    local prepared_accurate = Crop.effective_accurate_mode(opts, state.accurate_mode, "merge") == true
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
        local loud = apply_audio_normalization(plan.settings)
        if loud then
            show_hint(L("hint.loudness_applied", string.format("%.1f", loud.i),
                tostring(plan.settings.loudness_target_i)), 4)
        end
        coerce_audio_copy_for_container(plan.settings)
        coerce_video_copy_for_container(plan.settings)
        -- 去静音段的结果提示（整段都是静音时必须中止，否则会产出空文件）
        if not report_silence_plan(plan) then return end

        queue,tracks=plan.queue,plan.tracks
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
        local whole = #queue==1 and queue[1].id=="whole"
        local merge_names = {}
        for i, seg in ipairs(queue) do
            local lab = tostring(seg.label or "")
            merge_names[i] = (lab ~= "" and lab ~= L("hint.segment_label", seg.id)) and lab or ""
        end
        local tpl_on = tostring(opts.output_name_template or "") ~= ""
        local output=U.unique_path(outdir, U.merge_output_base(base, merge_names, whole, 48), ext,
            tpl_on and "" or nil)
        local final_temp=U.temp_output_path(output); U.remove_file(final_temp)
        local work=U.work_directory(outdir); local total=0; for _,seg in ipairs(queue) do total=total+(seg.end_time-seg.start_time) end
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
        local merge_accurate = Crop.effective_accurate_mode(plan.settings, plan.requested_accurate_mode, "merge")
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
        local smart_plans, smart_skip_reason, smart_skip_index
        if plan.settings.smart_cut == true and merge_accurate then
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
            if not ok_start then job.async_id=nil; fail(args, "subprocess async start failed: " .. tostring(start_err), "joining"); return end
            job.async_id = ok_start
        end
        local encode_next
        local function smart_encode_segment(seg, smart, segment_index)
            local length = seg.end_time - seg.start_time
            local head_length = smart.head_end - smart.head_start
            local tail_length = smart.tail_end - smart.head_end
            local head = utils.join_path(work, string.format("%s.merge.%03d.head.mkv", base, segment_index))
            local tail = utils.join_path(work, string.format("%s.merge.%03d.tail.mkv", base, segment_index))
            U.remove_file(head); U.remove_file(tail)
            table.insert(job.work_files, head); table.insert(job.work_files, tail)
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
            if not ok_start then
                stop_progress_monitor(true)
                U.remove_file_later(part,1)
                fail(args, "subprocess async start failed: " .. tostring(start_err), "encoding", segment_index, seg)
                return
            end
            job.async_id = ok_start
        end
        encode_next()
    end, nil, prepared_accurate)
end
M.run_merge = run_merge

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
    local settings = {}
    for k, v in pairs(opts) do settings[k] = v end
    settings.image_mode = "current"
    local tpl_stem = U.apply_name_template(opts.output_name_template,
        {name = base, in_time = pos, out_time = pos})
    local output = U.unique_path(outdir, (tpl_stem or base) .. "_frame", out_ext,
        tpl_stem and "" or nil)
    if config.ffmpeg_missing() then
        if U.commit_screenshot(source, outdir, output, {ext = out_ext,
                width = settings.image_width}) then
            show_hint(L("hint.frame_saved", output), 4, "success")
        else
            show_hint(L("hint.frame_save_failed"), 4, "error")
        end
        return
    end
    local temp = U.temp_output_path(output)
    U.remove_file(temp)
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

function M.shutdown_cleanup()
    if job.running then M.cancel_export() end
    local progress_file = job.progress_file
    stop_progress_monitor(false)
    local is_image_sequence = job.plan and job.plan.settings and image_output_is_sequence(job.plan.settings)
    if is_image_sequence and job.current_temp then U.remove_image_sequence(job.current_temp) end
    if job.cancel_progress_file then U.remove_file(job.cancel_progress_file); job.cancel_progress_file = nil end
    if progress_file then U.remove_file(progress_file) end
    U.remove_file(job.current_temp)
    for _,path in ipairs(job.work_files or {}) do U.remove_file(path) end
    if job.concat_list then U.remove_file(job.concat_list) end
    if progress_file then U.remove_file(progress_file) end
end

return M
