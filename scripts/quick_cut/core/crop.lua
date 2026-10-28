local mp = require "mp"

local U = require "util"
local msg = require "mp.msg"

local M = {}
local deps = {}

function M.init(d)
    if d then for k, v in pairs(d) do deps[k] = v end end
end

local function opts() return deps.opts end
local function state() return deps.state end
local function show_hint(...) if deps.show_hint then return deps.show_hint(...) end end
local function request_render(...) if deps.request_render then return deps.request_render(...) end end
local function L(...) if deps.L then return deps.L(...) end end
local function sync_segment_loop() if deps.apply_segment_loop then deps.apply_segment_loop() end end
local function remember() if deps.remember_action then deps.remember_action() end end

function M.crop_is_active(settings)
    settings = settings or opts()
    local mode = tostring(settings.crop_mode or "none")
    if mode == "none" then return false end
    if mode == "aspect" then return tostring(settings.crop_aspect or "source") ~= "source" end
    return mode == "custom"
end

-- 任何"要往滤镜链里加东西"的功能都必须重编码：裁剪、自动去黑边、去隔行、变速。
-- （音量归一化只动音频，视频可以继续流复制，因此不在这里，见 export.lua 的快速复制分支）
local function speed_changed(settings)
    local s = tonumber(settings.play_speed) or 1
    return math.abs(s - 1) > 0.005
end

local function needs_video_filters(settings)
    return M.crop_is_active(settings)
        or settings.auto_deinterlace == true
        or settings.auto_crop_black == true
        or speed_changed(settings)
end

function M.effective_accurate_mode(settings, requested, operation)
    -- 去静音段会把片段切成多段：快速复制的入点只能落到关键帧上，切出来的每段都会
    -- 多带前一 GOP 的内容（重复画面），所以这条路线必须是重新编码。
    if settings.remove_silence == true then return true end
    -- 码率模式（含"限定体积"）：流复制给不出指定码率，设置会被静默忽略，必须重新编码。
    -- （UI 里改这项参数本来就会自动切重新编码，这里补上从 conf 直接设置的情况。）
    if tostring(settings.video_quality_mode or "") == "bitrate" then return true end
    return needs_video_filters(settings) or requested == true
end

local function video_source_size()
    local vp = mp.get_property_native("video-params") or {}
    local w = tonumber(vp.w or vp.dw) or 0
    local h = tonumber(vp.h or vp.dh) or 0
    return math.floor(w), math.floor(h)
end

local function even_floor(value) return U.even_floor(value) end
local function even_coordinate(value) return U.even_coordinate(value) end

local function startup_band()
    local d = mp.get_property_native("osd-dimensions") or {}
    local win_h = tonumber(d.h) or 0
    local display = M.displayed_video_rect()
    if win_h < 2 or not display or display.h < 2 then return nil end
    local s = (deps.ui_scale and deps.ui_scale()) or (win_h / 720)
    local m = math.floor((tonumber(opts().deck_margin_bottom) or 52) * s)
    local panel_h = (deps.crop_panel_height and deps.crop_panel_height(s)) or math.floor(55 * s)
    local label_h = (deps.crop_label_height and deps.crop_label_height(s)) or math.floor(11 * s)
    local gap = math.floor(14 * s)
    -- 上下界必须夹在"真正显示画面的矩形"内：top/bottom 是按窗口算的，信件箱
    -- （panscan<1 / 画幅比窗口宽）时画面上下有黑边，直接用会把裁框算到画面外。
    local top = math.max(gap + label_h + gap, display.y1)
    local bottom = math.min(win_h - m - panel_h - m, display.y2)
    local avail = bottom - top
    if avail < 2 then return nil end
    local _, source_h = video_source_size()
    if not source_h or source_h < 2 then return nil end
    local scale = source_h / display.h
    return { y = math.max(0, math.floor((top - display.y1) * scale)),
             h = math.floor(avail * scale) }
end

function M.rect_for(settings)
    settings = settings or opts()
    if settings.crop_mode == "none" or settings.crop_aspect == "source" then return nil end
    local source_w, source_h = video_source_size()
    if source_w < 2 or source_h < 2 then return nil, L("hint.crop_no_size") end
    if settings.crop_mode == "custom" then
        if settings.crop_width < 2 or settings.crop_height < 2 then return nil, L("hint.crop_invalid_size") end
        local w=even_floor(math.max(2, math.min(settings.crop_width, source_w-settings.crop_x)))
        local h=even_floor(math.max(2, math.min(settings.crop_height, source_h-settings.crop_y)))
        local x=even_coordinate(math.max(0, math.min(settings.crop_x, source_w-w)))
        local y=even_coordinate(math.max(0, math.min(settings.crop_y, source_h-h)))
        return {x=x,y=y,w=w,h=h,label=string.format("%dx%d",w,h)}
    end
    local a,b=tostring(settings.crop_aspect):match("^(%d+):(%d+)$"); a,b=tonumber(a),tonumber(b)
    if not a or not b or a<=0 or b<=0 then return nil,L("hint.crop_invalid_aspect") end
    local target,source=a/b,source_w/source_h; local w,h
    if source>target then h=even_floor(source_h); w=even_floor(h*target)
    else w=even_floor(source_w); h=even_floor(w/target) end
    local band=startup_band()
    local y
    if band then
        if h>band.h then h=even_floor(band.h); w=even_floor(h*target) end
        if w>source_w then w=even_floor(source_w); h=even_floor(w/target) end
        y=even_coordinate(band.y+math.max(0,(band.h-h)/2))
    else
        y=even_coordinate((source_h-h)/2)
    end
    -- 兜底：不论 band 怎么算，裁框都必须落在源画面内（y+h<=source_h），
    -- 否则预览框画到画面外、导出参数被 ffmpeg 静默夹到别的位置。
    if h > source_h then h = even_floor(source_h); w = even_floor(math.min(h * target, source_w)) end
    if y + h > source_h then y = even_coordinate(source_h - h) end
    return {x=even_coordinate((source_w-w)/2),y=y,w=w,h=h,label=settings.crop_aspect}
end

function M.rect() return M.rect_for(opts()) end

function M.displayed_video_rect()
    local d = mp.get_property_native("osd-dimensions") or {}
    local x1, y1 = tonumber(d.ml) or 0, tonumber(d.mt) or 0
    local x2 = (tonumber(d.w) or 0) - (tonumber(d.mr) or 0)
    local y2 = (tonumber(d.h) or 0) - (tonumber(d.mb) or 0)
    if x2 <= x1 or y2 <= y1 then return nil end
    return {x1=x1,y1=y1,x2=x2,y2=y2,w=x2-x1,h=y2-y1}
end

function M.crop_to_screen_rect(crop)
    local display = M.displayed_video_rect()
    local source_w, source_h = video_source_size()
    if not display or not crop or source_w < 2 or source_h < 2 then return nil end
    return {
        x1=display.x1+crop.x/source_w*display.w,
        y1=display.y1+crop.y/source_h*display.h,
        x2=display.x1+(crop.x+crop.w)/source_w*display.w,
        y2=display.y1+(crop.y+crop.h)/source_h*display.h,
    }
end

local exit_crop_editor, cancel_crop_editor

local function export_running()
    local job = deps.job
    return job ~= nil and job.running == true
end

local function lock_ratio()
    local lk = state().crop_ratio_lock
    if not lk then return nil end
    local a, b = tostring(lk):match("^(%d+):(%d+)$")
    a, b = tonumber(a), tonumber(b)
    if a and b and a > 0 and b > 0 then return a / b end
    return nil
end

function M.select_preset(value)
    if export_running() then show_hint(L("hint.cannot_modify_crop"), 2,"error"); return end
    local o = opts(); local st = state()
    if value=="none" then
        if M.crop_is_active(o) then remember() end
        o.crop_mode,o.crop_aspect="none","source"
        st.crop_ratio_lock=nil
        if exit_crop_editor then exit_crop_editor(true) end
        show_hint(L("hint.crop_closed"),o.action_hint_long_duration,"info")
        request_render(true)
        sync_segment_loop()
        return
    end
    if value=="free" then
        local cur=M.rect(); local sw,sh=video_source_size()
        if cur then
            remember()
            o.crop_mode,o.crop_aspect="custom","custom"
            o.crop_x,o.crop_y,o.crop_width,o.crop_height=cur.x,cur.y,cur.w,cur.h
        elseif sw>=2 and sh>=2 then
            remember()
            local band=startup_band()
            local w,h,y
            if band then
                h=even_floor(math.min(band.h, sh)); w=even_floor(h*(sw/sh))
                if w>sw then w=even_floor(sw); h=even_floor(w*sh/sw) end
                y=even_coordinate(math.min(band.y, math.max(0, sh-h)))
            else
                w,h=even_floor(sw*.9),even_floor(sh*.9)
                y=even_coordinate((sh-h)/2)
            end
            o.crop_mode,o.crop_aspect="custom","custom"
            o.crop_x,o.crop_y=even_coordinate((sw-w)/2),y
            o.crop_width,o.crop_height=w,h
        else
            show_hint(L("hint.crop_no_size"),o.action_hint_long_duration,"error"); return
        end
        st.crop_ratio_lock=nil
        st.accurate_mode=true
        show_hint(L("hint.crop_free_applied",o.crop_width,o.crop_height),o.action_hint_duration)
        if not st.crop_editing then M.enter_editor() end
        request_render(true)
        sync_segment_loop()
        return
    end
    -- 同一比例已经锁在 custom 模式上：再点一次是空操作。不早退会白记一条撤销，
    -- 而且每次重算都要过 even_floor，反复点会让裁框慢慢缩水。
    if st.crop_mode == "custom" and st.crop_ratio_lock == value then return end
    local cur=M.rect()
    remember()
    o.crop_mode,o.crop_aspect="aspect",value
    st.crop_ratio_lock=value
    st.accurate_mode=true
    local sw,sh=video_source_size()
    local a,b=tostring(value):match("^(%d+):(%d+)$"); a,b=tonumber(a),tonumber(b)
    if cur and a and b and a>0 and b>0 and sw>=2 and sh>=2 then
        local target=a/b
        local w=math.min(cur.w,cur.h*target)
        local h=w/target
        if h>cur.h then h=cur.h; w=h*target end
        w=even_floor(math.max(2,math.min(w,sw)))
        h=even_floor(math.max(2,math.min(h,sh)))
        local cx,cy=cur.x+cur.w/2,cur.y+cur.h/2
        o.crop_mode,o.crop_aspect="custom","custom"
        o.crop_x=even_coordinate(math.max(0,math.min(sw-w,cx-w/2)))
        o.crop_y=even_coordinate(math.max(0,math.min(sh-h,cy-h/2)))
        o.crop_width,o.crop_height=w,h
        show_hint(L("hint.crop_applied",value,w,h),o.action_hint_duration)
        if not st.crop_editing then M.enter_editor() end
        request_render(true)
        sync_segment_loop()
        return
    end
    local crop,err=M.rect()
    show_hint(err or L("hint.crop_applied",value,crop.w,crop.h),err and o.action_hint_long_duration or o.action_hint_duration)
    if not err then M.enter_editor() else request_render(true) end
    sync_segment_loop()
end

function M.move(dx,dy,fast)
    if export_running() then show_hint(L("hint.cannot_modify_crop"), 2,"error"); return end
    local o = opts()
    local crop, err = M.rect()
    if not crop then show_hint(L("hint.crop_cannot_move",tostring(err or L("hint.crop_not_enabled"))),3,"error"); return end
    local source_w, source_h = video_source_size()
    local step = fast and o.crop_move_step_fast or o.crop_move_step
    local new_x = even_coordinate(math.max(0,math.min(source_w-crop.w,crop.x+dx*step)))
    local new_y = even_coordinate(math.max(0,math.min(source_h-crop.h,crop.y+dy*step)))
    if new_x ~= o.crop_x or new_y ~= o.crop_y or o.crop_mode ~= "custom" or o.crop_aspect ~= "custom"
        or o.crop_width ~= crop.w or o.crop_height ~= crop.h then remember() end
    o.crop_mode, o.crop_aspect = "custom", "custom"
    o.crop_width, o.crop_height = crop.w, crop.h
    o.crop_x, o.crop_y = new_x, new_y
    state().accurate_mode = true
    show_hint(L("hint.crop_box",crop.w,crop.h,o.crop_x,o.crop_y),o.action_hint_duration)
    request_render(false)
end

local function apply_custom_crop(crop, message)
    local o = opts()
    if not crop then return false end
    remember()
    o.crop_mode, o.crop_aspect = "custom", "custom"
    o.crop_x, o.crop_y = even_coordinate(crop.x), even_coordinate(crop.y)
    o.crop_width, o.crop_height = even_floor(crop.w), even_floor(crop.h)
    state().accurate_mode = true
    show_hint(message or L("hint.crop_box",o.crop_width,o.crop_height,o.crop_x,o.crop_y),o.action_hint_duration)
    request_render(true)
    return true
end

function M.resize(direction, fast)
    if export_running() then show_hint(L("hint.cannot_modify_crop"),2,"error"); return end
    local o = opts()
    local crop, err = M.rect()
    if not crop then show_hint(L("hint.crop_cannot_resize",tostring(err or L("hint.crop_not_enabled"))),3,"error"); return end
    local source_w, source_h = video_source_size()
    local step = fast and o.crop_resize_step_fast or o.crop_resize_step
    local min_size = 16
    local ratio = lock_ratio()
    local new_w, new_h
    if ratio then
        new_w = even_floor(crop.w + direction * step)
        new_h = even_floor(new_w / ratio)
        if new_w < min_size or new_h < min_size then show_hint(L("hint.crop_min_size"),2,"error"); return end
        if new_w > source_w or new_h > source_h then
            local scale = math.min(source_w/new_w, source_h/new_h)
            new_w, new_h = even_floor(new_w*scale), even_floor(new_h*scale)
        end
    else
        new_w = even_floor(math.max(min_size, math.min(source_w, crop.w + direction * step)))
        new_h = even_floor(math.max(min_size, math.min(source_h, crop.h + direction * step)))
    end
    local cx, cy = crop.x + crop.w/2, crop.y + crop.h/2
    local x = even_coordinate(math.max(0,math.min(source_w-new_w,cx-new_w/2)))
    local y = even_coordinate(math.max(0,math.min(source_h-new_h,cy-new_h/2)))
    apply_custom_crop({x=x,y=y,w=new_w,h=new_h},L("hint.crop_resized",new_w,new_h))
end

function M.align(where)
    if export_running() then show_hint(L("hint.cannot_modify_crop"),2,"error"); return end
    local crop, err = M.rect()
    if not crop then show_hint(L("hint.crop_cannot_align",tostring(err or L("hint.crop_not_enabled"))),3,"error"); return end
    local source_w, source_h = video_source_size()
    local x, y = crop.x, crop.y
    if where=="left" then x=0 elseif where=="right" then x=source_w-crop.w
    elseif where=="top" then y=0 elseif where=="bottom" then y=source_h-crop.h
    elseif where=="hcenter" then x=(source_w-crop.w)/2
    elseif where=="vcenter" then y=(source_h-crop.h)/2
    elseif where=="center" then x=(source_w-crop.w)/2; y=(source_h-crop.h)/2 end
    apply_custom_crop({x=x,y=y,w=crop.w,h=crop.h},L("hint.crop_aligned",where))
end

local drag = {active=false, mode=nil, start_src=nil, start_crop=nil, history_saved=false}

local HIT_MARGIN = 8

local MIN_DRAG_SIZE = 16
function M.set_size(w, h)
    if export_running() then show_hint(L("hint.cannot_modify_crop"),2,"error"); return nil end
    local o = opts()
    local source_w, source_h = video_source_size()
    if source_w < 2 or source_h < 2 then show_hint(L("hint.crop_no_size"),o.action_hint_long_duration,"error"); return nil end
    local cur = M.rect()
    w, h = tonumber(w), tonumber(h)
    local derived = not (w and h)
    if derived then
        local ratio = lock_ratio()
        if not ratio and cur and cur.h > 0 then ratio = cur.w / cur.h end
        if not ratio then show_hint(L("hint.crop_size_need_both"),4,"error"); return nil end
        if w then h = w / ratio elseif h then w = h * ratio else show_hint(L("hint.crop_size_bad"),4,"error"); return nil end
    end
    w, h = even_floor(w), even_floor(h)
    if w < MIN_DRAG_SIZE or h < MIN_DRAG_SIZE then show_hint(L("hint.crop_min_size"),3,"error"); return nil end
    local scale = math.min(1, source_w / w, source_h / h)
    w, h = even_floor(w * scale), even_floor(h * scale)
    local cx, cy = source_w / 2, source_h / 2
    if cur then cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2 end
    local x = even_coordinate(math.max(0, math.min(source_w - w, cx - w / 2)))
    local y = even_coordinate(math.max(0, math.min(source_h - h, cy - h / 2)))
    if not derived then state().crop_ratio_lock = nil end
    if not apply_custom_crop({x=x,y=y,w=w,h=h}, L("hint.crop_size_applied",w,h)) then return nil end
    if not state().crop_editing then M.enter_editor() end
    sync_segment_loop()
    return w, h
end

function M.screen_to_source(px, py)
    local display = M.displayed_video_rect()
    local source_w, source_h = video_source_size()
    if not display or source_w < 2 or source_h < 2 then return nil end
    return {
        x = (px - display.x1) / display.w * source_w,
        y = (py - display.y1) / display.h * source_h,
    }
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function M.drag_hit_test(px, py)
    local crop, err = M.rect()
    if not crop then return nil, err end
    local sr = M.crop_to_screen_rect(crop)
    if not sr then return nil end
    local near_l = math.abs(px - sr.x1) <= HIT_MARGIN
    local near_r = math.abs(px - sr.x2) <= HIT_MARGIN
    local near_t = math.abs(py - sr.y1) <= HIT_MARGIN
    local near_b = math.abs(py - sr.y2) <= HIT_MARGIN
    if near_l and near_t then return "nw"
    elseif near_r and near_t then return "ne"
    elseif near_l and near_b then return "sw"
    elseif near_r and near_b then return "se"
    elseif near_l then return "w"
    elseif near_r then return "e"
    elseif near_t then return "n"
    elseif near_b then return "s"
    end
    if px >= sr.x1 and px <= sr.x2 and py >= sr.y1 and py <= sr.y2 then return "move" end
    return nil
end

function M.drag_begin(px, py)
    if not state().crop_editing then return nil end
    if export_running() then return nil end
    local mode, mode_err = M.drag_hit_test(px, py)
    if not mode then
        -- 有原因才记日志（纯"没命中"不该刷日志）；源分辨率缺失时表现为"点框没反应"，必须有痕
        if mode_err then msg.warn("quick_cut: crop drag unavailable: " .. tostring(mode_err)) end
        return nil
    end
    local crop, err = M.rect()
    if not crop then
        -- 错误不能当作"未命中"静默吞掉：源分辨率信息丢失时表现为点框没反应，无从排查
        msg.warn("quick_cut: crop drag_begin unavailable: " .. tostring(err))
        return nil
    end
    local src = M.screen_to_source(px, py)
    if not src then return nil end
    drag.active, drag.mode = true, mode
    drag.start_src = src
    drag.start_crop = {x=crop.x, y=crop.y, w=crop.w, h=crop.h}
    drag.history_saved = false
    return mode
end

function M.drag_end()
    if not drag.active then return end
    drag.active, drag.mode = false, nil
    drag.start_src, drag.start_crop, drag.history_saved = nil, nil, false
    request_render(true)
end

function M.drag_move(px, py)
    if not drag.active then return end
    local src = M.screen_to_source(px, py)
    if not src then return end
    local o = opts()
    local source_w, source_h = video_source_size()
    local c = drag.start_crop
    local dx = src.x - drag.start_src.x
    local dy = src.y - drag.start_src.y
    local x, y, w, h = c.x, c.y, c.w, c.h
    local ratio = lock_ratio()
    local mode = drag.mode
    if mode == "move" then
        x = clamp(c.x + dx, 0, math.max(0, source_w - c.w))
        y = clamp(c.y + dy, 0, math.max(0, source_h - c.h))
    elseif mode == "nw" or mode == "ne" or mode == "sw" or mode == "se" then
        local right, bottom = c.x + c.w, c.y + c.h
        local fx, fy, mx, my
        if mode == "nw" then fx, fy, mx, my = right, bottom, src.x, src.y
        elseif mode == "se" then fx, fy, mx, my = c.x, c.y, src.x, src.y
        elseif mode == "ne" then fx, fy, mx, my = c.x, bottom, src.x, src.y
        else fx, fy, mx, my = right, c.y, src.x, src.y end
        local nw = math.abs(mx - fx)
        local nh = math.abs(my - fy)
        if ratio then
            if nw / math.max(2, nh) > ratio then nh = nw / ratio else nw = nh * ratio end
            nw = clamp(nw, MIN_DRAG_SIZE, source_w)
            nh = clamp(nh, MIN_DRAG_SIZE, source_h)
            if nw / math.max(2, nh) > ratio then nh = nw / ratio else nw = nh * ratio end
            if nw > source_w or nh > source_h then
                local sc = math.min(source_w / nw, source_h / nh)
                nw, nh = nw * sc, nh * sc
            end
        else
            nw = clamp(nw, MIN_DRAG_SIZE, source_w)
            nh = clamp(nh, MIN_DRAG_SIZE, source_h)
        end
        x = (mx >= fx) and fx or (fx - nw)
        y = (my >= fy) and fy or (fy - nh)
        x = clamp(x, 0, math.max(0, source_w - nw))
        y = clamp(y, 0, math.max(0, source_h - nh))
        w, h = nw, nh
    elseif mode:find("e") or mode:find("w") then
        local nw = (mode:find("w") and (c.w - dx) or (c.w + dx))
        nw = clamp(nw, MIN_DRAG_SIZE, source_w)
        if ratio then
            local nh = nw / ratio
            if nh > source_h then nh = source_h; nw = nh * ratio end
            local cy = c.y + c.h / 2
            local y1 = clamp(cy - nh / 2, 0, math.max(0, source_h - nh))
            if mode:find("w") then x = c.x + c.w - nw else x = c.x end
            y = y1
            w, h = nw, nh
        else
            if mode:find("w") then x = clamp(c.x + c.w - nw, 0, math.max(0, source_w - nw)) else x = c.x end
            y, h = c.y, c.h
            w = nw
        end
    elseif mode:find("s") or mode:find("n") then
        local nh = (mode:find("n") and (c.h - dy) or (c.h + dy))
        nh = clamp(nh, MIN_DRAG_SIZE, source_h)
        if ratio then
            local nw = nh * ratio
            if nw > source_w then nw = source_w; nh = nw / ratio end
            local cx = c.x + c.w / 2
            local x1 = clamp(cx - nw / 2, 0, math.max(0, source_w - nw))
            if mode:find("n") then y = c.y + c.h - nh else y = c.y end
            x = x1
            w, h = nw, nh
        else
            if mode:find("n") then y = clamp(c.y + c.h - nh, 0, math.max(0, source_h - nh)) else y = c.y end
            x, w = c.x, c.w
            h = nh
        end
    else
        return
    end
    if w < MIN_DRAG_SIZE or h < MIN_DRAG_SIZE then return end
    if not drag.history_saved then remember(); drag.history_saved = true end
    o.crop_mode, o.crop_aspect = "custom", "custom"
    o.crop_x, o.crop_y = even_coordinate(x), even_coordinate(y)
    o.crop_width, o.crop_height = even_floor(w), even_floor(h)
    state().accurate_mode = true
    request_render(false)
end

function M.enter_editor()
    if export_running() then show_hint(L("hint.cannot_enter_crop_editor"),2,"error"); return end
    if not M.crop_is_active(opts()) then show_hint(L("hint.crop_need_preset"),2,"error"); return end
    local st = state()
    st.modal,st.confirm_action=false,nil
    st.crop_editing=true; st.accurate_mode=true
    -- 每次进入裁剪都从"自动"开始：否则上次手动收起过，这次进来工具条会一直是收起的
    st.crop_panel_hidden, st.crop_panel_pinned = false, false
    st.hud_hidden=true
    st.crop_panel_hidden=false
    if st.in_studio and deps.install_crop_bindings then deps.install_crop_bindings() end
    request_render(true)
    sync_segment_loop()
end

exit_crop_editor=function(silent)
    local st = state()
    if not st.crop_editing then return end
    st.crop_editing=false
    st.hud_hidden=false
    if st.in_studio and deps.install_main_bindings then deps.install_main_bindings() end
    request_render(true)
    sync_segment_loop()
    if not silent then show_hint(L("hint.crop_editor_done"),opts().action_hint_long_duration,"success") end
end
M.exit_editor = function(silent) exit_crop_editor(silent) end

cancel_crop_editor=function()
    local o = opts(); local st = state()
    if M.crop_is_active(o) then remember() end
    o.crop_mode,o.crop_aspect="none","source"
    o.crop_x,o.crop_y,o.crop_width,o.crop_height=0,0,0,0
    st.crop_ratio_lock=nil
    st.crop_editing=false
    st.hud_hidden=false
    if st.in_studio and deps.install_main_bindings then deps.install_main_bindings() end
    request_render(true)
    sync_segment_loop()
    show_hint(L("hint.crop_cancelled"),o.action_hint_long_duration,"info")
end
M.cancel_editor = function() cancel_crop_editor() end

return M
