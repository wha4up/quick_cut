
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

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

local active_locale = I18n.set(opts.ui_language)

opts.ui_module_dir = (_G.QUICK_CUT_BOOTSTRAP and _G.QUICK_CUT_BOOTSTRAP.module_dir) or ""

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
    if not found.ffmpeg then
        msg.info("quick_cut: ffmpeg missing - export falls back to mpv's own encoders (reduced feature set)")
    end
end
local ui=UI.new(opts)
local ui_tokens=ui:tokens_for_core()
C.apply_ui_tokens(ui_tokens)

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
    crop_editing = false, crop_panel_hidden = false, crop_panel_pinned = false,
    editing_id = nil, manual_order = false,
    crop_ratio_lock = nil,
    optimize_goal = nil,
    goal_prev_accurate = nil,
    size_target = nil,
    input_active = false,
    hud_hidden = false,
    deck_hidden = false,
    flash_id = nil,
    hover_time = nil, hover_x = nil, confirm_action = nil,
    export_kind = "video", merge_output = false,
    param_dropdown = nil, dropdown_scroll = 0, dropdown_rect = nil, confirm_focus = nil,
    action_hint = nil, action_hint_until = 0, action_hint_token = 0, action_hint_level = "info",
    batch_preview = false, batch_index = 1,
    checked = {},
    model_dirty = false,
}

local request_render, update_ranges, show_hint, render_ui, mouse_click, get_queue
local toggle_segment_list, execute_cut, execute_merge, confirm_execute, execute_animated
local remember_action, install_main_bindings
local install_crop_bindings, install_confirm_bindings
local main_bindings, crop_bindings, confirm_bindings
local clear_all_context_bindings, mouse_move
local run_button
local open_crop_size_input
local toggle_waveform
local wave_cache
local apply_segment_loop, clear_segment_loop
local focus_segment, clear_selection, toggle_range_of_focus, action_deselect, segment_action, history_context_ok, list_op, rename_segment

local function primary_key(bindings, action)
    for _, b in ipairs(bindings or {}) do
        if b[2] == action then return b[1] end
    end
    return "?"
end

local crop_is_active = Crop.crop_is_active
local effective_accurate_mode = Crop.effective_accurate_mode

local deps = {opts=opts, theme=theme, state=state, version=C.VERSION, L=L}
deps.show_hint=function(...) return show_hint(...) end
deps.request_render=function(...) return request_render(...) end
deps.get_queue=function() return get_queue() end
deps.primary_key=function(action) return primary_key(main_bindings, action) end
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
local mouse_bound = false
overlay.z = 2000
local function osd_below_input()
    state.input_active = true
    overlay.z = -1
    for _, n in ipairs({"quick_cut_click", "quick_cut_wheel_up", "quick_cut_wheel_down"}) do mp.remove_key_binding(n) end
    mouse_bound = false
    local d = mp.get_property_native("osd-dimensions")
    local w, h = (d and d.w) or 1280, (d and d.h) or 720
    local fs = math.floor(h * 1.15)
    local fscx = math.ceil(w / (fs * 0.5) * 100) + 40
    overlay.res_x, overlay.res_y = w, h
    overlay.data = string.format([[{\an7\pos(0,%d)\fs%d\fscx%d\1c&H000000&\alpha&H66&}█]],
        -math.floor(h * 0.06), fs, fscx)
    overlay:update()
end
local function osd_restore()
    state.input_active = false
    overlay.z = 2000
    overlay.data = ""
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

    local MK = {}

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

local function delete_selection()
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
    apply_segment_loop()
    update_ranges(true); request_render(true)
    show_hint(L(#ids > 1 and "hint.deleted_segments" or "hint.deleted_segment", #ids)..L("hint.undo_suffix", primary_key(main_bindings, "undo")),1,"success")
end
local function delete_selected_segment() delete_selection() end

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
focus_segment=function(id)
    clear_checked()
    state.selected_segment_id = id
end
clear_selection=function()
    clear_checked()
    state.selected_segment_id = nil
end

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
    if snapshot.crop_mode~=nil then
        opts.crop_mode,opts.crop_aspect=snapshot.crop_mode,snapshot.crop_aspect
        opts.crop_x,opts.crop_y=snapshot.crop_x,snapshot.crop_y
        opts.crop_width,opts.crop_height=snapshot.crop_width,snapshot.crop_height
        state.crop_ratio_lock=snapshot.crop_ratio_lock
    end
    history.suspended=false
    state.model_dirty = true
    apply_segment_loop()
    update_ranges(true); request_render(true)
end
-- model_dirty = "用户真的动过片段/裁剪"。退出时只在这上面才允许清档：
-- 恢复被拒、或本次只是打开看了一眼，都不算"用户清空了模型"。
remember_action=function() state.model_dirty = true
    if not history.suspended and not Export.job.running then Editor.history_push(history,model_snapshot()) end end
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

local studio_source = nil
local function session_snapshot()
    local segments = {}
    for _, seg in ipairs(state.segments) do
        segments[#segments+1] = {
            id=seg.id, label=seg.label, enabled=(seg.enabled ~= false),
            start_time=tonumber(seg.start_time), end_time=tonumber(seg.end_time),
        }
    end
    local duration = mp.get_property_number("duration", 0)
    return {
        duration = (duration and duration > 0) and duration or nil,
        next_id = state.next_id,
        accurate_mode = state.accurate_mode == true,
        manual_order = state.manual_order == true,
        segment_scroll = state.segment_scroll,
        segments = segments,
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
    if #data.segments == 0 then
        -- 只有用户真的清空过模型才允许删档：恢复被拒/未编辑都只是"没内容可存"
        if state.model_dirty then Session.clear(source) end
        return
    end
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
    local saved_duration = tonumber(data.duration)
    if saved_duration and saved_duration > 0 and duration > 0 and math.abs(duration - saved_duration) > 0.5 then
        -- 返回独立状态：调用方必须能区分"没有存档"与"有存档但被拒绝"，
        -- 否则警告被"工作室已打开"盖掉，退出时还会把存档当"用户清空了"删掉。
        show_hint(L("hint.session_duration_changed"), 4, "error")
        return "refused"
    end
    state.segments, state.next_id = {}, tonumber(data.next_id) or 1
    for _, seg in ipairs(data.segments) do
        if type(seg.start_time) == "number" and type(seg.end_time) == "number" then
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
    show_hint(L("hint.opening_dir"),1)
    mp.log("quick_cut: open output directory: " .. tostring(path))
    U.open_directory(path)
end

local function split_at_playhead()
    if not prepare_main_action() then return end
    if Export.job.running then show_hint(L("hint.cannot_split"),2,"error"); return end
    -- 与删除保持一致：编辑中的草稿还没落盘，分裂会让草稿失去归属（editing_id 被清空、
    -- 入出点还留着），下一次 Enter 就会把原始范围又叠到两个新片段上。
    if state.editing_id then show_hint(L("hint.finish_editing_first"),3,"error"); return end
    local time=mp.get_property_number("time-pos",0)
    local duration=mp.get_property_number("duration",0)
    local min=min_len()
    local index,segment,from_gap
    local candidates=Editor.find_segments_at_time(state.segments,time)
    if #candidates==1 then
        index,segment=candidates[1].index,candidates[1].segment
    elseif #candidates>1 then
        local sel=Editor.find_segment_index(state.segments,state.selected_segment_id)
        local s=sel and state.segments[sel]
        if s and time>=s.start_time and time<=s.end_time then index,segment=sel,s
        else show_hint(L("hint.multiple_overlap_at_playhead"),4,"error"); return end
    else
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
        local _,idx=Editor.insert_segment_at_time(state,segment.start_time,segment.end_time)
        index=idx
    end
    local right,second=Editor.split_segment(state,index,time)
    if not right then
        if from_gap then table.remove(state.segments,index); state.next_id=state.next_id-1; state.selected_segment_id=prev_sel end
        show_hint(second or L("hint.split_failed"),3,"error"); return
    end
    if from_gap and opts.auto_sort_segments and not state.manual_order then sort_segments() end
    state.segment_scroll=math.max(0,math.min(index,#state.segments-(tonumber(opts.max_visible_segments) or 7)))
    MK.flash("split"); update_ranges(true); request_render(true)
    local text=(from_gap and L("hint.split_from_gap") or L("hint.split_done")):format(
        U.format_time(second.start_time), U.format_time(second.end_time),
        U.format_time(right.start_time), U.format_time(right.end_time))
    show_hint(text,2,"success")
end

local resolution_index, fps_index, encode_param_text

local function active_params()
    return C.params_for_kind(state.export_kind or C.DEFAULT_EXPORT_KIND)
end

local function set_export_kind(kind)
    if not C.params_for_kind(kind) then return end
    if state.export_kind == kind then return end
    state.export_kind = kind
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    state.confirm_focus = "confirm_go"
    request_render(true)
end

local function toggle_merge_output()
    if Export.job.running then show_hint(L("hint.cannot_modify_outmode"),2,"error"); return end
    if not (state.merge_output == true) and C.ffmpeg_missing() then
        show_hint(L("hint.mpv_no_merge"),3,"error"); return
    end
    state.merge_output = not (state.merge_output == true)
    request_render(true)
end

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

local function cropped_output_size()
    if not Crop.crop_is_active(opts) then return nil end
    local r = Crop.rect()
    if not r then return nil end
    return math.floor(r.w), math.floor(r.h)
end

resolution_index = function()
    local w, h = tonumber(opts.video_width) or 0, tonumber(opts.video_height) or 0
    for i, r in ipairs(C.RESOLUTIONS) do if r.w == w and r.h == h then return i end end
    return 1
end
fps_index = function()
    local f = math.floor(tonumber(opts.output_fps) or 0)
    for i, v in ipairs(C.FPS_OPTIONS) do if v == f then return i end end
    return 1
end

encode_param_text = function(id)
    for _, spec in ipairs(active_params()) do
        if spec.id == id then
            if spec.type == "list" then
                local cur = tostring(opts[spec.field] or "")
                local lab = spec.labels and spec.labels[cur]
                if cur == "0" and (spec.field == "animated_width" or spec.field == "image_width") then
                    local cw = cropped_output_size()
                    if cw then return tostring(cw) end
                end
                return lab and L(lab) or (C.codec_text and C.codec_text(cur)) or cur
            elseif spec.type == "quality" then
                if opts.video_quality_mode == "bitrate" then
                    return (opts.video_bitrate ~= "" and opts.video_bitrate) or L("value.no_bitrate")
                end
                return tostring(opts.video_quality)
            elseif spec.type == "resolution" then
                local w, h = tonumber(opts.video_width) or 0, tonumber(opts.video_height) or 0
                if w <= 0 and h <= 0 then
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

local filter_values, spec_values, coerce_dependents

local function accurate_neutral_field(field)
    if field == nil then return false end
    if field == "smart_cut" or field == "normalize_audio" or field == "auto_deinterlace"
        or field == "auto_crop_black" or field == "remove_silence" or field == "faststart" then
        return true
    end
    if field == "scale_mode" then
        return (tonumber(opts.video_width) or 0) == 0 and (tonumber(opts.video_height) or 0) == 0
    end
    if field == "audio_bitrate" or field == "audio_codec" then
        return tostring(opts.audio_codec or "") == "copy"
    end
    if field == "pixel_format" then return tostring(opts.pixel_format or "") == "auto" end
    if field == "encode_container" then return true end
    return false
end

local function cycle_encode_param(id, delta)
    if Export.job.running then show_hint(L("hint.cannot_modify_encode"),2,"error"); return end
    for _, spec in ipairs(active_params()) do
        if spec.id == id then
            local before_text = encode_param_text(id)
            if spec.type == "list" then
                local values = filter_values(spec, spec_values(spec))
                local idx = 1
                for i, v in ipairs(values) do if tostring(opts[spec.field]) == tostring(v) then idx = i end end
                idx = ((idx - 1 + delta) % #values) + 1
                opts[spec.field] = values[idx]
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
            local coerced = spec.field and coerce_dependents(spec.field) or nil
            local after_text = encode_param_text(id)
            local switched = false
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

local function cycle_export_preset()
    if Export.job.running then show_hint(L("hint.cannot_change_preset"),2,"error"); return end
    local order = C.PRESET_ORDER
    local idx = 1
    for i, name in ipairs(order) do if name == C.current_preset then idx = i end end
    local next_name = order[idx % #order + 1]
    local label = C.apply_export_preset(opts, next_name)
    if (C.EXPORT_PRESETS[next_name] or {}).from_source then state.accurate_mode = false end
    opts.video_quality = C.clamped_number(opts.video_quality, opts.video_quality, 0, 63)
    local switched = false
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

spec_values = function(spec)
    return (spec.dyn == "preset") and C.preset_options(opts.video_codec) or spec.values
end

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

local function param_options(id)
    if id == "_preset" then
        local rows = {}
        local function header(text) rows[#rows + 1] = {header = true, label = text} end
        header(L("preset.section_goal"))
        for _, g in ipairs(C.OPTIMIZE_GOAL_ORDER) do
            local goal_key = "goal." .. g
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
                local lab = p.label or name
                if p.kind and p.kind ~= cur_kind then
                    local kkey = "confirm.kind_" .. tostring(p.kind)
                    lab = lab .. " · " .. L(kkey)
                end
                rows[#rows + 1] = {value=name, label=lab, current=(state.optimize_goal == nil and C.current_preset == name)}
            end
        end
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
                    local lab = labels and labels[sv]
                    if sv == "0" and (spec.field == "animated_width" or spec.field == "image_width") then
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
            if spec.custom and mp_input then
                out[#out + 1] = {value=C.CUSTOM_PARAM_VALUE, label=L("common.custom"), current=false}
            end
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

local prompt_custom_param

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
    if spec.field == "audio_codec" and tostring(opts.audio_codec or ""):lower() == "none" then
        opts.normalize_audio = false
        opts.remove_silence = false
    end
    local coerced = spec.field and coerce_dependents(spec.field) or nil
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    state.confirm_focus = "confirm_go"
    local after_text = encode_param_text(spec.id)
    local switched = false
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

local function set_encode_param(id, value)
    if Export.job.running then show_hint(L("hint.cannot_modify_encode"),2,"error"); return end
    for _, spec in ipairs(active_params()) do
        if spec.id == id then
            if value == C.CUSTOM_PARAM_VALUE then
                if prompt_custom_param then prompt_custom_param(spec) end
                return
            end
            apply_param_value(spec, value)
            return
        end
    end
end

local function toggle_param_dropdown(id)
    if state.param_dropdown and state.param_dropdown.id == id then
        state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
        state.confirm_focus = "confirm_go"
    else
        state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = {id=id}, 0, nil
        local dmax = math.max(1, tonumber(C.DROPDOWN_MAX_ROWS) or 10)
        local cur = 1
        for i, o in ipairs(param_options(id)) do if o.current then cur = i break end end
        state.confirm_focus = "dp_" .. id .. "_" .. math.min(cur, dmax)
    end
    request_render(true)
end

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

local function params_modified()
    local base = C.encode_baseline()
    for _, spec in ipairs(active_params()) do
        if C.param_is_modified(spec, opts, base) then return true end
    end
    return false
end

local function modified_suffix()
    if params_modified() then return " · " .. L("confirm.modified") end
    return ""
end

local function choice_label()
    if state.optimize_goal then
        local key = "goal." .. state.optimize_goal
        return L("confirm.goal", L(key))
    end
    return L("confirm.preset", C.preset_label()) .. modified_suffix()
end

local function choice_tip()
    if not state.optimize_goal and params_modified() then
        return L("confirm.choice_tip_modified", C.preset_label())
    end
    return L("confirm.choice_tip")
end

local function choice_name()
    if state.optimize_goal then
        local key = "goal." .. state.optimize_goal
        return L(key)
    end
    return C.preset_label() .. modified_suffix()
end

local function goal_label()
    local g = state.optimize_goal
    if not g then return L("goal.none") end
    local key = "goal." .. g
    return L(key)
end

local function clear_optimize_goal()
    state.optimize_goal = nil
    state.size_target = nil
    if state.goal_prev_accurate ~= nil then
        state.accurate_mode = state.goal_prev_accurate == true
        state.goal_prev_accurate = nil
    end
    C.apply_export_preset(opts, C.current_preset)
    coerce_all()
    show_hint(L("hint.goal_cleared"), 3, "info")
    request_render(true)
end

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
                    set_export_preset(saved)
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
            C.apply_export_preset(opts, "original")
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
    local goal = tostring(name or ""):match("^_goal:(%w+)$")
    if goal == "size" then
        if not (mp_input and mp_input.get) then show_hint(L("hint.no_custom_input"),3,"error"); return end
        if state.optimize_goal == "size" then clear_optimize_goal(); return end
        local pending_warn, pending_warn_target
        local submitted_size
        local ask_size
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
                state.accurate_mode = true
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
                if warn_target == nil or tonumber(warn_target) ~= n then
                    local total = 0
                    for _, q in ipairs(get_queue() or {}) do total = total + (q.end_time - q.start_time) end
                    if total <= 0 then total = tonumber((mp.get_property_number("duration", 0))) or 0 end
                    local vk = Export.size_bitrates(n, total)
                    -- 括号不能省：mp.get_property_number 失败时会返回第二个错误串，
                    -- 直接当实参传进 tonumber 就是 "bad argument #2 to 'tonumber'"
                    local bps = mp.get_property_number("video-bitrate", 0)
                    local src_bps = tonumber(bps) or 0
                    local src_size = 0
                    local p = mp.get_property("path")
                    if p and utils and utils.file_info then
                        local li = utils.file_info(p)
                        if type(li) == "table" and type(li.size) == "number" then src_size = li.size end
                    end
                    local whole_bps = (src_size > 0 and total > 0) and (src_size * 8 / total) or 0
                    local ref_bps = src_bps > 0 and src_bps or whole_bps
                    local no_bitrate = (vk == nil)
                    local oversize = (vk ~= nil) and ref_bps > 0 and (vk * 1000) > ref_bps
                    local low_floor = (vk ~= nil) and (vk < min_video_kbps())
                    local low_source = (vk ~= nil) and ref_bps > 0 and (vk * 1000) < (ref_bps * 0.25)
                    if no_bitrate or oversize or low_floor or low_source then
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
                        state.size_target = n
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
        end
        ask_size(nil)
        return
    end
    if goal then
        if goal == "none" or state.optimize_goal == goal then clear_optimize_goal(); return end
        local applied, note = C.apply_optimize_goal(opts, goal, source_profile())
        if not applied then return end
        if state.optimize_goal == nil then state.goal_prev_accurate = state.accurate_mode end
        state.optimize_goal = goal
        opts.video_quality = C.clamped_number(opts.video_quality, opts.video_quality, 0, 63)
        local coerced = coerce_all()
        local op = state.confirm_action == "merge" and "merge" or "export"
        if not effective_accurate_mode(opts, state.accurate_mode, op) then
            state.accurate_mode = true
        end
        local suffix = coerced and L("hint.format_limit", coerced) or ""
        if note then suffix = suffix .. "  " .. note end
        local goal_key = "goal." .. goal
        show_hint(L("hint.goal_applied", L(goal_key)) .. suffix, opts.action_hint_long_duration)
        request_render(true)
        return
    end
    state.optimize_goal = nil
    local label = C.apply_export_preset(opts, name)
    if (C.EXPORT_PRESETS[name] or {}).from_source then state.accurate_mode = false end
    opts.video_quality = C.clamped_number(opts.video_quality, opts.video_quality, 0, 63)
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
    if not has_marks and not crop_is_active(opts) then return end
    remember_action()
    state.start_time,state.end_time,state.segments,state.segment_scroll=nil,nil,{},0
    state.editing_id, state.manual_order = nil, false
    clear_checked()
    state.selected_segment_id = nil
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
local function relative_seek(seconds)
    if not prepare_main_action() then return end
    mp.commandv("seek", tostring(seconds), "relative+exact")
end
local function add_segment()
    if not prepare_main_action() then return end
    local n,err=normalize_draft_segment()
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
        local msg=L("hint.segment_added",U.format_time(n.start_time),U.format_time(n.end_time))
        if state.start_time==nil then msg=msg..L("hint.mark_filled_in")
        elseif state.end_time==nil then msg=msg..L("hint.mark_filled_out") end
        show_hint(msg,2,"success")
    end
    state.start_time,state.end_time=nil,nil
    state.segment_scroll=math.max(0,#state.segments-(tonumber(opts.max_visible_segments) or 7))
    -- 片段边界变了就要重建预览循环：否则预览还在循环旧范围（或已删掉的片段）
    apply_segment_loop()
    update_ranges(true); request_render(true)
end

segment_action=function()
    if state.editing_id or (checked_count() == 0 and not state.selected_segment_id) then return add_segment() end
    return delete_selection()
end

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
        param_visible=C.param_visible,
        ffmpeg_missing=C.ffmpeg_missing, missing_ffmpeg_tip=C.missing_ffmpeg_tip,
        set_accurate_mode=function(want)
            want = want and true or false
            if Export.job.running then show_hint(L("hint.cannot_modify_encode"),2,"error"); return end
            if Crop.is_active and Crop.is_active(opts) then
                show_hint(L("confirm.crop_locked_short"),3,"info"); return
            end
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
                    state.confirm_focus="cp_"..id
                    request_render(true)
                    return
                end
            end
        end,
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
        local seg=timeline_drag.seg
        if not seg then return end
        local key=timeline_drag.handle=="end" and "end_time" or "start_time"
        seg[key]=Editor.clamp_handle(timeline_drag.handle,t,seg.start_time,seg.end_time,duration,min_len())
        state.selected_segment_id=seg.id
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
local last_drag_diag
local function segment_boundary_at_x(x, duration)
    if duration <= 0 or #state.segments == 0 then return nil end
    local best, best_dist, best_selected, best_rank
    for _, seg in ipairs(state.segments) do
        local x1 = Editor.time_to_x(seg.start_time, duration, timeline_bounds)
        local x2 = Editor.time_to_x(seg.end_time, duration, timeline_bounds)
        if x1 and x2 then
            local handle, dist
            local ds, de = math.abs(x - x1), math.abs(x - x2)
            if ds <= 6 or de <= 6 then
                if ds <= de then handle, dist = "start", ds else handle, dist = "end", de end
                local sel = (seg.id == state.selected_segment_id)
                local rank = (handle == "start") and 1 or 0
                local better = (best == nil)
                    or (sel and not best_selected)
                    or (sel == best_selected and dist < best_dist)
                    or (sel == best_selected and dist == best_dist and rank > best_rank)
                if better then
                    best, best_dist, best_selected, best_rank = {seg=seg, handle=handle}, dist, sel, rank
                end
            end
        end
    end
    return best
end
-- 按钮执行器：必须定义在 mouse 事件分发之前 —— timeline_mouse_event 会直接用它，
-- 而它可能早于 mouse_click 被调用（crop 编辑态下第一次点工具栏正是这种时序）。
run_button=function(b)
    if b.fn then
        local ok, err = pcall(b.fn)
        if not ok then
            U.log_error(err)
            show_hint(L("hint.action_failed"), 4, "error")
            request_render(true)
        end
    end
end
local function timeline_mouse_event(event)
    if type(event)~="table" or not event.event then return end
    if state.input_active then return end
    local p=mp.get_property_native("mouse-pos")
    if not p then reset_timeline_drag(true); return end
    if event.event=="down" then
        if state.help then state.help=false; request_render(true); return end
        pcall(mouse_move, "mouse-pos", p)
        if state.crop_editing then
            for i=#buttons,1,-1 do
                local b=buttons[i]
                if b.layer=="main" and p.x>=b.x1 and p.x<=b.x2 and p.y>=b.y1 and p.y<=b.y2 then
                    run_button(b); return
                end
            end
        end
        if state.crop_editing then
            local ok, mode = pcall(Crop.drag_begin, p.x, p.y)
            if not ok then
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
        local edge=segment_boundary_at_x(p.x,duration)
        if state.editing_id then edge = nil end
        timeline_drag.seg=edge and edge.seg or nil
        timeline_drag.handle=edge and edge.handle or timeline_handle_at_x(p.x,duration)
        timeline_drag.kind=edge and "segment" or (timeline_drag.handle and "handle" or "scrub")
        timeline_drag.was_paused=mp.get_property_bool("pause")
        if opts.timeline_drag_pause and not timeline_drag.was_paused then mp.set_property_bool("pause",true) end
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
        -- 拖拽改了边界（segment/handle）之后同样要重建预览循环
        if was_active and (kind=="segment" or kind=="handle") then apply_segment_loop() end
        reset_timeline_drag(true)
        request_render(true)
    end
end

mouse_click=function(outside)
    if not state.in_studio then return end
    if state.help then state.help=false; request_render(true); return end
    local p = mp.get_property_native("mouse-pos"); if not p then return end
    local function in_rect(r) return r and p.x >= r.x1 and p.x <= r.x2 and p.y >= r.y1 and p.y <= r.y2 end
    if state.param_dropdown then
        for i = #buttons, 1, -1 do
            local b = buttons[i]
            if b.layer == "confirm" and b.id:sub(1,3) == "dp_" and in_rect(b) then run_button(b); return end
        end
        if not in_rect(state.dropdown_rect) then
            state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
            request_render(true); return
        end
        return
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
                local chosen=Editor.cycle_candidate(candidates,state.selected_segment_id)
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
            clear_selection()
            clear_segment_loop()
            mp.commandv("seek",clicked_time,"absolute+exact"); request_render(true)
        end
    end
    if outside and not state.crop_editing and not state.modal and not state.hud_hidden
        and (state.selected_segment_id ~= nil or #state.checked > 0) then
        clear_selection(); clear_segment_loop()
        show_hint(L("hint.range_cleared"),opts.action_hint_duration)
        request_render(true)
    end
end
local function wheel(delta)
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
    local has_sel = state.selected_segment_id ~= nil or #state.checked > 0
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
    if state.batch_preview then
        local range = range_segments()
        local pos = mp.get_property_number("time-pos", 0)
        local seg = range[state.batch_index]
        if #range < 2 then
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
    apply_segment_loop()
end

local function toggle_playback()
    mp.commandv("cycle","pause")
end

local function set_ab_prop(name, value)
    local ok, err = pcall(mp.set_property, name, value)
    if not ok then
        msg.warn(string.format("quick_cut: set %s=%s failed: %s", name, tostring(value), tostring(err)))
    end
    return ok
end

apply_segment_loop=function()
    local range = range_segments()
    if not state.in_studio or #range == 0 then
        state.batch_preview = false; state.batch_index = 1
        clear_segment_loop()
        return
    end
    if state.modal or state.crop_editing or state.confirm_action then
        state.batch_preview = false; state.batch_index = 1
        clear_segment_loop()
        return
    end
    if #range >= 2 then
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
    state.batch_preview = false; state.batch_index = 1
    local seg = range[1]
    local s, e = tonumber(seg.start_time), tonumber(seg.end_time)
    if not s or not e or e <= s then
        clear_segment_loop()
        return
    end
    set_ab_prop("ab-loop-count", "inf")
    set_ab_prop("ab-loop-a", tostring(s))
    set_ab_prop("ab-loop-b", tostring(e))
end

clear_segment_loop=function()
    set_ab_prop("ab-loop-a", "no")
    set_ab_prop("ab-loop-b", "no")
end

local function confirm_focusable()
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
local function confirm_focus_move(delta)
    if not state.confirm_action then return end
    local list = confirm_focusable()
    if #list == 0 then return end
    local idx = 1
    for i, b in ipairs(list) do if b.id == state.confirm_focus then idx = i break end end
    state.confirm_focus = list[((idx - 1 + delta) % #list) + 1].id
    request_render(true)
end
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
local function confirm_param_step(delta)
    if not state.confirm_action then return end
    if state.param_dropdown then confirm_focus_move(delta); return end
    local id = tostring(state.confirm_focus or ""):match("^cp_(.+)$")
    if not id then return end
    cycle_encode_param(id, delta)
end
local function confirm_action(action)
    if not state.in_studio or not state.confirm_action then return end
    if action == "close" then close_or_exit()
    elseif action == "focus_next" then confirm_focus_move(1)
    elseif action == "focus_prev" then confirm_focus_move(-1)
    elseif action == "param_next" then confirm_param_step(1)
    elseif action == "param_prev" then confirm_param_step(-1)
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
    elseif action == "help" then state.help = not state.help; request_render(true)
    elseif action == "activate" then confirm_focus_activate() end
end

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

    local CONFIRM_KEY_DEFINITIONS={
        {"activate","key_activate"},{"focus_next","key_focus_next"},{"focus_prev","key_focus_prev"},
        {"param_prev","key_param_prev",true},{"param_next","key_param_next",true},
        {"param_reset","key_param_reset"},
        {"help","key_help"},
        {"close","key_close"},
    }

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
            local prefix = repeatable and (key .. " repeatable") or key
            table.insert(lines,string.format('%s script-message-to "%s" %s %s',prefix,script,script_message,action))
        end
        return lines
    end
    local MPV_NATIVE_PASSTHROUGH={"f cycle fullscreen"}
    local function append_input_shadows(lines,bindings)
        -- 用归一化后的键名判断"已占用"：否则 Shift+<字符键> 这类绑定会被按裸键追加的
        -- `X ignore` 影子覆盖掉（同一条 mpv 归并规则，见 normalize_key）。
        local seen={}
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
        for _,line in ipairs(MPV_NATIVE_PASSTHROUGH) do
            local key=line:match("^%S+")
            if not (key and binding_keys[normalize_key(key)]) then
                table.insert(lines,line)
            end
        end
        local raw=tostring(C.opts.extra_bindings or "")
        if raw~="" then
            -- 注意：不要把结果写回循环变量本身 —— Lua 5.5 起 for 的控制变量是 const，赋值会直接编译失败
            -- （本文件其余循环都是"只读控制变量"）。
            for raw_line in (raw:gsub(";","\n").."\n"):gmatch("([^\n]*)\n") do
                local line=tostring(raw_line):gsub("^%s+",""):gsub("%s+$","")
                if line~="" and line:sub(1,1)~="#" then
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

local function validate_custom_value(spec, text)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if text == "" then return false, L("hint.empty_input") end

    if spec.id == "resolution" then
        local w, h = text:match("^(%d+)%s*[xX×*]%s*(%d+)$")
        w, h = tonumber(w), tonumber(h)
        if not (w and h) or w <= 0 or h <= 0 then return false, L("hint.resolution_format") end
        if w > 16384 or h > 16384 then return false, L("hint.resolution_too_large") end
        return true, string.format("%dx%d", w, h)
    end

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

    if spec.id == "quality" and opts.video_quality_mode ~= "bitrate" then
        local n = tonumber(text)
        if not n or n < 0 or n > 63 or math.floor(n) ~= n then return false, L("hint.quality_integer") end
        return true, n
    end

    local num, unit = text:match("^([%d%.]+)%s*([kKMGg]?)[bB]?[pP]?[sS]?$")
    if not num then return false, L("hint.bitrate_format") end
    local n = tonumber(num)
    if not n or n <= 0 then return false, L("hint.must_be_positive") end
    return true, tostring(n) .. (unit or "")
end

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
                mouse_bound = false
                mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
            end
            request_render(true)
        end,
    })
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
        -- 换文件后这个回调仍会触发：请求路径已经不是当前路径就直接丢弃，
        -- 否则旧文件的关键帧表会被写进新文件的缓存（跳转落到错误位置）。
        if kf_cache.path ~= path then return end
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

wave_cache = {path = nil, cols = nil, loading = false}
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
        -- 同 kf_cache：旧文件的结果不能落到新文件的缓存里
        if wave_cache.path ~= path then return end
        wave_cache.loading = false
        local cols
        if success and res and res.status == 0 and res.stdout and #res.stdout >= W * H * 4 then
            cols = {}
            local data = res.stdout
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
            if max_dev > 0 then
                for x = 1, W do cols[x] = cols[x] / max_dev end
            end
        else
            msg.warn("quick_cut: waveform generation failed; timeline wave disabled for this file: " ..
                tostring((res and res.stderr) or "no output"))
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

toggle_waveform = function()
    opts.waveform = not opts.waveform
    if not opts.waveform then
        wave_cache.path, wave_cache.cols, wave_cache.loading = nil, nil, false
        request_render(true)
        show_hint(L("hint.wave_off"), 2)
        return
    end
    local ok = load_waveform(studio_source or mp.get_property("path"))
    request_render(true)
    show_hint(L(ok and "hint.wave_on" or "hint.wave_failed"), 2)
end
toggle_range_of_focus = function(id)
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

local function adjust_active(delta)
    local duration = mp.get_property_number("duration", 0)
    if duration <= 0 then return end
    local handle = state.active_handle == "end" and "end" or "start"
    local key = handle == "end" and "end_time" or "start_time"
    if state[key] == nil then
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

function MK.pause_for_navigation()
    if mp.get_property_bool("pause") == false then mp.set_property_bool("pause", true) end
end

local function frame_step(direction)
    if not prepare_main_action() then return end
    MK.pause_for_navigation()
    local delta = direction * get_frame_duration()
    if state.start_time == nil and state.end_time == nil then
        mp.commandv("seek", tostring(delta), "relative+exact")
        return
    end
    adjust_active(delta)
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
    mp.commandv("seek", string.format("%.3f", target), "absolute+exact")
    show_hint(L("hint.kf_jump", U.format_time(target)), 1)
    request_render(true)
end

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

local function parse_crop_size(text)
    local s = tostring(text or ""):gsub("%s", "")
    -- 乘号是多字节字符：必须整串替换；放进字符集会被按字节拆开，反而把内容弄坏
    s = s:gsub("×", "x"):gsub("[xX%*]", "x")
    local a, b = s:match("^(%d+)x(%d+)$")
    if a then return tonumber(a), tonumber(b) end
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
        open_crop_editor()
    elseif action=="wave" then toggle_waveform()
    elseif action=="frame_save" then Export.save_current_frame()
    elseif action=="panel" then
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
        if state.crop_panel_hidden then
            state.crop_panel_hidden, state.crop_panel_pinned = false, true
        else
            state.crop_panel_hidden, state.crop_panel_pinned = true, false
        end
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
    if kind == "merge" and C.ffmpeg_missing() then
        show_hint(L("hint.mpv_no_merge"), 4, "error")
        request_render(true)
        return
    end
    state.merge_output = (kind == "merge")
    if not opts.export_confirmation then
        -- 无确认分支同样要带导出类型：动图快捷键走的正是这条路径（漏传就导出成整段视频）
        local ek = state.export_kind or C.DEFAULT_EXPORT_KIND
        if kind=="merge" then Export.run_merge(ek) else Export.run_cut(ek) end
        return
    end
    state.help=false
    state.modal,state.confirm_action=false,kind
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    reset_confirm_params()
    state.accurate_mode = effective_accurate_mode(opts, false, (kind == "merge") and "merge" or "export")
    if C.ffmpeg_missing() then state.accurate_mode = true end
    state.confirm_focus = "confirm_go"; install_confirm_bindings()
    apply_segment_loop()
    pcall(mp.remove_key_binding, "quick_cut_click")
    pcall(mp.remove_key_binding, "quick_cut_wheel_up")
    pcall(mp.remove_key_binding, "quick_cut_wheel_down")
    mouse_bound = false
    mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
    request_render(true)
end
confirm_execute=function()
    if state.editing_id then show_hint(L("hint.finish_editing_first"),3,"error"); return end
    local kind=state.confirm_action; state.confirm_action=nil
    local export_kind=state.export_kind or C.DEFAULT_EXPORT_KIND
    local merge_output=state.merge_output == true
    state.param_dropdown, state.dropdown_scroll, state.dropdown_rect = nil, 0, nil
    state.confirm_focus = nil; install_main_bindings(); apply_segment_loop(); request_render(true)
    if kind=="export" or kind=="merge" then
        if merge_output then Export.run_merge(export_kind) else Export.run_cut(export_kind) end
    end
end
execute_cut=function() request_confirmation("export") end
execute_merge=function() request_confirmation("merge") end
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
    state.model_dirty = false
    studio_source = mp.get_property("path")
    log_startup_summary()
    Takeover.hide()
    install_main_bindings()
    mp.observe_property("mouse-pos", "native", mouse_move); mp.observe_property("time-pos", "number", on_time)
    mp.observe_property("osd-dimensions", "native", on_osd_dimensions)
    Export.probe_capabilities(function() request_render(true) end)
    load_waveform(studio_source)
    request_render(true)
    mouse_move("mouse-pos", mp.get_property_native("mouse-pos"))
    update_ranges(true)
    local restored = restore_session()
    if Export.job.running and Export.job.plan and mp.get_property("path") ~= Export.job.plan.source_path then
        show_hint(L("hint.background_task", tostring(Export.job.plan.source_name)), 3)
    elseif restored == "refused" then
        -- 恢复被拒：restore_session 里的警告必须留给用户看见，这里不再盖掉
    elseif type(restored) == "number" and restored > 0 then
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

deps.install_main_bindings = install_main_bindings
deps.install_crop_bindings = install_crop_bindings
deps.encode_summary = Export.encode_summary
deps.choice_label = choice_label
deps.choice_name = choice_name
deps.job = Export.job
deps.remember_action = remember_action
Export.init(deps)
deps.crop_panel_height = (type(UI.crop_panel_height) == "function") and UI.crop_panel_height or nil
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
local startup_coerced = coerce_all()
if startup_coerced then
    msg.info("quick_cut startup: coerced incompatible container/codec: " .. tostring(startup_coerced))
end
-- 跟随源文件的预设（"原始参数"）里容器取自**当前**文件，所以换文件后要重算一次：
-- 否则第二个文件会沿用上一个文件的容器（源扩展名不同时就是错的）。
mp.register_event("file-loaded", function()
    local p = C.EXPORT_PRESETS[C.current_preset]
    if p and p.from_source then
        C.apply_export_preset(opts, C.current_preset)
        coerce_all()
        if state.in_studio then request_render(true) end
    end
end)

mp.register_event("shutdown", shutdown)
