-- quick_cut 通用工具
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

local M = {}
local deps = {}

-- deps（由 core 注入，允许迟绑定）:
--   opts, show_hint, encode_summary
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

-- 按"字符"（非字节）截断长文本：中文路径/stderr 按字节切会落在多字节序列中间，
-- libass 渲染出乱码、日志里出现半个字。from_end=true 保留尾部（路径与 stderr 的尾部信息量最大），
-- 否则保留头部。结果恰好 max 个字符（含省略号）。
-- 全仓库唯一实现：ui.lua 经 ctx 注入使用，export.lua 直接用 U.truncate_chars，勿再各写一份。
function M.truncate_chars(s, max, from_end)
    s = tostring(s or "")
    local chars = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    if #chars <= max then return s end
    if from_end == "middle" then
        -- 中间省略：路径类提示既要保住动作名（"已保存当前帧："）又要保住文件名，
        -- 只留头或只留尾都会丢掉一半关键信息；头部留 40%、尾部留其余
        local keep = math.max(2, max - 1)
        local head = math.max(1, math.floor(keep * 0.4))
        local tail = keep - head
        return table.concat(chars, "", 1, head) .. "…" .. table.concat(chars, "", #chars - tail + 1)
    end
    if from_end then return "…" .. table.concat(chars, "", #chars - max + 2) end
    return table.concat(chars, "", 1, max - 1) .. "…"
end

-- 用户输入的名称 → 安全文件名片段：Windows 不允许 < > : " / \ | ? * 与控制字符，
-- 结尾的点和空格同样非法（"take 1." 建不出文件）；再截断到 max 个字符。
-- 结果为空时回退 fallback，避免拼出 "_001_.mp4" 这种名字。
function M.safe_filename(s, max, fallback)
    local out = tostring(s or ""):gsub("[%z\1-\31<>:\"/\\|%?%*]", "_")
    out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s%.]+$", "")
    -- truncate_chars 的"恰好 max 个字符"含省略号，这里去掉省略号后要的就是 max 个 ⇒ 传 max+1
    out = M.truncate_chars(out, (tonumber(max) or 40) + 1, false):gsub("…$", "")
    -- 只对"彻底为空"兜底：全非法字符的名字会留下下划线（"___" 是合法文件名，比凭空换成 seg 更诚实）
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
    local h = math.floor(t/3600); local m = math.floor(t%3600/60); local sec = math.floor(t%60); local ms = math.floor((t-math.floor(t))*1000+0.5)
    if ms >= 1000 then ms = 0; sec = sec + 1 end
    return string.format("%02dh%02dm%02ds%03d", h, m, sec, ms)
end

-- 字宽模型（**唯一实现，改系数前务必复核**）：
-- 系数按 libass 实测校准（ffmpeg `ass`+`bbox` 滤镜量 ArialMT，fs=100，
-- PlayResX/Y 必须等于视频尺寸否则字体整体缩放；取 16 条真实提示文案做验证集）。
--   汉字 .76em；CJK 标点 / 全角 / 箭头等其它非 ASCII .66em；**拉丁扩展(Ê Ä)与西里尔(Ð Ñ) .53em**
--   ASCII 字母数字 .53em、窄标点 .12em、空格 .30em、'%' .85em
--   特殊码点：中点 .28em、省略号/项目符号 .85em、→ .89em、— .90em、– .50em
-- 校准结果：16 条文案最大偏差 ±6px@fs19。分档更粗的模型误差会到 ±17px 甚至 ±126px，
-- 表现为"提示卡右侧一大片空白 + 提前截断"，以及"文本右侧边距看起来不固定"（卡片宽度随模型误差飘）。
-- 改系数时请用同一方法复测。
-- 之所以按"首字节"分档而不是解 UTF-8 码点：拉丁扩展 D0/D1 等按字母宽度算即可，够用且更快。
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
            elseif b >= 0xE4 and b <= 0xE9 then w = w + .76      -- 汉字
            elseif b == 0xC2 or b == 0xC3 or b == 0xD0 or b == 0xD1 then w = w + .53  -- 拉丁/西里尔扩展
            else w = w + .66 end                                  -- CJK 标点 / 全角 / 箭头等
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
        -- 静默回退源目录会让用户误以为输出写进了配置目录；至少留一条日志可排查
        msg.warn("quick_cut: expand-path failed for output_directory='" ..
            tostring(opts.output_directory) .. "'; falling back to source directory")
        return input_dir
    end
    return expanded
end

function M.unique_path(dir, base, ext, suffix)
    -- suffix 默认 "_cut"（保持既有文件名）；传 "" 表示不追加 —— 自定义命名模板启用时用
    suffix = (suffix == nil) and "_cut" or tostring(suffix)
    local p = utils.join_path(dir, base .. suffix .. ext)
    local i = 1
    while utils.file_info(p) do
        p = utils.join_path(dir, string.format("%s%s_%d%s", base, suffix, i, ext)); i = i + 1
    end
    return p
end

-- 输出文件名的小模板（不是通用模板引擎，只认 4 个占位符）：
--   {name} 源名   {index} 片段序号(3 位)   {in} / {out} 起止时间码
-- 规则：
--   · 未识别的占位符**原样保留**（拼错时一眼能看出，不静默吞掉）；
--   · 占位符在该场景无值（如整片导出的 {index}）时替换为空串；
--   · 解析结果为空 / 全是非法字符时返回 nil，调用方回退默认命名（不会拼出 ".mp4" 这种文件）。
-- 清洗复用 safe_filename（Windows 非法字符、结尾点、长度上限 120 字符）。
function M.apply_name_template(tpl, ctx)
    tpl = tostring(tpl or "")
    if tpl == "" then return nil end
    ctx = ctx or {}
    -- 一律走函数式替换：值里出现 % 时不会被当成替换串的反向引用
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
    -- 先读目录、成功后再置位：原来先置位再 readdir，且失败被 `or {}` 吞成空表 ——
    -- 那样"首次失败"会被记成"已清理"，本进程内永久跳过，且没有任何痕迹。
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
    -- 建不出工作目录时会把 .part/.progress/失败诊断散落到用户的输出目录：必须留日志，
    -- 否则用户只看到输出目录里多出一堆文件而无从判断（同 output_dir_for 的回退告警）
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
        -- 诊断文件是排障的最后手段，写不出来必须留痕
        msg.warn("quick_cut: cannot write failure diagnostic: " .. tostring(path))
        return nil
    end
    -- 排障的最后手段：这一串写入/关闭一个都不能静默失败（磁盘满 / 文件被占用时
    -- 用户拿到的会是空或截断的诊断文件，日志里必须留痕），写失败也不返回"看起来有效"的路径。
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

function M.commit_output(temp_path, final_path)
    M.remove_file(final_path)
    local ok, err = os.rename(temp_path, final_path)
    if not ok then
        M.log_error("无法提交输出文件：" .. tostring(err))
        return false
    end
    return true
end

function M.temp_output_path(final_path)
    local dir, name = utils.split_path(final_path)
    local work = M.work_directory(dir)
    local stem, ext = name:match("^(.*)(%.[^./\\]+)$")
    return utils.join_path(work, (stem or name)..".part"..(ext or ""))
end

-- 图片序列的临时/最终路径都是含 %04d 的模板，file_info 与 os.rename 均无法直接作用于模板，
-- 必须扫描工作目录、按帧号逐个重命名。
local function esc_magic(s)
    return (tostring(s):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- 拆分模板：返回 "前缀, 后缀"（以 %04d 为界，纯文本查找，不走 pattern）。
local function split_template(name)
    local pos = tostring(name):find("%04d", 1, true)
    if not pos then return nil end
    return name:sub(1, pos - 1), name:sub(pos + 4)
end

local function sequence_frames(dir, name)
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

-- 把工作目录里的帧序列逐帧提交到最终模板名。任一帧失败即返回 false（已提交的帧留在最终位置，由调用方走诊断路径）。
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
        local ok, err = os.rename(utils.join_path(temp_dir, fname), fin)
        if not ok then
            -- 目标已存在（上次提交失败的残留帧）会令 Windows 的 rename 失败：
            -- 删掉旧帧重试一次，仍失败才按提交失败处理（真因不是 ffmpeg）
            os.remove(fin)
            ok, err = os.rename(utils.join_path(temp_dir, fname), fin)
        end
        if not ok then
            M.log_error("无法提交输出帧：" .. tostring(fin) .. "；" .. tostring(err))
            return false
        end
    end
    return true
end

-- 清理残留的临时帧序列（单文件版的 remove_file_later 对模板路径无效）。
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
    -- 括号截断 gsub 的第二返回值（替换计数）：工具函数若把计数漏到调用方，
    -- 会被 f:write 之类的多值参数列表当额外实参写进文件
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
    -- 异步启动失败时回调不会触发：不兜底会让"打开目录"点击毫无反应且无日志
    if not ok_start then
        M.log_error("无法打开输出目录（async start failed）：" .. tostring(start_err) .. "; " .. tostring(path))
        if deps.show_hint then deps.show_hint(L("hint.cannot_open_dir"), 3, "error") end
    end
end

function M.notify(title, body)
    if deps.show_hint then deps.show_hint(title .. "\n" .. body, 4) end
    if package.config:sub(1, 1) ~= "\\" then return end
    local function ps(s) return tostring(s):gsub("[\r\n]", " "):gsub("'", "''") end
    -- `$t = @(...)` 的 @ 不能去掉：GetElementsByTagName 返回的是**活** XmlNodeList，
    -- 往 $t[0] 里 AppendChild 会在枚举过程中修改集合，PowerShell 直接抛
    -- "Collection was modified; enumeration operation may not execute."，
    -- 于是 $t[1] 变成 null、通知永远发不出去（日志里是两条 BadEnumeration /
    -- InvokeMethodOnNull 报错）。@() 先拍成数组快照，后续下标访问才安全。
    local script = string.format("[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null;$x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);$t=@($x.GetElementsByTagName('text'));$t[0].AppendChild($x.CreateTextNode('%s'))|Out-Null;$t[1].AppendChild($x.CreateTextNode('%s'))|Out-Null;$n=[Windows.UI.Notifications.ToastNotification]::new($x);[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('mpv').Show($n)", ps(title), ps(body))
    local ok_start, start_err = mp.command_native_async({name="subprocess", playback_only=false, args={"powershell","-NoProfile","-WindowStyle","Hidden","-Command",script}}, function() end)
    -- 系统通知是尽力而为（脚本内 hint 已提示），但启动失败必须留痕，否则"通知从不出现"无从排查
    if not ok_start then msg.warn("quick_cut: notify subprocess failed to start: " .. tostring(start_err)) end
end

-- 切分参数字符串：按空白分隔，支持单/双引号包裹含空格的整体（用于 -x265-params "k=v k2=v2" 这类值）。
-- 字符级状态机：引号内的空白并入 token；不支持引号内转义、不做变量展开（非 shell 语义）。
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

-- 过滤会破坏剪切流水线的危险参数（-i/-ss/-t/-to 由脚本控制）
function M.safe_extra_args(args)
    local blocked, out = {["-i"]=true, ["-ss"]=true, ["-t"]=true, ["-to"]=true}, {}
    for _, a in ipairs(args or {}) do
        if blocked[a] then
            msg.warn("quick_cut: ignored reserved ffmpeg option in extra args: " .. a)
        else
            out[#out+1] = a
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

-- ============================================================================
-- 可执行文件定位（ffmpeg / ffprobe）
-- 配置值是裸名（走 PATH）或路径（走文件校验）。裸名在 PATH 里找不到时，再按
-- "脚本自身目录及其上级 → 常见安装路径"查找一遍：便携安装（mpv 目录、portable_config）
-- 下放 ffmpeg.exe 是常见用法，为此让用户手改 conf 不划算。
-- 返回 resolved, source：
--   source = "configured"（显式路径且存在）/ "path"（裸名已在 PATH 中，原样返回）
--          / "script-dir" / "common"（自动定位到的新路径）
-- 全部失败返回 nil（调用方保持原值，让原有的"未找到 ffmpeg"链路照常报错）。
-- ============================================================================
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
        -- 显式路径：只按原样（含 ~ 展开）校验，不做任何"猜别的目录"
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
                -- 便携包常见布局：<目录>\bin\ffmpeg.exe
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
