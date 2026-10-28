local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

local M = {}
local deps = {}

function M.init(d)
    if d then for k, v in pairs(d) do deps[k] = v end end
end
local function L(...) if deps.L then return deps.L(...) end end

function M.log_error(text)
    msg.error(tostring(text))
end

function M.copy_value(value)
    if type(value) ~= "table" then return value end
    local out = {}; for k, v in pairs(value) do out[k] = M.copy_value(v) end; return out
end

function M.format_time(t)
    if t == nil then return "--:--:--.---" end
    t = math.max(0, t)
    return string.format("%02d:%02d:%06.3f", math.floor(t/3600), math.floor(t%3600/60), t%60)
end

function M.truncate_chars(s, max, from_end)
    s = tostring(s or "")
    local chars = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    if #chars <= max then return s end
    if from_end == "middle" then
        local keep = math.max(2, max - 1)
        local head = math.max(1, math.floor(keep * 0.4))
        local tail = keep - head
        return table.concat(chars, "", 1, head) .. "…" .. table.concat(chars, "", #chars - tail + 1)
    end
    if from_end then return "…" .. table.concat(chars, "", #chars - max + 2) end
    return table.concat(chars, "", 1, max - 1) .. "…"
end

function M.safe_filename(s, max, fallback)
    local out = tostring(s or ""):gsub("[%z\1-\31<>:\"/\\|%?%*]", "_")
    out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s%.]+$", "")
    out = M.truncate_chars(out, (tonumber(max) or 40) + 1, false):gsub("…$", "")
    if out == "" then return fallback or "seg" end
    return out
end

-- 合并导出的文件名主体（纯函数，便于单测）：
--   · whole=true（整片转码，队列里只有一个 id=="whole"）→ 直接用源名，unique_path 会再加 _cut
--   · 有自定义名 → <base>_<名字1>+<名字2>+… ：每个名字做文件名安全化并截到 20 字符；
--     再放不下下一段时以 "+N" 收尾（N = 没进名字的段数，**"+N" 本身不计入 max_chars**），不静默丢信息
--   · 全都没命名 → 保持原样 <base>_merged_<N>clips
-- names[i] 为 ""（或 nil）表示该段未命名，用 #序号 占位（顺序信息不丢，便于对回片段列表）。
-- **未命名请传空串而非 nil**：nil 会在数组里留空洞，ipairs 会提前结束、后面的片段被静默丢掉。
-- 长度按**字符**（不是字节）计：参数名与语义都是"字符"，中文名若按字节算会 3 倍高估长度，
-- 后面的片段还没轮到就被 "+N" 收掉（实测两个 19 字中文名时第二个名字整个没了）。
function M.merge_output_base(base, names, whole, max_chars)
    local list = names or {}
    base = tostring(base or "")
    if whole then return base end
    local parts, named = {}, 0
    for i, name in ipairs(list) do
        if name ~= nil and tostring(name) ~= "" then
            named = named + 1
            parts[#parts + 1] = M.safe_filename(name, 20)
        else
            parts[#parts + 1] = "#" .. i
        end
    end
    if named == 0 then return string.format("%s_merged_%dclips", base, #list) end
    local limit = tonumber(max_chars) or 48
    local function clen(v)
        local n = 0
        for _ in tostring(v):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
        return n
    end
    local s, kept = "", 0
    for _, p in ipairs(parts) do
        local add = (kept == 0) and p or ("+" .. p)
        if clen(s) + clen(add) > limit and kept > 0 then break end
        s = s .. add; kept = kept + 1
    end
    if kept < #parts then s = s .. "+" .. (#parts - kept) end
    return base .. "_" .. s
end

function M.safe_time_token(t)
    t = math.max(0, tonumber(t) or 0)
    -- 先四舍五入到整数毫秒再拆位：只对毫秒进位会让 59.9999 变成 "00h00m60s000"
    local total = math.floor(t * 1000 + 0.5)
    local ms = total % 1000
    local sec = math.floor(total / 1000) % 60
    local min = math.floor(total / 60000) % 60
    local hour = math.floor(total / 3600000)
    return string.format("%02dh%02dm%02ds%03d", hour, min, sec, ms)
end

local ASCII_NARROW={[32]=.30,[46]=.12,[44]=.12,[58]=.12,[59]=.12,[33]=.12,[124]=.12,[39]=.12,
    [45]=.12,[47]=.12,[40]=.12,[41]=.12,[91]=.12,[93]=.12}
local UNI_SPECIAL={["\194\183"]=.28,["\226\128\162"]=.28,["\226\128\166"]=.85,
    ["\226\134\146"]=.89,["\226\128\148"]=.90,["\226\128\147"]=.50}
function M.text_width(text, fs)
    local w = 0
    for ch in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local b = ch:byte(1)
        if b < 0x80 then
            if b == 0x25 then w = w + .85
            else w = w + (ASCII_NARROW[b] or .53) end
        else
            local sp = UNI_SPECIAL[ch]
            if sp then w = w + sp
            elseif b >= 0xE4 and b <= 0xE9 then w = w + .76
            elseif b == 0xC2 or b == 0xC3 or b == 0xD0 or b == 0xD1 then w = w + .53
            else w = w + .66 end
        end
    end
    return math.floor(w * fs + 2)
end

function M.valid_local_file(path)
    if not path or path == "" or path:match("^%a+://") or path:match("^ytdl://") or path:match("^-") then return false end
    local info = utils.file_info(path)
    return info and info.is_file
end

function M.output_dir_for(input_dir)
    local opts = deps.opts or {}
    if opts.output_directory == "" then return input_dir end
    local expanded = mp.command_native({"expand-path", opts.output_directory})
    if not expanded or expanded == "" then
        msg.warn("quick_cut: expand-path failed for output_directory='" ..
            tostring(opts.output_directory) .. "'; falling back to source directory")
        return input_dir
    end
    return expanded
end

-- 前置声明：unique_path 要用它，而它的实现在本文件靠后。Lua 闭包只捕获**已声明**的
-- 局部变量，写成后置的 local function 会让这里的引用永远解析成全局 nil。
local sequence_frames

-- 占名判断：序列模板（含 %04d）不能用 file_info 直接探测——那查的是字面名字，永远不存在，
-- 于是每次导出都拿到同一个名字、逐帧覆盖上一组。必须按"该模板是否已有帧"判断。
local function path_taken(dir, name)
    local frames = sequence_frames and sequence_frames(dir, name)
    if frames then return next(frames) ~= nil end
    return utils.file_info(utils.join_path(dir, name)) ~= nil
end

function M.unique_path(dir, base, ext, suffix)
    suffix = (suffix == nil) and "_cut" or tostring(suffix)
    local name = base .. suffix .. ext
    local i = 1
    while path_taken(dir, name) do
        name = string.format("%s%s_%d%s", base, suffix, i, ext); i = i + 1
    end
    return utils.join_path(dir, name)
end

function M.apply_name_template(tpl, ctx)
    tpl = tostring(tpl or "")
    if tpl == "" then return nil end
    ctx = ctx or {}
    local function rep(pat, v) tpl = tpl:gsub(pat, function() return tostring(v or "") end) end
    rep("{name}", ctx.name)
    local idx = tonumber(ctx.index)
    rep("{index}", idx and string.format("%03d", idx) or "")
    rep("{in}", ctx.in_time and M.safe_time_token(ctx.in_time) or "")
    rep("{out}", ctx.out_time and M.safe_time_token(ctx.out_time) or "")
    local out = M.safe_filename(tpl, 120, "")
    if out == "" then return nil end
    return out
end

function M.ensure_directory_quiet(path)
    if not path or path == "" then return false end
    local info = utils.file_info(path)
    if info then return info.is_dir == true end
    local result
    if package.config:sub(1,1) == "\\" then
        -- 不能用 New-Item：Windows PowerShell 5.1 的 New-Item **没有 -LiteralPath**
        -- （只有 -Path，会当通配符解析），用它会直接报 ParameterBindingException，
        -- 于是所有"目录不存在"的场景全部失败——.quickcut 工作目录建不出来、临时文件
        -- 与失败诊断被散落到用户的输出目录。.NET 的 CreateDirectory 按字面量处理路径、
        -- 且会自动补建中间目录，语义正好。
        local escaped = tostring(path):gsub("'", "''")
        result = mp.command_native({name="subprocess",playback_only=false,capture_stderr=true,
            args={"powershell","-NoProfile","-Command","[System.IO.Directory]::CreateDirectory('"..escaped.."') | Out-Null"}})
    else
        result = mp.command_native({name="subprocess",playback_only=false,capture_stderr=true,args={"mkdir","-p",path}})
    end
    local after = utils.file_info(path)
    return result and result.status==0 and after and after.is_dir==true
end

function M.ensure_output_directory(path)
    return M.ensure_directory_quiet(path)
end

local cleaned_workdirs = {}
local function stale_candidate(name)
    return name:match("%.progress$") or name:match("%.part%.[^%.]+$")
        or name:match("%.concat%.txt$") or name:match("%.merge%.%d+%.[^%.]+$")
end

function M.cleanup_stale_workdir(path)
    local opts = deps.opts or {}
    if not opts.cleanup_stale_tasks or cleaned_workdirs[path] then return end
    local names, derr = utils.readdir(path, "files")
    if not names then
        msg.warn("quick_cut: stale cleanup skipped, cannot list workdir: "
            .. tostring(path) .. " (" .. tostring(derr) .. ")")
        return
    end
    cleaned_workdirs[path] = true
    local now, max_age = os.time(), (tonumber(opts.stale_task_days) or 7) * 86400
    for _, name in ipairs(names) do
        if stale_candidate(name) and not name:match("^failure%-") then
            local full = utils.join_path(path, name); local info = utils.file_info(full)
            local mtime = info and tonumber(info.mtime)
            if mtime and now - mtime > max_age then
                local ok, err = os.remove(full)
                if not ok then msg.warn("stale cleanup failed: " .. tostring(full) .. "; " .. tostring(err)) end
            end
        end
    end
end

function M.work_directory(output_dir)
    local path = utils.join_path(output_dir, ".quickcut")
    if M.ensure_directory_quiet(path) then M.cleanup_stale_workdir(path); return path end
    msg.warn("quick_cut: cannot create work dir '" .. tostring(path) .. "'; writing temp/diagnostic files into the output dir")
    return output_dir
end

function M.write_failure_diagnostic(kind, input, output, queue, args, stderr, outdir, detail)
    local opts = deps.opts or {}
    if opts.diagnostic_location == "off" then return nil end
    local dir = M.work_directory(outdir)
    local path = utils.join_path(dir, "failure-"..os.date("%Y%m%d-%H%M%S")..".txt")
    local f = io.open(path, "w")
    if not f then
        msg.warn("quick_cut: cannot write failure diagnostic: " .. tostring(path))
        return nil
    end
    local wrote = true
    local function w(...)
        if not wrote then return end
        local ok, werr = f:write(...)
        if not ok then
            wrote = nil
            msg.warn("quick_cut: failure diagnostic write failed: " .. tostring(werr))
        end
    end
    w("quick_cut v", tostring(deps.version or "unknown"), "\noperation: ", tostring(kind), "\ninput: ", tostring(input), "\noutput: ", tostring(output), "\n")
    if detail then
        w("stage: ", tostring(detail.stage or "unknown"), "\nsegment: ", tostring(detail.index or "-"), "/", tostring(detail.total or "-"), "\n")
        if detail.segment then w(string.format("range: %.6f -> %.6f\n", detail.segment.start_time, detail.segment.end_time)) end
        if detail.validation then w("validation: ", tostring(detail.validation), "\n") end
    end
    local summary = deps.encode_summary and deps.encode_summary() or ""
    w("settings: ", summary, "\nsegments:\n")
    for i, seg in ipairs(queue or {}) do w(string.format("  %d: %.6f -> %.6f\n", i, seg.start_time, seg.end_time)) end
    w("ffmpeg args:\n", table.concat(args or {}, " "), "\nstderr:\n", tostring(stderr or "unknown"), "\n"); local closed, cerr = f:close()
    if not closed then msg.warn("quick_cut: failure diagnostic close failed: " .. tostring(cerr)) end
    if not wrote or not closed then return nil end
    return path
end

function M.remove_file(path)
    if path and path ~= "" and utils.file_info(path) then
        local ok, err = os.remove(path)
        if not ok then M.log_error("无法删除临时文件：" .. path .. "；" .. tostring(err)) end
    end
end

function M.remove_file_later(path, attempt)
    if not path or path == "" then return end
    attempt = attempt or 1
    mp.add_timeout(0.15*attempt, function()
        if not utils.file_info(path) then return end
        local ok, err = os.remove(path)
        if not ok then
            if attempt < 4 then M.remove_file_later(path, attempt+1)
            else M.log_error("无法删除临时文件（重试耗尽）：" .. path .. "；" .. tostring(err)) end
        end
    end)
end

-- 提交 = 把临时文件改名成最终名字。目标已存在时**绝不删除**：它可能是上一次的导出，
-- 也可能是别的进程刚写下的文件。此时判失败并保留 temp，由调用方提示。
function M.commit_output(temp_path, final_path)
    if utils.file_info(final_path) then return false, "exists" end
    local ok, err = os.rename(temp_path, final_path)
    if not ok then
        M.log_error("无法提交输出文件：" .. tostring(err))
        return false, tostring(err)
    end
    return true
end

-- 原子替换（Windows 上 os.rename 不能覆盖已存在文件）：旧文件先改名为 .bak，
-- 再让 tmp 上位，成功后才删 .bak；任何一步失败都把 .bak 恢复回去。
-- 语义保证：要么新内容生效，要么旧文件原样还在，绝不同时丢（session/config 共用）。
function M.replace_file(temp_path, final_path)
    local bak = final_path .. ".bak"
    local had_old = utils.file_info(final_path) ~= nil
    if had_old then
        if utils.file_info(bak) then os.remove(bak) end
        local ok, err = os.rename(final_path, bak)
        if not ok then return false, "backup: " .. tostring(err) end
    end
    local ok, err = os.rename(temp_path, final_path)
    if not ok then
        if had_old then
            local restored, rerr = os.rename(bak, final_path)
            if not restored then
                M.log_error("无法恢复备份文件：" .. tostring(bak) .. "；" .. tostring(rerr))
            end
        end
        return false, tostring(err)
    end
    if had_old then os.remove(bak) end
    return true
end

function M.temp_output_path(final_path)
    local dir, name = utils.split_path(final_path)
    local work = M.work_directory(dir)
    local stem, ext = name:match("^(.*)(%.[^./\\]+)$")
    return utils.join_path(work, (stem or name)..".part"..(ext or ""))
end

local function esc_magic(s)
    return (tostring(s):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function split_template(name)
    local pos = tostring(name):find("%04d", 1, true)
    if not pos then return nil end
    return name:sub(1, pos - 1), name:sub(pos + 4)
end

sequence_frames = function(dir, name)
    local prefix, suffix = split_template(name)
    if not prefix then return nil end
    local pat = "^" .. esc_magic(prefix) .. "(%d+)" .. esc_magic(suffix) .. "$"
    local frames = {}
    for _, fname in ipairs(utils.readdir(dir, "files") or {}) do
        local n = fname:match(pat)
        if n then frames[tonumber(n)] = fname end
    end
    return frames
end

function M.commit_image_sequence(temp_template, final_template)
    local temp_dir, temp_name = utils.split_path(temp_template)
    local final_dir, final_name = utils.split_path(final_template)
    local fprefix, fsuffix = split_template(final_name)
    local frames = sequence_frames(temp_dir, temp_name)
    if not fprefix or not frames then return false end
    local count = 0
    for _ in pairs(frames) do count = count + 1 end
    if count == 0 then return false end
    for n, fname in pairs(frames) do
        local fin = utils.join_path(final_dir, string.format("%s%04d%s", fprefix, n, fsuffix))
        -- 重名不删旧帧：删掉再取名会把上一次导出的帧永久抹掉（目录里可能还有更高编号的旧帧），
        -- 直接判失败并把 temp 留着，让调用方提示"名字被占用"。
        if utils.file_info(fin) then
            M.log_error("无法提交输出帧（目标已存在）：" .. tostring(fin))
            return false
        end
        local ok, err = os.rename(utils.join_path(temp_dir, fname), fin)
        if not ok then
            M.log_error("无法提交输出帧：" .. tostring(fin) .. "；" .. tostring(err))
            return false
        end
    end
    return true
end

function M.remove_image_sequence(template)
    if not template or template == "" then return end
    local dir, name = utils.split_path(template)
    local frames = sequence_frames(dir, name)
    if not frames then return end
    for _, fname in pairs(frames) do
        local ok, err = os.remove(utils.join_path(dir, fname))
        if not ok then M.log_error("无法删除临时帧：" .. tostring(fname) .. "；" .. tostring(err)) end
    end
end

function M.escape_concat_path(path)
    return (tostring(path):gsub("'", "'\\''"))
end

function M.open_directory(path)
    if not path or path == "" then
        if deps.show_hint then deps.show_hint(L("hint.no_output_dir"), 2) end
        return
    end
    local args
    if package.config:sub(1,1) == "\\" then args = {"explorer", path}
    elseif jit and jit.os == "OSX" then args = {"open", path}
    else args = {"xdg-open", path} end
    local ok_start, start_err = mp.command_native_async({name="subprocess", playback_only=false, detach=true, args=args}, function(success, res, err)
        if not success or (res and res.status and res.status ~= 0) then
            M.log_error("无法打开输出目录："..tostring(err or (res and res.stderr) or path))
            if deps.show_hint then deps.show_hint(L("hint.cannot_open_dir"), 3, "error") end
        end
    end)
    if not ok_start then
        M.log_error("无法打开输出目录（async start failed）：" .. tostring(start_err) .. "; " .. tostring(path))
        if deps.show_hint then deps.show_hint(L("hint.cannot_open_dir"), 3, "error") end
    end
end

function M.commit_screenshot(source, outdir, output, opts)
    opts = opts or {}
    local work = M.work_directory(outdir)
    local ext = tostring(opts.ext or ".png"):lower()
    if ext == ".jpeg" then ext = ".jpg" end
    local stem = tostring(output or ""):match("([^/\\]+)%.[^.]*$") or "frame"
    local capture = string.format("%s/%s_shot%s", work, stem,
        (ext == ".png" or ext == ".jpg" or ext == ".webp" or ext == ".jxl") and ext or ".png")
    M.remove_file(capture)
    local flags = {}
    -- 注意：screenshot 一旦带上 format/quality/high_bit_depth 就隐式要求 --vo=gpu，
    -- 软解/非 GPU 输出下 mpv 直接报 "Format selection requires the GPU vo" 并失败。
    -- 兜底路径不能因为"想套用格式"反而存不出图，所以这里只传 scale。
    local scale = math.floor(tonumber(opts.width) or 0)
    if scale > 0 then flags.scale = scale end
    local ok = pcall(mp.command_native, {name = "screenshot", filename = capture, flags = flags})
    if not ok then
        M.remove_file(capture)
        M.log_error("mpv screenshot fallback failed: " .. tostring(capture))
        return false
    end
    M.ensure_output_directory(outdir)
    if not M.commit_output(capture, output) then
        M.remove_file(capture)
        return false
    end
    return true
end

function M.notify(title, body)
    if deps.show_hint then deps.show_hint(title .. "\n" .. body, 4) end
    if package.config:sub(1, 1) ~= "\\" then return end
    local function ps(s) return tostring(s):gsub("[\r\n]", " "):gsub("'", "''") end
    local script = string.format("[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null;$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);$t=@($x.GetElementsByTagName('text'));$t[0].AppendChild($x.CreateTextNode('%s'))|Out-Null;$t[1].AppendChild($x.CreateTextNode('%s'))|Out-Null;$n=[Windows.UI.Notifications.ToastNotification]::new($x);[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('mpv').Show($n)", ps(title), ps(body))
    local ok_start, start_err = mp.command_native_async({name="subprocess", playback_only=false, args={"powershell","-NoProfile","-WindowStyle","Hidden","-Command",script}}, function() end)
    -- 系统通知是尽力而为（脚本内 hint 已提示），但启动失败必须留痕，否则"通知从不出现"无从排查
    if not ok_start then msg.warn("quick_cut: notify subprocess failed to start: " .. tostring(start_err)) end
end

function M.split_args(value)
    local out, token, quote = {}, nil, nil
    for ch in tostring(value or ""):gmatch(".") do
        if quote then
            if ch == quote then quote = nil
            else token = token .. ch end
        elseif ch == "'" or ch == '"' then
            quote = ch
            if not token then token = "" end
        elseif ch:match("%s") then
            if token and token ~= "" then out[#out + 1] = token; token = nil end
        else
            token = (token or "") .. ch
        end
    end
    if token and token ~= "" then out[#out + 1] = token end
    return out
end

-- 过滤保留参数：-i/-ss/-t/-to 会与脚本自己的定位/时长参数打架。
-- 两种写法都要挡住：分离形式（-ss 5）连值一起丢——只丢选项名会把 5 留成输出文件名，
-- ffmpeg 会直接报 "Unable to choose an output format"；内联形式（-t=5）整 token 丢。
function M.safe_extra_args(args)
    local blocked = {["-i"] = true, ["-ss"] = true, ["-t"] = true, ["-to"] = true}
    local out, skip = {}, false
    for _, raw in ipairs(args or {}) do
        local a = tostring(raw)
        if skip then
            skip = false
            msg.warn("quick_cut: ignored reserved ffmpeg option value in extra args: " .. a)
        else
            local name = a:match("^(%-[%w:%.%-]+)=")
            local key = name or a
            if blocked[key] then
                msg.warn("quick_cut: ignored reserved ffmpeg option in extra args: " .. key)
                if not name then skip = true end
            else
                out[#out+1] = a
            end
        end
    end
    return out
end

function M.even_floor(value)
    value = math.max(2, math.floor(tonumber(value) or 2))
    return value - value % 2
end

function M.even_coordinate(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    return value - value % 2
end

local WINDOWS = package.config:sub(1,1) == "\\"

local function executable_names(name)
    if WINDOWS then return {name, name .. ".exe"} end
    return {name}
end

local function is_file(path)
    local info = utils.file_info(path)
    return (info and info.is_file) and true or false
end

local function has_dir_separator(path)
    return path:find("[/\\]") ~= nil
end

local function path_directories()
    local out, seen = {}, {}
    local pattern = WINDOWS and "[^;]+" or "[^:]+"
    for raw in (os.getenv("PATH") or ""):gmatch(pattern) do
        -- Windows 的 PATH 允许带引号的项；结尾分隔符统一去掉便于去重
        -- （泛型 for 的控制变量在 Lua 5.4 里是 const，不能就地赋值）
        local entry = raw:gsub('^"', ""):gsub('"$', ""):gsub("[/\\]+$", "")
        local key = entry:lower()
        if entry ~= "" and not seen[key] then seen[key] = true; out[#out + 1] = entry end
    end
    return out
end

local function common_directories()
    local out = {}
    if WINDOWS then
        local program_files = os.getenv("ProgramFiles") or "C:\\Program Files"
        local program_files_x86 = os.getenv("ProgramFiles(x86)")
        local local_app = os.getenv("LOCALAPPDATA")
        local profile = os.getenv("USERPROFILE")
        local program_data = os.getenv("ProgramData")
        out[#out + 1] = program_files .. "\\ffmpeg\\bin"
        if program_files_x86 then out[#out + 1] = program_files_x86 .. "\\ffmpeg\\bin" end
        out[#out + 1] = "C:\\ffmpeg\\bin"
        if local_app then out[#out + 1] = local_app .. "\\Microsoft\\WinGet\\Links" end
        if profile then out[#out + 1] = profile .. "\\scoop\\shims" end
        if program_data then out[#out + 1] = program_data .. "\\chocolatey\\bin" end
    else
        for _, dir in ipairs({"/usr/local/bin", "/usr/bin", "/opt/homebrew/bin", "/opt/local/bin", "/snap/bin"}) do
            out[#out + 1] = dir
        end
    end
    return out
end

function M.resolve_executable(value, extra_dirs)
    value = tostring(value or "")
    if value == "" then return nil end
    if has_dir_separator(value) then
        local expanded = mp.command_native({"expand-path", value})
        if type(expanded) ~= "string" or expanded == "" then expanded = value end
        for _, name in ipairs(executable_names(expanded)) do
            if is_file(name) then return name, "configured" end
        end
        return nil
    end
    local names = executable_names(value)
    for _, dir in ipairs(path_directories()) do
        for _, name in ipairs(names) do
            if is_file(utils.join_path(dir, name)) then return value, "path" end
        end
    end
    for _, dir in ipairs(extra_dirs or {}) do
        if dir and dir ~= "" then
            for _, name in ipairs(names) do
                local direct = utils.join_path(dir, name)
                if is_file(direct) then return direct, "script-dir" end
                local nested = utils.join_path(utils.join_path(dir, "bin"), name)
                if is_file(nested) then return nested, "script-dir" end
            end
        end
    end
    for _, dir in ipairs(common_directories()) do
        for _, name in ipairs(names) do
            local full = utils.join_path(dir, name)
            if is_file(full) then return full, "common" end
        end
    end
    return nil
end

return M
