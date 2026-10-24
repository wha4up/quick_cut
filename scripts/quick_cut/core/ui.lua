-- quick_cut 统一 UI 与令牌模块
local mp=require "mp"
local msg=require "mp.msg"
local ICONS=require "icons"     -- 内置图标字形表（键名 → 字体码位；字形来自 fonts/Quickcut_icons.ttf）
local UI={}

-- ============================================================================
-- 设计令牌
-- ============================================================================

local DEFAULT_TOKENS={
    theme_name="graphite",
    color_panel="141416", color_text="FFFFFF", color_text_inverse="0B0B0C",
    color_primary="0A84FF", color_warning="FFD60A",
    -- 选中片段高亮的颜色覆盖：**留空 = 跟随片段自身色相**（对应色，见 alpha_segment_selected）。
    -- 想强制所有选中都用同一个颜色就写值（旧行为是 0A84FF）。
    color_selection="",
    color_success="30D158", color_danger="FF453A", color_timeline="141416",
    -- 片段底色（**已添加**的片段）：蓝 #4A90E2。设计稿的配色模型是
    --   已添加=蓝、未添加（正在标的截取范围）=橙、选中=对应色叠一层 + 加宽边线。
    -- 填充是**半透明**的（alpha_segment），而"边线 + 两端标记杆"一律**不透明** —— 见 color_segment_divider。
    color_segment="3B8FF0", color_segment_disabled="3A3A3C", color_playhead="FFFFFF",
    -- **未添加**的片段：正在用入点/出点标的这一段截取范围，以及它的两端标记杆 —— 橙 #FFB547。
    -- 与"已添加片段"的蓝分色相，一眼分得清"标好了"和"还在标"。
    color_pending="FFB547",
    -- 片段边线的颜色覆盖：**留空 = 跟随片段自身色相**（橙范围的边是橙、蓝片段的边是蓝、禁用片段是灰）。
    -- 想回到"所有边线统一一个颜色"就写死一个值（例如 FFFFFF）。线宽 = layout_segment_divider_w。
    -- 片段横向不再内缩留缝：透明缝里透出的是时间轴底色与画面，两段相连时会被读成"片段之间的空隙"，
    -- 所以边界一律用这条有色线表达。
    color_segment_divider="",
    color_group_divider="FFFFFF",
    -- 按钮悬停/激活的填充色覆盖（留空 = 用按钮自带的语义色）。
    -- 把它设成白色，就能得到"中性白色高亮"而不是彩色高亮。
    color_button_fill="FFFFFF",
    -- 图标按钮的图标色覆盖（留空 = 跟随文字色；激活态忽略此覆盖，用反色文字色）
    color_icon="FFFFFF",
    -- 图标按钮里"标签"的透明度（1 = 与图标一致；<1 让图标更亮、文字更收敛）
    alpha_icon_label=.70,
    -- 分组底板强度（0 = 不画分组底板，只保留按钮与分组分隔线）
    alpha_group_bg=0,
    -- 主面板按钮的"常显"底色（0 = 按钮平时无底色，只在悬停/激活时显示）。
    -- 与 alpha_button_idle 分开：确认面板 / 片段列表与主面板共用同一套按钮绘制，
    -- 那些面板的按钮需要常显底色才看得出可点（否则只剩文字）。
    alpha_button_idle_deck=0,
    -- 图标按钮里图标的尺寸比例（相对按钮高）；标签字号仍由 font_button 控制
    layout_icon_ratio=0.52,
    -- 图标按钮里标签是否加粗（0 = 不加粗，图标本身也会一并变细）
    label_bold=0,
    alpha_panel=.70, alpha_button_idle=.14, alpha_button_hover=.16, alpha_button_active=.88,
    -- 置灰（不可用）项的标签透明度 + 装饰样式。
    -- 只压暗在深色面板上常常"看着像能点、只是暗一点"，表达不清；
    -- 所以默认再加一条**删除线**（最通用的"不可用"语义，且不引入边框/底色，
    -- 与整体无框圆角风格一致）。可选值：
    --   strike       删除线（默认）
    --   slash        斜杠（更醒目，像"禁止"标记）
    --   strike_slash 两者叠加（最明确，但小按钮上会偏密）
    --   dim          只压暗（旧行为）
    button_disabled_style="strike",
    -- 删除线/斜杠的线宽（设计 px）
    layout_button_disabled_strike=2,
    -- 置灰标签的透明度（0 = 全透明，1 = 与正常标签一样亮；别调到 1，那样就看不出"不可用"了）
    alpha_button_disabled=.42,
    -- 片段填充的浓度层次：**已添加**的偏透（.7 —— 存下来的东西不必抢眼），
    -- **未添加/正在标**的更实（alpha_pending .35 —— 当前动作要看得见），
    -- **选中**的用同色相**提明度**再叠（见 alpha_segment_selected + 下面那圈加宽亮边）。
    -- 别把本项调太低：低于 .6 时蓝会被近黑轨道稀释成灰蓝（实测彩度只剩 ~44%）。
    alpha_timeline=.5, alpha_segment=.7, alpha_segment_disabled=.25,
    -- 选中填充（同色相提亮后的那一层）的强度；边线加宽量 = layout_selected_border（默认 3 设计 px）
    alpha_segment_selected=.92,
    -- 边线 / 两端标记杆的透明度：**1 = 不透明**（设计稿：填充可以透，边和标记不透）；0 = 不画边线
    alpha_segment_divider=1,
    -- 未添加（正在标的截取范围）的填充强度：默认 .35 —— 它代表"当前正在做的事"，要看得见；
    -- 已添加的片段反而更透（alpha_segment=.7），两者因此一眼分得开。0 = 只画两端标记，不铺底色。
    alpha_pending=.35,
    alpha_tooltip=.90, alpha_menu=.88, alpha_curtain=.62,
    alpha_shadow=.40, alpha_secondary_text=.60, alpha_group_divider=.20,
    shadow_blur=22, color_panel_highlight="FFFFFF", alpha_panel_highlight=.08,
    -- alpha_panel_highlight=0 时，卡片改用这条强度的 1px 描边立边界（见 UI:card）
    alpha_card_outline=.16,
    radius_button=8, radius_panel=14, radius_timeline=10, radius_tooltip=10, radius_menu=12,
    -- 按钮高 36 设计 px（720p 下实际 54px，仍高于 44px 的可点下限）。
    -- 10 个图标按钮的整条 deck 约占画面底部 1/8 高。
    button_height=36, button_width=52, status_button_width=94,
    panel_padding_x=14, panel_padding_y=8, button_gap=6, button_group_gap=14,
    button_timeline_gap=6, timeline_height=24, timeline_inset=10,
    -- 面板表面几何：这些键由 config.apply_ui_tokens 经 LAYOUT_MAP 同步进 opts
    -- （conf 显式设置优先）—— 它们就是内置外观的一部分。
    deck_margin_x=18, deck_margin_bottom=8, deck_corner_radius=14, deck_border_alpha=0.08,
    playhead_width=3, playhead_diamond_size=18, selected_border=3,
    -- 时间刻度 / 选区端点 IN-OUT 标签 / 底部状态行：默认关闭（0/1 开关）
    timeline_ruler=0,
    -- 时间轴**下方**那排片段边界时间码（1 = 显示）。与 timeline_ruler（轨道内的等距刻度）是两回事：
    -- 这条标的是"每一段从哪到哪"，也就是设计稿时间轴上方的 00:00:16.267 那排时间。
    timeline_boundaries=1,
    -- 按钮面板收起时的"贴底通条"留白：默认 0 = 与窗口同宽并贴到窗口底部（收起后操作走快捷键，
    -- 时间轴只作细长进度条）。若要保留浮动观感就给正值。
    layout_timeline_collapsed_margin_x=0, layout_timeline_collapsed_margin_bottom=0,
    layout_timeline_collapsed_h_ratio=.25,  -- 收起态时间轴高度相对展开态的比例（下限 7px，仅一条线）
    font_button=12, font_tooltip=12, font_menu=13, font_menu_title=15,
    -- 历史遗留键（**写了不生效**，别再新增）：
    --   font_timeline / font_hint → 时间轴时间文本用 layout_timeline_time_fs，操作提示条用 action_hint_font_size
    --   radius_tooltip            → tooltip 圆角当前跟随 opts.tooltip_radius（本令牌尚未接线）
    font_timeline=13, font_hint=19, shadow_offset=7,
    -- 图标按钮（variants.button="icon_stack"）：图标字号与图标字体族。
    -- 字形由内置 icons 表提供（按钮 id → 字形字符串），不硬编码在代码里。
    font_icon=16, icon_font="Segoe MDL2 Assets",
    -- ==========================================================================
    -- 统一间距标度（4px 基准）：4 / 8 / 12 / 16 / 20 / 24
    -- 所有 dialog_* 间距令牌的取值必须落在此标度上，禁止出现 6/10/18/34 之类零散值，
    -- 保证确认面板 / 裁剪菜单 / 片段列表 / 下拉浮层的视觉节奏完全一致。
    -- 标度： XS=4  SM=8  MD=12  LG=16  XL=20  2XL=24
    -- ==========================================================================
    dialog_padding=10,        -- 面板内边距            [XL]
    dialog_title_gap=8,       -- 标题 → 内容            [SM]
    dialog_section_gap=6,    -- 区块之间（参数区↔状态区/操作栏）[MD]
    dialog_row_height=26,     -- 行占用高（尺寸，非间距）
    dialog_row_gap=4,         -- 行距                   [SM]
    dialog_button_height=22,  -- 按钮高（尺寸，非间距）
    dialog_button_gap=10,     -- 按钮之间的水平间距      [MD]
    dialog_note_gap=4,        -- note 文本 → 操作栏      [SM]
    dialog_text_line=16,      -- 文本行高（尺寸，非间距）
    dialog_column_gap=12,     -- 参数网格列距（4/3/2 列自适应）  [XL]
    dialog_button_margin=5,   -- 按钮外边距             [SM]
    dialog_bottom_pad=8,     -- 面板底部内边距         [LG]
    dialog_cell_height=32,    -- 参数单元格高（标签在上 / 值在下两行）
    dialog_cell_gap=4,        -- 参数单元格行距         [SM]
    -- ==========================================================================
    -- 布局令牌：可由 conf 覆盖的几何尺寸
    -- 改令牌即可改变面板宽度、间距、字号等，从而形成不同的视觉骨架。
    -- ==========================================================================

    layout_confirm_width=700,     -- 导出确认面板宽度（4 列网格；窄窗口自适应收窄）
    layout_modal_width=680,       -- 片段列表宽度
    layout_confirm_label_w=64,    -- 确认面板标签列宽
    layout_confirm_preset_w=152,  -- 确认面板选单按钮宽（预设参数 / 优化目标，互斥只显示生效项）
    layout_narrow_floor=480,      -- **极窄地板**：窗口窄于它时整面板
                                  -- 等比缩小（复用 vfit）。地板及以上完全不变 —— 不再为极窄
                                  -- 做"逐项退化 + 单列重排"（那会留下空白与被压住的按钮）。
    layout_viewport_min_fit=1,    -- 窄视口整体缩放的下限（1=默认：**不按视口缩放**，图标/文字
                                  -- 始终保持默认尺寸；横向不够由主面板自身的按内容适配
                                  -- （丢标签 + layout_button_min_w 兜底）与各面板局部收缩解决。
                                  -- 只有窗口小到连最小按钮宽都排不下时，才建议调低到 .9/.8）
    layout_panel_icon=0,          -- **非主面板**是否使用图标：0=纯文本（默认）/1=放不下时退化为图标
                                  -- 1=允许（宽尺寸仍纯文本，窄尺寸退化为图标并与面板级同步）
                                  -- 主面板不受此令牌影响，始终使用图标
    layout_confirm_cancel_w=72,   -- 确认面板取消按钮宽
    layout_confirm_go_w=88,       -- 确认面板执行按钮宽
    layout_confirm_cols=4,        -- 参数网格最大列数（按可用宽度向下自适应 3/2）
    layout_grid_min_cell_w=104,   -- 参数单元格最小宽（决定何时降列）
    layout_modal_close_w=58,      -- 片段列表关闭按钮宽
    layout_modal_ops_w=330,       -- 片段列表操作区宽
    layout_modal_up_w=34,         -- 片段列表上移按钮宽
    layout_modal_down_w=34,       -- 片段列表下移按钮宽
    layout_modal_edit_w=48,       -- 片段列表编辑按钮宽
    layout_modal_toggle_w=54,     -- 片段列表启用/禁用按钮宽
    layout_modal_del_w=58,        -- 片段列表删除按钮宽
    layout_group_bg_pad=8,       -- 分组背景块高增量
    layout_group_bg_offset=4,     -- 分组背景块上偏移
    layout_group_bg_inset=5,      -- 分组背景块左右内边距
    layout_hover_time_fs=10,      -- 悬停时间提示字号
    layout_hover_time_pad=14,     -- 悬停时间提示横向内边距
    layout_hover_time_h=24,       -- 悬停时间提示高
    layout_hover_time_radius=4,   -- 悬停时间提示圆角
    layout_hover_time_gap=28,     -- 悬停时间提示距时间轴
    layout_tooltip_pad_ratio=2/3, -- tooltip 横向内边距（相对字号）
    layout_tooltip_height_ratio=1.7, -- tooltip 高（相对字号）
    layout_tooltip_edge=8,        -- tooltip 屏幕边缘留白
    layout_job_pad=12,            -- job 卡内边距（四边）
    layout_job_progress_h=5,      -- job 卡进度条高
    layout_job_fs=11,             -- job 卡标题字号
    layout_job_detail_fs=9,       -- job 卡脚注字号
    --（不要再用"绝对基线"式的任务卡令牌：
    --  任务卡是内容驱动的三段式布局，高度由内容决定）
    -- 提示条排版比例：向"小字 + 紧边距"收敛。
    -- 1.15/1.35/1.2 + 16px 边距下限会把两行提示撑到与主面板同高（72px vs 73px），
    -- 观感"又大又松"；两行卡只有面板高的 0.67~0.73 才合适。
    layout_hint_pad_x_ratio=.70,  -- action hint 横向内边距比例（floor 10px 兜底）
    layout_hint_pad_y_ratio=.40,  -- action hint 纵向内边距比例
    -- 想直接给"绝对像素边距"就用下面两项（>0 生效，数值会乘界面缩放系数，但不随字号漂移；
    -- 0 = 用上面的比例值 —— 比例值是"字号 × 比例"，所以字号一变边距跟着变）。
    -- 提示卡是 [内边距][图标][间距][文本][内边距]，左右两侧的内边距由 layout_hint_pad_x 一项同时决定。
    layout_hint_pad_x=0, layout_hint_pad_y=0,
    layout_hint_line_ratio=1.18,  -- action hint 标题行高比例
    layout_hint_row_ratio=1.12,   -- action hint 正文行高比例（比标题紧一档）
    layout_hint_icon_ratio=.95,   -- 提示条语义图标相对字号的比例（0.95 ≈ 与标题同高）
    -- 提示条字号相对**按钮标签字号**的上限比例：action_hint_font_size 是 conf 里的独立值，
    -- 用户把它调大后（实测 18 + scale 1.5）提示会比主面板标签还大，两块弹窗就"失衡"了。
    -- 取 0.95 让提示标题与面板标签同级；要保持大号提示就调大本令牌。
    layout_hint_font_ratio=1.05,
    -- 提示条宽度：**按内容自然宽度完整显示**，唯一的硬边界是不得侵入右上角任务卡的地盘
    -- （两者同屏，且都在屏幕顶部）。reserve_gap 是两者之间保留的间距；任务卡区域宽度取
    -- job_card_max_width（该卡的上限宽，按上限预留最安全）。
    -- 预留区宽度 = job_card_max_width（不做内部留白）；下面这一项就是两卡之间唯一的间距
    layout_hint_zone_gap=12,      -- 左上提示条与右上任务卡之间的间距（够两卡不贴在一起即可）
    layout_hint_max_ratio=.40,    -- 窗口过窄时（预留区吃掉大半屏）的最小可用宽占比，兜底不至于挤成一条
    layout_hint_min_w=180,        -- action hint 最小宽（卡片形态）
    layout_hint_min_h=34,         -- action hint 最小高（卡片形态）
    layout_hint_chip_min_h=24,    -- 单行紧凑提示（hint_compact）的最小高
    layout_card_edge=16,          -- 卡片距屏幕边的统一间距：提示卡（左上）与任务卡（右上）共用，保证顶部对齐
    min_viewport_w=1280,          -- 界面设计基准宽：窗口更窄时整体等比缩小
    min_viewport_h=720,           -- 界面设计基准高：窗口更矮时整体等比缩小
    layout_hint_max_edge=32,      -- action hint 最大宽留白
    layout_hint_bar_w=3,          -- action hint 左侧色条宽
    layout_hint_bar_inset=0,      -- action hint 色条内边距（0 = 满高细条；要留边距的自行调大）
    layout_hint_bar_gap=0,        -- action hint 色条上下留白
    -- ==========================================================================
    -- 浮动卡片（提示条 / 任务卡）的外观开关：这两块是画面左上 / 右上唯一的常驻浮层。
    -- 表面（阴影 / 顶部发丝高光）直接复用 shadow_* 与 color_panel_highlight/alpha_panel_highlight；
    -- 圆角分别取 radius_tooltip（提示条）与 radius_menu（任务卡），不另开圆角令牌。
    --   alpha_hint / alpha_job_card = 0（默认）→ 自动跟随令牌：
    --     提示条 = max(.90, theme.opacity.tooltip)；任务卡 = theme.opacity.menu
    --   hint_compact=1 时"单行提示"走紧凑 chip（无标题层级、无色条），多行仍是卡片
    --   hint_icon=1 且 icons 提供语义图标（check/alert/info）时，用图标承担语义色并替代色条
    --   job_card_width 语义 = **最小宽**；内容更宽时按 job_card_max_width 放宽（脚注不再压字）
    -- ==========================================================================
    alpha_hint=0, alpha_job_card=0, alpha_card_separator=.08,
    hint_compact=1, hint_icon=1, job_card_max_width=320,
    -- 任务卡最小宽/高（job_card_max_width 是上限）：同样是"内置外观 → opts"的一员
    job_card_width=210, job_card_height=56,
    -- 弹窗表面是否与主面板保持一致（默认 1）：两者通常同屏显示，风格不一致会很跳。
    -- 打开时透明度取 max(alpha_panel, .86)、圆角取 deck_corner_radius；
    -- 之所以设 .86 下限：面板那种大面透明度（onyx .70）套到小卡片上会"发虚"，
    -- 参考设计稿的卡片都更实；一致性应落在"同一套层次语言"，而不是同一个透明度值。
    -- 设为 0 时才由 alpha_hint / alpha_job_card / radius_tooltip / radius_menu 各自控制。
    card_match_panel=1, card_alpha_floor=.86,
    -- 卡片专用阴影/行距：大面板的 shadow_offset+shadow_blur 是给大面积用的，
    -- 套到小卡片上会糊成一片（设计稿的卡片几乎无投影，靠 1px 亮描边立边界）。
    layout_card_shadow_ratio=.5,  -- 卡片阴影 偏移/模糊/透明度 统一按此比例打折
    layout_card_row_gap=6,        -- 卡片内部行距（任务卡三段式之间）
    layout_dropdown_w=170,        -- 下拉浮层宽
    layout_dropdown_x=150,        -- 下拉浮层默认 x 偏移
    layout_dropdown_h=34,         -- 下拉浮层默认高
    layout_crop_hint_fs=11,       -- 裁剪菜单提示字号
    layout_confirm_fs=11,         -- 确认面板正文字号
    layout_confirm_note_fs=10,    -- 确认面板 note 字号
    layout_modal_empty_fs=13,     -- 片段列表空态字号
    layout_modal_footer_fs=11,    -- 片段列表页脚字号
    layout_modal_row_fs=10,       -- 片段列表行字号
    layout_timeline_label_fs=10,  -- 时间轴片段序号字号
    layout_timeline_time_fs=10,   -- 时间轴时间文本字号
    layout_timeline_time_pad=8,   -- 时间轴时间文本边距
    layout_crop_handle=11,        -- 裁剪手柄尺寸
    layout_crop_edge=7,           -- 裁剪边中点尺寸
    layout_crop_corner=42,        -- 裁剪角标最大尺寸
    layout_crop_label_gap=14,     -- 裁剪标签距上缘
    layout_crop_label_off=10,     -- 裁剪标签距裁剪框
    -- ==========================================================================
    -- 补充布局令牌：把 render() 中残留的硬编码几何值收拢为令牌，可由 conf 覆盖。
    -- ==========================================================================
    layout_button_min_w=22,       -- 按钮最小宽
    icon_font="Quickcut_icons",   -- 字体族名（与字体 name 表一致）
    layout_compact_pad=6,         -- 主面板"只画图标"（紧凑）时图标四周留白（×s）
    layout_contrast_border=2,     -- contrast_box 按钮边框宽
    layout_button_hover_grow=3,   -- 按钮悬停外扩宽
    layout_selected_border=3,     -- 时间轴选中片段边框宽
    -- 时间轴片段：**纵向内缩**与**边界线宽**是两个独立令牌（
    -- 共用一项时"想把线加粗"会同时把片段上下压窄）。片段左右不内缩：相邻片段严丝合缝，
    -- 边界一律由 color_segment_divider / alpha_segment_divider 那条线表达。
    -- 默认 0 = 片段与它的**边线**都贴满轨道高度。设成 1（设计 px × 缩放后上下各去 1px）：
    -- 片段块和边线会比时间轴矮 2px，看起来"边和轨道不同高"。
    -- 想要一点"浮在轨道里"的留缝感就调成 1。
    layout_segment_inset_y=0,      -- 片段上下内缩像素（0 = 贴满轨道高度）
    layout_segment_divider_w=1,    -- 相邻片段边界线宽（0 = 不画线）
    layout_row_extra=2,           -- 行高兜底增量（上下各 2px）
    layout_note_fs=10,            -- 确认面板 note 字号
    layout_dropdown_edge=8,       -- 下拉浮层底部边界留白
    layout_dropdown_min_y=4,      -- 下拉浮层顶部最小留白
    layout_scroll_more_fs=11,     -- 下拉浮层滚动提示字号
    layout_tooltip_min_y=8,       -- tooltip 顶部最小留白
    layout_group_divider_w=1,     -- 分组间竖分隔线宽（alpha_group_divider=0 时不画）
    layout_group_divider_pad=8,   -- 分组间竖分隔线上下留白
}

-- ============================================================================
-- 内置外观
-- ============================================================================

-- 外观已是内置常量（不支持自定义主题）：
--   · 令牌取值 = 下面 DEFAULT_TOKENS 里那一套；
--   · 图标库   = core/icons.lua（键名 → 码位表，字形来自 fonts/Quickcut_icons.ttf）；
--   · variants = 下面这一行。
-- 想改外观：颜色/透明度/尺寸优先走 quick_cut.conf 的 ui_* 选项，骨架风格才需要改这里的常量。
local DEFAULT_VARIANTS={panel="floating",button="icon_stack",timeline="solid",playhead="dot",tooltip="filled",hint="card",job="card",menu="filled",dialog="filled",list="cards"}

-- ============================================================================
-- 令牌加载与校验
-- ============================================================================

-- 键位速查浮层的"动作 → 文案键"映射：core.lua 的 *_KEY_DEFINITIONS 只给动作 id 与键位，
-- 文案在这里查（缺失的动作不会出现在浮层里，所以新增动作时两处都要补）。
-- 注意：这三张表必须与 core.lua 的动作表保持同步，缺项会让浮层索引 nil 报错
-- （只在绑定表非空时触发，预览里 bindings 为空所以看不出来）。
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
-- 字符数（非字节）：文本宽度预算是按"字"收缩的，用 #s 估算中文会多算 3 倍字符、把截断循环拖长
local function char_len(s)
    local n=0
    for _ in tostring(s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n=n+1 end
    return n
end
-- 估算文字宽度（不依赖绘制层的 text_width）：CJK/全角算 1 个字宽、其余算 0.55。
-- 只给"置灰删除线"量标签长度用 —— 那根线允许有几像素误差，不值得把 text_width 穿进来。
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
    -- 置灰（不可用）项：透明度 + 装饰样式 + 线宽（默认加删除线）
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
    -- 这些令牌在 conf 里直接可调
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
    -- 以下令牌全部有 conf 入口
    ui_timeline_ruler="timeline_ruler",                     -- 时间轴时间刻度（0/1）
    ui_timeline_boundaries="timeline_boundaries",           -- 时间轴下方的片段边界时间码（0/1）
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
    -- 导出面板的几何量，conf 可调
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
-- 令牌集合 = 内置默认值 + conf 的 ui_* 覆盖（见上方说明）
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

-- ============================================================================
-- ASS 基础图元与共享组件
-- ============================================================================

local function ass_color(v) v=tostring(v or "FFFFFF"):gsub("^#",""); return (v:sub(5,6)..v:sub(3,4)..v:sub(1,2)):upper() end
-- 只用于**选中片段那圈加宽的边线**：同色相 → 向白提亮 lift、再按 sat 提饱和。
-- 两个都必须做：
--   ① 选中片段的填充本来就叠到近乎不透明，画一圈"同色同透明度"的边等于没画（实测 4px 看不出来）；
--   ② 只提亮会掉饱和度（往白里混 = 变灰），所以提亮之后要再把彩度拉回来。
-- 设计稿里选中片的边是 #66AFFF，而片段底色是 #4A90E2 —— 正是"同色相 + 更亮 + 更饱和"的关系。
local function accent_hex(v, lift, sat)
    local s=tostring(v or ""):gsub("^#","")
    if not s:match("^%x%x%x%x%x%x$") then return v end
    local r,g,b=tonumber(s:sub(1,2),16),tonumber(s:sub(3,4),16),tonumber(s:sub(5,6),16)
    r=r+(255-r)*lift; g=g+(255-g)*lift; b=b+(255-b)*lift          -- 提亮
    local y=.299*r+.587*g+.114*b                                   -- 以亮度为轴拉彩度：不改变明暗关系
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
    -- bold 省略时沿用全局 font_bold；显式传 false 可让单处文本不加粗（图标按钮的标签要用）
    local b = (bold==nil) and (self.font_bold and 1 or 0) or (bold and 1 or 0)
    local tags=string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\b%d\\shad0\\1c&H%s&",align or 5,math.floor(x or 0),math.floor(y or 0),font or self.font,math.floor(size or 0),b,ass_color(color_value))
    if border==0 then tags=tags.."\\bord0" else tags=tags..string.format("\\bord%.1f\\3c&H%s&",border or self.text_border,ass_color(self.tokens.color_panel)) end
    if alpha then tags=tags..alpha_tag(alpha) end
    local body=esc(value)
    table.insert(self.ass,tags.."}"..body)
end
function UI:shadow(x,y,w,h,radius,scale) local t=self.tokens; local off=math.floor(t.shadow_offset*(scale or 1)); if off>0 then self:rect(x,y+off,w,h,t.color_panel,t.alpha_shadow,radius,t.shadow_blur or 0) end end
-- 任意方向直线：ASS 没有"画线"图元，`\p1` 只认闭合多边形，所以按线宽把线段展成四边形。
-- 用途：置灰项的删除线 / 斜杠（这两个符号比"压暗"更能一眼读出"不可用"）。
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
    -- 置灰（args.disabled）：不可点、不可聚焦、不着色、不高亮，只留压暗的文字。
    -- ① **fn 置 nil** —— 这是"不可点击"的落实点：core 的 run_button 只调 b.fn，
    --    confirm_focusable 也用 `b.fn` 过滤，所以键盘 Tab 会直接跳过置灰项。
    -- ② 不画任何底色或边框：方框与整体圆角/无框
    --    风格冲突。用"压暗 + 删除线"——单纯压暗在深色面板上
    --    仍像个暗一点的可用项，一条删除线才是通行的"不可用"符号。
    -- ③ tooltip 仍要保留：用户需要知道为什么不能用，所以 tip 原样带出去。
    if args.disabled then
        args = {id=args.id,x=args.x,y=args.y,w=args.w,h=args.h,label=args.label,accent=args.accent,
                tip=args.tip,fn=nil,active=false,hover=false,layer=args.layer,scale=args.scale,
                icon=args.icon,icon_size=args.icon_size,idle=args.idle,disabled=true,
                disable_alpha=(t.alpha_button_disabled or .38)}
    end
    local da = args.disabled and args.disable_alpha or nil
    -- 置灰装饰（disabled_style）画在文字之上：先记下标签的中心与字号，分支画完再统一叠。
    -- 三个分支里标签位置都是"按钮中心"，只有 icon_stack 有图标时标签下沉到 78% 高度。
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
        -- 图标 + 标签上下两行（系统工具栏观感）。两行字号按按钮高自适应：按钮矮时
        -- 同步缩小，任意 button_height 下都不重叠；未提供该按钮图标（或高度实在
        -- 放不下）时退化成单行标签——确认面板 / 片段列表里的按钮就属于这一类。
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
        -- 图标与标签可做差异化：color_icon 覆盖图标色（激活态忽略，用反色文字色保证对比度），
        -- alpha_icon_label 单独压低标签透明度（图标更亮、文字更收敛）
        local icon_fg=(not args.active and t.color_icon~="" and t.color_icon) or fg
        local label_alpha=(t.alpha_icon_label<1) and t.alpha_icon_label or nil
        -- 置灰优先级最高：标签透明度取 disable_alpha（图标同受压），亮色标签的 alpha_icon_label 让位
        if da then
            label_alpha=da
        end
        local label_bold=(t.label_bold==1)
        -- 图标尺寸由 layout_icon_ratio 控制（相对按钮高），标签字号仍由 font_button 控制
        -- 图标尺寸默认 = 按钮高 × layout_icon_ratio；args.icon_size 给定时以它为准。
        -- 用途：主面板"只画图标"时面板高度被压缩，若仍按按钮高算图标会跟着变小，
        -- 显式传入才能保持图标默认尺寸（缩小流程里则按同一比例一起缩）。
        local icon_box=args.icon_size and math.max(1,math.floor(args.icon_size))
            or math.floor(args.h*t.layout_icon_ratio)
        -- 图标 = 字体字形
        if args.icon and args.icon~="" and icon_box>=9 and label_fs>=8 then
            self:text(cx,label == "" and (args.y+args.h*.5) or (args.y+args.h*.33),
                icon_fs,icon_fg,args.icon,5,0,da,t.icon_font,label_bold)
            self:text(cx,args.y+args.h*.78,label_fs,fg,label,5,0,label_alpha,nil,label_bold)
            -- 装饰要压在标签上（不是按钮中心）：图标在上、标签在下
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
    -- 置灰装饰：只压暗在深色面板上容易被读成"暗一点的可用项"，
    -- 所以默认再叠一条删除线。样式由 button_disabled_style 决定：
    --   strike / slash / strike_slash / dim(只压暗)
    -- 纯图标按钮（label 为空）没有文字可划，一律退化成斜杠。
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
    -- 玻璃高光：顶部内沿细亮边，内缩并带小圆角，跟随面板圆角包裹（alpha_panel_highlight=0 时关闭）
    if t.alpha_panel_highlight and t.alpha_panel_highlight>0 and h>=10 then
        local e=math.max(1,math.floor(1.3*scale)); local inset=math.max(2,math.floor(r*.5))
        local hw=w-inset*2
        if hw>=2 then self:rect(x+inset,y+math.max(1,math.floor(scale*.6)),hw,e,t.color_panel_highlight,t.alpha_panel_highlight,math.max(1,math.floor(e*2))) end
    end
end
function UI:timeline_track(x,y,w,h,scale) local t=self.tokens; self:rect(x,y,w,h,t.color_timeline,t.alpha_timeline,math.floor(t.radius_timeline*scale)); self.bounds.timeline={x1=x,y1=y,x2=x+w,y2=y+h} end
-- 统一的菜单浮层表面：variants.menu 三种取值的唯一实现。
-- 各浮层共用同一套表面拼装，同一令牌在不同浮层上渲染一致。
-- alpha/radius 由调用方传 theme.opacity.menu / theme.menu_radius（conf 显式覆盖优先，
-- 回退值已由 apply_ui_tokens 接到 alpha_menu/radius_menu 令牌）。
function UI:menu_panel(x,y,w,h,alpha,radius,scale)
    local t=self.tokens; local v=t.variants.menu
        -- filled：与 UI:panel 同款阴影，跟随令牌菜单透明度/圆角
        self:shadow(x,y,w,h,math.floor(t.radius_menu*scale),scale)
        self:rect(x,y,w,h,t.color_panel,alpha,math.floor(t.radius_menu*scale))
end
-- 统一的"浮动卡片"表面：提示条 / 任务卡 / 悬停气泡共用。
-- 与按钮面板同一套层次语言（填充 + 顶部内沿发丝高光 + 轻投影），但尺寸适配到小卡片：
--   · 阴影 = shadow_offset / shadow_blur / alpha_shadow × layout_card_shadow_ratio
--     （面板那套大偏移大模糊是给大面积用的，直接套到卡片上会糊；shadow_offset=0 时就是纯色平面卡）
--   · 发丝高光 = color_panel_highlight / alpha_panel_highlight
--   · 若把 alpha_panel_highlight 设为 0，改用 1px 亮描边立边界 ——
--     参考设计稿的卡片就是"实底 + 细边 + 几乎无投影"
--   · 透明度与圆角由调用方传（alpha_hint/alpha_job_card 与 radius_tooltip/radius_menu）
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
        -- 无内沿高光时：补 1px 亮描边立边界 —— 颜色跟发丝色，强度走
        -- alpha_card_outline。注意这里**只能**用令牌：面板描边的 deck_border_alpha /
        -- deck_border_color 是 conf 选项而非令牌，读 t.deck_border_* 恒为 nil。
        local ba=tonumber(t.alpha_card_outline) or .16
        if ba>0 and w>4 and h>4 then
            local bc=t.color_panel_highlight or t.color_text
            self:rect(x,y,w,e,bc,ba,0); self:rect(x,y+h-e,w,e,bc,ba,0)
            self:rect(x,y,e,h,bc,ba,0); self:rect(x+w-e,y,e,h,bc,ba,0)
        end
    end
end
-- 提示条（左上浮动卡片）几何：内容驱动的尺寸 + 文本度量，供"定位"与"绘制"共用。
-- 渲染要点：字号/内边距比例/最小宽高/色条宽/紧凑开关全部来自令牌；
-- 单行且 hint_compact=1 时走紧凑 chip（无标题层级）；icons 提供 check/alert/info 时用图标替代色条。
function UI:hint_metrics(p)
    local t=self.tokens; local sc=p.scale
    -- 字号：取 conf 的 action_hint_font_size，但不超过"按钮标签字号 × layout_hint_font_ratio"，
    -- 否则用户在 conf 里调大提示字号后，弹窗会比主面板标签还大（横竖比例都失衡）
    local fs=math.max(1,math.floor(p.opts.action_hint_font_size*sc))
    -- 表面参数：默认与主面板一致（透明度取 alpha_panel、圆角取 deck_corner_radius），
    -- card_match_panel=0 或显式传 p.alpha / p.radius 时才独立指定
    local match_panel=(t.card_match_panel==1)
    local deck_r=tonumber(p.opts.deck_corner_radius) or 14
    local alpha=tonumber(p.alpha) or 0
    if alpha<=0 then
        local fallback=math.max(.90,tonumber(p.theme.opacity and p.theme.opacity.tooltip) or .90)
        -- 跟随面板时给一个更实的下限（card_alpha_floor）：面板大面积可以很透，
        -- 小卡片套同一个透明度会发虚、文字对比度也不够（设计稿的卡片都更实）
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
    -- 内边距：默认按字号比例（下限 10/6px，旧下限 16px 会让"紧缩比例"失效、卡片始终胖一圈）；
    -- 给了 layout_hint_pad_x/y（绝对像素）时优先用它 —— 不随字号漂移（仍乘界面缩放）。
    local pad_x=math.floor((tonumber(t.layout_hint_pad_x) or 0)>0 and t.layout_hint_pad_x*sc
        or math.max(10,p.opts.action_hint_font_size*t.layout_hint_pad_x_ratio)*sc)
    local pad_y=math.floor((tonumber(t.layout_hint_pad_y) or 0)>0 and t.layout_hint_pad_y*sc
        or math.max(6,p.opts.action_hint_font_size*t.layout_hint_pad_y_ratio)*sc)
    if compact then pad_x=math.floor(pad_x*.75); pad_y=math.floor(pad_y*.65) end
    local title_fs=fs; local body_fs=math.max(1,math.floor(fs*.85))
    local line_h=math.floor(title_fs*t.layout_hint_line_ratio)
    local body_h=math.floor(body_fs*t.layout_hint_row_ratio)
    local line_gap=math.floor(p.opts.action_hint_line_gap*sc)
    -- 图标字号：fs 已经乘过 sc，这里只乘比例（曾再乘一次 sc → 图标比文字大一号）
    local icon_size=math.max(10,math.floor(fs*t.layout_hint_icon_ratio)); local icon_gap=math.floor(6*sc)
    local use_icon=(t.hint_icon==1) and (type(p.icon)=="function" or (type(p.icon)=="string" and p.icon~=""))
    local extra=use_icon and (icon_size+icon_gap) or 0
    -- 宽度上限 = 内容自然宽度；唯一的硬边界是"任务卡确实在显示时"不得侵入其右上角地盘
    -- （两者同屏且都在顶部）。任务卡不在屏上时**不做任何预留** —— 否则提示会被稳定地截断在
    -- 一个与内容无关的宽度上，用户视角就是"宽度从来不是自然的"。
    --   预留区宽度 = job_card_max_width（该卡上限宽，按上限预留最安全）+ layout_hint_zone_gap（两卡间距）
    -- 只有当信息确实装不下时才截断（路径类走中间省略）；窗口过窄时用 max_ratio 兜个下限。
    -- 仍然尊重 conf 的 action_hint_max_width（用户自己设的提示最大宽）。
    local edge=math.floor(t.layout_hint_max_edge*sc)
    local reserved=p.reserve_job and math.floor(t.job_card_max_width*sc) or 0
    local zone_gap=reserved>0 and math.floor(t.layout_hint_zone_gap*sc) or 0
    local hard=math.min(p.sw-edge*2-reserved-zone_gap,math.floor(p.opts.action_hint_max_width*sc))
    local max_w=math.max(math.floor(p.sw*t.layout_hint_max_ratio),hard)
    local min_w=math.floor(t.layout_hint_min_w*sc)*(compact and .6 or 1)
    -- 放不下就截断，而不是把卡片撑宽。路径类信息（含盘符或分隔符）保尾部（文件名才是识别点），
    -- 普通文案保头部（"已选择入点："这类动作名在前）
    local avail_text=math.max(24,max_w-pad_x*2-extra)
    local lines={}
    for i,line in ipairs(p.lines) do
        local lfs=(i==1) and title_fs or body_fs
        local out=line
        if p.tw(line,lfs)>avail_text then
            -- 路径类信息（含盘符/分隔符）走中间省略：动作名与文件名都保留；普通文案保头部
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

-- 绘制提示条（x,y 为左上角；几何全部来自 hint_metrics）
function UI:hint_card(x,y,m)
    local theme=m.theme; local sc=m.scale
    local r=math.floor(m.radius*sc)
    self:card(x,y,m.w,m.h,m.alpha,r,sc)
    if m.use_icon then
        -- 图标承担语义色（矢量路径或图标字体字形皆可）
        local ix=x+m.pad_x
        local iy=m.compact and (y+math.floor((m.h-m.icon_size)/2)) or (y+m.pad_y+math.floor((m.line_h-m.icon_size)/2))
        if type(m.icon)=="function" then
            local draw=m.icon(ix,iy,m.icon_size)
            table.insert(self.ass,string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&%s\\p1}%s{\\p0}",ass_color(m.color),alpha_tag(nil),draw))
        else
            self:text(ix+m.icon_size/2,iy+m.icon_size/2,m.icon_size,m.color,m.icon,5,0,nil,m.icon_font)
        end
    else
        -- 无图标时退回左侧色条：默认满高细条，可用 layout_hint_bar_inset/gap 收进
        local t=self.tokens
        local inset=math.floor(t.layout_hint_bar_inset*sc); local bw=math.max(1,math.floor(t.layout_hint_bar_w*sc))
        local gap=math.floor(t.layout_hint_bar_gap*sc)
        self:rect(x+inset,y+inset,bw,math.max(1,m.h-inset*2-gap*2),m.color,1,math.floor(bw/2))
    end
    -- 文本两级：首行标题（加粗、全亮）→ 其余次级（更小字号 + alpha_secondary_text；时间码走等宽）。
    -- 颜色规则随图标能力切换：有语义图标时文本走主色（语义色由图标承担）；无图标时文本保持语义色。
    -- 紧凑 chip（单行）刻意不加粗：体积已经收小，再加粗就是之前"傻大粗"的根因。
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

-- 任务卡宽度固定：同一任务内取"见过的最大需求宽"，只增不减。
-- 右下角的速度 / ETA、脚注的当前段号这些文本每帧都在变，若每帧按内容算宽度，卡片就会一会长一会短。
-- 以 job.started_at 为界（新任务 → 归零重算），所以宽度的变化只可能发生在任务刚开始的头一两帧。
-- lo/hi 分别是 opts.job_card_width（最小宽）与 job_card_max_width（上限）。
-- slot 区分卡片形态（"full" 整卡 / "compact" 收起态小卡）：两种形态各留一份记录，
-- 所以小卡按**自己的自然宽度**算，不会继承整卡那份宽度；但同一形态内仍然只增不减 → 不抖动。
local function hold_job_card_width(self, slot, job, want, lo, hi)
    -- 记在 UI 实例上而不是 job 表上：每帧传进来的 job 是新的表（state.job 每帧重组），
    -- 只有 UI 实例是跨帧存在的；键用 job.started_at，新任务自然归零。
    local key=type(job)=="table" and job.started_at or nil
    self.card_w=self.card_w or {}
    local rec=self.card_w[slot]
    if not rec or rec.key~=key then rec={key=key,w=0}; self.card_w[slot]=rec end
    if rec.w<want then rec.w=want end
    return math.max(lo,math.min(hi,rec.w))
end

-- 任务卡（右上）：三段式（标题行 / 分隔线 / 进度行 / 脚注行），尺寸内容感知。
-- 渲染要点：宽下限取 opts.job_card_width、上限取 job_card_max_width 令牌；透明度取 alpha_job_card（0=跟随菜单）；
-- 进度色取强调色（不再固定 heatmap）；分隔线 alpha 取 alpha_card_separator；脚注等宽 + 次级色。
function UI:job_card_running(p)
    local t=self.tokens; local theme=p.theme; local sc=p.scale
    local tfs=math.floor(t.layout_job_fs*sc); local dfs=math.floor(t.layout_job_detail_fs*sc)
    local pad=math.floor(t.layout_job_pad*sc)          -- 横向内边距 + 距屏幕边
    -- 纵向节奏用卡片专用令牌：面板的 dialog_row_gap(8)+行高比例 1.6/1.9 是给大面板的，
    -- 套到小卡片上会把三段撑得很散（参考设计稿的卡片远比面板紧凑）
    local vpad=math.floor(t.layout_card_row_gap*sc); local gap=vpad
    local title_lh=math.floor(tfs*1.4); local foot_lh=math.floor(dfs*1.5)
    local ph=math.max(4,math.floor(t.layout_job_progress_h*sc)); local sep_h=math.max(1,math.floor(sc))
    local min_w=math.floor(p.opts.job_card_width*sc); local max_w=math.max(min_w,math.floor(t.job_card_max_width*sc))
    -- 表面（透明度/圆角）小卡与整卡共用：与主面板同款表面
    local match_panel=(t.card_match_panel==1)
    local deck_r=tonumber(p.opts.deck_corner_radius) or 14
    local surface_a=(t.alpha_job_card and t.alpha_job_card>0) and t.alpha_job_card
        or (match_panel and math.max(tonumber(theme.deck_alpha) or 0,tonumber(t.card_alpha_floor) or .86) or theme.opacity.menu)
    local surface_r=math.floor((match_panel and deck_r or theme.menu_radius)*sc)
    if p.compact then
        -- 小卡（主面板收起时）：一行「标题 + 状态」。标题自带片段数（如"导出片段 2/3"），右侧是百分比。
        -- 不画分隔线 / 进度条 / 脚注；宽度同样走"固定宽"逻辑，百分比与状态切换也不会让卡片抖。
        local line_h=math.floor(tfs*1.4)
        local pct_w=math.max(p.tw(p.status,tfs),p.tw("100%",tfs))   -- 状态可能是"处理中…"，按较宽者预留
        -- 小卡不吃 job_card_width 下限（那会把"导出 1/1  1%"撑出一大段空白），
        -- 宽度只由自己的内容决定 + 状态格预留；稳定性仍由 hold 保证。
        local cw2=math.min(max_w,pad*2+p.tw(p.title,tfs)+gap+pct_w)
        cw2=hold_job_card_width(self,"compact",p.job,cw2,0,max_w)
        local ch2=vpad*2+line_h
        local cx2=p.sw-cw2-math.floor(t.layout_card_edge*sc); local cy2=math.floor(t.layout_card_edge*sc)
        self:card(cx2,cy2,cw2,ch2,surface_a,surface_r,sc)
        self:text(cx2+pad,cy2+ch2/2,tfs,theme.bgt,p.title,4,0)
        self:text(cx2+cw2-pad,cy2+ch2/2,tfs,theme.success,p.status,6,0)
        return
    end
    -- 右下角是速度 · ETA（"4.8x · 00:00:12"），每帧都在变长变短：按**固定字符数**预留，
    -- 而不是用当前文本宽度，否则卡片宽度会跟着它一起抖。脚注是等宽字体，用最宽的数字 8
    -- 量 20 个字符（实际最长约 16）即可 ≥ 任何实际文本，所以同一任务内宽度恒定。
    local RIGHT_SLOT_CHARS=17
    local right_w=math.max(p.tw(p.right,dfs),p.tw(string.rep("8",RIGHT_SLOT_CHARS),dfs))
    local need=math.max(p.tw(p.title,tfs)+gap+p.tw(p.status,tfs),p.tw(p.detail,dfs)+gap+right_w)
    local cw=math.max(min_w,math.min(max_w,need+pad*2))
    cw=hold_job_card_width(self,"full",p.job,cw,min_w,max_w)   -- 速度/ETA 变长也不会把卡片撑得一跳一跳
    local content_h=vpad*2+title_lh+gap+sep_h+gap+ph+gap+foot_lh
    local ch=math.max(math.floor(p.opts.job_card_height*sc),content_h)
    local cx=p.sw-cw-math.floor(t.layout_card_edge*sc); local cy=math.floor(t.layout_card_edge*sc)
    -- 令牌声明的最小高大于内容时，余量上下平分：否则三段会被顶到上面、底部留一条空带
    local y0=cy+math.floor((ch-content_h)/2)
    if p.variant=="line" then self:rect(cx,cy,cw,1,theme.fg,.8,0)
    elseif p.variant=="console" then self:rect(cx,cy,cw,ch,theme.bg,1,0); self:rect(cx,cy,cw,3,theme.match,1,0)
    else
        -- 默认与主面板同款表面（透明度取 max(alpha_panel, card_alpha_floor)、圆角=deck_corner_radius）
        self:card(cx,cy,cw,ch,surface_a,surface_r,sc)
    end
    -- 卡片内部文字一律 border=0：卡片底色本身提供对比，再叠 text_border(1.2px) 会让小字号发糊
    self:text(cx+pad,y0+vpad+title_lh/2,tfs,theme.bgt,p.title,4,0)
    self:text(cx+cw-pad,y0+vpad+title_lh/2,tfs,theme.success,p.status,6,0)
    local sy=y0+vpad+title_lh+gap
    self:rect(cx+pad,sy,cw-pad*2,sep_h,theme.fg,t.alpha_card_separator,0)
    local py=sy+sep_h+gap
    self:rect(cx+pad,py,cw-pad*2,ph,theme.fg,.12,math.floor(ph/2))
    if p.progress>0 then self:rect(cx+pad,py,math.max(2,(cw-pad*2)*p.progress),ph,theme.match,.96,math.floor(ph/2)) end
    -- 脚注行：左侧按剩余宽度做字符级截断（信息多时不再与右侧速度·ETA 压字）
    local fy=py+ph+gap+foot_lh/2
    local rw=right_w; local avail=cw-pad*2-rw-gap; local left=p.detail
    if avail>0 and p.tw(left,dfs)>avail then
        -- 起点用**字符数**估算，再最多修正 8 轮（避免中文按字节估算把循环拖长）
        local n=math.max(2,math.floor(char_len(left)*avail/math.max(1,p.tw(left,dfs))))
        local guard=0
        left=p.trunc(left,n,true)
        while n>2 and guard<8 and p.tw(left,dfs)>avail do n=n-1; guard=guard+1; left=p.trunc(left,n,true) end
    end
    self:text(cx+pad,fy,dfs,theme.bgt,left,4,0,t.alpha_secondary_text,MONO_FONT)
    self:text(cx+cw-pad,fy,dfs,theme.bgt,p.right,6,0,.74,MONO_FONT)
end

-- 导出完成汇总卡：结果 + 输出目录 + 打开按钮（按钮高度取 dialog_button_height，不再用主面板按钮高）
function UI:job_card_done(p)
    local t=self.tokens; local theme=p.theme; local sc=p.scale
    local tfs=math.floor(t.layout_job_fs*sc); local dfs=math.floor(t.layout_job_detail_fs*sc)
    local pad=math.floor(t.layout_job_pad*sc)
    local vpad=math.floor(t.layout_card_row_gap*sc); local gap=vpad
    local title_lh=math.floor(tfs*1.4)
    local btnh=math.floor(t.dialog_button_height*sc); local btnw=0   -- 无底部按钮：宽度全留给输出路径文本
    local foot_lh=math.max(btnh,math.floor(dfs*1.5))
    local min_w=math.floor(p.opts.job_card_width*sc); local max_w=math.max(min_w,math.floor(t.job_card_max_width*sc))
    local dir=p.trunc(p.dir,34,true)
    local need=math.max(p.tw(p.title,tfs)+gap+p.tw(p.status,tfs),p.tw(p.confirm_output:format(dir),dfs)+gap+btnw)
    local cw=math.max(min_w,math.min(max_w,need+pad*2))
    -- 完成卡沿用同一任务记下的宽度：导出中 → 完成时不会突然缩窄/变宽
    cw=hold_job_card_width(self,"full",p.job,cw,min_w,max_w)
    local content_h=vpad*2+title_lh+gap+foot_lh
    local ch=math.max(math.floor(p.opts.job_card_height*sc),content_h)
    local cx=p.sw-cw-math.floor(t.layout_card_edge*sc); local cy=math.floor(t.layout_card_edge*sc)
    local y0=cy+math.floor((ch-content_h)/2)
    if p.variant=="line" then self:rect(cx,cy,cw,1,theme.fg,.8,0)
    elseif p.variant=="console" then self:rect(cx,cy,cw,ch,theme.bg,1,0); self:rect(cx,cy,cw,3,theme.success,1,0)
    else
        -- 与运行中任务卡同一套表面规则（默认跟随主面板，含 card_alpha_floor 下限）
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
    -- 「打开输出目录」按钮已移除（点了不生效）：相关信息保留为上面那行输出路径文本。
    -- 需要该功能时仍可用脚本消息 quick_cut open_output_directory（见 core 的同名函数，带提示与日志）。k})
end
function UI:tokens_for_core() return self.tokens end
function UI:regions() return self.bounds end

-- ============================================================================
-- 完整渲染器
-- core 提供状态与回调；本模块负责全部布局与 ASS 输出。
-- ============================================================================

-- 裁剪工具条的几何（设计像素 @720p，乘 OSD 缩放 s）。**真源就在这里**：
-- crop.lua 计算"裁剪框启动高度"时要给工具条让位，通过 deps.crop_panel_height 取这里的同一份数值，
-- 避免两边各写一套数字（改了高度却忘了改上限，工具条就会重新压住默认裁剪框）。
local CROP_PANEL = {row_h = 19, ratio_w = 48, gap = 4, pad_x = 8, pad_y = 6, row_gap = 5}
function UI.crop_panel_height(s)
    s = tonumber(s) or 1
    return math.floor(CROP_PANEL.row_h * s) * 2
        + math.floor(CROP_PANEL.row_gap * s)
        + math.floor(CROP_PANEL.pad_y * s) * 2
end

-- 主面板三段式形态：
--   full    完整标签放得下      → 面板原样
--   compact 一枚标签都留不下    → 只画图标：面板**高度压缩**、时间轴长提示同步隐藏；
--                                按钮宽改为"图标 + 留白"，图标尺寸**保持默认**（显式 icon_size）
--   shrink  compact 后仍放不下  → 进入缩小流程：按钮高与图标按同一比例缩（下限 layout_deck_min_scale）
-- 独立成模块级函数的原因：UI:render 的局部变量接近 Lua 的 200 上限，写进去会编译失败
-- （too many local variables … near 'do'）。
-- 标签取舍用渲染器同一把尺子 text_width 量实宽：完整标签 → 短标签（b[9]）→ 只画图标。
-- 非主面板按钮的"文本 / 图标"取舍：
--   文本放得下 ⇒ **只显示文本**（不画图标）；
--   放不下     ⇒ **退化为只画图标**（文本留空，完整说明仍在 tooltip 里）。
-- 与主面板的区别：主面板是"图标 + 文本"两层（图标常在，只收文本）；
-- 非主面板是二选一（有文本就不画图标）。
-- 尺子与主面板一致：text_width 量标签实宽 + 固定内边距。
-- ui_layout_panel_icon=0 可整体关掉这种退化（永远只显示文本）。
-- 行标题在窄面板下的退化：放不下整条标题时用**标题首字**代替。
-- 首字用 truncate_chars 取（UTF-8 安全），例如 编码格式 → 编、附加处理 → 附。
local function panel_title(text_width,truncate_chars,label,bw,fs,pad)
    if text_width(label,fs)+pad <= bw then return label end
    return truncate_chars(label,1,false)
end

-- 长文本按可用宽度**自动换行**：逐字符（UTF-8 安全）累加、量实宽，
-- 返回行数组；调用方逐行 text()，并按行数增加面板高度（否则会压到下一行）。
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
        -- 只画图标：按钮只需容纳图标 ⇒ 面板可以变窄（变窄也是面板能变矮的前提）
        local icon_box=math.floor(btn_h*t.layout_icon_ratio)
        local cpad=math.max(2,math.floor((tonumber(t.layout_compact_pad) or 6)*s))
        local cw=icon_box+cpad*2
        local need=#defs*cw+gaps+pad*2
        -- 同比例缩到**刚好放下**：k = available/need，不再设比例下限。
        -- 注意：不要给 k 设比例下限——k 被夹住后按钮不再缩、而面板底色被 panel_w=min(w,…) 夹住 ⇒
        -- 图标会顶出窗口。
        -- 按钮宽也不再用 layout_button_min_w 兜底（那同样会让总宽超过窗口），只保底 1px。
        scale=math.min(1,available/math.max(1,need))
        for i=1,#defs do bw[i]=math.max(1,math.floor(cw*scale)) end
        btn_h_out=math.max(6,math.floor((icon_box+cpad*2)*scale))
    end
    return {labels_full=natural_width<=available,compact=compact,scale=scale,btn_h=btn_h_out,bw=bw,label=label}
end

-- 行标题：左边一个图标 + 右边标题文本。
-- 做成方法的原因：UI:render 的局部变量已到 Lua 200 上限，写成本地函数会编译失败。
-- 图标来源：字体模式给的是字形串（走 icon_font 文本绘制）；
-- 也可以是绘制函数（走 \p1 路径，和 UI:button 里同一套写法）。
-- 没给图标时行为与以前完全一致（纯文本 ⇒ 零风险回退）。
-- 参数行图标：设计源名与参数 id 同名时直接取；
-- 不同名的在这张表里手工对应（config 的参数 id → 设计源名）。
local PARAM_ICON_ALIAS = {
    audio_channels    = "channels",      -- 声道
    audio_sample_rate = "sample_rate",   -- 采样率
    resolution        = "size",          -- 尺寸/分辨率
    faststart         = "fast_start",    -- 快速启动
    smart_cut         = "auto_fix",      -- 消除切点偏移（魔棒）
}
-- 返回该参数的图标（字形串或绘制函数）；没有对应设计源时返回 nil ⇒ 行为与以前一致
local function param_icon(t,id)
    if not id or not t.icons then return nil end
    return t.icons[PARAM_ICON_ALIAS[id] or id]
end

function UI:row_title(text_width,truncate_chars,x,y,fs,color,icon,label,bw,pad,icon_font,bold,icon_only)
    -- icon_only：面板级"图标态"（窄尺寸）时**只留图标、丢掉文本**，
    -- 与 Tabs / 输出方式 / 模式那几枚按钮同一个 pico 判定 ⇒ 同面板完全同步
    -- 新增的行标题/参数图标必须与面板级图标态同步
    -- 逐项退化：面板还没进图标态，但**本行/本格的标签放不下** ⇒
    -- 本项改用图标（不再画被截断的文本）。有图标才退化；没有图标时保持原来的截断行为。
    local has_icon=(type(icon)=="string" and icon~="")
    if (not icon_only) and has_icon and label~="" and text_width(label,fs)+pad > bw then
        icon_only=true
    end
    if icon_only then label="" end
    local icon_box=math.floor(fs*1.25)          -- 图标视觉尺寸：略大于标题字号
    local gap=math.floor(fs*0.5)
    local tx=x
    -- **默认纯文本**；面板级图标态、或本项放不下时才显示图标
    -- （面板级图标态优先，其次逐项退化）
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
    local L=ctx.L
    -- 从主面板绑定表取动作主键：提示文案中的键名与 conf 改绑联动
    local function key_of(action)
        for _, b in ipairs(ctx.key_help_main or {}) do
            if b[2] == action then return b[1] end
        end
        return "?"
    end
    local text_width=ctx.text_width
    local format_time=ctx.format_time
    local truncate_chars=ctx.truncate_chars
    -- 于是「波形」按钮的 fn=nil —— 点击毫无反应，而键盘/动作通道（core 的局部函数）正常。
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
    -- 窗口尺寸通常只改变可用横向空间。注意：不要"窗口小于最小视口就整体
    -- 等比缩小"——那会把图标与文字一起缩掉（竖屏 640x1280 缩到 0.5，图标明显变小）。
    -- 现在默认不缩（layout_viewport_min_fit=1）：主面板按**实际可用宽度**自适应
    -- （natural_width>available 时 fit 收缩 + 放不下的标签只画图标 + 最小按钮宽兜底 +
    -- panel_w 夹在窗口内），所以窄窗也不会被裁切，而图标始终是默认尺寸。
    local base_s=mp.get_property_bool("fullscreen") and theme.scale_fs or theme.scale
    local vfit=math.min(1, w/math.max(1,t.min_viewport_w or 1280), h/math.max(1,t.min_viewport_h or 720))
    -- 窄视口（如竖屏 640x1280）整体缩到 0.5 会让图标与文字都小到看不清
    -- （面板比例被缩小、图标没保持默认尺寸）。所以改为**有下限**：
    -- 只缩到 layout_viewport_min_fit（默认 1 = 不缩；调小（如 0.8）才允许缩到 0.8），
    -- 横向不够的部分交给"仅图标 + 最小按钮宽"适配。
    vfit=math.max(vfit, tonumber(t.layout_viewport_min_fit) or 1)
    -- 极窄地板：窗口窄于 layout_narrow_floor 才**整面板等比缩小**。
    -- 这一档窗口（~355px）会出现"单列重排留大片空白 + 底部按钮互相压住、预设点不到"，
    -- 与其继续逐项雕琢，不如整体缩下去（一套已验证的路径）。地板及以上不缩：图标/文字默认尺寸
    -- 令牌不在 LIMITS 里（拿不到那里的越界告警），所以这里自己兜：配错就按默认值走并**告警一次**；
    -- 标志挂在 tokens 上（它每帧复用），省得为一个提示新增 upvalue。
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
    -- 把本帧的缩放系数暴露给 crop.lua（deps.ui_scale）：
    -- 裁剪启动带要按**同一套**缩放算工具条高/标签高/间距，否则两边差一个系数，
    -- 框底会压到工具条上 ⇒ 工具条自动隐藏（21:9 下的现象）。
    state.ui_scale=s
    local radius=math.floor(theme.radius*s+.5); local ass={}; buttons={}
    local font=theme.font or mp.get_property("options/osd-font","sans-serif")
    self:begin(ass,font,opts.font_bold,theme.text_border*s)
    local function rect(x,y,rw,rh,color,alpha,r) self:rect(x,y,rw,rh,color,alpha,r or radius) end
    local function text(x,y,fs,color,value,align,border,alpha,font) self:text(x,y,fs,color,value,align,border,alpha,font) end
    -- icon_size：可选，显式指定图标尺寸（主面板"只画图标"时保持默认图标大小）
    local function button(id,x,y,bw,bh,label,accent,tip,fn,active,layer,icon,icon_size,disabled)
        local hit=self:button({id=id,x=x,y=y,w=bw,h=bh,label=label,accent=accent,tip=tip,fn=fn,active=active,hover=ctx.hovered_id==id or state.confirm_focus==id or state.flash_id==id,layer=layer,scale=s,icon=icon,icon_size=icon_size,idle=self.tokens.alpha_button_idle_deck,disabled=disabled})
        table.insert(buttons,hit)
    end
    -- 裁剪编辑模式默认隐藏主面板与时间轴（state.hud_hidden），可用裁剪键位（默认 H）呼出，
    -- 退出编辑自动恢复。其他浮层（任务卡/操作提示/裁剪菜单/面板）不受影响。
    local hud_visible = not state.crop_editing or not state.hud_hidden
    -- 主剪辑台可单独收起按钮面板（state.deck_hidden）：只影响按钮面板，
    -- 时间轴、键位与鼠标拖动都保留（躲开画面遮挡，但仍能看时间轴、继续标点）。
    -- 模态浮层（片段列表 / 导出确认 / 键位速查）打开时收起按钮面板，避免与浮层叠加
    local deck_visible = hud_visible and not state.deck_hidden
        and not state.modal and not state.confirm_action and not state.help

    local timeline_h=math.floor(opts.timeline_height*s)
    local btn_h=math.floor(opts.button_height*s)
    local timeline_margin_bottom=math.floor(opts.deck_margin_bottom*s)
    local inset=math.floor(opts.timeline_inner_margin*s)
    -- 按钮面板收起（state.deck_hidden）时时间轴改"贴底通条"：与窗口同宽、贴到窗口底部、状态行让位取消，
    -- 高度压到"够看出片段与播放位置"的程度（≈播放头标记的高度）。
    -- 依据：收起按钮面板后的操作必然走快捷键（要执行鼠标操作自然会先展开面板），
    -- 此时时间轴只需作为细长进度条存在，不再需要与按钮面板对齐成一条浮动轨道。
    -- 默认留白 0（想要留白就把 layout_timeline_collapsed_margin_* 调大）。
    if state.deck_hidden then
        inset=math.floor(t.layout_timeline_collapsed_margin_x*s)
        timeline_margin_bottom=math.floor(t.layout_timeline_collapsed_margin_bottom*s)
        -- 高度 = 展开态高度 × layout_timeline_collapsed_h_ratio（默认 .25），只留"一条线"：
        -- 收起态不再画时间数值/说明文本/刻度文字（见下方各处 state.deck_hidden 门控），
        -- 因此不需要为文字留高度，下限 7px 只为保证片段色块仍可见。
        timeline_h=math.max(math.floor(timeline_h*(tonumber(t.layout_timeline_collapsed_h_ratio) or .25)),
            math.floor(7*s))
    end
    -- 边界时间码那一行的高度：开关打开且未收起时才留（收起态是贴底细条，不画文字）
    local bound_h=0
    if t.timeline_boundaries==1 and not state.deck_hidden then
        bound_h=math.floor((tonumber(t.layout_timeline_time_fs) or 11)*s*1.5)
    end
    local bar_y=h-timeline_margin_bottom-timeline_h-bound_h
    local bar_x=inset; local bar_w=math.max(1,w-inset*2)
    -- 命中区含时间码那一行：点它同样能跳转（视觉上它属于时间轴）
timeline_bounds={x1=bar_x,y1=bar_y,x2=bar_x+bar_w,y2=bar_y+timeline_h+bound_h}
    if opts.show_crop_frame and ctx.crop_is_active(opts) then
        local crop=ctx.crop_rect(); local sr=ctx.crop_to_screen_rect(crop); local vr=ctx.displayed_video_rect()
        if sr and vr then
            local mask_alpha=state.crop_editing and opts.crop_edit_mask_alpha or opts.crop_preview_mask_alpha
            -- 掩膜范围用**整个 OSD（窗口）**，而不是 ctx.displayed_video_rect()：后者来自 osd-dimensions
            -- 的 mt/mb/ml/mr（窗口标题栏、别的脚本的底栏都会参与），它的下边界一旦偏小，
            -- 底部那条带子的高度 (vr.y2-sr.y2) 就被夹成 0 → 裁剪框底线以下不压暗。
            -- 用窗口矩形 + 把裁剪框夹进来，四条带子必然铺满"窗口减去裁剪框"，多压到的只是黑边/面板下方。
            local mr={x1=0,y1=0,x2=w,y2=h}
            local cy1=math.max(mr.y1,math.min(sr.y1,mr.y2))
            local cy2=math.max(mr.y1,math.min(sr.y2,mr.y2))
            local cx1=math.max(mr.x1,math.min(sr.x1,mr.x2))
            local cx2=math.max(mr.x1,math.min(sr.x2,mr.x2))
            -- 边界**朝裁剪框内取整**：sr 常有小数（例 805.55），libass 按整数格绘制时那条半像素边界
            -- 会以"部分覆盖"呈现 → 露出一行/列未压暗的原画面，看起来就是裁剪框某条边延伸出亮线
            -- （跟着框走）。取整后边界落在整数格上，最多多盖 1px（肉眼不可见），边界不再有半覆盖。
            local yt=math.floor(cy1+1e-6)     -- 上带子的下沿
            local yb=math.floor(cy2+1e-6)     -- 下带子的上沿
            local xl=math.floor(cx1+1e-6)     -- 左带子的右沿
            local xr=math.floor(cx2+1e-6)     -- 右带子的左沿
            rect(mr.x1,mr.y1,mr.x2-mr.x1,math.max(0,yt-mr.y1),theme.crop_mask,mask_alpha,0)         -- 上
            rect(mr.x1,yb,mr.x2-mr.x1,math.max(0,mr.y2-yb),theme.crop_mask,mask_alpha,0)             -- 下
            rect(mr.x1,yt,math.max(0,xl-mr.x1),math.max(0,yb-yt),theme.crop_mask,mask_alpha,0)       -- 左
            rect(xr,yt,math.max(0,mr.x2-xr),math.max(0,yb-yt),theme.crop_mask,mask_alpha,0)          -- 右
            -- 诊断（数值变化才打一行）：四条带子的实际数值 + 上游几何。用来确认"裁剪框底线以下"是否真有未压暗的缝：
            -- bottom_y 应等于屏幕上的裁剪框下沿，bottom_h 应为正；若 bottom_h=0 说明窗口下边界算错。
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
                -- 先铺一层半透明黑边再压强调色线，任何画面（含纯白/纯黑）上都能读出手柄。
                local function frect(x,y,w,h)
                    local e=math.max(1,math.floor(bw*1.5))
                    rect(x-e,y-e,w+e*2,h+e*2,"000000",.55,0)
                    rect(x,y,w,h,theme.crop_frame,1,0)
                end
                frect(sr.x1,sr.y1,math.max(fw,sr.x2-sr.x1),fw)
                frect(sr.x1,sr.y2-fw,math.max(fw,sr.x2-sr.x1),fw)
                frect(sr.x1,sr.y1,fw,math.max(fw,sr.y2-sr.y1))
                frect(sr.x2-fw,sr.y1,fw,math.max(fw,sr.y2-sr.y1))
                -- 拖拽手柄（四角）：黑描边 + 白底方块 + 强调色内芯，三层保证任何画面上都可见
                local hs=math.max(7,math.floor(t.layout_crop_handle*s)); local hh=math.floor(hs/2)
                local hc=theme.crop_frame
                -- 手柄中心钳进视频区域：裁剪框贴到窗口边（含满幅）时，手柄原本有一半在画面外，
                -- "该边贴边"时才内移，框在中间时保持骑在角上的观感。
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
                -- 四边中点小方块：提示可沿边缩放（同样带描边，贴边时同样内移）
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
            -- 尺寸标签避开裁剪手柄：手柄沿框边/角分布，标签贴边会压住拖动条。
            -- 优先放框外侧（蒙版区）；上方没空间退到下方外侧；满幅时退到框内靠上（仍留一个手柄的间距）。
            local handle_px=math.max(7,math.floor(t.layout_crop_handle*s))
            local clear_px=handle_px+math.floor(label_fs*0.9)
            -- 用户规则：标签居中于「窗口上边 ↔ 裁剪框上边」之间（两侧间距相等）。
            -- 间距下限 = max(deck_margin_bottom, layout_crop_label_gap)：
            -- deck_margin_bottom 默认就是 0，只按它定位等于贴顶 → 必须另设下限。
            -- crop.lua:startup_band 用**同一算式**把框顶压到 gap + 标签高 + gap，两处需一起改。
            local m=math.floor((tonumber(opts.deck_margin_bottom) or 52)*s)
            local gap=math.max(m,math.floor((t.layout_crop_label_gap or 14)*s))
            local half=label_fs/2
            local lo=math.floor(gap+half)                     -- 上边距至少 gap
            local hi=math.floor(sr.y1-gap-half)               -- 到框顶至少 gap
            local label_y=math.min(hi,math.max(lo,math.floor(sr.y1*0.5)))
            if label_y+half>sr.y1-handle_px then label_y=sr.y1-clear_px end
            if label_y-half<0 then label_y=sr.y2+clear_px end
            if label_y+half>vr.y2 then label_y=sr.y1+clear_px end
            text((sr.x1+sr.x2)/2,label_y,label_fs,label_color,state.crop_editing and L("hint.crop_editing",crop.w,crop.h) or L("hint.crop_preview",crop.w,crop.h),5,nil,.94)
        end
    end

    if hud_visible then
    if variants.timeline=="outline" then rect(bar_x,bar_y,bar_w,timeline_h,theme.timeline_bg,.14,2); rect(bar_x,bar_y,bar_w,1,theme.fg,.7,0); rect(bar_x,bar_y+timeline_h-1,bar_w,1,theme.fg,.7,0)
    elseif variants.timeline=="blocks" then rect(bar_x,bar_y,bar_w,timeline_h,theme.timeline_bg,1,0); rect(bar_x,bar_y,bar_w,3,theme.fg,1,0)
    -- 背景条必须与 bar_x/bar_w 同范围，否则视觉边缘（0..w）与时间映射边缘（inset..w-inset）错开，
    -- 会出现"时间轴看似占满宽度、但起止时间却不在两端"的错位
    else
        rect(bar_x,bar_y,bar_w,timeline_h,theme.timeline_bg,theme.opacity.timeline,0)
        -- 对比描边：底色是近黑 + 低透明，压在深色/同色系画面上会糊成一片
        -- （同/近色系下看不清）。上下各压 1px 亮边，
        -- 任何底色下都能看出时间轴的范围；不通吃填充色，保持"压在画面上"的观感。
        rect(bar_x,bar_y,bar_w,1,theme.fg,.45,0)
        rect(bar_x,bar_y+timeline_h-1,bar_w,1,theme.fg,.30,0)
    end

    local duration = mp.get_property_number("duration", 0)
    local cur = mp.get_property_number("time-pos", 0)
    if duration > 0 then
        local tx, ty, tw, th = bar_x, bar_y, bar_w, timeline_h
        -- 波形背景层：showwavespic 预生成的音频包络（列高 0-1），片段区间内以片段色高亮。
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
        -- 重叠检测：保存瞬间只提示一次，这里提供持续可见性（时间轴顶部警示条）
        local overlapping={}
        for oi,a in ipairs(state.segments) do
            for _,b in ipairs(state.segments) do
                if a~=b and a.start_time < b.end_time and b.start_time < a.end_time then overlapping[oi]=true; break end
            end
        end
        -- 编辑中的那一段：它的"新位置/新长度"由下面的草稿范围表示，旧位置那一份要跳过，
        -- 否则同屏会看到"新的范围 + 旧的蓝块"，像把一段拆成了"未添加/已添加"两层。
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
                -- alpha_segment / alpha_segment_disabled / alpha_segment_selected 三个令牌里，
                -- alpha_segment 本来就是内置令牌，一并补上，三档都由它控制。
                local seg_alpha=(seg.enabled~=false) and (t.alpha_segment or .80) or (t.alpha_segment_disabled or .30)
                -- 片段**横向不再内缩**：相邻两段严丝合缝，边界改由下面那条有色分隔线表达。
                -- 旧做法是四周各内缩 1px 留缝，缝里透出时间轴底色（半透明时还透出画面），
                -- 两段相连时会被读成"片段之间的空隙"——这正是要修掉的那个观感。
                -- 纵向内缩与线宽是**两个**令牌（layout_segment_inset_y / layout_segment_divider_w）：
                -- 合成一个时"想加粗分隔线"会连带把片段上下压窄。
                local edge_y=math.max(0,math.floor((tonumber(t.layout_segment_inset_y) or 1)*s))
                -- 分隔线宽：令牌 >0 表示"要这条线"，下限 1px —— 小窗口下 s<1，floor(1*s) 会归零，
                -- 结果是整条分隔线在小窗口里凭空消失（实测 800x450 下 6 条全没）。要关掉请用 alpha=0。
                local div_on=tonumber(t.layout_segment_divider_w) or 1
                local div_w=div_on>0 and math.max(1,math.floor(div_on*s)) or 0
                local gx,gy,gw,gh=bx,ty+edge_y,bw,math.max(1,th-edge_y*2)
                -- variants.timeline 已固化为 solid：旧的 outline / blocks 两条分支不可达，删。
                -- 片段就是一块横平竖直的实心色块（横向不内缩，边界交给上面那条有色分隔线）。
                rect(gx,gy,gw,gh,sc,seg_alpha,0)
                local selected=state.selected_segment_id==seg.id
                -- 选中 = **对应色**（自己的色相）再叠一层（alpha_segment_selected）＝"降低透明度"。
                -- 不换色相：换色相会让"选中了哪一段"被读成"这一段是另一种东西"。
                if selected then
                    -- 选中 = **同色相提明度**（不是同色加浓度）+ 下面那圈加宽的亮边。
                    -- 试过只叠同色：填充本来就接近不透明，叠完几乎看不出差别；提明度才立得住。
                    local sel_col=(t.color_selection and t.color_selection~="" and t.color_selection)
                                  or accent_hex(sc,.30,1.15)
                    rect(gx,gy,gw,gh,sel_col,t.alpha_segment_selected or .92,0)
                end
                -- 片段边线：**左右两侧都画**（只画右缘会让首尾片段看起来"只有右边有边"，不对称）。
                -- 默认**跟随片段自身色相且不透明**；选中时这条边**加宽**（layout_selected_border）
                -- 并补上上下两条同色细边，形成一个完整边框。alpha=0 或 div_w=0 则不画。
                -- 注意：两端"标记杆"只属于正在编辑的那一段（见下面的入/出点绘制），已添加的片段不画。
                -- 该侧是否与**另一个片段**相接/重叠：只有这种情况下才画边线。
                -- 朝向"无片段区域"（间隙、时间轴两端、视频首尾）的一侧不画线，让片段干净地收住 ——
                -- 否则空区里会凭空多出一条竖线，看起来像另一种边界。
                local function joined_at(time)
                    for _,o in ipairs(state.segments) do
                        if o~=seg and time>=o.start_time and time<=o.end_time then return true end
                    end
                    return false
                end
                if variants.timeline=="solid" and div_w>0 and (tonumber(t.alpha_segment_divider) or 0)>0 then
                    local dc=(t.color_segment_divider and t.color_segment_divider~="" and t.color_segment_divider) or sc
                    -- 收起态细条只有 10px 高，加宽的边会吃掉近一半，退回到 div_w
                    local ew=div_w; local edge_col=dc
                    if selected and not state.deck_hidden then
                        ew=math.max(div_w,math.floor((t.layout_selected_border or 3)*s))
                        edge_col=accent_hex(dc,.48,1.25)  -- 比提亮后的填充再亮一档，边框才不会糊进填充
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
                -- 重叠警示条：与选中高亮并存，提示存在时间区间冲突
                if overlapping[i] then rect(gx,gy,gw,math.max(2,math.floor(s)),theme.error,.95,0) end
                -- 收起态不画片段序号：细条放不下 15px 字，它属于"读时间"的信息
                if bw>16 and not state.deck_hidden then text(bx+bw/2,ty+th/2,math.floor(t.layout_timeline_label_fs*s),selected and theme.bg or theme.fgt,tostring(i),5,0) end
            end
        end
        -- 时间刻度（timeline_ruler=1 时）：画在片段层之上、选区/播放头之下。
        -- 间隔取预设整档序列（1/2/5 为主，含 15/900 这类过渡档）中"像素间距不小于 min_px"的最小档；
        -- 文本走默认描边，压在任何色块上都可读。
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
                    -- 末位刻度贴近右缘时标签会画出时间轴（且与总时长文本重叠），此时只保留刻度线
                    if rx+math.floor(3*s)+text_width(tl,rfs)<=tx+tw-math.floor(t.layout_timeline_time_pad*s) then
                        text(rx+math.floor(3*s),ty+math.floor(math.max(tickh,rfs)/2),rfs,theme.fg,tl,4,nil,.55,MONO_FONT)
                    end
                    k=k+1
                end
            end
        end
        -- 入点/出点只呈现"被明确标记过"的那一端：未标记的端点不再推断为当前播放位置
        -- 或视频首尾，否则拖动播放位置会让选区另一端跟着跑。
        if state.start_time ~= nil or state.end_time ~= nil then
            local marked_start = state.start_time ~= nil
            local marked_end = state.end_time ~= nil
            local start_active=state.active_handle=="start"; local end_active=state.active_handle=="end"
            -- 草稿范围的颜色/浓度分两种情形：
            --  · 新标的一段（未添加）→ 橙色 + 薄填充（alpha_pending），表示"还没存下来"；
            --  · 编辑**已添加**的片段 → 用它自己的颜色与浓度，看起来就是那一段，只是两端多了标记杆。
            --    否则会被误读成"又标出一段新的未添加内容"（并出现橙/蓝两层）。
            local dcol=theme.pending; local dalpha=t.alpha_pending or .35
            if editing_id then
                local off=(editing_seg and editing_seg.enabled==false)
                dcol=off and theme.timeline_disabled or theme.timeline_segment
                dalpha=off and (t.alpha_segment_disabled or .25) or (t.alpha_segment or .7)
            end
            local n = draft_n      -- 片段循环前已算好（编辑态要靠它决定是否跳过旧位置那一份）
            if n then
                -- 两端均已标记：绘制完整选区 + 两侧手柄
                local bx = tx + math.floor(n.start_time / duration * tw)
                local bw = math.max(4, math.floor((n.end_time - n.start_time) / duration * tw))
                -- 填充：新标的一段是橙色薄雾（能透出下面的画面/片段色）；编辑态则与那一段同色同浓度
                rect(bx,ty,bw,th,dcol,dalpha,0)
                -- 两端都确定（都被标记过）时，两侧端点**一并**画成可拖的杆：都 5px、都带抓握标记，
                -- 不再只强调"当前激活"的那一端 —— 端点既然确定，两边都该能一眼看到并直接抓。
                -- （start_active / end_active 仍决定键盘调整作用于哪一端，只是不再影响粗细。）
                local sw=5; local ew=5
                -- 收起态细条不再让手柄上下外扩 3px：10px 条里 th+6=16px 会戳出条外，像画歪了
                local oy=(state.deck_hidden and ty) or (ty-3); local oh=(state.deck_hidden and th) or (th+6)
                -- 两端标记杆：与它所属的那一段**同色**、且**不透明**。
                -- 只有"正在编辑/正在标"的这一段才画杆，其它已添加片段不画。
                rect(bx-math.floor(sw/2),oy,sw,oh,dcol,1,1)
                rect(bx+bw-math.floor(ew/2),oy,ew,oh,dcol,1,1)
                rect(bx-5,ty-5,10,3,dcol,1,1)
                rect(bx+bw-5,ty-5,10,3,dcol,1,1)
                -- 选区实时时长徽标：调整入出点时无需心算（收起态是细条，不画文字）
                if not state.deck_hidden then
                    text(bx+bw/2, ty-8, math.floor(t.layout_timeline_time_fs*s), theme.fg, format_time(n.end_time-n.start_time), 5, 0, .95, MONO_FONT)
                end
                -- 空间判定按标签实际文本宽度算（中文"入点/出点"比 IN/OUT 宽），放不下就不画
            else
                -- 只标记了一端：仅画该端的竖线标记，不铺选区、不猜测另一端位置
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
        if state.deck_hidden then
            -- 收起态：进度就是一条线（不画 ◆/●/▼ 字形，它们在 10px 细条上会溢出）
            rect(play_x-1,ty,3,th,theme.timeline_playhead,1,0)
        elseif variants.playhead=="dot" then rect(play_x-2,ty-4,4,th+8,theme.timeline_playhead,1,0); text(play_x,ty+th/2,math.floor(opts.playhead_diamond_size*s),theme.timeline_playhead,"●",5,1)
        else rect(play_x-1,ty-3,3,th+6,theme.timeline_playhead,1,0); text(play_x,ty+th/2,math.floor(opts.playhead_diamond_size*s),theme.timeline_playhead,"◆",5,1) end
        -- 时间数值（左当前 / 右总长）：收起态的细条不显示
        if not state.deck_hidden then
            local tfs=math.floor(t.layout_timeline_time_fs*s)
            text(tx+math.floor(t.layout_timeline_time_pad*s),ty+th/2,tfs,theme.fg,format_time(cur),4,0,.72,MONO_FONT)
            text(tx+tw-math.floor(t.layout_timeline_time_pad*s),ty+th/2,tfs,theme.fg,format_time(duration),6,0,.58,MONO_FONT)
        end
        -- 片段边界时间码：标在轨道**下方**那一行。取所有片段的 start/end 去重后逐个画，
        -- 相邻标签至少隔 6px 才画（密集片段时宁可少标几个，也别糊成一片）。
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
            for idx=1,#times do
                local bt=times[idx]
                -- 去重：两段相接处同一条边界会出现两次，只标一次；越界值丢弃
                if bt>=0 and bt<=duration and bt>=prev+.01 then
                    prev=bt
                    local rx=tx+math.floor(bt/duration*tw)
                    local label=format_time(bt)
                    local wp=text_width(label,bfs)
                    local lx=math.max(tx,math.min(rx-wp/2,tx+tw-wp))
                    if lx>=prev_end+math.floor(6*s) then
                        text(lx,row_y,bfs,theme.fg,label,4,nil,.55,MONO_FONT)
                        prev_end=lx+wp
                    end
                end
            end
        end
    end
    end -- hud_visible：时间轴

    -- 裁剪比例列表与高亮判定（裁剪窗口里的裁剪面板用；"关闭裁剪"是操作，单独放在第二行）。
    local crop_ratio_items={{"16:9","16:9"},{"9:16","9:16"},{"1:1","1:1"},{"4:3","4:3"},{"3:4","3:4"},{"21:9","21:9"},{L("crop.free"),"free"}}
    local function crop_ratio_active(id)
        return (id=="free" and opts.crop_mode=="custom" and not state.crop_ratio_lock)
            or (opts.crop_mode=="custom" and opts.crop_aspect=="custom" and state.crop_ratio_lock==id)
            or (opts.crop_mode=="aspect" and opts.crop_aspect==id)
    end

    -- 裁剪窗口里的**裁剪面板**：两行紧凑布局 —— 第一行比例、第二行对齐与收尾。
    -- 它是"操作面板"而不是二级菜单，所以刻意用**小尺寸 + 窄间距 + 少留白**：
    -- 按钮 19 设计 px 一档、间距 4、内边距 8/6，且不画标题行；底板比菜单更透（压在画面上不抢视线）。
    -- 位置依次试 左下→左上→右下→右上，取第一个不与裁剪框重叠的；全被占也**始终显示**（退回左下）。
    -- 层名必须用 "main"：core 的点击分发按 layer 白名单过滤，自定义层名会被过滤掉、点击穿透到时间轴。
    -- 裁剪态下"提示卡不要压住裁剪工具条"（小窗口里两者都在底部，必然重叠）：
    -- 所以要拿裁剪框与工具条的位置来避让。这两个变量必须在门控块**之外**声明 ——
    -- 放进 if 块就退化成块内局部，块外引用即 nil（与下面 btn_y 那个坑同一个道理）。
    -- ctx 给的是 {x1,y1,x2,y2}，这里统一成 {x,y,w,h}，免得两处各写一套比较
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
        -- 分组竖线：与主面板的分组分隔线**同一套令牌**（颜色/透明度/线宽/两端留白）。
        local dwid=math.max(1,math.floor(t.layout_group_divider_w*s))
        local dpad=math.floor(t.layout_group_divider_pad*s)
        local gmgap=math.max(mg*2,math.floor(dpad*1.5))
        -- 两行都按**类型**分组：组内等宽按钮、组间一条竖线。
        -- 每行再各自按内容宽度**居中** —— 之前两行都从左边起排，第二行右边会空一块。
        local row1={}
        for i,it in ipairs(crop_ratio_items) do
            if i==#crop_ratio_items then row1[#row1+1]={divider=true} end   -- 比例 ｜ 自由
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
            {divider=true},                                                 -- 对齐 ｜ 尺寸与收尾
            {id="cropbar_size",label=L("crop.size"),accent=theme.match,tip=L("crop.size_tip"),
                fn=function() if ctx.crop_size_input then ctx.crop_size_input() end end},
            -- 「取消」与「关闭」是同一件事（都把画面裁剪整个移除，见 crop.lua 的 cancel_crop_editor
            -- 与 select_preset("none")），所以只留一个：语义跟 Q 键一致，提示里写明后果。
            {id="cropbar_cancel",label=L("button.cancel"),accent=theme.error,tip=L("crop.cancel_tip"),
                fn=function() if ctx.crop_cancel then ctx.crop_cancel() end end},
            {id="cropbar_done",label=L("crop.done"),accent=theme.success,tip=L("crop.done_tip"),
                fn=function() if ctx.crop_done then ctx.crop_done() end end},
        }
        -- 行宽 = 各格宽度 + 格间间距（紧邻竖线的位置用更大的组间距）
        local function row_w(row)
            local total=0
            for i,e in ipairs(row) do
                total=total+(e.divider and dwid or rw)
                if i>1 then total=total+((e.divider or row[i-1].divider) and gmgap or mg) end
            end
            return total
        end
        local pw=math.max(row_w(row1),row_w(row2))+padx*2
        -- 窗口过窄：与主面板同一套做法（夹到 w-12*s 内）——等比缩小按钮宽/间距后重算行宽。
        -- 注意：不要给这里设比例下限——窗口比 .7 倍还窄时它会
        -- **超出窗口**（与主面板"绝不超出窗口"的标准冲突）⇒ 去掉下限，一路缩到刚好放下。
        local edge=math.floor(12*s)
        if pw > w-edge*2 then
            local fit=math.min(1,(w-edge*2)/pw)
            rw=math.floor(rw*fit); mg=math.max(1,math.floor(mg*fit))
            gmgap=math.max(2,math.floor(gmgap*fit)); dwid=math.max(1,math.floor(dwid*fit))
            padx=math.max(2,math.floor(padx*fit))
            pw=math.max(row_w(row1),row_w(row2))+padx*2
        end
        local ph=btnh*2+rowgap+pady*2
        -- 位置固定：水平居中、贴底（可预期，不再到处找地方）。clamp 防窄窗口跑出屏幕。
        local px=math.max(0,math.floor((w-pw)/2))
        local py=h-math.floor(opts.deck_margin_bottom*s)-ph
        -- 自动隐藏：工具条与裁剪框相交（含完全落在框内）。
        -- 手动收起（h）与自动隐藏是"或"关系；pin 可压过自动隐藏，避免框一大就再也叫不出工具条。
        -- （不做"拖动中隐藏"：与相交判定重复，且拖动时原本就在让位）
        local auto_hide=false
        local fr=crop_frame_rect
        if fr then
            local ox=math.min(px+pw,fr.x+fr.w)-math.max(px,fr.x)
            local oy=math.min(py+ph,fr.y+fr.h)-math.max(py,fr.y)
            if ox>0 and oy>0 then auto_hide=true end
        end
        -- pinned 只在"确实相交"期间有意义：一旦不再相交就自动解除，
        -- 这样"手动呼出后把框挪开、再压回来"仍然会正常自动让位（否则 pin 会永久失活让位能力）
        if state.crop_panel_pinned and not auto_hide then state.crop_panel_pinned=false end
        if state.crop_panel_pinned or (not state.crop_panel_hidden and not auto_hide) then
            -- 底板更透：菜单透明度打 6 折（下限 .45），避免一整块实色压在画面上
            local palpha=math.max(.45,(tonumber(theme.opacity.menu) or .88)*.6)
            self:menu_panel(px,py,pw,ph,palpha,math.max(4,math.floor(t.radius_menu*s*.7)),s)
            -- 一行：从左起排，首个格子的起点按"该行宽度在面板里居中"算出来。
            local function draw_row(row,y,rowy)
                local x=px+math.floor((pw-row_w(row))/2)
                for i,e in ipairs(row) do
                    if e.divider then
                        -- 竖线：上下只留 dpad/4（效果图里那根竖线是接近整行高的，留太多变成一个小短横）
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
            -- 两行之间一条横向细线：把"选比例"与"执行操作"分开。alpha_group_divider=0 时不画。
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
    -- 主面板形态（deck 块内算好，块之后的时间轴提示也要用；只占 1 个局部）
    --   .labels_full 完整标签放得下（false ⇒ 标签被收起 ⇒ 时间轴长提示同步隐藏）
    --   .compact     已进入"只画图标"紧凑态（面板高度压缩）
    --   .scale       缩小流程比例（≤1；.btn_h 已含它）
    --   .btn_h/.bw/.label  实际按钮高、每钮实际宽与实际标签（唯一来源，绘制不再二次判定）
    local deck_shape_data={labels_full=true,compact=false,scale=1,btn_h=btn_h,bw={},label={}}
    if deck_visible then
    -- 独立浮动按钮面板：纯文字、两档等宽、只压缩横向尺寸。
    local gap=math.max(1,math.floor(opts.button_gap*s))
    local group_gap=math.max(gap,math.floor(opts.button_group_gap*s))
    local crop_locked=ctx.crop_is_active(opts)
    if crop_locked then state.accurate_mode=true end
    local uniform_width=math.floor(opts.button_uniform_width*s)
    -- 按操作语义分五组：标记 | 片段 | 剪辑辅助 | 输出 | 会话
    -- 分类依据是"作用对象"：标记组改时间轴、片段组管片段集合、剪辑辅助组服务"剪哪几刀"
    -- （裁剪决定保留哪块画面、波形帮找准切点）、输出组是终点动作、会话组收尾。
    local has_selection = ctx.checked_count() > 0 or state.selected_segment_id ~= nil
    -- 合并按钮的删除态要显示作用数量（勾选多段时"删除 3"比"删除"清楚得多）
    local seg_sel_count = math.max(ctx.checked_count(), state.selected_segment_id ~= nil and 1 or 0)
    -- 没有 ffmpeg 时导出仍可用（mpv 编码模式兜底），但能力缩水：按钮不置灰（点了仍有活干），
    -- 改成"未点亮 + tooltip 说明"。这里**不新增局部**：render 已顶到 LuaJIT 的 200 槽位
    -- 上限（块内局部在 LuaJIT 也不回收），
    -- 所以下面用到的地方一律内联 ctx.ffmpeg_missing()。
    local defs = {
        -- 第 1 组：标记
        -- 入点/出点是"动作"而非"状态"，不点亮。曾尝试按 active_handle（会无故常亮）
        -- 和按"是否已标记"点亮，后者也会让人误以为是状态指示、再操作时别扭。
        -- 标记是否生效由时间轴上的入/出点标记直观呈现，按钮本身保持中性。
        -- 第 9 个元素 = 图标（内置 icons 表里的字形；variants.button="icon_stack" 时才画）
        {"in",uniform_width,L("button.in"),theme.btn["in"],L("tip.in"),ctx.set_start,false,t.icons["in"]},
        {"out",uniform_width,L("button.out"),theme.btn.out,L("tip.out"),ctx.set_end,false,t.icons.out},
        {"split",uniform_width,L("button.split"),theme.btn.split,L("tip.split"),ctx.split_at_playhead,false,t.icons.split},
        -- 第 2 组：片段（添加/删除合并为同一个按钮：无选择=添加、编辑中=保存、有选择=删除）
        -- 删除态必须点亮（active）危险色：否则用户看不出按钮已经变成破坏性动作
        {"ctx.segment_action",uniform_width,
            state.editing_id and L("button.save")
                or (has_selection and (L("button.delete") .. (seg_sel_count > 1 and (" " .. seg_sel_count) or "")) or L("button.add")),
            has_selection and not state.editing_id and theme.btn.del or theme.btn.add,
            state.editing_id and L("tip.save") or (has_selection and L("tip.delete") or L("tip.add")),
            ctx.segment_action, state.editing_id ~= nil or has_selection,
            -- 图标随状态切换，与文案同步（添加 / 删除 / 保存）
            state.editing_id and t.icons.save or (has_selection and t.icons.del or t.icons.add)},
        -- 有选中片段时：这个按钮换成「编辑」（点击=编辑该段，语义与"选中是为了操作它"一致）；
        -- 正在编辑中则**保持「编辑」并高亮（洗白成按下态）**（不换回列表，也不消失），未选中时仍是「片段列表 N」；
        -- 列表仍然随时可用（tip 里带上它当前的主键）
        state.selected_segment_id
            and {"segments",uniform_width,L("button.edit"),
                 theme.btn.seg,
                 state.editing_id and L("tip.editing_in_progress",key_of("add"),key_of("close"))
                     or L("tip.edit_selected",key_of("segments")),
                 ctx.edit_selected_segment,state.editing_id~=nil,t.icons.edit}
            or {"segments",uniform_width,string.format(L("button.segments"),#state.segments),theme.btn.seg,L("tip.segments"),ctx.toggle_segment_list,#state.segments>0,t.icons.segments,
                 -- 第 9 位 = **短标签**（可选）：宽度放不下完整标签时先退到它（先丢数字），
                 -- 再放不下才和其它按钮一样只画图标。图标尺寸两种情况都不变。
                 L("button.segments_short")},
        -- 第 3 组：剪辑辅助（裁剪 = 保留哪块画面；波形 = 找准切点）
        {"crop",uniform_width,L("button.crop"),theme.btn.crop,L("crop.edit_tip"),ctx.open_crop_editor,opts.crop_mode~="none",t.icons.crop},
        {"wave",uniform_width,L("button.wave"),theme.btn.seg,L("tip.wave"),ctx.toggle_waveform,opts.waveform,t.icons.wave},
        -- 第 4 组：输出
        -- 导出类型（视频/音频/动图/图片）与输出方式（分文件/合并）都在确认面板内选择，
        -- 主面板只保留"操作"本身，不承载任何文件类型相关的入口
        {"export",uniform_width,(job.running or job.preparing) and L("button.stop") or L("button.export"),(job.running or job.preparing) and theme.error or theme.btn.cut,
            job.running and L("tip.stop")
                or ((ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and L("hint.mpv_fallback_armed") or L("tip.export")),
            ctx.execute_cut,job.running,job.running and t.icons.stop or t.icons.export},
        -- 第 5 组：会话
        {"reset",uniform_width,state.editing_id and L("button.cancel") or L("button.clear"),theme.btn.rst,state.editing_id and L("tip.cancel_edit") or L("tip.clear"),state.editing_id and function() ctx.cancel_edit(false) end or ctx.clear_marks,state.editing_id~=nil,state.editing_id and t.icons.cancel or t.icons.clear},
        {"exit",uniform_width,L("button.exit"),theme.btn.exit,L("tip.exit"),function() mp.commandv("script-message-to",mp.get_script_name(),"exit_studio_mode") end,false,t.icons.exit},
    }
    -- 分组间隔落在每组的最后一个按钮之后
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
    -- 三段式形态（见文件上方 deck_shape）：full / compact（面板压缩）/ shrink（缩小流程）
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
        -- 阴影：与 self:panel 一致（偏移 + 模糊，跟随面板圆角）
        local soff=math.floor((tk.shadow_offset or 0)*s)
        if soff>0 then self:rect(panel_x,panel_y+soff,panel_w,panel_h,theme.bg,tk.alpha_shadow or 0,cr,tk.shadow_blur or 0) end
        rect(panel_x,panel_y,panel_w,panel_h,theme.bg,theme.deck_alpha,cr)
        -- 玻璃高光：与 self:panel 一致（顶部内沿细亮边，内缩并带小圆角）
        if tk.alpha_panel_highlight and tk.alpha_panel_highlight>0 and panel_h>=10 then
            local e=math.max(1,math.floor(1.3*s)); local inset=math.max(2,math.floor(cr*.5))
            local hw=panel_w-inset*2
            if hw>=2 then rect(panel_x+inset,panel_y+math.max(1,math.floor(s*.6)),hw,e,tk.color_panel_highlight,tk.alpha_panel_highlight,math.max(1,math.floor(e*2))) end
        end
        -- 顶部反光细边：两端内缩并带小圆角，跟随面板圆角包裹
        if opts.deck_border_alpha>0 and panel_w-math.floor(cr*.4)*2>=2 then
            rect(panel_x+math.floor(cr*.4),panel_y+math.max(1,math.floor(edge*.5)),panel_w-math.floor(cr*.4)*2,edge,theme.deck_border,opts.deck_border_alpha,math.max(1,math.floor(edge*2)))
        end
    btn_y=panel_y+panel_pad_y
    -- 预计算按钮布局，按功能分组绘制浅色背景块（仅 floating 面板），让分区更明确
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
                        -- 分组底板：alpha_group_bg=0 时完全不画（只留按钮与分组分隔线）
                        if t.alpha_group_bg>0 then
                            rect(gx,gbg_y,gw,gbg_h,theme.fg,t.alpha_group_bg,math.floor(self.tokens.radius_button*s))
                        end
                        -- 分组间竖分隔线：alpha_group_divider=0 时不画（默认 0，既有取值零影响）
                        if t.alpha_group_divider>0 and i<#defs then
                            -- 下一组的第一个按钮是 boxes[i+1]（当前组末位之后那个），
                            -- 写成 boxes[gstart+1] 会落到"本组第二个按钮"，线就画进组里了
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
        -- 回调缺失守卫：defs 里的回调是"取值引用"（不带括号），漏写 local/ctx 解构时名字退化成
        -- 全局 nil，按钮点了毫无反应却零日志。这里点出来。
        if b[6]==nil then msg.warn("quick_cut: deck button '"..tostring(b[1]).."' has no action (fn=nil); 检查 ctx 解构") end
        -- 宽度与标签都取自 deck_shape_data（唯一来源，避免与形态判定两套逻辑打架）。
        -- layer 传 nil（主面板按钮不需要分层；core 的点击派发要求 layer=="main" 才响应）；
        -- b[8] 是图标，别错位成 layer。compact 态显式给 icon_size ⇒ 面板变矮但图标保持默认尺寸。
        local bw=deck_shape_data.bw[i]
        local label=deck_shape_data.label[i]
        -- 第 10 位 = 置灰标识（没有 ffmpeg 时整类不可用的按钮，如合并导出）：
        -- 按钮照常命中，但不再画成"可按下"的样子，tooltip 直接说明为什么用不了。
        button(b[1],x,btn_y,bw,deck_shape_data.btn_h,label,b[4],b[5],b[6],b[7],nil,b[8],
            deck_shape_data.compact and math.floor(btn_h*t.layout_icon_ratio*deck_shape_data.scale) or nil,
            b[10] == true)
        if i<#defs then x=x+bw+(group_break[b[1]] and fitted_group_gap or fitted_gap) end
    end
    end -- deck_visible：按钮面板

    -- ── 空状态引导（挪到主面板之后绘制）─────────────────────────────────
    -- 空状态引导挪到主面板之后绘制：画在时间轴块里时还不知道主面板会收成什么样。
    -- 主面板标签被收起（labels_full=false）时，这条长提示**同步隐藏**（窄窗里它会挤到
    -- 时间刻度上、也很吵）。主面板因模态/键位速查而隐藏时 labels_full 保持 true ⇒ 行为不变。
    -- 注意：duration 在时间轴块内才是局部，挪到这里会读到 nil（comparison with nil），
    -- 所以就地取一次，不新增局部（render 的局部预算很紧）。
    if (mp.get_property_number("duration", 0) or 0) > 0
        and #state.segments == 0 and state.start_time == nil and state.end_time == nil
        and not state.deck_hidden and hud_visible and deck_shape_data.labels_full then
        text(bar_x+bar_w/2, bar_y+timeline_h/2, math.floor(t.layout_timeline_label_fs*s), theme.fg, L("hint.timeline_empty", key_of("in"), key_of("out"), key_of("add"), key_of("help")), 5, 0, .8)
    end


    -- 主场景顶层：位于按钮之上、菜单与模态窗口之下。
    if state.hover_time and state.hover_x then
        local label=format_time(state.hover_time)
        local fs=math.floor(t.layout_hover_time_fs*s)
        local lw=text_width(label,fs)+math.floor(t.layout_hover_time_pad*s)
        local lx=math.max(4,math.min(w-lw-4,state.hover_x-lw/2))
        local ly=bar_y-math.floor(t.layout_hover_time_gap*s)
        -- 悬停气泡也走浮动卡片表面，圆角/透明度跟随令牌（layout_hover_time_radius 仍是可见令牌）
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
        -- 右下角：速度（无速度时退化为已用时长）；有进度样本时追加按线性外推的剩余时间。
        -- started_at 在 Lua 里 0 是 truthy，故不能用 `or mp.get_time()` 兜底：一旦新增置 running 的
        -- 路径漏赋 started_at，elapsed 会等于 mpv 累计运行时长，ETA 直接荒谬（如"剩余 49:00:00"）
        local started=job.started_at
        if type(started)~="number" or started<=0 then started=mp.get_time() end
        local elapsed=math.max(0,mp.get_time()-started)
        local right_info=job.speed~="" and job.speed or format_time(elapsed)
        if job.progress_samples>0 and progress>0.02 and progress<0.999 then
            -- ETA 只在 2%~99.9% 区间显示：更低时除数过小外推爆炸，更高时剩余已无意义
            local eta=math.max(0,elapsed*(1-progress)/progress)
            right_info=right_info.." · "..L("hint.job_eta",string.format("%02d:%02d:%02d",math.floor(eta/3600),math.floor(eta%3600/60),math.floor(eta%60)))
        end
        -- 绘制提取到 UI:job_card_running（三段式 + 尺寸内容感知 + 脚注宽度预算）：
        -- 这里只准备文案，避免继续推高 render 的局部变量数（已接近 200 上限）
        self:job_card_running{variant=variants.job,theme=theme,scale=s,sw=w,opts=opts,job=job,
            compact=state.deck_hidden or nil,      -- 主面板收起 → 只留"片段数 + 百分比"的小卡
            tw=text_width,trunc=truncate_chars,
            title=title,status=status,progress=progress,detail=detail,right=right_info}
    elseif job.finish_ok and job.finished_at and mp.get_time()-job.finished_at < 15 then
        -- 导出完成汇总卡：结果 + 一键打开输出目录（让"结束"这个体验点是完整的），15 秒后自动消失。
        -- 绘制同样提取到 UI:job_card_done（按钮高改取 dialog_button_height，卡高按内容重算）
        self:job_card_done{variant=variants.job,theme=theme,scale=s,sw=w,opts=opts,job=job,
            tw=text_width,trunc=truncate_chars,
            title=L("hint.job_done_title"),status=L("hint.job_done_stat_short",job.succeeded or 0,job.total or 0),
            dir=job.last_output_dir or "",confirm_output=L("confirm.output")}
    end

    -- 目录选单已移除（功能与按钮一并取消）：相关目录仍可从系统文件管理器直接打开，
    -- 「打开输出目录」在导出完成卡上保留。
    if state.confirm_action then
        rect(0,0,w,h,theme.curtain,theme.opacity.curtain,0)
        local params=ctx.ENCODE_PARAMS or {}
        local t=self.tokens
        -- 参数分两拨：bool 单独成"开关组"（拨动开关，不占 ▾ 格子），其余走网格。
        -- 参数可见性跟模式走（规则见 config.param_visible）：快速=流复制，那一堆"改了才要
        -- 重编码"的参数在快速复制下不生效，显示出来只会让人以为可用。模式在这里内联算出来
        -- （is_merge 在下面才声明，这里用等价表达式），避免新增局部变量。
        -- 只有一个参数、且是列表类型的页（目前只有字幕抽取格式）：不摆网格。
        -- 网格里孤零零一枚格子＋右侧 ▾＋浮层，三层才选一个值，纯浪费。
        -- **必须放在度量之前**：行数决定"要不要整体缩小"，而缩放要影响下面所有由 s 派生的量。
        local inline_spec=(#params==1 and params[1].type=="list") and params[1] or nil
        local psw,pval={},{}
        for _,spec in ipairs(params) do
            if ctx.param_visible and ctx.param_visible(spec, state.export_kind,
                ctx.effective_accurate_mode and ctx.effective_accurate_mode(opts, state.accurate_mode,
                    (state.confirm_action == "merge") and "merge" or "export") or false) == false then
                -- 当前模式下不生效：不显示（容器/快速启动/音频参数/智能切割不在收起之列）
            elseif spec==inline_spec then -- 走下面的内联行，不进网格
            elseif spec.type=="bool" then psw[#psw+1]=spec else pval[#pval+1]=spec end
        end
        local maxcols=math.max(2,math.floor(tonumber(t.layout_confirm_cols) or 4))
        -- ── 整体等比缩放 ────────────────────────────────────────────────
        -- 面板高随参数页行数增长，矮窗口（640×360）里放不下。只把面板高夹到窗口
        -- 内、内部照旧按原尺寸往下画 ⇒ 行与行、行与底部按钮互相压字。
        -- 只缩"行高类"度量同样不行：字号没缩，行距一压就变成文字叠文字。
        -- 这里先按行数粗估总高，超出可用高就把**整个面板的 s** 等比缩小 —— 下面的度量、
        -- 字号、图标、间距全部由 s 派生，一处缩放即整体协调，不会再各自漂移。
        local rows_est=6+math.ceil(#pval/maxcols)+math.ceil(#psw/maxcols)
        local est_h=(t.dialog_row_height+t.dialog_row_gap)*rows_est
            +3*t.dialog_text_line+t.dialog_button_height+t.dialog_padding*2
            +t.dialog_bottom_pad+opts.menu_title_font_size
        -- 注意：这里必须**就地改写外层 s**，不能 `local s=`。
        -- button() 闭包（本函数开头定义）捕获的是外层的 s，用作 self:button 的 scale，
        -- 按钮文字字号 = font_button*那个 s。若这里新建局部 s，则几何/定宽按缩小后的值算、
        -- 文字仍按原 s 画 ⇒ 640×360 下"分片输出/合并输出"这类按钮文字撑出按钮宽、
        -- 相邻两枚互相压字。就地改写让闭包看到同一个 s。
        -- 安全：s 每帧由 base_s*vfit 重算、不跨帧留存；下面 modal/crop 分支互斥，
        -- 不会继承这里的缩小值。
        s=s*math.min(1,(h-24)/math.max(1,est_h*s))
        local dp=math.floor(t.dialog_padding*s)
        local sg=math.floor(t.dialog_section_gap*s)
        local btnh=math.floor(t.dialog_button_height*s)
        local btngap=math.floor(t.dialog_button_gap*s)
        local notegap=math.floor(t.dialog_note_gap*s)
        local lineh=math.floor(t.dialog_text_line*s)
        -- 兜底：行占用高度至少比按钮高 4px（上下各 2px），避免相邻行按钮重叠
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

        -- 文本宽度估算（不依赖绘制层的量宽函数）：CJK/全角算 1 个字宽，其余算 0.55
        local function est_w(v)
            local n=0
            for ch in tostring(v or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do n=n+(#ch==1 and 0.55 or 1) end
            return n
        end
        -- 参数分两拨（inline_spec / psw / pval 已在上面度量前算好，见那段注释）
        -- 列数：先按单元格最小宽决定列数，格子宽再按"内容实际需要"取最大值（不再均分到整列，
        -- 否则短值 mp4/crf 会撑出一条空带，长值反被截断）；超宽时按比例收，由值截断兜底。
        local grid_avail=math.max(mincellw,math.min(w-24,capw)-dp*2-label_w)
        local grid_cols=math.max(1,math.min(maxcols,math.floor((grid_avail+colgap)/(mincellw+colgap))))
        -- 逐列按内容定宽：列宽 = 该列格子需要宽（标签/值取大者）+ 内边距 + 箭头位。
        -- 原来"所有列同一个宽（取全局最宽内容）"会让 mp4/crf/18 这类短值撑出空槽。
        local colw={}
        for j=1,grid_cols do colw[j]=mincellw end
        for i,spec in ipairs(pval) do
            local j=(i-1)%grid_cols+1
            -- +6px 余量：估算按 0.55 字宽算拉丁字符，实测略宽，"H.264 (libx264)" 会差几像素被截断
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
        -- ── 高度预算 ──────────────────────────────────────────────────
        -- 不要用 est_rows 粗估：估偏 ⇒ mh 被 min(h-24,...)
        -- 裁短，内部各行却照旧往下画，「预设参数」压住「取消」、「附加处理」压住下一行
        -- 现在矮窗口由上面的**整体 s 缩放**兜住，
        -- 这里只负责如实求和 —— 每一段画完把 y 往下推，这里按同一加法累加，
        -- 两套算式必须同步，别再让"面板高"与"实际画到哪"各自漂移。
        local grid_h=grid_rows*cellh+math.max(0,grid_rows-1)*cellgap
        local sw_h=(sw_rows>0) and (sw_rows*rowh+math.max(0,sw_rows-1)*cellgap) or 0
        -- 模式切换控件的段宽：两段等宽（取两个标签里较宽者）+ 内边距；整条 = 2 段 + 2px 缝。
        -- 声明在这里是因为下面的面板定宽要用到它（底部操作栏也是定宽依据之一）。
        local seg_w=math.floor(math.max(est_w(L("confirm.mode_fast")),est_w(L("confirm.mode_accurate")))*fs_val)+padx*2
        -- 输出方式行两枚按钮的内容宽度也在定宽之前算：这一行的宽度要并进 need
        local om_w=math.floor(math.max(est_w(L("confirm.out_separate")),est_w(L("confirm.out_merged")))*fs_val)+padx*2
        -- ── 面板级"图标态"同步 ────────────────────────────────────────
        -- 问题：om_w/seg_w 按**文字**算死 ⇒ 窗口收窄时按钮宽不变、行照旧溢出；
        --       且不要按每枚按钮各自的文字宽度判定 ⇒ 会出现"一枚图标一枚文字"的混排。
        -- 现在的规则（与主面板同一标准，但**整面板同步**）：
        --   用几何量判定（不需要字体度量）——"标签列 + 输出方式两枚 + 竖线 + 模式两枚 + 间距"
        --   这一行是面板最宽的行；它放不进可用宽 ⇒ **整面板**按钮一起切图标态，
        --   并且按钮宽**同时收窄**到"图标 + 留白"（不收窄的话行宽不变、照样溢出）。
        local pico_avail=math.min(w-24,capw)-dp*2
        local pico=false      -- 用**短名**（全名放不下）
        local mini=false      -- 连短名都放不下 ⇒ 才用**图标**（链条：全名→短名→图标）
        -- 宽度不够 ⇒ **改用短名**（不切图标：导出面板全程文字）。
        -- 关键：必须同时按短名**重算按钮宽**，否则文字变短了、按钮还占着长名的宽度，整行照样顶出窗口
        if label_w+2*om_w+2*seg_w+math.max(1,math.floor(t.layout_group_divider_w*s))+4*btngap > pico_avail then
            pico=true
            seg_w=math.floor(math.max(est_w(L("confirm.mode_fast_short")),est_w(L("confirm.mode_accurate_short")))*fs_val)+padx*2
            om_w=math.floor(math.max(est_w(L("confirm.out_separate_short")),est_w(L("confirm.out_merged_short")))*fs_val)+padx*2
            -- 标签列也按**短名**收窄：否则"类型/输出/源/格式/附加"贴着左边缘、
            -- 内容却仍从全名（导出类型=4 字）的宽度处开始 ⇒ 中间留出一大条空白
            -- 收窄后 need 随之变小 ⇒ 面板整体也变窄
            label_w=math.floor(math.max(
                est_w(L("confirm.kind_short")),est_w(L("confirm.outmode_short")),
                est_w(L("confirm.source_label_short")),est_w(L("confirm.sec_format_short")),
                est_w(L("confirm.sec_extra_short")))*fs_val)+math.floor(12*s)
            -- 短名也放不下 ⇒ 第三级：图标（按钮宽按图标宽重算，整行才不会顶出窗口）
            if label_w+2*om_w+2*seg_w+math.max(1,math.floor(t.layout_group_divider_w*s))+4*btngap > pico_avail then
                mini=true
                local icw=math.floor(btnh*t.layout_icon_ratio)+2*math.max(2,math.floor((tonumber(t.layout_compact_pad) or 6)*s))
                om_w=icw; seg_w=icw
            end
        end
        -- 面板宽由内容决定（取各段需要的最大值），上限 layout_confirm_width，再受窗口约束
        -- Tab 行现在铺满可用宽度、且文字很短（3-4 字），只按内容下限参与定宽
        -- 底部操作栏（预设 + 模式切换两段 + 取消 + 开始）一并参与定宽，否则窄面板时挤爆
        -- 注意：这里用的 om_w/seg_w 已是**图标态收窄后**的值（见上），所以面板宽会随之变小
        local need=math.max(label_w+#(ctx.EXPORT_KINDS or {})*math.floor(64*s)+(#(ctx.EXPORT_KINDS or {})-1)*btngap,
                            -- 单参数内联行：按每枚下限 64 宽参与定宽（实际铺满可用宽）
                            label_w+(inline_spec and (#inline_spec.values*math.floor(64*s)
                                +math.max(0,#inline_spec.values-1)*btngap) or 0),
                            label_w+grid_w,
                            -- 输出方式行：两枚方式 + 竖线 + 两枚模式 + 4 处 btngap
                            label_w+2*om_w+2*seg_w+math.max(1,math.floor(t.layout_group_divider_w*s))+4*btngap,
                            math.floor(t.layout_confirm_preset_w*s)
                            +math.floor(t.layout_confirm_cancel_w*s)+math.floor(t.layout_confirm_go_w*s)+btngap*2)
        -- 不要设硬下限 460：窗口比 460 还窄时面板会**超出窗口**。用软下限 300（够放标题与按钮行），
        -- 真正决定的是 need ⇒ 图标态下 need 变小、面板随之变窄、始终不超窗口
        local mw=math.min(w-24,capw,math.max(300,need+dp*2))
        -- 底部那两块是只读陈述：状态行（输出/顺序）+ 黄字编码摘要，故 note_h*2。
        -- 源文件行可能因自动换行而变高（下面绘制时按同样算式加高），这里必须同名补进面板高，
        -- 否则换行出来的行会压到"编码格式"那一行上。
        local src_lines=math.max(1,#wrap_text(text_width,fs_val,
            ctx.source_param_text and ctx.source_param_text() or "",mw-dp*2-label_w))
        local avail_h=h-24
        -- 面板高：与下面绘制逐段一一对应地求和（每画完一段把 y 往下推，这里按同一加法累加）。
        -- 矮窗口的超高问题已由上面的整体 s 缩放解决，这里只如实求和 + 兜底夹到可用高；
        -- 两套算式必须同步，别再让"面板高"与"实际画到哪"各自漂移。
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
        -- 光标式排版：每段画完把 y 往下推，与上面 mh 的加法一一对应，不再用一堆绝对偏移
        local y=my+dp
        -- 标题按"这一行的高度盒"居中画：align=4 是垂直居中，直接画在 my+dp 会贴上边，
        -- 顶边留白变成 dp-title_h/2。画在盒子中线，顶边留白就等于左右/底部的 dp。
        text(mx+dp,y+math.floor(title_h/2),math.floor(opts.menu_title_font_size*s),theme.bgt,is_merge and L("confirm.title_merge") or L("confirm.title_export"),4)
        y=y+title_h
        local function hr()
            y=y+sepgap
            rect(mx+dp+math.floor(math.floor(t.layout_group_divider_pad*s)/2),y,
                mw-dp*2-math.floor(t.layout_group_divider_pad*s),math.max(1,math.floor(t.layout_group_divider_w*s)),
                t.color_group_divider,t.alpha_group_divider,math.floor(math.max(1,math.floor(t.layout_group_divider_w*s))/2))
            y=y+hr_h-sepgap
        end
        -- 单元格文字：标签在上（次级色）/ 值在下；超宽按字符截断（按字节切中文会出乱码）。
        -- 可点的格子先调 button() 拿底色/焦点/命中（layer=confirm），再补画两行字与右侧矢量 ▾
        local chev=t.icons.chevron
        -- 单元格：标签（次级色）+ 值。**已修改**（与「原始参数」基线不同，见 config.encode_baseline）时：
        -- 值前一个强调色圆点、值加粗，右侧图标位换成"回退 ⟲"（点它恢复为原始参数的值；
        -- 整格其余部分仍点开下拉）。
        -- 判定放在 ctx（config.param_is_modified），这里只负责画。
        local function cell_text(x0,y0,cw,lab,val,with_chev,spec_id)
            local mod=spec_id~=nil and ctx.encode_param_modified and ctx.encode_param_modified(spec_id) or false
            -- 圆点放**标签行**：放值前面会吃掉值宽度，长值（H.264 (libx264)）立刻被挤到截断。
            local dot=mod and (math.max(3,math.floor(cellh*0.11))+math.floor(3*s)) or 0
            if mod then
                local d=math.max(3,math.floor(cellh*0.11))
                -- 已修改标记：**圆点**（默认不显示图标）
                rect(x0+padx,y0+math.floor(cellh*0.30)-math.floor(d/2),d,d,theme.match,1,math.floor(d/2))
            end
            -- 单元格标签：有设计源就带图标（无图标时 row_title 只画文本，观感不变）
            self:row_title(text_width,truncate_chars,x0+padx+dot,y0+math.floor(cellh*0.30),fs_lab,theme.bgt,
                param_icon(t,spec_id),lab,math.max(8,cw-padx*2-dot),math.floor(4*s),t.icon_font,nil,mini)
            -- 截断阈值要和定宽用同一套估算（est_w 把 CJK 记 1、其余记 .55）：不要按
            -- "每字 0.62 字宽"硬算字符数（比定宽算法更保守，于是 "H.264 (libx264)" 明明列宽够
            -- 却被砍成 "H.264 (libx2…"）。按"需要宽 / 可用宽"的比例折算字符数。
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
                -- 右侧图标位：回退。命中区单独注册，且在整格按钮**之后**注册，
                -- 而点击/悬停都反向遍历（后注册优先），所以点 ⟲ 不会被展开下拉吞掉。
                local box=math.floor(cellh*0.26)
                -- 回退：用文本符号 ⟲（U+27F2）而不是图标字体里的 revert 字形 ——
                -- 图标字形在当前格子尺寸（约 9–11px）下形状分不清。
                -- 主字体走 libass 的 fontconfig 回退，缺字形时也能落到 Segoe UI Symbol；
                -- 字号给到 box*1.35：符号的墨迹比图标字形小一圈，同字号会显得更小。
                self:text(x0+cw-padx-box+box/2,y0+math.floor((cellh-box)/2)+box/2,math.floor(box*1.35),theme.match,"⟲",5,0,nil,nil)
                button("cr_"..spec_id,x0+cw-padx-box-math.floor(2*s),y0+math.floor((cellh-box)/2)-math.floor(2*s),
                    box+math.floor(4*s),box+math.floor(4*s),"",theme.match,L("confirm.revert_tip"),
                    function() ctx.reset_encode_param(spec_id) end,false,"confirm")
            elseif with_chev and chev then
                local box=math.floor(cellh*0.26)
                -- chevron：字体字形（矢量方案已退役；以前是直接画 \p1 路径）
                self:text(x0+cw-padx-box+box/2,y0+math.floor((cellh-box)/2)+box/2,math.floor(box*1.30),theme.bgt,t.icons.chevron,5,0,nil,t.icon_font)
            end
        end
        hr()
        -- 导出类型：Tab 宽也跟文字走（原来固定 96，5 个就把面板撑宽了一截）
        local kinds=ctx.EXPORT_KINDS or {}
        local cur_kind=state.export_kind or "video"
        if #kinds>0 then
            self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
                t.icons.export_kind,(pico and L("confirm.kind_short")) or L("confirm.kind"),label_w,math.floor(6*s),t.icon_font,nil,mini)
            -- 铺满可用宽度：否则这一行短、面板宽，右边会留一大块空白
            local tw=math.floor((mw-dp*2-label_w-(#kinds-1)*btngap)/#kinds)
            local x0=mx+dp+label_w
            -- 标签页与输出方式行**同一个面板**，图标态跟面板级 pico 走（保证同面板完全同步）
            local kico_all=mini
            for i,k in ipairs(kinds) do
                -- kind id → 图标键不是一一对应：animated→gif、image→images
                local klbl,kico=(kico_all and "") or L(k.label),
                    kico_all and (t.icons[k.id == "animated" and "gif" or (k.id == "image" and "images" or k.id)] or nil) or nil
                button("kind_"..k.id,x0,y+math.floor((rowh-btnh)/2),tw,btnh,klbl,theme.match,
                    L("confirm.kind_tip", L(k.label)),function() ctx.set_export_kind(k.id) end, cur_kind==k.id, "confirm",kico)
                x0=x0+tw+btngap
            end
        end
        y=y+rowh+rowgap
        hr()
        -- 输出分组：方式两枚 ｜ 模式两枚。模式与"怎么输出"同类，挨着放视线才顺，
        -- 底部操作栏只留"预设 + 取消 + 开始"三件事。
        local merging=state.merge_output==true
        self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
            t.icons.output_mode,(pico and L("confirm.outmode_short")) or L("confirm.outmode"),label_w,math.floor(6*s),t.icon_font,nil,mini)
        -- 模式判定必须在按钮**之前**算出来：这两个 local 原来声明在按钮下面，按钮读到的
        -- 是全局 nil（`not nil` 恒真），于是切到重新编码后白洗仍停在"快速剪切"上。
        -- 两枚方式按钮**按内容定宽**（原来各占一半 → 右边一大块留白，也跟模式按钮不成比例）；
        -- 整组（方式 ｜ 模式）在标签列右侧居中，与裁剪面板两行的排版一致。
        -- 与其它行一致：从标签列右端起排，控件之间统一用 btngap；按钮按内容定宽，
        -- 右侧余下多少就空着（不再把空隙均分拉满）。
        -- 模式判定必须在下面这几枚按钮**之前**算出来。这两个名字曾被当成"重复声明"误删，
        -- 于是退化成全局 nil：`not nil` 恒真 → 白洗永远停在"快速复制"，
        -- 且"切点可能偏移"的提示在重新编码模式下也照显示（参数集却按真实模式切换，自相矛盾）。
        -- 取值顺序：ctx 函数 → 用户的选择，任何一步缺席都不会得到 nil。
        local confirm_crop_locked=ctx.crop_is_active(opts)
        local confirm_accurate=(ctx.effective_accurate_mode
            and (ctx.effective_accurate_mode(opts,state.accurate_mode,
                (state.confirm_action == "merge") and "merge" or "export") and true or false))
            or (state.accurate_mode == true)
        -- 图标态由上面的面板级 pico 决定（**整面板同步**，按几何量判定）
        local olbl,oico=(mini and "") or (pico and L("confirm.out_separate_short")) or L("confirm.out_separate"),mini and t.icons.parts or nil
        button("out_sep",mx+dp+label_w,y+math.floor((rowh-btnh)/2),om_w,btnh,olbl,
            theme.match,L("confirm.out_separate_tip"),
            function() if merging then ctx.toggle_merge_output() end end, not merging, "confirm",oico)
        local mlbl,mico=(mini and "") or (pico and L("confirm.out_merged_short")) or L("confirm.out_merged"),mini and t.icons.merge or nil
        -- 合并导出要把多段拼成一条流，mpv 编码模式没有 concat ⇒ 没有 ffmpeg 时置灰并说明。
        -- 不新增局部（render 已到 LuaJIT 槽位上限）：两个分支各调一次 ffmpeg_missing()，
        -- 它只读一个布尔字段，开销可忽略。
        button("out_merge",mx+dp+label_w+om_w+btngap,y+math.floor((rowh-btnh)/2),om_w,btnh,mlbl,
            theme.match,
            (ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and L("tip.needs_ffmpeg_merge") or L("confirm.out_merged_tip"),
            (ctx.ffmpeg_missing and ctx.ffmpeg_missing()) and nil
                or function() if not merging then ctx.toggle_merge_output() end end,
            merging and not (ctx.ffmpeg_missing and ctx.ffmpeg_missing()), "confirm",mico,nil,
            ctx.ffmpeg_missing and ctx.ffmpeg_missing() or false)
        -- 组内竖线（与裁剪面板同款）：夹在两段之间，两侧同样留 btngap
        om_w=mx+dp+label_w+2*om_w+2*btngap
        rect(om_w,y+math.floor((rowh-btnh)/2)+math.max(2,math.floor(math.floor(t.layout_group_divider_pad*s)/2)),
            math.max(1,math.floor(t.layout_group_divider_w*s)),
            btnh-math.max(2,math.floor(math.floor(t.layout_group_divider_pad*s)/2))*2,
            t.color_group_divider,t.alpha_group_divider,math.floor(math.max(1,math.floor(t.layout_group_divider_w*s))/2))
        om_w=om_w+math.max(1,math.floor(t.layout_group_divider_w*s))+btngap
        local flbl,fico=(mini and "") or (pico and L("confirm.mode_fast_short")) or L("confirm.mode_fast"),mini and t.icons.copy or nil
        -- 没有 ffmpeg 时快速复制整类不可用（mpv 编码模式没有 copy 编码器）：置灰并说明。
        -- 面板打开时 core 已把默认模式设成重新编码，所以不会一进来就停在置灰项上。
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
        -- "当前状态"不再单独成组：它和底部黄字一样是**只读的结果陈述**，已下移到 note 同一区
        -- （视线顺序：调参数 → 确认结果 → 执行）。其中"模式"改成底部操作栏里的切换控件。
        hr()
        -- 源文件：源文件的**实际**编码参数（只读参照）。放这里是为了与下面"编码格式"（目标参数）
        -- 对照着看：一眼知道"从什么编到什么"。
        self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
            t.icons.source_codec,(pico and L("confirm.source_label_short")) or L("confirm.source_label"),label_w,math.floor(6*s),t.icon_font,nil,mini)
        -- ④ 源文件文本按可用宽度**自动换行**（原来是硬截断到 64 字符，窄面板里会丢信息）
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
            -- 内联行：每个值一枚按钮，选中=白洗（与 Tab/输出方式同一套语言）。
            -- 局部预算紧（render 顶到 200 上限）：宽度算一次存 bw，x 游标复用已失效的 om_w。
            local bw=math.floor((mw-dp*2-label_w-(#inline_spec.values-1)*btngap)/#inline_spec.values)
            om_w=mx+dp+label_w
            for _,v in ipairs(inline_spec.values) do
                local lab=inline_spec.labels and inline_spec.labels[tostring(v)]
                -- 值按钮**不做逐项退化**：内联行只在"仅一个 list 参数"时成立，
                -- 唯一实例是字幕抽取页（subtitle_codec），它与取值都没有设计源图标
                -- （icon_for 全仓库无定义；t.icons 里既无 subtitle_codec 也无 goal_srt|ass|…），
                -- 那段退化分支恒不生效。要恢复得先给字幕格式补设计源字形。
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
        -- 开关组：单独一组，标签 + 拨动开关（胶囊 + 圆钮），开=强调色、关=次级色
        if sw_rows>0 then
            hr()
            self:row_title(text_width,truncate_chars,mx+dp,y+math.floor(rowh/2),fs_val,theme.bgt,
                t.icons.extra_processing,(pico and L("confirm.sec_extra_short")) or L("confirm.sec_extra"),label_w,math.floor(6*s),t.icon_font,nil,mini)
            for i,spec in ipairs(psw) do
                local on=(spec.id and true) and (opts[spec.field] and true or false)
                local j=(i-1)%grid_cols+1
                local x0=col_x(j); local cy=y+math.floor((i-1)/grid_cols)*(rowh+cellgap)
                -- 没有 ffmpeg 时整类不可用的开关（如消除切点偏移）：保留格子但置灰，
                -- 点也不改值 —— 让用户看到它存在、也知道为什么用不了（tooltip 指向装 ffmpeg）。
                -- 这里**不新增局部**（render 已到 LuaJIT 的 200 槽位上限）：mftip 用一次内联一次。
                button("cs_"..spec.id,x0,cy,colw[j],rowh,"",theme.match,
                    (ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec)) and L(ctx.missing_ffmpeg_tip(spec))
                        or (spec.desc and L(spec.desc) or nil),
                    (not (ctx.missing_ffmpeg_tip and ctx.missing_ffmpeg_tip(spec)))
                        and function() ctx.set_encode_param(spec.id, on and "false" or "true") end or nil,
                    false, "confirm", nil, nil, false)
                -- 开关组的按钮本身是空的（只当命中区与 tooltip），标签由下面单独画 ⇒
                -- 这里不能交给 UI:button 的置灰装饰（它会给整格画一道斜杠，压到开关本体上很难看）。
                -- 改为只在标签文字上划一道删除线，语义与其它置灰项一致。
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
                -- 置灰：开关本体一起压暗，且不再画到"开"的位置（画成关态，避免暗示已生效）
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
        -- 只在"快速复制 且 没开消除切点偏移"时提示：开了之后偏移会被局部重编码消掉，
        -- 重新编码整片重编码更谈不上偏移（原来两个条件都漏了，重新编码也照显示）。
        if not confirm_accurate and opts.smart_cut ~= true then note=note.." ｜ "..L("confirm.fast_note") end
        text(mx+dp,y+math.floor(note_h/2),math.floor(t.layout_note_fs*s),theme.heatmap,note,4)
        -- 操作栏：左 预设下拉；右 取消 / 开始（模式已并入上面的"输出方式"行）
        local by=my+mh-btm-btnh
        if ctx.cycle_export_preset then
            -- 同一枚按钮承载两种语义：当前是「优化目标」用 optimize 图标，否则用 preset 图标。
            -- 文本放得下就只显示文本，放不下才退化为图标（panel_button_content）。
            -- 极窄下不能按固定令牌宽画：三枚按钮之和超过面板 ⇒ 预设被取消/开始压住（且**点不到**）。
            -- 夹到"取消 + 开始 + 间距 + 边距"之外的剩余空间；放不下时 panel_button_content 自动退化为
            -- 只画图标（位置不变、命中区完整 ⇒ 仍可点）。
            local pcw=math.min(math.floor(t.layout_confirm_preset_w*s), math.max(math.floor(24*s),
                mw-math.floor(t.layout_confirm_cancel_w*s)-math.floor(t.layout_confirm_go_w*s)
                -dp*2-btngap*2-2))
            local choice=(ctx.choice_label and ctx.choice_label()) or nil
            -- 三级：全名（预设参数：原始）→ 值（原始）→ 图标（mini）。
            -- 窄尺寸不要显示通用短名「优化」（当前预设其实是「原始」），
            -- 值必须留着（图标只说明「这是哪一项」，值才说明「选的什么」）。
            local pnow=(ctx.choice_name and ctx.choice_name()) or ctx.preset_label()
            local plbl=(mini and nil) or (pico and pnow) or choice or L("confirm.preset", ctx.preset_label())
            local plbl2,pico_icon=panel_button_content(t,ctx.text_width,plbl,
                choice and t.icons.optimize or t.icons.preset,
                pcw,math.floor((tonumber(t.font_button) or 20)*s),math.floor(12*s))
            button("confirm_preset",mx+dp,by,pcw,btnh,plbl2,theme.match,(ctx.choice_tip and ctx.choice_tip()) or L("confirm.choice_tip"),function() ctx.toggle_param_dropdown("_preset") end,dd and dd.id=="_preset","confirm",pico_icon)
            -- 下拉箭头改用**图标字体**的 chevron：原来那个 ▾ 写在 i18n 文案里、用普通字体画，
            -- 和旁边 Tabs/单元格的图标箭头（图标字体）观感不一致
            -- 颜色必须与按钮自己的文字一致（激活=反色，否则=常规文字色）。
            -- 注意：不要用 theme.match（强调色）⇒ 箭头会被标蓝
            self:text(mx+dp+pcw-math.floor(14*s),by+math.floor(btnh/2),math.max(8,math.floor(btnh*0.42)),
                ((dd and dd.id=="_preset") and t.color_text_inverse or t.color_text),t.icons.chevron,5,0,nil,t.icon_font)
            anchors["_preset"]={x=mx+dp,y=by,w=pcw,h=btnh}
        end
        local go_x=mx+mw-dp-math.floor(t.layout_confirm_go_w*s)
        local cancel_x=go_x-math.floor(t.layout_confirm_cancel_w*s)-btngap
        button("confirm_cancel",cancel_x,by,math.floor(t.layout_confirm_cancel_w*s),btnh,L("confirm.cancel"),theme.error,L("confirm.cancel"),function() state.confirm_action=nil; state.param_dropdown=nil; if ctx.install_main_bindings then ctx.install_main_bindings() end; ctx.request_render(true) end,false,"confirm")
        -- 主操作 = success 绿实心 + 反色字（白洗只留给"选中"，执行类按钮用它自己的 success 色染底）。
        rect(go_x,by,math.floor(t.layout_confirm_go_w*s),btnh,theme.success,1,math.floor(btnh/2))
        text(go_x+math.floor(math.floor(t.layout_confirm_go_w*s)/2),by+math.floor(btnh/2),fs_val,
            theme.bgt,L("confirm.go"),5)
        button("confirm_go",go_x,by,math.floor(t.layout_confirm_go_w*s),btnh,"",theme.success,L("confirm.go_tip"),ctx.confirm_execute,false,"confirm")
        if dd then
            local did=dd.id
            local options=ctx.param_options(did)
            local dmax=math.max(1,tonumber(DROPDOWN_MAX_ROWS) or 10)
            -- 行步进 = 按钮高 + 行距，保证选项之间有 dialog_row_gap 的净间隙
            local drowh=math.floor(t.dialog_button_height*s)+math.floor(t.dialog_row_gap*s)
            local visible=math.min(#options,dmax)
            local dpad=math.floor(t.dialog_button_margin*s)  -- 浮层内边距，与按钮外边距同令牌
            local dw=math.floor(t.layout_dropdown_w*s); local dx=mx+math.floor(t.layout_dropdown_x*s); local ay=by; local ah=math.floor(t.layout_dropdown_h*s)
            local anchor=anchors[did]
            if anchor then dw,dx,ay,ah=anchor.w,anchor.x,anchor.y,anchor.h end
            local has_more=#options>visible
            -- 内边距 + 选项行 + 内边距 + (更多提示行)
            local dh=dpad*2+visible*drowh+(has_more and lineh or 0)
            -- 定位：**优先作为飞出层贴在面板外侧**（面板宽度按内容算，右侧通常有余地），
            -- 这样不会盖住面板自身的内容；一律向下展开时，从中间行一展开就会把下面几行
            -- 连同 note / 操作栏压住。
            -- 面板外侧都放不下时，才回到"锚点上方/下方"的覆盖式定位，并按两侧余量挑更大的一侧。
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
                        -- 分节标题：不可点、不参与焦点。行高与选项一致，滚动/可视行数算法不用分叉。
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
                    -- 下拉选项**不做逐项退化**（判定恒不生效，不是"不会空白"
                    -- 而是"从未退化"）。两处原因：① 优化目标项的 value 是 `_goal:<goal>`
                    -- （core.lua 的 ctx.param_options），拼 `"goal_"..opt.value` 得到 `goal__goal:quality`，
                    -- 永远查不到；② ctx.param_options 产出的每个 row 只有 {value,label,current}，
                    -- 根本没有 icon 字段。选项保持文本 + 截断。要恢复该能力，先让 row 带上真图标键。
                    local olbl=opt.label..(opt.current and "  ✓" or "")
                    button("dp_"..did.."_"..k,dx+dpad,oy,dw-dpad*2,math.floor(t.dialog_button_height*s),
                        olbl,theme.match,
                        nil,   -- 选项不再显示"选择 xxx/当前值"这类操作指示（tooltip 只描述功能）
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
        -- 与确认面板同一套兜底：行占用高度至少比按钮高 4px，避免相邻行按钮重叠
        local rowh=math.max(math.floor(t.dialog_row_height*s), btnh+math.floor(t.layout_row_extra*s))
        local rowgap=math.floor(t.dialog_row_gap*s)
        local lineh=math.floor(t.dialog_text_line*s)
        local btm=math.floor(t.dialog_bottom_pad*s)
        local mw = math.min(w - 24, math.floor(t.layout_modal_width * s))
        local maxv = math.max(1, tonumber(opts.max_visible_segments) or 7)
        local title_h=math.floor(opts.menu_title_font_size*s)
        -- 结构化：内边距 + 标题 + gap + 列表(最多 maxv 行) + 页脚操作行 + 页脚说明 + 底部内边距
        local sg=math.floor(t.dialog_section_gap*s)
        local mh = math.min(h - 24, dp+title_h+tg+maxv*(rowh+rowgap)+sg+btnh+lineh+btm); local mx = math.floor((w - mw) / 2); local my = math.floor((h - mh) / 2)
        self:panel(mx,my,mw,mh,1)
        local order_note = state.manual_order and L("hint.manual_order") or ""
        text(mx+dp,my+dp,math.floor(opts.menu_title_font_size*s), theme.bgt, string.format("%s (%d)%s", L.title, #state.segments, order_note), 4)
        -- 关闭按钮与标题基线对齐，右边缘对齐到 dp 内边距
        button("close", mx + mw - dp - math.floor(t.layout_modal_close_w * s), my + dp + (title_h - btnh) / 2, math.floor(t.layout_modal_close_w * s), btnh, L.close, theme.btn.close, L("tip.close_modal"), function() state.modal = false; ctx.request_render(true) end, false, "modal")
        local btngap=math.floor(t.dialog_button_gap*s)
        local chk_w=btnh
        local first = math.min(math.max(1, state.segment_scroll + 1), math.max(1, #state.segments))
        local last = math.min(#state.segments, first + maxv - 1); local yy = my + dp + title_h + tg
        if #state.segments == 0 then
            text(mx + mw / 2, my + mh / 2, math.floor(t.layout_modal_empty_fs * s), theme.bgt, L("modal.empty", key_of("add")), 5, nil, .6)
        else
            -- 行内冲突标记：与时间轴的警示条同源（存在时间区间重叠即标记）
            local list_overlapping={}
            for oi,a in ipairs(state.segments) do
                for _,b in ipairs(state.segments) do
                    if a~=b and a.start_time < b.end_time and b.start_time < a.end_time then list_overlapping[oi]=true; break end
                end
            end
            for i = first, last do
                local seg = state.segments[i]; local seg_id = seg.id
                local by = yy + (rowh - btnh) / 2
                -- 自定义名称放在行首（重命名入口在页脚）：列表里一眼能认出"这段是什么"。
                -- 会话恢复时写入的自动名（"片段 N"）与序号重复，不显示。
                local custom = tostring(seg.label or "")
                local shown_name = (custom ~= "" and custom ~= L("hint.segment_label", seg_id)) and (custom .. "  ") or ""
                local label = string.format("%d. %s%s -> %s (%.3fs)%s", i, shown_name, format_time(seg.start_time), format_time(seg.end_time), seg.end_time - seg.start_time,
                    list_overlapping[i] and " ⚠" or "")
                -- 行体（除行首勾选格以外的整行）是命中区：点击 = 单选该段并跳到段首（播放范围随之
                -- 收窄到这一段）；行首勾选格 = 加入/移出多选播放范围。行内不再堆操作按钮。
                -- 行体用透明按钮做命中区（label 空串，文字仍用左对齐等宽 text 绘制），
                -- 这样悬停/选中的底色由按钮变体统一提供，不必额外手绘高亮矩形。
                local row_x = mx + dp + chk_w + btngap
                local row_w = math.max(1, mw - dp*2 - chk_w - btngap)
                button("row_"..seg_id, row_x, by, row_w, btnh, "", theme.btn.seg, L("tip.row_select"), function()
                    ctx.focus_segment(seg_id)
                    mp.commandv("seek", tostring(seg.start_time), "absolute+exact")
                    ctx.apply_segment_loop(); ctx.request_render(true)
                end, state.selected_segment_id == seg_id, "modal")
                -- 停用的片段用"停用片段色"（与时间轴同一令牌）并压低透明度，
                local row_enabled = seg.enabled ~= false
                text(row_x + math.floor(t.dialog_padding*s), yy + rowh/2, math.floor(opts.menu_font_size*s),
                    row_enabled and theme.bgt or (theme.timeline_disabled or theme.fg), label, 4, nil, row_enabled and nil or .5)
                local marked = ctx.is_checked(seg_id)
                button("chk_"..seg_id, mx + dp, by, chk_w, btnh, marked and "✓" or "", marked and theme.match or theme.btn.seg,
                    marked and L("tip.uncheck_segment") or L("tip.check_segment"), function() ctx.toggle_range(seg_id) end, marked, "modal")
                yy = yy + rowh + rowgap
            end
            -- 页脚操作集中成一行（原每行 5 个按钮 → 集中）：作用于"勾选集合（若有）或当前聚焦段"。
            -- 目标不唯一时按钮变暗，点击由 core 的 ctx.list_op 给出明确提示而不是静默失败。
            -- 不设"添加"：新增片段要用入/出点，而列表打开时时间轴不可见（面板按钮负责这件事）。
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
    -- 宽高按文本自适应：超屏宽自动换行，盒宽取最长行、盒高随行数。
    -- ctx.hovered_id/ctx.hovered_tip 可能是上一次渲染留下的：面板开合会让按钮消失，
    -- 此时 btn_y 也为 nil，继续画 tooltip 会算术崩溃。找不到按钮就不画。
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
            -- 文本居中（\an5 中中锚定，x 为 tooltip 水平中心）
            text(tip_x+tip_w/2,ty,tip_fs,theme.fg,l,5,0)
            ty=ty+line_h
        end
    end

    if state.help then
        -- 键位速查浮层（? / K 切换，Esc 或点击任意处关闭）：数据来自当前上下文的键位绑定表，
        -- *-fast 变体归并到基础动作行，只追加键名。
        -- 三个上下文的绑定表互斥（确认面板打开时不可能在编辑裁剪；片段列表用的是主面板键位）。
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
        -- 布局按给定缩放算一次；窗口装不下就整体等比缩小后重算（宽度优先铺开，尽量少折行）
        local function help_layout(sv)
            local dp = math.floor(t.dialog_padding*sv)
            -- 行高与字号对齐片段列表行（dialog_row_height + menu_font_size）
            local rowh = math.max(math.floor(t.dialog_row_height*sv), math.floor(opts.menu_font_size*sv) + math.floor(t.dialog_row_gap*sv))
            local row_fs = math.floor(opts.menu_font_size*sv)
            local title_h = math.floor(opts.menu_title_font_size*sv)
            local cols = 2
            local pw, colw, keyw, percol, line_h, ph, colh
            repeat
                percol = math.max(1, math.ceil(#rows / cols))
                -- 宽度取"可用宽度"与基准宽的较小值：右侧有空间就不再折行
                pw = math.min(w - dp*2, math.floor(t.layout_modal_width * sv))
                colw = math.floor(pw / cols) - dp
                -- "ENTER / KP_ENTER" 这类长键名会直接压到描述上
                keyw = 0
                for _, row in ipairs(rows) do keyw = math.max(keyw, text_width(row.keys, row_fs)) end
                keyw = math.min(math.floor(colw * .55), keyw + math.floor(row_fs * .9))
                local descw = math.max(math.floor(row_fs * 4), colw - keyw)
                line_h = math.floor(row_fs * 1.35)
                -- 折行后每行最多占一行高，按"本列各行实际高度之和"算面板高度
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
                -- 高度装不下就先加列（降低高度），最多 4 列
                if ph <= h - dp*2 or cols >= 4 then break end
                cols = cols + 1
            until false
            return {dp=dp, rowh=rowh, row_fs=row_fs, title_h=title_h, cols=cols, percol=percol,
                pw=pw, colw=colw, keyw=keyw, line_h=line_h, ph=ph, colh=colh}
        end
        local H = help_layout(s)
        -- 仍装不下（窗口很矮）就局部再等比缩小，保证整块面板可见
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
        -- 语义图标：icons 表按提示级别给字形（函数=矢量路径 / 字符串=图标字体）；缺图标则退回色条
        local icon_key=state.action_hint_level=="success" and "check" or (state.action_hint_level=="error" and "alert" or "info")
        local m=self:hint_metrics{lines=lines,scale=s,sw=w,theme=theme,opts=opts,tw=text_width,trunc=truncate_chars,
            color=hint_color,icon=t.icons[icon_key],secondary=t.alpha_secondary_text,
            -- 只有任务卡真的在屏上（导出中 / 完成卡 15 秒内）才为它预留右上角，否则提示走自然宽度
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
