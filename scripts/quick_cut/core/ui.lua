local mp=require "mp"
local msg=require "mp.msg"
local ICONS=require "icons"
local UI={}

local DEFAULT_TOKENS={
    theme_name="graphite",
    color_panel="141416", color_text="FFFFFF", color_text_inverse="0B0B0C",
    color_primary="0A84FF", color_warning="FFD60A",
    color_selection="",
    color_success="30D158", color_danger="FF453A", color_timeline="141416",
    color_segment="3B8FF0", color_segment_disabled="3A3A3C", color_playhead="FFFFFF",
    color_pending="FFB547",
    color_segment_divider="",
    color_group_divider="FFFFFF",
    color_button_fill="FFFFFF",
    color_icon="FFFFFF",
    alpha_icon_label=.70,
    alpha_group_bg=0,
    alpha_button_idle_deck=0,
    layout_icon_ratio=0.52,
    label_bold=0,
    alpha_panel=.70, alpha_button_idle=.14, alpha_button_hover=.16, alpha_button_active=.88,
    button_disabled_style="strike",
    layout_button_disabled_strike=2,
    alpha_button_disabled=.42,
    alpha_timeline=.5, alpha_segment=.7, alpha_segment_disabled=.25,
    alpha_segment_selected=.92,
    alpha_segment_divider=1,
    alpha_pending=.35,
    alpha_tooltip=.90, alpha_menu=.88, alpha_curtain=.62,
    alpha_shadow=.40, alpha_secondary_text=.60, alpha_group_divider=.20,
    shadow_blur=22, color_panel_highlight="FFFFFF", alpha_panel_highlight=.08,
    alpha_card_outline=.16,
    radius_button=8, radius_panel=14, radius_timeline=10, radius_tooltip=10, radius_menu=12,
    button_height=36, button_width=52, status_button_width=94,
    panel_padding_x=14, panel_padding_y=8, button_gap=6, button_group_gap=14,
    button_timeline_gap=6, timeline_height=24, timeline_inset=10,
    deck_margin_x=18, deck_margin_bottom=8, deck_corner_radius=14, deck_border_alpha=0.08,
    playhead_width=3, playhead_diamond_size=18, selected_border=3,
    timeline_ruler=0,
    timeline_boundaries=1,
    layout_timeline_collapsed_margin_x=0, layout_timeline_collapsed_margin_bottom=0,
    layout_timeline_collapsed_h_ratio=.25,
    font_button=12, font_tooltip=12, font_menu=13, font_menu_title=15,
    -- 历史遗留键（**写了不生效**，别再新增）：
    --   font_timeline / font_hint → 时间轴时间文本用 layout_timeline_time_fs，操作提示条用 action_hint_font_size
    --   radius_tooltip            → tooltip 圆角当前跟随 opts.tooltip_radius（本令牌尚未接线）
    font_timeline=13, font_hint=19, shadow_offset=7,
    font_icon=16, icon_font="Segoe MDL2 Assets",
    dialog_padding=10,
    dialog_title_gap=8,
    dialog_section_gap=6,
    dialog_row_height=26,
    dialog_row_gap=4,
    dialog_button_height=22,
    dialog_button_gap=10,
    dialog_note_gap=4,
    dialog_text_line=16,
    dialog_column_gap=12,
    dialog_button_margin=5,
    dialog_bottom_pad=8,
    dialog_cell_height=32,
    dialog_cell_gap=4,

    layout_confirm_width=700,
    layout_modal_width=680,
    layout_confirm_label_w=64,
    layout_confirm_preset_w=152,
    layout_narrow_floor=480,
    layout_viewport_min_fit=1,
    layout_panel_icon=0,
    layout_confirm_cancel_w=72,
    layout_confirm_go_w=88,
    layout_confirm_cols=4,
    layout_grid_min_cell_w=104,
    layout_modal_close_w=58,
    layout_modal_ops_w=330,
    layout_modal_up_w=34,
    layout_modal_down_w=34,
    layout_modal_edit_w=48,
    layout_modal_toggle_w=54,
    layout_modal_del_w=58,
    layout_group_bg_pad=8,
    layout_group_bg_offset=4,
    layout_group_bg_inset=5,
    layout_hover_time_fs=10,
    layout_hover_time_pad=14,
    layout_hover_time_h=24,
    layout_hover_time_radius=4,
    layout_hover_time_gap=28,
    layout_tooltip_pad_ratio=2/3,
    layout_tooltip_height_ratio=1.7,
    layout_tooltip_edge=8,
    layout_job_pad=12,
    layout_job_progress_h=5,
    layout_job_fs=11,
    layout_job_detail_fs=9,
    layout_hint_pad_x_ratio=.70,
    layout_hint_pad_y_ratio=.40,
    layout_hint_pad_x=0, layout_hint_pad_y=0,
    layout_hint_line_ratio=1.18,
    layout_hint_row_ratio=1.12,
    layout_hint_icon_ratio=.95,
    layout_hint_font_ratio=1.05,
    layout_hint_zone_gap=12,
    layout_hint_max_ratio=.40,
    layout_hint_min_w=180,
    layout_hint_min_h=34,
    layout_hint_chip_min_h=24,
    layout_card_edge=16,
    min_viewport_w=1280,
    min_viewport_h=720,
    layout_hint_max_edge=32,
    layout_hint_bar_w=3,
    layout_hint_bar_inset=0,
    layout_hint_bar_gap=0,
    alpha_hint=0, alpha_job_card=0, alpha_card_separator=.08,
    hint_compact=1, hint_icon=1, job_card_max_width=320,
    job_card_width=210, job_card_height=56,
    card_match_panel=1, card_alpha_floor=.86,
    layout_card_shadow_ratio=.5,
    layout_card_row_gap=6,
    layout_dropdown_w=170,
    layout_dropdown_x=150,
    layout_dropdown_h=34,
    layout_crop_hint_fs=11,
    layout_confirm_fs=11,
    layout_confirm_note_fs=10,
    layout_modal_empty_fs=13,
    layout_modal_footer_fs=11,
    layout_modal_row_fs=10,
    layout_timeline_label_fs=10,
    layout_timeline_time_fs=10,
    layout_timeline_time_pad=8,
    layout_crop_handle=11,
    layout_crop_edge=7,
    layout_crop_corner=42,
    layout_crop_label_gap=14,
    layout_crop_label_off=10,
    layout_button_min_w=22,
    icon_font="Quickcut_icons",
    layout_compact_pad=6,
    layout_contrast_border=2,
    layout_button_hover_grow=3,
    layout_selected_border=3,
    layout_segment_inset_y=0,
    layout_segment_divider_w=1,
    layout_row_extra=2,
    layout_note_fs=10,
    layout_dropdown_edge=8,
    layout_dropdown_min_y=4,
    layout_scroll_more_fs=11,
    layout_tooltip_min_y=8,
    layout_group_divider_w=1,
    layout_group_divider_pad=8,
}

local DEFAULT_VARIANTS={panel="floating",button="icon_stack",timeline="solid",playhead="dot",tooltip="filled",hint="card",job="card",menu="filled",dialog="filled",list="cards"}

local HELP_ACTIONS_MAIN = {
    pause="help.pause", ["in"]="help.in", out="help.out", add="help.add",
    undo="help.undo", redo="help.redo", left="help.nudge", right="help.nudge",
    export="help.export", merge="help.merge", animated="help.export_animated",
    clear="help.clear", segments="help.segments", split="help.split", delete="help.delete",
    crop_menu="help.crop_open", wave="help.wave", panel="help.panel", frame_save="help.frame_save",
    range_toggle="help.range_toggle", deselect="help.deselect",
    segment_prev="help.segment_prev", segment_next="help.segment_next",
    close="help.close", edit_time="help.edit_time", seek_time="help.seek_time",
    help="help.help", kf_prev="help.kf", kf_next="help.kf",
    frame_back="help.frame", frame_fwd="help.frame",
}
local HELP_ACTIONS_CROP = {
    pause="help.pause", left="help.crop_move", right="help.crop_move", up="help.crop_move", down="help.crop_move",
    smaller="help.crop_smaller", larger="help.crop_larger", center="help.crop_center",
    done="help.crop_done", cancel="help.crop_cancel", hud="help.crop_hud",
    help="help.help", undo="help.undo", redo="help.redo",
}
local HELP_ACTIONS_CONFIRM = {
param_reset="help.param_reset",
    activate="help.confirm_activate", focus_next="help.focus_next", focus_prev="help.focus_prev",
    param_prev="help.param_prev", param_next="help.param_next",
    help="help.help", close="help.close",
}

local function copy(t) local o={}; for k,v in pairs(t or {}) do o[k]=v end; return o end
local function merge(dst,src) for k,v in pairs(src or {}) do dst[k]=v end; return dst end
local function clamp(v,fallback,lo,hi) v=tonumber(v); if not v then return fallback end; return math.max(lo,math.min(hi,v)) end
local function char_len(s)
    local n=0
    for _ in tostring(s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n=n+1 end
    return n
end
local function text_est_width(v, fs)
    local n=0
    for ch in tostring(v or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n=n+(#ch==1 and .55 or 1) end
    return n*fs
end
local function valid_color(v) return type(v)=="string" and v:gsub("^#",""):match("^%x%x%x%x%x%x$")~=nil end
local function color(v,fallback) if v==nil or v=="" then return fallback end; if valid_color(v) then return v:gsub("^#",""):upper() end; msg.warn("quick_cut UI invalid color token: "..tostring(v)); return fallback end
-- 长文本/路径类文本一律经 ctx.truncate_chars 截断（实现唯一放在 util.lua）：
-- 中文路径按字节切会落在多字节序列中间，libass 渲染出乱码，勿用 #s / sub 自行截断。
local CONFIG_TOKENS={
    ui_color_panel="color_panel",
    ui_icon_font="icon_font",
    ui_color_text="color_text",
    ui_color_text_inverse="color_text_inverse",
    ui_color_primary="color_primary",
    ui_color_selection="color_selection",
    ui_color_warning="color_warning",
    ui_color_success="color_success",
    ui_color_danger="color_danger",
    ui_color_timeline="color_timeline",
    ui_color_segment="color_segment",
    ui_color_segment_disabled="color_segment_disabled",
    ui_color_playhead="color_playhead",
    ui_alpha_panel="alpha_panel",
    ui_alpha_button_idle="alpha_button_idle",
    ui_alpha_button_hover="alpha_button_hover",
    ui_alpha_button_active="alpha_button_active",
    ui_alpha_button_disabled="alpha_button_disabled",
    ui_button_disabled_style="button_disabled_style",
    ui_layout_button_disabled_strike="layout_button_disabled_strike",
    ui_alpha_timeline="alpha_timeline",
    ui_radius_button="radius_button",
    ui_radius_panel="radius_panel",
    ui_radius_timeline="radius_timeline",
    ui_button_width="button_width",
    ui_button_height="button_height", ui_font_button="font_button", ui_layout_icon_ratio="layout_icon_ratio",
    ui_layout_panel_icon="layout_panel_icon",
    ui_layout_compact_pad="layout_compact_pad",
    ui_layout_viewport_min_fit="layout_viewport_min_fit",
    ui_layout_narrow_floor="layout_narrow_floor",
    ui_status_button_width="status_button_width",
    ui_panel_padding_x="panel_padding_x",
    ui_panel_padding_y="panel_padding_y",
    ui_button_timeline_gap="button_timeline_gap",
    ui_timeline_inset="timeline_inset",
    ui_playhead_diamond_size="playhead_diamond_size",
    ui_color_segment_divider="color_segment_divider",
    ui_color_pending="color_pending",
    ui_alpha_segment="alpha_segment",
    ui_alpha_segment_divider="alpha_segment_divider",
    ui_alpha_pending="alpha_pending",
    ui_layout_segment_divider_w="layout_segment_divider_w",
    ui_layout_segment_inset_y="layout_segment_inset_y",
    ui_color_panel_highlight="color_panel_highlight",
    ui_alpha_panel_highlight="alpha_panel_highlight",
    ui_alpha_card_outline="alpha_card_outline",
    ui_timeline_ruler="timeline_ruler",
    ui_timeline_boundaries="timeline_boundaries",
    ui_layout_card_edge="layout_card_edge",
    ui_layout_selected_border="layout_selected_border",
    ui_radius_tooltip="radius_tooltip",
    ui_alpha_hint="alpha_hint", ui_alpha_job_card="alpha_job_card",
    ui_card_match_panel="card_match_panel", ui_card_alpha_floor="card_alpha_floor",
    ui_hint_compact="hint_compact", ui_hint_icon="hint_icon",
    ui_job_card_max_width="job_card_max_width",
    ui_alpha_group_bg="alpha_group_bg", ui_alpha_group_divider="alpha_group_divider",
    ui_layout_card_shadow_ratio="layout_card_shadow_ratio",
    ui_layout_card_row_gap="layout_card_row_gap",
    ui_layout_hint_font_ratio="layout_hint_font_ratio",
    ui_layout_hint_zone_gap="layout_hint_zone_gap",
    ui_layout_hint_max_ratio="layout_hint_max_ratio",
    ui_layout_hint_row_ratio="layout_hint_row_ratio",
    ui_layout_hint_icon_ratio="layout_hint_icon_ratio",
    ui_layout_hint_pad_x="layout_hint_pad_x", ui_layout_hint_pad_y="layout_hint_pad_y",
    ui_layout_timeline_collapsed_margin_x="layout_timeline_collapsed_margin_x",
    ui_layout_timeline_collapsed_margin_bottom="layout_timeline_collapsed_margin_bottom",
    ui_layout_confirm_width="layout_confirm_width",
    ui_layout_confirm_cols="layout_confirm_cols",
    ui_layout_grid_min_cell_w="layout_grid_min_cell_w",
    ui_dialog_cell_height="dialog_cell_height",
    ui_dialog_cell_gap="dialog_cell_gap",
    ui_dialog_column_gap="dialog_column_gap",
}
local LIMITS={
    alpha_panel={0,1},alpha_button_idle={0,1},alpha_button_hover={0,1},alpha_button_active={0,1},alpha_button_disabled={0,1},layout_button_disabled_strike={1,6},alpha_timeline={0,1},alpha_segment={0,1},alpha_segment_disabled={0,1},alpha_segment_selected={0,1},alpha_tooltip={0,1},alpha_menu={0,1},alpha_curtain={0,1},alpha_shadow={0,.6},alpha_secondary_text={0,1},shadow_blur={0,40},alpha_panel_highlight={0,.4},alpha_group_divider={0,1},alpha_icon_label={0,1},alpha_group_bg={0,1},alpha_button_idle_deck={0,1},layout_icon_ratio={.2,.8},label_bold={0,1},timeline_ruler={0,1},timeline_boundaries={0,1},alpha_hint={0,1},alpha_job_card={0,1},alpha_card_separator={0,1},hint_compact={0,1},hint_icon={0,1},job_card_max_width={180,480},layout_hint_chip_min_h={16,60},layout_hint_max_ratio={.15,.9},layout_hint_row_ratio={1,1.8},layout_hint_icon_ratio={.6,1.6},layout_hint_font_ratio={.8,2},card_match_panel={0,1},layout_hint_zone_gap={0,60},card_alpha_floor={0,1},layout_card_shadow_ratio={0,1},layout_card_row_gap={0,24},layout_timeline_collapsed_margin_x={0,60},layout_timeline_collapsed_margin_bottom={0,60},layout_timeline_collapsed_h_ratio={.08,1},layout_hint_pad_x={0,80},layout_hint_pad_y={0,80},alpha_segment_divider={0,1},alpha_pending={0,1},alpha_card_outline={0,.6},layout_segment_inset_y={0,6},layout_segment_divider_w={0,6},
    radius_button={0,30},radius_panel={0,40},radius_timeline={0,30},radius_tooltip={0,30},radius_menu={0,40},
    button_height={28,72},button_width={36,180},status_button_width={48,220},panel_padding_x={4,50},panel_padding_y={4,40},button_gap={1,24},button_timeline_gap={0,40},timeline_height={16,80},timeline_inset={0,40},playhead_width={1,8},playhead_diamond_size={6,30},selected_border={0,8},font_button={8,24},font_tooltip={8,28},font_menu={8,24},font_menu_title={9,30},font_timeline={8,22},font_hint={8,32},font_icon={8,32},shadow_offset={0,16},
    dialog_padding={8,40},dialog_title_gap={4,24},dialog_section_gap={4,32},dialog_row_height={24,40},dialog_row_gap={4,16},dialog_button_height={20,48},dialog_button_gap={4,24},dialog_note_gap={4,20},dialog_text_line={12,28},dialog_column_gap={4,60},dialog_button_margin={4,20},dialog_bottom_pad={8,40},layout_group_divider_w={0,4},layout_group_divider_pad={0,24},
    dialog_cell_height={22,60},dialog_cell_gap={0,20},layout_grid_min_cell_w={80,240},layout_confirm_cols={2,6},layout_confirm_width={320,1200},
}
local COLOR_KEYS={"color_panel","color_text","color_text_inverse","color_primary","color_selection","color_warning","color_success","color_danger","color_timeline","color_segment","color_segment_disabled","color_segment_divider","color_playhead","color_pending","color_panel_highlight","color_group_divider","color_button_fill","color_icon"}
function UI.build_tokens(config)
    config = config or {}

    local tokens = copy(DEFAULT_TOKENS)
    tokens.variants = copy(DEFAULT_VARIANTS)
    tokens.icons = ICONS
    tokens.theme_name = "builtin"

    for option, token in pairs(CONFIG_TOKENS) do
        local value = config[option]
        if value ~= nil and value ~= "" and value ~= "auto" then
            tokens[token] = value
        end
    end

    for _, key in ipairs(COLOR_KEYS) do
        tokens[key] = color(tokens[key], DEFAULT_TOKENS[key])
    end

    for key, range in pairs(LIMITS) do
        local before = tokens[key]
        tokens[key] = clamp(before, DEFAULT_TOKENS[key], range[1], range[2])
        -- 越界被夹取时留日志：否则 conf 写了超限值只会"改了没反应"，无从排查
        if type(before)=="number" and before ~= tokens[key] then
            msg.warn("quick_cut UI token clamped: "..key.."="..tostring(before).." -> "..tostring(tokens[key]))
        end
    end

    return tokens
end

local function ass_color(v) v=tostring(v or "FFFFFF"):gsub("^#",""); return (v:sub(5,6)..v:sub(3,4)..v:sub(1,2)):upper() end
local function accent_hex(v, lift, sat)
    local s=tostring(v or ""):gsub("^#","")
    if not s:match("^%x%x%x%x%x%x$") then return v end
    local r,g,b=tonumber(s:sub(1,2),16),tonumber(s:sub(3,4),16),tonumber(s:sub(5,6),16)
    r=r+(255-r)*lift; g=g+(255-g)*lift; b=b+(255-b)*lift
    local y=.299*r+.587*g+.114*b
    r=y+(r-y)*sat; g=y+(g-y)*sat; b=y+(b-y)*sat
    local function c(x) return math.max(0,math.min(255,math.floor(x+.5))) end
    return string.format("%02X%02X%02X", c(r), c(g), c(b))
end
local function alpha_tag(a) local n=math.floor((1-math.max(0,math.min(1,a or 1)))*255+.5); return string.format("\\1a&H%02X&\\2a&H%02X&\\3a&H%02X&\\4a&H%02X&",n,n,n,n) end
local function esc(v) return tostring(v or ""):gsub("\\","\\\\"):gsub("{","\\{"):gsub("}","\\}"):gsub("\n","\\N") end
local function round_rect(x,y,w,h,r) x=math.floor(x); y=math.floor(y); w=math.floor(w); h=math.floor(h); r=math.max(0,math.min(r,math.floor(w/2),math.floor(h/2))); return string.format("m %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",x+r,y,x+w-r,y,x+w,y,x+w,y,x+w,y+r,x+w,y+h-r,x+w,y+h,x+w,y+h,x+w-r,y+h,x+r,y+h,x,y+h,x,y+h,x,y+h-r,x,y+r,x,y,x,y,x+r,y) end
function UI.new(config)
    config = config or {}
    local self={tokens=UI.build_tokens(config),ass=nil,font=nil,font_bold=true,text_border=1.2,
        bounds={buttons={},button_panel={x1=0,y1=0,x2=0,y2=0},timeline={x1=0,y1=0,x2=0,y2=0}}}
    return setmetatable(self,{__index=UI})
end
function UI:begin(ass,font,font_bold,text_border) self.ass=ass; self.font=font; self.font_bold=font_bold~=false; self.text_border=text_border or 1.2; self.bounds.buttons={} end
function UI:rect(x,y,w,h,color_value,alpha,radius,blur)
    local b=(blur and blur>0) and string.format("\\blur%d",blur) or ""
    table.insert(self.ass,string.format("{\\an7\\pos(0,0)\\bord0\\shad0%s\\1c&H%s&%s\\p1}%s{\\p0}",b,ass_color(color_value),alpha_tag(alpha),round_rect(x,y,w,h,radius or 0)))
end
function UI:text(x,y,size,color_value,value,align,border,alpha,font,bold)
    local b = (bold==nil) and (self.font_bold and 1 or 0) or (bold and 1 or 0)
    local tags=string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\b%d\\shad0\\1c&H%s&",align or 5,math.floor(x or 0),math.floor(y or 0),font or self.font,math.floor(size or 0),b,ass_color(color_value))
    if border==0 then tags=tags.."\\bord0" else tags=tags..string.format("\\bord%.1f\\3c&H%s&",border or self.text_border,ass_color(self.tokens.color_panel)) end
    if alpha then tags=tags..alpha_tag(alpha) end
    local body=esc(value)
    table.insert(self.ass,tags.."}"..body)
end
function UI:shadow(x,y,w,h,radius,scale) local t=self.tokens; local off=math.floor(t.shadow_offset*(scale or 1)); if off>0 then self:rect(x,y+off,w,h,t.color_panel,t.alpha_shadow,radius,t.shadow_blur or 0) end end
function UI:line(x1,y1,x2,y2,color_value,alpha,w)
    local dx,dy=x2-x1,y2-y1
    local len=math.sqrt(dx*dx+dy*dy)
    if len<.001 then return end
    local nx,ny=-dy/len*(w/2),dx/len*(w/2)
    local pts=string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f l %.1f %.1f",
        x1+nx,y1+ny,x2+nx,y2+ny,x2-nx,y2-ny,x1-nx,y1-ny)
    table.insert(self.ass,string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&%s\\p1}%s{\\p0}",
        ass_color(color_value),alpha_tag(alpha),pts))
end
function UI:button(args)
    local t=self.tokens; local v=t.variants.button; local r=math.floor(t.radius_button*args.scale)
    local label = args.label
    if args.disabled then
        args = {id=args.id,x=args.x,y=args.y,w=args.w,h=args.h,label=args.label,accent=args.accent,
                tip=args.tip,fn=nil,active=false,hover=false,layer=args.layer,scale=args.scale,
                icon=args.icon,icon_size=args.icon_size,idle=args.idle,disabled=true,
                disable_alpha=(t.alpha_button_disabled or .38)}
    end
    local da = args.disabled and args.disable_alpha or nil
    local d_cx,d_cy=args.x+args.w/2,args.y+args.h/2
    local d_fs=math.floor(t.font_button*args.scale)
    if v=="underline" then
        if args.hover then self:rect(args.x,args.y,args.w,args.h,t.color_text,t.alpha_button_hover,r) end
        if args.active then self:rect(args.x+args.w*.18,args.y+args.h-3,args.w*.64,3,args.accent,1,0) end
        self:text(args.x+args.w/2,args.y+args.h/2,math.floor(t.font_button*args.scale),args.active and args.accent or t.color_text,label,5,0,da,nil)
    elseif v=="contrast_box" then
        if not da then
            self:rect(args.x,args.y,args.w,args.h,args.active and args.accent or t.color_panel,args.active and 1 or .98,0)
            local b=math.max(2,math.floor(t.layout_contrast_border*args.scale)); local e=args.hover and args.accent or t.color_text
            self:rect(args.x,args.y,args.w,b,e,1,0); self:rect(args.x,args.y+args.h-b,args.w,b,e,1,0); self:rect(args.x,args.y,b,args.h,e,1,0); self:rect(args.x+args.w-b,args.y,b,args.h,e,1,0)
        end
        self:text(args.x+args.w/2,args.y+args.h/2,math.floor(t.font_button*args.scale),args.active and t.color_text_inverse or t.color_text,label,5,0,da,nil)
    elseif v=="icon_stack" then
        local fc=(t.color_button_fill~="" and t.color_button_fill) or args.accent
        local idle_alpha=args.idle or t.alpha_button_idle
        local fill=args.active and fc or (args.hover and fc or t.color_text); local a=args.active and t.alpha_button_active or (args.hover and t.alpha_button_hover or idle_alpha)
        if not da and args.hover and not args.active and t.alpha_button_hover>=.30 then
            local g=math.max(1,math.floor(t.layout_button_hover_grow*args.scale)); self:rect(args.x-g,args.y-g,args.w+g*2,args.h+g*2,args.accent,math.min(.32,a*.7),r+g)
        end
        if not da then self:rect(args.x,args.y,args.w,args.h,fill,a,r) end
        local fg=args.active and t.color_text_inverse or t.color_text
        local cx=args.x+args.w/2
        local icon_fs=math.min(math.floor(t.font_icon*args.scale),math.floor(args.h*.46))
        local label_fs=math.min(math.floor(t.font_button*args.scale),math.floor(args.h*.34))
        local icon_fg=(not args.active and t.color_icon~="" and t.color_icon) or fg
        local label_alpha=(t.alpha_icon_label<1) and t.alpha_icon_label or nil
        if da then
            label_alpha=da
        end
        local label_bold=(t.label_bold==1)
        local icon_box=args.icon_size and math.max(1,math.floor(args.icon_size))
            or math.floor(args.h*t.layout_icon_ratio)
        if args.icon and args.icon~="" and icon_box>=9 and label_fs>=8 then
            self:text(cx,label == "" and (args.y+args.h*.5) or (args.y+args.h*.33),
                icon_fs,icon_fg,args.icon,5,0,da,t.icon_font,label_bold)
            self:text(cx,args.y+args.h*.78,label_fs,fg,label,5,0,label_alpha,nil,label_bold)
            d_cy,d_fs=args.y+args.h*.78,label_fs
        else
            self:text(cx,args.y+args.h/2,math.floor(t.font_button*args.scale),fg,label,5,0,label_alpha)
        end
    else
        local fc=(t.color_button_fill~="" and t.color_button_fill) or args.accent
        local idle_alpha=args.idle or t.alpha_button_idle
        local fill=args.active and fc or (args.hover and fc or t.color_text); local a=args.active and t.alpha_button_active or (args.hover and t.alpha_button_hover or idle_alpha)
        if not da and args.hover and not args.active and t.alpha_button_hover>=.30 then
            local g=math.max(1,math.floor(t.layout_button_hover_grow*args.scale)); self:rect(args.x-g,args.y-g,args.w+g*2,args.h+g*2,args.accent,math.min(.32,a*.7),r+g)
        end
        if not da then self:rect(args.x,args.y,args.w,args.h,fill,a,r) end
        self:text(args.x+args.w/2,args.y+args.h/2,math.floor(t.font_button*args.scale),args.active and t.color_text_inverse or t.color_text,label,5,0,da,nil,t.label_bold==1)
    end
    if args.disabled then
        local style=t.button_disabled_style or "strike"
        if label=="" then style="slash" end
        if style~="dim" then
            local sa=math.min(1,(da or .42)*1.15)
            local lw=math.max(1,math.floor((t.layout_button_disabled_strike or 2)*args.scale))
            if style=="strike" or style=="strike_slash" then
                local hw=math.max(4,text_est_width(label,d_fs)/2+2)
                self:line(d_cx-hw,d_cy,d_cx+hw,d_cy,t.color_text,sa,lw)
            end
            if style=="slash" or style=="strike_slash" then
                local inx=math.max(2,math.floor(args.w*.14)); local iny=math.max(1,math.floor(args.h*.16))
                self:line(args.x+inx,args.y+args.h-iny,args.x+args.w-inx,args.y+iny,t.color_text,sa,lw)
            end
        end
    end
    local hit={id=args.id,x1=args.x,y1=args.y,x2=args.x+args.w,y2=args.y+args.h,cx=args.x+args.w/2,tip=args.tip,fn=args.fn,layer=args.layer or "main"}; table.insert(self.bounds.buttons,hit); return hit
end
function UI:panel(x,y,w,h,scale)
    local t=self.tokens; local r=math.floor(t.radius_panel*scale)
    self:shadow(x,y,w,h,r,scale)
    self:rect(x,y,w,h,t.color_panel,t.alpha_panel,r)
    if t.alpha_panel_highlight and t.alpha_panel_highlight>0 and h>=10 then
        local e=math.max(1,math.floor(1.3*scale)); local inset=math.max(2,math.floor(r*.5))
        local hw=w-inset*2
        if hw>=2 then self:rect(x+inset,y+math.max(1,math.floor(scale*.6)),hw,e,t.color_panel_highlight,t.alpha_panel_highlight,math.max(1,math.floor(e*2))) end
    end
end
function UI:timeline_track(x,y,w,h,scale) local t=self.tokens; self:rect(x,y,w,h,t.color_timeline,t.alpha_timeline,math.floor(t.radius_timeline*scale)); self.bounds.timeline={x1=x,y1=y,x2=x+w,y2=y+h} end
function UI:menu_panel(x,y,w,h,alpha,radius,scale)
    local t=self.tokens; local v=t.variants.menu
        self:shadow(x,y,w,h,math.floor(t.radius_menu*scale),scale)
        self:rect(x,y,w,h,t.color_panel,alpha,math.floor(t.radius_menu*scale))
end
function UI:card(x,y,w,h,alpha,radius,scale)
    local t=self.tokens; local r=math.floor(radius or 0); local sc=scale or 1
    local sr=tonumber(t.layout_card_shadow_ratio) or .5
    local off=math.floor((t.shadow_offset or 0)*sc*sr)
    if off>0 then self:rect(x,y+off,w,h,t.color_panel,(t.alpha_shadow or 0)*sr,r,math.floor((t.shadow_blur or 0)*sr)) end
    self:rect(x,y,w,h,t.color_panel,alpha,r)
    local e=math.max(1,math.floor(1.3*sc))
    if (t.alpha_panel_highlight or 0)>0 and h>=10 then
        local inset=math.max(2,math.floor(r*.5)); local hw=w-inset*2
        if hw>=2 then self:rect(x+inset,y+math.max(1,math.floor(sc*.6)),hw,e,t.color_panel_highlight,t.alpha_panel_highlight,math.max(1,math.floor(e*2))) end
    else
        local ba=tonumber(t.alpha_card_outline) or .16
        if ba>0 and w>4 and h>4 then
            local bc=t.color_panel_highlight or t.color_text
            self:rect(x,y,w,e,bc,ba,0); self:rect(x,y+h-e,w,e,bc,ba,0)
            self:rect(x,y,e,h,bc,ba,0); self:rect(x+w-e,y,e,h,bc,ba,0)
        end
    end
end
function UI:hint_metrics(p)
    local t=self.tokens; local sc=p.scale
    local fs=math.max(1,math.floor(p.opts.action_hint_font_size*sc))
    local match_panel=(t.card_match_panel==1)
    local deck_r=tonumber(p.opts.deck_corner_radius) or 14
    local alpha=tonumber(p.alpha) or 0
    if alpha<=0 then
        local fallback=math.max(.90,tonumber(p.theme.opacity and p.theme.opacity.tooltip) or .90)
        alpha=match_panel and math.max(tonumber(p.theme.deck_alpha) or 0,tonumber(t.card_alpha_floor) or .86) or fallback
    end
    local radius=tonumber(p.radius) or (match_panel and deck_r or p.theme.tooltip_radius)
    local fs_cap=math.floor(p.opts.button_font_size*t.layout_hint_font_ratio*sc)
    if fs_cap>0 and fs>fs_cap then
        fs=fs_cap
        if not self._hint_font_capped then
            self._hint_font_capped=true
            msg.warn("quick_cut hint font capped: action_hint_font_size="..tostring(p.opts.action_hint_font_size)..
                " -> "..tostring(math.floor(fs_cap/sc)).." (theme button font x layout_hint_font_ratio="..
                tostring(t.layout_hint_font_ratio).."); raise layout_hint_font_ratio in the theme to keep it larger")
        end
    end
    local compact=(t.hint_compact==1) and (#p.lines==1)
    local pad_x=math.floor((tonumber(t.layout_hint_pad_x) or 0)>0 and t.layout_hint_pad_x*sc
        or math.max(10,p.opts.action_hint_font_size*t.layout_hint_pad_x_ratio)*sc)
    local pad_y=math.floor((tonumber(t.layout_hint_pad_y) or 0)>0 and t.layout_hint_pad_y*sc
        or math.max(6,p.opts.action_hint_font_size*t.layout_hint_pad_y_ratio)*sc)
    if compact then pad_x=math.floor(pad_x*.75); pad_y=math.floor(pad_y*.65) end
    local title_fs=fs; local body_fs=math.max(1,math.floor(fs*.85))
    local line_h=math.floor(title_fs*t.layout_hint_line_ratio)
    local body_h=math.floor(body_fs*t.layout_hint_row_ratio)
    local line_gap=math.floor(p.opts.action_hint_line_gap*sc)
    local icon_size=math.max(10,math.floor(fs*t.layout_hint_icon_ratio)); local icon_gap=math.floor(6*sc)
    local use_icon=(t.hint_icon==1) and (type(p.icon)=="function" or (type(p.icon)=="string" and p.icon~=""))
    local extra=use_icon and (icon_size+icon_gap) or 0
    local edge=math.floor(t.layout_hint_max_edge*sc)
    local reserved=p.reserve_job and math.floor(t.job_card_max_width*sc) or 0
    local zone_gap=reserved>0 and math.floor(t.layout_hint_zone_gap*sc) or 0
    local hard=math.min(p.sw-edge*2-reserved-zone_gap,math.floor(p.opts.action_hint_max_width*sc))
    local max_w=math.max(math.floor(p.sw*t.layout_hint_max_ratio),hard)
    local min_w=math.floor(t.layout_hint_min_w*sc)*(compact and .6 or 1)
    local avail_text=math.max(24,max_w-pad_x*2-extra)
    local lines={}
    for i,line in ipairs(p.lines) do
        local lfs=(i==1) and title_fs or body_fs
        local out=line
        if p.tw(line,lfs)>avail_text then
            local from_end=(line:match("[\\/]")~=nil or line:match("^%a:")~=nil) and "middle" or false
            local n=math.max(4,math.floor(char_len(line)*avail_text/math.max(1,p.tw(line,lfs))))
            local guard=0
            out=p.trunc(line,n,from_end)
            while n>4 and guard<8 and p.tw(out,lfs)>avail_text do n=n-1; guard=guard+1; out=p.trunc(line,n,from_end) end
        end
        lines[i]=out
    end
    local widest=0
    for i,line in ipairs(lines) do widest=math.max(widest,p.tw(line,(i==1) and title_fs or body_fs)) end
    local content_h=(#lines==1) and line_h or (line_h+body_h*(#lines-1)+line_gap*(#lines-1))
    local h=math.max(math.floor((compact and t.layout_hint_chip_min_h or t.layout_hint_min_h)*sc),pad_y*2+content_h)
    return {lines=lines,w=math.max(math.floor(min_w),math.min(max_w,widest+pad_x*2+extra)),h=h,
        pad_x=pad_x,pad_y=pad_y,title_fs=title_fs,body_fs=body_fs,line_h=line_h,body_h=body_h,line_gap=line_gap,
        icon_size=icon_size,icon_gap=icon_gap,use_icon=use_icon,compact=compact,
        color=p.color,theme=p.theme,scale=sc,alpha=alpha,radius=radius,
        icon_font=t.icon_font,secondary=p.secondary,mono=MONO_FONT,icon=p.icon}
end

function UI:hint_card(x,y,m)
    local theme=m.theme; local sc=m.scale
    local r=math.floor(m.radius*sc)
    self:card(x,y,m.w,m.h,m.alpha,r,sc)
    if m.use_icon then
        local ix=x+m.pad_x
        local iy=m.compact and (y+math.floor((m.h-m.icon_size)/2)) or (y+m.pad_y+math.floor((m.line_h-m.icon_size)/2))
        if type(m.icon)=="function" then
            local draw=m.icon(ix,iy,m.icon_size)
            table.insert(self.ass,string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&%s\\p1}%s{\\p0}",ass_color(m.color),alpha_tag(nil),draw))
        else
            self:text(ix+m.icon_size/2,iy+m.icon_size/2,m.icon_size,m.color,m.icon,5,0,nil,m.icon_font)
        end
    else
        local t=self.tokens
        local inset=math.floor(t.layout_hint_bar_inset*sc); local bw=math.max(1,math.floor(t.layout_hint_bar_w*sc))
        local gap=math.floor(t.layout_hint_bar_gap*sc)
        self:rect(x+inset,y+inset,bw,math.max(1,m.h-inset*2-gap*2),m.color,1,math.floor(bw/2))
    end
    local tx=x+m.pad_x+(m.use_icon and (m.icon_size+m.icon_gap) or 0)
    local ty=y+m.pad_y+m.line_h/2
    for i,line in ipairs(m.lines) do
        local is_title=(i==1)
        local fs=is_title and m.title_fs or m.body_fs
        local font=(not is_title and line:match("^%d+:%d+")) and m.mono or nil
        local col=m.use_icon and theme.fg or m.color
        local al=is_title and 1 or m.secondary
        self:text(tx,ty,fs,col,line,4,0,al,font,is_title and not m.compact or false)
        if is_title then ty=ty+m.line_h/2+m.line_gap+m.body_h/2
        else ty=ty+m.body_h+m.line_gap end
    end
end

local function hold_job_card_width(self, slot, job, want, lo, hi)
    local key=type(job)=="table" and job.started_at or nil
    self.card_w=self.card_w or {}
    local rec=self.card_w[slot]
    if not rec or rec.key~=key then rec={key=key,w=0}; self.card_w[slot]=rec end
    if rec.w<want then rec.w=want end
    return math.max(lo,math.min(hi,rec.w))
end

function UI:job_card_running(p)
    local t=self.tokens; local theme=p.theme; local sc=p.scale
    local tfs=math.floor(t.layout_job_fs*sc); local dfs=math.floor(t.layout_job_detail_fs*sc)
    local pad=math.floor(t.layout_job_pad*sc)
    local vpad=math.floor(t.layout_card_row_gap*sc); local gap=vpad
    local title_lh=math.floor(tfs*1.4); local foot_lh=math.floor(dfs*1.5)
    local ph=math.max(4,math.floor(t.layout_job_progress_h*sc)); local sep_h=math.max(1,math.floor(sc))
    local min_w=math.floor(p.opts.job_card_width*sc); local max_w=math.max(min_w,math.floor(t.job_card_max_width*sc))
    local match_panel=(t.card_match_panel==1)
    local deck_r=tonumber(p.opts.deck_corner_radius) or 14
    local surface_a=(t.alpha_job_card and t.alpha_job_card>0) and t.alpha_job_card
        or (match_panel and math.max(tonumber(theme.deck_alpha) or 0,tonumber(t.card_alpha_floor) or .86) or theme.opacity.menu)
    local surface_r=math.floor((match_panel and deck_r or theme.menu_radius)*sc)
    if p.compact then
        local line_h=math.floor(tfs*1.4)
        local pct_w=math.max(p.tw(p.status,tfs),p.tw("100%",tfs))
        local cw2=math.min(max_w,pad*2+p.tw(p.title,tfs)+gap+pct_w)
        cw2=hold_job_card_width(self,"compact",p.job,cw2,0,max_w)
        local ch2=vpad*2+line_h
        local cx2=p.sw-cw2-math.floor(t.layout_card_edge*sc); local cy2=math.floor(t.layout_card_edge*sc)
        self:card(cx2,cy2,cw2,ch2,surface_a,surface_r,sc)
        self:text(cx2+pad,cy2+ch2/2,tfs,theme.bgt,p.title,4,0)
        self:text(cx2+cw2-pad,cy2+ch2/2,tfs,theme.success,p.status,6,0)
        return
    end
    local RIGHT_SLOT_CHARS=17
    local right_w=math.max(p.tw(p.right,dfs),p.tw(string.rep("8",RIGHT_SLOT_CHARS),dfs))
    local need=math.max(p.tw(p.title,tfs)+gap+p.tw(p.status,tfs),p.tw(p.detail,dfs)+gap+right_w)
    local cw=math.max(min_w,math.min(max_w,need+pad*2))
    cw=hold_job_card_width(self,"full",p.job,cw,min_w,max_w)
    local content_h=vpad*2+title_lh+gap+sep_h+gap+ph+gap+foot_lh
    local ch=math.max(math.floor(p.opts.job_card_height*sc),content_h)
    local cx=p.sw-cw-math.floor(t.layout_card_edge*sc); local cy=math.floor(t.layout_card_edge*sc)
    -- 令牌声明的最小高大于内容时，余量上下平分：否则三段会被顶到上面、底部留一条空带
    local y0=cy+math.floor((ch-content_h)/2)
    if p.variant=="line" then self:rect(cx,cy,cw,1,theme.fg,.8,0)
    elseif p.variant=="console" then self:rect(cx,cy,cw,ch,theme.bg,1,0); self:rect(cx,cy,cw,3,theme.match,1,0)
    else
        self:card(cx,cy,cw,ch,surface_a,surface_r,sc)
    end
    self:text(cx+pad,y0+vpad+title_lh/2,tfs,theme.bgt,p.title,4,0)
    self:text(cx+cw-pad,y0+vpad+title_lh/2,tfs,theme.success,p.status,6,0)
    local sy=y0+vpad+title_lh+gap
    self:rect(cx+pad,sy,cw-pad*2,sep_h,theme.fg,t.alpha_card_separator,0)
    local py=sy+sep_h+gap
    self:rect(cx+pad,py,cw-pad*2,ph,theme.fg,.12,math.floor(ph/2))
    if p.progress>0 then self:rect(cx+pad,py,math.max(2,(cw-pad*2)*p.progress),ph,theme.match,.96,math.floor(ph/2)) end
    local fy=py+ph+gap+foot_lh/2
    local rw=right_w; local avail=cw-pad*2-rw-gap; local left=p.detail
    if avail>0 and p.tw(left,dfs)>avail then
        local n=math.max(2,math.floor(char_len(left)*avail/math.max(1,p.tw(left,dfs))))
        local guard=0
        left=p.trunc(left,n,true)
        while n>2 and guard<8 and p.tw(left,dfs)>avail do n=n-1; guard=guard+1; left=p.trunc(left,n,true) end
    end
    self:text(cx+pad,fy,dfs,theme.bgt,left,4,0,t.alpha_secondary_text,MONO_FONT)
    self:text(cx+cw-pad,fy,dfs,theme.bgt,p.right,6,0,.74,MONO_FONT)
end

function UI:job_card_done(p)
    local t=self.tokens; local theme=p.theme; local sc=p.scale
    local tfs=math.floor(t.layout_job_fs*sc); local dfs=math.floor(t.layout_job_detail_fs*sc)
    local pad=math.floor(t.layout_job_pad*sc)
    local vpad=math.floor(t.layout_card_row_gap*sc); local gap=vpad
    local title_lh=math.floor(tfs*1.4)
    local btnh=math.floor(t.dialog_button_height*sc); local btnw=0
    local foot_lh=math.max(btnh,math.floor(dfs*1.5))
    local min_w=math.floor(p.opts.job_card_width*sc); local max_w=math.max(min_w,math.floor(t.job_card_max_width*sc))
    local dir=p.trunc(p.dir,34,true)
    local need=math.max(p.tw(p.title,tfs)+gap+p.tw(p.status,tfs),p.tw(p.confirm_output:format(dir),dfs)+gap+btnw)
    local cw=math.max(min_w,math.min(max_w,need+pad*2))
    cw=hold_job_card_width(self,"full",p.job,cw,min_w,max_w)
    local content_h=vpad*2+title_lh+gap+foot_lh
    local ch=math.max(math.floor(p.opts.job_card_height*sc),content_h)
    local cx=p.sw-cw-math.floor(t.layout_card_edge*sc); local cy=math.floor(t.layout_card_edge*sc)
    local y0=cy+math.floor((ch-content_h)/2)
    if p.variant=="line" then self:rect(cx,cy,cw,1,theme.fg,.8,0)
    elseif p.variant=="console" then self:rect(cx,cy,cw,ch,theme.bg,1,0); self:rect(cx,cy,cw,3,theme.success,1,0)
    else
        local match_panel=(t.card_match_panel==1)
        local deck_r=tonumber(p.opts.deck_corner_radius) or 14
        local a=(t.alpha_job_card and t.alpha_job_card>0) and t.alpha_job_card
            or (match_panel and math.max(tonumber(theme.deck_alpha) or 0,tonumber(t.card_alpha_floor) or .86) or theme.opacity.menu)
        self:card(cx,cy,cw,ch,a,math.floor((match_panel and deck_r or theme.menu_radius)*sc),sc)
    end
    self:text(cx+pad,y0+vpad+title_lh/2,tfs,theme.bgt,p.title,4,0)
    self:text(cx+cw-pad,y0+vpad+title_lh/2,tfs,theme.success,p.status,6,0)
    local fy=y0+vpad+title_lh+gap+foot_lh/2
    local avail=cw-pad*2-btnw-gap; local left=p.confirm_output:format(dir)
    if avail>0 and p.tw(left,dfs)>avail then
        local n=math.max(2,math.floor(char_len(left)*avail/math.max(1,p.tw(left,dfs))))
        local guard=0
        left=p.confirm_output:format(p.trunc(dir,n,true))
        while n>2 and guard<8 and p.tw(left,dfs)>avail do n=n-1; guard=guard+1; left=p.confirm_output:format(p.trunc(dir,n,true)) end
    end
    self:text(cx+pad,fy,dfs,theme.bgt,left,4,0,t.alpha_secondary_text,MONO_FONT)
end
function UI:tokens_for_core() return self.tokens end
function UI:regions() return self.bounds end

local CROP_PANEL = {row_h = 19, ratio_w = 48, gap = 4, pad_x = 8, pad_y = 6, row_gap = 5}
function UI.crop_panel_height(s)
    s = tonumber(s) or 1
    return math.floor(CROP_PANEL.row_h * s) * 2
        + math.floor(CROP_PANEL.row_gap * s)
        + math.floor(CROP_PANEL.pad_y * s) * 2
end

local function panel_title(text_width,truncate_chars,label,bw,fs,pad)
    if text_width(label,fs)+pad <= bw then return label end
    return truncate_chars(label,1,false)
end

local function wrap_text(text_width,fs,label,bw)
    local lines={}
    if not label or label=="" or bw<=0 then return lines end
    local i,n=1,#label
    while i<=n do
        local chunk=""
        while i<=n do
            local b=label:byte(i)
            local cl=(b<0x80) and 1 or ((b<0xE0) and 2 or ((b<0xF0) and 3 or 4))
            local ch=label:sub(i,i+cl-1)
            if chunk~="" and text_width(chunk..ch,fs)>bw then break end
            chunk=chunk..ch; i=i+cl
        end
        lines[#lines+1]=chunk
    end
    return lines
end

local function panel_button_content(t,text_width,label,icon,bw,label_fs,pad)
    if (tonumber(t.layout_panel_icon) or 1) <= 0 then return label,nil end
    if not label or label=="" then return "",icon end
    if bw >= text_width(label,label_fs)+pad then return label,nil end
    return "",icon
end

local function deck_shape(defs,fit,available,s,t,btn_h,natural_width,gaps,pad,text_width)
    local label_fs=math.floor((tonumber(t.font_button) or 20)*s)
    local label_pad=math.floor(12*s)
    local bw,label={},{}
    local any=false
    for i,b in ipairs(defs) do
        local w_=math.max(t.layout_button_min_w,math.floor(b[2]*fit))
        local lb=b[3]
        if w_ < text_width(lb,label_fs)+label_pad then
            lb=(b[9] and text_width(b[9],label_fs)+label_pad<=w_) and b[9] or ""
        end
        bw[i]=w_; label[i]=lb
        if lb~="" then any=true end
    end
    local compact=not any
    local scale=1
    local btn_h_out=btn_h
    if compact then
        local icon_box=math.floor(btn_h*t.layout_icon_ratio)
        local cpad=math.max(2,math.floor((tonumber(t.layout_compact_pad) or 6)*s))
        local cw=icon_box+cpad*2
        local need=#defs*cw+gaps+pad*2
        scale=math.min(1,available/math.max(1,need))
        for i=1,#defs do bw[i]=math.max(1,math.floor(cw*scale)) end
        btn_h_out=math.max(6,math.floor((icon_box+cpad*2)*scale))
    end
    return {labels_full=natural_width<=available,compact=compact,scale=scale,btn_h=btn_h_out,bw=bw,label=label}
end

local PARAM_ICON_ALIAS = {
    audio_channels    = "channels",
    audio_sample_rate = "sample_rate",
    resolution        = "size",
    faststart         = "fast_start",
    smart_cut         = "auto_fix",
}
local function param_icon(t,id)
    if not id or not t.icons then return nil end
    return t.icons[PARAM_ICON_ALIAS[id] or id]
end

function UI:row_title(text_width,truncate_chars,x,y,fs,color,icon,label,bw,pad,icon_font,bold,icon_only)
    local has_icon=(type(icon)=="string" and icon~="")
    if (not icon_only) and has_icon and label~="" and text_width(label,fs)+pad > bw then
        icon_only=true
    end
    if icon_only then label="" end
    local icon_box=math.floor(fs*1.25)
    local gap=math.floor(fs*0.5)
    local tx=x
    if icon_only and type(icon)=="string" and icon~="" and icon_box>=8 then
        self:text(x+gap+icon_box/2,y,icon_box,color,icon,5,0,nil,icon_font,bold)
        tx=x+gap+icon_box+gap
    end
    label=panel_title(text_width,truncate_chars,label,bw-(tx-x),fs,pad)
    self:text(tx,y,fs,color,label,4,nil,nil,nil,bold)
end

function UI:render(ctx)
    local mp=ctx.mp
    local overlay=ctx.overlay
    local opts=ctx.opts
    local theme=ctx.theme
    local state=ctx.state
    local job=ctx.job
    -- 导出按钮的"忙碌"判定：准备窗口（job.preparing）与真正导出（job.running）都算。
    -- 标签/语义色/tip/激活位/图标必须同源，否则会出现"文字已变停止、图标还是导出"。
    local busy=job.running or job.preparing
    local L=ctx.L
    local function key_of(action)
        for _, b in ipairs(ctx.key_help_main or {}) do
            if b[2] == action then return b[1] end
        end
        return "?"
    end
    local text_width=ctx.text_width
    local format_time=ctx.format_time
    local truncate_chars=ctx.truncate_chars
    local DROPDOWN_MAX_ROWS=ctx.DROPDOWN_MAX_ROWS or 10
    local variants=self.tokens.variants
    local t=self.tokens
    local buttons={}
    local button_panel_bounds={x1=0,y1=0,x2=0,y2=0}
    local timeline_bounds={x1=0,y1=0,x2=0,y2=0}
    -- 无窗口/尺寸为 0（纯音频、idle、窗口过渡期）时不能裸 return：调用方会解引用返回值。
    -- 必须返回结构完整的空结果表，保证 render_ui 拿到合法 table。
    if not state.in_studio then overlay:remove()
        return {buttons={}, button_panel_bounds={x1=0,y1=0,x2=0,y2=0}, timeline_bounds={x1=0,y1=0,x2=0,y2=0}}
    end
    local d=mp.get_property_native("osd-dimensions")
    if not d or d.w==0 or d.h==0 then
        return {buttons={}, button_panel_bounds={x1=0,y1=0,x2=0,y2=0}, timeline_bounds={x1=0,y1=0,x2=0,y2=0}}
    end
    local w,h=d.w,d.h; overlay.res_x,overlay.res_y=w,h
    local base_s=mp.get_property_bool("fullscreen") and theme.scale_fs or theme.scale
    local vfit=math.min(1, w/math.max(1,t.min_viewport_w or 1280), h/math.max(1,t.min_viewport_h or 720))
    vfit=math.max(vfit, tonumber(t.layout_viewport_min_fit) or 1)
    local floor_raw=t.layout_narrow_floor
    local floor_w=tonumber(floor_raw)
    if floor_w==nil then
        floor_w=480
        if floor_raw~=nil and not t._narrow_floor_warned then
            t._narrow_floor_warned=true
            msg.warn("quick_cut: ui_layout_narrow_floor 不是数字（"..tostring(floor_raw)
                .."）⇒ 按默认 480 处理")
        end
    end
    if w < floor_w then vfit=math.min(vfit, w/floor_w) end
    local s=base_s*vfit
    state.ui_scale=s
    local radius=math.floor(theme.radius*s+.5); local ass={}; buttons={}
    local font=theme.font or mp.get_property("options/osd-font","sans-serif")
    self:begin(ass,font,opts.font_bold,theme.text_border*s)
    local function rect(x,y,rw,rh,color,alpha,r) self:rect(x,y,rw,rh,color,alpha,r or radius) end
    local function text(x,y,fs,color,value,align,border,alpha,font) self:text(x,y,fs,color,value,align,border,alpha,font) end
    local function button(id,x,y,bw,bh,label,accent,tip,fn,active,layer,icon,icon_size,disabled)
        local hit=self:button({id=id,x=x,y=y,w=bw,h=bh,label=label,accent=accent,tip=tip,fn=fn,active=active,hover=ctx.hovered_id==id or state.confirm_focus==id or state.flash_id==id,layer=layer,scale=s,icon=icon,icon_size=icon_size,idle=self.tokens.alpha_button_idle_deck,disabled=disabled})
        table.insert(buttons,hit)
    end
    local hud_visible = not state.crop_editing or not state.hud_hidden
    local deck_visible = hud_visible and not state.deck_hidden
        and not state.modal and not state.confirm_action and not state.help

    local timeline_h=math.floor(opts.timeline_height*s)
    local btn_h=math.floor(opts.button_height*s)
    local timeline_margin_bottom=math.floor(opts.deck_margin_bottom*s)
    local inset=math.floor(opts.timeline_inner_margin*s)
    if state.deck_hidden then
        inset=math.floor(t.layout_timeline_collapsed_margin_x*s)
        timeline_margin_bottom=math.floor(t.layout_timeline_collapsed_margin_bottom*s)
        timeline_h=math.max(math.floor(timeline_h*(tonumber(t.layout_timeline_collapsed_h_ratio) or .25)),
            math.floor(7*s))
    end
    local bound_h=0
    -- 草稿时长标注也要占这一行：只在"有边界时间码"时才留行会让标注被夹进进度条
    local has_draft_label = (state.start_time ~= nil and state.end_time ~= nil)
    if (t.timeline_boundaries==1 or has_draft_label) and not state.deck_hidden then
        bound_h=math.floor((tonumber(t.layout_timeline_time_fs) or 11)*s*1.5)
    end
    local bar_y=h-timeline_margin_bottom-timeline_h-bound_h
    local bar_x=inset; local bar_w=math.max(1,w-inset*2)
    -- 命中区只在时间轴真的画出来时才发布（绘制块的条件就是 hud_visible）：
    -- 否则 HUD 隐藏后这片区域仍是"有效"的，点空白会被判成时间轴点击（seek/改选中）。
    if hud_visible then
        timeline_bounds={x1=bar_x,y1=bar_y,x2=bar_x+bar_w,y2=bar_y+timeline_h+bound_h}
    else
        timeline_bounds={x1=0,y1=0,x2=0,y2=0}
    end
    if opts.show_crop_frame and ctx.crop_is_active(opts) then
        local crop=ctx.crop_rect(); local sr=ctx.crop_to_screen_rect(crop); local vr=ctx.displayed_video_rect()
        if sr and vr then
            local mask_alpha=state.crop_editing and opts.crop_edit_mask_alpha or opts.crop_preview_mask_alpha
            local mr={x1=0,y1=0,x2=w,y2=h}
            local cy1=math.max(mr.y1,math.min(sr.y1,mr.y2))
            local cy2=math.max(mr.y1,math.min(sr.y2,mr.y2))
            local cx1=math.max(mr.x1,math.min(sr.x1,mr.x2))
            local cx2=math.max(mr.x1,math.min(sr.x2,mr.x2))
            local yt=math.floor(cy1+1e-6)
            local yb=math.floor(cy2+1e-6)
            local xl=math.floor(cx1+1e-6)
            local xr=math.floor(cx2+1e-6)
            rect(mr.x1,mr.y1,mr.x2-mr.x1,math.max(0,yt-mr.y1),theme.crop_mask,mask_alpha,0)
            rect(mr.x1,yb,mr.x2-mr.x1,math.max(0,mr.y2-yb),theme.crop_mask,mask_alpha,0)
            rect(mr.x1,yt,math.max(0,xl-mr.x1),math.max(0,yb-yt),theme.crop_mask,mask_alpha,0)
            rect(xr,yt,math.max(0,mr.x2-xr),math.max(0,yb-yt),theme.crop_mask,mask_alpha,0)
            local geom=string.format("osd=%dx%d crop=%d,%d %dx%d video=[%.0f,%.0f]-[%.0f,%.0f] screen=[%.0f,%.0f]-[%.0f,%.0f] bands top_h=%.0f bottom_y=%.0f bottom_h=%.0f left_w=%.0f right_w=%.0f",
                math.floor(w),math.floor(h),
                crop.x or -1, crop.y or -1, crop.w or -1, crop.h or -1,
                vr.x1,vr.y1,vr.x2,vr.y2, sr.x1,sr.y1,sr.x2,sr.y2,
                math.max(0,yt-mr.y1), yb, math.max(0,mr.y2-yb),
                math.max(0,xl-mr.x1), math.max(0,mr.x2-xr))
            if self.crop_geom_logged~=geom then
                self.crop_geom_logged=geom
                msg.info("quick_cut crop mask: "..geom)
            end
            if state.crop_editing then
                local fw=math.max(2,math.floor(opts.crop_frame_width*s*1.8))
                local bw=math.max(1,math.floor(s))
                local function frect(x,y,w,h)
                    local e=math.max(1,math.floor(bw*1.5))
                    rect(x-e,y-e,w+e*2,h+e*2,"000000",.55,0)
                    rect(x,y,w,h,theme.crop_frame,1,0)
                end
                frect(sr.x1,sr.y1,math.max(fw,sr.x2-sr.x1),fw)
                frect(sr.x1,sr.y2-fw,math.max(fw,sr.x2-sr.x1),fw)
                frect(sr.x1,sr.y1,fw,math.max(fw,sr.y2-sr.y1))
                frect(sr.x2-fw,sr.y1,fw,math.max(fw,sr.y2-sr.y1))
                local hs=math.max(7,math.floor(t.layout_crop_handle*s)); local hh=math.floor(hs/2)
                local hc=theme.crop_frame
                local pad=hh+bw+1
                local function clamp_handle(hx,hy)
                    return math.max(vr.x1+pad,math.min(hx,vr.x2-pad)),
                           math.max(vr.y1+pad,math.min(hy,vr.y2-pad))
                end
                local function handle(hx,hy)
                    rect(hx-hh-1,hy-hh-1,hs+2,hs+2,"000000",.55,0)
                    rect(hx-hh,hy-hh,hs,hs,"FFFFFF",1,math.max(1,math.floor(hs*.25)))
                    rect(hx-hh+bw,hy-hh+bw,hs-bw*2,hs-bw*2,hc,1,math.max(1,math.floor(hs*.2)))
                end
                local hx,hy=clamp_handle(sr.x1,sr.y1); handle(hx,hy)
                hx,hy=clamp_handle(sr.x2,sr.y1); handle(hx,hy)
                hx,hy=clamp_handle(sr.x1,sr.y2); handle(hx,hy)
                hx,hy=clamp_handle(sr.x2,sr.y2); handle(hx,hy)
                local em=math.max(4,math.floor(t.layout_crop_edge*s)); local ec=theme.crop_frame
                local function edge(hx,hy,w,h)
                    rect(hx-w/2-1,hy-h/2-1,w+2,h+2,"000000",.55,1)
                    rect(hx-w/2,hy-h/2,w,h,ec,1,1)
                    rect(hx-w/2+bw,hy-h/2+bw,w-bw*2,h-bw*2,"FFFFFF",.95,1)
                end
                local mx,my=(sr.x1+sr.x2)/2,(sr.y1+sr.y2)/2
                hx,hy=clamp_handle(mx,sr.y1); edge(hx,hy,em,em)
                hx,hy=clamp_handle(mx,sr.y2); edge(hx,hy,em,em)
                hx,hy=clamp_handle(sr.x1,my); edge(hx,hy,em,em)
                hx,hy=clamp_handle(sr.x2,my); edge(hx,hy,em,em)
            else
                local fw=math.max(1,math.floor(opts.crop_frame_width*s))
                local corner=math.max(12,math.floor(math.min(sr.x2-sr.x1,sr.y2-sr.y1)*.10))
                corner=math.min(corner,math.floor(t.layout_crop_corner*s))
                local c=theme.match
                rect(sr.x1,sr.y1,corner,fw,c,1,0); rect(sr.x1,sr.y1,fw,corner,c,1,0)
                rect(sr.x2-corner,sr.y1,corner,fw,c,1,0); rect(sr.x2-fw,sr.y1,fw,corner,c,1,0)
                rect(sr.x1,sr.y2-fw,corner,fw,c,1,0); rect(sr.x1,sr.y2-corner,fw,corner,c,1,0)
                rect(sr.x2-corner,sr.y2-fw,corner,fw,c,1,0); rect(sr.x2-fw,sr.y2-corner,fw,corner,c,1,0)
            end
            local label_color=state.crop_editing and theme.crop_frame or theme.match
            local label_fs=math.floor(opts.menu_font_size*s)
            local handle_px=math.max(7,math.floor(t.layout_crop_handle*s))
            local gap=math.floor((t.layout_crop_label_gap or 14)*s)
            local half=label_fs*.5
            local above_y=sr.y1-gap-half
            local below_y=sr.y2+gap+math.max(0,handle_px-gap)+half
            local label_y
            if above_y-half>=0 then
                label_y=above_y
            else
                label_y=below_y
                if label_y+half>vr.y2 then label_y=sr.y2-handle_px-half end
            end
            if state.crop_editing then
                text((sr.x1+sr.x2)/2,label_y,label_fs,label_color,L("hint.crop_editing",crop.w,crop.h),5,nil,.94)
            end
        end
    end

    if hud_visible then
    if variants.timeline=="outline" then rect(bar_x,bar_y,bar_w,timeline_h,theme.timeline_bg,.14,2); rect(bar_x,bar_y,bar_w,1,theme.fg,.7,0); rect(bar_x,bar_y+timeline_h-1,bar_w,1,theme.fg,.7,0)
    elseif variants.timeline=="blocks" then rect(bar_x,bar_y,bar_w,timeline_h,theme.timeline_bg,1,0); rect(bar_x,bar_y,bar_w,3,theme.fg,1,0)
    -- 背景条必须与 bar_x/bar_w 同范围，否则视觉边缘（0..w）与时间映射边缘（inset..w-inset）错开，
    -- 会出现"时间轴看似占满宽度、但起止时间却不在两端"的错位
    else
        rect(bar_x,bar_y,bar_w,timeline_h,theme.timeline_bg,theme.opacity.timeline,0)
        rect(bar_x,bar_y,bar_w,1,theme.fg,.45,0)
        rect(bar_x,bar_y+timeline_h-1,bar_w,1,theme.fg,.30,0)
    end

    local duration = mp.get_property_number("duration", 0)
    local cur = mp.get_property_number("time-pos", 0)
    if duration > 0 then
        local tx, ty, tw, th = bar_x, bar_y, bar_w, timeline_h
        local wave = ctx.wave
        if wave and wave.cols and wave.path == mp.get_property("path") then
            local cols, n = wave.cols, #wave.cols
            if n > 0 and tw > 0 then
                local step = tw / n
                local merge = math.max(1, math.floor(6 / step))
                local segs = state.segments
                local i = 1
                while i <= n do
                    local mx = 0
                    for k = 0, merge - 1 do
                        local v = cols[i + k] or 0
                        if v > mx then mx = v end
                    end
                    local span_end = math.min(n, i + merge - 1)
                    local mid_t = ((i + span_end) / 2 - 0.5) / n * duration
                    local in_seg = false
                    for _, seg in ipairs(segs) do
                        if mid_t >= seg.start_time and mid_t <= seg.end_time then in_seg = true; break end
                    end
                    local bh = math.max(1, math.floor(mx * (th - 4)))
                    local bw = math.max(1, math.floor(step * merge))
                    local bx = math.floor(tx + (i - 1) * step)
                    local base_y = ty + math.floor((th - bh) / 2)
                    if in_seg then
                        rect(bx, base_y, bw, bh, theme.timeline_segment, .55, 0)
                    else
                        rect(bx, base_y, bw, bh, theme.fg, .22, 0)
                    end
                    i = i + merge
                end
            end
        end
        local overlapping={}
        for oi,a in ipairs(state.segments) do
            for _,b in ipairs(state.segments) do
                if a~=b and a.start_time < b.end_time and b.start_time < a.end_time then overlapping[oi]=true; break end
            end
        end
        local editing_id=state.editing_id
        local editing_seg
        if editing_id then
            for _,sg in ipairs(state.segments) do if sg.id==editing_id then editing_seg=sg break end end
        end
        local draft_n=(state.start_time~=nil and state.end_time~=nil) and ctx.normalize_draft_segment() or nil
        local hide_editing=(editing_id~=nil and draft_n~=nil)
        for i, seg in ipairs(state.segments) do
            local n = ctx.normalize_segment(seg.start_time, seg.end_time, duration)
            if hide_editing and seg.id==editing_id then n=nil end
            if n then
                local bx = tx + math.floor(n.start_time / duration * tw)
                local bw = math.max(3, math.floor((n.end_time - n.start_time) / duration * tw))
                local sc=seg.enabled~=false and theme.timeline_segment or theme.timeline_disabled
                local seg_alpha=(seg.enabled~=false) and (t.alpha_segment or .80) or (t.alpha_segment_disabled or .30)
                local edge_y=math.max(0,math.floor((tonumber(t.layout_segment_inset_y) or 1)*s))
                local div_on=tonumber(t.layout_segment_divider_w) or 1
                local div_w=div_on>0 and math.max(1,math.floor(div_on*s)) or 0
                local gx,gy,gw,gh=bx,ty+edge_y,bw,math.max(1,th-edge_y*2)
                rect(gx,gy,gw,gh,sc,seg_alpha,0)
                local selected=state.selected_segment_id==seg.id
                if selected then
                    local sel_col=(t.color_selection and t.color_selection~="" and t.color_selection)
                                  or accent_hex(sc,.30,1.15)
                    rect(gx,gy,gw,gh,sel_col,t.alpha_segment_selected or .92,0)
                end
                local function joined_at(time)
                    for _,o in ipairs(state.segments) do
                        if o~=seg and time>=o.start_time and time<=o.end_time then return true end
                    end
                    return false
                end
                if variants.timeline=="solid" and div_w>0 and (tonumber(t.alpha_segment_divider) or 0)>0 then
                    local dc=(t.color_segment_divider and t.color_segment_divider~="" and t.color_segment_divider) or sc
                    local ew=div_w; local edge_col=dc
                    if selected and not state.deck_hidden then
                        ew=math.max(div_w,math.floor((t.layout_selected_border or 3)*s))
                        edge_col=accent_hex(dc,.48,1.25)
                    end
                    if joined_at(n.start_time) then
                        rect(bx,gy,ew,gh,edge_col,t.alpha_segment_divider,0)
                    end
                    if joined_at(n.end_time) then
                        rect(bx+bw-ew,gy,ew,gh,edge_col,t.alpha_segment_divider,0)
                    end
                    if selected and not state.deck_hidden then
                        rect(gx,gy,gw,div_w,edge_col,t.alpha_segment_divider,0)
                        rect(gx,gy+gh-div_w,gw,div_w,edge_col,t.alpha_segment_divider,0)
                    end
                end
                if overlapping[i] then rect(gx,gy,gw,math.max(2,math.floor(s)),theme.error,.95,0) end
                if bw>16 and not state.deck_hidden then text(bx+bw/2,ty+th/2,math.floor(t.layout_timeline_label_fs*s),selected and theme.bg or theme.fgt,tostring(i),5,0) end
            end
        end
        if t.timeline_ruler==1 and tw>0 and not state.deck_hidden then
            do
                local rfs=math.floor(t.layout_timeline_time_fs*s)
                local tickh=math.max(3,math.floor(th*.3))
                local min_px=math.max(48,math.floor(64*s))
                local step
                for _,st in ipairs({1,2,5,10,15,30,60,120,300,600,900,1800,3600}) do
                    if st/duration*tw>=min_px then step=st break end
                end
                step=step or 3600
                -- 超长/异常 duration（直播流、损坏文件报出数天时长）：继续倍增到"间距达标且总数 ≤64"，
                -- 否则每帧要生成数百个 rect+text，且标签互相重叠成一片
                while (step/duration*tw<min_px or duration/step>64) and step<duration do step=step*2 end
                local k=1
                while k*step<=duration and k<=64 do
                    local tt=k*step
                    local rx=tx+math.floor(tt/duration*tw)
                    rect(rx,ty,1,tickh,theme.fg,.30,0)
                    local tl
                    if duration>=3600 then tl=string.format("%d:%02d:%02d",math.floor(tt/3600),math.floor(tt%3600/60),tt%60)
                    else tl=string.format("%d:%02d",math.floor(tt/60),tt%60) end
                    if rx+math.floor(3*s)+text_width(tl,rfs)<=tx+tw-math.floor(t.layout_timeline_time_pad*s) then
                        text(rx+math.floor(3*s),ty+math.floor(math.max(tickh,rfs)/2),rfs,theme.fg,tl,4,nil,.55,MONO_FONT)
                    end
                    k=k+1
                end
            end
        end
        if state.start_time ~= nil or state.end_time ~= nil then
            local marked_start = state.start_time ~= nil
            local marked_end = state.end_time ~= nil
            local start_active=state.active_handle=="start"; local end_active=state.active_handle=="end"
            local dcol=theme.pending; local dalpha=t.alpha_pending or .35
            if editing_id then
                local off=(editing_seg and editing_seg.enabled==false)
                dcol=off and theme.timeline_disabled or theme.timeline_segment
                dalpha=off and (t.alpha_segment_disabled or .25) or (t.alpha_segment or .7)
            end
            local n = draft_n
            if n then
                local bx = tx + math.floor(n.start_time / duration * tw)
                local bw = math.max(4, math.floor((n.end_time - n.start_time) / duration * tw))
                rect(bx,ty,bw,th,dcol,dalpha,0)
                local sw=5; local ew=5
                local oy=(state.deck_hidden and ty) or (ty-3); local oh=(state.deck_hidden and th) or (th+6)
                rect(bx-math.floor(sw/2),oy,sw,oh,dcol,1,1)
                rect(bx+bw-math.floor(ew/2),oy,ew,oh,dcol,1,1)
                rect(bx-5,ty-5,10,3,dcol,1,1)
                rect(bx+bw-5,ty-5,10,3,dcol,1,1)
                if not state.deck_hidden and not (bound_h>0 and #state.segments>0) then
                    local dur_fs=math.floor(t.layout_timeline_time_fs*s)
                    local dtxt=format_time(n.end_time-n.start_time)
                    local dw=text_width(dtxt,dur_fs)
                    -- 水平方向与边界行同样夹进时间轴范围（贴 0 的短草稿否则会越出窗口）；
                    -- 纵向不再"把中心夹回来"——那等于把标注塞进进度条，bound_h 已经为它留了行。
                    local dcx=math.max(tx+dw/2,math.min(bx+bw/2,tx+tw-dw/2))
                    local dur_y=ty+th+math.floor(dur_fs*.75)
                    if dur_y+math.floor(dur_fs*.75)>h then dur_y=h-math.floor(dur_fs*.75) end
                    text(dcx, dur_y, dur_fs, theme.fg, dtxt, 5, 0, .95, MONO_FONT)
                end
            else
                local oy=(state.deck_hidden and ty) or (ty-3); local oh=(state.deck_hidden and th) or (th+6)
                if marked_start then
                    local px=tx+math.floor(math.max(0,math.min(duration,state.start_time))/duration*tw)
                    local sw=start_active and 5 or 2
                    rect(px-math.floor(sw/2),oy,sw,oh,dcol,1,1)
                    if start_active then rect(px-5,ty-5,10,3,dcol,1,1) end
                end
                if marked_end then
                    local px=tx+math.floor(math.max(0,math.min(duration,state.end_time))/duration*tw)
                    local ew=end_active and 5 or 2
                    rect(px-math.floor(ew/2),oy,ew,oh,dcol,1,1)
                    if end_active then rect(px-5,ty-5,10,3,dcol,1,1) end
                end
            end
        end
        local shown_time=state.drag_preview_time or cur
        local play_x=tx+math.floor(math.max(0,math.min(duration,shown_time))/duration*tw)
        if not editing_id then
        if state.deck_hidden then
            rect(play_x-1,ty,3,th,theme.timeline_playhead,1,0)
        elseif variants.playhead=="dot" then rect(play_x-2,ty-4,4,th+8,theme.timeline_playhead,1,0); text(play_x,ty+th/2,math.floor(opts.playhead_diamond_size*s),theme.timeline_playhead,"●",5,1)
        else rect(play_x-1,ty-3,3,th+6,theme.timeline_playhead,1,0); text(play_x,ty+th/2,math.floor(opts.playhead_diamond_size*s),theme.timeline_playhead,"◆",5,1) end
        end
        if not state.deck_hidden then
            local tfs=math.floor(t.layout_timeline_time_fs*s)
            text(tx+math.floor(t.layout_timeline_time_pad*s),ty+th/2,tfs,theme.fg,format_time(cur),4,0,.72,MONO_FONT)
            text(tx+tw-math.floor(t.layout_timeline_time_pad*s),ty+th/2,tfs,theme.fg,format_time(duration),6,0,.58,MONO_FONT)
        end
        if bound_h>0 and tw>0 and duration>0 and #state.segments>0 then
            local bfs=math.floor(t.layout_timeline_time_fs*s)
            local times={}
            for _,sg in ipairs(state.segments) do
                times[#times+1]=sg.start_time
                times[#times+1]=sg.end_time
            end
            table.sort(times)
            local row_y=ty+th+math.floor(bfs*.75)
            local prev=-math.huge; local prev_end=-math.huge
            -- 草稿段时长也占这一行：先画它，后面的边界时间码据此避让
            local dur_l, dur_r
            if draft_n then
                local dtxt=format_time(draft_n.end_time-draft_n.start_time)
                local dw=text_width(dtxt,bfs)
                local dcx=tx+math.floor((draft_n.start_time+draft_n.end_time)*.5/duration*tw)
                dur_l=math.max(tx,math.min(dcx-dw/2,tx+tw-dw)); dur_r=dur_l+dw
                text((dur_l+dur_r)/2,row_y,bfs,theme.fg,dtxt,5,0,.95,MONO_FONT)
            end
            for idx=1,#times do
                local bt=times[idx]
                if bt>=0 and bt<=duration and bt>=prev+.01 then
                    prev=bt
                    local rx=tx+math.floor(bt/duration*tw)
                    local label=format_time(bt)
                    local wp=text_width(label,bfs)
                    local lx=math.max(tx,math.min(rx-wp/2,tx+tw-wp))
                    if lx>=prev_end+math.floor(6*s) and (not dur_l or lx+wp<=dur_l or lx>=dur_r) then
                        text(lx,row_y,bfs,theme.fg,label,4,nil,.55,MONO_FONT)
                        prev_end=lx+wp
                    end
                end
            end
        end
    end
    end

    local crop_ratio_items={{"16:9","16:9"},{"9:16","9:16"},{"1:1","1:1"},{"4:3","4:3"},{"3:4","3:4"},{"21:9","21:9"},{L("crop.free"),"free"}}
    local function crop_ratio_active(id)
        return (id=="free" and opts.crop_mode=="custom" and not state.crop_ratio_lock)
            or (opts.crop_mode=="custom" and opts.crop_aspect=="custom" and state.crop_ratio_lock==id)
            or (opts.crop_mode=="aspect" and opts.crop_aspect==id)
    end

    local crop_frame_rect=nil
    if state.crop_editing then
        local cr0=ctx.crop_rect and ctx.crop_rect()
        local r0=cr0 and ctx.crop_to_screen_rect and ctx.crop_to_screen_rect(cr0) or nil
        if r0 then crop_frame_rect={x=r0.x1,y=r0.y1,w=r0.x2-r0.x1,h=r0.y2-r0.y1} end
    end

    if state.crop_editing and not deck_visible then
        local btnh=math.floor(CROP_PANEL.row_h*s)
        local rw=math.floor(CROP_PANEL.ratio_w*s)
        local mg=math.floor(CROP_PANEL.gap*s)
        local padx=math.floor(CROP_PANEL.pad_x*s)
        local pady=math.floor(CROP_PANEL.pad_y*s)
        local rowgap=math.floor(CROP_PANEL.row_gap*s)
        local dwid=math.max(1,math.floor(t.layout_group_divider_w*s))
        local dpad=math.floor(t.layout_group_divider_pad*s)
        local gmgap=math.max(mg*2,math.floor(dpad*1.5))
        local row1={}
        for i,it in ipairs(crop_ratio_items) do
            if i==#crop_ratio_items then row1[#row1+1]={divider=true} end
            row1[#row1+1]={id="cropopt_"..it[2],label=it[1],accent=theme.btn.crop,
                tip=L("crop.select_tip",it[1]),fn=function() ctx.select_crop_preset(it[2]) end,
                active=crop_ratio_active(it[2])}
        end
        local row2={
            {id="cropbar_align_left",label=L("crop.align_left"),accent=theme.match,tip=L("crop.align"),
                fn=function() ctx.align_crop("left") end},
            {id="cropbar_align_center",label=L("crop.align_center"),accent=theme.match,tip=L("crop.align"),
                fn=function() ctx.align_crop("center") end},
            {id="cropbar_align_right",label=L("crop.align_right"),accent=theme.match,tip=L("crop.align"),
                fn=function() ctx.align_crop("right") end},
            {divider=true},
            {id="cropbar_size",label=L("crop.size"),accent=theme.match,tip=L("crop.size_tip"),
                fn=function() if ctx.crop_size_input then ctx.crop_size_input() end end},
            {id="cropbar_cancel",label=L("button.cancel"),accent=theme.error,tip=L("crop.cancel_tip"),
                fn=function() if ctx.crop_cancel then ctx.crop_cancel() end end},
            {id="cropbar_done",label=L("crop.done"),accent=theme.success,tip=L("crop.done_tip"),
                fn=function() if ctx.crop_done then ctx.crop_done() end end},
        }
        local function row_w(row)
            local total=0
            for i,e in ipairs(row) do
                total=total+(e.divider and dwid or rw)
                if i>1 then total=total+((e.divider or row[i-1].divider) and gmgap or mg) end
            end
            return total
        end
        local pw=math.max(row_w(row1),row_w(row2))+padx*2
        local edge=math.floor(12*s)
        if pw > w-edge*2 then
            local fit=math.min(1,(w-edge*2)/pw)
            rw=math.floor(rw*fit); mg=math.max(1,math.floor(mg*fit))
            gmgap=math.max(2,math.floor(gmgap*fit)); dwid=math.max(1,math.floor(dwid*fit))
            padx=math.max(2,math.floor(padx*fit))
            pw=math.max(row_w(row1),row_w(row2))+padx*2
        end
        local ph=btnh*2+rowgap+pady*2
        local px=math.max(0,math.floor((w-pw)/2))
        local py=h-math.floor(opts.deck_margin_bottom*s)-ph
        local auto_hide=false
        local fr=crop_frame_rect
        if fr then
            local ox=math.min(px+pw,fr.x+fr.w)-math.max(px,fr.x)
            local oy=math.min(py+ph,fr.y+fr.h)-math.max(py,fr.y)
            if ox>0 and oy>0 then auto_hide=true end
        end
        if state.crop_panel_pinned and not auto_hide then state.crop_panel_pinned=false end
        if state.crop_panel_pinned or (not state.crop_panel_hidden and not auto_hide) then
            local palpha=math.max(.45,(tonumber(theme.opacity.menu) or .88)*.6)
            self:menu_panel(px,py,pw,ph,palpha,math.max(4,math.floor(t.radius_menu*s*.7)),s)
            local function draw_row(row,y,rowy)
                local x=px+math.floor((pw-row_w(row))/2)
                for i,e in ipairs(row) do
                    if e.divider then
                        local inset=math.max(2,math.floor(dpad/4))
                        rect(x,y+inset,dwid,btnh-inset*2,t.color_group_divider,t.alpha_group_divider,math.floor(dwid/2))
                    else
                        button(e.id,x,y,rw,btnh,e.label,e.accent,e.tip,e.fn,e.active or false,"main")
                    end
                    if i<#row then
                        x=x+(e.divider and dwid or rw)+((e.divider or row[i+1].divider) and gmgap or mg)
                    end
                end
            end
            draw_row(row1,py+pady)
            if t.alpha_group_divider>0 then
                local dy=py+pady+btnh+math.floor(rowgap/2)
                local dl=padx+math.floor(dpad/2)
                rect(px+dl,dy,pw-dl*2,dwid,t.color_group_divider,t.alpha_group_divider,math.floor(dwid/2))
            end
                draw_row(row2,py+pady+btnh+rowgap)
        end
    end

    -- btn_y 必须声明在门控块之外：tooltip 与裁剪菜单锚点都在块外引用，
    -- 放进 if 块会退化成全局 nil，导致 "arithmetic on global 'btn_y'" 崩溃。
    -- hud 隐藏时保持 nil，引用处走 bar_y 回退。
    local btn_y
    local deck_shape_data={labels_full=true,compact=false,scale=1,btn_h=btn_h,bw={},label={}}
    if deck_visible then
    local gap=math.max(1,math.floor(opts.button_gap*s))
    local group_gap=math.max(gap,math.floor(opts.button_group_gap*s))
    local crop_locked=ctx.crop_is_active(opts)
    if crop_locked then state.accurate_mode=true end
    local uniform_width=math.floor(opts.button_uniform_width*s)
    local has_selection = ctx.checked_count() > 0 or state.selected_segment_id ~= nil
    local seg_sel_count = math.max(ctx.checked_count(), state.selected_segment_id ~= nil and 1 or 0)
    local defs = {
        {"in",uniform_width,L("button.in"),theme.btn["in"],L("tip.in"),ctx.set_start,false,t.icons["in"]},
        {"out",uniform_width,L("button.out"),theme.btn.out,L("tip.out"),ctx.set_end,false,t.icons.out},
        {"split",uniform_width,L("button.split"),theme.btn.split,L("tip.split"),ctx.split_at_playhead,false,t.icons.split},
        {"ctx.segment_action",uniform_width,
            state.editing_id and L("button.save")
                or (has_selection and (L("button.delete") .. (seg_sel_count > 1 and (" " .. seg_sel_count) or "")) or L("button.add")),
            has_selection and not state.editing_id and theme.btn.del or theme.btn.add,
            state.editing_id and L("tip.save") or (has_selection and L("tip.delete") or L("tip.add")),
            ctx.segment_action, state.editing_id ~= nil or has_selection,
            state.editing_id and t.icons.save or (has_selection and t.icons.del or t.icons.add)},
        state.selected_segment_id
            and {"segments",uniform_width,L("button.edit"),
                 theme.btn.seg,
                 state.editing_id and L("tip.editing_in_progress",key_of("add"),key_of("close"))
                     or L("tip.edit_selected",key_of("segments")),
                 ctx.edit_selected_segment,state.editing_id~=nil,t.icons.edit}
            or {"segments",uniform_width,string.format(L("button.segments"),#state.segments),theme.btn.seg,L("tip.segments"),ctx.toggle_segment_list,#state.segments>0,t.icons.segments,
                 L("button.segments_short")},
        {"crop",uniform_width,L("button.crop"),theme.btn.crop,L("crop.edit_tip"),ctx.open_crop_editor,opts.crop_mode~="none",t.icons.crop},
        {"wave",uniform_width,L("button.wave"),theme.btn.seg,L("tip.wave"),ctx.toggle_waveform,opts.waveform,t.icons.wave},
        {"export",uniform_width,busy and L("button.stop") or L("button.export"),busy and theme.error or theme.btn.cut,
            busy and L("tip.stop")
                or ((ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and L("hint.mpv_fallback_armed") or L("tip.export")),
            ctx.execute_cut,busy,busy and t.icons.stop or t.icons.export},
        {"reset",uniform_width,state.editing_id and L("button.cancel") or L("button.clear"),theme.btn.rst,state.editing_id and L("tip.cancel_edit") or L("tip.clear"),state.editing_id and function() ctx.cancel_edit(false) end or ctx.clear_marks,state.editing_id~=nil,state.editing_id and t.icons.cancel or t.icons.clear},
        {"exit",uniform_width,L("button.exit"),theme.btn.exit,L("tip.exit"),function() mp.commandv("script-message-to",mp.get_script_name(),"exit_studio_mode") end,false,t.icons.exit},
    }
    local group_break={split=true, segments=true, wave=true, export=true}
    local natural_buttons=0
    for _,b in ipairs(defs) do natural_buttons=natural_buttons+b[2] end
    local natural_gaps=0
    for i=1,#defs-1 do natural_gaps=natural_gaps+(group_break[defs[i][1]] and group_gap or gap) end
    local natural_pad=math.floor(opts.button_panel_padding_x*s)
    local available=math.max(1,w-math.floor(opts.deck_margin_x*s)*2)
    local natural_width=natural_buttons+natural_gaps+natural_pad*2
    local fit=natural_width>available and math.max(.30,available/natural_width) or 1
    local fitted_gap=math.max(1,math.floor(gap*fit))
    local fitted_group_gap=math.max(fitted_gap,math.floor(group_gap*fit))
    local fitted_pad=math.max(2,math.floor(natural_pad*fit))
    local panel_buttons=0
    for _,b in ipairs(defs) do panel_buttons=panel_buttons+math.max(t.layout_button_min_w,math.floor(b[2]*fit)) end
    local panel_gaps=0
    for i=1,#defs-1 do panel_gaps=panel_gaps+(group_break[defs[i][1]] and fitted_group_gap or fitted_gap) end
    deck_shape_data=deck_shape(defs,fit,available,s,t,btn_h,natural_width,panel_gaps,fitted_pad,text_width)
    -- 面板宽按**最终**按钮宽重算，否则面板居中会偏
    panel_buttons=0
    for i=1,#defs do panel_buttons=panel_buttons+deck_shape_data.bw[i] end
    local panel_w=math.min(w,panel_buttons+panel_gaps+fitted_pad*2)
    local panel_pad_y=math.floor(opts.button_panel_padding_y*s)
    local panel_h=deck_shape_data.btn_h+panel_pad_y*2
    local panel_x=math.floor((w-panel_w)/2)
    local panel_y=bar_y-math.floor(opts.button_timeline_gap*s)-panel_h
    button_panel_bounds={x1=panel_x,y1=panel_y,x2=panel_x+panel_w,y2=panel_y+panel_h}
    local edge=math.max(1,math.floor(s))
        local cr=math.floor(opts.deck_corner_radius*s)
        local tk=self.tokens
        local soff=math.floor((tk.shadow_offset or 0)*s)
        if soff>0 then self:rect(panel_x,panel_y+soff,panel_w,panel_h,theme.bg,tk.alpha_shadow or 0,cr,tk.shadow_blur or 0) end
        rect(panel_x,panel_y,panel_w,panel_h,theme.bg,theme.deck_alpha,cr)
        if tk.alpha_panel_highlight and tk.alpha_panel_highlight>0 and panel_h>=10 then
            local e=math.max(1,math.floor(1.3*s)); local inset=math.max(2,math.floor(cr*.5))
            local hw=panel_w-inset*2
            if hw>=2 then rect(panel_x+inset,panel_y+math.max(1,math.floor(s*.6)),hw,e,tk.color_panel_highlight,tk.alpha_panel_highlight,math.max(1,math.floor(e*2))) end
        end
        if opts.deck_border_alpha>0 and panel_w-math.floor(cr*.4)*2>=2 then
            rect(panel_x+math.floor(cr*.4),panel_y+math.max(1,math.floor(edge*.5)),panel_w-math.floor(cr*.4)*2,edge,theme.deck_border,opts.deck_border_alpha,math.max(1,math.floor(edge*2)))
        end
    btn_y=panel_y+panel_pad_y
    local boxes={}
    local x0=panel_x+math.max(fitted_pad,math.floor((panel_w-panel_buttons-panel_gaps)/2))
    do
        local x=x0
        for i,b in ipairs(defs) do
            local bw=deck_shape_data.bw[i]; boxes[i]={x=x,w=bw}
            if i<#defs then x=x+bw+(group_break[b[1]] and fitted_group_gap or fitted_gap) end
        end
        if variants.panel=="floating" then
            local gbg_h=deck_shape_data.btn_h+math.floor(t.layout_group_bg_pad*s); local gbg_y=btn_y-math.floor(t.layout_group_bg_offset*s); local gstart=1
            local gpad=math.floor(fitted_gap*.75)
            for i=1,#defs do
                if i==#defs or group_break[defs[i][1]] then
                    local gx=boxes[gstart].x-gpad
                    local gw=boxes[i].x+boxes[i].w-gx+gpad
                    if gx<panel_x+math.floor(t.layout_group_bg_inset*s) then gw=gw-(panel_x+math.floor(t.layout_group_bg_inset*s)-gx); gx=panel_x+math.floor(t.layout_group_bg_inset*s) end
                    if gx+gw>panel_x+panel_w-math.floor(t.layout_group_bg_inset*s) then gw=panel_x+panel_w-math.floor(t.layout_group_bg_inset*s)-gx end
                    if gw>0 then
                        if t.alpha_group_bg>0 then
                            rect(gx,gbg_y,gw,gbg_h,theme.fg,t.alpha_group_bg,math.floor(self.tokens.radius_button*s))
                        end
                        if t.alpha_group_divider>0 and i<#defs then
                            local nx=boxes[i+1].x-gpad
                            local dw=math.max(1,math.floor(t.layout_group_divider_w*s))
                            local dpad=math.floor(t.layout_group_divider_pad*s)
                            rect(math.floor((gx+gw+nx)/2),btn_y+dpad,dw,math.max(2,deck_shape_data.btn_h-dpad*2),t.color_group_divider,t.alpha_group_divider,math.floor(dw/2))
                        end
                    end
                    gstart=i+1
                end
            end
        end
    end
    local x=x0
    for i,b in ipairs(defs) do
        if b[6]==nil then msg.warn("quick_cut: deck button '"..tostring(b[1]).."' has no action (fn=nil); 检查 ctx 解构") end
        local bw=deck_shape_data.bw[i]
        local label=deck_shape_data.label[i]
        button(b[1],x,btn_y,bw,deck_shape_data.btn_h,label,b[4],b[5],b[6],b[7],nil,b[8],
            deck_shape_data.compact and math.floor(btn_h*t.layout_icon_ratio*deck_shape_data.scale) or nil,
            b[10] == true)
        if i<#defs then x=x+bw+(group_break[b[1]] and fitted_group_gap or fitted_gap) end
    end
    end

    if (mp.get_property_number("duration", 0) or 0) > 0
        and #state.segments == 0 and state.start_time == nil and state.end_time == nil
        and not state.deck_hidden and hud_visible and deck_shape_data.labels_full then
        text(bar_x+bar_w/2, bar_y+timeline_h/2, math.floor(t.layout_timeline_label_fs*s), theme.fg, L("hint.timeline_empty", key_of("in"), key_of("out"), key_of("add"), key_of("help")), 5, 0, .8)
    end

    if state.hover_time and state.hover_x then
        local label=format_time(state.hover_time)
        local fs=math.floor(t.layout_hover_time_fs*s)
        local lw=text_width(label,fs)+math.floor(t.layout_hover_time_pad*s)
        local lx=math.max(4,math.min(w-lw-4,state.hover_x-lw/2))
        local ly=bar_y-math.floor(t.layout_hover_time_gap*s)
        self:card(lx,ly,lw,math.floor(t.layout_hover_time_h*s),theme.opacity.tooltip,math.floor(t.layout_hover_time_radius*s),s)
        text(lx+lw/2,ly+math.floor(t.layout_hover_time_h/2*s),fs,theme.fg,label,5,0,nil,MONO_FONT)
    end
    if job.running or job.preparing then
        local dots=string.rep("·",(job.animation_frame%3)+1)
        local title=job.operation=="merge" and L("hint.job_merge",math.min(job.current,job.total),job.total) or L("hint.job_export",math.min(job.current,job.total),job.total)
        local status
        if job.status=="stopping" then status=L("hint.job_stopping",dots)
        elseif job.status=="joining" then status=L("hint.job_joining",dots)
        elseif job.status=="preparing" then status=L("hint.job_preparing",dots)
        elseif job.progress_samples>0 then status=string.format("%d%%",math.floor((job.overall_progress or 0)*100+.5))
        else status=L("hint.job_processing",math.min(job.current,job.total),job.total,dots) end
        local progress=math.max(0,math.min(1,job.overall_progress or 0))
        local stage_key=job.stage or job.status or "-"
        local detail=(ctx.STAGE_LABELS[stage_key] or tostring(stage_key))
        if job.current_range then detail=detail.." · "..format_time(job.current_range.start_time).." → "..format_time(job.current_range.end_time) end
        local started=job.started_at
        if type(started)~="number" or started<=0 then started=mp.get_time() end
        local elapsed=math.max(0,mp.get_time()-started)
        local right_info=job.speed~="" and job.speed or format_time(elapsed)
        if job.progress_samples>0 and progress>0.02 and progress<0.999 then
            local eta=math.max(0,elapsed*(1-progress)/progress)
            right_info=right_info.." · "..L("hint.job_eta",string.format("%02d:%02d:%02d",math.floor(eta/3600),math.floor(eta%3600/60),math.floor(eta%60)))
        end
        self:job_card_running{variant=variants.job,theme=theme,scale=s,sw=w,opts=opts,job=job,
            compact=state.deck_hidden or nil,
            tw=text_width,trunc=truncate_chars,
            title=title,status=status,progress=progress,detail=detail,right=right_info}
    elseif job.finish_ok and job.finished_at and mp.get_time()-job.finished_at < 15 then
        self:job_card_done{variant=variants.job,theme=theme,scale=s,sw=w,opts=opts,job=job,
            tw=text_width,trunc=truncate_chars,
            title=L("hint.job_done_title"),status=L("hint.job_done_stat_short",job.succeeded or 0,job.total or 0),
            dir=job.last_output_dir or "",confirm_output=L("confirm.output")}
    end

    if state.confirm_action then
        rect(0,0,w,h,theme.curtain,theme.opacity.curtain,0)
        local params=ctx.ENCODE_PARAMS or {}
        local t=self.tokens
        local inline_spec=(#params==1 and params[1].type=="list") and params[1] or nil
        local psw,pval={},{}
        for _,spec in ipairs(params) do
            if ctx.param_visible and ctx.param_visible(spec, state.export_kind,
                ctx.effective_accurate_mode and ctx.effective_accurate_mode(opts, state.accurate_mode,
                    (state.confirm_action == "merge") and "merge" or "export") or false,
                opts) == false then
            elseif spec==inline_spec then
            elseif spec.type=="bool" then psw[#psw+1]=spec else pval[#pval+1]=spec end
        end
        local maxcols=math.max(2,math.floor(tonumber(t.layout_confirm_cols) or 4))
        local rows_est=6+math.ceil(#pval/maxcols)+math.ceil(#psw/maxcols)
        local est_h=(t.dialog_row_height+t.dialog_row_gap)*rows_est
            +3*t.dialog_text_line+t.dialog_button_height+t.dialog_padding*2
            +t.dialog_bottom_pad+opts.menu_title_font_size
        s=s*math.min(1,(h-24)/math.max(1,est_h*s))
        local dp=math.floor(t.dialog_padding*s)
        local sg=math.floor(t.dialog_section_gap*s)
        local btnh=math.floor(t.dialog_button_height*s)
        local btngap=math.floor(t.dialog_button_gap*s)
        local notegap=math.floor(t.dialog_note_gap*s)
        local lineh=math.floor(t.dialog_text_line*s)
        local rowh=math.max(math.floor(t.dialog_row_height*s), btnh+math.floor(t.layout_row_extra*s))
        local rowgap=math.floor(t.dialog_row_gap*s)
        local btm=math.floor(t.dialog_bottom_pad*s)
        local cellh=math.floor(t.dialog_cell_height*s)
        local cellgap=math.floor(t.dialog_cell_gap*s)
        local colgap=math.floor(t.dialog_column_gap*s)
        local mincellw=math.floor(t.layout_grid_min_cell_w*s)
        local capw=math.floor(t.layout_confirm_width*s)
        local title_h=math.floor(opts.menu_title_font_size*s)
        local label_w=math.floor(t.layout_confirm_label_w*s)
        local note_h=lineh
        local fs_val=math.floor(t.layout_confirm_fs*s)
        local fs_lab=math.floor(t.layout_confirm_note_fs*s)
        local padx=math.floor(t.dialog_button_margin*s)
        local sepgap=math.max(2,math.floor(sg*0.5))
        local hr_h=math.max(1,math.floor(t.layout_group_divider_w*s))+sepgap*2

        local function est_w(v)
            local n=0
            for ch in tostring(v or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n=n+(#ch==1 and 0.55 or 1) end
            return n
        end
        local grid_avail=math.max(mincellw,math.min(w-24,capw)-dp*2-label_w)
        local grid_cols=math.max(1,math.min(maxcols,math.floor((grid_avail+colgap)/(mincellw+colgap))))
        local colw={}
        for j=1,grid_cols do colw[j]=mincellw end
        for i,spec in ipairs(pval) do
            local j=(i-1)%grid_cols+1
            local w0=math.floor(math.max(est_w(L(spec.label))*fs_lab,est_w(ctx.encode_param_text(spec.id))*fs_val))+padx*2+math.floor(cellh*0.42)+math.floor(6*s)
            if w0>colw[j] then colw[j]=w0 end
        end
        for i,spec in ipairs(psw) do
            local j=(i-1)%grid_cols+1
            -- 开关格：标签 + 内边距 + 开关本体；**不要**再留箭头位（cellh*0.42）——
            -- 开关没有 ▾，那 12px 白占，会把带开关的那一页顶宽（视频页快速复制比其他页宽 12px 即此）。
            local w0=math.floor(est_w(L(spec.label))*fs_val)+padx*2+math.floor(26*s)
            if w0>colw[j] then colw[j]=w0 end
        end
        local grid_w=(grid_cols-1)*colgap
        for j=1,grid_cols do grid_w=grid_w+colw[j] end

        local grid_rows=math.max(0,math.ceil(#pval/grid_cols))
        local sw_rows=math.max(0,math.ceil(#psw/grid_cols))
        local grid_h=grid_rows*cellh+math.max(0,grid_rows-1)*cellgap
        local sw_h=(sw_rows>0) and (sw_rows*rowh+math.max(0,sw_rows-1)*cellgap) or 0
        local seg_w=math.floor(math.max(est_w(L("confirm.mode_fast")),est_w(L("confirm.mode_accurate")))*fs_val)+padx*2
        local om_w=math.floor(math.max(est_w(L("confirm.out_separate")),est_w(L("confirm.out_merged")))*fs_val)+padx*2
        local pico_avail=math.min(w-24,capw)-dp*2
        local pico=false
        local mini=false
        -- 宽度不够 ⇒ **改用短名**（不切图标：导出面板全程文字）。
        -- 关键：必须同时按短名**重算按钮宽**，否则文字变短了、按钮还占着长名的宽度，整行照样顶出窗口
        if label_w+2*om_w+2*seg_w+math.max(1,math.floor(t.layout_group_divider_w*s))+4*btngap > pico_avail then
            pico=true
            seg_w=math.floor(math.max(est_w(L("confirm.mode_fast_short")),est_w(L("confirm.mode_accurate_short")))*fs_val)+padx*2
            om_w=math.floor(math.max(est_w(L("confirm.out_separate_short")),est_w(L("confirm.out_merged_short")))*fs_val)+padx*2
            label_w=math.floor(math.max(
                est_w(L("confirm.kind_short")),est_w(L("confirm.outmode_short")),
                est_w(L("confirm.source_label_short")),est_w(L("confirm.sec_format_short")),
                est_w(L("confirm.sec_extra_short")))*fs_val)+math.floor(12*s)
            if label_w+2*om_w+2*seg_w+math.max(1,math.floor(t.layout_group_divider_w*s))+4*btngap > pico_avail then
                mini=true
                local icw=math.floor(btnh*t.layout_icon_ratio)+2*math.max(2,math.floor((tonumber(t.layout_compact_pad) or 6)*s))
                om_w=icw; seg_w=icw
            end
        end
        local need=math.max(label_w+#(ctx.EXPORT_KINDS or {})*math.floor(64*s)+(#(ctx.EXPORT_KINDS or {})-1)*btngap,
                            label_w+(inline_spec and (#inline_spec.values*math.floor(64*s)
                                +math.max(0,#inline_spec.values-1)*btngap) or 0),
                            label_w+grid_w,
                            label_w+2*om_w+2*seg_w+math.max(1,math.floor(t.layout_group_divider_w*s))+4*btngap,
                            math.floor(t.layout_confirm_preset_w*s)
                            +math.floor(t.layout_confirm_cancel_w*s)+math.floor(t.layout_confirm_go_w*s)+btngap*2)
        -- 不要设硬下限 460：窗口比 460 还窄时面板会**超出窗口**。用软下限 300（够放标题与按钮行），
        -- 真正决定的是 need ⇒ 图标态下 need 变小、面板随之变窄、始终不超窗口
        local mw=math.min(w-24,capw,math.max(300,need+dp*2))
        local src_lines=math.max(1,#wrap_text(text_width,fs_val,
            ctx.source_param_text and ctx.source_param_text() or "",mw-dp*2-label_w))
        local avail_h=h-24
        local mh=dp+title_h+hr_h+(rowh+rowgap)+hr_h+(rowh+rowgap)
            +hr_h+(rowh+(src_lines-1)*note_h+rowgap)+hr_h
            +((#pval>0) and grid_h or (rowh+rowgap))
            +((sw_rows>0) and (hr_h+sw_h) or 0)+hr_h+note_h*2+notegap+btnh+btm
        if mh>avail_h then mh=avail_h end
        local mx=math.floor((w-mw)/2); local my=math.floor((h-mh)/2)
        -- 第 j 列的左边界（网格与开关组共用，保证两组列对齐）。必须放在 mx 之后定义：
        -- 放在前面时 mx 尚未声明，闭包读到的会是全局 nil，一调用就崩。
        local col_x=function(j) local x=mx+dp+label_w; for k=1,j-1 do x=x+colw[k]+colgap end return x end
        self:panel(mx,my,mw,mh,1)
        local queue=ctx.get_queue(); local total=0; for _,seg in ipairs(queue) do total=total+(seg.end_time-seg.start_time) end
        local is_merge=state.confirm_action=="merge"
        local y=my+dp
        text(mx+dp,y+math.floor(title_h/2),math.floor(opts.menu_title_font_size*s),theme.bgt,is_merge and L("confirm.title_merge") or L("confirm.title_export"),4)
        y=y+title_h
        local function hr()
            y=y+sepgap
            rect(mx+dp+math.floor(math.floor(t.layout_group_divider_pad*s)/2),y,
                mw-dp*2-math.floor(t.layout_group_divider_pad*s),math.max(1,math.floor(t.layout_group_divider_w*s)),
                t.color_group_divider,t.alpha_group_divider,math.floor(math.max(1,math.floor(t.layout_group_divider_w*s))/2))
            y=y+hr_h-sepgap
        end
        local chev=t.icons.chevron
        local function cell_text(x0,y0,cw,lab,val,with_chev,spec_id)
            local mod=spec_id~=nil and ctx.encode_param_modified and ctx.encode_param_modified(spec_id) or false
            local dot=mod and (math.max(3,math.floor(cellh*0.11))+math.floor(3*s)) or 0
            if mod then
                local d=math.max(3,math.floor(cellh*0.11))
                rect(x0+padx,y0+math.floor(cellh*0.30)-math.floor(d/2),d,d,theme.match,1,math.floor(d/2))
            end
            self:row_title(text_width,truncate_chars,x0+padx+dot,y0+math.floor(cellh*0.30),fs_lab,theme.bgt,
                param_icon(t,spec_id),lab,math.max(8,cw-padx*2-dot),math.floor(4*s),t.icon_font,nil,mini)
            local avail_w=cw-padx*2-math.floor(cellh*0.42)
            local need_w=est_w(val)*fs_val
            local shown=val
            if need_w>avail_w then
                local cnt=0
                for _ in val:gmatch("[%z\1-\127\194-\244][\128-\191]*") do cnt=cnt+1 end
                shown=truncate_chars(val,math.max(1,math.floor(cnt*avail_w/need_w)-1),false)
            end
            text(x0+padx+dot,y0+math.floor(cellh*0.70),fs_val,mod and theme.match or theme.bgt,shown,4)
            if mod then
                local box=math.floor(cellh*0.26)
                self:text(x0+cw-padx-box+box/2,y0+math.floor((cellh-box)/2)+box/2,math.floor(box*1.35),theme.match,"⟲",5,0,nil,nil)
                button("cr_"..spec_id,x0+cw-padx-box-math.floor(2*s),y0+math.floor((cellh-box)/2)-math.floor(2*s),
                    box+math.floor(4*s),box+math.floor(4*s),"",theme.match,L("confirm.revert_tip"),
                    function() ctx.reset_encode_param(spec_id) end,false,"confirm")
            elseif with_chev and chev then
                local box=math.floor(cellh*0.26)
                self:text(x0+cw-padx-box+box/2,y0+math.floor((cellh-box)/2)+box/2,math.floor(box*1.30),theme.bgt,t.icons.chevron,5,0,nil,t.icon_font)
            end
        end
        hr()
        local kinds=ctx.EXPORT_KINDS or {}
        local cur_kind=state.export_kind or "video"
        if #kinds>0 then
            self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
                t.icons.export_kind,(pico and L("confirm.kind_short")) or L("confirm.kind"),label_w,math.floor(6*s),t.icon_font,nil,mini)
            local tw=math.floor((mw-dp*2-label_w-(#kinds-1)*btngap)/#kinds)
            local x0=mx+dp+label_w
            local kico_all=mini
            for i,k in ipairs(kinds) do
                local klbl,kico=(kico_all and "") or L(k.label),
                    kico_all and (t.icons[k.id == "animated" and "gif" or (k.id == "image" and "images" or k.id)] or nil) or nil
                button("kind_"..k.id,x0,y+math.floor((rowh-btnh)/2),tw,btnh,klbl,theme.match,
                    L("confirm.kind_tip", L(k.label)),function() ctx.set_export_kind(k.id) end, cur_kind==k.id, "confirm",kico)
                x0=x0+tw+btngap
            end
        end
        y=y+rowh+rowgap
        hr()
        local merging=state.merge_output==true
        self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
            t.icons.output_mode,(pico and L("confirm.outmode_short")) or L("confirm.outmode"),label_w,math.floor(6*s),t.icon_font,nil,mini)
        local confirm_crop_locked=ctx.crop_is_active(opts)
        local confirm_accurate=(ctx.effective_accurate_mode
            and (ctx.effective_accurate_mode(opts,state.accurate_mode,
                (state.confirm_action == "merge") and "merge" or "export") and true or false))
            or (state.accurate_mode == true)
        local olbl,oico=(mini and "") or (pico and L("confirm.out_separate_short")) or L("confirm.out_separate"),mini and t.icons.parts or nil
        button("out_sep",mx+dp+label_w,y+math.floor((rowh-btnh)/2),om_w,btnh,olbl,
            theme.match,L("confirm.out_separate_tip"),
            function() if merging then ctx.toggle_merge_output() end end, not merging, "confirm",oico)
        local mlbl,mico=(mini and "") or (pico and L("confirm.out_merged_short")) or L("confirm.out_merged"),mini and t.icons.merge or nil
        button("out_merge",mx+dp+label_w+om_w+btngap,y+math.floor((rowh-btnh)/2),om_w,btnh,mlbl,
            theme.match,
            (ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and L("tip.needs_ffmpeg_merge") or L("confirm.out_merged_tip"),
            (ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and nil
                or function() if not merging then ctx.toggle_merge_output() end end,
            merging and not (ctx.ffmpeg_missing and ctx.ffmpeg_missing()), "confirm",mico,nil,
            ctx.ffmpeg_missing and ctx.ffmpeg_missing() or false)
        om_w=mx+dp+label_w+2*om_w+2*btngap
        rect(om_w,y+math.floor((rowh-btnh)/2)+math.max(2,math.floor(math.floor(t.layout_group_divider_pad*s)/2)),
            math.max(1,math.floor(t.layout_group_divider_w*s)),
            btnh-math.max(2,math.floor(math.floor(t.layout_group_divider_pad*s)/2))*2,
            t.color_group_divider,t.alpha_group_divider,math.floor(math.max(1,math.floor(t.layout_group_divider_w*s))/2))
        om_w=om_w+math.max(1,math.floor(t.layout_group_divider_w*s))+btngap
        local flbl,fico=(mini and "") or (pico and L("confirm.mode_fast_short")) or L("confirm.mode_fast"),mini and t.icons.copy or nil
        button("mode_fast",om_w,y+math.floor((rowh-btnh)/2),seg_w,btnh,flbl,theme.match,
            (ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and L("hint.mpv_no_copy_mode")
                or (confirm_crop_locked and L("confirm.crop_locked_short") or L("confirm.mode_fast_tip")),
            (ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and nil
                or function() if ctx.set_accurate_mode then ctx.set_accurate_mode(false) end end,
            not confirm_accurate and not (ctx.ffmpeg_missing and ctx.ffmpeg_missing()),"confirm",fico,nil,
            ctx.ffmpeg_missing and ctx.ffmpeg_missing() or false)
        local albl,aico=(mini and "") or (pico and L("confirm.mode_accurate_short")) or L("confirm.mode_accurate"),mini and t.icons.coding or nil
        button("mode_acc",om_w+seg_w+btngap,y+math.floor((rowh-btnh)/2),seg_w,btnh,albl,theme.match,
            confirm_crop_locked and L("confirm.crop_locked_short") or L("confirm.mode_accurate_tip"),
            function() if ctx.set_accurate_mode then ctx.set_accurate_mode(true) end end,
            confirm_accurate,"confirm",aico)
        y=y+rowh+rowgap
        hr()
        self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
            t.icons.source_codec,(pico and L("confirm.source_label_short")) or L("confirm.source_label"),label_w,math.floor(6*s),t.icon_font,nil,mini)
        do
            local srclines=wrap_text(text_width,fs_val,ctx.source_param_text and ctx.source_param_text() or "",
                mw-dp*2-label_w)
            if #srclines==0 then srclines={""} end
            for li,ln in ipairs(srclines) do
                text(mx+dp+label_w,y+math.floor(rowh/2)+(li-1)*note_h,fs_val,theme.bgt,ln,4,nil,t.alpha_secondary_text)
            end
            y=y+rowh+(#srclines-1)*note_h+rowgap
        end
        -- 快速复制（流复制）下编码参数整组收起：连分隔线和组标题一起不画，
        -- 只留一句说明，否则会出现"空的组标题"这种更奇怪的样子。
        local dd=state.param_dropdown
        local anchors={}
        if #pval>0 or inline_spec then
            hr()
            self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(cellh/2),fs_val,theme.bgt,
                t.icons.codec_format,(pico and L("confirm.sec_format_short")) or L("confirm.sec_format"),label_w,math.floor(6*s),t.icon_font,nil,mini)
        if inline_spec then
            local bw=math.floor((mw-dp*2-label_w-(#inline_spec.values-1)*btngap)/#inline_spec.values)
            om_w=mx+dp+label_w
            for _,v in ipairs(inline_spec.values) do
                local lab=inline_spec.labels and inline_spec.labels[tostring(v)]
                local vilab=lab and L(lab) or string.upper(tostring(v))
                button("ip_"..inline_spec.id.."_"..tostring(v),om_w,y+math.floor((rowh-btnh)/2),bw,btnh,
                    vilab,theme.match,
                    inline_spec.desc and L(inline_spec.desc) or nil,
                    function() ctx.set_encode_param(inline_spec.id,tostring(v)) end,
                    tostring(opts[inline_spec.field] or "")==tostring(v),"confirm")
                om_w=om_w+bw+btngap
            end
            y=y+rowh+rowgap
        else
        for i,spec in ipairs(pval) do
            local j=(i-1)%grid_cols+1
            local x0=col_x(j); local cy=y+math.floor((i-1)/grid_cols)*(cellh+cellgap)
            button("cp_"..spec.id,x0,cy,colw[j],cellh,"",theme.match,spec.desc and L(spec.desc) or nil,
                function() ctx.toggle_param_dropdown(spec.id) end, dd and dd.id==spec.id, "confirm")
            cell_text(x0,cy,colw[j],L(spec.label),ctx.encode_param_text(spec.id),true,spec.id)
            anchors[spec.id]={x=x0,y=cy,w=colw[j],h=cellh}
        end
            y=y+grid_h
        end
        else
            hr()
            text(mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
                panel_title(text_width,truncate_chars,L("confirm.sec_format"),label_w,fs_val,math.floor(6*s)),4)
            text(mx+dp+label_w,y+math.floor(rowh/2),fs_lab,theme.bgt,L("confirm.sec_format_skipped"),4,nil,t.alpha_secondary_text)
            y=y+rowh+rowgap
        end
        if sw_rows>0 then
            hr()
            self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
                t.icons.extra_processing,(pico and L("confirm.sec_extra_short")) or L("confirm.sec_extra"),label_w,math.floor(6*s),t.icon_font,nil,mini)
            for i,spec in ipairs(psw) do
                local on=(spec.id and true) and (opts[spec.field] and true or false)
                local j=(i-1)%grid_cols+1
                local x0=col_x(j); local cy=y+math.floor((i-1)/grid_cols)*(rowh+cellgap)
                button("cs_"..spec.id,x0,cy,colw[j],rowh,"",theme.match,
                    (ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec)) and L(ctx.missing_ffmpeg_tip(spec))
                        or (spec.desc and L(spec.desc) or nil),
                    (not (ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec)))
                        and function() ctx.set_encode_param(spec.id, on and "false" or "true") end or nil,
                    false, "confirm", nil, nil, false)
                text(x0+padx,cy+math.floor(rowh/2),fs_val,theme.bgt,L(spec.label),4,nil,
                    (ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec)) and t.alpha_button_disabled or nil)
                if ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec) then
                    self:line(x0+padx,cy+math.floor(rowh/2),
                        x0+padx+text_est_width(L(spec.label),fs_val),cy+math.floor(rowh/2),
                        t.color_text,math.min(1,t.alpha_button_disabled*1.15),
                        math.max(1,math.floor(t.layout_button_disabled_strike*s)))
                end
                local pw,ph=math.floor(26*s),math.floor(13*s)
                local bx=x0+colw[j]-padx-pw; local byy=cy+math.floor((rowh-ph)/2)
                local kon=on and not (ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec))
                rect(bx,byy,pw,ph,kon and theme.match or t.color_text,
                    ((kon and 1 or .30) * ((ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec)) and .55 or 1)),math.floor(ph/2))
                local kd=ph-math.floor(2*s)
                rect(kon and (bx+pw-kd-math.floor(1*s)) or (bx+math.floor(1*s)),byy+math.floor(1*s),kd,kd,
                    kon and t.color_text_inverse or t.color_text,
                    (kon and 1 or .75) * ((ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec)) and .38 or 1),math.floor(kd/2))
            end
            y=y+sw_h
        end
        hr()
        -- 结果确认区（两行）：第 1 行"输出 / 顺序"是只读状态（次级色），第 2 行是黄字编码摘要。
        -- 复用同一个 note 局部：render() 已顶到 200 局部上限，不能新增。
        local note=L("confirm.lbl_output").."："..truncate_chars(
            opts.output_directory~="" and opts.output_directory or L("confirm.output_source_dir"),
            math.max(8,math.floor((mw-dp*2)/(fs_lab*0.55))-60),true)
            .." ｜ "..L("confirm.lbl_order").."："
            ..(state.manual_order and L("confirm.order_manual") or L("confirm.order_time")).." · "
            ..((#queue==0) and string.format(L("confirm.whole"),format_time(mp.get_property_number("duration",0)))
                or string.format(L("confirm.count"),#queue,format_time(total)))
        text(mx+dp,y+math.floor(note_h/2),fs_lab,theme.bgt,note,4,nil,t.alpha_secondary_text)
        y=y+note_h
        note=L("confirm.encode", ctx.encode_summary())
        if not confirm_accurate and opts.smart_cut ~= true then note=note.." ｜ "..L("confirm.fast_note") end
        text(mx+dp,y+math.floor(note_h/2),math.floor(t.layout_note_fs*s),theme.heatmap,note,4)
        local by=my+mh-btm-btnh
        if ctx.cycle_export_preset then
            local pcw=math.min(math.floor(t.layout_confirm_preset_w*s), math.max(math.floor(24*s),
                mw-math.floor(t.layout_confirm_cancel_w*s)-math.floor(t.layout_confirm_go_w*s)
                -dp*2-btngap*2-2))
            local choice=(ctx.choice_label and ctx.choice_label()) or nil
            local pnow=(ctx.choice_name and ctx.choice_name()) or ctx.preset_label()
            local plbl=(mini and nil) or (pico and pnow) or choice or L("confirm.preset", ctx.preset_label())
            local plbl2,pico_icon=panel_button_content(t,ctx.text_width,plbl,
                choice and t.icons.optimize or t.icons.preset,
                pcw,math.floor((tonumber(t.font_button) or 20)*s),math.floor(12*s))
            button("confirm_preset",mx+dp,by,pcw,btnh,plbl2,theme.match,(ctx.choice_tip and ctx.choice_tip()) or L("confirm.choice_tip"),function() ctx.toggle_param_dropdown("_preset") end,dd and dd.id=="_preset","confirm",pico_icon)
            self:text(mx+dp+pcw-math.floor(14*s),by+math.floor(btnh/2),math.max(8,math.floor(btnh*0.42)),
                ((dd and dd.id=="_preset") and t.color_text_inverse or t.color_text),t.icons.chevron,5,0,nil,t.icon_font)
            anchors["_preset"]={x=mx+dp,y=by,w=pcw,h=btnh}
        end
        local go_x=mx+mw-dp-math.floor(t.layout_confirm_go_w*s)
        local cancel_x=go_x-math.floor(t.layout_confirm_cancel_w*s)-btngap
        button("confirm_cancel",cancel_x,by,math.floor(t.layout_confirm_cancel_w*s),btnh,L("confirm.cancel"),theme.error,L("confirm.cancel"),function() state.confirm_action=nil; state.param_dropdown=nil; if ctx.install_main_bindings then ctx.install_main_bindings() end; ctx.request_render(true) end,false,"confirm")
        rect(go_x,by,math.floor(t.layout_confirm_go_w*s),btnh,theme.success,1,math.floor(btnh/2))
        text(go_x+math.floor(math.floor(t.layout_confirm_go_w*s)/2),by+math.floor(btnh/2),fs_val,
            theme.bgt,L("confirm.go"),5)
        button("confirm_go",go_x,by,math.floor(t.layout_confirm_go_w*s),btnh,"",theme.success,L("confirm.go_tip"),ctx.confirm_execute,false,"confirm")
        if dd then
            local did=dd.id
            local options=ctx.param_options(did)
            local dmax=math.max(1,tonumber(DROPDOWN_MAX_ROWS) or 10)
            local drowh=math.floor(t.dialog_button_height*s)+math.floor(t.dialog_row_gap*s)
            local visible=math.min(#options,dmax)
            local dpad=math.floor(t.dialog_button_margin*s)
            local dw=math.floor(t.layout_dropdown_w*s); local dx=mx+math.floor(t.layout_dropdown_x*s); local ay=by; local ah=math.floor(t.layout_dropdown_h*s)
            local anchor=anchors[did]
            if anchor then dw,dx,ay,ah=anchor.w,anchor.x,anchor.y,anchor.h end
            local has_more=#options>visible
            local dh=dpad*2+visible*drowh+(has_more and lineh or 0)
            local dy=ay
            local outx=(anchor and (anchor.x+anchor.w+btngap) or (dx+dw+btngap))
            if outx+dw<=w-math.floor(t.layout_dropdown_edge*s) then dx=outx
            elseif mx-dp-btngap-dw>=math.floor(t.layout_dropdown_edge*s) then dx=mx-dp-btngap-dw
            else
                local rd=(my+mh-btm-btngap)-(ay+ah)
                dy=ay+ah
                if dh>rd and (dh<=ay-(my+dp) or ay-(my+dp)>rd) then dy=ay-dh end
            end
            dy=math.max(math.min(dy,h-math.floor(t.layout_dropdown_edge*s)-dh),math.floor(t.layout_dropdown_min_y*s))
            state.dropdown_rect={x1=dx,y1=dy,x2=dx+dw,y2=dy+dh}
            self:menu_panel(dx,dy,dw,dh,theme.opacity.menu,theme.menu_radius,s)
            for k=1,visible do
                local opt=options[(state.dropdown_scroll or 0)+k]
                if opt then
                    local oy=dy+dpad+(k-1)*drowh
                    if opt.header then
                        text(dx+dpad,oy+math.floor(drowh/2),math.floor(t.layout_scroll_more_fs*s),theme.bgt,
                            opt.label,4,nil,t.alpha_secondary_text)
                    else
                    if opt.danger then
                        -- 删除是唯一不可撤销的动作：标签用危险色自绘 —— button 的标签色是它内部
                        -- 定的（accent 只作用于底色/悬停），这里只把命中区交给它，标签传空串。
                        button("dp_"..did.."_"..k,dx+dpad,oy,dw-dpad*2,math.floor(t.dialog_button_height*s),
                            "",theme.error,nil,
                            function() if did=="_preset" then ctx.set_export_preset(opt.value) else ctx.set_encode_param(did,opt.value) end end,
                            false,"confirm")
                        text(dx+math.floor(dw/2),oy+math.floor(math.floor(t.dialog_button_height*s)/2),
                            math.floor(t.font_button*s),theme.error,opt.label,5)
                    else
                    local olbl=opt.label..(opt.current and "  ✓" or "")
                    button("dp_"..did.."_"..k,dx+dpad,oy,dw-dpad*2,math.floor(t.dialog_button_height*s),
                        olbl,theme.match,
                        nil,
                        function() if did=="_preset" then ctx.set_export_preset(opt.value) else ctx.set_encode_param(did,opt.value) end end,
                        opt.current,"confirm")
                    end
                    end
                end
            end
            if has_more then text(dx+dpad,dy+dh-dpad-lineh/2,math.floor(t.layout_scroll_more_fs*s),theme.heatmap,L("hint.scroll_more"),4,nil,.7) end
        else
            state.dropdown_rect=nil
        end
    elseif state.modal then
        rect(0, 0, w, h, theme.curtain, theme.opacity.curtain, 0)
        local t=self.tokens
        local dp=math.floor(t.dialog_padding*s)
        local tg=math.floor(t.dialog_title_gap*s)
        local btnh=math.floor(t.dialog_button_height*s)
        local rowh=math.max(math.floor(t.dialog_row_height*s), btnh+math.floor(t.layout_row_extra*s))
        local rowgap=math.floor(t.dialog_row_gap*s)
        local lineh=math.floor(t.dialog_text_line*s)
        local btm=math.floor(t.dialog_bottom_pad*s)
        local mw = math.min(w - 24, math.floor(t.layout_modal_width * s))
        local maxv = math.max(1, tonumber(opts.max_visible_segments) or 7)
        local title_h=math.floor(opts.menu_title_font_size*s)
        local sg=math.floor(t.dialog_section_gap*s)
        local mh = math.min(h - 24, dp+title_h+tg+maxv*(rowh+rowgap)+sg+btnh+lineh+btm); local mx = math.floor((w - mw) / 2); local my = math.floor((h - mh) / 2)
        self:panel(mx,my,mw,mh,1)
        local order_note = state.manual_order and L("hint.manual_order") or ""
        text(mx+dp,my+dp,math.floor(opts.menu_title_font_size*s), theme.bgt, string.format("%s (%d)%s", L.title, #state.segments, order_note), 4)
        button("close", mx + mw - dp - math.floor(t.layout_modal_close_w * s), my + dp + (title_h - btnh) / 2, math.floor(t.layout_modal_close_w * s), btnh, L.close, theme.btn.close, L("tip.close_modal"), function() state.modal = false; ctx.request_render(true) end, false, "modal")
        local btngap=math.floor(t.dialog_button_gap*s)
        local chk_w=btnh
        local first = math.min(math.max(1, state.segment_scroll + 1), math.max(1, #state.segments))
        local last = math.min(#state.segments, first + maxv - 1); local yy = my + dp + title_h + tg
        if #state.segments == 0 then
            text(mx + mw / 2, my + mh / 2, math.floor(t.layout_modal_empty_fs * s), theme.bgt, L("modal.empty", key_of("add")), 5, nil, .6)
        else
            local list_overlapping={}
            for oi,a in ipairs(state.segments) do
                for _,b in ipairs(state.segments) do
                    if a~=b and a.start_time < b.end_time and b.start_time < a.end_time then list_overlapping[oi]=true; break end
                end
            end
            for i = first, last do
                local seg = state.segments[i]; local seg_id = seg.id
                local by = yy + (rowh - btnh) / 2
                local custom = tostring(seg.label or "")
                local shown_name = (custom ~= "" and custom ~= L("hint.segment_label", seg_id)) and (custom .. "  ") or ""
                local label = string.format("%d. %s%s -> %s (%.3fs)%s", i, shown_name, format_time(seg.start_time), format_time(seg.end_time), seg.end_time - seg.start_time,
                    list_overlapping[i] and " ⚠" or "")
                local row_x = mx + dp + chk_w + btngap
                local row_w = math.max(1, mw - dp*2 - chk_w - btngap)
                button("row_"..seg_id, row_x, by, row_w, btnh, "", theme.btn.seg, L("tip.row_select"), function()
                    ctx.focus_segment(seg_id)
                    mp.commandv("seek", tostring(seg.start_time), "absolute+exact")
                    ctx.apply_segment_loop(); ctx.request_render(true)
                end, state.selected_segment_id == seg_id, "modal")
                local row_enabled = seg.enabled ~= false
                text(row_x + math.floor(t.dialog_padding*s), yy + rowh/2, math.floor(opts.menu_font_size*s),
                    row_enabled and theme.bgt or (theme.timeline_disabled or theme.fg), label, 4, nil, row_enabled and nil or .5)
                local marked = ctx.is_checked(seg_id)
                button("chk_"..seg_id, mx + dp, by, chk_w, btnh, marked and "✓" or "", marked and theme.match or theme.btn.seg,
                    marked and L("tip.uncheck_segment") or L("tip.check_segment"), function() ctx.toggle_range(seg_id) end, marked, "modal")
                yy = yy + rowh + rowgap
            end
            local has_target = ctx.checked_count() > 0 or state.selected_segment_id ~= nil
            local ops = {
                {L("button.delete"), theme.btn.del, L("tip.delete"), "delete", has_target},
                {"↑", theme.match, L("tip.move_up"), "up", has_target},
                {"↓", theme.match, L("tip.move_down"), "down", has_target},
                {L("modal.edit"), theme.heatmap, L("tip.edit_segment"), "edit", has_target},
                {L("modal.rename"), theme.fg, L("tip.rename_segment"), "rename", has_target},
                {L("modal.toggle_label"), theme.success, L("tip.enabled_click"), "toggle", has_target},
            }
            local op_w = math.max(1, math.floor((mw - dp*2 - btngap*(#ops-1)) / #ops))
            local op_y = my + mh - btm - lineh - btnh
            for oi, o in ipairs(ops) do
                local ox = mx + dp + (oi-1)*(op_w + btngap)
                button("op_"..o[4], ox, op_y, op_w, btnh, o[1], o[5] and o[2] or theme.btn.seg, o[3], function() ctx.list_op(o[4]) end, false, "modal")
            end
            text(mx + mw / 2, my + mh - btm - lineh / 2, math.floor(t.layout_modal_footer_fs * s), theme.bgt,
                L("hint.segment_list_footer", first, last, #state.segments, ctx.undo_count or 0, ctx.redo_count or 0), 5, nil, .6)
        end
    end
    local hover_btn=nil
    if ctx.hovered_tip then
        for i=#buttons,1,-1 do if buttons[i].id==ctx.hovered_id then hover_btn=buttons[i]; break end end
    end
    if ctx.hovered_tip and hover_btn then
        local hb=hover_btn
        local tip_fs=math.floor(opts.tooltip_font_size*s)
        local line_h=math.floor(tip_fs*1.35)
        local pad_x=math.floor(tip_fs*t.layout_tooltip_pad_ratio)
        local edge=math.floor(t.layout_tooltip_edge*s)
        local max_line_w=math.max(80, w - edge*2 - pad_x*2)
        local function wrap_lines(str)
            local out={}
            for hard in (tostring(str).."\n"):gmatch("(.-)\n") do
                local line=""
                for ch in hard:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                    if text_width(line..ch,tip_fs) > max_line_w and line ~= "" then
                        out[#out+1]=line; line=ch
                    else
                        line=line..ch
                    end
                end
                out[#out+1]=line
            end
            return out
        end
        local lines=wrap_lines(ctx.hovered_tip)
        local tip_w=0
        for _,l in ipairs(lines) do tip_w=math.max(tip_w, text_width(l,tip_fs)) end
        tip_w=tip_w+pad_x*2
        local tip_h=#lines*line_h + math.floor(tip_fs*0.4)
        local center=hb and hb.cx or w/2
        local tip_x=math.max(edge,math.min(w-tip_w-edge,math.floor(center-tip_w/2)))
        local gap_px=math.floor(opts.tooltip_gap*s)
        local tip_y=(hb and hb.y1 or btn_y)-tip_h-gap_px
        if tip_y<math.floor(t.layout_tooltip_min_y*s) then tip_y=(hb and hb.y2 or bar_y)+gap_px end
        if variants.tooltip=="outline" then rect(tip_x,tip_y,tip_w,tip_h,theme.bg,.3,3); rect(tip_x,tip_y,tip_w,1,theme.fg,.8,0)
        elseif variants.tooltip=="contrast" then rect(tip_x,tip_y,tip_w,tip_h,theme.bg,1,0); rect(tip_x,tip_y,tip_w,2,theme.match,1,0)
        else rect(tip_x,tip_y,tip_w,tip_h,theme.bg,theme.opacity.tooltip,math.floor(theme.tooltip_radius*s)) end
        local ty=tip_y+math.floor(tip_fs*0.2)+line_h/2
        for _,l in ipairs(lines) do
            text(tip_x+tip_w/2,ty,tip_fs,theme.fg,l,5,0)
            ty=ty+line_h
        end
    end

    if state.help then
        local bindings, action_labels
        if state.confirm_action then
            bindings, action_labels = ctx.key_help_confirm or {}, HELP_ACTIONS_CONFIRM
        elseif state.crop_editing then
            bindings, action_labels = ctx.key_help_crop or {}, HELP_ACTIONS_CROP
        else
            bindings, action_labels = ctx.key_help_main or {}, HELP_ACTIONS_MAIN
        end
        local grouped, order = {}, {}
        for _, b in ipairs(bindings) do
            local a = tostring(b[2] or ""):gsub("%-fast$", "")
            local desc = action_labels[a]
            if desc then
                if not grouped[a] then grouped[a] = {keys = {}, desc = desc}; order[#order + 1] = a end
                local ks = grouped[a].keys
                if #ks == 0 or ks[#ks] ~= b[1] then ks[#ks + 1] = b[1] end
            end
        end
        local rows = {}
        for _, a in ipairs(order) do rows[#rows + 1] = {keys = table.concat(grouped[a].keys, " / "), desc = L(grouped[a].desc)} end
        local function help_layout(sv)
            local dp = math.floor(t.dialog_padding*sv)
            local rowh = math.max(math.floor(t.dialog_row_height*sv), math.floor(opts.menu_font_size*sv) + math.floor(t.dialog_row_gap*sv))
            local row_fs = math.floor(opts.menu_font_size*sv)
            local title_h = math.floor(opts.menu_title_font_size*sv)
            local cols = 2
            local pw, colw, keyw, percol, line_h, ph, colh
            repeat
                percol = math.max(1, math.ceil(#rows / cols))
                pw = math.min(w - dp*2, math.floor(t.layout_modal_width * sv))
                colw = math.floor(pw / cols) - dp
                keyw = 0
                for _, row in ipairs(rows) do keyw = math.max(keyw, text_width(row.keys, row_fs)) end
                keyw = math.min(math.floor(colw * .55), keyw + math.floor(row_fs * .9))
                local descw = math.max(math.floor(row_fs * 4), colw - keyw)
                line_h = math.floor(row_fs * 1.35)
                for _, row in ipairs(rows) do
                    local lines = {}
                    for hard in (tostring(row.desc) .. "\n"):gmatch("(.-)\n") do
                        local line = ""
                        for ch in hard:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                            if text_width(line .. ch, row_fs) > descw and line ~= "" then
                                lines[#lines + 1] = line; line = ch
                            else
                                line = line .. ch
                            end
                        end
                        lines[#lines + 1] = line
                    end
                    row.lines = lines
                    row.h = rowh + (#lines - 1) * line_h
                end
                colh = {}
                for i, row in ipairs(rows) do
                    local col = math.floor((i - 1) / percol)
                    colh[col] = (colh[col] or 0) + row.h
                end
                local body_h = 0
                for _, v in pairs(colh) do if v > body_h then body_h = v end end
                ph = dp*2 + title_h + 10 + body_h + math.floor(t.dialog_text_line*sv)
                if ph <= h - dp*2 or cols >= 4 then break end
                cols = cols + 1
            until false
            return {dp=dp, rowh=rowh, row_fs=row_fs, title_h=title_h, cols=cols, percol=percol,
                pw=pw, colw=colw, keyw=keyw, line_h=line_h, ph=ph, colh=colh}
        end
        local H = help_layout(s)
        if H.ph > h - 4 then H = help_layout(s * math.max(0.4, (h - 4) / H.ph)) end
        local pw, ph, dp = H.pw, H.ph, H.dp
        local px = math.floor((w - pw) / 2); local py = math.floor((h - ph) / 2)
        rect(0, 0, w, h, theme.curtain, theme.opacity.curtain, 0)
        self:panel(px, py, pw, ph, 1)
        text(px + dp, py + dp + H.title_h/2, H.title_h, theme.bgt, L("help.title"), 4)
        local coly = {}
        for i, row in ipairs(rows) do
            local col = math.floor((i - 1) / H.percol)
            local cx0 = px + dp + col * (H.colw + dp)
            local cy0 = py + dp + H.title_h + 10 + (coly[col] or 0) + H.rowh/2
            coly[col] = (coly[col] or 0) + row.h
            text(cx0, cy0, H.row_fs, theme.fg, row.keys, 4, 0, 1, MONO_FONT)
            for k, line in ipairs(row.lines) do
                text(cx0 + H.keyw, cy0 + (k - 1) * H.line_h, H.row_fs, theme.bgt, line, 4, 0, .92)
            end
        end
        text(px + pw - dp, py + ph - dp - math.floor(t.layout_modal_footer_fs*s)/2, math.floor(t.layout_modal_footer_fs*s), theme.bgt, L("help.close_hint"), 6, 0, .6)
    end
    if state.action_hint and mp.get_time() < (state.action_hint_until or 0) then
        local lines={}
        for line in (tostring(state.action_hint).."\n"):gmatch("(.-)\n") do table.insert(lines,line) end
        if #lines==0 then lines={tostring(state.action_hint)} end
        local hint_color=state.action_hint_level=="success" and theme.success or (state.action_hint_level=="error" and theme.error or theme.match)
        local icon_key=state.action_hint_level=="success" and "check" or (state.action_hint_level=="error" and "alert" or "info")
        local m=self:hint_metrics{lines=lines,scale=s,sw=w,theme=theme,opts=opts,tw=text_width,trunc=truncate_chars,
            color=hint_color,icon=t.icons[icon_key],secondary=t.alpha_secondary_text,
            reserve_job=(job.running or (job.finish_ok and job.finished_at and mp.get_time()-job.finished_at<15)) and 1 or nil,
            alpha=(t.alpha_hint and t.alpha_hint>0) and t.alpha_hint or 0}
        local hx=math.floor(t.layout_card_edge*s); local hy=math.floor(t.layout_card_edge*s)
        self:hint_card(hx,hy,m)
    end
    overlay.data=table.concat(ass,"\n")
    overlay:update()
    return {
        buttons=buttons,
        button_panel_bounds=button_panel_bounds,
        timeline_bounds=timeline_bounds,
    }
end

return UI
