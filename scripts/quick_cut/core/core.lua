-- quick_cut 运行时（编排层）
-- mpv + ffmpeg 剪辑操作台
-- 模块分工：config=选项与令牌初始化 / util=通用工具 / takeover=OSC 接管 /
-- editor=片段数据域 / crop=裁剪域 / export=导出流水线 / ui=渲染 / core=状态与编排

local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

-- 自定义参数输入依赖 mp.input（mpv >= 0.38）。用 pcall 兜底：
-- 万一运行在更老的版本上，只是禁用"自定义输入"这一项功能，脚本其余部分照常工作。
local mp_input = nil
do
    local ok, mod = pcall(require, "mp.input")
    if ok and mod and mod.get then
        mp_input = mod
    else
        msg.warn("quick_cut: mp.input unavailable (need mpv >= 0.38); custom parameter input disabled")
    end
end

local C = require "config"
local U = require "util"
local I18n = require "i18n"
local Takeover = require "takeover"
local Session = require "session"
local Editor = require "editor"
local Crop = require "crop"
local Export = require "export"
local UI = require "ui"

local opts, theme = C.load()

-- 语言必须在任何界面文本产生之前设定：auto 时按 mpv 的 osd-lang 选择已安装的语言包
local active_locale = I18n.set(opts.ui_language)

opts.ui_module_dir = (_G.QUICK_CUT_BOOTSTRAP and _G.QUICK_CUT_BOOTSTRAP.module_dir) or ""

-- ffmpeg/ffprobe 自动定位：便携安装常把可执行文件放在 mpv 目录或 portable_config 下，
-- 启动时扫一遍比让用户手改 conf 划算。只写日志、不改动用户显式给出的路径（定位失败
-- 时保持原值，让 check_ffmpeg 的"未找到 ffmpeg"提示照常工作）。
-- 探测结果同时记进全局：界面要据此把依赖 ffmpeg 的按钮置灰（core/ui.lua 的 FFMPEG_OFF）。
-- 注意这里**并不声称 ffmpeg 真的能跑**（路径存在但二进制坏了仍会在导出时报错），
-- 只回答"有没有找到"，所以导出前的 check_ffmpeg 仍然照跑，这里只是入口层的前置提示。
_G.QUICK_CUT_RUNTIME = _G.QUICK_CUT_RUNTIME or { ffmpeg_found = true, ffprobe_found = true }
do
    local dirs, dir = {}, opts.ui_module_dir
    for _ = 1, 4 do
        if not dir or dir == "" then break end
        dirs[#dirs + 1] = dir
        local trimmed = dir:gsub("[/\\]+$", "")
        dir = trimmed:match("^(.-)[/\\][^/\\]+$")
    end
    local found = {}
    for _, key in ipairs({"ffmpeg", "ffprobe"}) do
        local configured = tostring(opts[key] or "")
        local resolved, source = U.resolve_executable(configured, dirs)
        if resolved and source ~= "configured" and source ~= "path" then
            opts[key] = resolved
            msg.info(string.format("quick_cut: %s located automatically (%s): %s", key, source, resolved))
        elseif resolved then
            msg.info(string.format("quick_cut: %s resolved (%s): %s", key, source, tostring(opts[key])))
        else
            msg.warn(string.format(
                "quick_cut: %s not found (configured %q); looked in the script directory, PATH and common install paths",
                key, configured))
        end
        found[key] = resolved ~= nil
    end
    _G.QUICK_CUT_RUNTIME.ffmpeg_found = found.ffmpeg
    -- 没装 ffmpeg 时脚本仍能用 mpv 自带的编码模式兜底，所以这里只是 info 不是 warn
    if not found.ffmpeg then
        msg.info("quick_cut: ffmpeg missing - export falls back to mpv's own encoders (reduced feature set)")
    end
end
local ui=UI.new(opts)
local ui_tokens=ui:tokens_for_core()
C.apply_ui_tokens(ui_tokens)

-- 这里保留一个适配器：既有旧的点号访问（L.copy，片段列表在用），
-- 又支持新的键式调用（L("hint.in")，i18n 化的提示文本）。
-- setmetatable 的第一个参数必须是 table，所以用一个空表同时实现 __index（点号访问）
-- 与 __call（括号调用）。
local L = setmetatable({}, {
    __index = function(_, k)
        if type(k) == "string" then return I18n.t("modal." .. k) end
        return nil
    end,
    __call = function(_, key, ...)
        return I18n.t(key, ...)
    end,
})

local STAGE_LABELS = {
    preparing=L("stage.preparing"), building=L("stage.building"), exporting=L("stage.exporting"), committing=L("stage.committing"), encoding=L("stage.encoding"),
    validating=L("stage.validating"), joining=L("stage.joining"), stopping=L("stage.stopping"), running=L("stage.running"),
    pass1=L("stage.pass1"), pass2=L("stage.pass2"),
}

local state = {
    start_time = nil, end_time = nil, segments = {}, next_id = 1,
    accurate_mode = false, in_studio = false, modal = false,
    segment_scroll = 0, active_handle = "start", selected_segment_id = nil,
    crop_editing = false, crop_panel_hidden = false, crop_panel_pinned = false,   -- pinned=用户强制显示（压过自动隐藏）
    editing_id = nil, manual_order = false,
    crop_ratio_lock = nil,  -- 裁剪比例锁（"16:9" 等）：编辑中切换比例后拖拽仍按该比例约束；nil=自由
    optimize_goal = nil,    -- 当前优化目标（quality/speed/lossless/size），选择编码预设时复位
    goal_prev_accurate = nil, -- 设目标**之前**的准确模式开关：取消目标时按它还原（否则"快速复制"回不去）
    size_target = nil,      -- 限体积目标（MiB），optimize_goal=="size" 时有效
    input_active = false,   -- mp.input 输入期间为 true：渲染管线追加全屏压暗蒙版（render_ui）
    hud_hidden = false,     -- 裁剪编辑中主面板/时间轴是否被隐藏（进入编辑自动隐藏，快捷键呼出，退出恢复）
    deck_hidden = false,    -- 主剪辑台：按钮面板是否收起（只收按钮面板，时间轴保留；与裁剪的 hud_hidden 无关）
    flash_id = nil,         -- 动作类快捷键执行后短暂高亮的按钮 id（按悬停样式闪一下）
    hover_time = nil, hover_x = nil, confirm_action = nil,
    export_kind = "video", merge_output = false,
    param_dropdown = nil, dropdown_scroll = 0, dropdown_rect = nil, confirm_focus = nil,
    action_hint = nil, action_hint_until = 0, action_hint_token = 0, action_hint_level = "info",
    batch_preview = false, batch_index = 1,  -- 范围播放（选中 ≥2 段时按序连播，由 apply_segment_loop 推导）
    checked = {},          -- 播放范围：勾选的片段 id；为空时范围退化为当前聚焦的那一段
}

local request_render, update_ranges, show_hint, render_ui, mouse_click, get_queue
local toggle_segment_list, execute_cut, execute_merge, confirm_execute, execute_animated
local remember_action, install_main_bindings
local install_crop_bindings, install_confirm_bindings  -- 前向声明：定义在下面的键位段（do…end）内
local main_bindings, crop_bindings, confirm_bindings  -- 前向声明：渲染上下文（键位速查）需在赋值前引用
-- 前向声明（迟定义）：限体积目标的输入分支定义在它们之前，不声明会退化成全局 nil
local clear_all_context_bindings, mouse_move
local run_button  -- 前向声明：timeline_mouse_event 里要先用它做面板按钮命中
local open_crop_size_input  -- 前向声明：ctx 在文件前部构造，实现在后面（赋值式定义）
local toggle_waveform
local wave_cache  -- 前向声明：render_ui 的 ctx 在本声明之前构造，晚声明会退化为全局 nil
local apply_segment_loop, clear_segment_loop
-- 前向声明（迟定义）：选择辅助函数被更早定义的片段动作（编辑/导航）引用，
local focus_segment, clear_selection, toggle_range_of_focus, action_deselect, segment_action, history_context_ok, list_op, rename_segment

-- 取动作在绑定表中的主键（首个）：提示文案中的键名与 conf 改绑联动，不硬编码键名
local function primary_key(bindings, action)
    for _, b in ipairs(bindings or {}) do
        if b[2] == action then return b[1] end
    end
    return "?"
end

local crop_is_active = Crop.crop_is_active
local effective_accurate_mode = Crop.effective_accurate_mode

-- 模块注入表：函数字段均为迟绑定包装，供 crop/util/export 回调 core。
local deps = {opts=opts, theme=theme, state=state, version=C.VERSION, L=L}
deps.show_hint=function(...) return show_hint(...) end
deps.request_render=function(...) return request_render(...) end
deps.get_queue=function() return get_queue() end
-- 供无绑定表的域模块（export）在提示文案中引用当前键位
deps.primary_key=function(action) return primary_key(main_bindings, action) end
-- 裁剪面板/编辑器的开合会改变片段预览循环的合法性；crop.lua 在状态变更后调用此钩子。
deps.apply_segment_loop=function(...) return apply_segment_loop(...) end

local function input_context()
    if state.confirm_action then return "export_confirm" end
    if state.crop_editing then return "crop_editor" end
    if state.modal then return "segment_list" end
    return "main"
end

local function prepare_main_action()
    local context=input_context()
    if context~="main" then return false end
    return true
end

local overlay = mp.create_osd_overlay("ass-events")
-- mouse_bound 必须在 osd_below_input（下方）之前声明：闭包只捕获已声明的局部，
-- 否则 osd_below_input 内的赋值会静默写到全局变量而非本文件状态
local mouse_bound = false
overlay.z = 2000
-- mp.input 的输入框由内置 console 层绘制：z 固定 0、位置固定底部，脚本 API 不可配置。
-- 输入期间：自有 overlay 降层到 z=-1（console 之下），渲染管线在帧末尾追加全屏压暗
-- 蒙版（render_ui，坐标复用面板 res_x/res_y），画面与面板变暗、输入框浮在最上；
-- 关闭后恢复 2000。不选择自绘输入框：需逐键捕获、无法支持中文 IME。
local function osd_below_input()
    state.input_active = true
    overlay.z = -1
    -- 冻结全部鼠标交互：仅解绑还不够——mouse_move 观察器的 inside 判定含 confirm_action/
    -- modal 等状态，输入期间鼠标一动就会把点击绑定装回来（导致"输入框开着还能点按钮"）。
    -- 此处解绑 + 观察器入口按 input_active 拦截，双保险；closed 回调负责重装。
    for _, n in ipairs({"quick_cut_click", "quick_cut_wheel_up", "quick_cut_wheel_down"}) do mp.remove_key_binding(n) end
    mouse_bound = false
    -- 轻量蒙版帧：不渲染面板（输入期间交互冻结、无需刷新），只画一个半透明黑块铺满窗口。
    -- 实现用全块字符（U+2588 █）放大：libass 会缓存字形位图，首帧之后每帧零栅格化开销。
    -- 千万不要改回 ASS drawing 矩形：drawing 每帧按 bounding box 重新光栅化且不裁剪到
    local d = mp.get_property_native("osd-dimensions")
    local w, h = (d and d.w) or 1280, (d and d.h) or 720
    local fs = math.floor(h * 1.15)
    -- FULL BLOCK 的 advance 约为字高的 0.5~0.6 倍：横向拉伸并留足余量，溢出部分被窗口裁剪
    local fscx = math.ceil(w / (fs * 0.5) * 100) + 40
    overlay.res_x, overlay.res_y = w, h
    overlay.data = string.format([[{\an7\pos(0,%d)\fs%d\fscx%d\1c&H000000&\alpha&H66&}█]],
        -math.floor(h * 0.06), fs, fscx)
    overlay:update()
end
local function osd_restore()
    state.input_active = false
    overlay.z = 2000
    overlay.data = ""   -- 立即撤掉蒙版帧；随后的 request_render 用正常面板覆盖
    overlay:update()
end
local buttons = {}
local button_panel_bounds = {x1=0,y1=0,x2=0,y2=0}
local timeline_bounds = {x1=0,y1=0,x2=0,y2=0}
local hovered_id, hovered_tip = nil, nil
local render_timer, ranges_timer, action_hint_timer = nil, nil, nil
local render_pending, ranges_pending = false, false
local last_ranges_json = nil
local timeline_drag={down=false,active=false,kind=nil,handle=nil,seg=nil,start_x=0,last_time=nil,last_seek=0,was_paused=true,history_saved=false}
local history=Editor.new_history(50)

-- 最小片段长度：默认"1 帧"（剪辑的自然最小单位）；conf 的 min_segment_duration > 0 时
-- 作为额外的人工下限（秒），取两者较大者。分割/拖拽/时间码校验统一用它。
local function min_len()
    local frame = 1 / math.max(1, mp.get_property_number("estimated-vf-fps", mp.get_property_number("container-fps", 25)) or 25)
    local user = tonumber(opts.min_segment_duration) or 0
    return math.max(frame, user)
end

local function normalize_segment(s,e,duration)
    return Editor.normalize_segment(s,e,duration,min_len())
end

local function normalize_draft_segment()
    local duration = mp.get_property_number("duration", 0)
    local s, e = state.start_time, state.end_time
    if opts.draft_mode == "strict" and (s == nil or e == nil) then
        return nil, L("hint.need_both_marks")
    end
    return normalize_segment(s, e, duration)
end

request_render = function(immediate)
    if not state.in_studio then return end
    render_pending = true
    if immediate then
        if render_timer then render_timer:kill(); render_timer = nil end
        render_pending = false
        if render_ui then render_ui() end
        return
    end
    if render_timer then return end
    render_timer = mp.add_timeout(1 / math.max(10, tonumber(opts.render_fps) or 30), function()
        render_timer = nil
        if render_pending and state.in_studio then
            render_pending = false
            if render_ui then render_ui() end
        end
    end)
end

show_hint=function(message,duration,level)
    message=tostring(message or "")
    duration=tonumber(duration) or opts.action_hint_duration
    level=(level=="success" or level=="error") and level or "info"
    if not state.in_studio then mp.osd_message(message,duration); return end
    state.action_hint_token=(state.action_hint_token or 0)+1
    local token=state.action_hint_token
    state.action_hint,state.action_hint_level=message,level
    state.action_hint_until=mp.get_time()+duration
    if action_hint_timer then action_hint_timer:kill(); action_hint_timer=nil end
    request_render(true)
    action_hint_timer=mp.add_timeout(math.max(.05,state.action_hint_until-mp.get_time()),function()
        action_hint_timer=nil
        if state.action_hint_token~=token then return end
        state.action_hint_token=(state.action_hint_token or 0)+1
    state.action_hint,state.action_hint_until,state.action_hint_level=nil,0,"info"
    request_render(true)
    end)
    end

    -- 剪辑台内部小工具集：新增辅助一律挂在这个表上，不再新增顶层 local。
    -- 原因：core.lua 主 chunk 的局部变量已贴近 Lua 的上限 200，超限会让整个脚本加载失败
    -- （表现为 "quick_cut bootstrap failed"）。
    local MK = {}

    -- 按钮 flash：动作类快捷键执行成功时，让对应按钮按"悬停"样式短暂亮一下。
    -- 只用于自身没有任何状态变化的按钮（入点/出点/分割/清空），避免与"点亮即反馈"的按钮重复；
    -- 面板收起/模态打开时按钮不在场，设置状态也不会画出来，天然静默。
    function MK.flash(id)
        if not id then return end
        state.flash_id = id
        if MK.flash_timer then MK.flash_timer:kill() end
        MK.flash_timer = mp.add_timeout(0.18, function()
            MK.flash_timer = nil
            state.flash_id = nil
            request_render(true)
        end)
        request_render(true)
    end

local function build_ranges()
    local duration = mp.get_property_number("duration", 0)
    local ranges = {}
    for _, seg in ipairs(state.segments) do
        if seg.enabled ~= false then
            local n = normalize_segment(seg.start_time, seg.end_time, duration)
            if n then table.insert(ranges, {start=n.start_time, ["end"]=n.end_time, color="#69c5ff", opacity=0.85}) end
        end
    end
    -- 只有入点和出点都被明确标记后才上报选区；否则未标记的一端会被推断成
    -- 当前播放位置，导致拖动进度条时 uosc 上的选区另一端跟着跑。
    if state.start_time ~= nil and state.end_time ~= nil then
        local n = normalize_draft_segment()
        if n then table.insert(ranges, {start=n.start_time, ["end"]=n.end_time, color="#ff9800", opacity=0.85}) end
    end
    return ranges
end

update_ranges = function(immediate)
    ranges_pending = true
    local function send()
        ranges_timer = nil
        if not ranges_pending then return end
        ranges_pending = false
        local json = utils.format_json(build_ranges())
        if json ~= last_ranges_json then
            last_ranges_json = json
            mp.commandv("script-message-to", "uosc", "set-timeline-ranges", "quick_cut", json)
        end
    end
    if immediate then
        if ranges_timer then ranges_timer:kill(); ranges_timer = nil end
        send(); return
    end
    if not ranges_timer then ranges_timer = mp.add_timeout(1 / math.max(2, tonumber(opts.timeline_fps) or 10), send) end
end

local function sort_segments() Editor.sort_segments(state.segments) end
local function find_segment_index(id)
    return Editor.find_segment_index(state.segments, id)
end

local function overlap_count(candidate, exclude_id)
    local count = 0
    for _, seg in ipairs(state.segments) do
        if seg.id ~= exclude_id and candidate.start_time < seg.end_time - 0.001
            and candidate.end_time > seg.start_time + 0.001 then count = count + 1 end
    end
    return count
end

local function notify_overlap(candidate, exclude_id)
    local count = overlap_count(candidate, exclude_id)
    if count > 0 then show_hint(L("hint.overlap", count), 3) end
end

local function cancel_edit(silent)
    if not state.editing_id then return end
    state.editing_id, state.start_time, state.end_time = nil, nil, nil
    state.selected_segment_id = nil
    update_ranges(true); request_render(true)
    if not silent then show_hint(L("hint.edit_cancelled"),2,"info") end
end

-- 进入裁剪窗口。
-- 没有裁剪框时先按「自由」起一个 90% 的框 —— select_preset("free") 自己就会进入编辑态；
-- 已有裁剪框则直接进编辑态。错误情形（导出中、读不到视频尺寸）由 Crop 内部给提示。
local function open_crop_editor()
    if not Crop.crop_is_active(opts) then Crop.select_preset("free") else Crop.enter_editor() end
end

local function begin_edit_segment(id)
    if Export.job.running then show_hint(L("hint.cannot_edit_segment"), 2,"error"); return end
    local _, seg = find_segment_index(id)
    if not seg then return end
    state.editing_id = id
    focus_segment(id)
    state.start_time, state.end_time = seg.start_time, seg.end_time
    state.active_handle, state.modal = "start", false
    mp.commandv("seek", seg.start_time, "absolute", "exact")
    apply_segment_loop()
    update_ranges(true); request_render(true)
    show_hint(L("hint.editing_segment", primary_key(main_bindings, "add"), primary_key(main_bindings, "close")), 4)
end

-- 启用/停用：作用于勾选集合（若有）或当前聚焦段。只要其中有一个是停用状态就整体启用，
-- 否则整体停用（与"停用的片段不参与导出"配合，就是"只导出勾选的这几段"的实现方式）。
local function toggle_segment_scope()
    if not (prepare_main_action() or history_context_ok()) then return end
    if Export.job.running then show_hint(L("hint.cannot_modify_segment"), 2, "error"); return end
    local ids = {}
    if #state.checked > 0 then
        for i = 1, #state.checked do ids[i] = state.checked[i] end
    elseif state.selected_segment_id then
        ids[1] = state.selected_segment_id
    end
    if #ids == 0 then show_hint(L("hint.select_segment_first"), 2, "error"); return end
    local all_enabled = true
    for _, id in ipairs(ids) do
        local _, seg = find_segment_index(id)
        if seg and seg.enabled == false then all_enabled = false end
    end
    remember_action()
    for _, id in ipairs(ids) do
        local _, seg = find_segment_index(id)
        if seg then seg.enabled = not all_enabled end
    end
    update_ranges(true); request_render(true)
    show_hint(L(all_enabled and "hint.segments_disabled" or "hint.segments_enabled", #ids), 2)
end

-- 删除目标：勾选了片段则删勾选的全部（批量），否则删当前聚焦段。
-- 批量删除只压一条撤销记录（一次 Z 全部恢复）。
local function delete_selection()
    -- 片段列表打开时也要能用（页脚"删除"）：放行 modal 上下文，同 undo/redo
    if not (prepare_main_action() or history_context_ok()) then return end
    if Export.job.running then show_hint(L("hint.cannot_delete_segment"),2,"error"); return end
    if state.editing_id then show_hint(L("hint.finish_editing_first"),3,"error"); return end
    local ids = {}
    if #state.checked > 0 then
        for i = 1, #state.checked do ids[i] = state.checked[i] end
    elseif state.selected_segment_id then
        ids[1] = state.selected_segment_id
    end
    if #ids == 0 then show_hint(#state.segments==0 and L("hint.no_segment_to_delete") or L("hint.select_segment_first"),3,"error"); return end
    remember_action()
    for _, id in ipairs(ids) do
        local index = find_segment_index(id)
        if index then
            if state.editing_id == id then state.editing_id, state.start_time, state.end_time = nil, nil, nil end
            table.remove(state.segments, index)
        end
    end
    clear_selection()
    local maxv = math.max(1, tonumber(opts.max_visible_segments) or 7)
    state.segment_scroll = math.min(state.segment_scroll, math.max(0, #state.segments - maxv))
    update_ranges(true); request_render(true)
    show_hint(L(#ids > 1 and "hint.deleted_segments" or "hint.deleted_segment", #ids)..L("hint.undo_suffix", primary_key(main_bindings, "undo")),1,"success")
end
local function delete_selected_segment() delete_selection() end

-- 键盘循环选段：UP/DOWN 在片段间移动选中项并滚动列表、跳转播放头。
local function select_segment_by_offset(delta)
    if not prepare_main_action() then return end
    if Export.job.running then show_hint(L("hint.cannot_switch_segment"),2,"error"); return end
    if state.editing_id then show_hint(L("hint.finish_editing_first"),3,"error"); return end
    if #state.segments == 0 then show_hint(L("hint.no_segment_to_select"),2,"error"); return end
    local current = state.selected_segment_id and find_segment_index(state.selected_segment_id) or 0
    local target = current + delta
    if target < 1 then target = #state.segments elseif target > #state.segments then target = 1 end
    local seg = state.segments[target]
    -- 键盘导航只移动焦点，不清空勾选集合：否则 R 键永远只能选中一段
    -- （UP → 勾选 → UP 会把上一次的勾选清掉）。取消范围用 Ctrl+SPACE 或点时间轴空白。
    state.selected_segment_id = seg.id
    local maxv = math.max(1, tonumber(opts.max_visible_segments) or 7)
    if target <= state.segment_scroll then state.segment_scroll = target - 1
    elseif target > state.segment_scroll + maxv then state.segment_scroll = target - maxv end
    mp.commandv("seek", seg.start_time, "absolute", "exact")
    show_hint(L("hint.selected_segment_range", tostring(seg.label or seg.id),
        U.format_time(seg.start_time), U.format_time(seg.end_time)),opts.action_hint_duration)
    apply_segment_loop()
    request_render(true)
end

local function move_segment(id, delta)
    if Export.job.running then show_hint(L("hint.cannot_reorder"), 2,"error"); return end
    local index = find_segment_index(id); if not index then return end
    local target = index + delta
    if target < 1 or target > #state.segments then return end
    remember_action()
    state.segments[index], state.segments[target] = state.segments[target], state.segments[index]
    state.manual_order = true
    local maxv=math.max(1,tonumber(opts.max_visible_segments) or 7)
    local first,last=state.segment_scroll+1,state.segment_scroll+maxv
    if target<first then state.segment_scroll=math.max(0,target-1)
    elseif target>last then state.segment_scroll=math.max(0,target-maxv) end
    state.segment_scroll=math.min(state.segment_scroll,math.max(0,#state.segments-maxv))
    update_ranges(true); request_render(true)
end

get_queue = function()
    local duration, q = mp.get_property_number("duration", 0), {}
    for _, seg in ipairs(state.segments) do
        if seg.enabled ~= false then
            local n = normalize_segment(seg.start_time, seg.end_time, duration)
            if n then table.insert(q, n) end
        end
    end
    return q
end

-- ============================================================================
-- 播放范围（原「预览」与「连播」两个开关合并为同一个概念）
--   范围 = 勾选的片段集合（列表行首勾选格 / R 键）；没有勾选任何片段时，
--   范围退化为"当前聚焦的那个片段"（点片段块、UP/DOWN、点列表行都会聚焦）。
--   0 段 → 自由播放；1 段 → A-B 循环；≥2 段 → 越过出点依次连播。
-- 因此不再需要 segment_preview 选项与预览/连播按钮；点时间轴空白即清空范围。
-- ============================================================================
local function is_checked(id)
    if not id then return false end
    for _, v in ipairs(state.checked) do if v == id then return true end end
    return false
end
local function checked_count() return #state.checked end
local function clear_checked() state.checked = {} end
local function toggle_checked(id)
    if not id then return false end
    for i, v in ipairs(state.checked) do
        if v == id then table.remove(state.checked, i); return false end
    end
    state.checked[#state.checked + 1] = id
    return true
end
-- 范围片段：按片段序号（时间顺序）返回，供 A-B 循环与连播推进共用
local function range_segments()
    local out = {}
    if #state.checked > 0 then
        for _, seg in ipairs(state.segments) do
            if is_checked(seg.id) then out[#out + 1] = seg end
        end
        return out
    end
    if state.selected_segment_id then
        local _, seg = Editor.find_segment_index(state.segments, state.selected_segment_id)
        if seg then out[1] = seg end
    end
    return out
end
-- 单选：清空勾选集合、把焦点落到 id 上（点行体 / UP / DOWN / 点片段块共用）
focus_segment=function(id)
    clear_checked()
    state.selected_segment_id = id
end
-- 清空全部选择（点时间轴空白 / 取消选中键位）
clear_selection=function()
    clear_checked()
    state.selected_segment_id = nil
end

-- 快照 = 片段模型（state）+ 裁剪（存于 opts）。
-- 裁剪必须一起入栈：它是"本次剪辑的操作"，否则拖框 / 改比例 / 取消裁剪都退不回去，
-- 且"清空"会重置裁剪，撤销时若不恢复裁剪，用户辛苦框好的区域就被无声抹掉了。
local function model_snapshot()
    local x=Editor.snapshot(state)
    x.crop_mode,x.crop_aspect=opts.crop_mode,opts.crop_aspect
    x.crop_x,x.crop_y=opts.crop_x,opts.crop_y
    x.crop_width,x.crop_height=opts.crop_width,opts.crop_height
    x.crop_ratio_lock=state.crop_ratio_lock
    return x
end
local function restore_snapshot(snapshot)
    if not snapshot then return end
    history.suspended=true
    Editor.apply_snapshot(state,snapshot,opts.max_visible_segments)
    -- 只有确实带裁剪字段的快照才还原裁剪，避免把 state 里的裁剪抹成 nil
    if snapshot.crop_mode~=nil then
        opts.crop_mode,opts.crop_aspect=snapshot.crop_mode,snapshot.crop_aspect
        opts.crop_x,opts.crop_y=snapshot.crop_x,snapshot.crop_y
        opts.crop_width,opts.crop_height=snapshot.crop_width,snapshot.crop_height
        state.crop_ratio_lock=snapshot.crop_ratio_lock
    end
    history.suspended=false
    update_ranges(true); request_render(true)
end
-- 前向声明；片段动作在历史栈定义之前就需要调用它。
remember_action=function() if not history.suspended and not Export.job.running then Editor.history_push(history,model_snapshot()) end end
-- 片段列表（modal）与裁剪编辑器都放行撤销/重做：这两个上下文里 prepare_main_action
-- 会一律拒绝，而历史栈覆盖的正是"片段模型 + 裁剪"（同一份剪辑状态），与面板参数无关。
-- 导出确认面板仍拦截：那里按 Z 不该有副作用。
history_context_ok=function()
    return not state.confirm_action and (state.modal or state.crop_editing)
end
local function undo_action()
    if not (prepare_main_action() or history_context_ok()) then return end; if Export.job.running then show_hint(L("hint.cannot_undo"),2,"error"); return end
    local snapshot=Editor.history_undo(history,model_snapshot()); if not snapshot then show_hint(L("hint.nothing_to_undo"),2,"error"); return end
    restore_snapshot(snapshot); show_hint(L("hint.undone"),1,"success")
end
local function redo_action()
    if not (prepare_main_action() or history_context_ok()) then return end; if Export.job.running then show_hint(L("hint.cannot_redo"),2,"error"); return end
    local snapshot=Editor.history_redo(history,model_snapshot()); if not snapshot then show_hint(L("hint.nothing_to_redo"),2,"error"); return end
    restore_snapshot(snapshot); show_hint(L("hint.redone"),1,"success")
end

-- 会话持久化：以媒体路径为键保存/恢复剪辑进度（resume_session 控制开关）。
local studio_source = nil
local function session_snapshot()
    local segments = {}
    for _, seg in ipairs(state.segments) do
        segments[#segments+1] = {
            id=seg.id, label=seg.label, enabled=(seg.enabled ~= false),
            start_time=tonumber(seg.start_time), end_time=tonumber(seg.end_time),
        }
    end
    -- 片尾自动结束（end-file）时媒体已被卸载，duration 读到 0。此时不写该字段：
    -- 写 0 会被恢复侧拿去与真实时长比对（|真实 − 0| > 0.5），判为"媒体时长已变化"而拒绝恢复。
    local duration = mp.get_property_number("duration", 0)
    return {
        duration = (duration and duration > 0) and duration or nil,
        next_id = state.next_id,
        accurate_mode = state.accurate_mode == true,
        manual_order = state.manual_order == true,
        segment_scroll = state.segment_scroll,
        segments = segments,
        -- 裁剪随会话一起保存：它只存在 opts 里，而 opts 运行时改动不会写回 conf，
        -- 不存进 session 的话重启 mpv 就丢了
        crop = {
            mode = opts.crop_mode, aspect = opts.crop_aspect,
            x = opts.crop_x, y = opts.crop_y,
            w = opts.crop_width, h = opts.crop_height,
        },
    }
end
local function save_session()
    if not opts.resume_session then return end
    local source = studio_source or mp.get_property("path")
    if not U.valid_local_file(source) then return end
    local data = session_snapshot()
    if #data.segments == 0 then Session.clear(source); return end
    if Session.save(source, data) then
        msg.info("quick_cut session saved: " .. #data.segments .. " segment(s)")
    end
end
local function restore_session()
    if not opts.resume_session then return 0 end
    local source = mp.get_property("path")
    if not U.valid_local_file(source) then return 0 end
    local data = Session.load(source)
    if not data or type(data.segments) ~= "table" or #data.segments == 0 then return 0 end
    local duration = mp.get_property_number("duration", 0)
    -- data.duration 缺失或为 0（旧记录 / 片尾结束保存）时不做时长校验，否则永远拒绝恢复
    local saved_duration = tonumber(data.duration)
    if saved_duration and saved_duration > 0 and duration > 0 and math.abs(duration - saved_duration) > 0.5 then
        show_hint(L("hint.session_duration_changed"), 4, "error")
        return 0
    end
    state.segments, state.next_id = {}, tonumber(data.next_id) or 1
    for _, seg in ipairs(data.segments) do
        if type(seg.start_time) == "number" and type(seg.end_time) == "number" then
            -- 二者可能错位（label 序号与片段列表顺序对不上）。
            local sid = tonumber(seg.id) or state.next_id
            state.segments[#state.segments+1] = {
                id=sid,
                label=tostring(seg.label or L("hint.segment_label", sid)),
                enabled=(seg.enabled ~= false),
                start_time=math.max(0, seg.start_time), end_time=math.max(0, seg.end_time),
            }
            state.next_id = math.max(state.next_id, sid + 1)
        end
    end
    if #state.segments == 0 then return 0 end
    state.accurate_mode = data.accurate_mode == true
    state.manual_order = data.manual_order == true
    -- 恢复裁剪；没有记录时保持 conf 基线，不做改动
    local crop = data.crop
    if type(crop) == "table" then
        local mode = tostring(crop.mode or "none")
        if mode == "aspect" or mode == "custom" then
            opts.crop_mode = mode
            opts.crop_aspect = tostring(crop.aspect or "source")
            opts.crop_x = math.floor(tonumber(crop.x) or 0)
            opts.crop_y = math.floor(tonumber(crop.y) or 0)
            opts.crop_width = math.floor(tonumber(crop.w) or 0)
            opts.crop_height = math.floor(tonumber(crop.h) or 0)
        end
    end
    -- 恢复会话时保留上次的列表滚动位置（clamp 到有效范围），旧数据无该字段时回落到底部
    local maxv = tonumber(opts.max_visible_segments) or 7
    local last = math.max(0, #state.segments - maxv)
    state.segment_scroll = math.max(0, math.min(tonumber(data.segment_scroll) or last, last))
    Editor.history_clear(history)
    update_ranges(true)
    return #state.segments
end

local function current_output_directory()
    local path=Export.job.last_output_dir
    if path and path~="" then return path end
    local source=mp.get_property("path")
    if U.valid_local_file(source) then local dir,_=utils.split_path(source); return U.output_dir_for(dir) end
    return nil
end

local function open_last_output_directory()
    local path=current_output_directory()
    if not path then show_hint(L("hint.no_output_dir"),2,"error"); return end
    -- 先给一次可见反馈，再交给系统文件管理器：
    -- 反馈没出现 = 点击没命中按钮（命中区问题）；反馈出现但没窗口 = 打开失败（看下一行日志）
    show_hint(L("hint.opening_dir"),1)
    mp.log("quick_cut: open output directory: " .. tostring(path))
    U.open_directory(path)
end

-- 目录选单整功能已移除（打开输出目录仍保留，见上方 open_last_output_directory）：
-- 该入口低频且与"剪辑"无关，主面板不再为它留常驻按钮与浮层。

-- 分割：以"片头 / 片尾 / 各片段的入点、出点"为界，取播放头所在区间后按需切分。
--   播放头落在唯一的已有片段里 → 就地在它上面切；
--   落在重叠片段里 → 沿用"先点选目标"的提示；
--   落在间隙（片头前 / 段间 / 片尾后）→ 先把这个间隙建成片段（按时间落位），再切（两块都进列表）。
local function split_at_playhead()
    if not prepare_main_action() then return end
    if Export.job.running then show_hint(L("hint.cannot_split"),2,"error"); return end
    local time=mp.get_property_number("time-pos",0)
    local duration=mp.get_property_number("duration",0)
    local min=min_len()
    local index,segment,from_gap
    local candidates=Editor.find_segments_at_time(state.segments,time)
    if #candidates==1 then
        index,segment=candidates[1].index,candidates[1].segment
    elseif #candidates>1 then
        -- 重叠：优先用已选中且包含播放头的那个片段，否则要求先点选目标
        local sel=Editor.find_segment_index(state.segments,state.selected_segment_id)
        local s=sel and state.segments[sel]
        if s and time>=s.start_time and time<=s.end_time then index,segment=sel,s
        else show_hint(L("hint.multiple_overlap_at_playhead"),4,"error"); return end
    else
        -- 间隙：左边界 = 左侧最近边界，右边界 = 右侧最近边界（duration 缺失时读不到右侧）
        local L,R=Editor.interval_at(state.segments,time,duration)
        if not R then show_hint(L("hint.no_boundary_at_playhead"),4,"error"); return end
        from_gap=true
        segment={start_time=L,end_time=R}
    end
    local ok,err=Editor.can_split(segment,time,min)
    if not ok then show_hint(err,3,"error"); return end
    local prev_sel=state.selected_segment_id
    -- 快照必须早于任何改动：间隙分割若"先建段再快照"，撤销后会留下一个没切开的整段
    remember_action()
    if from_gap then
        -- 按时间顺序插入：手动排序（manual_order）下不会把两块甩到列表末尾
        local _,idx=Editor.insert_segment_at_time(state,segment.start_time,segment.end_time)
        index=idx
    end
    -- split_segment 的第二个返回值：成功时是左段，失败时是错误文案
    local right,second=Editor.split_segment(state,index,time)
    if not right then
        -- 间隙已建的片段要回滚，避免留下一个没切开的空壳
        if from_gap then table.remove(state.segments,index); state.next_id=state.next_id-1; state.selected_segment_id=prev_sel end
        show_hint(second or L("hint.split_failed"),3,"error"); return
    end
    if from_gap and opts.auto_sort_segments and not state.manual_order then sort_segments() end
    state.segment_scroll=math.max(0,math.min(index,#state.segments-(tonumber(opts.max_visible_segments) or 7)))
    MK.flash("split"); update_ranges(true); request_render(true)
    -- 提示报"切分后的两段"，中间那个时间就是切点。不要报切分前的区间端点：
    -- 段内分割会显示成"入点 → 出点"、间隙分割显示成"片头 → 片尾"，极易被读成按片头片尾切。
    local text=(from_gap and L("hint.split_from_gap") or L("hint.split_done")):format(
        U.format_time(second.start_time), U.format_time(second.end_time),
        U.format_time(right.start_time), U.format_time(right.end_time))
    show_hint(text,2,"success")
end

local resolution_index, fps_index, encode_param_text

-- 当前生效的参数集：由导出类型（视频/音频/动图/图片序列）决定。
-- 每套参数内部 id 唯一；跨集共享的字段（encode_container 等）语义一致，
-- 过滤、赋值、校验逻辑按当前激活集共用。
-- 必须定义在 encode_param_text 之前：否则那里会解析成全局变量而拿到 nil。
local function active_params()
    return C.params_for_kind(state.export_kind or C.DEFAULT_EXPORT_KIND)
end

-- 切换导出类型。参数集整个换掉，旧类型的下拉焦点/滚动位置已失效，一并清掉。
local function set_export_kind(kind)
    if not C.params_for_kind(kind) then return end
    if state.export_kind == kind then return end
    state.export_kind = kind
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    state.confirm_focus = "confirm_go"
    request_render(true)
end

-- 输出方式：每个片段单独文件 / 合并为一个文件
local function toggle_merge_output()
    if Export.job.running then show_hint(L("hint.cannot_modify_outmode"),2,"error"); return end
    -- 合并导出要把多段拼成一条流，mpv 编码模式没有 concat ⇒ 没有 ffmpeg 时整类不可用。
    -- 按钮已置灰且 fn 为 nil，这里再拦一道，防止脚本消息绕过按钮直接调进来。
    if not (state.merge_output == true) and C.ffmpeg_missing() then
        show_hint(L("hint.mpv_no_merge"),3,"error"); return
    end
    state.merge_output = not (state.merge_output == true)
    request_render(true)
end

-- 目标分辨率与源视频宽高比差异提示（源信息不可用时返回 nil）
local function resolution_ar_note()
    local dw = mp.get_property_number("video-params/dw", 0)
    local dh = mp.get_property_number("video-params/dh", 0)
    local w, h = tonumber(opts.video_width) or 0, tonumber(opts.video_height) or 0
    if dw <= 0 or dh <= 0 or w <= 0 or h <= 0 then return nil end
    local src_ar, dst_ar = dw / dh, w / h
    if math.abs(src_ar - dst_ar) < 0.001 then return nil end
    local mode = tostring(opts.scale_mode or "fit")
    if mode == "stretch" then return L("hint.scale_stretch") end
    if mode == "pad" then return L("hint.scale_pad") end
    return L("hint.scale_fit")
end

-- 裁剪生效时的输出画幅（未设置缩放时导出即该尺寸）；未启用裁剪或画幅不可用时返回 nil。
-- 供尺寸类参数回显"当前已编辑的尺寸"，而非笼统的"原尺寸"。
local function cropped_output_size()
    if not Crop.crop_is_active(opts) then return nil end
    local r = Crop.rect()
    if not r then return nil end
    return math.floor(r.w), math.floor(r.h)
end

-- 当前分辨率在候选项中的序号（不匹配时视为"原尺寸"）
resolution_index = function()
    local w, h = tonumber(opts.video_width) or 0, tonumber(opts.video_height) or 0
    for i, r in ipairs(C.RESOLUTIONS) do if r.w == w and r.h == h then return i end end
    return 1
end
-- 当前帧率在候选项中的序号
fps_index = function()
    local f = math.floor(tonumber(opts.output_fps) or 0)
    for i, v in ipairs(C.FPS_OPTIONS) do if v == f then return i end end
    return 1
end

encode_param_text = function(id)
    for _, spec in ipairs(active_params()) do
        if spec.id == id then
            if spec.type == "list" then
                -- labels 存 i18n 键，翻译后显示（如宽度 0 → "原尺寸"）
                local cur = tostring(opts[spec.field] or "")
                local lab = spec.labels and spec.labels[cur]
                -- 宽度类参数取 0（原尺寸）且裁剪生效时，回显裁剪后的实际宽度
                if cur == "0" and spec.field == "animated_width" then
                    local cw = cropped_output_size()
                    if cw then return tostring(cw) end
                end
                -- 编码类参数：显示"格式名 (编码器)"，与源文件行同一套话
                return lab and L(lab) or (C.codec_text and C.codec_text(cur)) or cur
            elseif spec.type == "quality" then
                if opts.video_quality_mode == "bitrate" then
                    return (opts.video_bitrate ~= "" and opts.video_bitrate) or L("value.no_bitrate")
                end
                return tostring(opts.video_quality)
            elseif spec.type == "resolution" then
                -- 预置档位回显档位名（label 是 i18n 键）；自定义分辨率不在档位表里，
                -- 直接回显实际宽高，否则会 fallback 成索引 1 而错误地显示成"原尺寸"
                local w, h = tonumber(opts.video_width) or 0, tonumber(opts.video_height) or 0
                if w <= 0 and h <= 0 then
                    -- 未设置缩放时导出尺寸就是裁剪后画幅：回显实际尺寸而非笼统的"原尺寸"
                    local cw, ch = cropped_output_size()
                    if cw then return string.format("%d×%d", cw, ch) end
                    return L("value.original_size")
                end
                for _, r in ipairs(C.RESOLUTIONS) do
                    if not (r.w == 0 and r.h == 0) and r.w == w and r.h == h then return L(r.label) end
                end
                if w > 0 and h > 0 then return string.format("%d×%d", w, h) end
                return string.format("%s×%s", w > 0 and tostring(w) or L("value.auto"), h > 0 and tostring(h) or L("value.auto"))
            elseif spec.type == "fps" then
                -- 预置整数档位直接回显；自定义帧率（如 23.976）保留小数，
                -- 不能取整去匹配档位，否则 23.976 会显示成"原帧率"
                local f = tonumber(opts.output_fps) or 0
                if f <= 0 then return L("value.original_fps") end
                for _, v in ipairs(C.FPS_OPTIONS) do if v > 0 and v == f then return L("value.fps", tostring(v)) end end
                local s = string.format("%.3f", f):gsub("0+$", ""):gsub("%.$", "")
                return L("value.fps", s)
            elseif spec.type == "bool" then
                return (opts[spec.field] == true) and L("value.on") or L("value.off")
            end
        end
    end
    return ""
end

-- 前向声明：这几个函数实际定义在 param_options 之前（本文件更靠后处），
-- 而 cycle_encode_param 在其之前就需要引用它们。
local filter_values, spec_values, coerce_dependents

-- 导出确认面板：左右循环切换任意编码参数（delta = -1 上一项 / +1 下一项）。
-- 快速复制（流复制）下自定义编码参数不会生效，参数一旦变更自动切换到重新编码。
-- 拨动这些参数不该把导出从快速（流复制）顶到重新编码——它们要么在快速复制下本来就成立，
-- 要么由 effective_accurate_mode 在导出时按实际情况判定（抢先切重新编码还有"关掉也回不去"的副作用）：
--   normalize_audio        只重编音频，快速复制下视频仍流复制
--   auto_deinterlace / auto_crop_black / remove_silence
--                          确实需要重编码，但导出时会判定；在这里切重新编码会让"关掉它们"也回不到快速复制
--   faststart              只是内联 moov（-movflags +faststart），流复制也能加（export.lua 已同步支持）
--   scale_mode             只在"目标尺寸 ≠ 源尺寸"时才产生 scale 滤镜，原尺寸下是空设置
--   audio_codec = copy     快速复制的 -c copy 正是"保持源音频"这个语义
--   audio_bitrate          只在音频会被重编码时才有意义（audio_codec = copy 时是空设置）
--   pixel_format = auto    语义是"保持源格式"，而流复制正是这个语义
-- 注意：video_codec / preset / quality* / 明确的 pixel_format 等确实要重编码，保持"改了就切重新编码"。
local function accurate_neutral_field(field)
    if field == nil then return false end
    if field == "smart_cut" or field == "normalize_audio" or field == "auto_deinterlace"
        or field == "auto_crop_black" or field == "remove_silence" or field == "faststart" then
        return true
    end
    if field == "scale_mode" then
        return (tonumber(opts.video_width) or 0) == 0 and (tonumber(opts.video_height) or 0) == 0
    end
    -- 音频：只有"音频确实会被重编码"时才需要重新编码；选 copy 时快速复制给的就是这个
    if field == "audio_bitrate" or field == "audio_codec" then
        return tostring(opts.audio_codec or "") == "copy"
    end
    if field == "pixel_format" then return tostring(opts.pixel_format or "") == "auto" end
    -- container：快速复制下只要"源编码装得进目标容器"就是一次纯 remux（秒级），装不进则由
    -- fast_remux_ext 在导出时退回重新编码并说明原因——所以在这里不该抢先切重新编码。
    if field == "encode_container" then return true end
    return false
end

local function cycle_encode_param(id, delta)
    if Export.job.running then show_hint(L("hint.cannot_modify_encode"),2,"error"); return end
    for _, spec in ipairs(active_params()) do
        if spec.id == id then
            local before_text = encode_param_text(id)
            if spec.type == "list" then
                -- 只在不被当前格式允许的取值之外循环
                local values = filter_values(spec, spec_values(spec))
                local idx = 1
                for i, v in ipairs(values) do if tostring(opts[spec.field]) == tostring(v) then idx = i end end
                idx = ((idx - 1 + delta) % #values) + 1
                opts[spec.field] = values[idx]
                -- 换编码器后同步为该族合法的 preset：优先 medium，否则取中位
                if spec.field == "video_codec" then
                    local options = C.preset_options(values[idx])
                    local pick = 1
                    for i, v in ipairs(options) do if v == "medium" then pick = i break end end
                    if options[pick] ~= "medium" then pick = math.floor(#options / 2) + 1 end
                    opts.preset = options[pick]
                end
            elseif spec.type == "quality" then
                if opts.video_quality_mode == "bitrate" then
                    local values, idx = C.BITRATE_OPTIONS, 1
                    for i, v in ipairs(values) do if tostring(opts.video_bitrate) == v then idx = i end end
                    idx = ((idx - 1 + delta) % #values) + 1
                    opts.video_bitrate = values[idx]
                else
                    local hi = (opts.video_quality_mode == "crf") and 51 or 63
                    opts.video_quality = math.max(0, math.min(hi, (tonumber(opts.video_quality) or 18) + delta))
                end
            elseif spec.type == "resolution" then
                local idx = ((resolution_index() - 1 + delta) % #C.RESOLUTIONS) + 1
                opts.video_width, opts.video_height = C.RESOLUTIONS[idx].w, C.RESOLUTIONS[idx].h
            elseif spec.type == "fps" then
                local idx = ((fps_index() - 1 + delta) % #C.FPS_OPTIONS) + 1
                opts.output_fps = C.FPS_OPTIONS[idx]
            elseif spec.type == "bool" then
                opts[spec.field] = not (opts[spec.field] == true)
            end
            -- 格式联动：与下拉点选、自定义输入保持同一套规则
            local coerced = spec.field and coerce_dependents(spec.field) or nil
            local after_text = encode_param_text(id)
            local switched = false
            -- 非视频类型（音频/动图/图片/字幕）走各自独立链路，accurate_mode 对它们没有意义：
            -- 在那里拨参数不该把"视频导出"的模式悄悄改成精确（切回视频导出时会一直用着）。
            if after_text ~= before_text and active_params() == C.ENCODE_PARAMS
                and not accurate_neutral_field(spec.field) then
                local op = state.confirm_action == "merge" and "merge" or "export"
                if not effective_accurate_mode(opts, state.accurate_mode, op) then
                    state.accurate_mode = true
                    switched = true
                end
            end
            local hint = L("hint.param_changed", L(spec.label), after_text)
            if switched then hint = hint .. L("hint.mode_switched") end
            if coerced then hint = hint .. L("hint.format_limit", coerced) end
            show_hint(hint, opts.action_hint_long_duration)
            request_render(true)
            return
        end
    end
end

-- 循环切换导出编码预设（自定义 / 网页 / 高质量 / 归档），实时应用到 opts。
local function cycle_export_preset()
    if Export.job.running then show_hint(L("hint.cannot_change_preset"),2,"error"); return end
    local order = C.PRESET_ORDER
    local idx = 1
    for i, name in ipairs(order) do if name == C.current_preset then idx = i end end
    local next_name = order[idx % #order + 1]
    local label = C.apply_export_preset(opts, next_name)
    -- 跟随源文件的预设＝流复制，模式跟着回快速复制（否则参数集与白洗都会停在精确那套）
    if (C.EXPORT_PRESETS[next_name] or {}).from_source then state.accurate_mode = false end
    opts.video_quality = C.clamped_number(opts.video_quality, opts.video_quality, 0, 63)
    -- 预设替换了编码参数：快速复制下同样自动切换重新编码
    local switched = false
    -- 同 set_export_preset：跟随源文件的预设不需要重编码，别被强制切到重新编码
    if next_name ~= "default" and not (C.EXPORT_PRESETS[next_name] or {}).from_source
            and tostring((C.EXPORT_PRESETS[next_name] or {}).video_codec or "") ~= "copy" then
        local op = state.confirm_action == "merge" and "merge" or "export"
        if not effective_accurate_mode(opts, state.accurate_mode, op) then
            state.accurate_mode = true
            switched = true
        end
    end
    local suffix = switched and L("hint.mode_switched") or (next_name == "default" and L("hint.restored_baseline") or "")
    show_hint(L("hint.preset_changed", label) .. suffix, opts.action_hint_long_duration)
    request_render(true)
end

-- 当前容器/编码器对某参数的取值约束；返回允许集合，nil 表示不限制。
-- 这是"格式联动"的唯一真相来源，过滤选项与自动纠正都走这里。
local function allowed_values(spec)
    if spec.id == "video_codec" then
        return C.container_video_codecs(opts.encode_container)
    elseif spec.id == "audio_codec" then
        return C.container_audio_codecs(opts.encode_container)
    elseif spec.id == "quality_mode" then
        return C.codec_quality_modes(opts.video_codec)
    end
    return nil
end

-- 取参数的候选值：preset 是随编码器动态生成的，其余用静态 values
spec_values = function(spec)
    return (spec.dyn == "preset") and C.preset_options(opts.video_codec) or spec.values
end

-- 按格式约束过滤下拉选项。过滤结果为空则原样返回，避免误伤导致选项整个消失。
-- value_requires（config 声明的 ffmpeg 能力依赖）在此一并过滤：
-- 探测完成前按"不可用"处理，探测回调触发重渲染后再显示。
filter_values = function(spec, values)
    local allow = allowed_values(spec)
    local reqs = spec.value_requires
    if not allow and not reqs then return values end
    local out = {}
    for _, v in ipairs(values or {}) do
        local sv = tostring(v)
        local ok = (not allow or allow[sv])
        if ok and reqs and reqs[sv] then ok = Export.value_available(reqs[sv]) end
        if ok then out[#out + 1] = v end
    end
    return (#out > 0) and out or values
end

-- 某个配置项变更后，下游参数若不再合法则自动纠正为第一个合法值。
-- 例：容器切到 webm 后音频编码 aac 不合法 → 自动改为 libopus。
-- 返回纠正说明（供提示用），无纠正则返回 nil。
coerce_dependents = function(changed_field)
    local deps = C.PARAM_DEPENDENTS[changed_field]
    if not deps then return nil end
    local notes = {}
    for _, dep_id in ipairs(deps) do
        for _, spec in ipairs(active_params()) do
            if spec.id == dep_id and spec.field then
                local allow = allowed_values(spec)
                local values = spec_values(spec)
                if allow then
                    if not allow[tostring(opts[spec.field] or "")] then
                        local first = nil
                        for _, v in ipairs(values or {}) do
                            if allow[tostring(v)] then first = v break end
                        end
                        if first then
                            local old = tostring(opts[spec.field] or "")
                            opts[spec.field] = tostring(first)
                            notes[#notes + 1] = string.format("%s %s→%s", L(spec.label), old, first)
                        end
                    end
                elseif values and spec.id == "preset" then
                    -- preset 无静态约束表，但候选值随编码器变化，当前值可能已越界
                    local cur = tostring(opts[spec.field] or "")
                    local ok = false
                    for _, v in ipairs(values) do if tostring(v) == cur then ok = true break end end
                    if not ok and values[1] then
                        local old = cur
                        opts[spec.field] = tostring(values[1])
                        notes[#notes + 1] = string.format("%s %s→%s", L(spec.label), old, tostring(values[1]))
                    end
                end
            end
        end
    end
    if #notes > 0 then return table.concat(notes, L("hint.list_sep")) end
    return nil
end

-- 对依赖链起点做一次全量纠正。用于预设切换这类一次性大批量改动的场景：
-- 预设（尤其用户自定义的）可能直接配成 webm + aac 这类不兼容组合。
local function coerce_all()
    local notes = {}
    -- 预设可能带 normalize_audio / remove_silence：选了「无音频」时这两个开关必须先关掉，
    -- 否则 loudnorm / silencedetect 会去处理一条根本不存在的音轨
    if tostring(opts.audio_codec or ""):lower() == "none" then
        opts.normalize_audio = false
        opts.remove_silence = false
    end
    for _, field in ipairs({"encode_container", "video_codec"}) do
        local n = coerce_dependents(field)
        if n then notes[#notes + 1] = n end
    end
    if #notes > 0 then return table.concat(notes, L("hint.list_sep")) end
    return nil
end

-- 参数/预设下拉选项列表；id=="_preset" 为导出编码预设，其余为 ENCODE_PARAMS 中某项。
-- 每项 {value=..., label=..., current=是否当前值}，供 ui 浮层渲染与滚轮滚动计数。
local function param_options(id)
    if id == "_preset" then
        local rows = {}
        local function header(text) rows[#rows + 1] = {header = true, label = text} end
        -- 优化目标组放在最前；第一项「无」= 不做优化（不改内置参数）。
        -- 预设与优化目标互斥，所以外面只有**一个**选单，列表内分组区分。
        -- 优化目标组：设了目标时预设行**不再打勾**（两者互斥，界面上只能有一项 current）。
        -- 「无」已去掉：要取消目标，直接选一个预设即可（选预设本来就会复位目标）。
        header(L("preset.section_goal"))
        for _, g in ipairs(C.OPTIMIZE_GOAL_ORDER) do
            local goal_key = "goal." .. g  -- 变量拼接，避免 i18n 检查器收集假键
            rows[#rows + 1] = {value="_goal:"..g, label=L(goal_key), current=(state.optimize_goal == g)}
        end
        header(L("preset.section_builtin"))
        for _, name in ipairs(C.PRESET_ORDER) do
            local p = C.EXPORT_PRESETS[name]
            if not (p and (p.custom or p.from_conf)) then
                rows[#rows + 1] = {value=name, label=L((p and p.label) or name),
                    current=(state.optimize_goal == nil and C.current_preset == name)}
            end
        end
        header(L("preset.section_mine"))
        local cur_kind = state.export_kind or "video"
        for _, name in ipairs(C.PRESET_ORDER) do
            local p = C.EXPORT_PRESETS[name]
            if p and (p.custom or p.from_conf) then
                -- conf 的 export_preset_list 也算"我的"（只读：改名/删除会提示内置不可改）；
                -- 别的导出类型的预设也列出来（否则在视频页存下的预设切到字幕页就再也找不到），
                -- 用「名字 · 类型」标出它属于哪一页
                local lab = p.label or name
                -- 变量拼接，避免 i18n 检查器把 "confirm.kind_" 前缀收集成假键
                if p.kind and p.kind ~= cur_kind then
                    local kkey = "confirm.kind_" .. tostring(p.kind)
                    lab = lab .. " · " .. L(kkey)
                end
                rows[#rows + 1] = {value=name, label=lab, current=(state.optimize_goal == nil and C.current_preset == name)}
            end
        end
        -- 管理动作（不是"选中某项"，而是对当前预设做事）：保存 / 重命名 / 删除 / 默认启动。
        header(L("preset.section_manage"))
        local curp = C.EXPORT_PRESETS[C.current_preset]
        rows[#rows + 1] = {value="_act:save", label=L("confirm.preset_save"), action=true}
        if curp and curp.custom then
            rows[#rows + 1] = {value="_act:rename", label=L("confirm.preset_rename", C.preset_label()), action=true}
            rows[#rows + 1] = {value="_act:delete", label=L("confirm.preset_delete", C.preset_label()), action=true, danger=true}
        end
        rows[#rows + 1] = {value="_act:default", label=L("confirm.preset_default", C.preset_label()), action=true}
        return rows
    end
    for _, spec in ipairs(active_params()) do
        if spec.id == id then
            local out = {}
            if spec.type == "list" then
                local values = filter_values(spec, spec_values(spec))
                local cur = tostring(opts[spec.field] or "")
                local labels = spec.labels
                for _, v in ipairs(values or {}) do
                    local sv = tostring(v)
                    -- labels 存的是 i18n 键，需经 L() 翻译
                    local lab = labels and labels[sv]
                    -- 宽度参数取 0（原尺寸）且裁剪生效时，标注裁剪后的实际宽度
                    if sv == "0" and spec.field == "animated_width" then
                        local cw = cropped_output_size()
                        if cw then lab = string.format("%s · %d", L("value.original_size"), cw) end
                    end
                    out[#out + 1] = {value=sv, label=lab and L(lab) or (C.codec_text and C.codec_text(sv)) or sv, current=(cur == sv)}
                end
            elseif spec.type == "quality" then
                if opts.video_quality_mode == "bitrate" then
                    local cur = tostring(opts.video_bitrate or "")
                    for _, v in ipairs(C.BITRATE_OPTIONS) do out[#out + 1] = {value=tostring(v), label=tostring(v), current=(cur == tostring(v))} end
                else
                    -- 只列常用档位（0..63 全列出来有 64 项，翻起来没意义）；当前值不在表里就插到最前，
                    -- "自定义…" 项由函数末尾统一追加，所以仍可手动填任意值。
                    local cur = tonumber(opts.video_quality) or 18
                    local qs = {14, 18, 20, 23, 28}
                    local seen = false
                    for _, q in ipairs(qs) do
                        if q == cur then seen = true end
                        out[#out + 1] = {value=tostring(q), label=tostring(q), current=(cur == q)}
                    end
                    if not seen then table.insert(out, 1, {value=tostring(cur), label=tostring(cur), current=true}) end
                end
            elseif spec.type == "resolution" then
                local wi, he = tonumber(opts.video_width) or 0, tonumber(opts.video_height) or 0
                local cw, ch = cropped_output_size()
                for _, r in ipairs(C.RESOLUTIONS) do
                    -- "原尺寸"选项附带裁剪后实际画幅，明确该档位下的真实输出尺寸
                    local lab = L(r.label)
                    if r.w == 0 and r.h == 0 and cw then lab = string.format("%s · %d×%d", lab, cw, ch) end
                    out[#out + 1] = {value=r.label, label=lab, current=(tonumber(r.w) == wi and tonumber(r.h) == he)}
                end
            elseif spec.type == "fps" then
                local cur = tonumber(opts.output_fps) or 0
                for _, f in ipairs(C.FPS_OPTIONS) do out[#out + 1] = {value=tostring(f), label=(f == 0 and L("value.original_fps") or tostring(f)), current=(cur == f)} end
            elseif spec.type == "bool" then
                local cur = opts[spec.field] == true
                out[#out + 1] = {value="true", label=L("value.enable"), current=cur}
                out[#out + 1] = {value="false", label=L("value.disable"), current=not cur}
            end
            -- 支持自定义输入的参数：末尾追加"自定义…"（mp.input 不可用时隐藏该入口）
            if spec.custom and mp_input then
                out[#out + 1] = {value=C.CUSTOM_PARAM_VALUE, label=L("common.custom"), current=false}
            end
            -- 当前值不在选项集（可能经编码预设或自定义输入设置）时，把当前值补到最前，
            -- 保证打开下拉就能看到当前值并可一键回落。
            local cur_txt
            if spec.type == "list" then
                cur_txt = tostring(opts[spec.field] or "")
            elseif spec.type == "quality" then
                cur_txt = opts.video_quality_mode == "bitrate" and tostring(opts.video_bitrate or "")
                    or tostring(tonumber(opts.video_quality) or "")
            elseif spec.type == "resolution" then
                cur_txt = string.format("%dx%d", tonumber(opts.video_width) or 0, tonumber(opts.video_height) or 0)
            elseif spec.type == "fps" then
                cur_txt = tostring(tonumber(opts.output_fps) or 0)
            end
            if cur_txt and cur_txt ~= "" then
                -- 当前值声明了能力依赖但 ffmpeg 不支持时，不补当前值选项（与过滤行为一致）
                local creq = spec.value_requires and spec.value_requires[cur_txt]
                if creq and not Export.value_available(creq) then cur_txt = nil end
            end
            if cur_txt and cur_txt ~= "" then
                local has_cur = false
                for _, o in ipairs(out) do if o.current then has_cur = true; break end end
                if not has_cur then table.insert(out, 1, {value=cur_txt, label=cur_txt, current=true}) end
            end
            return out
        end
    end
    return {}
end

-- 打开自定义输入框。前向声明：它依赖后面才定义的键区安装函数与 show_hint。
local prompt_custom_param

-- 应用参数值：赋值 → 必要时自动切重新编码 → 提示。
-- 下拉点选与自定义输入提交共用这一条路径，保证两种入口行为完全一致。
-- quiet=true 时不弹"已修改"提示（回退/恢复默认由调用方给一条汇总提示）
local function apply_param_value(spec, value, quiet)
    -- 「无音频」与"必须动音频的开关"互斥：开启时直接拒绝，否则导出会缺音轨而失败/被静默忽略
    if spec.type == "bool" and value == "true"
        and (spec.field == "normalize_audio" or spec.field == "remove_silence")
        and tostring(opts.audio_codec or ""):lower() == "none" then
        show_hint(L("hint.audio_off_conflict"), opts.action_hint_long_duration)
        return
    end
    local before_text = encode_param_text(spec.id)
    if spec.type == "list" then
        opts[spec.field] = tostring(value)
    elseif spec.type == "quality" then
        -- bitrate 模式下取值一律是码率字符串（"5M" 等）；其余模式是 0-63 的数值。
        -- 不能靠 tonumber 判断：纯数字码率（如 "128000"）会被 tonumber 解析成功而误存进 quality。
        if opts.video_quality_mode == "bitrate" then
            opts.video_bitrate = tostring(value)
        else
            opts.video_quality = tonumber(value) or opts.video_quality
        end
    elseif spec.type == "resolution" then
        -- 先按预置档位匹配；匹配不到再按"宽x高"自定义格式解析
        local matched = false
        for _, r in ipairs(C.RESOLUTIONS) do
            if r.label == value then opts.video_width, opts.video_height = r.w, r.h; matched = true; break end
        end
        if not matched then
            local w, h = tostring(value):match("^(%d+)%s*[xX×*]%s*(%d+)$")
            if w and h then opts.video_width, opts.video_height = tonumber(w), tonumber(h) end
        end
    elseif spec.type == "fps" then
        opts.output_fps = tonumber(value) or 0
    elseif spec.type == "bool" then
        opts[spec.field] = (value == "true")
    end
    -- 选了「无音频」就把需要音轨的开关一并关掉（手动逐项改与预设切换两条路径都经这里）
    if spec.field == "audio_codec" and tostring(opts.audio_codec or ""):lower() == "none" then
        opts.normalize_audio = false
        opts.remove_silence = false
    end
    -- 格式联动：容器/编码器变更后，下游参数若不再合法则一并纠正
    local coerced = spec.field and coerce_dependents(spec.field) or nil
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    state.confirm_focus = "confirm_go"
    local after_text = encode_param_text(spec.id)
    local switched = false
    -- 非视频类型见 cycle_encode_param 处的说明：它们的参数集与视频模式无关
    if after_text ~= before_text and active_params() == C.ENCODE_PARAMS
        and not accurate_neutral_field(spec.field) then
        local op = state.confirm_action == "merge" and "merge" or "export"
        if not effective_accurate_mode(opts, state.accurate_mode, op) then
            state.accurate_mode = true; switched = true
        end
    end
    local hint = L("hint.param_changed", L(spec.label), after_text)
    if spec.id == "resolution" and after_text ~= L("value.original_size") then
        local note = resolution_ar_note()
        if note then hint = hint .. note end
    end
    if switched then hint = hint .. L("hint.mode_switched") end
    if coerced then hint = hint .. L("hint.format_limit", coerced) end
    if not quiet then show_hint(hint, opts.action_hint_long_duration) end
    request_render(true)
end

-- 下拉菜单点选：直接设置参数值，并执行与循环切换一致的"自动切重新编码"规则。
local function set_encode_param(id, value)
    if Export.job.running then show_hint(L("hint.cannot_modify_encode"),2,"error"); return end
    for _, spec in ipairs(active_params()) do
        if spec.id == id then
            -- 选中"自定义…"：不在此处赋值，交给输入框，提交后再走同一套应用逻辑
            if value == C.CUSTOM_PARAM_VALUE then
                if prompt_custom_param then prompt_custom_param(spec) end
                return
            end
            apply_param_value(spec, value)
            return
        end
    end
end

-- 展开/收起参数（或编码预设）下拉菜单；id=="_preset" 表示编码预设列表。
local function toggle_param_dropdown(id)
    if state.param_dropdown and state.param_dropdown.id == id then
        state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
        state.confirm_focus = "confirm_go"
    else
        state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = {id=id}, 0, nil
        -- 键盘焦点默认落在当前值选项；超出可视行数时落在末行
        local dmax = math.max(1, tonumber(C.DROPDOWN_MAX_ROWS) or 10)
        local cur = 1
        for i, o in ipairs(param_options(id)) do if o.current then cur = i break end end
        state.confirm_focus = "dp_" .. id .. "_" .. math.min(cur, dmax)
    end
    request_render(true)
end

-- 下拉菜单点选：直接应用导出预设。
-- 源画质画像（供优化目标自适应）：bpp = 视频码率/(fps×宽×高)。
-- video-bitrate 为 bits/s；任一数据不可得（未起播/无视频）返回 nil，目标按固定值应用。
local function source_profile()
    local vp = mp.get_property_native("video-params") or {}
    local w = math.floor(tonumber(vp.w or vp.dw) or 0)
    local h = math.floor(tonumber(vp.h or vp.dh) or 0)
    -- 括号不能省：mp.get_property 在属性不可用时会返回第二个值（错误串），
    -- 直接当实参传进 tonumber 会被当成"进制参数"→ bad argument #2 to tonumber。
    local fps = tonumber((mp.get_property("container-fps"))) or tonumber((mp.get_property("fps"))) or 0
    local vbit = tonumber((mp.get_property_number("video-bitrate", 0))) or 0
    if w <= 0 or h <= 0 or fps <= 0 or vbit <= 0 then return nil end
    return {w=w, h=h, fps=fps, bpp=vbit / (fps * w * h)}
end

-- 当前参数是否已偏离「原始参数」基线：与确认面板里参数格的"已修改"标记**同一个判定**，
-- 避免出现"格子里标了已改、选单却还写着原始参数"的不一致。
local function params_modified()
    local base = C.encode_baseline()
    for _, spec in ipairs(active_params()) do
        if C.param_is_modified(spec, opts, base) then return true end
    end
    return false
end

-- "· 已修改"后缀：只在真的偏离基线时出现（设了优化目标时不加，见下面两个函数）
local function modified_suffix()
    if params_modified() then return " · " .. L("confirm.modified") end
    return ""
end

-- 确认面板那个选单显示的文本：预设与优化目标互斥，只显示**当前生效的那一项**。
local function choice_label()
    if state.optimize_goal then
        local key = "goal." .. state.optimize_goal
        return L("confirm.goal", L(key))
    end
    -- 偏离「原始参数」时标出"已修改"：不丢"当前是哪个预设"，也不谎称参数还是原始值
    return L("confirm.preset", C.preset_label()) .. modified_suffix()
end

-- 选单悬停提示：偏离「原始参数」时说明怎么回去（面板上就有「还原」）
local function choice_tip()
    if not state.optimize_goal and params_modified() then
        return L("confirm.choice_tip_modified", C.preset_label())
    end
    return L("confirm.choice_tip")
end

-- 生效设置的**裸名**（不带「预设参数：/优化目标：」前缀）：摘要行本身已有「编码：」，
-- 用带前缀的会变成「编码：优化目标：画质优先」这种重复。
local function choice_name()
    if state.optimize_goal then
        local key = "goal." .. state.optimize_goal
        return L(key)
    end
    -- 摘要行首项：同样带上"已修改"，与选单显示一致
    return C.preset_label() .. modified_suffix()
end

-- 当前优化目标的显示名（供提示文案用；未设 = 「无」）。
local function goal_label()
    local g = state.optimize_goal
    if not g then return L("goal.none") end
    local key = "goal." .. g   -- 先拼进变量再查表：避免 i18n 检查器收集假键
    return L(key)
end

-- 取消优化目标：恢复当前编码预设的参数基线（current_preset=="default" 时即 conf 直配值）。
local function clear_optimize_goal()
    state.optimize_goal = nil
    state.size_target = nil
    -- 设目标时可能把"快速复制"顺带切成了重新编码：取消目标要还原回去
    if state.goal_prev_accurate ~= nil then
        state.accurate_mode = state.goal_prev_accurate == true
        state.goal_prev_accurate = nil
    end
    C.apply_export_preset(opts, C.current_preset)
    coerce_all()
    show_hint(L("hint.goal_cleared"), 3, "info")
    request_render(true)
end

-- 清空导出面板上的设置：各参数回到「当前预设的基线」，优化目标一并取消。
-- 取消导出、导出完成后都会走它，否则上次调过的参数会留在面板里，下次导出像"还没清干净"。
-- 编码器接受的最低视频码率（保守下限，用于导出前拦掉明显不可能的目标体积）。
-- 依据（libx264 实测）：过低码率只在**第 2 遍**被拒，
-- 报 "requested bitrate is too low. estimated minimum is N kbps"，且 N 与前一遍统计有关、无法精确预测；
-- 实测简单画面 4K60≈80、1080p60≈29、720p30≈12 kbps。这里取"像素率 / 4M"（对 4K60 约 124 kbps，
-- 约为实测值的 1.6 倍），宁可提前劝退，也不让作业跑到一半再失败。
local function min_video_kbps()
    local vp = mp.get_property_native("video-params") or {}
    local w = tonumber(vp.dw or vp.w) or 0
    local h = tonumber(vp.dh or vp.h) or 0
    local fps = tonumber((mp.get_property("container-fps"))) or 25
    if w <= 0 or h <= 0 then return 16 end
    if fps <= 0 then fps = 25 end
    return math.max(16, math.ceil(w * h * fps / 4000000))
end

local function reset_confirm_params()
    clear_optimize_goal()
    local base = C.encode_baseline()
    for _, spec in ipairs(active_params()) do
        local v = C.param_baseline_value(spec, opts, base)
        if v ~= nil then apply_param_value(spec, tostring(v), true) end
    end
    coerce_all()
end


local function set_export_preset(name)
    if Export.job.running then show_hint(L("hint.cannot_change_preset"),2,"error"); return end
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    state.confirm_focus = "confirm_go"
    -- 预设管理（下拉"我的"区的动作行）：保存 / 重命名 / 删除 / 设为启动默认。
    -- 用 `_act:` 前缀而不是新接口，是因为下拉的行点击统一走 ctx.set_export_preset
    -- （与 "_goal:" 同一套路），ui 那边一行都不用改。
    local act = tostring(name or ""):match("^_act:(%w+)$")
    if act then
        local function prompt_or_warn()
            if mp_input and mp_input.get then return true end
            show_hint(L("hint.no_custom_input"), 3, "error"); return false
        end
        local function reopen_bindings()
            osd_restore()
            if state.in_studio then
                if state.confirm_action then install_confirm_bindings() else install_main_bindings() end
                mouse_bound = false
                mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
            end
            request_render(true)
        end
        local function name_error(err, text)
            local e = tostring(err or "")
            if e == "empty" then show_hint(L("hint.preset_name_empty"), 3, "error")
            elseif e == "long" then show_hint(L("hint.preset_name_long"), 3, "error")
            elseif e == "taken" then show_hint(L("hint.preset_name_taken", tostring(text)), 3, "error")
            else show_hint(L("hint.preset_store_broken"), 4, "error") end
        end
        local curp = C.EXPORT_PRESETS[C.current_preset]
        local editable = (curp and curp.custom) and C.current_preset or nil
        if act == "save" then
            if not prompt_or_warn() then return end
            local kind = state.export_kind or "video"
            local values = C.export_presets_values(opts, kind)
            clear_all_context_bindings(); osd_below_input()
            local ok_get, get_err = pcall(mp_input.get, {
                prompt = L("confirm.preset_save_prompt") .. " > ",
                default = "",
                submit = function(text)
                    local saved, err = C.export_presets_save(text, kind, values)
                    if not saved then name_error(err, text); return end
                    state.optimize_goal = nil
                    set_export_preset(saved)   -- 立刻切到刚存的预设，省掉"再点一次"
                    show_hint(L("hint.preset_saved", saved), opts.action_hint_long_duration, "success")
                end,
                closed = reopen_bindings,
            })
            if not ok_get then
                msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
                reopen_bindings()
            end
            return
        end
        if act == "rename" or act == "delete" then
            if not editable then show_hint(L("hint.preset_locked"), 3, "error"); return end
        end
        if act == "rename" then
            if not prompt_or_warn() then return end
            local old = editable
            clear_all_context_bindings(); osd_below_input()
            local ok_get, get_err = pcall(mp_input.get, {
                prompt = L("confirm.preset_rename_prompt") .. " > ",
                default = old,
                submit = function(text)
                    local new, err = C.export_presets_rename(old, text)
                    if not new then name_error(err, text); return end
                    C.current_preset = new
                    show_hint(L("hint.preset_renamed", old, new), opts.action_hint_long_duration, "success")
                    request_render(true)
                end,
                closed = reopen_bindings,
            })
            if not ok_get then
                msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
                reopen_bindings()
            end
            return
        end
        if act == "delete" then
            local gone = editable
            if not C.export_presets_delete(gone) then show_hint(L("hint.preset_store_broken"), 4, "error"); return end
            C.apply_export_preset(opts, "original")   -- 删的是当前预设：退回"原始参数"
            state.optimize_goal, state.accurate_mode = nil, false
            show_hint(L("hint.preset_deleted", gone), opts.action_hint_long_duration, "success")
            request_render(true)
            return
        end
        if act == "default" then
            local target = C.current_preset
            if not C.export_presets_set_default(target) then show_hint(L("hint.preset_store_broken"), 4, "error"); return end
            show_hint(L("hint.preset_default_set", C.preset_label()), opts.action_hint_long_duration, "success")
            request_render(true)
            return
        end
        return
    end
    -- 优化目标（"_goal:xxx"）：一键取向预设，应用后不改当前编码预设（current_preset 不变）
    local goal = tostring(name or ""):match("^_goal:(%w+)$")
    if goal == "size" then
        -- 限定体积：输入目标大小（MB），导出时按总时长推导码率；视频走两遍编码，合并为单遍近似
        if not (mp_input and mp_input.get) then show_hint(L("hint.no_custom_input"),3,"error"); return end
        -- 再次点击已选目标 = 取消，恢复当前预设参数基线
        if state.optimize_goal == "size" then clear_optimize_goal(); return end
        -- 体积异常时"再问一次"，把估算写进提示行：预填原值 -> Enter 即确认执行、Esc 取消回面板，
        -- 也可以直接改成别的数值。询问发生在 closed 阶段（上一个输入框已完全关闭），避免嵌套输入。
        -- 每次询问都要重新进入"输入态"：否则第二次询问期间面板会照常渲染、鼠标一动就把提示盖住。
        local pending_warn, pending_warn_target
        local submitted_size   -- 是否真正提交过：Esc 走到底要连带取消「限定体积」目标
        local ask_size
        -- warn / warn_target = 上一次已经警告过的提示与体积值：
        -- 只有"用户改了数值"才重新判定；若提交的就是刚警告过的那个值（= 看过警告后回车确认），
        -- 直接放行 —— 否则 Enter 永远过不去。
        ask_size = function(warn, warn_target)
        clear_all_context_bindings()
        osd_below_input()
        local pre_prompt = warn and (warn .. "\n") or ""
        local ok_get, get_err = pcall(mp_input.get, {
            prompt = pre_prompt .. L("modal.size_target_prompt") .. " > ",
            default = state.size_target and tostring(state.size_target) or "50",
            submit = function(text)
                local n = tonumber(tostring(text):match("^%s*([%d%.]+)") or "")
                if not n or n <= 0 then show_hint(L("hint.size_target_invalid"), 3, "error"); return end
                if state.optimize_goal == nil then state.goal_prev_accurate = state.accurate_mode end
                state.optimize_goal = "size"
                state.size_target = n
                state.accurate_mode = true  -- 限体积依赖重新编码，流复制无法控体积
                -- 光设码率不够：参数里留着"复制"时 ffmpeg 直接忽略码率，用户看到"限定体积"
                -- 实际跑的却是复制流程（摘要也一直显示复制/crf）。这里就把编码器换成真实编码器，
                -- 摘要随即能看到它，导出侧再保一道。
                -- 限体积必须重编码：只动 copy，不碰用户已选的编码器（按容器挑合法的）
                local notes = {}
                if tostring(opts.video_codec or "") == "copy" then
                    local prev = tostring(opts.video_codec)
                    opts.video_codec = C.real_video_codec_for(opts.encode_container)
                    notes[#notes + 1] = prev .. "→" .. opts.video_codec
                end
                if tostring(opts.audio_codec or "") == "copy" then
                    opts.audio_codec = C.lossy_audio_for(opts.encode_container)
                    notes[#notes + 1] = "copy→" .. opts.audio_codec
                end
                local extra = #notes > 0 and (" " .. L("hint.size_needs_recoding", table.concat(notes, "/"))) or ""
                -- 估算是否属于"极限体积"：**每次提交都判定**（改完再来一个极端值也要拦），
                -- 只有"与刚警告过的值相同"（= 看过警告后回车确认）才跳过判定。
                if warn_target == nil or tonumber(warn_target) ~= n then
                    -- 没设片段 = 导出整片：此时 get_queue() 为空，必须回退到整片时长，否则估算恒为 0
                    local total = 0
                    for _, q in ipairs(get_queue() or {}) do total = total + (q.end_time - q.start_time) end
                    if total <= 0 then total = tonumber((mp.get_property_number("duration", 0))) or 0 end
                    local vk = Export.size_bitrates(n, total)
                    -- 括号不能省：mp.get_property_number 失败时会返回第二个错误串，
                    -- 直接当实参传进 tonumber 就是 "bad argument #2 to 'tonumber'"
                    local bps = mp.get_property_number("video-bitrate", 0)
                    local src_bps = tonumber(bps) or 0
                    -- video-bitrate 经常读不到（刚加载、部分容器/编码、某些硬解状态会返回 0）：
                    -- 读不到就退化为"整片体积 ÷ 整片时长"的整体码率，至少给一个可用参考值。
                    local src_size = 0
                    local p = mp.get_property("path")
                    if p and utils and utils.file_info then
                        local li = utils.file_info(p)
                        if type(li) == "table" and type(li.size) == "number" then src_size = li.size end
                    end
                    local whole_bps = (src_size > 0 and total > 0) and (src_size * 8 / total) or 0
                    local ref_bps = src_bps > 0 and src_bps or whole_bps
                    -- **四个**原因各一句：判定与文案用同一组布尔变量，结构上保证不会张冠李戴
                    --   no_bitrate: 算不出可用码率（预算被 2%+0.5MiB 余量与音频下限吃光）
                    --   oversize  : 目标体积 >= 源文件 → 体积不会更小，码率反被抬高，对画质无增益
                    --   low_floor : 码率低于本机该分辨率的下限
                    --   low_source: 码率不足源码率的 25%（画面会比源文件明显劣化）
                    local no_bitrate = (vk == nil)
                    local oversize = (vk ~= nil) and ref_bps > 0 and (vk * 1000) > ref_bps
                    local low_floor = (vk ~= nil) and (vk < min_video_kbps())
                    local low_source = (vk ~= nil) and ref_bps > 0 and (vk * 1000) < (ref_bps * 0.25)
                    if no_bitrate or oversize or low_floor or low_source then
                        -- 首次询问与二次确认共用同一段文字（pending_warn 直接复用）
                        local detail
                        if no_bitrate then
                            detail = L("modal.size_detail_nobitrate", n, total)
                        elseif oversize then
                            detail = L("modal.size_detail_oversize", n, src_size / 1073741824)
                        elseif low_floor then
                            detail = L("modal.size_confirm_detail", n, total, tostring(vk), min_video_kbps())
                        else
                            detail = L("modal.size_detail_low_source", n, total, tostring(vk),
                                ref_bps / 1000, vk * 1000 / ref_bps * 100)
                        end
                        state.size_target = n   -- 预填：第二次直接回车即确认
                        pending_warn, pending_warn_target = L("modal.size_confirm_warn", detail), n
                        return
                    end
                end
                submitted_size = true
                show_hint(L("hint.goal_applied", L("goal.size")) .. string.format(" · %.0f MB", n) .. extra, opts.action_hint_long_duration)
                request_render(true)
            end,
            closed = function()
                osd_restore()
                if pending_warn then
                    local w, wt = pending_warn, pending_warn_target
                    pending_warn, pending_warn_target = nil, nil
                    ask_size(w, wt)
                    return
                end
                if not submitted_size and state.optimize_goal == "size" then
                    -- 用户按 Esc 放弃了体积输入（也可能是在极端体积的二次询问里放弃）：
                    -- 连带取消「限定体积」目标，否则面板上它仍显示为选中。
                    clear_optimize_goal()
                end
                if state.in_studio then
                    -- 与 prompt_custom_param 相同的上下文分流：size 输入从确认面板的
                    -- 预设下拉进入，必须恢复 confirm 键区，否则面板键盘（Tab/Enter）失效
                    if state.confirm_action then install_confirm_bindings() else install_main_bindings() end
                    mouse_bound = false
                    mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
                end
                request_render(true)
            end,
        })
        -- 同步异常恢复：get 抛错时 closed 不会触发，必须在这里收口，否则蒙版停留
        -- z=-1、全部键位 section 禁用、鼠标冻结，且无日志
        if not ok_get then
            msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
            osd_restore()
            if state.in_studio then
                if state.confirm_action then install_confirm_bindings() else install_main_bindings() end
                mouse_bound = false
                mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
            end
            request_render(true)
        end
        end   -- ask_size
        ask_size(nil)
        return
    end
    if goal then
        -- 再次点击已选目标 = 取消：恢复当前预设参数基线
        if goal == "none" or state.optimize_goal == goal then clear_optimize_goal(); return end
        local applied, note = C.apply_optimize_goal(opts, goal, source_profile())
        if not applied then return end
        if state.optimize_goal == nil then state.goal_prev_accurate = state.accurate_mode end
        state.optimize_goal = goal
        opts.video_quality = C.clamped_number(opts.video_quality, opts.video_quality, 0, 63)
        local coerced = coerce_all()
        -- 目标改了画质参数：快速复制（流复制）下同样自动切重新编码
        local op = state.confirm_action == "merge" and "merge" or "export"
        if not effective_accurate_mode(opts, state.accurate_mode, op) then
            state.accurate_mode = true
        end
        local suffix = coerced and L("hint.format_limit", coerced) or ""
        if note then suffix = suffix .. "  " .. note end
        -- 先拼进变量再查表：避免 i18n 检查器把 "goal." 前缀静态收集成假键
        local goal_key = "goal." .. goal
        show_hint(L("hint.goal_applied", L(goal_key)) .. suffix, opts.action_hint_long_duration)
        request_render(true)
        return
    end
    state.optimize_goal = nil
    local label = C.apply_export_preset(opts, name)
    if (C.EXPORT_PRESETS[name] or {}).from_source then state.accurate_mode = false end
    opts.video_quality = C.clamped_number(opts.video_quality, opts.video_quality, 0, 63)
    -- 预设一次性改动多个字段，可能带入不兼容组合，统一纠正一次
    local coerced = coerce_all()
    local switched = false
    -- 内置预设（网络/高清/归档）都是重编码档，选中后直接进重新编码模式；
    -- 但"跟随源文件"类预设本身就是 copy，不该被强制（否则上面设的 false 立刻被覆盖）。
    if name ~= "default" and not (C.EXPORT_PRESETS[name] or {}).from_source
            and tostring((C.EXPORT_PRESETS[name] or {}).video_codec or "") ~= "copy" then
        local op = state.confirm_action == "merge" and "merge" or "export"
        if not effective_accurate_mode(opts, state.accurate_mode, op) then
            state.accurate_mode = true; switched = true
        end
    end
    local suffix = switched and L("hint.mode_switched") or (name == "default" and L("hint.restored_baseline") or "")
    if coerced then suffix = suffix .. L("hint.format_limit", coerced) end
    show_hint(L("confirm.preset", label) .. suffix, opts.action_hint_long_duration)
    request_render(true)
end

local function clear_marks()
    if not prepare_main_action() then return end
    if Export.job.running then show_hint(L("hint.stop_export_first"),2,"error"); return end
    local has_marks = #state.segments > 0 or state.start_time ~= nil or state.end_time ~= nil
    -- 裁剪也算"本次剪辑的操作"，没有片段但设了裁剪时同样应能清空
    if not has_marks and not crop_is_active(opts) then return end
    remember_action()
    state.start_time,state.end_time,state.segments,state.segment_scroll=nil,nil,{},0
    state.editing_id, state.manual_order = nil, false
    clear_checked()
    state.selected_segment_id = nil
    -- 完全重置裁剪（含自定义坐标），否则下一次导出会沿用旧裁剪区域
    opts.crop_mode, opts.crop_aspect = "none", "source"
    opts.crop_x, opts.crop_y, opts.crop_width, opts.crop_height = 0, 0, 0, 0
    state.crop_ratio_lock = nil
    state.batch_preview = false; state.batch_index = 1
    clear_segment_loop()
    if opts.resume_session then Session.clear(studio_source or mp.get_property("path")) end
    MK.flash("reset"); update_ranges(true); request_render(true)
    show_hint(L("hint.cleared")..L("hint.undo_suffix", primary_key(main_bindings, "undo")), 2)
end

local function set_start()
    if not prepare_main_action() then return end
    remember_action()
    state.start_time=mp.get_property_number("time-pos",0); state.active_handle="start"
    MK.flash("in"); show_hint(L("hint.in",U.format_time(state.start_time)),2); update_ranges(true); request_render(true)
end
local function set_end()
    if not prepare_main_action() then return end
    remember_action()
    state.end_time=mp.get_property_number("time-pos",0); state.active_handle="end"
    MK.flash("out"); show_hint(L("hint.out",U.format_time(state.end_time)),2); update_ranges(true); request_render(true)
end
-- 方向键组合一律只移动播放位置，不直接调整标记（标记的调整手段：鼠标拖拽 / T 时间码）。
local function relative_seek(seconds)
    if not prepare_main_action() then return end
    -- 必须显式 exact：mpv 在 --hr-seek=default 下会把 relative seek 吸附到关键帧。
    -- 实测（60s 片、10s GOP、暂停态）：从 2.0 按一次 → 落到 10.0，换个位置按又停在同一个
    -- 关键帧画面上 —— 这就是"左右键不像在按秒走"的根因。加 exact 后落点是 3.0。
    mp.commandv("seek", tostring(seconds), "relative+exact")
end
local function add_segment()
    -- 只在主界面生效：列表打开时时间轴不可见，看不到入/出点却"添加"是误导
    if not prepare_main_action() then return end
    local n,err=normalize_draft_segment()
    -- 错误文案含 %s 占位符，必须经 L 填参，否则用户会看到裸露的 "%s"
    if not n then show_hint(L(state.editing_id and "hint.save_failed" or "hint.add_failed", tostring(err)),3,"error"); return end
    if state.editing_id then
        local before = model_snapshot()
        before.start_time, before.end_time, before.editing_id = nil, nil, nil
        Editor.history_push(history, before)
        local _, seg = find_segment_index(state.editing_id)
        if not seg then
            state.editing_id = nil
            show_hint(L("hint.origin_gone"), 3,"error")
            return
        end
        local editing_id = state.editing_id
        seg.start_time, seg.end_time = n.start_time, n.end_time
        notify_overlap(seg, editing_id)
        state.editing_id = nil
        -- 保存后清掉选中：否则再点这个片段会被"已选中→取消选择"吃掉第一下，
        -- 表现为"编辑过的片段点击后激活不了删除按钮"（新建的片段没有这个残留）
        state.selected_segment_id = nil
        if opts.auto_sort_segments and not state.manual_order then sort_segments() end
        show_hint(L("hint.edits_saved"),2,"success")
    else
        remember_action()
        n.id,n.label,n.enabled=state.next_id,L("hint.segment_label",state.next_id),true; state.next_id=state.next_id+1
        table.insert(state.segments,n)
        notify_overlap(n, n.id)
        if opts.auto_sort_segments and not state.manual_order then sort_segments() end
        -- 提示（标题 + 时间码）本身两行，1 秒读不完；draft_mode=smart 还会用片头/片尾补齐缺失端点，
        -- 这一步在时间轴上看不出来（未标记端刻意不画），故点名补的是哪一端。
        -- 注意补全说明**并进时间码行**而不是另起一行：同一字号下三行卡片会比主面板还高。
        local msg=L("hint.segment_added",U.format_time(n.start_time),U.format_time(n.end_time))
        if state.start_time==nil then msg=msg..L("hint.mark_filled_in")
        elseif state.end_time==nil then msg=msg..L("hint.mark_filled_out") end
        show_hint(msg,2,"success")
    end
    state.start_time,state.end_time=nil,nil
    state.segment_scroll=math.max(0,#state.segments-(tonumber(opts.max_visible_segments) or 7))
    update_ranges(true); request_render(true)
end

-- 合并后的片段动作按钮（主面板那一个位置）：编辑中 → 保存；有选择（勾选或聚焦）→ 删除；
-- 否则 → 添加。键盘侧刻意不合并：Enter 恒为添加/保存、DEL 恒为删除——否则用 UP/DOWN
-- 浏览片段时误按 Enter 就会把片段删掉（选中是浏览的副产品，不该让动作变成破坏性的）。
segment_action=function()
    if state.editing_id or (checked_count() == 0 and not state.selected_segment_id) then return add_segment() end
    return delete_selection()
end

-- 片段列表页脚的操作分发：上移/下移/编辑需要"唯一目标"，多选或未选中时给出明确提示
list_op=function(kind)
    if kind == "add" then return add_segment() end
    if kind == "delete" then return delete_selection() end
    if kind == "toggle" then return toggle_segment_scope() end
    local id = state.selected_segment_id
    if not id or checked_count() > 1 then show_hint(L("hint.select_single_first"), 2, "error"); return end
    if kind == "up" then return move_segment(id, -1) end
    if kind == "down" then return move_segment(id, 1) end
    if kind == "edit" then return begin_edit_segment(id) end
    if kind == "rename" then return rename_segment() end
end

-- 一帧的时长：**优先 container-fps**（流的标称帧率，暂停时也稳定）；
-- estimated-vf-fps 是播放中的估算值，暂停/异常源上可能离谱（曾导致"步进只有 1ms、画面看着不动"）。
-- 再夹到 [1/240, 1/2]：无论属性怎么坏，步进都不会退化成看不见、也不会一步半秒。
local function get_frame_duration()
    local fps=mp.get_property_number("container-fps",mp.get_property_number("estimated-vf-fps",25))
    if not fps or fps <= 0 then fps=25 end
    return math.max(1/240, math.min(0.5, 1/fps))
end

local function timeline_handle_at_x(x,duration)
    return Editor.find_handle(x,duration,timeline_bounds,{start_time=state.start_time,end_time=state.end_time},opts.timeline_handle_hit_radius,state.active_handle)
end
local function select_timeline_handle(handle)
    local key=handle=="end" and "end_time" or "start_time"; local value=state[key]
    if value==nil then return false end
    state.active_handle=handle; mp.commandv("seek",value,"absolute+exact")
    show_hint(handle=="end" and L("hint.selected_out", U.format_time(value)) or L("hint.selected_in", U.format_time(value)),opts.action_hint_duration)
    request_render(true); return true
end
local function timeline_time_from_x(x,duration) return Editor.x_to_time(x,duration,timeline_bounds,opts.timeline_edge_snap) end

render_ui=function()
    -- mp.input 输入期间：OSD 由 osd_below_input 写入的轻量蒙版帧接管，面板冻结不渲染
    -- （交互已冻结，且避免全量 ASS 帧重复生成/解析造成输入期打字卡顿）
    if state.input_active then return end
    if not state.in_studio then
        overlay:remove()
        return
    end
    local ok, result=pcall(ui.render, ui, {
        mp=mp, overlay=overlay, opts=opts, theme=theme, state=state, job=Export.job, L=L, STAGE_LABELS=STAGE_LABELS,
        hovered_id=hovered_id, hovered_tip=hovered_tip,
        crop_is_active=crop_is_active, crop_rect=Crop.rect, crop_to_screen_rect=Crop.crop_to_screen_rect, displayed_video_rect=Crop.displayed_video_rect,
        normalize_segment=normalize_segment, normalize_draft_segment=normalize_draft_segment, text_width=U.text_width, format_time=U.format_time, truncate_chars=U.truncate_chars, effective_accurate_mode=effective_accurate_mode,
        toggle_segment_list=toggle_segment_list, set_start=set_start, set_end=set_end, add_segment=add_segment,
    edit_selected_segment=function()
        if state.selected_segment_id and not state.editing_id then begin_edit_segment(state.selected_segment_id) end
    end,
        split_at_playhead=split_at_playhead, delete_selected_segment=delete_selected_segment,
        execute_cut=execute_cut, execute_merge=execute_merge, open_last_output_directory=open_last_output_directory, cancel_edit=cancel_edit, clear_marks=clear_marks, cycle_export_preset=cycle_export_preset,
        focus_segment=focus_segment, toggle_checked=toggle_checked, is_checked=is_checked, checked_count=checked_count,
        delete_selection=delete_selection, segment_action=segment_action,
        toggle_range=toggle_range_of_focus, apply_segment_loop=apply_segment_loop,
        list_op=list_op,
        set_export_kind=set_export_kind, toggle_merge_output=toggle_merge_output, EXPORT_KINDS=C.EXPORT_KINDS,
        encode_param_text=encode_param_text, ENCODE_PARAMS=active_params(),
        -- 参数可见性规则（按模式/导出类型收参数）由 config 提供；ui 侧拿不到 C，只能走 ctx
        param_visible=C.param_visible,
        -- 没装 ffmpeg 时（导出走 mpv 兜底）把"整类做不了"的控件置灰并说明原因：
        -- ffmpeg_missing 判运行态，missing_ffmpeg_tip 查单个参数该用哪条提示。
        ffmpeg_missing=C.ffmpeg_missing, missing_ffmpeg_tip=C.missing_ffmpeg_tip,
        -- 模式切换：写状态 + 说明"为什么点了没变"（去静音/码率模式/视频滤镜/裁剪锁定都会
        -- 让 effective 保持精确，原来点了毫无反馈，看起来就像白洗没跟着变）。
        set_accurate_mode=function(want)
            want = want and true or false
            if Export.job.running then show_hint(L("hint.cannot_modify_encode"),2,"error"); return end
            if Crop.is_active and Crop.is_active(opts) then
                show_hint(L("confirm.crop_locked_short"),3,"info"); return
            end
            -- 没有 ffmpeg 时快速复制是整类不可用：按钮已置灰且 fn 为 nil，正常点不到；
            -- 这里再拦一道，防止键盘/脚本消息绕过按钮直接调进来。
            if not want and C.ffmpeg_missing() then
                show_hint(L("hint.mpv_no_copy_mode"),3,"error"); return
            end
            state.accurate_mode = want
            if not want then
                local why
                if opts.remove_silence == true then why = L("param.remove_silence")
                elseif tostring(opts.video_quality_mode or "") == "bitrate" then why = L("param.quality_mode")
                else why = L("confirm.mode_blocked_filters") end
                if effective_accurate_mode(opts,false,"export") then
                    show_hint(L("hint.mode_kept_precise",why),4,"info")
                end
            end
            request_render(true)
        end,
        -- "已修改"双态 / 回退 / 恢复默认 / 源文件参照行（判定与取值在 config.lua，这里只做遍历）
        encode_param_modified=function(id)
            local base=C.encode_baseline()
            for _,spec in ipairs(active_params()) do
                if spec.id==id then return C.param_is_modified(spec,opts,base) end
            end
            return false
        end,
        any_param_modified=function()
            local base=C.encode_baseline()
            for _,spec in ipairs(active_params()) do
                if C.param_is_modified(spec,opts,base) then return true end
            end
            return false
        end,
        reset_encode_param=function(id)
            local base=C.encode_baseline()
            for _,spec in ipairs(active_params()) do
                if spec.id==id then
                    apply_param_value(spec,tostring(C.param_baseline_value(spec,opts,base) or ""),true)
                    if not Export.job.running then
                        show_hint(L("hint.param_reverted",L(spec.label),encode_param_text(id)),opts.action_hint_long_duration)
                    end
                    state.confirm_focus="cp_"..id   -- 连按可继续回退同一格（apply 会把焦点踢回开始）
                    request_render(true)
                    return
                end
            end
        end,
        -- 源文件参照行：源文件的实际编码参数（只读，用来与"编码格式"的目标参数对照）
        source_param_text=function()
            local s = C.source_info()
            if not s then return L("confirm.source_none") end
            local p = {}
            if s.video_codec ~= "" then p[#p+1] = s.video_codec end
            if s.width > 0 and s.height > 0 then p[#p+1] = string.format("%d×%d", s.width, s.height) end
            if s.fps > 0 then p[#p+1] = string.format("%g fps", s.fps) end
            if s.audio_codec ~= "" then
                p[#p+1] = s.audio_codec
                if s.channels > 0 then p[#p+1] = string.format("%dch", s.channels) end
                if s.samplerate > 0 then p[#p+1] = string.format("%g kHz", s.samplerate/1000) end
            end
            if #p == 0 then return L("confirm.source_none") end
            return table.concat(p, " · ")
        end,
        param_options=param_options, set_encode_param=set_encode_param, set_export_preset=set_export_preset,
        -- choice_name：选单按钮在窄尺寸显示的值。注释必须独占一行：写成行尾注释会把它后面的
        -- 字段（DROPDOWN_MAX_ROWS）一起注释掉，ctx 通道会静默断链
        toggle_param_dropdown=toggle_param_dropdown, preset_label=C.preset_label, goal_label=goal_label, choice_label=choice_label, choice_name=choice_name, choice_tip=choice_tip, DROPDOWN_MAX_ROWS=C.DROPDOWN_MAX_ROWS,
        select_crop_preset=Crop.select_preset, align_crop=Crop.align, enter_crop_editor=Crop.enter_editor, confirm_execute=confirm_execute,
        open_crop_editor=open_crop_editor, crop_size_input=open_crop_size_input,
        crop_done=function() Crop.exit_editor(false) end, crop_cancel=function() Crop.cancel_editor() end,
        move_segment=move_segment, begin_edit_segment=begin_edit_segment,
        get_queue=get_queue, encode_summary=Export.encode_summary, request_render=request_render,
        wave=wave_cache,
        toggle_waveform=toggle_waveform,
        install_main_bindings=install_main_bindings,
        undo_count=#history.undo, redo_count=#history.redo,
        key_help_main=main_bindings, key_help_crop=crop_bindings, key_help_confirm=confirm_bindings,
    })
    -- pcall 只防异常，防不住"正常返回 nil"：必须同时校验结果类型，否则下方解引用会抛出
    -- 未捕获错误并终止脚本（此时 Takeover.hide 已执行，OSC 将无人恢复）。
    if not ok or type(result) ~= "table" then
        msg.error("quick_cut render failed: "..tostring(result))
        -- 渲染失败不能让界面毫无反馈：给一条 OSD 提示，避免用户误以为脚本卡死
        mp.osd_message(L("hint.render_failed"), 3)
        return
    end
    buttons=result.buttons
    button_panel_bounds=result.button_panel_bounds
    timeline_bounds=result.timeline_bounds
end

local function timeline_drag_update(final)
    if not timeline_drag.down then return end
    local p=mp.get_property_native("mouse-pos"); local duration=mp.get_property_number("duration",0)
    if not p or duration<=0 then return end
    local distance=math.abs(p.x-timeline_drag.start_x)
    if not timeline_drag.active and distance>=opts.timeline_drag_threshold then
        timeline_drag.active=true
        if (timeline_drag.kind=="handle" or timeline_drag.kind=="segment") and not timeline_drag.history_saved then remember_action(); timeline_drag.history_saved=true end
    end
    if not timeline_drag.active then return end
    local t=Editor.x_to_time(p.x,duration,timeline_bounds,0); timeline_drag.last_time=t
    if timeline_drag.kind=="segment" then
        -- 拖拽已保存片段的边界：改片段时间，不触发 seek
        local seg=timeline_drag.seg
        if not seg then return end
        local key=timeline_drag.handle=="end" and "end_time" or "start_time"
        seg[key]=Editor.clamp_handle(timeline_drag.handle,t,seg.start_time,seg.end_time,duration,min_len())
        state.selected_segment_id=seg.id
        -- 正在编辑这一段时，草稿（state.start_time/end_time）必须跟着走：
        -- 屏幕上直接显示的是草稿那两根标记杆，只改 seg 会让它们留在原位，
        -- 看起来就是"拖动没生效，得再拖一次"。
        if state.editing_id==seg.id then state[key]=seg[key] end
        update_ranges(false); request_render(false)
        return
    elseif timeline_drag.kind=="handle" then
        local key=timeline_drag.handle=="end" and "end_time" or "start_time"
        state[key]=Editor.clamp_handle(timeline_drag.handle,t,state.start_time,state.end_time,duration,min_len())
        state.active_handle=timeline_drag.handle
        update_ranges(false); request_render(false)
    else
        local now=mp.get_time(); state.drag_preview_time=t; request_render(false)
        if final or now-timeline_drag.last_seek>=1/opts.timeline_drag_seek_fps then
            timeline_drag.last_seek=now
            mp.commandv("seek",t,final and "absolute+exact" or "absolute+keyframes")
        end
    end
end

local function reset_timeline_drag(restore_playback)
    local resume=restore_playback and opts.timeline_drag_resume and not timeline_drag.was_paused
    timeline_drag.down=false
    timeline_drag.active=false
    timeline_drag.kind=nil
    timeline_drag.handle=nil
    timeline_drag.seg=nil
    timeline_drag.history_saved=false
    state.drag_preview_time=nil
    if resume then mp.set_property_bool("pause",false) end
end

local crop_drag={down=false}
local last_drag_diag   -- 拖拽命中诊断去重（见 timeline_mouse_event 的 down 分支）
-- 时间轴上命中的片段边界（±6px，优先选中片段）；用于直接拖拽已保存片段的起止时间。
local function segment_boundary_at_x(x, duration)
    if duration <= 0 or #state.segments == 0 then return nil end
    local hit
    for _, seg in ipairs(state.segments) do
        local x1 = Editor.time_to_x(seg.start_time, duration, timeline_bounds)
        local x2 = Editor.time_to_x(seg.end_time, duration, timeline_bounds)
        if x1 and x2 then
            local handle
            if math.abs(x - x1) <= 6 then handle = "start"
            elseif math.abs(x - x2) <= 6 then handle = "end" end
            if handle then
                if seg.id == state.selected_segment_id then return {seg=seg, handle=handle} end
                hit = hit or {seg=seg, handle=handle}
            end
        end
    end
    return hit
end
local function timeline_mouse_event(event)
    if type(event)~="table" or not event.event then return end
    -- mp.input 输入期间不接受任何鼠标事件（防残留绑定通道导致状态错乱）
    if state.input_active then return end
    local p=mp.get_property_native("mouse-pos")
    if not p then reset_timeline_drag(true); return end
    if event.event=="down" then
        -- 键位速查浮层打开时：点击任意处（含时间轴区域）关闭，不进入拖拽/scrub
        if state.help then state.help=false; request_render(true); return end
        -- 按下瞬间先把 hover / 鼠标绑定同步到"当前指针位置"再命中。
        -- 面板每次渲染都会重排、按钮会换位（例如刚进编辑态），若鼠标自上次移动后
        -- 一直没动，hit 数据可能整体过期 —— 现象就是"第一次拖动没反应、要拖两次"。
        -- pcall：极端时序下（指针刚离开 UI、绑定正要被卸载）刷新可能失败，
        -- 但绝不能因此打断这次点击/拖拽的处理。
        pcall(mouse_move, "mouse-pos", p)
        -- 裁剪窗口里的面板**浮在视频区之上**，所以必须先判面板按钮，再判裁剪框拖拽：
        -- 否则点在面板上也会被下面的 drag_begin 当成"拖动裁剪框"吞掉 ——
        -- 现象就是"刚进裁剪窗口点按钮没反应，先拖一下裁剪框才生效"。
        if state.crop_editing then
            for i=#buttons,1,-1 do
                local b=buttons[i]
                if b.layer=="main" and p.x>=b.x1 and p.x<=b.x2 and p.y>=b.y1 and p.y<=b.y2 then
                    run_button(b); return
                end
            end
        end
        -- 裁剪编辑模式优先处理裁剪框拖拽
        if state.crop_editing then
            local ok, mode = pcall(Crop.drag_begin, p.x, p.y)
            if not ok then
                -- 吞掉错误会让"点裁剪框没反应"完全无法排查，至少记入日志
                msg.error("quick_cut: crop drag_begin failed: " .. tostring(mode))
            elseif mode then
                crop_drag.down=true
                return
            end
        end
        local on_timeline=not state.hud_hidden and not state.modal and not state.confirm_action
            and p.x>=timeline_bounds.x1 and p.x<=timeline_bounds.x2
            and p.y>=timeline_bounds.y1 and p.y<=timeline_bounds.y2
        if not on_timeline then
            if mouse_click then
                local ok,err=pcall(mouse_click,true)
                if not ok then msg.error("quick_cut button click failed: "..tostring(err)) end
            end
            return
        end
        timeline_drag.down=true
        timeline_drag.active=false
        timeline_drag.start_x=p.x
        timeline_drag.last_seek=0
        timeline_drag.history_saved=false
        local duration=mp.get_property_number("duration",0)
        -- 已保存片段的边界优先于入/出点草稿手柄：前者是"更重"的已有对象
        local edge=segment_boundary_at_x(p.x,duration)
        -- **但正在编辑的那一段例外**：编辑态的语义是"改草稿 → Enter 保存 / Esc 取消"，
        -- 若还按"改已保存片段"处理，就会直接写进片段 —— 现象是每次拖动都提示"片段已保存"、
        -- 且点取消也退不回去。这里把它降级成草稿手柄。
        if edge and state.editing_id and edge.seg.id == state.editing_id then edge = nil end
        timeline_drag.seg=edge and edge.seg or nil
        timeline_drag.handle=edge and edge.handle or timeline_handle_at_x(p.x,duration)
        timeline_drag.kind=edge and "segment" or (timeline_drag.handle and "handle" or "scrub")
        timeline_drag.was_paused=mp.get_property_bool("pause")
        if opts.timeline_drag_pause and not timeline_drag.was_paused then mp.set_property_bool("pause",true) end
        -- 命中诊断（同一结果只打一行）：排查"拖动要两次/没反应"时先看这行
        local diag=string.format("kind=%s handle=%s seg=%s x=%.0f tl_x=[%.0f,%.0f] y=%.0f tl_y=[%.0f,%.0f] editing=%s",
            tostring(timeline_drag.kind),tostring(timeline_drag.handle),
            tostring(timeline_drag.seg and timeline_drag.seg.id),p.x,
            timeline_bounds.x1,timeline_bounds.x2,p.y,timeline_bounds.y1,timeline_bounds.y2,
            tostring(state.editing_id~=nil))
        if last_drag_diag~=diag then last_drag_diag=diag; msg.info("quick_cut drag: "..diag) end
    elseif event.event=="up" then
        if crop_drag.down then
            crop_drag.down=false
            Crop.drag_end()
            return
        end
        if not timeline_drag.down then return end
        timeline_drag_update(true)
        local was_active=timeline_drag.active
        local kind=timeline_drag.kind
        local handle=timeline_drag.handle
        if was_active and kind=="segment" then
            -- 片段边界拖拽结束：提示重叠冲突，不 seek
            local seg=timeline_drag.seg
            if seg then notify_overlap(seg, seg.id) end
            show_hint(L("hint.edits_saved"),1,"success")
        elseif was_active and kind=="handle" then
            local key=handle=="end" and "end_time" or "start_time"
            local value=state[key]
            if value then mp.commandv("seek",value,"absolute+exact") end
            show_hint(handle=="end" and L("hint.out_moved") or L("hint.in_moved"),1,"success")
        elseif not was_active and mouse_click then
            local ok,err=pcall(mouse_click)
            if not ok then msg.error("quick_cut timeline click failed: "..tostring(err)) end
        end
        reset_timeline_drag(true)
        request_render(true)
    end
end

-- outside=true 表示这次点击落在"时间轴与按钮面板之外"（由 timeline_mouse_event 的 down 分支传入）。
-- 参数刻意只在 down 时传：up 时的坐标可能已经滑出时间轴几个像素，用它判定会误取消选择。
mouse_click=function(outside)
    if not state.in_studio then return end
    -- 键位速查浮层打开时：点击任意处关闭，不穿透到下层按钮
    if state.help then state.help=false; request_render(true); return end
    local p = mp.get_property_native("mouse-pos"); if not p then return end
    local function in_rect(r) return r and p.x >= r.x1 and p.x <= r.x2 and p.y >= r.y1 and p.y <= r.y2 end
    run_button=function(b)
        if b.fn then
            local ok, err = pcall(b.fn)
            if not ok then
                -- 与 safe_action 标准一致：日志 + OSD 提示，避免点击毫无反馈
                U.log_error(err)
                show_hint(L("hint.action_failed"), 4, "error")
                request_render(true)
            end
        end
    end
    -- 下拉菜单展开时：优先命中浮层选项；点击浮层外区域收起下拉
    if state.param_dropdown then
        for i = #buttons, 1, -1 do
            local b = buttons[i]
            if b.layer == "confirm" and b.id:sub(1,3) == "dp_" and in_rect(b) then run_button(b); return end
        end
        if not in_rect(state.dropdown_rect) then
            state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
            request_render(true); return
        end
        return -- 点击浮层内但未命中选项（边框/空白）：忽略，避免误触被覆盖的下层按钮
    end
    for i = #buttons, 1, -1 do
        local b = buttons[i]
        local allowed=(state.confirm_action and b.layer=="confirm") or (not state.confirm_action and state.modal and b.layer=="modal") or (not state.confirm_action and not state.modal and b.layer=="main")
        if allowed and in_rect(b) then run_button(b); return end
    end
    if state.confirm_action then return end
    if not state.modal and p.x>=timeline_bounds.x1 and p.x<=timeline_bounds.x2 and p.y>=timeline_bounds.y1 and p.y<=timeline_bounds.y2 then
        local duration=mp.get_property_number("duration",0)
        if duration>0 then
            local handle=timeline_handle_at_x(p.x,duration)
            if handle and select_timeline_handle(handle) then return end
            local clicked_time=timeline_time_from_x(p.x,duration)
            local candidates=Editor.find_segments_at_time(state.segments,clicked_time)
            if #candidates>0 then
                -- 点片段块 = 单选该段（清空勾选），播放范围随之收窄到这一段
                local chosen=Editor.cycle_candidate(candidates,state.selected_segment_id)
                -- 取消选中只走"点时间轴空白 / 点别的片段"：
                -- 重复点同一段不再切换选中状态，只把播放头移过去，避免误触丢掉当前选中。
                if chosen.segment.id==state.selected_segment_id then
                    mp.commandv("seek",clicked_time,"absolute+exact")
                    request_render(true); return
                end
                focus_segment(chosen.segment.id)
                mp.commandv("seek",clicked_time,"absolute+exact")
                show_hint(L("hint.selected_segment", tostring(chosen.segment.label or chosen.segment.id)),opts.action_hint_duration)
                apply_segment_loop()
                request_render(true); return
            end
            -- 点空白 = 取消全部选择（播放范围清空 → 恢复自由播放）
            clear_selection()
            clear_segment_loop()
            mp.commandv("seek",clicked_time,"absolute+exact"); request_render(true)
        end
    end
    -- 点画面区（面板与时间轴之外）= 取消选择：时间轴被片段铺满时"点空白"没有落点，
    -- 这里提供一个永远存在的落点。只在 down 且确实落在画面区时生效（见 mouse_click 的 outside 参数）；
    -- 裁剪编辑中不生效（裁剪框就在画面区里，误点会顺手把选中清掉）。
    -- 代价：有选中时左键被脚本接管，这段时间内的"左键=播放/暂停"要让给 SPACE。
    -- 只在"主界面"生效：裁剪编辑（裁剪框就在画面区）、片段列表/确认面板（各自有焦点与页脚动作，
    -- 页脚按钮作用于"聚焦段"，误清会让它们变成"请先选中一个片段"）都不在这里取消选择。
    -- 确认面板更早就 return 了；这里补 modal 与裁剪。
    if outside and not state.crop_editing and not state.modal and not state.hud_hidden
        and (state.selected_segment_id ~= nil or #state.checked > 0) then
        clear_selection(); clear_segment_loop()
        show_hint(L("hint.range_cleared"),opts.action_hint_duration)
        request_render(true)
    end
end
local function wheel(delta)
    -- 确认面板下拉浮层展开时：滚轮滚动选项列表
    if state.confirm_action and state.param_dropdown then
        local n = #param_options(state.param_dropdown.id)
        local dmax = math.max(1, tonumber(C.DROPDOWN_MAX_ROWS) or 10)
        if n > dmax then
            state.dropdown_scroll = math.max(0, math.min(n - dmax, (state.dropdown_scroll or 0) + delta)); request_render(true)
        end
        return
    end
    if not state.modal then return end
    local maxv = math.max(1, tonumber(opts.max_visible_segments) or 7)
    state.segment_scroll = math.max(0, math.min(math.max(0, #state.segments - maxv), state.segment_scroll + delta)); request_render(true)
end
mouse_move = function(_,p)
    if not state.in_studio or not p then return end
    -- mp.input 输入期间冻结：不更新 hover、不重装鼠标绑定（否则会把点击绑定装回来，
    -- 出现"输入框开着仍能点面板"的状态错乱；closed 回调负责恢复）
    if state.input_active then return end
    if timeline_drag.down then timeline_drag_update(false) end
    if crop_drag.down then
        local ok, err = pcall(Crop.drag_move, p.x, p.y)
        if not ok then msg.error("quick_cut crop drag failed: "..tostring(err)) end
    end
    local inside_panel=p.x>=button_panel_bounds.x1 and p.x<=button_panel_bounds.x2
        and p.y>=button_panel_bounds.y1 and p.y<=button_panel_bounds.y2
    local inside_timeline=p.x>=timeline_bounds.x1 and p.x<=timeline_bounds.x2
        and p.y>=timeline_bounds.y1 and p.y<=timeline_bounds.y2
    -- crop_editing 必须计入：裁剪框在视频区域内，拖动裁剪框时鼠标不在面板/时间轴上，
    -- 漏掉它会在拖动中被判定为"离开 UI"从而解除点击绑定（按钮点不动）
    local inside=inside_panel or inside_timeline or state.modal or state.confirm_action or state.crop_editing
    -- 有选中/勾选时把左键绑定扩到"整窗"（want_bind="click"）：这样点画面区就能取消选择。
    -- 但滚轮绑定只在指针位于 UI 内时才装 —— 否则会顺手抢走 mpv 的"滚轮=seek"，那是得不偿失的。
    -- mouse_bound 复用为三态：false / "click"（只左键）/ "both"（左键+滚轮），换挡时需要重装。
    local has_sel = state.selected_segment_id ~= nil or #state.checked > 0
    -- 滚轮只在"确实会被脚本消费"时才接管（片段列表 / 确认面板的下拉展开）。
    -- 不这么收窄的话，脚本的强制滚轮绑定会盖住 extra_bindings 里的 WHEEL_* ——
    -- 那正是用户放行"滚轮调音量"时最容易被踩的坑（指针一旦进入 UI 音量就失效）。
    -- （局部变量预算紧张，want_wheel 内联在这行里，不给 render/mouse_move 再添一格）
    local want_bind = (inside or has_sel)
        and (((state.modal or (state.confirm_action and state.param_dropdown)) and "both") or "click") or false
    if want_bind and mouse_bound ~= want_bind then
        mp.remove_key_binding("quick_cut_click")
        mp.remove_key_binding("quick_cut_wheel_up")
        mp.remove_key_binding("quick_cut_wheel_down")
        mp.add_forced_key_binding("MBTN_LEFT","quick_cut_click",timeline_mouse_event,{complex=true})
        if want_bind == "both" then
            mp.add_forced_key_binding("WHEEL_UP", "quick_cut_wheel_up", function() wheel(-1) end)
            mp.add_forced_key_binding("WHEEL_DOWN", "quick_cut_wheel_down", function() wheel(1) end)
        end
        mouse_bound = want_bind
    elseif not want_bind and mouse_bound and not timeline_drag.down and not crop_drag.down then
        mp.remove_key_binding("quick_cut_click"); mp.remove_key_binding("quick_cut_wheel_up"); mp.remove_key_binding("quick_cut_wheel_down"); mouse_bound = false
    end
    local old=hovered_id; local old_time=state.hover_time
    state.hover_time,state.hover_x=nil,nil
    if not state.hud_hidden and not state.modal and not state.confirm_action and p.x>=timeline_bounds.x1 and p.x<=timeline_bounds.x2 and p.y>=timeline_bounds.y1 and p.y<=timeline_bounds.y2 then
        local duration=mp.get_property_number("duration",0); if duration>0 then state.hover_time=timeline_time_from_x(p.x,duration); state.hover_x=p.x end
    end
    hovered_id,hovered_tip=nil,nil
    if inside then
        for i = #buttons, 1, -1 do
            local b = buttons[i]
            local allowed=(state.confirm_action and b.layer=="confirm") or (not state.confirm_action and state.modal and b.layer=="modal") or (not state.confirm_action and not state.modal and b.layer=="main")
            if allowed and p.x >= b.x1 and p.x <= b.x2 and p.y >= b.y1 and p.y <= b.y2 then
                hovered_id, hovered_tip = b.id, b.tip
                break
            end
        end
    end
    if old~=hovered_id or old_time~=state.hover_time then request_render() end
end
local function on_time()
    if not state.in_studio then return end
    request_render()
    if state.start_time ~= nil and state.end_time == nil then update_ranges() end
    -- 范围连播（勾选 ≥2 段）：播放越过当前段出点即推进到范围里的下一段，
    -- 播完范围最后一段回到范围首段继续（范围由「选择」决定，取消选择即恢复自由播放）
    if state.batch_preview then
        local range = range_segments()
        local pos = mp.get_property_number("time-pos", 0)
        local seg = range[state.batch_index]
        if #range < 2 then
            -- 范围被改动（取消勾选/删除片段等）：重新推导一次，避免状态残留
            apply_segment_loop(); request_render(true); return
        end
        if not seg then
            state.batch_index = 1
        elseif pos >= (tonumber(seg.end_time) or 0) - 0.03 then
            state.batch_index = state.batch_index < #range and (state.batch_index + 1) or 1
            local nxt = range[state.batch_index]
            if nxt then mp.commandv("seek", tostring(nxt.start_time), "absolute+exact") end
            request_render(true)
        end
    end
end
local function on_osd_dimensions()
    request_render(true)
end

local function close_or_exit()
    -- 键位速查浮层在最顶层：第一次 Esc 先关浮层
    if state.help then state.help=false; request_render(true); return end
    if state.param_dropdown then state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil; request_render(true)
    elseif state.confirm_action then
        reset_confirm_params()
        state.confirm_action=nil; state.confirm_focus=nil
        install_main_bindings(); request_render(true)
    elseif state.crop_editing then return
    elseif state.modal then state.modal=false; request_render(true)
    elseif state.editing_id then cancel_edit(false)
    else mp.commandv("script-message-to",mp.get_script_name(),"exit_studio_mode") end
    -- 面板开合改变预览循环的合法性：开面板时挂起、关面板后恢复（apply_segment_loop 内部自检）
    apply_segment_loop()
end

local function toggle_playback()
    mp.commandv("cycle","pause")
end

-- ============================================================================
-- 播放范围应用（原「片段预览」）：单段用 mpv 原生 A-B 循环把播放限制在段内；
-- 多段改由 on_time 推进（mpv 只能记住一对 ab 点）。范围来自「选择」，
-- 没有独立开关。模态/裁剪/确认面板打开时清掉循环（下面有守卫，面板关闭后由调用点重算）。
-- 属性语义（mpv 手册 PLAYBACK CONTROL / Properties，验证基于官方文档）：
--   ab-loop-a / ab-loop-b：<time>，任一为 "no"（默认值）即禁用循环；
--   ab-loop-count：<N|inf>，默认 inf（无限循环）；设为 0 会整体禁用且 ab-loop 命令也无法再启用。
-- 注意：mpv 没有 "loop-ab" 这个属性/选项，对它 set_property 只会静默失败。
-- ============================================================================
local function set_ab_prop(name, value)
    local ok, err = pcall(mp.set_property, name, value)
    if not ok then
        -- 预览循环失效必须可排查：过老版本的 mpv 可能缺少这些属性
        msg.warn(string.format("quick_cut: set %s=%s failed: %s", name, tostring(value), tostring(err)))
    end
    return ok
end

apply_segment_loop=function()
    -- 播放范围由「选择」推导，不再有独立开关：
    --   0 段 → 清掉循环；1 段 → A-B 循环；≥2 段 → 交给 on_time 越过出点推进
    local range = range_segments()
    if not state.in_studio or #range == 0 then
        state.batch_preview = false; state.batch_index = 1
        clear_segment_loop()
        return
    end
    -- 模态/裁剪/确认面板打开时暂停播放范围，避免干扰面板操作
    if state.modal or state.crop_editing or state.confirm_action then
        state.batch_preview = false; state.batch_index = 1
        clear_segment_loop()
        return
    end
    if #range >= 2 then
        -- 连播：mpv 只能记住一对 ab 点，所以多段范围必须清掉 A-B，由 on_time 推进
        clear_segment_loop()
        local pos = mp.get_property_number("time-pos", 0)
        local idx = 1
        for i, s in ipairs(range) do
            if pos < (tonumber(s.end_time) or 0) then idx = i; break end
        end
        state.batch_preview = true
        state.batch_index = idx
        return
    end
    -- 单段：走 mpv 原生 A-B 循环
    state.batch_preview = false; state.batch_index = 1
    local seg = range[1]
    local s, e = tonumber(seg.start_time), tonumber(seg.end_time)
    if not s or not e or e <= s then
        clear_segment_loop()
        return
    end
    -- count 必须为 inf：若被外部（如用户配置/其他脚本）设为 0，ab 点再正确循环也被整体禁用
    set_ab_prop("ab-loop-count", "inf")
    set_ab_prop("ab-loop-a", tostring(s))
    set_ab_prop("ab-loop-b", tostring(e))
end

clear_segment_loop=function()
    -- 任一 ab 点设为 "no" 即禁用循环（手册：a/b 默认 no，缺一即禁）
    set_ab_prop("ab-loop-a", "no")
    set_ab_prop("ab-loop-b", "no")
end

-- 确认面板键盘焦点：当前可聚焦的 confirm 按钮（下拉浮层展开时仅浮层选项）
local function confirm_focusable()
    -- 焦点顺序：**参数行排在前面**。默认焦点在「开始」按钮上，从它 Tab 一步就该落到参数网格；
    -- 若按绘制顺序（导出类型×5 → 输出方式×2 → 参数 → 模式/预设/取消/开始）走，
    -- 下拉展开时只有 dp_* 可聚焦，此时维持原顺序。
    local params, others = {}, {}
    local dd_only = state.param_dropdown ~= nil
    for _, b in ipairs(buttons) do
        if b.layer == "confirm" and b.fn then
            if dd_only then
                if b.id:sub(1,3) == "dp_" then others[#others + 1] = b end
            elseif b.id:sub(1,3) == "cp_" then
                params[#params + 1] = b
            else
                others[#others + 1] = b
            end
        end
    end
    if dd_only then return others end
    for _, b in ipairs(others) do params[#params + 1] = b end
    return params
end
-- Tab 在可聚焦按钮间循环移动焦点
local function confirm_focus_move(delta)
    if not state.confirm_action then return end
    local list = confirm_focusable()
    if #list == 0 then return end
    local idx = 1
    for i, b in ipairs(list) do if b.id == state.confirm_focus then idx = i break end end
    state.confirm_focus = list[((idx - 1 + delta) % #list) + 1].id
    request_render(true)
end
-- Enter 激活当前焦点按钮（等价于鼠标点击）
local function confirm_focus_activate()
    if not state.confirm_action or not state.confirm_focus then return end
    for _, b in ipairs(buttons) do
        if b.id == state.confirm_focus and b.fn then
            local ok, err = pcall(b.fn)
            if not ok then
                U.log_error(err)
                show_hint(L("hint.action_failed"), 4, "error")
                request_render(true)
            end
            return
        end
    end
end
-- 左右键：调整"当前聚焦那个参数"的值（cycle_encode_param 的键盘入口；下拉浮层展开时
-- 改为在选项间移动高亮，等价于 Tab/Shift+Tab，Enter 仍是选中）。
-- 焦点不在参数行时**不动作**：否则会出现"在取消按钮上按右方向键却把参数改了"。
-- 确认面板与本面板/裁剪是互斥的 input section（install 时切换），所以这里的 LEFT/RIGHT
-- 也不会穿透到 mpv 内置 seek（含用户 input.conf 的绑定）。
local function confirm_param_step(delta)
    if not state.confirm_action then return end
    if state.param_dropdown then confirm_focus_move(delta); return end
    local id = tostring(state.confirm_focus or ""):match("^cp_(.+)$")
    if not id then return end
    cycle_encode_param(id, delta)
end
-- 导出确认面板独立输入上下文：Tab 循环焦点、左右键调值、Enter 激活、? 速查、Esc 关闭
local function confirm_action(action)
    if not state.in_studio or not state.confirm_action then return end
    if action == "close" then close_or_exit()
    elseif action == "focus_next" then confirm_focus_move(1)
    elseif action == "focus_prev" then confirm_focus_move(-1)
    elseif action == "param_next" then confirm_param_step(1)
    elseif action == "param_prev" then confirm_param_step(-1)
    -- 回退当前聚焦参数（Backspace）：与鼠标点单元格里的 ⟲ 同一条路径
    elseif action == "param_reset" then
        local id = tostring(state.confirm_focus or ""):match("^cp_(.+)$")
        if id and not Export.job.running then
            local base = C.encode_baseline()
            for _, spec in ipairs(active_params()) do
                if spec.id == id then
                    apply_param_value(spec, tostring(C.param_baseline_value(spec, opts, base) or ""), true)
                    show_hint(L("hint.param_reverted", L(spec.label), encode_param_text(id)), opts.action_hint_long_duration)
                    state.confirm_focus = "cp_" .. id
                    request_render(true)
                    break
                end
            end
        end
    -- 键位速查浮层：本面板自己的上下文（close_or_exit 已在最前面拦下 Esc 先关浮层）
    elseif action == "help" then state.help = not state.help; request_render(true)
    elseif action == "activate" then confirm_focus_activate() end
end

-- ---- 键位段：包在 do…end 里 ---------------------------------------------- --
-- 为什么：Lua 每个函数的活跃局部上限 200，而**主 chunk 也算一个函数**。本文件顶层
-- 已有 199 个 local，再动几行就会 too many local variables 直接加载失败。这一段
-- （键位解析 / 动作定义 / 输入段安装）的局部只在段内互相使用；段外要用的名字
-- （main_bindings、install_*_bindings、clear_all_context_bindings 等）都在文件头部
-- 有前置声明 → 用 do…end 收进来，块结束时这些段内局部即释放：顶层 199 → 182。
do
    local function parse_key_list(value)
        local result,seen={},{}
        for raw_key in tostring(value or ""):gmatch("[^,]+") do
            local key=raw_key:match("^%s*(.-)%s*$")
            if key~="" and not key:find("[\r\n]") and not seen[key] then
                seen[key]=true
                result[#result+1]=key
            end
        end
        return result
    end

    --   * 单字符键（含 SPACE）**忽略 Shift**：Shift+SPACE ≡ SPACE、Shift+= ≡ =、Shift+- ≡ -
    --   * 命名键（TAB/ENTER/LEFT/KP_ADD…）保留 Shift：Shift+TAB ≠ TAB
    -- 所以同一段里写 `SPACE` 和 `Shift+SPACE`，mpv 视为同一个键 → **后定义者生效、前者消失**。
    -- 冲突检测必须按这个规则比较，否则这种覆盖会静默发生（例如「播放/暂停」被从 SPACE 上顶掉，
    -- 表现成「按空格变成了移出播放范围」）。返回归一后的键名用于查重，原字符串仍照原样写进输入段。
    local NAMED_CHAR_KEYS={SPACE=true,PERIOD=true,COMMA=true,SEMICOLON=true,SLASH=true,
        BACKSLASH=true,MINUS=true,EQUAL=true,PLUS=true,GRAVE=true,QUOTE=true}
    local function normalize_key(key)
        local parts={}
        for part in tostring(key):gmatch("[^+]+") do
            local p=part:match("^%s*(.-)%s*$")
            if p~="" then parts[#parts+1]=p end
        end
        if #parts==0 then return tostring(key):upper() end
        local body=parts[#parts]
        local is_char=(#body==1) or NAMED_CHAR_KEYS[body:upper()]==true
        local mods={}
        for i=1,#parts-1 do
            local m=parts[i]:lower()
            if not (is_char and m=="shift") then mods[#mods+1]=m end
        end
        table.sort(mods)
        if not is_char then body=body:upper() end
        if #mods==0 then return body end
        return table.concat(mods,"+").."+"..body
    end

    local function build_configured_bindings(definitions,context_name)
        local result,owners={},{}
        for _,definition in ipairs(definitions) do
            local action,option_name=definition[1],definition[2]
            for _,key in ipairs(parse_key_list(opts[option_name])) do
                local normalized=normalize_key(key)
                if owners[normalized] then
                    msg.warn(string.format("quick_cut %s key conflict: %s (=%s) belongs to %s; ignoring %s",
                        context_name,key,normalized,owners[normalized],action))
                else
                    owners[normalized]=action
                    result[#result+1]={key,action,definition[3]}
                end
            end
        end
        return result
    end

    -- 第三项为 repeatable：长按会持续重复触发（频率由 mpv 的 input-ar-delay / input-ar-rate 控制）。
    -- 只给"连续调整类"动作开启；入点/出点/导出/清空这类一次性动作绝不能开，否则长按会反复触发。
    local MAIN_KEY_DEFINITIONS={
        {"pause","key_pause"},{"in","key_set_in"},{"out","key_set_out"},{"add","key_add"},
        {"undo","key_undo",true},{"redo","key_redo",true},{"left","key_nudge_back",true},{"right","key_nudge_forward",true},
        {"export","key_export"},{"merge","key_merge"},{"animated","key_export_animated"},{"clear","key_clear"},{"segments","key_segments"},
        {"split","key_split"},    {"delete","key_delete"},
        {"crop_menu","key_crop"},{"wave","key_wave"},{"panel","key_panel"},{"frame_save","key_frame_save"},
        {"range_toggle","key_range_toggle"},{"deselect","key_deselect"},
        {"segment_prev","key_segment_prev",true},{"segment_next","key_segment_next",true},
        {"close","key_close"},{"edit_time","key_edit_time"},{"seek_time","key_seek_time"},{"help","key_help"},
        {"kf_prev","key_kf_prev",true},{"kf_next","key_kf_next",true},
        {"frame_back","key_frame_back",true},{"frame_fwd","key_frame_fwd",true},
    }

    -- 导出确认面板独立键位：Tab 循环焦点、Enter 激活焦点、↑/↓ 调值、Esc 关闭面板
    local CONFIRM_KEY_DEFINITIONS={
        {"activate","key_activate"},{"focus_next","key_focus_next"},{"focus_prev","key_focus_prev"},
        -- 上下键调值开长按连发（与裁剪的移动同款），长按可快速扫过取值列表
        {"param_prev","key_param_prev",true},{"param_next","key_param_next",true},
        {"param_reset","key_param_reset"},
        {"help","key_help"},
        {"close","key_close"},
    }

    -- 裁剪的移动 / 缩放全部可长按连发；center / done / cancel 是一次性动作，不开。
    local CROP_KEY_DEFINITIONS={
        {"pause","crop_key_pause"},{"left","crop_key_left",true},{"right","crop_key_right",true},{"up","crop_key_up",true},{"down","crop_key_down",true},
        {"left-fast","crop_key_left_fast",true},{"right-fast","crop_key_right_fast",true},{"up-fast","crop_key_up_fast",true},{"down-fast","crop_key_down_fast",true},
        {"smaller","crop_key_smaller",true},{"larger","crop_key_larger",true},{"smaller-fast","crop_key_smaller_fast",true},{"larger-fast","crop_key_larger_fast",true},
        {"center","crop_key_center"},{"done","crop_key_done"},{"cancel","crop_key_cancel"},
        {"hud","crop_key_hud"},{"help","crop_key_help"},{"undo","crop_key_undo"},{"redo","crop_key_redo"},
    }

    local binding_context="none"
    local MAIN_INPUT_SECTION="quick_cut_main_editor"
    local CROP_INPUT_SECTION="quick_cut_crop_editor"
    local CONFIRM_INPUT_SECTION="quick_cut_export_confirm"
    local function disable_input_section(name)
        pcall(mp.commandv,"disable-section",name)
    end
    local function build_section_lines(bindings,script_message)
        local script=mp.get_script_name(); local lines={}
        for _,b in ipairs(bindings or {}) do
            local key,action,repeatable=b[1],b[2],b[3]
            -- repeatable 是 mpv input.conf 的原生标志：长按即按 input-ar-delay/input-ar-rate 连续触发
            local prefix = repeatable and (key .. " repeatable") or key
            table.insert(lines,string.format('%s script-message-to "%s" %s %s',prefix,script,script_message,action))
        end
        return lines
    end
    -- section 尾巴：先给"脚本没绑的键"补 ignore 影子，再追加用户的放行行。
    -- 放行行**必须在影子之后**：同一 section 内同名键后写者生效，否则用户行会被 `<key> ignore` 吃掉。
    -- 放行来源是 conf 的 extra_bindings（input.conf 原生语法、分号分行、# 开头当注释）。
    -- 背景：三个上下文都以 exclusive 启用 section，除脚本绑定外 mpv 原绑定与 input.conf 全失效，
    -- 想保留少量原生操作（最典型是滚轮调音量）只能显式加行 —— 典型值见 conf 注释里的示例。
    local function append_input_shadows(lines,bindings)
        -- 用归一化后的键名判断"已占用"：否则 Shift+<字符键> 这类绑定会被按裸键追加的
        -- `X ignore` 影子覆盖掉（同一条 mpv 归并规则，见 normalize_key）。
        local seen={}
        -- binding_keys = 脚本自己绑的键（与"影子 ignore 的键"区分开）：放行行若命中它，说明用户覆盖了脚本动作
        local binding_keys={}
        for _,b in ipairs(bindings or {}) do local n=normalize_key(b[1]); seen[n]=true; binding_keys[n]=true end
        local keys={"SPACE","BS","TAB","HOME","END","PGUP","PGDWN","INS","DEL","UP","DOWN",
            "PLAYPAUSE","PLAY","PAUSE","STOP","NEXT","PREV","VOLUME_UP","VOLUME_DOWN","MUTE",
            "KP0","KP1","KP2","KP3","KP4","KP5","KP6","KP7","KP8","KP9","KP_DEC","KP_ENTER",
            "KP_ADD","KP_SUBTRACT","KP_MULTIPLY","KP_DIVIDE","F1","F2","F3","F4","F5","F6",
            "F7","F8","F9","F10","F11","F12","`","~","!","@","#","$","%","^","&","*",
            "(",")","-","_","=","+","{","}","\\","|",";",":","'",'"',",","<",".",">","/","?"}
        for c=string.byte("a"),string.byte("z") do table.insert(keys,string.char(c)); table.insert(keys,string.char(c):upper()) end
        for n=0,9 do table.insert(keys,tostring(n)) end
        for _,key in ipairs(keys) do
            local normalized=normalize_key(key)
            if not seen[normalized] then
                table.insert(lines,key.." ignore")
                seen[normalized]=true
            end
        end
        -- 全屏是 mpv 原生高频键，脚本没提供替代品，三个 section 都以 exclusive 启用 ⇒
        -- 不显式放行就会"按 f 没反应"。放行行必须在影子之后。
        table.insert(lines,"f cycle fullscreen")
        local raw=tostring(C.opts.extra_bindings or "")
        if raw~="" then
            -- 注意：不要把结果写回循环变量本身 —— Lua 5.5 起 for 的控制变量是 const，赋值会直接编译失败
            -- （本文件其余循环都是"只读控制变量"）。
            for raw_line in (raw:gsub(";","\n").."\n"):gmatch("([^\n]*)\n") do
                local line=tostring(raw_line):gsub("^%s+",""):gsub("%s+$","")
                if line~="" and line:sub(1,1)~="#" then
                    -- 放行行排在最后 → 同一 section 内后写者生效，它会**覆盖脚本自己的同名绑定**。
                    -- 这属于"用户要的"，但静默覆盖很难排查（表现为"某个键忽然不干原来的事了"），留一条日志。
                    local key=line:match("^%S+")
                    if key and binding_keys[normalize_key(key)] then
                        msg.warn("quick_cut extra_bindings overrides a script key: "..line)
                    end
                    table.insert(lines,line)
                end
            end
        end
    end
    local function define_main_input_section()
        local lines=build_section_lines(main_bindings,"main-input")
        append_input_shadows(lines,main_bindings)
        mp.commandv("define-section",MAIN_INPUT_SECTION,table.concat(lines,"\n"),"force")
    end
    local function define_crop_input_section()
        local lines=build_section_lines(crop_bindings,"crop-input")
        append_input_shadows(lines,crop_bindings)
        mp.commandv("define-section",CROP_INPUT_SECTION,table.concat(lines,"\n"),"force")
    end
    install_main_bindings = function()
        if binding_context=="main" then return end
        disable_input_section(CROP_INPUT_SECTION)
        disable_input_section(CONFIRM_INPUT_SECTION)
        disable_input_section(MAIN_INPUT_SECTION)
        define_main_input_section()
        mp.commandv("enable-section",MAIN_INPUT_SECTION,"exclusive")
        binding_context="main"
        -- 退回主面板时同样强制重建鼠标绑定，防止历史状态残留导致点击失效
        pcall(mp.remove_key_binding, "quick_cut_click")
        pcall(mp.remove_key_binding, "quick_cut_wheel_up")
        pcall(mp.remove_key_binding, "quick_cut_wheel_down")
        mouse_bound = false
        mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
    end
    install_crop_bindings=function()
        if binding_context=="crop" then return end
        disable_input_section(MAIN_INPUT_SECTION)
        disable_input_section(CONFIRM_INPUT_SECTION)
        disable_input_section(CROP_INPUT_SECTION)
        define_crop_input_section()
        mp.commandv("enable-section",CROP_INPUT_SECTION,"exclusive")
        binding_context="crop"
        -- 进入裁剪编辑同样强制重建鼠标绑定：MBTN_LEFT 拖动裁剪框必须可用
        pcall(mp.remove_key_binding, "quick_cut_click")
        pcall(mp.remove_key_binding, "quick_cut_wheel_up")
        pcall(mp.remove_key_binding, "quick_cut_wheel_down")
        mouse_bound = false
        mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
    end
    clear_all_context_bindings = function()
        disable_input_section(MAIN_INPUT_SECTION)
        disable_input_section(CROP_INPUT_SECTION)
        disable_input_section(CONFIRM_INPUT_SECTION)
        binding_context="none"
    end

    toggle_segment_list=function()
        if input_context()~="main" then return end
        state.help=false
        state.modal=not state.modal; request_render(true)
        apply_segment_loop()
    end

    main_bindings=build_configured_bindings(MAIN_KEY_DEFINITIONS,"main")
    crop_bindings=build_configured_bindings(CROP_KEY_DEFINITIONS,"crop")
    confirm_bindings=build_configured_bindings(CONFIRM_KEY_DEFINITIONS,"confirm")

    local function define_confirm_input_section()
        local lines=build_section_lines(confirm_bindings,"confirm-input")
        append_input_shadows(lines,confirm_bindings)
        mp.commandv("define-section",CONFIRM_INPUT_SECTION,table.concat(lines,"\n"),"force")
    end
    install_confirm_bindings=function()
        if binding_context=="confirm" then return end
        disable_input_section(MAIN_INPUT_SECTION)
        disable_input_section(CROP_INPUT_SECTION)
        disable_input_section(CONFIRM_INPUT_SECTION)
        define_confirm_input_section()
        mp.commandv("enable-section",CONFIRM_INPUT_SECTION,"exclusive")
        binding_context="confirm"
    end
end

-- ============================================================================
-- 自定义参数输入（依赖 mp.input / mpv >= 0.38）
-- ============================================================================

-- 校验并归一化用户输入的自定义值。成功返回 true, value；失败返回 false, 错误说明。
-- 返回值可直接交给 apply_param_value。
local function validate_custom_value(spec, text)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if text == "" then return false, L("hint.empty_input") end

    -- 分辨率：宽x高（分隔符支持 x / X / × / *）
    if spec.id == "resolution" then
        local w, h = text:match("^(%d+)%s*[xX×*]%s*(%d+)$")
        w, h = tonumber(w), tonumber(h)
        if not (w and h) or w <= 0 or h <= 0 then return false, L("hint.resolution_format") end
        if w > 16384 or h > 16384 then return false, L("hint.resolution_too_large") end
        return true, string.format("%dx%d", w, h)
    end

    -- 帧率：小数（23.976）或分数（24000/1001）
    if spec.id == "fps" then
        local a, b = text:match("^(%d+%.?%d*)%s*/%s*(%d+%.?%d*)$")
        if a and b then
            a, b = tonumber(a), tonumber(b)
            if not (a and b) or b <= 0 then return false, L("hint.fraction_format") end
            return true, a / b
        end
        local n = tonumber(text)
        if not n or n <= 0 or n > 1000 then return false, L("hint.fps_format") end
        return true, n
    end

    -- 质量值：bitrate 模式按码率解析，crf / cq / global_quality 按 0-63 整数
    if spec.id == "quality" and opts.video_quality_mode ~= "bitrate" then
        local n = tonumber(text)
        if not n or n < 0 or n > 63 or math.floor(n) ~= n then return false, L("hint.quality_integer") end
        return true, n
    end

    -- 码率类（音频码率 / bitrate 模式的质量值）：数字 + 可选单位 k/K/M/G，可带 bps 后缀
    local num, unit = text:match("^([%d%.]+)%s*([kKMGg]?)[bB]?[pP]?[sS]?$")
    if not num then return false, L("hint.bitrate_format") end
    local n = tonumber(num)
    if not n or n <= 0 then return false, L("hint.must_be_positive") end
    return true, tostring(n) .. (unit or "")
end

-- 打开输入框让用户手动输入参数值。
-- 输入期间释放键盘与鼠标绑定，避免和 console 抢键、或点击穿透到面板按钮；
-- 关闭后（提交或 ESC 取消都会触发 closed）恢复回原来的上下文。
prompt_custom_param = function(spec)
    if not (mp_input and mp_input.get) then
        show_hint(L("hint.no_custom_input"), 3, "error")
        return
    end
    clear_all_context_bindings()
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    osd_below_input()

    local ok_get, get_err = pcall(mp_input.get, {
        prompt = L(spec.label) .. " > ",
        default = encode_param_text(spec.id),
        submit = function(text)
            local ok, val = validate_custom_value(spec, text)
            if not ok then
                show_hint(L("hint.invalid_input", L(spec.label), tostring(val)), 3, "error")
                return
            end
            apply_param_value(spec, val)
        end,
        closed = function()
            osd_restore()
            if state.in_studio then
                if state.confirm_action then
                    install_confirm_bindings()
                else
                    install_main_bindings()
                end
                apply_segment_loop()
                -- 强制重建鼠标绑定，避免输入框期间的残留状态
                mouse_bound = false
                mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
            end
            request_render(true)
        end,
    })
    -- 同步异常恢复：get 抛错时 closed 不会触发（同 size 分支的收口逻辑）
    if not ok_get then
        msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
        osd_restore()
        if state.in_studio then
            if state.confirm_action then install_confirm_bindings() else install_main_bindings() end
            mouse_bound = false
            mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
        end
        request_render(true)
    end
end

-- ============================================================================
-- 关键帧对齐：跳到上/下一个关键帧，对活跃入/出点标记或播放头生效。
-- 索引用 ffprobe（-skip_frame nokey 只解码关键帧）惰性加载并按源文件缓存；
-- 索引未就绪/不可用时退化为 mpv 的 absolute+keyframes seek（近似对齐）。
-- ============================================================================
local kf_cache = {path = nil, times = nil, loading = false, pending = {}}
local function load_keyframe_index(path, callback)
    if kf_cache.path == path and kf_cache.times then if callback then pcall(callback, true) end return true end
    if kf_cache.loading then if callback then kf_cache.pending[#kf_cache.pending + 1] = callback end return false end
    if not U.valid_local_file(path) then if callback then pcall(callback, false) end return false end
    kf_cache.loading = true
    kf_cache.path = path
    kf_cache.pending = callback and {callback} or {}
    local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,capture_stdout=true,args={
        opts.ffprobe,"-v","error","-select_streams","v:0","-skip_frame","nokey",
        "-show_entries","frame=pts_time","-of","csv=p=0",path}}, function(success, res)
        local times = {}
        if success and res and res.status == 0 and res.stdout then
            for t in res.stdout:gmatch("([%d%.]+)") do times[#times + 1] = tonumber(t) end
        else
            msg.warn("quick_cut: keyframe index unavailable (ffprobe failed); falling back to approximate keyframe seek")
        end
        kf_cache.times = times
        kf_cache.loading = false
        local pend = kf_cache.pending; kf_cache.pending = {}
        for _, cb in ipairs(pend) do pcall(cb, #times > 0) end
        msg.info(string.format("quick_cut keyframe index: %d keyframe(s)", #times))
    end)
    -- 异步启动失败时回调不会触发：必须复位状态机并放行 pending 回调，否则
    -- kf_cache.loading 永久卡 true、索引在本文件上无法重建且零日志
    if not ok_start then
        msg.warn("quick_cut: keyframe probe async start failed: " .. tostring(start_err))
        kf_cache.times = {}
        kf_cache.loading = false
        local pend = kf_cache.pending; kf_cache.pending = {}
        for _, cb in ipairs(pend) do pcall(cb, false) end
    end
    return false
end

-- direction：-1 上一个关键帧 / +1 下一个。锚点优先级：活跃入/出点标记 > 播放头。
-- 波形缓存：showwavespic 生成整条音频包络（rawvideo BGRA），Lua 逐列采样列高（0-1 归一化），
-- 供时间轴背景层绘制。异步生成、每源文件缓存一次；失败静默降级（记一次日志，本文件不再重试）。
wave_cache = {path = nil, cols = nil, loading = false}
-- 返回值即"这次能不能用上波形"：true = 已就绪/正在生成，false = 没成（此时已把 opts.waveform
-- 复位，让按钮状态与事实一致，由调用方决定提示文案）。修的是"按钮亮着却永远不出波形"这类
-- 静默死交互：任意一条早退分支都不能再无声返回。
local function load_waveform(path)
    if not opts.waveform then return false end
    if not path or path == "" or not U.valid_local_file(path) then
        msg.warn("quick_cut: waveform unavailable (no valid local file): " .. tostring(path))
        opts.waveform = false
        return false
    end
    if wave_cache.loading then return true end
    if wave_cache.path == path then
        if wave_cache.cols then return true end
        -- 该文件上次生成失败（最常见：没有音轨）：按既有约定不重试，但也不能假装开着
        opts.waveform = false
        return false
    end
    wave_cache.path, wave_cache.loading = path, true
    local W, H = 1600, 44
    local ok_start, start_err = mp.command_native_async({name="subprocess",playback_only=false,
        capture_stdout=true,capture_stderr=true,args={
        opts.ffmpeg,"-v","error","-vn","-i",path,
        "-filter_complex",string.format("aformat=channel_layouts=mono,showwavespic=s=%dx%d:colors=FFFFFF",W,H),
        "-frames:v","1","-f","rawvideo","-pix_fmt","bgra","pipe:1"}}, function(success, res)
        wave_cache.loading = false
        local cols
        if success and res and res.status == 0 and res.stdout and #res.stdout >= W * H * 4 then
            cols = {}
            local data = res.stdout
            -- showwavespic 输出透明背景 + 白色波形：逐列扫 alpha 通道取包络。
            -- 一次性 ~70K 次 byte 读取（LuaJIT 下毫秒级），在回调里同步执行。
            local max_dev = 0
            for x = 1, W do
                local lo, hi = H, 0
                for y = 0, H - 1 do
                    local a = data:byte((y * W + x - 1) * 4 + 4)
                    if a and a > 0 then
                        if y < lo then lo = y end
                        if y > hi then hi = y end
                    end
                end
                local cy = (H - 1) / 2
                local dev = (hi >= lo) and math.max(cy - lo, hi - cy) or 0
                cols[x] = dev
                if dev > max_dev then max_dev = dev end
            end
            -- 归一化：安静音频（播客/低音量录音）也充满时间轴高度
            if max_dev > 0 then
                for x = 1, W do cols[x] = cols[x] / max_dev end
            end
        else
            msg.warn("quick_cut: waveform generation failed; timeline wave disabled for this file: " ..
                tostring((res and res.stderr) or "no output"))
            -- 生成失败（最常见：源没有音轨）：把开关复位并提示，否则按钮一直亮着却看不到
            opts.waveform = false
            show_hint(L("hint.wave_failed"), 4, "error")
        end
        wave_cache.cols = cols
        request_render(true)
    end)
    -- 异步启动失败兜底（本仓库红线）：回调不会触发，复位状态并清除 path——
    -- 不保留 path 才能让同一文件下次点「波形」时重新尝试
    if not ok_start then
        msg.warn("quick_cut: waveform async start failed: " .. tostring(start_err))
        wave_cache.loading = false
        wave_cache.path = nil
        opts.waveform = false
        return false
    end
    return true
end

-- 主面板开关：时间轴波形 / 片段循环预览（会话级切换，不回写 conf）
toggle_waveform = function()
    opts.waveform = not opts.waveform
    if not opts.waveform then
        wave_cache.path, wave_cache.cols, wave_cache.loading = nil, nil, false
        request_render(true)
        show_hint(L("hint.wave_off"), 2)
        return
    end
    -- 先加载再提示：load_waveform 失败时会复位 opts.waveform，此时不能再喊"已开"
    -- （否则后一条提示会把失败提示盖掉，用户只看到按钮亮着）
    local ok = load_waveform(studio_source or mp.get_property("path"))
    request_render(true)
    show_hint(L(ok and "hint.wave_on" or "hint.wave_failed"), 2)
end
toggle_range_of_focus = function(id)
    -- 片段列表打开时也要能用（勾选格就在那里）：放行 modal 上下文，同 undo/redo
    if not (prepare_main_action() or history_context_ok()) then return end
    id = id or state.selected_segment_id
    if not id then show_hint(L("hint.select_segment_first"), 2, "error"); return end
    toggle_checked(id)
    apply_segment_loop(); request_render(true)
    show_hint(checked_count() > 0 and L("hint.range_multi", checked_count()) or L("hint.range_cleared"), 2)
end
action_deselect = function()
    if not (prepare_main_action() or history_context_ok()) then return end
    if #state.checked == 0 and not state.selected_segment_id then return end
    clear_selection(); apply_segment_loop(); request_render(true)
    show_hint(L("hint.range_cleared"), 2)
end
-- 注：原「连播」按钮已并入「选择」——勾选 ≥2 段即为连播范围，
-- 推进逻辑在 on_time（越过当前段出点则跳到范围里的下一段），无需独立入口。

-- 逐帧微调"活跃端点"（Ctrl+←/→ 且已有标记时）：数值经 Editor.clamp_handle 兜底，
-- 不会越过另一端（保持最小片段时长）。原实现随 8/30 之后的重构被删除但调用点残留，
-- 导致有标记时按 Ctrl+←/→ 会调用到 nil（safe_action 兜住 → 只提示"操作失败"）。
local function adjust_active(delta)
    local duration = mp.get_property_number("duration", 0)
    if duration <= 0 then return end
    local handle = state.active_handle == "end" and "end" or "start"
    local key = handle == "end" and "end_time" or "start_time"
    if state[key] == nil then
        -- 该端尚未标记：先把当前位置标上（与"无标记时逐帧跳转"的语义衔接）
        if handle == "start" then set_start() else set_end() end
        return
    end
    local proposed = math.max(0, math.min(duration, (state[key] or 0) + delta))
    local clamped = Editor.clamp_handle(handle, proposed, state.start_time, state.end_time, duration, min_len())
    if clamped ~= state[key] then
        remember_action()
        state[key] = clamped
        update_ranges(true); request_render(true)
    end
    show_hint(L(handle == "end" and "hint.out" or "hint.in", U.format_time(state[key])), opts.action_hint_duration)
end

-- 时间导航前先暂停：逐帧的步长（一帧）比实时播放慢，边播边挪会被播放进度"拉回"，
-- 表现为"播一段又被拽回来"。只在**播放中**暂停一次：
-- 已暂停时什么都不做 —— 不要每次按键都再下发 pause（那会反复打断/闪烁）。
function MK.pause_for_navigation()
    if mp.get_property_bool("pause") == false then mp.set_property_bool("pause", true) end
end

-- 逐帧步进（Ctrl+←/→）：无标记时逐帧移动播放位置；有标记时逐帧微调标记，并把播放头跟到该标记
local function frame_step(direction)
    if not prepare_main_action() then return end
    -- 先暂停：逐帧的步长比实时播放慢，边播边挪会被播放进度"拉回"（见 MK.pause_for_navigation）
    MK.pause_for_navigation()
    local delta = direction * get_frame_duration()
    if state.start_time == nil and state.end_time == nil then
        -- 用 seek + exact 而不是 mpv 的 frame-step：后者语义是"解除暂停→放一帧→再暂停"，
        -- 在已暂停状态下会产生 pause false→true 的抖动。
        mp.commandv("seek", tostring(delta), "relative+exact")
        return
    end
    adjust_active(delta)
    -- 播放头同步到刚被微调的那一端：不同步的话画面不动，用户看不出自己改的是哪一帧
    local key = state.active_handle == "end" and "end_time" or "start_time"
    if state[key] then mp.commandv("seek", tostring(state[key]), "absolute+exact") end
end

local function keyframe_nudge(direction)
    if not prepare_main_action() then return end
    local duration = mp.get_property_number("duration", 0)
    if duration <= 0 then return end
    local path = mp.get_property("path")
    local cur = mp.get_property_number("time-pos", 0)

    local loaded = load_keyframe_index(path, function() request_render(true) end)
    if not loaded then
        -- 索引未就绪/不可用：退化为 mpv 关键帧 seek（落在 ≤ 目标时间的关键帧）
        local seek_to = direction < 0 and cur or math.min(duration, cur + 0.3)
        mp.commandv("no-osd", "seek", string.format("%.3f", seek_to), "absolute+keyframes")
        show_hint(L("hint.kf_index_loading"), 2)
        request_render(true)
        return
    end
    local times = kf_cache.times
    local target
    if direction < 0 then
        for i = #times, 1, -1 do if times[i] < cur - 0.001 then target = times[i]; break end end
    else
        for i = 1, #times do if times[i] > cur + 0.001 then target = times[i]; break end end
    end
    if not target then show_hint(L("hint.kf_boundary"), 2); return end
    target = math.max(0, math.min(duration, target))
    -- 只移动播放头，不调整标记（方向键组合一律不直接动标记）
    mp.commandv("seek", string.format("%.3f", target), "absolute+exact")
    show_hint(L("hint.kf_jump", U.format_time(target)), 1)
    request_render(true)
end

-- 时间码解析："H:MM:SS.f" / "M:SS.f" / 秒；非法返回 nil。
local function parse_timecode(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    local hh, mm, ss = text:match("^(%d+):(%d+):(%d+%.?%d*)$")
    if hh then return tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss) end
    local mm2, ss2 = text:match("^(%d+):(%d+%.?%d*)$")
    if mm2 then return tonumber(mm2) * 60 + tonumber(ss2) end
    local sec = text:match("^(%d+%.?%d*)$")
    if sec then return tonumber(sec) end
    return nil
end

-- 重命名选中片段（片段列表页脚的「重命名」按钮）。名称用于提示与导出文件名；
-- 留空 = 清除自定义名（导出名回落到"序号 + 起止时间码"）。复用参数输入那条 mp.input 通道，
-- 输入期间释放键鼠绑定、closed 恢复上下文，避免与 console 抢键。
rename_segment=function()
    if not state.in_studio or state.crop_editing or state.confirm_action then return end
    if Export.job.running then show_hint(L("hint.cannot_edit_segment"),2,"error"); return end
    local id = state.selected_segment_id
    if not id then show_hint(L("hint.select_segment_first"),2,"error"); return end
    if not (mp_input and mp_input.get) then show_hint(L("hint.no_custom_input"),3,"error"); return end
    local _, seg = find_segment_index(id)
    if not seg then return end
    clear_all_context_bindings()
    osd_below_input()
    local ok_get, get_err = pcall(mp_input.get, {
        prompt = L("modal.rename_prompt") .. " > ",
        default = tostring(seg.label or ""),
        submit = function(text)
            -- 名称本身是"给人看的"，只在拼文件名时做安全化（见 U.safe_filename）：
            -- 这里只压掉换行/多余空白，避免列表里一行被拆成两行
            local name = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            remember_action()
            if name == "" then
                seg.label = nil
                show_hint(L("hint.renamed_cleared"), 2, "success")
            else
                seg.label = U.truncate_chars(name, 60, false)
                show_hint(L("hint.renamed", seg.label), 2, "success")
            end
            request_render(true)
        end,
        closed = function()
            osd_restore()
            if state.in_studio then
                if state.confirm_action then install_confirm_bindings() else install_main_bindings() end
                mouse_bound = false
                mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
            end
            request_render(true)
        end,
    })
    -- 同步异常恢复：get 抛错时 closed 不会触发，必须在这里收口（否则蒙版与冻结状态残留）
    if not ok_get then
        msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
        osd_restore()
        if state.in_studio then
            if state.confirm_action then install_confirm_bindings() else install_main_bindings() end
            mouse_bound = false
            mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
        end
        request_render(true)
    end
end

-- 裁剪尺寸输入（裁剪面板「尺寸…」）：与时间码输入复用同一条 mp.input 通道。
-- 支持「1136」（另一个尺寸按所选比例自动算）与「1136x1136」（自定义尺寸）两种写法；
-- x 也接受 X / × / *，允许空格。
local function parse_crop_size(text)
    local s = tostring(text or ""):gsub("%s", "")
    -- 乘号是多字节字符：必须整串替换；放进字符集会被按字节拆开，反而把内容弄坏
    s = s:gsub("×", "x"):gsub("[xX%*]", "x")
    local a, b = s:match("^(%d+)x(%d+)$")
    if a then return tonumber(a), tonumber(b) end
    -- 只给高：x720 / 720h（只给宽就是裸数字，见下）
    local only_h = s:match("^[x](%d+)$") or s:match("^(%d+)[hH]$")
    if only_h then return nil, tonumber(only_h) end
    local n = s:match("^(%d+)$")
    if n then return tonumber(n), nil end
    return nil, nil
end

open_crop_size_input=function()
    if not state.in_studio or not state.crop_editing then return end
    if Export.job.running then show_hint(L("hint.cannot_modify_crop"),2,"error"); return end
    if not (mp_input and mp_input.get) then show_hint(L("hint.no_custom_input"),3,"error"); return end
    local cur = Crop.rect()
    if not cur then show_hint(L("hint.crop_need_preset"),2,"error"); return end
    clear_all_context_bindings()
    osd_below_input()
    local function restore()
        osd_restore()
        if state.in_studio then
            if state.confirm_action then install_confirm_bindings()
            elseif state.crop_editing then install_crop_bindings()
            else install_main_bindings() end
            mouse_bound = false
            mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
        end
        request_render(true)
    end
    local ok_get, get_err = pcall(mp_input.get, {
        -- 提示语带上当前尺寸：输入框虽然已预填（default），但提示里再写一遍更直观
        prompt = L("modal.crop_size_prompt", cur.w, cur.h) .. " > ",
        default = string.format("%d*%d", cur.w, cur.h),
        submit = function(text)
            local w, h = parse_crop_size(text)
            if not w and not h then show_hint(L("hint.crop_size_bad"),4,"error"); return end
            Crop.set_size(w, h)
        end,
        closed = restore,
    })
    if not ok_get then
        msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
        restore()
    end
end

-- 直接编辑片段时间码（T 键，对选中片段生效；主界面与片段列表均可触发）。
-- 复用参数自定义输入的 mp.input 通道与绑定释放/恢复流程，保证输入期间不抢键。
local function edit_segment_times()
    if not state.in_studio or state.crop_editing or state.confirm_action then return end
    if Export.job.running then show_hint(L("hint.cannot_edit_segment"),2,"error"); return end
    if not state.selected_segment_id then show_hint(L("hint.select_segment_first"),2,"error"); return end
    if not (mp_input and mp_input.get) then show_hint(L("hint.no_custom_input"),3,"error"); return end
    local _, seg = find_segment_index(state.selected_segment_id)
    if not seg then return end
    clear_all_context_bindings()
    osd_below_input()
    local ok_get, get_err = pcall(mp_input.get, {
        prompt = L("modal.edit_time_prompt") .. " > ",
        default = string.format("%s - %s", U.format_time(seg.start_time), U.format_time(seg.end_time)),
        submit = function(text)
            local a, b = tostring(text):match("^(.+)%s*%-%s*(.+)$")
            local t1 = a and parse_timecode(a)
            local t2 = b and parse_timecode(b)
            if not (t1 and t2) then t1, t2 = parse_timecode(text), nil end
            if not (t1 and t2) or t2 <= t1 then show_hint(L("hint.timecode_invalid"), 4, "error"); return end
            local duration = mp.get_property_number("duration", 0)
            if duration > 0 then
                t1 = math.max(0, math.min(duration, t1))
                t2 = math.max(0, math.min(duration, t2))
            end
            local min = min_len()
            if t2 - t1 < min then show_hint(L("hint.min_segment_seconds", string.format("%.3f", min)), 3, "error"); return end
            remember_action()
            seg.start_time, seg.end_time = t1, t2
            notify_overlap(seg, seg.id)
            if opts.auto_sort_segments and not state.manual_order then sort_segments() end
            update_ranges(true); request_render(true)
            show_hint(L("hint.edits_saved"), 2, "success")
        end,
        closed = function()
            osd_restore()
            if state.in_studio then
                install_main_bindings()
                mouse_bound = false
                mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
            end
            request_render(true)
        end,
    })
    -- 同步异常恢复：get 抛错时 closed 不会触发（同 size 分支的收口逻辑）
    if not ok_get then
        msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
        osd_restore()
        if state.in_studio then
            install_main_bindings()
            mouse_bound = false
            mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
        end
        request_render(true)
    end
end

-- 手动输入时间码跳转（用于精确标点：跳过去后按 [ / ] 即入/出点）。
-- 输入通道与 edit_segment_times 同构：输入期间释放绑定并降层，closed 统一恢复。
local function seek_to_time()
    if not state.in_studio or state.crop_editing or state.confirm_action then return end
    if not (mp_input and mp_input.get) then show_hint(L("hint.no_custom_input"),3,"error"); return end
    local duration = mp.get_property_number("duration", 0)
    clear_all_context_bindings()
    osd_below_input()
    local function restore()
        osd_restore()
        if state.in_studio then
            install_main_bindings()
            mouse_bound = false
            mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
        end
        request_render(true)
    end
    local ok_get, get_err = pcall(mp_input.get, {
        prompt = L("modal.seek_time_prompt") .. " > ",
        default = U.format_time(mp.get_property_number("time-pos", 0) or 0),
        submit = function(text)
            local t = parse_timecode(text)
            if not t then show_hint(L("hint.timecode_invalid"), 3, "error"); return end
            if duration > 0 then t = math.max(0, math.min(duration, t)) end
            mp.commandv("seek", t, "absolute", "exact")
            show_hint(L("hint.seeked", U.format_time(t)), 2, "success")
        end,
        closed = restore,
    })
    if not ok_get then
        msg.error("quick_cut: mp.input.get failed: " .. tostring(get_err))
        restore()
    end
end

local function main_action(action)
    if not state.in_studio or state.crop_editing then return end
    if action=="pause" then toggle_playback()
    elseif action=="in" then set_start()
    elseif action=="out" then set_end()
    elseif action=="add" then add_segment()
    elseif action=="undo" then undo_action()
    elseif action=="redo" then redo_action()
    elseif action=="left" then relative_seek(-1)
    elseif action=="right" then relative_seek(1)
    elseif action=="frame_back" then frame_step(-1)
    elseif action=="frame_fwd" then frame_step(1)
    elseif action=="kf_prev" then keyframe_nudge(-1)
    elseif action=="kf_next" then keyframe_nudge(1)
    elseif action=="export" then execute_cut()
    elseif action=="merge" then execute_merge()
    elseif action=="animated" then execute_animated()
    elseif action=="clear" then clear_marks()
    elseif action=="segments" then toggle_segment_list()
    elseif action=="split" then split_at_playhead()
    elseif action=="delete" then delete_selected_segment()
    elseif action=="segment_action" then segment_action()
    elseif action=="crop_menu" then
        -- 键名沿用（conf 里的改绑继续有效），行为改为直接进入裁剪窗口
        open_crop_editor()
    elseif action=="wave" then toggle_waveform()
    elseif action=="frame_save" then Export.save_current_frame()
    elseif action=="panel" then
        -- 收起按钮面板只躲开画面遮挡，时间轴与键位保留，随时可继续标点
        state.deck_hidden = not state.deck_hidden
        show_hint(state.deck_hidden and L("hint.deck_hidden") or L("hint.deck_shown"), 1)
        request_render(true)
    elseif action=="range_toggle" then toggle_range_of_focus()
    elseif action=="deselect" then action_deselect()
    elseif action=="segment_prev" then select_segment_by_offset(-1)
    elseif action=="segment_next" then select_segment_by_offset(1)
    elseif action=="edit_time" then edit_segment_times()
    elseif action=="seek_time" then seek_to_time()
    elseif action=="help" then
        -- 键位速查浮层：主界面/片段列表共用，Esc、点击任意处或再按一次关闭
        state.help = not state.help; request_render(true)
    elseif action=="close" then close_or_exit() end
end
local function crop_action(action)
    if not state.crop_editing then return end
    if action=="pause" then toggle_playback(); return end
    if action=="undo" then undo_action(); return end
    if action=="redo" then redo_action(); return end
    if action=="left" then Crop.move(-1,0,false)
    elseif action=="right" then Crop.move(1,0,false)
    elseif action=="up" then Crop.move(0,-1,false)
    elseif action=="down" then Crop.move(0,1,false)
    elseif action=="left-fast" then Crop.move(-1,0,true)
    elseif action=="right-fast" then Crop.move(1,0,true)
    elseif action=="up-fast" then Crop.move(0,-1,true)
    elseif action=="down-fast" then Crop.move(0,1,true)
    elseif action=="smaller" then Crop.resize(-1,false)
    elseif action=="larger" then Crop.resize(1,false)
    elseif action=="smaller-fast" then Crop.resize(-1,true)
    elseif action=="larger-fast" then Crop.resize(1,true)
    elseif action=="center" then Crop.align("center")
    elseif action=="hud" then
        -- 裁剪工具条的可见性由两件事决定：用户手动收起 / 自动隐藏（拖动中或压住裁剪框）。
        -- 没有 pin 的话，"框一大而自动隐藏"就再也叫不出工具条了；见下方两态循环。
        -- 只有两个可见状态，每按一次都有变化：可见 ⇄ 已收起。
        -- 从"已收起"呼出时置 pinned（压过自动隐藏，避免按了没反应）；
        -- pinned 在"不再与裁剪框相交"时由渲染层自动解除，于是把框挪开再压回来仍会自动让位。
        if state.crop_panel_hidden then
            state.crop_panel_hidden, state.crop_panel_pinned = false, true
        else
            state.crop_panel_hidden, state.crop_panel_pinned = true, false
        end
        -- 不弹提示：工具条收起来/展开是**眼见为实**的（面板就在那儿消失/出现），
        -- 再压一条底部居中的提示卡反而挡画面。
        request_render(true)
    elseif action=="help" then
        state.help = not state.help; request_render(true)
    elseif action=="done" then Crop.exit_editor(false)
    elseif action=="cancel" then Crop.cancel_editor() end
end

local function request_confirmation(kind)
    -- 片段还在编辑（未保存）时不允许导出：否则会把旧范围导出去
    if state.editing_id then show_hint(L("hint.finish_editing_first"),3,"error"); return end
    if Export.job.running or Export.job.preparing then Export.cancel_export(); return end
    if not prepare_main_action() then return end
    -- 合并导出要把多段拼成一条流，mpv 编码模式没有 concat ⇒ 没有 ffmpeg 时整类不可用。
    -- 必须在动任何状态之前就拦住（否则 accurate_mode 已被下面那行算成"快速复制"，
    -- 拦下来之后面板没开、状态却停在一个不可用的模式上）。
    if kind == "merge" and C.ffmpeg_missing() then
        show_hint(L("hint.mpv_no_merge"), 4, "error")
        request_render(true)
        return
    end
    -- 输出方式与面板类型同步：M 进入合并面板时开启合并，E 打开时恢复逐段导出，
    -- 避免上次残留的 merge_output 让后续导出意外走合并流程
    state.merge_output = (kind == "merge")
    -- 允许无片段打开导出面板：可直接对整片转码（不剪辑直接转码）
    if not opts.export_confirmation then if kind=="merge" then Export.run_merge() else Export.run_cut() end; return end
    state.help=false
    state.modal,state.confirm_action=false,kind
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    -- 面板每次打开都从基线开始：于是"取消"与"导出完成后"都不会残留上次调过的参数
    -- （"复制"在没 ffmpeg 时的纠正并进 config 的 source_preset_values，基线自己就是
    -- 真实编码器，这里不需要再改一遍）
    reset_confirm_params()
    -- 没有"必须重编码"的参数时以快速复制打开（不会残留上一次重新编码的选择）
    state.accurate_mode = effective_accurate_mode(opts, false, (kind == "merge") and "merge" or "export")
    -- 没有 ffmpeg 时快速复制根本用不了（mpv 编码模式没有 copy 编码器）：默认直接落在
    -- 重新编码上，而不是让用户打开面板先看到一个点不动的置灰按钮。
    if C.ffmpeg_missing() then state.accurate_mode = true end
    state.confirm_focus = "confirm_go"; install_confirm_bindings()
    apply_segment_loop()
    -- 面板打开即强制重建鼠标绑定：保证 mouse_bound 与真实绑定同步，
    -- 键盘打开面板后无需移动鼠标即可点击按钮
    pcall(mp.remove_key_binding, "quick_cut_click")
    pcall(mp.remove_key_binding, "quick_cut_wheel_up")
    pcall(mp.remove_key_binding, "quick_cut_wheel_down")
    mouse_bound = false
    mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
    request_render(true)
end
confirm_execute=function()
    -- 双保险：面板已打开后用户才进入编辑（或从别的入口触发）时，仍然拦住
    if state.editing_id then show_hint(L("hint.finish_editing_first"),3,"error"); return end
    local kind=state.confirm_action; state.confirm_action=nil
    -- 导出类型与输出方式都在确认面板里选，这里只负责按选择分发
    local export_kind=state.export_kind or C.DEFAULT_EXPORT_KIND
    local merge_output=state.merge_output == true
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    state.confirm_focus = nil; install_main_bindings(); apply_segment_loop(); request_render(true)
    if kind=="export" or kind=="merge" then
        if merge_output then Export.run_merge(export_kind) else Export.run_cut(export_kind) end
    end
end
execute_cut=function() request_confirmation("export") end
-- M 键作为快捷方式：直接进入"合并为一个文件"的确认面板
-- （merge_output 由 request_confirmation 依据 kind 同步，无需在此手动设置）
execute_merge=function() request_confirmation("merge") end
-- 其他导出类型的预设入口（供快捷键或后续扩展使用）
execute_animated=function() set_export_kind("animated"); request_confirmation("export") end

local function log_startup_summary()
    local out=opts.output_directory~="" and opts.output_directory or "source-directory"
    msg.info(string.format("quick_cut v"..C.VERSION.." | ui-preset=%s | ui-scale=%s/%s | ui-module=ui.lua | theme="..ui_tokens.theme_name.." | variants="..ui_tokens.variants.panel..","..ui_tokens.variants.button..","..ui_tokens.variants.timeline..","..ui_tokens.variants.hint.." | theme-source="..tostring(ui_tokens.theme_source).." | layout=floating-uniform-text-buttons+fullwidth-timeline | input=main/crop-exclusive | crop-preview=%s | validation=%s | output=%s",
        tostring(opts.ui_preset),tostring(theme.scale),tostring(theme.scale_fs),tostring(opts.crop_preview_style),tostring(opts.merge_validation),tostring(out)))
    msg.info("quick_cut timeline seek | drag=absolute+keyframes | release=absolute+exact")
end
local function enter()
    if state.in_studio then return end
    state.in_studio = true; state.modal = false
    studio_source = mp.get_property("path")
    log_startup_summary()
    Takeover.hide()
    install_main_bindings()
    mp.observe_property("mouse-pos", "native", mouse_move); mp.observe_property("time-pos", "number", on_time)
    mp.observe_property("osd-dimensions", "native", on_osd_dimensions)
    -- 惰性探测 ffmpeg 编码器/封装器能力，完成后重渲染（新格式选项按能力显隐）
    Export.probe_capabilities(function() request_render(true) end)
    -- 后台生成时间轴音频波形（每源文件一次，就绪后重渲染）
    load_waveform(studio_source)
    request_render(true)
    mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
    update_ranges(true)
    local restored = restore_session()
    if Export.job.running and Export.job.plan and mp.get_property("path") ~= Export.job.plan.source_path then
        show_hint(L("hint.background_task", tostring(Export.job.plan.source_name)), 3)
    elseif restored > 0 then
        show_hint(L("hint.session_restored", restored), 3)
        request_render(true)
    else show_hint(L("hint.studio_opened"), 2) end
end

local function exit()
    if not state.in_studio then Takeover.restore(); return end
    save_session()
    studio_source = nil
    state.in_studio=false; state.modal=false; state.crop_editing=false; state.confirm_action=nil
    clear_checked()
    state.crop_ratio_lock=nil
    state.hud_hidden=false
    state.deck_hidden=false
    state.batch_preview=false; state.batch_index=1
    state.help=false
    state.optimize_goal=nil
    state.input_active=false
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect, state.confirm_focus = nil, 0, nil, nil
    state.hover_time=nil; reset_timeline_drag(true); hovered_id,hovered_tip=nil,nil
    if crop_drag.down then crop_drag.down=false; Crop.drag_end() end
    clear_segment_loop()
    clear_all_context_bindings()
    for _, n in ipairs({"quick_cut_click", "quick_cut_wheel_up", "quick_cut_wheel_down"}) do mp.remove_key_binding(n) end
    mouse_bound = false; mp.unobserve_property(mouse_move); mp.unobserve_property(on_time); mp.unobserve_property(on_osd_dimensions)
    if render_timer then render_timer:kill(); render_timer = nil end
    if action_hint_timer then action_hint_timer:kill(); action_hint_timer=nil end
    state.action_hint,state.action_hint_until,state.action_hint_level=nil,0,"info"
    render_pending = false
    overlay:remove()
    Takeover.restore()
    show_hint(Export.job.running and L("hint.studio_exited_bg") or L("hint.studio_exited"), 2)
end

local function toggle() if state.in_studio then exit() else enter() end end

local function shutdown()
    Export.shutdown_cleanup()
    exit()
    Takeover.restore()
    if ranges_timer then ranges_timer:kill(); ranges_timer = nil end
    last_ranges_json = nil; mp.commandv("script-message-to", "uosc", "set-timeline-ranges", "quick_cut", "[]")
end

-- ============================================================================
-- 模块装配：所有函数与绑定就绪后，注入依赖并初始化各域模块。
-- ============================================================================
deps.install_main_bindings = install_main_bindings
deps.install_crop_bindings = install_crop_bindings
deps.encode_summary = Export.encode_summary
deps.choice_label = choice_label
deps.choice_name = choice_name
deps.job = Export.job
-- 裁剪改动也要进撤销栈（crop.lua 在写 crop_* 之前回调它）
deps.remember_action = remember_action
Export.init(deps)
-- 工具条几何的真源在 ui（它负责画），这里只做一次转发：裁剪框启动尺寸要给工具条让位
deps.crop_panel_height = (type(UI.crop_panel_height) == "function") and UI.crop_panel_height or nil
    -- 桩文本（裁剪尺寸标签）的标称高度：crop.lua 的启动高度公式要减掉它。
    -- 字号真源与 ui 画标签时用的同一个 opts.menu_font_size，避免两处数字漂移。
    deps.crop_label_height = function(s) return math.floor((tonumber(opts.menu_font_size) or 11) * (tonumber(s) or 1)) end
-- ui 每帧的缩放系数（render 里写入 state.ui_scale）：crop.lua 算"启动带"必须用它，
-- 否则与 ui 的 s（theme.scale × vfit）差一个系数，框底会压住工具条 ⇒ 工具条自动隐藏。
deps.ui_scale = function() return state and state.ui_scale or nil end
Crop.init(deps)
Editor.init(deps)
U.init(deps)
Takeover.init(deps)

mp.register_script_message("enter_studio_mode", enter)
mp.register_script_message("exit_studio_mode", exit)
mp.register_script_message("toggle_studio_mode", toggle)
mp.register_script_message("cut_menu", toggle)
mp.register_script_message("cancel_export", Export.cancel_export)
mp.register_script_message("undo", undo_action)
mp.register_script_message("redo", redo_action)
mp.register_script_message("open_output_directory", open_last_output_directory)
-- 输入分发加 pcall 保护：处理函数出错只提示并记日志，绝不终止脚本
-- （脚本一旦终止，被接管的 OSC 将无法恢复）。
local function safe_action(handler)
    return function(...)
        local ok, err = pcall(handler, ...)
        if not ok then
            U.log_error("input action failed: " .. tostring(err))
            show_hint(L("hint.action_failed"), 4, "error")
            request_render(true)
        end
    end
end
mp.register_script_message("main-input", safe_action(main_action))
mp.register_script_message("crop-input", safe_action(crop_action))
mp.register_script_message("confirm-input", safe_action(confirm_action))
mp.register_script_message("restore_player_osc", Takeover.force_restore)
mp.register_script_message("quick_cut_ping", function()
    show_hint(L("hint.quick_cut_loaded", mp.get_script_name()), 3)
end)
mp.add_key_binding(nil, "cut_menu", toggle)
mp.register_event("end-file", function()
    exit()
    Takeover.restore()
    state.start_time, state.end_time, state.segments, state.segment_scroll, state.next_id = nil, nil, {}, 0, 1
    state.editing_id, state.manual_order = nil, false
    clear_checked()
    state.selected_segment_id = nil
    state.crop_ratio_lock=nil
    state.hud_hidden=false
    state.deck_hidden=false
    state.help=false
    state.optimize_goal=nil
    state.input_active=false
    state.batch_preview=false; state.batch_index=1
    kf_cache.path=nil; kf_cache.times=nil; kf_cache.loading=false; kf_cache.pending={}
    wave_cache.path=nil; wave_cache.cols=nil; wave_cache.loading=false
    Editor.history_clear(history)
    update_ranges(true)
end)
-- 启动时纠正一次容器/编码器组合：conf 与 --script-opts 直配的值**不走** UI 的联动
-- （PARAM_DEPENDENTS 只在面板改参数时执行），于是会留下 encode_container=webm + video_codec=libx264
-- 这类组合——重新编码把 h264 往 webm 里封装，必然失败。
-- 预设切换与优化目标已有同样的全量纠正（coerce_all），这里补上"启动直配"这条路径。
-- 只写日志不弹提示：面板随后显示的就是纠正后的值，用户看到的一致。
local startup_coerced = coerce_all()
if startup_coerced then
    msg.info("quick_cut startup: coerced incompatible container/codec: " .. tostring(startup_coerced))
end
-- 跟随源文件的预设（"原始参数"）里容器取自**当前**文件，所以换文件后要重算一次：
-- 否则第二个文件会沿用上一个文件的容器（源扩展名不同时就是错的）。
mp.register_event("file-loaded", function()
    -- 不能要求"已在剪辑台"：常规流程是**先播文件、再按快捷键进剪辑台**。
    -- 也不能在这里提前 return，"原始参数"的容器会停留在启动时算出的 mkv（那时还没文件），
    -- 用户看到的就是"mp4 的源却默认 mkv"。文件一加载就重算。
    local p = C.EXPORT_PRESETS[C.current_preset]
    if p and p.from_source then
        C.apply_export_preset(opts, C.current_preset)
        coerce_all()
        if state.in_studio then request_render(true) end
    end
end)

mp.register_event("shutdown", shutdown)
