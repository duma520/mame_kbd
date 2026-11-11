-- license:BSD-3-Clause
-- copyright-holders:local
--
-- MAME 0.289 插件 mame_kbd —— 当前 ROM 的 1P~4P 按键对照表
--
-- 用途：把运行中游戏的方向键、选择、开始、以及按键 1~N 各自绑定了哪个真实按键，
--       在画面下方以「P1 / P2 / P3 / P4 四列」实时显示，玩家按下时该项变色高亮。
--
-- 数据来源（全部走官方 Lua API，不读 cfg、不硬编码 IPT_ 枚举数值）：
--   1) 遍历 ioport.ports[tag].fields，用 ioport:input_type_to_token(type, player)
--      拿到 "P1_JOYSTICK_UP" / "P1_BUTTON1" / "START1" 这类 token，
--      再从 token 解析「玩家号 + 语义」（不用枚举数值，MAME 改枚举也不受影响）。
--      注意：START1/COIN1 这类 token 的 field.player 恒为 0，玩家号必须取自 token。
--   2) 单个输入最终生效的绑定按三级回退取：
--      field:input_seq('standard')      → 本游戏单独覆盖
--      field:default_input_seq()        → 字段默认（未覆盖时即通用分配）
--      ioport:type_seq(type, player)    → 通用输入分配
--   3) 显示文本用 input:seq_name(seq)，由 MAME 自己生成，自动跟随语言设置。
--   4) 按下判定：读 port:read() 与 field.mask 做按位与，和 field.defvalue 比较
--      （MAME 的 ioport 是低有效：未按下该位为 1，按下为 0）。
--
-- 布局（每列内）：
--     第 1 行  方向键 U / D / L / R  —— 固定 4 格
--     第 2 行  选择 / 开始          —— 有才显示
--     之后     按键 1..N            —— 只渲染游戏真实存在的字段
--              每行格数由「显示设置 → 每行按键数」决定：
--                'auto' → 按当列可用宽度自适应：取「所有按键都能在一行内
--                         完整显示」的最大格数（上限 16 个，即单玩家按键上限；
--                         放不下就减格，降到 1 格仍放不下才交给 split_cell
--                         换行/截断）；
--                1..16  → 强制每行该格数
--              注意：auto 看的是实际键名文本长度，同一 ROM 换过绑定后
--              算出的格数可能变化，这是预期行为。
--
-- 绘制：register_frame_done 里往 manager.machine.render.ui_container 画
--       （坐标 0..1 归一化，(0,0)=左上、(1,1)=右下）。
--
-- 持久化：按 ROM 分别保存，互不污染。
--       <插件目录>/settings_<rom>.ini（当前 ROM 的设置）
--       <homepath>/mame_kbd/settings_default.ini（无 ROM 时的默认值）
--       插件目录不可写时回退 <homepath>/mame_kbd/

local exports = {
	name = 'mame_kbd',
	version = '2.9.8',
	description = 'Show P1-P4 direction/select/start/button key bindings at the bottom of the screen',
	license = 'BSD-3-Clause',
	author = { name = 'local' } }

local mame_kbd = exports

local frame_subscription, reset_subscription, stop_subscription
local plugin_folder = nil

-- ============================================================
-- 位运算辅助（Lua 5.1 没有 & | << >>，必须用算术模拟）
-- ============================================================
local function band(a, b)
	a = math.floor(tonumber(a) or 0)
	b = math.floor(tonumber(b) or 0)
	local r, bit = 0, 1
	while a > 0 and b > 0 do
		if a % 2 == 1 and b % 2 == 1 then r = r + bit end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		bit = bit * 2
	end
	return r
end

local function safe(fn, default)
	local ok, v = pcall(fn)
	if ok and v ~= nil then return v end
	return default
end

local function clamp_int(v, lo, hi, default)
	local n = tonumber(v)
	if not n then return default end
	n = math.floor(n)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

-- ============================================================
-- 语义与 token 解析
-- ============================================================
local DIR_ORDER = { 'UP', 'DOWN', 'LEFT', 'RIGHT' }
local DIR_SET = { UP = true, DOWN = true, LEFT = true, RIGHT = true }
local MAX_BUTTON = 16
-- 「每行按键数」的上限：'auto' 自适应与手动档位（1..PER_ROW_MAX）共用这个上限。
-- 改这里就能整体放开/收紧档位，不必逐个改判断。
-- 16 与 MAX_BUTTON 对齐：单个玩家最多 16 个按键，再多也没有意义。
local PER_ROW_MAX = 16

-- 从 ioport token 解析出 (玩家索引 0 基, 类别, 语义键)
--   "P1_JOYSTICK_UP" -> 0, 'DIR',    'UP'
--   "P1_UP"          -> 0, 'DIR',    'UP'
--   "P1_BUTTON3"     -> 0, 'BUTTON', 'BUTTON3'
--   "START1"         -> 0, 'START',  'START'
--   "SELECT2"        -> 1, 'SELECT', 'SELECT'
local function parse_token(tok)
	if not tok then return nil end
	tok = tostring(tok)

	local p, dir = tok:match('^P(%d+)_JOYSTICK_(%u+)$')
	if p and DIR_SET[dir] then
		return tonumber(p) - 1, 'DIR', dir
	end

	local p2, dir2 = tok:match('^P(%d+)_(%u+)$')
	if p2 and DIR_SET[dir2] then
		return tonumber(p2) - 1, 'DIR', dir2
	end

	local p3, btn = tok:match('^P(%d+)_BUTTON(%d+)$')
	if p3 and btn then
		return tonumber(p3) - 1, 'BUTTON', 'BUTTON' .. tostring(tonumber(btn))
	end

	local s = tok:match('^START(%d+)$')
	if s then return tonumber(s) - 1, 'START', 'START' end

	local sel = tok:match('^SELECT(%d+)$')
	if sel then return tonumber(sel) - 1, 'SELECT', 'SELECT' end

	-- 通用输入分配的 token 形如 P1_SELECT（实测 xmen：ty=43、token=P1_SELECT）。
	-- 这类槽位在 ioport.ports 里没有对应字段，只能从 ioport.types 建虚拟项。
	local p4 = tok:match('^P(%d+)_SELECT$')
	if p4 then return tonumber(p4) - 1, 'SELECT', 'SELECT' end

	return nil
end

-- 过滤说明：不再按 type_class 黑名单过滤。
-- 原因（实测 119 得到的真实数据）：START1/START2/COIN1/COIN2/SERVICE1 的
-- type_class 都是 misc，若照 copilot2p 那样把 misc 排除，就永远拿不到「开始」。
-- 改为：只认 parse_token 解析成功的白名单 token（DIR/BUTTON/START/SELECT），
-- 其余 token（COIN/SERVICE/DIPSWITCH/…）自然被丢弃，无需再套黑名单。

-- ============================================================
-- 设置（按 ROM 分别持久化）
-- ============================================================
local function default_settings()
	return {
		show = true,             -- 是否显示
		layout = 'four',         -- 'four' = 固定四列（P3/P4 无输入时显示「无」）；'auto' = 只显示有输入的玩家
		label = 'zh',            -- 'zh' = 中文标签；'ascii' = U/D/L/R
		per_row = 'auto',        -- 'auto' = 按可用宽度自适应（完整显示前提下取最大格数，上限 16）；1..16 = 强制每行格数
		show_start = true,       -- 显示「选择 / 开始」行
		highlight = true,        -- 按下时变色高亮
		seq_mode = 'first',      -- 'first' = 键盘+手柄都显示；'priority' = 手柄>键盘>鼠标 只显示最高优先级那一路；'full' = 显示全部（or 连接）
		wrap = true,             -- 长键名自动换行成两行（字号无法调小，只能换行）
		line_px = 24,            -- 行距（像素）
		bottom_px = 28,          -- 距画面底部边距（像素）；draw_text 的 y 是基线，需留出降部空间
		col_px = 6,              -- 列间空隙（像素）
		bg_alpha = 200,          -- 背景不透明度 0..255
		char_px = 15,            -- UI 字体半角字符宽度（像素）。实测（1351px 窗口一行四列）：Down=65px/4字、1:Right Ctrl=235px/12字，平均约 16px；取 15 略保守，配合多词缩写（Num 8->N8）后 5 字可过、6 字截断
		-- 以下三项是「显示格式」预设，只影响文字长什么样，不影响绑定逻辑。
		-- 之所以做成预设档位而不是自由输入：MAME 插件菜单没有文本输入控件
		-- （官方 commonui 只有「选一项」和「捕获按键」两种交互），做不出打字界面。
		mod_style = 'short',     -- 修饰键：'short'=LShft / 'zh'=左Shft / 'hyphen'=L-Shift / 'full'=Left Shift
		joy_style = 'under',     -- 手柄：'under'=J1_B1 / 'plain'=J1B1 / 'num'=J1_1 / 'zh'=手柄1_1 / 'joy'=Joy1_1
		                         --       / 'abxy'=J1A / 'abxyu'=J1_A（按钮 1~8 → A B X Y L1 R1 L2 R2）
		mouse_style = 'under',   -- 鼠标/光枪：'under'=M1_B1 / 'plain'=M1B1 / 'num'=M1_1 / 'zh'=鼠标1_1 / 'mou'=Mou1_1
		-- 只作用于手柄的四个方向（键盘方向键不受影响）：
		--   'letter' = U / D / L / R          （默认，最省位）
		--   'word'   = Up / Dn / Lt / Rt      （2.8.4 之前的旧形态，更易读但多占 1 位）
		--   'arrow'  = ↑ / ↓ / ← / →        （箭头）
		--   'tri'    = ▲ / ▼ / ◀ / ▶        （三角，与菜单里已有的 ◀ ▶ 同字形族）
		dir_style = 'letter',
		-- 按下高亮的三种颜色（见 HL_COLORS）。存 id 不存数值：
		-- 数值写进 ini 后可读性差，且以后调整色值不会让老配置锁死在旧色上。
		hl_phys = 'green',       -- 物理按下
		hl_mirror = 'blue',      -- 仅镜像按下
		hl_both = 'gold',        -- 物理 + 镜像同时
	}
end

local settings = default_settings()

-- ============================================================
-- 按下高亮的颜色预设（用户可在「按键颜色」页左右切换）
-- ============================================================
-- 为什么是预设而不是调色板：MAME 插件菜单只有「选一项」和「捕获按键」两种
-- 交互（官方 commonui 源码实证），既没有文本输入也没有颜色选择器，做不出
-- 让用户直接填 #RRGGBB 的界面。所以颜色只能做成档位列表，左右键循环切换。
--
-- 每档同时给出 fg（文字色）和 bg（同色系压暗的半透明底）。bg 不单独开放：
-- 否则 3 种状态会变成 6 个旋钮，反而难调；而底色本来就该跟字色同色系。
--
-- 档位按色系排列（绿→青→蓝→紫→粉→红→金→黄→中性），浅/深变体紧挨原色，
-- 这样左右切换时看到的颜色是渐变过渡的，而不是每次跳到完全不相干的色。
-- 新增档位只能【往后插到对应色系里】，绝不能改已有档位的 id 与色值——
-- 用户 ini 里存的是 id，改了 id 等于把人家配好的颜色重置掉。
--
-- 这张表必须定义在 apply_kv（下方白名单校验）之前，否则读配置时取不到。
local HL_COLORS = {
	{ id = 'green',    text = '绿',    fg = 0xFF00FF66, bg = 0xB0008020 },
	{ id = 'green_l',  text = '浅绿',  fg = 0xFF66FF9C, bg = 0xB02B6B41 },
	{ id = 'green_d',  text = '深绿',  fg = 0xFF00B84A, bg = 0xB0004D1F },
	{ id = 'lime',     text = '黄绿',  fg = 0xFFB0FF3C, bg = 0xB04A6B19 },
	{ id = 'mint',     text = '薄荷',  fg = 0xFF6CFFC8, bg = 0xB02D6B54 },
	{ id = 'cyan',     text = '青',    fg = 0xFF4FE8D0, bg = 0xB0006058 },
	{ id = 'aqua',     text = '水蓝',  fg = 0xFF3CE8FF, bg = 0xB019616B },
	{ id = 'blue',     text = '蓝',    fg = 0xFF40C4FF, bg = 0xB0003C80 },
	{ id = 'blue_l',   text = '浅蓝',  fg = 0xFF8CD8FF, bg = 0xB03A5A6B },
	{ id = 'blue_d',   text = '深蓝',  fg = 0xFF1A78D0, bg = 0xB00B3257 },
	{ id = 'azure',    text = '天青',  fg = 0xFF7AA8FF, bg = 0xB033466B },
	{ id = 'indigo',   text = '靛',    fg = 0xFF6C7CFF, bg = 0xB02D346B },
	{ id = 'purple',   text = '紫',    fg = 0xFFD08CFF, bg = 0xB0503080 },
	{ id = 'purple_l', text = '浅紫',  fg = 0xFFE8B8FF, bg = 0xB0614D6B },
	{ id = 'purple_d', text = '深紫',  fg = 0xFF9A4CD0, bg = 0xB0402057 },
	{ id = 'magenta',  text = '洋红',  fg = 0xFFFF5CE0, bg = 0xB06B275E },
	{ id = 'pink',     text = '粉',    fg = 0xFFFF80C0, bg = 0xB0802050 },
	{ id = 'rose',     text = '玫红',  fg = 0xFFFF5C9E, bg = 0xB06B2742 },
	{ id = 'red',      text = '红',    fg = 0xFFFF5A5A, bg = 0xB0802020 },
	{ id = 'red_l',    text = '浅红',  fg = 0xFFFF8C8C, bg = 0xB06B3B3B },
	{ id = 'red_d',    text = '深红',  fg = 0xFFD02A2A, bg = 0xB0571212 },
	{ id = 'coral',    text = '珊瑚',  fg = 0xFFFF7A5C, bg = 0xB06B3327 },
	{ id = 'orange',   text = '橙',    fg = 0xFFFFA040, bg = 0xB0805000 },
	{ id = 'gold',     text = '金',    fg = 0xFFFFD23F, bg = 0xB0806000 },
	{ id = 'gold_l',   text = '浅金',  fg = 0xFFFFE884, bg = 0xB06B6128 },
	{ id = 'gold_d',   text = '暗金',  fg = 0xFFD0A000, bg = 0xB0574300 },
	{ id = 'yellow',   text = '黄',    fg = 0xFFFFFF60, bg = 0xB0807000 },
	{ id = 'white',    text = '白',    fg = 0xFFFFFFFF, bg = 0xB0606060 },
	{ id = 'silver',   text = '银',    fg = 0xFFE0E0E0, bg = 0xB05E5E5E },
	{ id = 'gray',     text = '灰',    fg = 0xFFA0A0A0, bg = 0xB0434343 },
}

-- 按 id 取一档；找不到回落到第一档（绿），手写 ini 打错字也不会崩。
local function hl_pick(id)
	for _, c in ipairs(HL_COLORS) do
		if c.id == id then return c end
	end
	return HL_COLORS[1]
end

-- 菜单里显示成「绿 #00FF66」。带色值是因为菜单无法预览颜色，
-- 想与外面对照（比如把这个色值抄到别处）时能用上。
local function hl_label(id)
	local c = hl_pick(id)
	return string.format('%s #%06X', c.text, c.fg % 0x1000000)
end

local function home_dir()
	return safe(function()
		return manager.options.entries.homepath:value():match('([^;]+)')
	end, nil)
end

local function current_rom()
	local name = safe(function() return manager.machine.system.name end, nil)
	if name and tostring(name) ~= '' then return tostring(name) end
	return nil
end

-- 本 ROM 的设置文件名（settings_xmen.ini 之类）；没有 ROM 时返回 nil。
-- 菜单里要显示「重置本 ROM」到底会删掉哪个文件，所以抽出来单独用。
local function rom_ini_name()
	local rom = current_rom()
	if not rom then return nil end
	return 'settings_' .. rom:gsub('[\\/:*?"<>|]', '_') .. '.ini'
end

-- 配置目录：<homepath>/mame_kbd。
-- homepath 实测是「.」（基准 = mameui.exe 所在目录），所以拼出来就是
-- <mameui>/mame_kbd/，与插件代码目录 plugins/mame_kbd/ 分开。
-- ★ 为什么必须分开：插件目录可能整体替换/重新解压，配置放里面会被一起冲掉；
--   而且用户升级插件时也不该动到自己的设置。
local function config_dir()
	local home = home_dir()
	if home and home ~= '' then return home .. '/mame_kbd' end
	return nil
end

-- 目录不存在就建。返回 true 表示「现在这个目录可用」。
local function ensure_dir(d)
	if not d or d == '' then return false end
	local ok, lfs = pcall(require, 'lfs')
	if not ok or not lfs then return false end
	local attr = nil
	pcall(function() attr = lfs.attributes(d) end)
	if attr then return true end
	pcall(function() lfs.mkdir(d) end)
	-- mkdir 返回值不完全可信（可能是别人刚建好），统一再探测一次
	attr = nil
	pcall(function() attr = lfs.attributes(d) end)
	return attr ~= nil
end

-- 按 ROM 名生成设置文件路径；无 ROM 时用 settings_default.ini
local function settings_path()
	local d = config_dir()
	if not d then return nil end
	return d .. '/' .. (rom_ini_name() or 'settings_default.ini')
end

local function serialize()
	local t = {}
	t[#t + 1] = 'show=' .. (settings.show and '1' or '0')
	t[#t + 1] = 'layout=' .. tostring(settings.layout)
	t[#t + 1] = 'label=' .. tostring(settings.label)
	t[#t + 1] = 'per_row=' .. tostring(settings.per_row)
	t[#t + 1] = 'show_start=' .. (settings.show_start and '1' or '0')
	t[#t + 1] = 'highlight=' .. (settings.highlight and '1' or '0')
	t[#t + 1] = 'seq_mode=' .. tostring(settings.seq_mode)
	t[#t + 1] = 'line_px=' .. tostring(settings.line_px)
	t[#t + 1] = 'bottom_px=' .. tostring(settings.bottom_px)
	t[#t + 1] = 'col_px=' .. tostring(settings.col_px)
	t[#t + 1] = 'bg_alpha=' .. tostring(settings.bg_alpha)
	t[#t + 1] = 'char_px=' .. tostring(settings.char_px)
	t[#t + 1] = 'wrap=' .. (settings.wrap and '1' or '0')
	t[#t + 1] = 'mod_style=' .. tostring(settings.mod_style)
	t[#t + 1] = 'joy_style=' .. tostring(settings.joy_style)
	t[#t + 1] = 'mouse_style=' .. tostring(settings.mouse_style)
	t[#t + 1] = 'dir_style=' .. tostring(settings.dir_style)
	t[#t + 1] = 'hl_phys=' .. tostring(settings.hl_phys)
	t[#t + 1] = 'hl_mirror=' .. tostring(settings.hl_mirror)
	t[#t + 1] = 'hl_both=' .. tostring(settings.hl_both)
	return table.concat(t, '\n') .. '\n'
end

local function write_file(path, text)
	local f = io.open(path, 'w')
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

local function save_settings()
	local body = serialize()
	local d = config_dir()
	if not d or not ensure_dir(d) then return end
	write_file(d .. '/' .. (rom_ini_name() or 'settings_default.ini'), body)
end

-- 把当前设置写成「全局默认」(settings_default.ini)。
-- 用途：在一个 ROM 里调好格式后，一键让其它没有自己 ini 的 ROM 也采用同一套。
-- 注意：settings_<rom>.ini 优先级更高，已存在专属配置的 ROM 不会被覆盖，
-- 需要用「重置本 ROM」把旧文件删掉才会回落到这里（菜单里会明确提示）。
local function save_default_settings()
	local d = config_dir()
	if not d or not ensure_dir(d) then return false end
	return write_file(d .. '/settings_default.ini', serialize())
end

-- 删掉本 ROM 的专属 ini，让它回落到 settings_default.ini。
-- 返回：'no_rom'（当前无 ROM）/ 'removed'（删成功）/ 'missing'（本来就没有）/ 'failed'
local function reset_rom_settings()
	local name = rom_ini_name()
	if not name then return 'no_rom' end
	local targets = {}
	local d = config_dir()
	if d then targets[#targets + 1] = d .. '/' .. name end
	-- 旧版本把配置写在插件目录里，残留也要一并清掉，否则读完旧文件
	-- 看起来就像「重置没生效」。
	if plugin_folder and plugin_folder ~= '' then
		targets[#targets + 1] = plugin_folder .. '/' .. name
	end
	local removed, missing = 0, 0
	for _, p in ipairs(targets) do
		local f = io.open(p, 'r')
		if f then
			f:close()
			-- os.remove 在 Windows 上删不存在的文件会返回 nil,msg，这里已先确认存在
			local ok = os.remove(p)
			if ok then removed = removed + 1 else return 'failed' end
		else
			missing = missing + 1
		end
	end
	if removed > 0 then return 'removed' end
	if missing > 0 then return 'missing' end
	return 'failed'
end

local function apply_kv(cfg, k, v)
	if k == 'show' then
		cfg.show = (v == '1' or v == 'true')
	elseif k == 'layout' then
		if v == 'four' or v == 'auto' then cfg.layout = v end
	elseif k == 'label' then
		if v == 'ascii' or v == 'zh' then cfg.label = v end
	elseif k == 'per_row' then
		if v == 'auto' then
			cfg.per_row = 'auto'
		else
			local n = tonumber(v)
			-- 白名单必须覆盖全部档位，否则手写 ini 里的 4/5/6 会被静默丢弃
			if n and n >= 1 and n <= PER_ROW_MAX and n == math.floor(n) then
				cfg.per_row = n
			end
		end
	elseif k == 'show_start' then
		cfg.show_start = (v == '1' or v == 'true')
	elseif k == 'highlight' then
		cfg.highlight = (v == '1' or v == 'true')
	elseif k == 'seq_mode' then
		if v == 'full' or v == 'first' or v == 'priority' then cfg.seq_mode = v end
	elseif k == 'line_px' then
		cfg.line_px = clamp_int(v, 10, 64, cfg.line_px)
	elseif k == 'bottom_px' then
		cfg.bottom_px = clamp_int(v, 0, 200, cfg.bottom_px)
	elseif k == 'col_px' then
		cfg.col_px = clamp_int(v, 0, 64, cfg.col_px)
	elseif k == 'bg_alpha' then
		cfg.bg_alpha = clamp_int(v, 0, 255, cfg.bg_alpha)
	elseif k == 'char_px' then
		cfg.char_px = clamp_int(v, 4, 32, cfg.char_px)
	elseif k == 'wrap' then
		cfg.wrap = (v == '1' or v == 'true')
	elseif k == 'mod_style' then
		-- 白名单：写错档位名不生效、保留默认，避免手写 ini 打错字导致显示异常
		if v == 'short' or v == 'zh' or v == 'hyphen' or v == 'full' then cfg.mod_style = v end
	elseif k == 'joy_style' then
		if v == 'under' or v == 'plain' or v == 'num' or v == 'zh' or v == 'joy'
			or v == 'abxy' or v == 'abxyu' then cfg.joy_style = v end
	elseif k == 'mouse_style' then
		if v == 'under' or v == 'plain' or v == 'num' or v == 'zh' or v == 'mou' then cfg.mouse_style = v end
	elseif k == 'dir_style' then
		if v == 'letter' or v == 'word' or v == 'arrow' or v == 'tri'
			or v == 'arrown' or v == 'trin' then cfg.dir_style = v end
	elseif k == 'hl_phys' or k == 'hl_mirror' or k == 'hl_both' then
		-- 白名单：必须是 HL_COLORS 里存在的 id，否则保留默认，避免手写 ini 打错字
		for _, c in ipairs(HL_COLORS) do
			if c.id == v then cfg[k] = v; break end
		end
	end
end

local function read_into(cfg, path)
	local f = io.open(path, 'r')
	if not f then return false end
	local text = f:read('*a')
	f:close()
	if not text then return false end
	for line in text:gmatch('[^\r\n]+') do
		local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
		if k and v then apply_kv(cfg, k, v) end
	end
	return true
end

-- 把旧版本写在插件目录里的 settings_*.ini 搬到配置目录。
-- 只在目标不存在时搬，搬成功才删源；任何一步失败都留着源文件（读取时有兜底）。
-- 返回搬了几个。
local function migrate_legacy_configs()
	local d = config_dir()
	if not d or not ensure_dir(d) then return 0 end
	if not (plugin_folder and plugin_folder ~= '') then return 0 end
	local ok, lfs = pcall(require, 'lfs')
	if not ok or not lfs then return 0 end
	local moved = 0
	local iter, dobj = nil, nil
	local tok = pcall(function() iter, dobj = lfs.dir(plugin_folder) end)
	if not (tok and iter) then return 0 end
	local names = {}
	for f in iter, dobj do
		if f ~= '.' and f ~= '..' and f:match('^settings_[%w_%-%.]+%.ini$') then
			names[#names + 1] = f
		end
	end
	for _, f in ipairs(names) do
		local target = d .. '/' .. f
		local exists = io.open(target, 'r')
		if exists then
			exists:close()
		else
			local srcp = plugin_folder .. '/' .. f
			local rf = io.open(srcp, 'r')
			if rf then
				local body = rf:read('*a')
				rf:close()
				if body and write_file(target, body) then
					-- 写完回读确认，这才敢删源
					local chk = io.open(target, 'r')
					local okc = false
					if chk then
						okc = (chk:read('*a') == body)
						chk:close()
					end
					if okc then
						os.remove(srcp)
						moved = moved + 1
					end
				end
			end
		end
	end
	return moved
end

local function load_settings()
	local cfg = default_settings()

	-- 读顺序：配置目录优先，插件目录兜底（兼容还没搬过来的旧配置）。
	-- 先读默认，再读本 ROM 覆盖（本 ROM 必须最后读，才能盖过默认值）。
	local d = config_dir()
	local ok_any = false

	local p_rom = settings_path()
	local p_def = d and (d .. '/settings_default.ini') or nil
	if p_def and read_into(cfg, p_def) then ok_any = true end
	if plugin_folder and plugin_folder ~= '' then
		if read_into(cfg, plugin_folder .. '/settings_default.ini') then ok_any = true end
	end

	if p_rom and read_into(cfg, p_rom) then ok_any = true end
	local nm = rom_ini_name()
	if nm and plugin_folder and plugin_folder ~= '' then
		if read_into(cfg, plugin_folder .. '/' .. nm) then ok_any = true end
	end

	settings = cfg
	return ok_any
end

-- ============================================================
-- 采集
-- ============================================================
-- items[pl] = 有序数组，元素 { kind, sem, field, ty, port, mask, defvalue, text }
-- present[pl] = true 表示该玩家有任何可操作字段
local items = {}
local present = {}

local dumped = false

local function dump_tokens(ioport, ports)
	if dumped then return end
	dumped = true
	local n = 0
	for tag, port in pairs(ports) do
		local fields = safe(function() return port.fields end, nil)
		if fields then
			for fname, f in pairs(fields) do
				n = n + 1
				if n > 400 then return end
				local pl = safe(function() return f.player end, -1)
				local ty = safe(function() return f.type end, -1)
				local tok = safe(function() return ioport:input_type_to_token(ty, pl) end, '?')
				emu.print_verbose(string.format('[mame_kbd][dump] %s.%s pl=%s ty=%s tok=%s',
					tostring(tag), tostring(fname), tostring(pl), tostring(ty), tostring(tok)))
			end
		end
	end
	-- 再 dump 通用输入分配表（ioport.types），用于找 SELECT 这类没有 ioport 字段的槽位
	local types = safe(function() return ioport.types end, nil)
	if types then
		for _, t in pairs(types) do
			local tok = safe(function() return t.token end, '?')
			if tostring(tok):match('SELECT') then
				local ty = safe(function() return t.type end, -1)
				local pl = safe(function() return t.player end, -1)
				local nm = safe(function() return t.name end, '?')
				local toks = safe(function() return ioport:input_type_to_token(ty, pl) end, '?')
				emu.print_verbose(string.format('[mame_kbd][type] ty=%s pl=%s token=%s name=%s toktoken=%s',
					tostring(ty), tostring(pl), tostring(tok), tostring(nm), tostring(toks)))
			end
		end
	end
end

-- 精简绑定显示名，用于窄格子（一行四列时每格只有约 80px）。
-- MAME 的 code_name 形如 "Kbd Up" / "Kbd Ctrl" / "Joy 2 Up" / "Joy 1 Start"，
-- 其中 "Kbd " 前缀对键盘按键毫无信息量，占掉 5 个字符位，必须去掉；
-- 手柄则缩写为 J1/J2 以便仍能区分。
-- 注意：必须定义在 seq_text 之前（Lua 的 local 只在定义点之后可见）。
local ABBR = {
	CONTROL = 'Ctrl', CTRL = 'Ctrl', SHIFT = 'Shift', ALT = 'Alt', SPACE = 'Spc',
	ENTER = 'Ent', RETURN = 'Ent', ESCAPE = 'Esc', BACKSPACE = 'Bksp', TAB = 'Tab',
	NUMPAD = 'N', NUM = 'N', PAD = 'N', DELETE = 'Del', INSERT = 'Ins',
	HOME = 'Home', END = 'End', PAGEUP = 'PgUp', PAGEDOWN = 'PgDn',
	-- 左右修饰键：用户指定 LShft / RShft / LCtl / RCtl / LAlt / RAlt。
	-- 去掉了旧版的连字符（旧为 L-Shift / L-Ctrl / L-Alt），Win 键一并统一。
	LSHIFT = 'LShft', RSHIFT = 'RShft', LCTRL = 'LCtl', RCTRL = 'RCtl',
	LALT = 'LAlt', RALT = 'RAlt', LWIN = 'LWin', RWIN = 'RWin',
	CAPSLOCK = 'Caps', PRINTSCREEN = 'PrtSc', SCROLLLOCK = 'Scrlk', PAUSE = 'Pause',
	MINUS = '-', PLUS = '+', EQUALS = '=', COMMA = ',', PERIOD = '.', SLASH = '/',
	BACKSLASH = '\\', SEMICOLON = ';', APOSTROPHE = "'", GRAVE = '`',
	OPENBRACKET = '[', CLOSEBRACKET = ']',
	START = 'Sta', SELECT = 'Sel',
	-- 方向：四个方向各一个字母（用户 m01323 要求：上=U / 下=D / 左=L / 右=R，
	-- 理由「四个方向，基本1个字母就解决了」）。旧版是 Dn / Lt / Rt 两字母。
	-- 与字母键 L / R / D 同字的风险由位置消解：方向键永远只出现在方向行，
	-- 那一行的左侧标签已经写明「上/下/左/右」，不会和按钮行的字母键混淆。
	UP = 'U', DOWN = 'D', LEFT = 'L', RIGHT = 'R',
}

-- 方位修饰键专用缩写（只用于 "Left X" / "Right X" 的 X 部分）。
-- 与 ABBR 分开的理由：ABBR.SHIFT 要给别处保持 'Shift' 五个字符，
-- 而方位键必须压成 'Shft' 才能让 "Left Shift" → 'LShft' 只占 5 位。
local MOD_ABBR = {
	SHIFT = 'Shft', CTRL = 'Ctl', CONTROL = 'Ctl', ALT = 'Alt',
	WIN = 'Win', META = 'Meta', CMD = 'Cmd', GUI = 'Gui',
}

-- 手柄方向显示格式（用户 m01440 要求：只作用于手柄的四个方向）。
-- 四档共用同一套语义键 U/D/L/R，只是画成不同的字符。
--   'letter' = U / D / L / R     （默认，最省位）
--   'word'   = Up / Dn / Lt / Rt （2.8.4 之前的旧形态）
--   'arrow'  = ↑ / ↓ / ← / →
--   'tri'    = ▲ / ▼ / ◀ / ▶
-- 为什么箭头/三角能显示：MAMEUI 的 UI 文字走系统 GDI 字体（部署目录全树没有
-- 任何 .ttf/.bdf/.fon 文件），菜单里原本就在用 '◀' '▶' '↳' 这些符号且显示正常，
-- 这些几何符号和它们同属一个字形族，风险很低。
-- 注意：用户截图里菜单的 ◀ ▶ 是**绿色**的，那是菜单选中态配色；这里的方向字符
-- 跟着格子原本的前景色（方向行是淡黄 C_DIR），不会被菜单配色影响。
local DIR_STYLE_CHARS = {
	letter = { U = 'U',  D = 'D',  L = 'L',  R = 'R' },
	word   = { U = 'Up', D = 'Dn', L = 'Lt', R = 'Rt' },
	arrow  = { U = '↑',  D = '↓',  L = '←',  R = '→' },
	tri    = { U = '▲',  D = '▼',  L = '◀',  R = '▶' },
	-- 无连接符版（用户 m01672：J1↑ / J1▲ 这种写法也要有）。
	-- 字形与 arrow / tri 完全相同，区别只在拼装时不插 '_'。
	arrown = { U = '↑',  D = '↓',  L = '←',  R = '→' },
	trin   = { U = '▲',  D = '▼',  L = '◀',  R = '▶' },
}

-- 哪些档位用「设备名直接接方向」的无连接符写法（J1↑ 而不是 J1_↑）。
-- 单独一张表：方向档位的分隔符不能只看 joy_style，还要看方向档位自己要不要 '_'，
-- 否则 letter 档在 plain 手柄格式下会被 forced 成 J1U，与用户要的 J1_↑ 不一致。
local DIR_NOSEP = { arrown = true, trin = true }

-- 手柄 token 尾部 -> 缩写（JOYCODE_1_YAXIS_UP_SWITCH -> J1_U 等）
-- 方向一律单个字母：U / D / L / R（旧版是 U / Dn / Lt / Rt）
local JOY_MAP = {
	['YAXIS_UP_SWITCH'] = 'U', ['YAXIS_UP'] = 'U',
	['YAXIS_DOWN_SWITCH'] = 'D', ['YAXIS_DOWN'] = 'D',
	['XAXIS_LEFT_SWITCH'] = 'L', ['XAXIS_LEFT'] = 'L',
	['XAXIS_RIGHT_SWITCH'] = 'R', ['XAXIS_RIGHT'] = 'R',
	['HAT1UP'] = 'U', ['HAT1DOWN'] = 'D', ['HAT1LEFT'] = 'L', ['HAT1RIGHT'] = 'R',
	['START'] = 'Sta', ['SELECT'] = 'Sel', ['BACK'] = 'Sel',
}

-- 多词按键名压缩：MAME 对数字键盘返回 "Num 8"、"Num Enter"、"Num Del"，
-- 手柄返回 "Joy 2 Up"。一行四列时每格只有约 82px（约 5 个半角字符），
-- 「Num 8」占 5 字 + 空格正好卡满，四个格连排会糊成一片；「Num Enter」9 字必然截断。
-- 因此把 "Num X" 压成 "N8"/"NEnt"，把长单词按 ABBR 缩写，既保住可辨识度又塞得下。
local function shrink_words(t)
	-- "N <token>" -> "N<缩写>"（数字键盘专用，用户指定 Num 简写成 N，最省位）
	t = t:gsub('^N%s+(%S+)$', function(w)
		local up = w:upper()
		local a = ABBR[up]
		if a and #a <= 2 then return 'N' .. a end
		if up:match('^%d$') then return 'N' .. up end
		if a then return 'N' .. a end
		return 'N' .. w
	end)
	local words = {}
	for w in t:gmatch('%S+') do words[#words + 1] = w end
	if #words == 0 then return t end
	-- 修饰键方位：MAME 会把右侧键显示成 "Right Shift"/"Left Ctrl"。
	-- 输出形态由 settings.mod_style 决定（用户在菜单里可选）：
	--   'short'  = LShft / RShft   （紧凑，一行四列最省位）
	--   'zh'     = 左Shft / 右Shft  （中文方位，更直观但占 2 个字符位）
	--   'hyphen' = L-Shift / R-Shift（2.6.0 旧版形态）
	--   'full'   = Left Shift / Right Shift（MAME 原文，不缩写）
	-- 必须放在单字/通用缩写之前，否则 "Left" 会被当成方向键缩成 "Lt"。
	if #words >= 2 then
		local side = words[1]:upper()
		if side == 'LEFT' or side == 'RIGHT' then
			local mode = settings.mod_style or 'short'
			-- 'full' 档不做任何改写，原样返回（保留 MAME 的原文大小写）
			if mode == 'full' then return t end
			local rest = {}
			for i = 2, #words do
				local w = words[i]
				-- 方位修饰键用专用的短表：Shift 要压成 Shft（不是 Shift），
				-- 而 ABBR.SHIFT 保持 'Shift' 供别处使用，两者不能互相污染。
				-- hyphen 档例外：它要的就是完整的 'Shift'（L-Shift）。
				local a
				if mode == 'hyphen' then
					a = ABBR[w:upper()]
				else
					a = MOD_ABBR[w:upper()] or ABBR[w:upper()]
				end
				if not a and #w > 5 then a = w:sub(1, 4) end
				rest[#rest + 1] = a or w
			end
			local joined = table.concat(rest)
			if mode == 'zh' then
				return (side == 'LEFT' and '左' or '右') .. joined
			end
			local pre = (side == 'LEFT' and 'L' or 'R')
			-- ★ hyphen 档必须显式补连字符。
			-- 踩过的坑：把 '-' 写成 table.concat 的分隔符 —— 当 rest 只有 1 个词
			-- （Left Shift / Left Ctrl / Left Alt 全是，方位词后面就一个词）时，
			-- concat 根本不插入分隔符，结果是 'LShift' 而不是 'L-Shift'。
			if mode == 'hyphen' then return pre .. '-' .. joined end
			return pre .. joined
		end
	end
	-- 单字也查表：用户明确要求 Down->Dn / Left->Lt / Right->Rt 省位置；
	-- 未收录的单字（Up/Home/Tab…）保持原样，缩写反而更难认。
	if #words == 1 then
		local a = ABBR[words[1]:upper()]
		return a or words[1]
	end
	local out = {}
	for _, w in ipairs(words) do
		-- ★ 手柄/鼠标缩写是「设备名 + '_' + 语义后缀」的语义单元，绝不能按长度截断。
		-- 踩过的坑（v2.7.0 引入的回归）：J1_Sta 是 6 个字符，被下面「超过 5 字就截到
		-- 4 字」的通用规则砍成 'J1_S'，屏幕上显示成看不懂的残字；Joy1_1 / Mou1_1
		-- （都是 6 字）同样中招，被砍成 'Joy1' / 'Mou1'。
		-- v2.6.0 时手柄写成 J1Sta（5 字）不触发这条规则，加下划线后长度 +1 才暴露。
		-- 这些形态由 joy_short / mouse_short 生成，长度是设计好的，必须整词保留。
		if w:match('^[JMG]%d') or w:match('^Joy%d') or w:match('^Mou%d')
			or w:match('^手柄%d') or w:match('^鼠标%d') or w:match('^光枪%d') then
			out[#out + 1] = w
		else
			local a = ABBR[w:upper()]
			-- 未收录的词：超过 5 字才截短到 4 字，否则原样保留
			if not a and #w > 5 then a = w:sub(1, 4) end
			out[#out + 1] = a or w
		end
	end
	return table.concat(out, ' ')
end

local function trim_binding(s)
	if not s then return s end
	local t = tostring(s)
	t = t:gsub('^Kbd%s+', '')
	t = t:gsub('^Joy%s+(%d+)%s+', function(n) return 'J' .. n .. ' ' end)
	t = t:gsub('^Joy%s+', 'J ')
	t = shrink_words(t)
	return t
end

local function seq_name_of(seq)
	if not seq then return nil end
	local input = manager and manager.machine and manager.machine.input
	if not input then return nil end
	local ok, s = pcall(function() return input:seq_name(seq) end)
	if not ok or s == nil then return nil end
	s = tostring(s)
	if s == '' or s == 'None' or s == 'none' then return nil end
	return s
end

-- 只取序列里第一个绑定的显示名。
-- 为什么需要它：MAME 一个 field 的默认绑定常是「键盘 Up 或 手柄1上 或 摇杆…」的复合序列，
-- input:seq_name() 会把整串拼出来（实测形如 "Kbd Up or Joy 2 Up or Kbd F or …"），
-- 塞进一格必然溢出。这里用 seq_to_tokens 拿第一个 token，再翻成显示名。
local function first_binding_name(seq)
	if not seq then return nil end
	local input = manager and manager.machine and manager.machine.input
	if not input then return nil end
	local toks = safe(function() return input:seq_to_tokens(seq) end, nil)
	if not toks then return nil end
	toks = tostring(toks)
	local first = toks:match('^(%S+)')
	if not first or first == '' then return nil end
	local code = safe(function() return input:code_from_token(first) end, nil)
	if code ~= nil and code ~= 0 then
		local nm = safe(function() return input:code_name(code) end, nil)
		if nm and tostring(nm) ~= '' then return tostring(nm) end
	end
	-- 兜底：直接把 token 去掉前缀当名字
	return (first:gsub('^KEYCODE_', ''):gsub('^JOYCODE_', 'Joy'))
end

-- 手柄 token 缩写成 "J1_U"/"J1_B1"/"J1_Sta" 这种形式。
-- 依据实测 token：JOYCODE_1_YAXIS_UP_SWITCH / JOYCODE_1_HAT1UP / JOYCODE_1_BUTTON1 / JOYCODE_1_START
local function joy_short(token)
	local n, rest = tostring(token):match('^JOYCODE_(%d+)_(.+)$')
	if not n then return nil end
	local up = rest:upper()
	-- UNKNOWN_SWITCH 表示该槽位没有实际绑定（实测 P3/P4 的 START 就是
	-- "KEYCODE_3 OR JOYCODE_3_UNKNOWN_SWITCH"），必须返回 nil 让上层忽略，
	-- 否则会显示成 "J3UN" 这种无意义文字。
	if up:match('^UNKNOWN') or up:match('^INVALID') then return nil end
	-- 方向单独拆出来：方向要受 settings.dir_style 控制（用户 m01440 要求手柄
	-- 四个方向有独立的显示格式），而按钮/开始/选择不受它影响。
	-- dir_pre 是可能的前缀（多轴手柄的轴名 X/Y/Z/W，或 HAT 编号 H1），dir_core 是
	-- 方向的语义字母 U/D/L/R；两者分开保存，最后再按 dir_style 拼成实际文字。
	local dir_pre, dir_core = '', nil
	local sfx = JOY_MAP[up]
	if sfx then
		-- JOY_MAP 里只有方向和 START/SELECT；方向值恰好是单字母 U/D/L/R
		if sfx == 'U' or sfx == 'D' or sfx == 'L' or sfx == 'R' then
			dir_core = sfx
			sfx = nil
		end
	end
	if not sfx and not dir_core then
		local b = up:match('^BUTTON(%d+)$')
		if b then sfx = 'B' .. b end
	end
	if not sfx and not dir_core then
		-- 必须同时捕获「轴名」与「方向」两个值：只捕获轴名却拿去按方向查表，
		-- 这个分支永远不会命中（曾经的实际 bug）。
		local ax, ad = up:match('^([XYZW])AXIS_(%a+)_SWITCH$')
		if ax and ad then
			local dir = ({ UP = 'U', DOWN = 'D', LEFT = 'L', RIGHT = 'R' })[ad]
			if dir then dir_pre, dir_core = ax, dir end
		end
	end
	if not sfx and not dir_core then
		-- 同上：编号与方向要各自捕获。
		local hn, hd = up:match('^HAT(%d)(%u+)$')
		if hn and hd then
			local dir = ({ UP = 'U', DOWN = 'D', LEFT = 'L', RIGHT = 'R' })[hd]
			if dir then dir_pre, dir_core = 'H' .. hn, dir end
		end
	end
	if not sfx and not dir_core then
		sfx = up:gsub('_SWITCH$', ''):gsub('AXIS_', '')
		if #sfx > 5 then sfx = sfx:sub(1, 5) end
	end
	-- 显示形态由 settings.joy_style 决定（用户在菜单里可选）：
	--   'under' = J1_B1 / J1_U / J1_Sta   （默认，下划线分隔最易读）
	--   'plain' = J1B1  / J1U  / J1Sta    （最省位）
	--   'num'   = J1_1  / J1_U / J1_D     （按钮去掉 B；方向无序号，仍用字母）
	--   'zh'    = 手柄1_1 / 手柄1_U       （中文设备名 + 按钮去 B）
	--   'joy'   = Joy1_1 / Joy1_U         （英文前缀 + 按钮去 B）
	--   'abxy'  = J1A / J1B / J1X / J1Y / J1L1 / J1R1 / J1L2 / J1R2  （字母式，无分隔）
	--   'abxyu' = J1_A / J1_B / J1_X / J1_Y / J1_L1 / J1_R1 / J1_L2 / J1_R2（字母式，有分隔）
	local mode = settings.joy_style or 'under'

	-- ★ 方向单独一条路径：方向文字由 settings.dir_style 决定，
	-- 与 joy_style 无关（用户 m01440 要求「只针对手柄的 4 个方向的显示格式」）。
	-- 四档：letter=U/D/L/R、word=Up/Dn/Lt/Rt、arrow=↑↓←→、tri=▲▼◀▶。
	-- 注意这里保留设备前缀（J1_）与轴/HAT 前缀（X / H1），只替换方向字符本身，
	-- 这样「哪个手柄的哪个方向」仍然一眼可辨，只是方向怎么画变了。
	if dir_core then
		local dstyle = settings.dir_style or 'letter'
		local d = DIR_STYLE_CHARS[dstyle]
		local glyph = (d and d[dir_core]) or dir_core
		-- ★ 方向格的连接符只由方向档位自己决定，与手柄格式(joy_style)无关。
		-- 六档里 letter / word / arrow / tri 带 '_'，arrown / trin 不带。
		-- 踩过的坑（用户 m01774 实测报障）：v2.8.6 写成了
		--   local sep = ((mode == 'plain' or mode == 'abxy') and '' or '_')
		--   if DIR_NOSEP[dstyle] then sep = '' end
		-- 于是手柄格式选 abxy 时，arrow 档也输出 J1↑，与 arrown 档完全一样，
		-- 菜单「实际效果」写着 J1_↑ 而画面画的是 J1↑，六档看起来全无区别。
		-- 方向格式是独立维度，它的分隔符必须自己说了算。
		local sep = DIR_NOSEP[dstyle] and '' or '_'
		local dev
		if mode == 'zh' then
			dev = '手柄' .. n
		elseif mode == 'joy' then
			dev = 'Joy' .. n
		else
			dev = 'J' .. n
		end
		return dev .. sep .. dir_pre .. glyph
	end

	-- 字母式档位：按钮 1~8 映射成 ABXY 与 L1/R1/L2/R2。
	-- 依据用户 m01231 要求「再增加 J1ABXY 和 J1_ABXY……新的就是 J1_A 和 J1A」，
	-- 按钮 5~8 的写法由用户 m01242 明确选择 L1/R1/L2/R2（不用 C/Z/L/R）。
	if mode == 'abxy' or mode == 'abxyu' then
		local b = sfx:match('^B(%d+)$')
		if b then
			local LETTER = { ['1'] = 'A', ['2'] = 'B', ['3'] = 'X', ['4'] = 'Y',
			                 ['5'] = 'L1', ['6'] = 'R1', ['7'] = 'L2', ['8'] = 'R2' }
			sfx = LETTER[b] or sfx
		end
		local sep = (mode == 'abxyu') and '_' or ''
		return 'J' .. n .. sep .. sfx
	end
	-- ★ 去 B 的档位是 num / zh / joy 三档，不是只有 num。
	-- 依据：用户原话举例「手柄的按键显示可以自定义选择显示 J1B1 J1_1 手柄1_1，
	-- Joy1_1」—— 后三档给的示例全是「_1」数字式，没有一个带 B。
	-- 曾经把去 B 只写在 num 档，结果 zh/joy 档输出「手柄1_B1 / Joy1_B1」，
	-- 和用户给的示例对不上。
	local digitized = (mode == 'num' or mode == 'zh' or mode == 'joy')
	if digitized then
		-- 只有按钮序号可以去掉 B：方向键 U/D/L/R 没有数字含义，
		-- 强行数字化会变成 "J1_8" 这种要靠背的写法（用户已确认保持字母）。
		local b = sfx:match('^B(%d+)$')
		if b then sfx = b end
	end
	local sep = (mode == 'plain') and '' or '_'
	local dev
	if mode == 'zh' then
		dev = '手柄' .. n
	elseif mode == 'joy' then
		dev = 'Joy' .. n
	else
		dev = 'J' .. n
	end
	return dev .. sep .. sfx
end

-- 鼠标/光枪 token 缩写成 "M1_B1"/"G1_B1" 这种形式，与手柄的 "J1_B1" 同构。
-- 依据实测 token：MOUSECODE_1_BUTTON1 / MOUSECODE_1_BUTTON3 / GUNCODE_1_BUTTON1
-- 输出形态由 settings.mouse_style 决定，档位与手柄一致：
--   'under' = M1_B1 / 'plain' = M1B1 / 'num' = M1_1 / 'zh' = 鼠标1_B1 / 'mou' = Mou1_B1
local function mouse_short(token)
	local t = tostring(token):upper()
	local n, rest = t:match('^MOUSECODE_(%d+)_(.+)$')
	local prefix = 'M'
	local is_gun = false
	if not n then
		n, rest = t:match('^GUNCODE_(%d+)_(.+)$')
		prefix = 'G'
		is_gun = true
	end
	if not n then return nil end
	local mode = settings.mouse_style or 'under'
	local sep = (mode == 'plain') and '' or '_'
	local function dev()
		if mode == 'zh' then
			-- 光枪也走中文名，否则同一档位下手柄中文、光枪英文，风格不统一
			return (is_gun and '光枪' or '鼠标') .. n
		elseif mode == 'mou' then
			return 'Mou' .. n
		else
			return prefix .. n
		end
	end
	local function numify(s)
		-- 与手柄侧保持一致：num / zh / mou 三档都去掉按钮的 B 前缀
		-- （用户举例里「手柄1_1 / Joy1_1」全是数字式，鼠标档同理同构）。
		if mode ~= 'num' and mode ~= 'zh' and mode ~= 'mou' then return s end
		local b = s:match('^B(%d+)$')
		return b or s
	end
	local b = rest:match('^BUTTON(%d+)$')
	if b then return dev() .. sep .. numify('B' .. b) end
	-- 注意要同时捕获轴名与方向两个值：只捕获第一个的话，下面按方向查表
	-- （POS/NEG/INC/DEC）永远查不到，整个轴分支会静默失效。
	local ax, ad = rest:match('^([XY])AXIS_(%a+)$')
	if ax and ad then
		local dir = ({ POS = '+', NEG = '-', INC = '+', DEC = '-' })[ad]
		if dir then return dev() .. sep .. ax .. dir end
	end
	local sfx = rest:gsub('_SWITCH$', ''):gsub('AXIS_', '')
	if #sfx > 5 then sfx = sfx:sub(1, 5) end
	return dev() .. sep .. numify(sfx)
end

-- 把一个绑定序列拆成「键盘名 + 手柄名 + 鼠标名」三路。
-- 为什么不能只看第一个 token：实测 BUTTON1 = KEYCODE_LCONTROL OR MOUSECODE_1_BUTTON1
-- OR GUNCODE_1_BUTTON1 OR JOYCODE_1_BUTTON1，START = JOYCODE_1_START OR KEYCODE_1。
-- 只取第一个会丢掉手柄（或丢掉键盘），而用户明确要求「手柄的1也要显示」。
-- 因此按类型各取第一个：键盘取第一个 KEYCODE_*，手柄取第一个 JOYCODE_*，
-- 鼠标/光枪取第一个 MOUSECODE_*/GUNCODE_*（供「优先次序」模式使用）。
local function seq_dual(seq)
	if not seq then return nil, nil, nil end
	local input = manager and manager.machine and manager.machine.input
	if not input then return nil, nil, nil end
	local toks = safe(function() return input:seq_to_tokens(seq) end, nil)
	if not toks then return nil, nil, nil end

	local kb, joy, mouse = nil, nil, nil
	for tok in tostring(toks):upper():gmatch('[^%s]+') do
		if tok == 'OR' then
			-- 分隔符，跳过
		elseif not kb and tok:match('^KEYCODE_') then
			local code = safe(function() return input:code_from_token(tok) end, nil)
			if code ~= nil and code ~= 0 then
				local nm = safe(function() return input:code_name(code) end, nil)
				if nm and tostring(nm) ~= '' then kb = trim_binding(tostring(nm)) end
			end
			if not kb then
				kb = trim_binding((tok:gsub('^KEYCODE_', '')))
			end
		elseif not joy and tok:match('^JOYCODE_') then
			joy = joy_short(tok)
		elseif not mouse and (tok:match('^MOUSECODE_') or tok:match('^GUNCODE_')) then
			mouse = mouse_short(tok)
		end
	end
	return kb, joy, mouse
end

-- 单个 field 最终生效的绑定文本（三级回退）
DBG_EMPTY = 0
DBG_NAMED = 0
DBG_ITEMS = 0
local function seq_text(f, ty, pl)
	local seq = safe(function() return f:input_seq('standard') end, nil)
	local dbg_first = seq
	if not (seq and not safe(function() return seq.empty end, false)) then
		seq = nil
	end
	if not seq then
		local dseq = safe(function() return f:default_input_seq('standard') end, nil)
		if dseq and not safe(function() return dseq.empty end, false) then
			seq = dseq
		end
	end
	if not seq and ty then
		local ioport = manager and manager.machine and manager.machine.ioport
		if ioport then
			local tseq = safe(function() return ioport:type_seq(ty, pl) end, nil)
			if tseq and not safe(function() return tseq.empty end, false) then
				seq = tseq
			end
		end
	end
	-- 诊断：只在 seq 为空时打印一次每项的中间状态，定位为什么拿不到绑定文本
	if not seq then
		DBG_EMPTY = DBG_EMPTY + 1
		if DBG_EMPTY <= 24 then
			local t1 = safe(function() return tostring(dbg_first) end, 'nil')
			local e1 = safe(function() return tostring(dbg_first and dbg_first.empty) end, 'nil')
			local t2 = safe(function() return tostring(f:default_input_seq('standard')) end, 'nil')
			local t3 = safe(function() return tostring(manager.machine.ioport:type_seq(ty, pl)) end, 'nil')
			emu.print_info(string.format('[mame_kbd][seqnil] %s ty=%s pl=%s first=%s first.empty=%s def=%s typeseq=%s',
				tostring(safe(function() return f.name end, '?')), tostring(ty), tostring(pl), t1, e1, t2, t3))
		end
		return nil
	end

	if settings.seq_mode == 'full' then
		local full = seq_name_of(seq)
		-- 全部绑定模式下仍去掉 "Kbd " 前缀，否则更挤
		return full and trim_binding(full) or nil
	end

	-- 三路绑定都已取出，供「优先次序」模式按 手柄 > 键盘 > 鼠标 择一显示，
	-- 也供方向行这类极窄格做「上下两行」排版。
	local kb, joy, mouse = seq_dual(seq)
	local nm = nil

	if settings.seq_mode == 'priority' then
		-- 优先次序：只显示最高优先级那一路（手柄 > 键盘 > 鼠标）。
		-- 依据用户要求：「如果绑定了手柄的，只显示手柄的按键，如果没有绑定手柄就
		-- 显示键盘的按键，如果只绑定了鼠标，就显示鼠标的」。
		nm = joy or kb or mouse
	end

	if not nm then
		-- 'first'（默认，键盘与手柄都显示）与 priority 的兜底路径共用这段：
		-- 拼接顺序固定为「键盘 手柄」，宽度不够时由 split_cell 换行兜住。
		if kb and joy then nm = kb .. ' ' .. joy
		elseif kb then nm = kb
		elseif joy then nm = joy
		elseif mouse then nm = mouse end
	end

	if not nm then
		nm = first_binding_name(seq) or seq_name_of(seq)
		nm = nm and trim_binding(nm) or nil
	end
	-- 诊断：seq 有值但取不出名字时，把中间量打出来（xmen 就是这种情况）
	if not nm then
		DBG_NAMED = DBG_NAMED + 1
		if DBG_NAMED <= 24 then
			local input = safe(function() return manager.machine.input end, nil)
			local toks = input and safe(function() return input:seq_to_tokens(seq) end, nil)
			local len = safe(function() return seq.length end, nil)
			local snake = input and safe(function() return input:seq_name(seq) end, nil)
			emu.print_info(string.format('[mame_kbd][seqnoname] %s ty=%s pl=%s len=%s toks=%s seq_name=%s',
				tostring(safe(function() return f.name end, '?')), tostring(ty), tostring(pl),
				tostring(len), tostring(toks), tostring(snake)))
		end
		return nil
	end
	-- priority 模式只显示一路，不能把另两路也返回：方向行的两行排版判定
	-- （dir_lines_of 要求 kb_text 与 joy_text 同时存在）会因此误判成需要两行。
	if settings.seq_mode == 'priority' then
		return trim_binding(nm), nil, nil
	end
	return trim_binding(nm), kb, joy
end

-- 某个 field 当前的【最终值】是否按下（含物理按键 + 别的插件 set_value 的覆盖）。
--
-- ★★ 2026-11-09 真机探针实测（xmen，P1_BUTTON1）——推翻了先前的假设：
--     set_value(1) 后：port:read() 65535 → 65519（mask=16 位被清），
--                      而 ioport:type_pressed(ty, pl) 对 pl=0/1/2/3 恒为 false。
--   即：type_pressed 只看【物理设备】，看不见程序化覆盖；
--       port:read() 才是【最终值】。
--   （旧代码正好反着用——首选 type_pressed 并直接 return，导致镜像格永不变色。）
--
-- 极性判据：不能写 band(v, m) ~= 0。本机未按键时 port:read() 返回 65535（全 1），
-- 按下时对应位【清零】；换成高有效端口则相反。用「与 defvalue 的同掩码位比较」
-- 就与极性无关：band(read, mask) ~= band(defvalue, mask) 即按下。
local function field_pressed(item)
	local port = item.port
	local m = item.mask
	if port and m and m ~= 0 then
		local v = safe(function() return port:read() end, nil)
		if v ~= nil then
			local cur = band(v, m)
			local dv = item.defvalue
			if dv == nil then
				-- 没有 defvalue 时退回「非零即按下」的老判据（只在高有效端口上可靠）。
				return cur ~= 0
			end
			return cur ~= band(dv, m)
		end
	end
	-- 虚拟项（如 P1_SELECT / STARTn，没有 port 与 field）只能问官方 API。
	local ioport = safe(function() return manager.machine.ioport end, nil)
	if ioport and item.ty then
		local fpl = item.press_player or 0
		local ok, pressed = pcall(function() return ioport:type_pressed(item.ty, fpl) end)
		if ok and pressed ~= nil then
			return (pressed == true) or (tonumber(pressed) or 0) ~= 0
		end
	end
	return false
end

-- 该字段当前是否被【物理设备】按下（不含别的插件写进来的覆盖值）。
--
-- ★★ 2026-11-09 真机探针实测（xmen，P1_BUTTON1，见 scaffold/probe_plugin）：
--     field:set_value(1) 之后，
--       ioport:type_pressed(ty, pl)  对 pl=0/1/2/3 恒为 false  ← 看不见覆盖
--       port:read() & mask           mask 位被清零            ← 看得见覆盖
--     即 type_pressed 读的是【物理设备状态】，port:read() 才是【最终值】。
--   这与先前注释里的猜测正好相反，也是「镜像蓝/同时金不出现」的根因。
--
-- 因此这里的物理判据首选 type_pressed（官方 API，物理按键时可靠返回 true）；
-- seq_pressed 只作为次要回退——在取不到 seq 时它会返回 false，若当主判据会把
-- 真实的物理按下误判成「镜像」（绿→蓝），那是比不变色更糟的错误。
local function field_physical_pressed(item)
	local ioport = safe(function() return manager.machine.ioport end, nil)
	if ioport and item.ty then
		local fpl = item.press_player or 0
		local ok, pressed = pcall(function() return ioport:type_pressed(item.ty, fpl) end)
		if ok and pressed ~= nil then
			return (pressed == true) or (tonumber(pressed) or 0) ~= 0
		end
	end
	-- 回退：input:seq_pressed(seq) 读物理设备绑定状态，set_value 同样改不动它。
	local input = safe(function() return manager.machine.input end, nil)
	if not input then return nil end
	local seq = nil
	if item.field then
		seq = safe(function() return item.field:input_seq('standard') end, nil)
		if (not seq) or safe(function() return seq.empty end, true) then
			seq = safe(function() return item.field:default_input_seq('standard') end, nil)
		end
	end
	if (not seq) or safe(function() return seq.empty end, true) then
		if ioport and item.ty then
			seq = safe(function() return ioport:type_seq(item.ty, item.press_player or 0) end, nil)
		end
	end
	if (not seq) or safe(function() return seq.empty end, true) then return nil end
	local ok2, pressed2 = pcall(function() return input:seq_pressed(seq) end)
	if not ok2 then return nil end
	return pressed2 and true or false
end

-- 「本格曾经只被镜像驱动过」的标记表。
-- 用途：判断本格「先被镜像顶着，然后自己又物理按下」= 同时按下（金）。
--
-- 为什么需要它：MAME 的最终值只有 0/1，自己物理按下是 1，镜像写 set_value(1)
-- 也是 1，任何 API 都看不出这个 1 是谁写的。唯一可靠的时序信号是：
--   先看到「最终值为真但物理为假」（= 只有镜像能造成）→ 记下本格确实被镜像驱动，
--   之后它变成「最终值真且物理真」→ 说明自己的物理按下叠加在镜像之上。
--
-- ★ 不用「另一个玩家是否也按着同一键」来侧推。2026-11-09 实测推翻了这个做法：
--   copilot2p 是 P1→P2..P4 单向镜像，若 P1 与 P2 同时物理按 Button1，
--   按那个判据 P1 的格子也会被判成金色 —— 但 P1 恰恰是源、从未被写入。
--   逐格时序标记没有这个误判：P1 那格从来没有「物理假但最终值真」的时刻。
--
-- key = 玩家号 | 语义类别 | 语义键；跨 rebuild_bindings 保留（items 每 60 帧重建）。
local mirror_flag = {}

local function mirror_key(item)
	return tostring(item.player or 0) .. '|'
		.. tostring(item.kind or '') .. '|'
		.. tostring(item.sem or '')
end

-- 三种来源的工作状态，供绘制层统一取色：
--   0 = 没按下；1 = 仅物理按下；2 = 仅被镜像按下；3 = 物理与镜像同时按下
local PRESS_NONE, PRESS_PHYS, PRESS_MIRROR, PRESS_BOTH = 0, 1, 2, 3
local function press_state(item)
	if not item then return PRESS_NONE end
	if not field_pressed(item) then
		-- 松开就清标记：下次按下重新从头判断。
		mirror_flag[mirror_key(item)] = nil
		return PRESS_NONE
	end
	local phys = field_physical_pressed(item)
	if phys == nil then
		-- 拿不到物理状态（老 ROM / API 差异），只能保守当成物理按下。
		return PRESS_PHYS
	end
	local k = mirror_key(item)
	if not phys then
		-- 最终值为真、物理为假 —— 只能是别的插件写进来的（镜像）。
		mirror_flag[k] = true
		return PRESS_MIRROR
	end
	-- 物理确实按着。这格刚才是不是已经被镜像顶着？是则算叠加。
	if mirror_flag[k] then return PRESS_BOTH end
	return PRESS_PHYS
end

local function rebuild_bindings()
	items = {}
	present = {}

	local machine = manager and manager.machine
	if not machine then return end
	local ioport = machine.ioport
	if not ioport then return end
	local ports = safe(function() return ioport.ports end, nil)
	if not ports then return end

	dump_tokens(ioport, ports)

	-- 收集：collected[pl][key] = item
	local collected = {}

	for tag, port in pairs(ports) do
		local fields = safe(function() return port.fields end, nil)
		if fields then
			for fname, f in pairs(fields) do
				local ty = safe(function() return f.type end, nil)
				local analog = safe(function() return f.is_analog end, false)
				local enabled = safe(function() return f.enabled end, false)
				local pl_raw = safe(function() return f.player end, 0)

				if ty and enabled and not analog then
					local tok = safe(function() return ioport:input_type_to_token(ty, pl_raw) end, nil)
					local pl, kind, sem = parse_token(tok)

					-- parse_token 只在 DIR/BUTTON/START/SELECT 这四类上返回非 nil，
					-- 因此这里天然完成了白名单过滤（COIN/SERVICE/DIP 等解析不出、自动丢弃）。
					if pl and pl >= 0 and pl <= 3 then
						local mask = safe(function() return f.mask end, 0)
						local defv = safe(function() return f.defvalue end, nil)
						local txt, kb_txt, joy_txt = seq_text(f, ty, pl)
						local item = {
							kind = kind,
							sem = sem,
							field = f,
							ty = ty,
							port = port,
							mask = mask,
							defvalue = defv,
							player = pl,
							-- 查按下状态时要传给 ioport:type_pressed 的 player：
							-- 真实字段用字段自身的 player（DIR/BUTTON/START 的 ty 已内含玩家号，
							-- 其 field.player 恒为 0）；虚拟项另在下面覆盖。
							press_player = pl_raw,
							field_name = tostring(fname),
							text = txt,
							-- 键盘 / 手柄两路分开存，方向行的极窄格要按路排版
							kb_text = kb_txt,
							joy_text = joy_txt,
						}
						collected[pl] = collected[pl] or {}
						-- 同一玩家同一语义可能出现在多个 port，取第一个
						if not collected[pl][sem] then
							collected[pl][sem] = item
						end
					end
				end
			end
		end
	end

	-- 补「虚拟槽位」：有些输入在游戏里没有对应的 ioport 字段，只存在于
	-- MAME 的通用输入分配表（ioport.types）里。实测两类：
	--   选择 SELECT：ty=43，token=P1_SELECT…P10_SELECT
	--   开始 START ：ty=7…14，token=START1…START8
	-- 3stooges / tmnt 就是后一类——它们的 ports 里完全没有 START 字段（dump 只有
	-- Coin / Tilt / Service / 方向 / 按钮），于是「开始」那格永远是 --，而用户在
	-- MAME 的「输入配置」里看到的是 Kbd 1 or Joy 1 Start 已绑定。
	-- 这类槽位没有 port/mask，按下状态只能靠 ioport:type_pressed(ty, player) 获得。
	--
	-- ★ 只给「真有输入字段」的玩家补。
	-- 踩过的坑（用户 m01882 报障）：这段原来无条件给 P1~P4 都补，而 MAME 的
	-- 通用输入分配表里 P1_SELECT…P4_SELECT / START1…START4 槽位永远存在，
	-- 哪怕游戏只有 3 名玩家。于是 P4 靠这条虚构项把 present[3] 撑成 true，
	-- 「仅实际玩家」档仍然画出第 4 列（3stooges 只有 :P1JOY/:P2JOY/:P3JOY，
	-- 1941 更是 players="2"），整列全是「上:- 下:- 开始:--」，白占地方还把
	-- 别的列挤窄。判据：这个玩家已经收集到过真实字段，才值得补虚拟槽位。
	local has_real_field = {}
	for pl = 0, 3 do
		local c = collected[pl]
		has_real_field[pl] = c ~= nil and next(c) ~= nil
	end

	-- 把一条通用输入分配（ioport.types）转成可绘制的虚拟项。
	-- vtok：token_to_input_type 用的 token；vpl：type_seq / type_pressed 的玩家号
	-- （SELECT 用 types 里的 player，START 传 0，因为 START1..8 的枚举已内含编号）。
	local function fill_virtual(pl, sem, vtok, vpl)
		if not has_real_field[pl] then return end
		if collected[pl] and collected[pl][sem] then return end
		local ty, tpl = nil, nil
		local ok, rty, rpl = pcall(function() return ioport:token_to_input_type(vtok) end)
		if ok then
			ty = rty
			tpl = rpl
		end
		if not ty then return end
		local use_pl = tpl
		if use_pl == nil then use_pl = vpl end
		if use_pl == nil then use_pl = pl end
		local tseq = nil
		do
			local ok2, s2 = pcall(function() return ioport:type_seq(ty, use_pl) end)
			if ok2 and s2 and not safe(function() return s2.empty end, false) then
				tseq = s2
			end
		end
		if not tseq then return end
		local full = seq_name_of(tseq)
		local txt = nil
		if settings.seq_mode == 'full' then
			txt = full and trim_binding(full) or nil
		else
			-- 与 seq_text 保持一致：priority 模式只取最高优先级那一路，
			-- 其余模式键盘 + 手柄各取一个同时显示
			local kb, jy, ms = seq_dual(tseq)
			if settings.seq_mode == 'priority' then
				txt = jy or kb or ms
			else
				if kb and jy then txt = kb .. ' ' .. jy
				elseif kb then txt = kb
				elseif jy then txt = jy
				elseif ms then txt = ms end
			end
			if not txt then
				local nm = first_binding_name(tseq) or full
				txt = nm and trim_binding(nm) or nil
			end
		end
		if not txt then return end
		collected[pl] = collected[pl] or {}
		collected[pl][sem] = {
			kind = sem,
			sem = sem,
			field = nil,
			ty = ty,
			port = nil,
			mask = nil,
			defvalue = nil,
			player = pl,
			-- ioport:type_pressed(ty, player) 才是这条虚拟项的正确查法
			press_player = use_pl,
			field_name = vtok,
			text = txt,
		}
	end

	for pl = 0, 3 do
		-- 选择：token 形如 P1_SELECT
		fill_virtual(pl, 'SELECT', 'P' .. (pl + 1) .. '_SELECT', pl)
		-- 开始：token 形如 START1（ty=7..14），其 player 恒为 0
		fill_virtual(pl, 'START', 'START' .. (pl + 1), 0)
	end

	-- 兜底清理：把「只靠虚拟槽位（SELECT/START）撑着」的玩家整条去掉。
	-- 正常路径上 has_real_field 已经挡住了，这里再兜一层，防止将来有人
	-- 在 SELECT 之前又加了别的虚拟补位项而把玩家数撑大。
	-- 判据：这个玩家除了 SELECT 之外一个真实字段都没有，就不算实际玩家。
	for pl = 0, 3 do
		local c = collected[pl]
		if c then
			local real = 0
			for sem, item in pairs(c) do
				if item and item.field then
					real = real + 1
				end
			end
			if real == 0 then
				collected[pl] = nil
			end
		end
	end

	-- 整理成有序数组：方向 → 选择/开始 → 按键 1..16
	for pl = 0, 3 do
		local c = collected[pl]
		if c then
			local list = {}
			for _, sem in ipairs(DIR_ORDER) do
				if c[sem] then list[#list + 1] = c[sem] end
			end
			if c['SELECT'] then list[#list + 1] = c['SELECT'] end
			if c['START'] then list[#list + 1] = c['START'] end
			for i = 1, MAX_BUTTON do
				local it = c['BUTTON' .. i]
				if it then list[#list + 1] = it end
			end
			if #list > 0 then
				items[pl] = list
				present[pl] = true
			end
		end
	end

	local function cnt(pl)
		local c = 0
		local l = items[pl]
		if l then
			for _, it in ipairs(l) do
				if it.kind == 'BUTTON' then c = c + 1 end
			end
		end
		return c
	end

	emu.print_verbose(string.format('[mame_kbd] rebuild rom=%s P1=%d P2=%d P3=%d P4=%d 按钮数=%d/%d/%d/%d',
		tostring(current_rom()), items[0] and #items[0] or 0, items[1] and #items[1] or 0,
		items[2] and #items[2] or 0, items[3] and #items[3] or 0,
		cnt(0), cnt(1), cnt(2), cnt(3)))

	-- 诊断：把 P1 每一项的 kind/sem/text 打出来，用于定位「有 item 但显示 --」
	if DBG_ITEMS < 1 then
		DBG_ITEMS = DBG_ITEMS + 1
		for pl = 0, 3 do
			for _, it in ipairs(items[pl] or {}) do
				emu.print_info(string.format('[mame_kbd][item] P%d sem=%s kind=%s ty=%s text=%s',
					pl + 1, tostring(it.sem), tostring(it.kind), tostring(it.ty), tostring(it.text)))
				-- 同时打出该字段的完整 token 串，用于确定手柄/键盘 token 的真实格式
				if it.field then
					local s0 = safe(function() return it.field:input_seq('standard') end, nil)
					if not (s0 and not safe(function() return s0.empty end, false)) then
						s0 = safe(function() return it.field:default_input_seq('standard') end, nil)
					end
					if s0 then
						local input = safe(function() return manager.machine.input end, nil)
						local tk = input and safe(function() return input:seq_to_tokens(s0) end, nil)
						emu.print_info(string.format('[mame_kbd][toks] P%d %s = %s',
							pl + 1, tostring(it.sem), tostring(tk)))
					end
				end
			end
		end
	end
end

-- ============================================================
-- 绘制
-- ============================================================
local C_BG = 0xC8000000          -- 半透明黑底
local C_EDGE = 0xFF3C3C3C        -- 列边框
local C_TITLE = 0xFF00E0FF       -- 玩家标题：亮青
local C_DIR = 0xFFFFFF80          -- 方向：淡黄
local C_SPECIAL = 0xFF80D0FF      -- 选择/开始：淡蓝
local C_BTN = 0xFFE8E8E8          -- 按键：近白
local C_NONE = 0xFF909090         -- 未绑定：灰
-- 按下高亮的三种颜色已改为可配（见文件上方的 HL_COLORS 与 settings.hl_*），
-- 这里不再保留 C_HL / C_MIR / C_BOTH 常量——留着会被误当成真值引用。
--
-- 判定依据（v2.9.1 真机探针实证，与早期注释写的正好相反）：
--   ioport:type_pressed(ty, pl)  读【物理设备】状态，看不见 set_value 覆盖
--   port:read()                  读【最终值】，含别的插件 set_value 写进来的覆盖
--   input:seq_pressed(seq)       读【物理绑定】，同样看不见覆盖
-- 所以 field_pressed 走 port:read()，field_physical_pressed 走 type_pressed。

-- 取色：把「工作状态」翻译成前景色/背景色。highlight 关闭时一律用原色。
-- v2.9.2：三种状态的颜色改为用户可配（菜单「按键颜色」页），从 HL_COLORS 取。
local function press_color(st, base)
	if not settings.highlight or st == PRESS_NONE then return base, nil end
	local c
	if st == PRESS_PHYS then c = hl_pick(settings.hl_phys)
	elseif st == PRESS_MIRROR then c = hl_pick(settings.hl_mirror)
	elseif st == PRESS_BOTH then c = hl_pick(settings.hl_both)
	else return base, nil end
	return c.fg, c.bg
end

local LABEL_ZH = {
	UP = '上', DOWN = '下', LEFT = '左', RIGHT = '右',
	SELECT = '选择', START = '开始',
}
local LABEL_ASCII = {
	UP = 'U', DOWN = 'D', LEFT = 'L', RIGHT = 'R',
	SELECT = 'Sel', START = 'Sta',
}

local function sem_label(sem, kind)
	if kind == 'DIR' or kind == 'START' or kind == 'SELECT' then
		local tbl = (settings.label == 'zh') and LABEL_ZH or LABEL_ASCII
		return tbl[sem] or tostring(sem)
	end
	-- BUTTONn
	return tostring(sem):gsub('^BUTTON', '')
end

-- 诊断计数
local draw_calls = 0
local draw_errors = 0
local last_err = nil
local draw_ok_once = false
local draw_frames = 0
local lit_sig = nil      -- 上一次的「按下项签名」，只有变化才打日志

local function dt(container, x, y, text, fg, bg)
	if not text or text == '' then return end
	local ok, err
	if bg then
		ok, err = pcall(function() container:draw_text(x, y, text, fg, bg) end)
	else
		ok, err = pcall(function() container:draw_text(x, y, text, fg) end)
	end
	if not ok then draw_errors = draw_errors + 1; last_err = tostring(err) end
	draw_calls = draw_calls + 1
end

-- 估算字符串的「显示宽度」：ASCII 记 1，中日韩全角字符记 2。
-- 不能用 #text 直接当宽度 —— UTF-8 里一个汉字占 3 字节但只占 2 个字符位。
-- 返回每一段的 (宽度, 占用字节数)
local function next_char(s, i)
	local b = s:byte(i)
	if not b then return nil end
	if b < 0x80 then return 1, 1 end
	if b >= 0xF0 then return 2, 4 end
	if b >= 0xE0 then return 2, 3 end
	return 2, 2
end

local function disp_width(s)
	local w, i = 0, 1
	while i <= #s do
		local cw, adv = next_char(s, i)
		if not cw then break end
		w = w + cw
		i = i + adv
	end
	return w
end

-- 按显示宽度截断，超出时结尾用 '..'
local function fit(text, maxw)
	if not text or text == '' then return '' end
	maxw = math.floor(maxw)
	if maxw <= 2 then return '' end
	if disp_width(text) <= maxw then return text end
	local kept, w, i = {}, 0, 1
	local limit = maxw - 2
	while i <= #text do
		local cw, adv = next_char(text, i)
		if not cw then break end
		if w + cw > limit then break end
		kept[#kept + 1] = text:sub(i, i + adv - 1)
		w = w + cw
		i = i + adv
	end
	return table.concat(kept) .. '..'
end

-- 把「标签:绑定名」拆成最多两行以适应窄格。
-- 返回行数组（1 或 2 个元素）。
--
-- 为什么需要它：MAME 的 UI 文字是固定字模，draw_text 没有字号参数
-- （已核实 docs.mamedev.org ref-render：签名只有 x/y/text/fg/bg），
-- 所以「字号调小」做不到；能做的只有换行，让长键名占用两行的水平空间。
--
-- 压缩顺序（从好到差）：
--   1) 原样「1:Right Ctrl」放得下 → 一行；
--   2) 去掉绑定名里的空格「1:RightCtrl」放得下 → 一行；
--   3) 按空格切词贪心填第一行，剩下的放第二行（标签始终留在第一行）；
--   4) 标签本身就超宽 → 第一行只放标签、第二行放绑定名并截断。
local function split_cell(label, text, maxw)
	local head = tostring(label) .. ':'
	text = tostring(text or '--')

	local full = head .. text
	if disp_width(full) <= maxw then return { full } end

	local tight = head .. (text:gsub('%s+', ''))
	if disp_width(tight) <= maxw then return { tight } end

	-- 关闭自动换行时直接截断（保持单行版式）
	if not settings.wrap then return { fit(full, maxw) } end

	-- 标签自己就已经超宽：标签一行、绑定名一行
	if disp_width(head) >= maxw then
		local l1 = fit(head, maxw)
		local l2 = fit(text, maxw)
		-- 格子窄到连「1:」都放不下时 fit 会返回空串，整格变成一片空白——
		-- 那看起来像插件坏了（不是「截断」而是「什么都没有」）。
		-- 退一步只画按键编号本身（如「1」），至少还能认出这是哪个键。
		-- 每行 16 格这种极端档位下就是这个情况。
		if l1 == '' and maxw >= 1 then
			local bare = tostring(label)
			l1 = fit(bare, maxw)
			if l1 == '' then
				local cw, adv = next_char(bare, 1)
				if cw and cw <= maxw then l1 = bare:sub(1, adv) end
			end
		end
		return { l1, l2 }
	end

	local words = {}
	for w in text:gmatch('%S+') do words[#words + 1] = w end
	if #words == 0 then return { fit(full, maxw) } end

	local line1 = head
	local i = 1
	while i <= #words do
		local cand = line1 .. ((i > 1) and ' ' or '') .. words[i]
		if disp_width(cand) > maxw then break end
		line1 = cand
		i = i + 1
	end
	if i > #words then return { line1 } end

	local rest = {}
	for k = i, #words do rest[#rest + 1] = words[k] end
	return { line1, fit(table.concat(rest, ' '), maxw) }
end

-- 按键区占用的行数（含换行）。绘制时必须用同一套判定，否则高度会算错。
local function btn_rows_for(btns, pr, maxw)
	local n, i = 0, 1
	while i <= #btns do
		local need = 1
		for c = 0, pr - 1 do
			local it = btns[i + c]
			if it then
				local lines = split_cell(sem_label(it.sem, it.kind), it.text or '--', maxw)
				if #lines > 1 then need = 2; break end
			end
		end
		n = n + need
		i = i + pr
	end
	return n
end

-- 一个按键格能否在该宽度内「不截断」地整行显示。
-- 判定与 split_cell 的前两步一致（原样 / 去掉绑定名里的空格），
-- 但只认「放得下」——被 fit() 加上 '..' 的算放不下。
local function cell_fits_one_line(label, text, maxw)
	local head = tostring(label) .. ':'
	text = tostring(text or '--')
	if disp_width(head .. text) <= maxw then return true end
	if disp_width(head .. (text:gsub('%s+', ''))) <= maxw then return true end
	return false
end

-- 每行格数判定（高度统计与绘制必须都走这里，否则行数会算错）。
--   'auto' → 按当列可用宽度自适应：从 2 格往大试，只要这一档里
--            「每个按键都能单行完整显示」就继续加，一旦放不下就停在上一档。
--            格数越多格子越窄，单调性成立，所以一旦失败可以 break。
--            上限 min(PER_ROW_MAX, 按钮数)；最小 1 格兜底。
--   1..16  → 强制该格数，不管放不放得下。
-- col_w_px: 单列可用宽度（像素）；char_px: 半个字符的估算像素宽。
local function per_row_for(btns, col_w_px, px_per_char)
	local n = #btns
	if n <= 0 then return 1 end
	if settings.per_row ~= 'auto' then
		return clamp_int(settings.per_row, 1, PER_ROW_MAX, 1)
	end
	local best = 1
	local hi = math.min(PER_ROW_MAX, n)
	for pr = 2, hi do
		local maxw = (col_w_px / pr) / px_per_char
		local ok = true
		for _, it in ipairs(btns) do
			if not cell_fits_one_line(sem_label(it.sem, it.kind), it.text or '--', maxw) then
				ok = false
				break
			end
		end
		if not ok then break end
		best = pr
	end
	return best
end

local function draw_frame()
	if not settings.show then return end
	local machine = manager and manager.machine
	if not machine then return end
	local render = machine.render
	if not render then return end
	local container = safe(function() return render.ui_container end, nil)
	if not container then return end

	local target = safe(function() return render.ui_target end, nil)
	local out_w = safe(function() return target.width end, 0) or 0
	local out_h = safe(function() return target.height end, 0) or 0
	if out_w <= 0 then out_w = 1920 end
	if out_h <= 0 then out_h = 1080 end

	-- 决定显示哪几列
	local cols = {}
	for pl = 0, 3 do
		if settings.layout == 'auto' then
			if present[pl] then cols[#cols + 1] = pl end
		else
			cols[#cols + 1] = pl
		end
	end
	if #cols == 0 then return end

	local line_px = clamp_int(settings.line_px, 10, 64, 24)
	local bottom_px = clamp_int(settings.bottom_px, 0, 200, 10)
	local gap_px = clamp_int(settings.col_px, 0, 64, 6)
	local char_px = clamp_int(settings.char_px, 4, 32, 15)

	-- 逐列计算行数，取最大值决定整体高度
	-- 方向行固定一行 4 格（用户确认这个版式没问题）。
	-- 4 列显示时格宽可能不足（1351px 窗口下每格约 82px，「下:Down」需 91px），
	-- 这种情况不改变版式，而是靠省略中文前缀 + 缩写绑定名来解决。
	local col_px_w = (1 / #cols) * out_w - gap_px
	local dir_cell_px = col_px_w / 4
	local maxw_dir = dir_cell_px / char_px

	-- 方向格的显示行数：同时有键盘与手柄两路绑定、且一行放不下时用两行
	-- （上行键盘、下行手柄），避免被截断成「Up ..」把信息丢掉。
	-- 与下方绘制处必须用同一套判定，否则高度会算错。
	local function dir_lines_of(it)
		if not (it and it.text) then return 1 end
		if it.kb_text and it.joy_text then
			local both = it.kb_text .. ' ' .. it.joy_text
			if disp_width(both) > maxw_dir then return 2 end
		end
		return 1
	end

	-- 方向行的高度必须四列统一：只要有一列需要「键盘/手柄」上下两行，
	-- 四列都按两行排版，否则各列的选择/开始行会错位（第 3 列以后的文字整体上移）。
	local global_dir_need = 1
	for _, pl in ipairs(cols) do
		for _, it in ipairs(items[pl] or {}) do
			if it.kind == 'DIR' then
				local n = dir_lines_of(it)
				if n > global_dir_need then global_dir_need = n end
			end
		end
	end

	local col_rows = {}
	local max_rows = 0
	for _, pl in ipairs(cols) do
		local list = items[pl] or {}
		local btn = 0
		for _, it in ipairs(list) do
			if it.kind == 'BUTTON' then btn = btn + 1 end
		end
		local special = 0
		for _, it in ipairs(list) do
			if it.kind == 'START' or it.kind == 'SELECT' then special = special + 1 end
		end
		local rows = 1                                  -- 标题
		rows = rows + global_dir_need                   -- 方向行（固定 4 格，可能两行）
		-- 选择/开始行：只要有 START 或 SELECT 之一就画（两个格子固定都画）
		if settings.show_start and special > 0 then
			-- 这一行也可能换行，按实际宽度算（与绘制处同一套 split_cell）
			local cell_w2_px = ((1 / #cols) * out_w - gap_px) / 2
			local maxw2 = cell_w2_px / char_px
			local need = 1
			for _, it in ipairs(list) do
				if it.kind == 'START' or it.kind == 'SELECT' then
					local lines = split_cell(sem_label(it.sem, it.kind), it.text or '--', maxw2)
					if #lines > 1 then need = 2; break end
				end
			end
			rows = rows + need
		end
		if btn > 0 then
			local btns = {}
			for _, it in ipairs(list) do
				if it.kind == 'BUTTON' then btns[#btns + 1] = it end
			end
			-- 先算列宽再求每行格数：'auto' 需要宽度才能判断能排在几个
			local col_w_px = (1 / #cols) * out_w - gap_px
			local pr = per_row_for(btns, col_w_px, char_px)
			local maxw_b = (col_w_px / pr) / char_px
			rows = rows + btn_rows_for(btns, pr, maxw_b)
		end
		col_rows[pl] = rows
		if rows > max_rows then max_rows = rows end
	end
	if max_rows <= 0 then return end

	-- 纵向放不下时压缩行距
	local avail = out_h - bottom_px - 8
	if max_rows * line_px > avail then
		line_px = math.max(10, math.floor(avail / max_rows))
	end
	local total_px = max_rows * line_px
	local top = 1 - (total_px + bottom_px) / out_h
	if top < 0 then top = 0 end
	local line_h = line_px / out_h

	local n_cols = #cols
	local col_w = 1 / n_cols
	local gap = gap_px / out_w
	local bg = clamp_int(settings.bg_alpha, 0, 255, 200) * 0x1000000

	-- 整条背景
	local ok_bg, err_bg = pcall(function()
		container:draw_box(0, top, 1, top + (total_px + 4) / out_h, 0, bg)
	end)
	if not ok_bg then draw_errors = draw_errors + 1; last_err = 'box: ' .. tostring(err_bg) end

	if not draw_ok_once then
		draw_ok_once = true
		emu.print_info(string.format('[mame_kbd] 首帧绘制 rom=%s out=%dx%d top=%.4f 列数=%d 行数=%d',
			tostring(current_rom()), out_w, out_h, top, n_cols, max_rows))
	end
	draw_frames = draw_frames + 1

	for ci, pl in ipairs(cols) do
		local x0 = (ci - 1) * col_w + gap * 0.5
		local x1 = ci * col_w - gap * 0.5
		local rows_this = col_rows[pl] or 1
		local h_col = rows_this * line_h

		local ok_b, err_b = pcall(function()
			container:draw_box(x0, top, x1, top + h_col, C_EDGE, 0x00000000)
		end)
		if not ok_b then draw_errors = draw_errors + 1; last_err = 'edge: ' .. tostring(err_b) end

		local pad = 0.004
		local y_cursor = 0

		local function row_y()
			-- 实测证据：draw_text 的 y 是「文字顶部」而不是基线。
			-- （_shot4.png 里 top=0.8881/out_h=1001/4 行，末行 y≈981px 时文字下缘
			--   被 1001px 的窗口底边切掉 —— 若 y 是基线，字顶应在 965 左右、不该被切。）
			-- 因此按行顶 + 很小的偏移定位，底部另留一整行给字高。
			local y = top + (y_cursor + 0.06) * line_h
			y_cursor = y_cursor + 1
			return y
		end

		-- 标题
		dt(container, x0 + pad, row_y(), 'P' .. (pl + 1),
			present[pl] and C_TITLE or C_NONE)

		local list = items[pl] or {}

		-- 方向行：固定一行 4 格（用户确认这个版式没问题）
		local dir_items = {}
		for _, it in ipairs(list) do
			if it.kind == 'DIR' then dir_items[#dir_items + 1] = it end
		end
		local cell_w4 = (x1 - x0) / 4
		local maxw4 = (cell_w4 * out_w) / char_px
		-- 窄格时只显示绑定名、省掉「上:」前缀：
		-- 「下:Down」需要 7 个半角宽，而 1351px 窗口 4 列时每格只有约 6.5 个半角宽，
		-- 必然被截成「下:D..」。4 个格子的顺序是固定的（上/下/左/右）且颜色有别，
		-- 所以省掉中文前缀后信息不丢，反而能把真正的按键名完整显示出来。
		local dir_compact = maxw4 < 7
		-- 4 个格共用同一段行区，必须只推进一次 y_cursor；
		-- 高度用全局 global_dir_need（四列统一），与行数统计处完全一致，否则列间会错位。
		local y_dir_base = y_cursor
		y_cursor = y_cursor + global_dir_need
		for c = 1, 4 do
			local sem = DIR_ORDER[c]
			local found = nil
			for _, it in ipairs(dir_items) do
				if it.sem == sem then found = it; break end
			end
			local cell_x = x0 + (c - 1) * cell_w4 + pad * 0.5
			local st = found and press_state(found) or PRESS_NONE
			local lines
			if found and found.text then
				if global_dir_need == 2 then
					-- 四列统一两行时，语义固定为「上行键盘、下行手柄」；
					-- 只有一路绑定的项，另一行留空（跳过不画），
					-- 否则 P2 的 J2U 会被放到第一行、看起来像下一格键盘名的前缀。
					local l1 = found.kb_text and fit(found.kb_text, maxw4) or ''
					local l2 = found.joy_text and fit(found.joy_text, maxw4) or ''
					if l1 == '' and l2 == '' then
						lines = { fit(found.text, maxw4) }
					else
						lines = { l1, l2 }
					end
				elseif dir_compact then
					lines = { fit(found.text, maxw4) }
				else
					lines = { fit(sem_label(sem, 'DIR') .. ':' .. found.text, maxw4) }
				end
			else
				lines = { fit(sem_label(sem, 'DIR') .. ':-', maxw4) }
			end
			local fg = C_NONE
			if found then fg = C_DIR end
			local bgc
			fg, bgc = press_color(st, fg)
			for li = 1, #lines do
				if lines[li] and lines[li] ~= '' then
					dt(container, cell_x, top + (y_dir_base + li - 1 + 0.06) * line_h,
						lines[li], fg, bgc)
				end
			end
		end

		-- 选择 / 开始行：固定两格「选择」「开始」。
		-- 为什么固定两格而不是只画存在的：用户要求第 2 行就是「选择 和 开始」，
		-- 且 119 这类只有 START、没有 SELECT token 的 ROM 也要保持版式一致。
		if settings.show_start then
			local sel_it, sta_it = nil, nil
			for _, it in ipairs(list) do
				if it.kind == 'SELECT' then sel_it = it
				elseif it.kind == 'START' then sta_it = it end
			end
			if sel_it or sta_it then
				local cell_w2 = (x1 - x0) / 2
				local maxw = (cell_w2 * out_w) / char_px
				-- 两个格共用起始行；某格需要两行时，另一个格只占第一行，
				-- 整行按「本行最高格」推进，绘制与行数计算必须一致。
				local y_base = y_cursor
				local need = 1
				local pair = { { it = sel_it, sem = 'SELECT' }, { it = sta_it, sem = 'START' } }
				for c = 1, 2 do
					local entry = pair[c]
					local it = entry.it
					local cell_x = x0 + (c - 1) * cell_w2 + pad * 0.5
					local label = sem_label(entry.sem, entry.sem)
					local fg
					local st = (it and it.text) and press_state(it) or PRESS_NONE
					local lines = split_cell(label, it and it.text or '--', maxw)
					if #lines > need then need = #lines end
					local fg
					if it and it.text then
						fg = C_SPECIAL
					else
						fg = C_NONE
					end
					local bgc
					fg, bgc = press_color(st, fg)
					for li = 1, #lines do
						local y = top + (y_base + li - 1 + 0.06) * line_h
						dt(container, cell_x, y, lines[li], fg, bgc)
					end
				end
				y_cursor = y_base + need
			end
		end

		-- 按键行（支持单项换行成两行）
		local btns = {}
		for _, it in ipairs(list) do
			if it.kind == 'BUTTON' then btns[#btns + 1] = it end
		end
		if #btns > 0 then
			-- 与高度统计（draw_frame 里的 col_rows 循环）用【完全相同的表达式】
			-- 求列宽，而不是 (x1-x0)*out_w —— 两者数学等价但浮点结果可能差最后几位，
			-- 边界上会让 auto 在两处算出不同格数，导致行数算错、列间错位。
			local col_w_px = (1 / n_cols) * out_w - gap_px
			local pr = per_row_for(btns, col_w_px, char_px)
			local cell_w = (x1 - x0) / pr
			local maxw = (cell_w * out_w) / char_px
			local i = 1
			while i <= #btns do
				local y_base = y_cursor
				local need = 1
				-- 先算本行所有格子的行数，取最大值作为本行占用的行数
				local cells = {}
				for c = 0, pr - 1 do
					local it = btns[i + c]
					if it then
						local lines = split_cell(sem_label(it.sem, it.kind), it.text or '--', maxw)
						cells[#cells + 1] = { c = c, it = it, lines = lines }
						if #lines > need then need = #lines end
					end
				end
				for _, cell in ipairs(cells) do
					local cell_x = x0 + cell.c * cell_w + pad * 0.5
					local st = press_state(cell.it)
					local fg = cell.it.text and C_BTN or C_NONE
					local bgc
					fg, bgc = press_color(st, fg)
					for li = 1, #cell.lines do
						local y = top + (y_base + li - 1 + 0.06) * line_h
						dt(container, cell_x, y, cell.lines[li], fg, bgc)
					end
				end
				y_cursor = y_base + need
				i = i + pr
			end
		end
	end

	-- 按下状态变化时打日志（用于验证 field_pressed 读取链路；仅状态变化才打印，避免刷屏）
	do
		local lit_n, lit_which = 0, {}
		for pl = 0, 3 do
			for _, it in ipairs(items[pl] or {}) do
				if field_pressed(it) then
					lit_n = lit_n + 1
					lit_which[#lit_which + 1] = string.format('P%d.%s', pl + 1, tostring(it.sem))
				end
			end
		end
		local sig = tostring(lit_n) .. '|' .. table.concat(lit_which, ',')
		if sig ~= lit_sig then
			lit_sig = sig
			emu.print_info(string.format('[mame_kbd] 帧%d 按下项=%d%s',
				draw_frames, lit_n,
				(#lit_which > 0) and (' [' .. table.concat(lit_which, ',') .. ']') or ''))
		end
	end

	if draw_frames == 120 or (draw_frames > 0 and draw_frames % 300 == 0) then
		emu.print_info(string.format('[mame_kbd] 帧%d 统计：draw_text=%d 失败=%d 最近错误=%s',
			draw_frames, draw_calls, draw_errors, tostring(last_err or '无')))
		-- 诊断：把 P1 每个 item 的 mask/defvalue/port:read() 都打出来。
		-- 目的：证明「按下判定」的读取链路是通的（不是 nil / 不是恒等），
		-- 因为本机无法可靠地向 MAME 注入键盘（截图验证过 keybd_event 不生效）。
		for _, it in ipairs(items[0] or {}) do
			local rv = safe(function() return it.port:read() end, nil)
			local tp = 'ERR'
			do
				local ioport = safe(function() return manager.machine.ioport end, nil)
				if ioport and it.ty then
					local ok, v = pcall(function() return ioport:type_pressed(it.ty, it.player) end)
					tp = ok and tostring(v) or 'ERR:' .. tostring(v)
				end
			end
			emu.print_info(string.format('[mame_kbd][press] %s mask=%s def=%s read=%s cur=%s type_pressed=%s phys=%s pressed=%s',
				tostring(it.sem), tostring(it.mask), tostring(it.defvalue), tostring(rv),
				tostring(rv and band(rv, it.mask)),
				tp,
				tostring(field_physical_pressed(it)),
				tostring(field_pressed(it))))
		end
	end
end

-- ============================================================
-- 菜单
-- ============================================================
local last_actions = {}

local function layout_text()
	return (settings.layout == 'four') and '固定四列' or '仅实际玩家'
end

local function label_text()
	return (settings.label == 'ascii') and 'U/D/L/R' or '中文'
end

local function per_row_text()
	if settings.per_row == 'auto' then return '自动' end
	return string.format('每行 %d 个', tonumber(settings.per_row) or 1)
end

local function seq_mode_text()
	if settings.seq_mode == 'full' then return '全部绑定' end
	if settings.seq_mode == 'priority' then return '优先次序' end
	return '首个绑定'
end

local function onoff(v)
	return v and '开' or '关'
end

-- 显示格式档位的可读名。菜单里显示「LShft / 左Shft …」，用户左右切换。
local MOD_STYLES = {
	{ id = 'short',  text = 'LShft',      sample = 'LShft / RShft' },
	{ id = 'zh',     text = '左Shft',     sample = '左Shft / 右Shft' },
	{ id = 'hyphen', text = 'L-Shift',    sample = 'L-Shift / R-Shift' },
	{ id = 'full',   text = '全称',       sample = 'Left Shift / Right Shift' },
}
local JOY_STYLES = {
	{ id = 'under', text = 'J1_B1',   sample = 'J1_B1 / J1_U' },
	{ id = 'plain', text = 'J1B1',    sample = 'J1B1 / J1U' },
	{ id = 'num',   text = 'J1_1',    sample = 'J1_1 / J1_U' },
	{ id = 'zh',    text = '手柄1_1', sample = '手柄1_1 / 手柄1_U' },
	{ id = 'joy',   text = 'Joy1_1',  sample = 'Joy1_1 / Joy1_U' },
	{ id = 'abxy',  text = 'J1A',     sample = 'J1A / J1B / J1X / J1Y / J1L1 / J1R1' },
	{ id = 'abxyu', text = 'J1_A',    sample = 'J1_A / J1_B / J1_X / J1_Y / J1_L1 / J1_R1' },
}
local MOUSE_STYLES = {
	{ id = 'under', text = 'M1_B1',   sample = 'M1_B1' },
	{ id = 'plain', text = 'M1B1',    sample = 'M1B1' },
	{ id = 'num',   text = 'M1_1',    sample = 'M1_1' },
	{ id = 'zh',    text = '鼠标1_1', sample = '鼠标1_1' },
	{ id = 'mou',   text = 'Mou1_1',  sample = 'Mou1_1' },
}
-- 手柄方向格式（用户 m01440 要求，只作用于手柄的四个方向）
local DIR_STYLES = {
	{ id = 'letter', text = 'U/D/L/R',      sample = 'J1_U / J1_D / J1_L / J1_R' },
	{ id = 'word',   text = 'Up/Dn/Lt/Rt',  sample = 'J1_Up / J1_Dn / J1_Lt / J1_Rt' },
	{ id = 'arrow',  text = '↑/↓/←/→',      sample = 'J1_↑ / J1_↓ / J1_← / J1_→' },
	{ id = 'arrown', text = '↑↓←→',         sample = 'J1↑ / J1↓ / J1← / J1→' },
	{ id = 'tri',    text = '▲/▼/◀/▶',      sample = 'J1_▲ / J1_▼ / J1_◀ / J1_▶' },
	{ id = 'trin',   text = '▲▼◀▶',         sample = 'J1▲ / J1▼ / J1◀ / J1▶' },
}

-- 在档位表里找当前值的下标（1 基）；找不到返回 1（回落到第一档，不报错）
local function style_index(tbl, cur)
	for i, e in ipairs(tbl) do
		if e.id == cur then return i end
	end
	return 1
end

-- 左右切换一档：dir 为 -1/0/1，0 当 +1（select 键也当「下一档」）
local function style_step(tbl, cur, dir)
	if dir == 0 then dir = 1 end
	local i = style_index(tbl, cur) + dir
	if i < 1 then i = #tbl elseif i > #tbl then i = 1 end
	return tbl[i].id
end

-- 多页菜单。
-- MAME 插件的 emu.register_menu(callback, populate, title) 只接受一个扁平数组，
-- 菜单项 flags 里没有任何「子项 / 展开」标志（已核对本机 14 个官方插件，
-- 实际出现过的只有 off / heading / lr / r / l / lrrepeat / '' 共 7 种）。
-- 官方自己是怎么做分层的：plugins/autofire/autofire_menu.lua 用「菜单栈 +
-- populate 按栈顶分发」——这里采用同样的做法，只是栈退化成单层子页（够用）。
local PAGE_MAIN = 0
local PAGE_SHOW = 1
local PAGE_FORMAT = 2
local PAGE_LOOK = 3
local PAGE_COLOR = 4
local PAGE_DIAG = 5

local ALL_PAGES = { PAGE_MAIN, PAGE_SHOW, PAGE_FORMAT, PAGE_LOOK, PAGE_COLOR, PAGE_DIAG }

local menu_page = PAGE_MAIN
local last_msg = nil        -- 主页「上次操作」的反馈（保存/重置的结果）

-- 按页自检，本页第一次构建时跑一次。
-- 注意：不能用 #actions == #list 判断 —— head()/disp() 不传动作，
-- actions 里天然留 nil 稀疏空洞，Lua 的 # 对稀疏表结果不可靠。
local MENU_SELFCHECK = {}

local function selfcheck_page(page, list, actions)
	if MENU_SELFCHECK[page] then return end
	MENU_SELFCHECK[page] = true
	local bad = {}
	for i = 1, #list do
		if list[i][3] == 'lr' and actions[i] == nil then
			bad[#bad + 1] = string.format('%d:%s', i, tostring(list[i][1]))
		end
	end
	if #bad > 0 then
		emu.print_error(string.format('[mame_kbd][menu] 页%d 菜单下标错位！缺动作的行: %s',
			page, table.concat(bad, ', ')))
	else
		emu.print_info(string.format('[mame_kbd][menu] 页%d 自检通过 items=%d 可调项下标对齐',
			page, #list))
	end
end

local function menu_items()
	local list = {}
	local actions = {}

	local function push(label_txt, value, flags, act)
		list[#list + 1] = { label_txt, value or '', flags or 'off' }
		-- ★ 必须用 #list（插入后的新长度），不能用 #list + 1。
		-- 上一行刚把 list 插满，此时 #list 已经是本项的 1 基下标；
		-- 写成 #list + 1 会让动作整体后移一格，导致「选第 2 行、第 1 行的值在变」。
		actions[#list] = act
	end
	local function head(l, v) push(l, v, 'heading') end
	local function disp(l, v) push(l, v, 'off') end
	local function toggle(l, on, a) push(l, onoff(on), 'lr', a) end
	local function adj(l, v, a) push(l, v, 'lr', a) end
	-- 入口项用 'lr' 而不是 ''：这样 select / left / right 三个键都能进子页，
	-- 用户按哪个都不会「没反应」，箭头也顺带提示「这行通往下一页」。
	local function entry(l, v, a) push(l, v, 'lr', a) end
	local function back_row()
		-- 双保险之一：底部放一行可点的「返回」。
		-- 另一条路是 menu_callback 里处理 event=='back'（官方 commonui 也这么做）。
		-- 两条都实现，是因为 back 事件对插件菜单是否派发我没有实测证据。
		push('← 返回上级', '', '', { kind = 'back' })
	end

	if menu_page == PAGE_MAIN then
		head('KBD 按键对照表', '画面下方四列显示 P1~P4 绑定')
		entry('▶ 显示设置', '开关与布局', { kind = 'page', page = PAGE_SHOW })
		entry('▶ 显示格式', '键名怎么写', { kind = 'page', page = PAGE_FORMAT })
		entry('▶ 外观微调', '行距边距等', { kind = 'page', page = PAGE_LOOK })
		entry('▶ 按键颜色', '按下时的三色', { kind = 'page', page = PAGE_COLOR })
		entry('▶ 诊断信息', 'ROM 与绘制状态', { kind = 'page', page = PAGE_DIAG })
		-- ↓ 插件级操作：与「在哪个子页」无关，所以放在主页。
		--   右侧写真实文件名，用户能直接看到会写/删哪个文件（照 copilot2p 的做法）。
		push('---', '', '')
		-- 右侧只写文件名，不写 mame_kbd/ 目录前缀。
		-- 菜单右侧的宽度很窄（约 8 个汉字），加上目录名会被折成两行、
		-- 连文件名本身都断在中间（"settings_defau" / "lt.ini"），反而看不清。
		-- 目录位置在「附：配置文件位置」处统一说明，不必每行重复。
		push('保存为默认（其他 ROM 通用）', '写入 settings_default.ini', '', { kind = 'save_default' })
		local rin = rom_ini_name()
		push('重置本 ROM（回落到默认）', rin and ('删除 ' .. rin) or '当前无 ROM', '', { kind = 'reset_rom' })
		-- ★ 这一行必须恒定存在（没有消息时显示占位符），不能「有消息才加」。
		-- 原因：MAME 菜单的光标按行下标定位，行数在运行中浮动会让光标跳到别的行。
		disp('  ↳ 上次操作', last_msg or '—')

	elseif menu_page == PAGE_SHOW then
		head('显示设置', '决定显示什么、怎么排')
		toggle('显示对照表', settings.show, { kind = 'show' })
		adj('列布局', layout_text(), { kind = 'layout' })
		adj('标签语言', label_text(), { kind = 'label' })
		adj('每行按键数', per_row_text(), { kind = 'per_row' })
		adj('绑定显示', seq_mode_text(), { kind = 'seq_mode' })
		toggle('长键名自动换行', settings.wrap, { kind = 'wrap' })
		toggle('显示「选择/开始」', settings.show_start, { kind = 'show_start' })
		toggle('按下高亮', settings.highlight, { kind = 'highlight' })
		push('---', '', '')
		back_row()

	elseif menu_page == PAGE_FORMAT then
		head('显示格式', '只改文字写法，不影响绑定的实际功能')
		local mi = style_index(MOD_STYLES, settings.mod_style)
		adj('修饰键格式', MOD_STYLES[mi].text, { kind = 'mod_style' })
		disp('  实际效果', MOD_STYLES[mi].sample)
		local ji = style_index(JOY_STYLES, settings.joy_style)
		adj('手柄格式', JOY_STYLES[ji].text, { kind = 'joy_style' })
		disp('  实际效果', JOY_STYLES[ji].sample)
		local oi = style_index(MOUSE_STYLES, settings.mouse_style)
		adj('鼠标/光枪格式', MOUSE_STYLES[oi].text, { kind = 'mouse_style' })
		disp('  实际效果', MOUSE_STYLES[oi].sample)
		local di = style_index(DIR_STYLES, settings.dir_style)
		adj('手柄方向格式', DIR_STYLES[di].text, { kind = 'dir_style' })
		disp('  实际效果', DIR_STYLES[di].sample)
		-- 保存/重置已提升到主页（插件级操作，与当前在哪个子页无关）。
		-- 主页就在上一层，按「← 返回上级」即可到达。
		push('---', '', '')
		back_row()

	elseif menu_page == PAGE_LOOK then
		head('外观微调', '单位都是像素，左右键调整')
		adj('行距', string.format('%d 像素', settings.line_px), { kind = 'line_px' })
		adj('底部边距', string.format('%d 像素', settings.bottom_px), { kind = 'bottom_px' })
		adj('列间隙', string.format('%d 像素', settings.col_px), { kind = 'col_px' })
		adj('背景不透明度', string.format('%d / 255', settings.bg_alpha), { kind = 'bg_alpha' })
		adj('字符宽度估计', string.format('%d 像素', settings.char_px), { kind = 'char_px' })
		push('---', '', '')
		back_row()

	elseif menu_page == PAGE_COLOR then
		head('按键颜色', '按下时用哪种颜色，左右键切换')
		-- ★ 这里只写色名与色值，不画色块。
		-- 原因：MAME 菜单的每一行都由菜单自己按主题配色绘制，菜单项只是一个
		-- {label, value, flags} 文本三元组，无法单独给某一行上色——
		-- 在 label 里塞「■ ■ ■」只会显示成菜单的前景色（白），
		-- 看起来像能预览、其实什么也没显示，反而误导。
		-- 想看真实观感：直接看画面下方对照表，按住对应按键即可。
		adj('物理按下', hl_label(settings.hl_phys), { kind = 'hl_phys' })
		adj('镜像按下', hl_label(settings.hl_mirror), { kind = 'hl_mirror' })
		adj('同时按下', hl_label(settings.hl_both), { kind = 'hl_both' })
		push('---', '', '')
		disp('  提示', '三色可设成一样，也可任意搭配')
		disp('  查看效果', '进游戏按住键，看下方对照表')
		push('---', '', '')
		back_row()

	else
		head('诊断信息', '排查显示异常时看这里')
		disp('当前 ROM', current_rom() or '(无)')
		local pc = 0
		for pl = 0, 3 do
			if present[pl] then pc = pc + 1 end
		end
		disp('检测到玩家数', string.format('%d / 4', pc))
		for pl = 0, 3 do
			local l = items[pl]
			if l then
				local btn = 0
				for _, it in ipairs(l) do
					if it.kind == 'BUTTON' then btn = btn + 1 end
				end
				disp(string.format('P%d', pl + 1), string.format('%d 项，按键 %d 个', #l, btn))
			else
				disp(string.format('P%d', pl + 1), '无输入')
			end
		end
		disp('绘制调用 / 失败', string.format('%d / %d', draw_calls, draw_errors))
		-- 配置文件位置统一在这里说明，主页那两行就不再重复写目录名
		-- （菜单右侧太窄，带目录会把文件名折成两行）。
		disp('配置目录', config_dir() or '(无 homepath)')
		push('---', '', '')
		back_row()
	end

	selfcheck_page(menu_page, list, actions)
	last_actions = actions
	-- 第三个返回值是【菜单级】flags（不是菜单项的 flags）。
	-- lrrepeat：按住左右键连续走档。颜色页现在有 30 档，一次一档点太费手；
	-- 官方 autofire / inputmacro / offscreenreload 都用这个标志。
	-- 第二个返回值是初始光标位置，传 nil 表示沿用 MAME 自己的记忆行为。
	return list, nil, 'lrrepeat'
end

local function menu_callback(index, event)
	-- 返回事件优先处理：它在任何页都可能到达，且不依赖 index 指向哪一行。
	-- （另一条退路是每页底部的「← 返回上级」行，两条都留着，
	--  因为 back 事件对插件菜单是否派发我只在官方源码见到、未在本机实测。）
	if event == 'back' then
		if menu_page ~= PAGE_MAIN then
			menu_page = PAGE_MAIN
			return true
		end
		return false
	end

	local a = last_actions[index]
	if not a then return false end
	local sel = (event == 'select')
	local lft = (event == 'left')
	local rgt = (event == 'right')
	if not (sel or lft or rgt) then return false end

	local k = a.kind
	local dir = 0
	if lft then dir = -1 elseif rgt then dir = 1 end

	-- 翻页类动作先处理：它们不需要 save_settings，也不需要 rebuild。
	if k == 'page' then
		if sel or lft or rgt then
			menu_page = a.page or PAGE_MAIN
			return true
		end
		return false
	elseif k == 'back' then
		if sel then
			menu_page = PAGE_MAIN
			return true
		end
		return false
	elseif k == 'save_default' then
		if sel then
			if save_default_settings() then
				last_msg = '已写入默认配置'
				emu.print_info('[mame_kbd] 已保存全局默认配置 settings_default.ini')
			else
				last_msg = '写入失败（目录不可写）'
				emu.print_error('[mame_kbd] 保存全局默认配置失败：插件目录与 homepath 均不可写')
			end
			return true
		end
		return false
	elseif k == 'reset_rom' then
		if sel then
			local r = reset_rom_settings()
			if r == 'removed' then
				last_msg = '已删除本 ROM 配置'
				emu.print_info('[mame_kbd] 已删除本 ROM 的 settings ini，将回落到默认配置')
				-- 删掉的正是当前生效的配置，立刻按默认重新加载，界面马上跟着变
				load_settings()
				rebuild_bindings()
			elseif r == 'missing' then
				last_msg = '本 ROM 没有专属配置'
			elseif r == 'no_rom' then
				last_msg = '当前没有 ROM'
			else
				last_msg = '删除失败'
				emu.print_error('[mame_kbd] 删除本 ROM 配置失败')
			end
			return true
		end
		return false
	end

	if k == 'show' then
		settings.show = not settings.show
	elseif k == 'layout' then
		settings.layout = (settings.layout == 'four') and 'auto' or 'four'
	elseif k == 'label' then
		settings.label = (settings.label == 'ascii') and 'zh' or 'ascii'
	elseif k == 'per_row' then
		-- 档位循环：自动 → 1 → 2 → … → PER_ROW_MAX → 自动（左右都循环）
		if dir == 0 then dir = 1 end
		local cycle = { 'auto' }
		for i = 1, PER_ROW_MAX do cycle[#cycle + 1] = i end
		local cur = tonumber(settings.per_row) or 'auto'
		local idx = 1
		for i = 1, #cycle do
			if cycle[i] == cur then idx = i; break end
		end
		idx = idx + dir
		if idx < 1 then idx = #cycle elseif idx > #cycle then idx = 1 end
		settings.per_row = cycle[idx]
	elseif k == 'show_start' then
		settings.show_start = not settings.show_start
	elseif k == 'seq_mode' then
		-- 三档循环：首个绑定 → 优先次序 → 全部绑定 → 首个绑定
		if settings.seq_mode == 'first' then
			settings.seq_mode = 'priority'
		elseif settings.seq_mode == 'priority' then
			settings.seq_mode = 'full'
		else
			settings.seq_mode = 'first'
		end
		rebuild_bindings()
	elseif k == 'mod_style' or k == 'joy_style' or k == 'mouse_style' or k == 'dir_style' then
		-- 显示格式只改文字写法，但绑定文本是在采集/rebuild 时就算好的，
		-- 所以必须 rebuild_bindings() 才会立即生效（否则要等下次换 ROM）。
		if k == 'mod_style' then
			settings.mod_style = style_step(MOD_STYLES, settings.mod_style, dir)
		elseif k == 'joy_style' then
			settings.joy_style = style_step(JOY_STYLES, settings.joy_style, dir)
		elseif k == 'dir_style' then
			settings.dir_style = style_step(DIR_STYLES, settings.dir_style, dir)
		else
			settings.mouse_style = style_step(MOUSE_STYLES, settings.mouse_style, dir)
		end
		rebuild_bindings()
	elseif k == 'wrap' then
		settings.wrap = not settings.wrap
	elseif k == 'highlight' then
		settings.highlight = not settings.highlight
	elseif k == 'line_px' then
		if dir == 0 then dir = 1 end
		settings.line_px = clamp_int(settings.line_px + dir * 2, 10, 64, 24)
	elseif k == 'bottom_px' then
		if dir == 0 then dir = 1 end
		settings.bottom_px = clamp_int(settings.bottom_px + dir * 4, 0, 200, 10)
	elseif k == 'col_px' then
		if dir == 0 then dir = 1 end
		settings.col_px = clamp_int(settings.col_px + dir * 2, 0, 64, 6)
	elseif k == 'bg_alpha' then
		if dir == 0 then dir = 1 end
		settings.bg_alpha = clamp_int(settings.bg_alpha + dir * 25, 0, 255, 200)
	elseif k == 'char_px' then
		if dir == 0 then dir = 1 end
		settings.char_px = clamp_int(settings.char_px + dir, 4, 32, 15)
	elseif k == 'hl_phys' or k == 'hl_mirror' or k == 'hl_both' then
		-- 颜色只影响绘制，不需要 rebuild_bindings（那会重建整个绑定表，很贵）。
		settings[k] = style_step(HL_COLORS, settings[k], dir)
	else
		return false
	end

	save_settings()
	return true
end

-- ============================================================
-- 生命周期
-- ============================================================
local function on_stop()
	items = {}
	present = {}
end

function mame_kbd.set_folder(dir)
	plugin_folder = dir
end

function mame_kbd.startplugin()
	-- 第一步：把旧版本写在插件目录里的 settings_*.ini 搬到配置目录。
	-- 必须在 load_settings() 之前做 —— 否则这一轮读到的还是旧位置的文件，
	-- 看起来像「配置没搬」；搬完再读，两种来源天然一致。
	local moved = safe(function() return migrate_legacy_configs() end, 0)
	if moved and moved > 0 then
		emu.print_info(string.format('[mame_kbd] 已把 %d 个旧配置从插件目录搬到 mame_kbd/', moved))
	end

	-- 注意：此刻机器还没起来，current_rom() 返回 nil，所以这里读到的只是
	-- settings_default.ini。真正的「按 ROM 保存的配置」必须等机器就绪后再读一次，
	-- 见 process_frame 里的 loaded_rom 变更检测。
	load_settings()

	local frame_count = 0
	local dirty = true
	local loaded_rom = nil

	local function process_frame()
		frame_count = frame_count + 1

		-- 机器就绪 / 换 ROM 后重新加载该 ROM 的专属配置
		local rom = current_rom()
		if rom ~= loaded_rom then
			loaded_rom = rom
			dirty = true
			if rom then
				load_settings()
				emu.print_info(string.format('[mame_kbd] 载入 ROM 配置 rom=%s 显示=%s 绑定=%s',
					rom, tostring(settings.show), tostring(settings.seq_mode)))
			end
		end

		if dirty or (frame_count % 60 == 0) then
			rebuild_bindings()
			dirty = false
		end
	end

	local function on_reset()
		dirty = true
	end

	frame_subscription = emu.add_machine_frame_notifier(process_frame)
	emu.register_frame_done(draw_frame)
	reset_subscription = emu.add_machine_reset_notifier(on_reset)
	stop_subscription = emu.add_machine_stop_notifier(on_stop)

	emu.register_menu(menu_callback, menu_items, _p('plugin-mame_kbd', 'KBD 按键对照表'))

	-- 启动即跑一次菜单自检：menu_items() 只构造数组、不画界面，调用安全。
	-- 目的是让「菜单下标对齐」这件事在每次冒烟日志里都能被验证，
	-- 而不是等到用户发现「选第 2 行、第 1 行的值在变」才知道又错了。
	safe(function() menu_items() end, nil)

	emu.print_info(string.format('[mame_kbd] v%s 已启动（ROM 就绪后再载入专属配置）', exports.version))
end

return exports
