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
--              按钮数 2~4  → 每行 1 个
--              按钮数 5~6  → 每行 2 个
--              按钮数 7 以上 → 每行 3 个
--
-- 绘制：register_frame_done 里往 manager.machine.render.ui_container 画
--       （坐标 0..1 归一化，(0,0)=左上、(1,1)=右下）。
--
-- 持久化：按 ROM 分别保存，互不污染。
--       <插件目录>/settings_<rom>.ini（当前 ROM 的设置）
--       <插件目录>/settings_default.ini（无 ROM 时的默认值）
--       插件目录不可写时回退 <homepath>/mame_kbd/

local exports = {
	name = 'mame_kbd',
	version = '2.8.1',
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
		per_row = 'auto',        -- 'auto' = 按按钮数自适应；1/2/3 = 强制每行格数
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
		mouse_style = 'under',   -- 鼠标/光枪：'under'=M1_B1 / 'plain'=M1B1 / 'num'=M1_1 / 'zh'=鼠标1_1 / 'mou'=Mou1_1
	}
end

local settings = default_settings()

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

-- 按 ROM 名生成设置文件路径；无 ROM 时用 settings_default.ini
local function settings_path(for_write)
	local rom = current_rom()
	local file
	if rom then
		-- ROM 名可能含路径非法字符，统一替换
		local clean = rom:gsub('[\\/:*?"<>|]', '_')
		file = 'settings_' .. clean .. '.ini'
	else
		file = 'settings_default.ini'
	end
	if plugin_folder and plugin_folder ~= '' then
		return plugin_folder .. '/' .. file
	end
	if for_write then return nil end
	return nil
end

local function fallback_dir()
	local home = home_dir()
	if home and home ~= '' then return home .. '/mame_kbd' end
	return nil
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
	local p = settings_path(true)
	if p and write_file(p, body) then return end
	-- 插件目录不可写，回退到 homepath
	local dir2 = fallback_dir()
	if not dir2 then return end
	pcall(function() require('lfs').mkdir(dir2) end)
	local rom = current_rom()
	local name = rom and ('settings_' .. rom:gsub('[\\/:*?"<>|]', '_') .. '.ini') or 'settings_default.ini'
	write_file(dir2 .. '/' .. name, body)
end

-- 把当前设置写成「全局默认」(settings_default.ini)。
-- 用途：在一个 ROM 里调好格式后，一键让其它没有自己 ini 的 ROM 也采用同一套。
-- 注意：settings_<rom>.ini 优先级更高，已存在专属配置的 ROM 不会被覆盖，
-- 需要用「重置本 ROM」把旧文件删掉才会回落到这里（菜单里会明确提示）。
local function save_default_settings()
	local body = serialize()
	local wrote = false
	if plugin_folder and plugin_folder ~= '' then
		if write_file(plugin_folder .. '/settings_default.ini', body) then wrote = true end
	end
	if not wrote then
		local dir2 = fallback_dir()
		if dir2 then
			pcall(function() require('lfs').mkdir(dir2) end)
			if write_file(dir2 .. '/settings_default.ini', body) then wrote = true end
		end
	end
	return wrote
end

-- 删掉本 ROM 的专属 ini，让它回落到 settings_default.ini。
-- 返回：'no_rom'（当前无 ROM）/ 'removed'（删成功）/ 'missing'（本来就没有）/ 'failed'
local function reset_rom_settings()
	local rom = current_rom()
	if not rom then return 'no_rom' end
	local name = 'settings_' .. rom:gsub('[\\/:*?"<>|]', '_') .. '.ini'
	local targets = {}
	if plugin_folder and plugin_folder ~= '' then
		targets[#targets + 1] = plugin_folder .. '/' .. name
	end
	local dir2 = fallback_dir()
	if dir2 then targets[#targets + 1] = dir2 .. '/' .. name end
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
			if n == 1 or n == 2 or n == 3 then cfg.per_row = n end
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
		if v == 'under' or v == 'plain' or v == 'num' or v == 'zh' or v == 'joy' then cfg.joy_style = v end
	elseif k == 'mouse_style' then
		if v == 'under' or v == 'plain' or v == 'num' or v == 'zh' or v == 'mou' then cfg.mouse_style = v end
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

local function load_settings()
	local cfg = default_settings()

	-- 先读默认，再读本 ROM 覆盖
	local dir2 = fallback_dir()
	local ok_any = false

	local p_def = plugin_folder and (plugin_folder .. '/settings_default.ini') or nil
	if p_def and read_into(cfg, p_def) then ok_any = true end
	if dir2 and read_into(cfg, dir2 .. '/settings_default.ini') then ok_any = true end

	local p_rom = settings_path(false)
	if p_rom and read_into(cfg, p_rom) then ok_any = true end
	local rom = current_rom()
	if dir2 and rom then
		local name = 'settings_' .. rom:gsub('[\\/:*?"<>|]', '_') .. '.ini'
		if read_into(cfg, dir2 .. '/' .. name) then ok_any = true end
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
	-- 方向：用户指定 Down=Dn / Left=Lt / Right=Rt（Up 只有 2 字，保持原样最直观）
	DOWN = 'Dn', LEFT = 'Lt', RIGHT = 'Rt',
}

-- 方位修饰键专用缩写（只用于 "Left X" / "Right X" 的 X 部分）。
-- 与 ABBR 分开的理由：ABBR.SHIFT 要给别处保持 'Shift' 五个字符，
-- 而方位键必须压成 'Shft' 才能让 "Left Shift" → 'LShft' 只占 5 位。
local MOD_ABBR = {
	SHIFT = 'Shft', CTRL = 'Ctl', CONTROL = 'Ctl', ALT = 'Alt',
	WIN = 'Win', META = 'Meta', CMD = 'Cmd', GUI = 'Gui',
}

-- 手柄 token 尾部 -> 缩写（JOYCODE_1_YAXIS_UP_SWITCH -> J1_U 等）
local JOY_MAP = {
	['YAXIS_UP_SWITCH'] = 'U', ['YAXIS_UP'] = 'U',
	['YAXIS_DOWN_SWITCH'] = 'Dn', ['YAXIS_DOWN'] = 'Dn',
	['XAXIS_LEFT_SWITCH'] = 'Lt', ['XAXIS_LEFT'] = 'Lt',
	['XAXIS_RIGHT_SWITCH'] = 'Rt', ['XAXIS_RIGHT'] = 'Rt',
	['HAT1UP'] = 'U', ['HAT1DOWN'] = 'Dn', ['HAT1LEFT'] = 'Lt', ['HAT1RIGHT'] = 'Rt',
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
	local sfx = JOY_MAP[up]
	if not sfx then
		local b = up:match('^BUTTON(%d+)$')
		if b then sfx = 'B' .. b end
	end
	if not sfx then
		-- 必须同时捕获「轴名」与「方向」两个值：只捕获轴名却拿去按方向查表，
		-- 这个分支永远不会命中（曾经的实际 bug）。
		local ax, ad = up:match('^([XYZW])AXIS_(%a+)_SWITCH$')
		if ax and ad then
			local dir = ({ UP = 'U', DOWN = 'Dn', LEFT = 'Lt', RIGHT = 'Rt' })[ad]
			if dir then sfx = ax .. dir end
		end
	end
	if not sfx then
		-- 同上：编号与方向要各自捕获。
		local hn, hd = up:match('^HAT(%d)(%u+)$')
		if hn and hd then
			local dir = ({ UP = 'U', DOWN = 'Dn', LEFT = 'Lt', RIGHT = 'Rt' })[hd]
			if dir then sfx = 'H' .. hn .. dir end
		end
	end
	if not sfx then
		sfx = up:gsub('_SWITCH$', ''):gsub('AXIS_', '')
		if #sfx > 5 then sfx = sfx:sub(1, 5) end
	end
	-- 显示形态由 settings.joy_style 决定（用户在菜单里可选）：
	--   'under' = J1_B1 / J1_U / J1_Sta   （默认，下划线分隔最易读）
	--   'plain' = J1B1  / J1U  / J1Sta    （最省位）
	--   'num'   = J1_1  / J1_U / J1_Dn    （按钮去掉 B；方向无序号，仍用字母）
	--   'zh'    = 手柄1_1 / 手柄1_U       （中文设备名 + 按钮去 B）
	--   'joy'   = Joy1_1 / Joy1_U         （英文前缀 + 按钮去 B）
	local mode = settings.joy_style or 'under'
	-- ★ 去 B 的档位是 num / zh / joy 三档，不是只有 num。
	-- 依据：用户原话举例「手柄的按键显示可以自定义选择显示 J1B1 J1_1 手柄1_1，
	-- Joy1_1」—— 后三档给的示例全是「_1」数字式，没有一个带 B。
	-- 曾经把去 B 只写在 num 档，结果 zh/joy 档输出「手柄1_B1 / Joy1_B1」，
	-- 和用户给的示例对不上。
	local digitized = (mode == 'num' or mode == 'zh' or mode == 'joy')
	if digitized then
		-- 只有按钮序号可以去掉 B：方向键 U/Dn/Lt/Rt 没有数字含义，
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

-- 某个 field 当前是否被按下
local function field_pressed(item)
	-- 首选官方 API：ioport:type_pressed(type, player) 直接返回该输入类型当前是否按下。
	-- 这是 MAME 自己维护的状态，不依赖 ioport 的有效电平约定，是最可靠的一路。
	--
	-- 注意 player 参数必须传「字段自身的 player」，不能用 item.player：
	-- item.player 是从 token 尾部数字解析出来的（START2 → 1），而 IPT_START1..4
	-- 这类枚举本身已经内含玩家号、其字段 player 恒为 0。实测（xmen）传 1 去查
	-- ty=8 永远返回 false，正是「P1 开始能变色、P2~P4 开始不变色」的根因。
	-- 因此采集时就把正确值存进 press_player：真实字段用 field.player，
	-- 虚拟项（如 P1_SELECT，ty=43 靠 player 区分）用 token 解析出的玩家号。
	local ioport = safe(function() return manager.machine.ioport end, nil)
	if ioport and item.ty then
		local fpl = item.press_player or 0
		local ok, pressed = pcall(function() return ioport:type_pressed(item.ty, fpl) end)
		if ok and pressed ~= nil then
			return (pressed == true) or (tonumber(pressed) or 0) ~= 0
		end
	end
	-- 回退：直接读 port 值做按位与。
	-- 注意：实测在本机 port:read() 未按键时返回 0（而不是理论上低有效应有的全 1），
	-- 所以这里不能写 band(v, m) == 0——那会把所有项都误判成「按下」。
	-- 只有在与出来的位明显非零时才认为按下，宁可漏判也不误判（误判会让整块常亮）。
	local port = item.port
	if not port then return false end
	local v = safe(function() return port:read() end, nil)
	if v == nil then return false end
	local m = item.mask
	if not m or m == 0 then return false end
	return band(v, m) ~= 0
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

	-- 补「选择」：实测（xmen）没有任何 ioport 字段对应 IPT_SELECT，
	-- 它只存在于通用输入分配表（ioport.types：ty=43、token=P1_SELECT…P4_SELECT）。
	-- 这类槽位没有 port/mask，按下状态只能靠 ioport:type_pressed(ty, player) 获得。
	for pl = 0, 3 do
		collected[pl] = collected[pl] or {}
		if not collected[pl]['SELECT'] then
			local tok = 'P' .. (pl + 1) .. '_SELECT'
			local ty, tpl = nil, nil
			local ok, rty, rpl = pcall(function() return ioport:token_to_input_type(tok) end)
			if ok then
				ty = rty
				tpl = rpl
			end
			if ty then
				local tseq = nil
				do
					local ok2, s2 = pcall(function() return ioport:type_seq(ty, tpl or pl) end)
					if ok2 and s2 and not safe(function() return s2.empty end, false) then
						tseq = s2
					end
				end
				local txt = nil
				if tseq then
					local full = seq_name_of(tseq)
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
				end
				if txt then
					collected[pl]['SELECT'] = {
						kind = 'SELECT',
						sem = 'SELECT',
						field = nil,
						ty = ty,
						port = nil,
						mask = nil,
						defvalue = nil,
						player = pl,
						-- ioport:type_pressed(IPT_SELECT, pl) 才是这条虚拟项的正确查法
						press_player = tpl or pl,
						field_name = tok,
						text = txt,
					}
				end
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
local C_HL = 0xFF00FF66           -- 按下高亮：亮绿
local C_HL_BG = 0xB0008020        -- 按下背景：暗绿半透明

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
		return { fit(head, maxw), fit(text, maxw) }
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

-- 按钮数 → 每行格数
local function per_row_for(button_count)
	if settings.per_row ~= 'auto' then
		return clamp_int(settings.per_row, 1, 3, 1)
	end
	if button_count >= 7 then return 3 end
	if button_count >= 5 then return 2 end
	return 1
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
		local pr = per_row_for(btn)
		if btn > 0 then
			local btns = {}
			for _, it in ipairs(list) do
				if it.kind == 'BUTTON' then btns[#btns + 1] = it end
			end
			local cell_w_px = ((1 / #cols) * out_w - gap_px) / pr
			local maxw_b = cell_w_px / char_px
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
			local lit = found and field_pressed(found)
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
			if settings.highlight and lit then fg = C_HL end
			local bgc = (settings.highlight and lit) and C_HL_BG or nil
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
					local lit = it and it.text and field_pressed(it) or false
					local lines = split_cell(label, it and it.text or '--', maxw)
					if #lines > need then need = #lines end
					if it and it.text then
						fg = settings.highlight and lit and C_HL or C_SPECIAL
					else
						fg = C_NONE
					end
					local bgc = (settings.highlight and lit) and C_HL_BG or nil
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
			local pr = per_row_for(#btns)
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
					local lit = field_pressed(cell.it)
					local fg = cell.it.text and C_BTN or C_NONE
					if settings.highlight and lit then fg = C_HL end
					local bgc = (settings.highlight and lit) and C_HL_BG or nil
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
			emu.print_info(string.format('[mame_kbd][press] %s mask=%s def=%s read=%s cur=%s type_pressed=%s pressed=%s',
				tostring(it.sem), tostring(it.mask), tostring(it.defvalue), tostring(rv),
				tostring(rv and band(rv, it.mask)),
				tp,
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
}
local MOUSE_STYLES = {
	{ id = 'under', text = 'M1_B1',   sample = 'M1_B1' },
	{ id = 'plain', text = 'M1B1',    sample = 'M1B1' },
	{ id = 'num',   text = 'M1_1',    sample = 'M1_1' },
	{ id = 'zh',    text = '鼠标1_1', sample = '鼠标1_1' },
	{ id = 'mou',   text = 'Mou1_1',  sample = 'Mou1_1' },
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
local PAGE_DIAG = 4

local ALL_PAGES = { PAGE_MAIN, PAGE_SHOW, PAGE_FORMAT, PAGE_LOOK, PAGE_DIAG }

local menu_page = PAGE_MAIN
local last_msg = nil        -- 格式页的操作反馈（保存/重置的结果）

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
		entry('▶ 诊断信息', 'ROM 与绘制状态', { kind = 'page', page = PAGE_DIAG })

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
		push('---', '', '')
		push('保存为默认（其他 ROM 通用）', '点此写入', '', { kind = 'save_default' })
		push('重置本 ROM（回落到默认）', '点此删除', '', { kind = 'reset_rom' })
		-- ★ 这一行必须恒定存在（没有消息时显示一个占位符），不能「有消息才加」。
		-- 原因：MAME 菜单的光标是按行下标记的，菜单项数量在运行中变化会让
		-- 光标跳到别的行上（用户按完「保存为默认」一转身发现自己选中的是别的项）。
		-- 所以宁可多一行占位，也不让行数浮动。
		disp('  ↳ 上次操作', last_msg or '—')
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
		push('---', '', '')
		back_row()
	end

	selfcheck_page(menu_page, list, actions)
	last_actions = actions
	return list
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
		if dir == 0 then dir = 1 end
		if settings.per_row == 'auto' then
			settings.per_row = (dir > 0) and 1 or 3
		else
			local n = tonumber(settings.per_row) or 1
			n = n + dir
			if n < 1 or n > 3 then
				settings.per_row = 'auto'
			else
				settings.per_row = n
			end
		end
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
	elseif k == 'mod_style' or k == 'joy_style' or k == 'mouse_style' then
		-- 显示格式只改文字写法，但绑定文本是在采集/rebuild 时就算好的，
		-- 所以必须 rebuild_bindings() 才会立即生效（否则要等下次换 ROM）。
		if k == 'mod_style' then
			settings.mod_style = style_step(MOD_STYLES, settings.mod_style, dir)
		elseif k == 'joy_style' then
			settings.joy_style = style_step(JOY_STYLES, settings.joy_style, dir)
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
