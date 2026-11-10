# MAME 插件开发避坑指南

> 适用：MAME / MAMEUI64 Plus 的 Lua 插件（`plugins/<name>/init.lua` + `plugin.json`）。
> 来源：mame_kbd（v2.0.0 → v2.8.9）与 copilot2p 两个插件的实战踩坑记录。
> 每条格式：**症状 → 根因 → 正确做法**。按「遇到什么现象」检索即可。

---

## 一、文件与加载

### 1.1 plugin.json 带 UTF-8 BOM → 插件根本不加载

**症状**
MAMEUI 弹窗：

```
Unable to parse plugin definition file plugins\<name>\plugin.json.
Errors returned:
Invalid value.
```

插件选项里看不到它，日志里**一行 `[插件名]` 都没有**（不是「运行了但没输出」，是压根没起来）。

**根因**
MAME 用 rapidjson 系解析器，**不接受 UTF-8 BOM**（`EF BB BF`）。官方插件 `plugin.json` 首字节都是 `7B`（`{`）。

**踩坑路径（最坑的地方）**
Windows PowerShell 5.1 的 `Set-Content -Encoding UTF8` / `Out-File -Encoding UTF8` **默认写 BOM**。用 Python `json.dump` 配 `encoding='utf-8'` 不会带 BOM，但若中途经过 pwsh 中转就会中招。

**更坑的地方**：当时本地 / 部署侧 / 归档三处 SHA256 完全一致，但**三个都是带 BOM 的坏文件**。哈希一致只证明副本同步，证明不了内容合法。两个版本（v2.8.0 / v2.8.1）因此从未被加载过，而团队一直在找「为什么拿不到运行日志」，以为是进程占用。

**正确做法**
- 写文件统一用 Python `io.open(path, 'w', encoding='utf-8', newline='\n')`，或 PowerShell `-Encoding UTF8NoBOM`。
- 把**编码检查放为校验脚本第一项**：UTF-8 BOM / UTF-16 BOM / 结尾 NUL / `json.loads` 能否解析。
- 交付前看**首字节**，不要只看 SHA256。`plugin.json` 应为 `7B 0A 09 22`（`{\n\t"`）。

### 1.2 plugin.json 是 225 B 还是 291 B，能看出你有没有整篇重写

**症状**：文件从 225 B 涨到 291 B，格式仍能解析，但缩进从 tab 变成 4 空格；版本号有时跑到顶层。

**根因**：用 `json.dumps(obj, indent=4)` 整篇序列化重写。

**正确做法**
- 这类小配置**永远只做定点字符串替换**：
  ```python
  p = io.open(pj, encoding='utf-8').read()
  p = p.replace('"version": "2.8.8"', '"version": "2.8.9"', 1)
  ```
- 注意版本号的正确层级是 `plugin.plugin.version`（对象套对象），不是顶层 `version`。

### 1.3 插件目录名 / `plugin.json` 的 `name` / 显示名，三者不是一回事

**症状**：改了显示名之后插件加载失败。

**根因**：MAME 的 `boot.lua` 用 `require(entry.name)` 加载插件，所以**目录名与 `plugin.json` 的 `"name"` 必须英文且一致**。

**正确做法**
- 目录名 = `plugin.json` 的 `"name"` = 英文标识（如 `mame_kbd`），永不改动。
- 中文显示名只改 `"description"` 与 `register_menu` 的标题、菜单首行 heading。
- 插件选项里的显示名来自 `plugin.json`，`ini/plugin.ini` 里的条目仍是英文标识。

---

## 二、菜单 API（坑最密集的区域）

### 2.1 `register_menu` 原生不支持子菜单

**症状**：想在菜单里做二级菜单，翻遍 API 找不到。

**根因（实证）**：扫遍官方 14 个插件，`emu.register_menu(callback, populate, title)` 的菜单项 `{label, value, flags}` 里 flags **只出现过 7 种**：`'off'`（纯展示）、`'heading'`（分组标题）、`'lr'`（可左右调）、`'r'` / `'l'`（单侧箭头）、`'lrrepeat'`（连发）、`''`。**没有 subitem / children / expand**。

`plugins/plugin.schema` 是 0 字节，没有 schema 可依。

**正确做法**：用官方 autofire / commonui 的**菜单栈模式**自己实现多页（见 2.2）。菜单项超过 ~20 项就该上多页。

### 2.2 多页菜单的标准写法（官方 autofire 实证）

**结构**

```lua
local PAGE_MAIN, PAGE_SHOW, PAGE_FORMAT = 0, 1, 2
local menu_page = PAGE_MAIN

local function menu_items()
    local list, actions = {}, {}
    local function push(label, value, flags, act)
        list[#list + 1] = { label, tostring(value), flags }
        -- ★ 必须用 actions[#list]，不能用 actions[#list + 1]
        actions[#list] = act
    end
    if menu_page == PAGE_MAIN then
        push('▶ 显示设置', '', 'lr', { kind = 'page', page = PAGE_SHOW })
        ...
    elseif menu_page == PAGE_SHOW then
        ...
    end
    last_actions = actions
    return list
end

local function menu_callback(index, event)
    if event == 'back' then
        if menu_page ~= PAGE_MAIN then menu_page = PAGE_MAIN; return true end
        return false
    end
    local a = last_actions[index]
    ...
    return true
end

emu.register_menu(menu_callback, menu_items, _p('plugin-mame_kbd', '标题'))
```

**要点**
- **动作表下标必须 `actions[#list]`**：`push` 里先追加 `list`，此时 `#list` 已是新长度，用 `#list + 1` 会错位一格（这是一个真实踩过的 bug，表现为「点 A 改了 B」）。
- **稀疏表不能用 `#` 判断长度**。校验时不能写 `#actions == #list`，要遍历 `list[i][3] == 'lr' and actions[i] == nil` 找漏配。
- **多页时动作表必须按当前页重建**，不能缓存。`menu_items()` 每次弹出都会被调用，天然重建。
- `flags` 可以空格组合（官方 commonui 用 `flags .. " nokeys"`）。
- `populate` 的**第二个返回值是光标初始下标**（`return items, selection`），回退到上级时可以用它把光标停回原来那一项。

### 2.3 不处理 `event == 'back'`，子页退不出去

**症状**：进了子页，按退出键没反应，只能退出整个游戏。

**事件全集（实证）**：`'select'`、`'left'`、`'right'`、`'back'`、`'clear'`、`'prevgroup'`、`'nextgroup'`。

**正确做法**
- **双保险**：既处理 `event == 'back'` 出栈，也在子页底部放一行「← 返回上级」由 `select` 出栈。因为 `back` 事件是否对插件菜单派发，不同版本行为未必一致，两路都做才稳。
- 子页的 `back` 要 `return true` 吞掉，否则会连带把上级菜单也关掉。

### 2.4 菜单行数浮动 → 光标跳行

**症状**：某一行有时候出现有时候消失，光标就错位到相邻项。

**根因**：MAME 按**行下标**定位光标。动态增删行会让下标漂移。

**正确做法**：需要「有时才显示」的信息，用**恒定占位**：

```lua
-- ✗ 错
if last_msg then disp('  ↳ 上次操作', last_msg) end
-- ✓ 对
disp('  ↳ 上次操作', last_msg or '—')
```

### 2.5 `register_menu` 只能进「插件选项」子菜单，进不了顶层菜单

**根因**：顶层菜单（输入设定 / 作弊选项 / 插件选项…）硬编码在 MAME 的 C++ 源码里，官方 28 个 `emu.*` API 中没有任何能往顶层插项的接口。

**正确做法**：接受它。用户的操作路径是「Tab → 插件选项 → 你的插件」。

### 2.6 菜单只有「选一项」和「捕获按键」，**没有文本输入控件**

**根因**：官方 commonui 只提供 `input_selection_menu`（选一项）与 `switch_polling_helper`（捕获按键），没有文本框。

**影响**：任何「让用户自己输入名字」的需求都做不了。只能做成**预设档位**（左右切换）。例如「自定义按键显示方式」实际落地为 4~7 个格式档位，而不是让用户打字。

**设计时先问自己**：这个需求能不能表述成「N 个预设里选一个」？不行就要改需求。

### 2.6b 菜单行**无法单独上色**，做不出「颜色预览」

**症状**：想在菜单里用色块预览「物理按下=绿、镜像按下=蓝」，于是在 label 里写 `■ ■ ■ 绿`，进游戏一看——全白，色块和别的行没任何区别。

**根因**：菜单项只是一个 `{label, value, flags}` **文本三元组**，整行由 MAME 按当前主题配色统一绘制。插件拿不到任何 per-row 的绘制接口，label 里的字符只会用菜单的前景色画出来。

**正确做法**：
- 菜单里只写**色名 + 色值**（`绿 #00FF66`），不画色块；
- 让用户看实际效果的办法是「进游戏按住键，看画面下方对照表」——那才是插件自己用 `container:draw_text` 画的地方，颜色由插件完全控制；
- 在菜单页里加一行说明文字指路（`进游戏按住键，看下方对照表`）。

**教训**：菜单能改的只有「有哪些行、行的文字、能不能左右调」，**不能改任何外观**。凡是「预览视觉效果」的诉求，都要转移到插件自己绘制的区域去实现。

### 2.7 边界值的箭头提示

不是坑，是个好习惯：值已到下限时，flags 只给 `'r'`（右侧有箭头）而不是 `'lr'`，用户一眼能看出还有没有余量。

```lua
{ _p(ctx, 'On frames'), tostring(cur.on_frames), cur.on_frames > 1 and 'lr' or 'r' }
```

---

## 三、输入数据模型（最容易理解错的地方）

### 3.1 `ioport.ports` 与 `ioport.types` 是两套东西

- **`ports`**：这个 ROM 实际声明的输入端口与字段（`ports[tag].fields[token]`）。**因游戏而异**。
- **`types`**：MAME 的**通用输入分配表**，与具体游戏无关。`P1_SELECT`…`P4_SELECT`、`START1`…`START8` 这类槽位**永远存在**，且自带默认绑定。

### 3.2 很多 ROM 的端口里根本没有 START 字段

**症状**：「开始」格永远显示 `--`，但 MAME 输入配置菜单里明明有绑定。部分游戏正常、个别游戏异常。

**实证**：`3stooges` 的端口只有 `:DSW`、`:IN1`~`:IN4`、`:P1JOY`~`:P3JOY`、`:r2sound:SB2`，没有任何 START 字段；`tmnt` 同理。它们的「开始」只存在于 `types` 里：

```
[mame_kbd][type] ty=7  pl=0 token=START1 name=1 Player Start  toktoken=START1
[mame_kbd][type] ty=8  pl=0 token=START2 name=2 Players Start
[mame_kbd][type] ty=43 pl=0 token=P1_SELECT name=P1 Select   toktoken=P1_SELECT
```

而 `xmen` 有真实字段（`:EEPROM.玩家 1 开始 ty=7 tok=START1`），所以一直正常。

**正确做法**：凡是从 `types` 才能拿到的语义，都要做「虚拟补位」：

```lua
local function fill_virtual(pl, sem, vtok, vpl)
    if not has_real_field[pl] then return end          -- 该玩家一个真实字段都没有，就不补
    if collected[pl] and collected[pl][sem] then return end
    local ty, tpl = nil, nil
    local ok, rty, rpl = pcall(function() return ioport:token_to_input_type(vtok) end)
    if ok then ty = rty; tpl = rpl end
    if not ty then return end
    local use_pl = tpl; if use_pl == nil then use_pl = vpl end
    if use_pl == nil then use_pl = pl end
    local tseq = nil
    do
        local ok2, s2 = pcall(function() return ioport:type_seq(ty, use_pl) end)
        if ok2 and s2 and not safe(function() return s2.empty end, false) then tseq = s2 end
    end
    if not tseq then return end
    -- 用与真实字段相同的显示逻辑算文本，再塞进 collected[pl][sem]
end

for pl = 0, 3 do
    fill_virtual(pl, 'SELECT', 'P' .. (pl + 1) .. '_SELECT', pl)
    fill_virtual(pl, 'START',  'START' .. (pl + 1), 0)   -- ★ vpl 必须传 0
end
```

**★ 两个必踩的坑**

1. **`START1..8` 的 type player 恒为 0**。这个枚举本身已内含编号，`token_to_input_type` / `type_seq` 必须传 0；传真实玩家号会取不到 seq，补位**静默失败**（不报错，就是没补上）。
2. **兜底清理判据不能再排除这个语义**。原判据 `if sem ~= 'SELECT' and item and item.field then`（只让真实字段算「真实玩家」）。补了虚拟 START 后必须改成 `if item and item.field then` —— 虚拟项本身 `field == nil` 已被天然排除；若继续排除 `'SELECT'`，那些**有真实 START 字段**的玩家（xmen）会被误删整列。

### 3.3 虚拟补位会让「空玩家」复活，导致多画空列

**症状**：3 人游戏仍画 4 列，第 4 列全空；2 人游戏画 4 列且列被挤窄到残字。

**根因**：`types` 里 `P1_SELECT`…`P4_SELECT` 永远存在。无条件补虚拟 SELECT 后，第 4 人也拿到了 1 个条目，整理有序数组时 `#list > 0` 把它判为「在场」。

**正确做法（双保险）**
1. **源头**：只在**该玩家有真实字段**时才补虚拟槽位 —— `if has_real_field[pl] then ... end`。
2. **末尾兜底**：统计每个玩家的**非虚拟**条目数，为 0 就把整列删掉：
   ```lua
   local real = 0
   for sem, item in pairs(collected[pl] or {}) do
       if item and item.field then real = real + 1 end
   end
   if real == 0 then collected[pl] = nil end
   ```

### 3.4 插件侧拿不到「游戏声明了几人」

**根因**：官方 22 个插件全树 grep `count_players|:players|player_count|numplayers` **零命中**。`mameui.exe -listxml <rom>` 里的 `<input players="3">` 是前端元数据，插件访问不到。

**正确做法**：只能靠「该玩家有没有真实输入字段」推断。这就是 3.3 那段逻辑的存在理由。

### 3.5 `field.player` 恒为 0，别拿它当玩家号

**症状**：所有玩家的按键都被归到 P1。

**根因**：真实字段的 `field.player` 恒为 0；玩家号要从 **token 尾部数字**解析（`START2` → 1，`P3_BUTTON2` → 2）。

**正确做法**：单独存一个 `press_player` 字段放真实玩家号，`player` 字段留给解析结果。

### 3.6 `-listxml` 拿不到字段定义

**症状**：想从 `mameui.exe -listxml 3stooges` 里看 START 的 token 形态，结果 `<field>` 出现 **0 次**（`<port>` 内部是空的）。

**正确做法**：token 形态只能靠插件自己的 `dump_tokens` 打日志（见 6.4）。

### 3.7 `type_pressed` 读的是物理状态，`port:read()` 才是最终值

**症状**：别的插件（如 `copilot2p` 镜像）用 `field:set_value(1)` 把某个键「点亮」了，画面里那个键确实在动，但你的插件判定它「没按下」，于是永远不变色。

**根因（2026-11-09 真机探针实测，推翻直觉）**：

| API | 实际读的是 | 看得见 `set_value` 覆盖吗 |
|---|---|---|
| `ioport:type_pressed(ty, pl)` | **物理设备**状态 | **看不见**（pl=0/1/2/3 恒 false） |
| `port:read()` | **最终值**（含程序化覆盖） | **看得见**（mask 位被清零） |
| `input:seq_pressed(seq)` | 物理设备绑定 | 看不见（与 `type_pressed` 同类） |

实测（xmen，`:P2_P4.P2 Button 1`，`mask=16 defvalue=16`，每帧 `set_value(1)`）：

```
f10  基线        read=65535  band=16  def=16  type_pressed=false  → 未按
f13  持续写入    read=65519  band=0   def=16  type_pressed=false  → 最终值按下
f42  停止写入    read=65535  band=16  def=16  type_pressed=false  → 回落未按
```

**正确做法**：

```lua
-- 读「最终值」（含物理 + 镜像覆盖）
local v = port:read()
local cur = band(v, mask)
local dv  = item.defvalue
local pressed = (cur ~= band(dv, mask))     -- ★ 与 defvalue 同掩码位比较

-- 读「物理状态」（区分来源用）
local phys = ioport:type_pressed(ty, pl)
```

**极性判据绝不能写 `band(v, mask) ~= 0`**。本机未按键时 `port:read()` 返回 `65535`（全 1），按下时对应位**清零**；换台机器/换端口可能是高有效，那样写就全反了。用「与 `defvalue` 的同掩码位比较」才与极性无关。

### 3.8 `set_value(1)` 有 1 帧延迟，且必须每帧持续写

**症状**：只调一次 `set_value(1)`，当场读 `port:read()` 还是没变；过几帧又自己弹回去了。

**根因**：写入要到**下一帧**才反映进 `port:read()`；而 MAME 每帧会把物理状态刷新回字段，所以不持续写就会被顶回原值。这正是 `copilot2p` 的 `tick()` 每帧都调 `set_field()` 的原因。

**正确做法**：模拟/仿真这类行为时按「每帧写」来做；判定方则不必关心时序，因为帧初（`add_machine_frame_notifier`）与帧末（`register_frame_done`）读到的值一致。

---

## 四、绘制与字体

### 4.1 键名会被「超长截断」规则砍断语义单元

**症状**：`J1_Sta` 显示成 `J1_S`，`Joy1_1` 显示成 `Joy1`。

**根因**：缩写函数末尾有一条通用规则「未收录的词超过 5 字就取前 4 字」。`J1_Sta` 恰是 6 个字符 → 被砍。`J1Sta`（5 字）时不触发，加了分隔符后长度 +1 才暴露。

**正确做法**：给语义单元加整词豁免，**先判语义单元，再走通用缩略**：

```lua
for _, w in ipairs(words) do
    if w:match('^[JMG]%d') or w:match('^Joy%d') or w:match('^Mou%d')
        or w:match('^手柄%d') or w:match('^鼠标%d') or w:match('^光枪%d') then
        out[#out + 1] = w                      -- 语义单元整词保留
    else
        local a = ABBR[w:upper()]
        if not a and #w > 5 then a = w:sub(1, 4) end
        out[#out + 1] = a or w
    end
end
```

### 4.2 `table.concat` 在单元素时不插分隔符

**症状**：`Left Shift` 想要 `L-Shift`，实际输出 `LShift`。

**根因**：`table.concat(rest, '-')` 里 `rest` 只有 1 个元素（方位词后面就一个词），concat **根本不插入分隔符**。

**正确做法**：单元素场景显式拼：

```lua
if mode == 'hyphen' then return pre .. '-' .. joined end
```

### 4.3 字符能否显示：MAMEUI 走系统 GDI 字体

**实证**
- 部署侧全树 `*.bdf,*.ttf,*.otf,*.ttc,*.fnt,*.fon,*.pcf` 共 **0 个**；`mameui\ui` 目录不存在。
- `mameui.exe` ASCII 扫描只命中 `GDI` / `uifont`，未命中 DirectWrite / Segoe / Arial / Tahoma / NotoSans / msyh / simhei。
- → **UI 文字走系统字体**，只要系统字体里有这个码位就能画。

**已验证可用的几何符号**：`◀ ▶ ↳ ← → ↑ ↓ ▲ ▼`（菜单里的 ◀▶ 是 MAME 自己的选中态，本就常驻，可作为「该字形族可用」的强证据）。

**注意**：截图里 ◀▶ 呈绿色是**菜单选中态配色**，不是字符本身的颜色；格子里画的字符跟随格子前景色。

### 4.4 N 个可切换档位，必须断言「彼此不同」

**症状**：菜单里六个方向格式档位，画到屏幕上全都一样。

**根因**：分隔符判定先看了**手柄格式**再被方向档覆盖：

```lua
local sep = ((mode == 'plain' or mode == 'abxy') and '' or '_')  -- ← 被 adxy 直接置空
if DIR_NOSEP[dstyle] then sep = '' end
```

用户的手柄格式是 `J1A`（本身不带连接符），于是六个方向档全被盖成无连接符，`↑/↓/←/→` 和 `↑↓←→` 撞车。

**为什么测试没抓到**：交叉用例覆盖了 7 种手柄格式 × 6 档 = 42 条，但每条只断言「某档在该格式下输出什么」，**没有任何一条断言「不同档必须彼此不同」**。这是判据设计缺口，不是覆盖率问题。

**正确做法**
- 分隔符/后缀这类属性，**只由它自己的档位决定**，不要被另一组档位影响。
- 加**唯一性断言**：同一外部条件下，N 个档位的输出必须两两不同。
- 判据防空：抓取失败得到空集时，「两两不同」在空集上**恒真**。必须加「抓到空即判失败」守卫。

### 4.5 视口太窄时诊断会假失败

**症状**：诊断脚本报「箭头/三角字形缺失」，但代码明明对。

**根因**：方向格只画得下键盘侧的 `U`，手柄侧的箭头被 `fit()` 截掉，末尾留 `..` 截断标记。

**正确做法**
- 诊断时把 mock 视口放大（`manager.machine.render.ui_target.width = 8000`）。
- 或别靠上屏文字判断，直接读数据字段 / 断言设置已变。
- 循环里取菜单表必须**每轮重新 `pop()`**，否则打印的是陈旧值。

---

## 五、设置持久化

### 5.1 首次进 ROM 会把刚改的设置覆盖掉

**症状**：脚本里改了 `settings.layout = 'auto'`，一进游戏又变回 `'four'`。

**根因**：`process_frame` 首次检测到 ROM 变化时会调 `load_settings()`；没有 ini 就回落默认值。

**正确做法**：切换设置要在**第一次 frame notifier 之后**做（等它加载完），或者显式写完 ini 再触发重载。

### 5.2 `rebuild_bindings()` 不是每帧都跑

**症状**：换了 mock 机器后数据不更新。

**根因**：只在 `dirty or frame_count % 60 == 0` 时跑。

**正确做法**：换机器后推 ≥60 帧。

### 5.3 跑测试必须把 `-cfg_directory` 等指向临时目录

**根因**：插件会把 `settings_<rom>.ini` 写到配置目录（v2.9.5 起到 `<homepath>/mame_kbd/`，之前是插件目录）。测试直接跑会污染用户的真实配置。

**正确做法**：`-cfg_directory` / `-nvram_directory` / `-snapshot_directory` / `-state_directory` 全部指向 `scaffold/_runlog/` 下的临时目录。

### 5.4 设置文件读写的健壮性

- 写 ini 用 `key=value` 逐行，读回时**逐行白名单校验**：值不认识就保留默认，不要照单全收。
- 「保存为默认」与「重置本 ROM」是两件不同的事，不要共用一个文件。
- **本 ROM 配置必须最后读**，才能盖过全局默认。

### 5.5 ★ 配置存 `<homepath>/<插件名>/`，绝不放插件目录（标准做法）

**症状**：升级/重装插件后用户配置全没了；或者想备份配置，得从 `init.lua`、`plugin.json`
里面挑出几个 ini。

**根因**：插件目录装的是**代码**。整目录被替换时配置跟着被覆盖；用户卸载插件时
删目录 = 连配置一起删；有些部署方式（ROM 在只读共享上）插件目录压根不可写。

**正确做法**（`manager.options.entries.homepath:value()` 实测是 `.`，
基准 = `mameui.exe` 所在目录，所以 `./mame_kbd` 就是 `<mameui>/mame_kbd/`）：

```lua
local function config_dir()
	local home = home_dir()          -- homepath:value():match('([^;]+)')
	if home and home ~= '' then return home .. '/mame_kbd' end
	return nil
end

-- mkdir 的返回值不完全可信，判据永远是「现在 attributes 拿得到」
local function ensure_dir(d)
	local ok, lfs = pcall(require, 'lfs')
	if not ok or not lfs then return false end
	if lfs.attributes(d) then return true end
	pcall(function() lfs.mkdir(d) end)
	return lfs.attributes(d) ~= nil
end
```

读取顺序固定为：**配置目录默认 → 插件目录默认（只读兜底）→ 配置目录本 ROM
→ 插件目录本 ROM（只读兜底）**。兜底必须留着：万一搬迁失败（权限、磁盘满），
至少还能读到旧配置，不至于全丢。

### 5.6 ★ 旧配置搬迁的三条铁律（漏一条就丢用户配置）

**症状**：用户升级后配置没搬过来；或者更糟——配置文件凭空消失了。

**正确做法**：

1. **目标已存在时不许覆盖**。否则用户在新版本里保存过的配置，会被插件目录里的
   旧文件反向覆盖，升级一次回到解放前。
2. **回读校验一致才 `os.remove` 源文件**。写失败还删源 = 数据丢失，这是不可接受
   的；宁可留一份重复文件，也不能两头落空。
3. **搬迁必须早于第一次 `load_settings()`**。顺序反了，这一轮读到的还是旧位置的
   文件，用户会看到「搬了但没生效」，下一轮才生效——这种延迟最难排查。

```lua
local function migrate_legacy_configs()
	local d = config_dir()
	if not d or not ensure_dir(d) then return 0 end
	-- ... 枚举 plugin_folder 下的 ^settings_[%w_%-%.]+%.ini$
	-- 目标存在 → 跳过（不覆盖）
	-- 写目标 → 回读比对一致 → os.remove(源)
end

function mame_kbd.startplugin()
	local moved = safe(function() return migrate_legacy_configs() end, 0)
	if moved and moved > 0 then
		emu.print_info(string.format('[mame_kbd] 已把 %d 个旧配置从插件目录搬到 mame_kbd/', moved))
	end
	load_settings()          -- ★ 必须在搬迁之后
	-- ...
end
```

**重置操作要同时清两处**（配置目录 + 插件目录旧残留），否则删完新位置的副本、
下一轮又读到旧位置的旧文件，看起来像「重置没生效」。

**验证要点**（`scaffold/_verify_migrate.py` 的五个场景，普通回归一个都碰不到）：

| 场景 | 断言 |
|---|---|
| A 全新安装 | 两边都没有文件，不报错 |
| B 典型升级 | 旧文件搬到配置目录，插件目录清空，值正确 |
| C 目标已存在 | **不覆盖**新值，**不删**源文件 |
| D 混合文件 | 只搬 `settings_*.ini`，`init.lua` / `plugin.json` 原样保留 |
| E 顺序正确 | 搬迁后同一轮就生效（读到的样式是新值，不是默认值） |

---

## 六、验证方法

### 6.1 本机有 lupa，就一定要用它真跑 Lua

**背景**：本机曾长期认为「没法执行 Lua」（无 lua/luac/luajit 可执行文件）。实际上 `pip install --index-url https://pypi.org/simple lupa` 就能装到 `lupa-2.8`（cp310-win_amd64），用真实 Lua 解释器加载插件。

**做法**：写一份 mock MAME API（`emu` / `manager` / `ioport` / `input` / `container` / `seq` / `field` 全套），然后：

```python
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(MOCK_PRELUDE)
exports = lua.eval('LOAD_PLUGIN')(open(INIT, encoding='utf-8').read())
exports['set_folder']('X:/plugins/mame_kbd'); exports['startplugin']()
```

能覆盖：加载、`set_folder`、`startplugin`、`register_menu`、frame notifier、菜单五个页面、返回路径、设置切换、`draw_frame` 实际绘制文本。

**写 mock 的三条铁律**

1. **seq 必须自带 tokens 字符串**，不能按序列名去查表 —— 四个玩家的 `Kbd Up` 名字相同但手柄 token 不同，按名字查会互相覆盖。
2. **每个 (玩家, 输入) 的 ioport type 必须全局唯一**。曾把方向写成 `100 + pl*10`（四方向共用一个 type）、按键写成 `200 + b`（四人 BUTTON1 共用一个 type），token 表被最后一人覆盖 → 诊断页显示 P1~P3「3 项，按键 0 个」。
3. **键盘 code 必须一一对应**。曾用 `codes[k] = 200 + #codes`，`#codes` 每轮都变，同一 token 拿到不同 code，最终显示成残字。

### 6.2 mock 与真实 API 的差异，会让回归用例假通过或假失败

**实例**：新写「无 START 字段」回归用例，一开始 FAIL。原因不是插件，是 mock 只把 START 注册进 `token_of`，没注册进 `type_of` / `typeseq`。**真实 MAME 的 `types` 里 START 是带默认绑定的**，`token_to_input_type('START1')` 与 `type_seq(7, 0)` 都能取到。

**更险的一次（2026-11-09）**：三色高亮的 mock 把 `ioport:type_pressed` 实现成「读我设的最终值」，于是「镜像=蓝」的用例**假通过**了——真实 MAME 上 `type_pressed` 根本不反映 `set_value` 覆盖（见 3.7），插件在真机上完全失效。**mock 的语义错了，测试就在替你撒谎。**

**教训**：
- 写 mock 要按真实 API 的**数据组织方式**造，不能只造「够用的最小集」；
- 每一条「新特性」用例，都要问一句「这条断言在我的 mock 里成立，能代表真机也成立吗？」——不能的话，就得去真机探针实测一次（见 6.3）。

### 6.3 拿不准 API 语义时，写临时探针插件进真机实测

**适用**：怀疑某个 API 读的是 A 还是 B，且两种假设的修法完全不同。靠读文档、读别的插件源码都推不出来时，不要再猜。

**做法**（约半小时，一次定论）：

1. 在 `scaffold/probe_plugin/` 写一个最小插件（`init.lua` + `plugin.json`，`name` 用 `mame_kbd_probe`）；
2. 部署到部署侧 `plugins\mame_kbd_probe\`，并在 `ini\plugin.ini` **逐行重写**追加 `mame_kbd_probe            1`（`Add-Content` 不补换行会把上一行粘坏）；
3. 用 6.4 的 `Start-Process` 跑法加 `-log -verbose`，日志里 `Select-String '\[probe\]'` 取结果；
4. **验证完立刻删目录 + 从 `plugin.ini` 摘掉那一行**，别把探针留在用户环境里。

**注意**：
- `emu.add_machine_frame_notifier(cb)` 的返回值必须存进**文件级 local 变量**，否则订阅被 GC，回调永远不触发（症状：只打出 startplugin，之后一行都没有）。这是 8.8 那条坑的具体形态。
- 探针要复刻**真实条件**。第一版只调了一次 `set_value(1)`，4 帧内就被顶回，结论完全错；改成每帧持续写才复现出镜像（见 3.8）。

### 6.4 拿真实运行日志的可行方法（UNC 路径场景）

**失败路径（别再试）**
- `cmd /c "cd /d <UNC路径> && ..."` → `CMD does not support UNC paths as current directories.`
- `cmd /c "pushd <UNC> && ..."` → exit 9009，`'mameui.exe' is not recognized as an internal or external command`
- `Get-ChildItem -Recurse` 全盘找 console 版 `mame.exe` → 超 300 s 未完成

**可用路径**

```powershell
net use Z: "\\Ds1821\hd" /persistent:no      # 先映射盘符
$wd = 'Z:\ROM 街机\MAMEUI64 Plus!\mameui'
$t  = 'G:\Python_Code\mame_kbd\scaffold\_runlog'
$p = Start-Process -FilePath "$wd\mameui.exe" `
  -ArgumentList @($rom,'-log','-verbose','-window','-seconds_to_run','6',
                 '-noreadconfig','-nowriteconfig',
                 '-nvram_directory',"$t\nvram", '-cfg_directory',"$t\cfg",
                 '-snapshot_directory',"$t\snap", '-state_directory',"$t\sta") `
  -WorkingDirectory $wd `                      # ★ 必须是 exe 所在目录
  -RedirectStandardOutput "$t\out.txt" `
  -RedirectStandardError  "$t\err.txt" `
  -PassThru -NoNewWindow
$p | Wait-Process -Timeout 90
```

→ 得到 15~18 KB 日志，含 `Starting plugin ...`、`[插件名] vX.Y.Z 已启动`、自定义的 `[dump]/[item]/[toks]` 打点与首帧绘制信息。

**其他事实**
- 部署侧 `mameui\mame.ini` 不存在；真实位置是 `ini\mame.ini`。
- `ini\plugin.ini` 里 `插件名 1` 表示已启用。
- `cfg\<rom>.cfg` 里只有 `<mixer>` / `<counters>`，**不含输入绑定**；菜单里看到的绑定来自 `default.cfg` 或 MAME 内置默认。
- 跑完会写 `mameui\error.log`，但通常只有 screen scale 之类，无插件信息。

### 6.5 有些东西只能人工实测

- 只有 `mameui.exe`、没有 console 版 `mame.exe`，拿不到 stdout（除非用 6.4 的方法）。
- `keybd_event` / `SendInput` 注入被系统拒绝（`SendInput` 直接返回 0）；MAME 输入层走 RawInput，合成按键不进它的输入流。
- 因此「按下变色 / 高亮」「物理按住键的行为」必须用户在游戏内完全退出重启 MAMEUI（**含托盘**）后人工确认。

---

## 七、Lua 语言层面的坑

### 7.1 `local` 不是 hoisted，定义必须早于首次使用

**症状**：`attempt to index a nil value`，但变量明明在上面写过。

**根因**：Lua 的 `local` 从声明位置起才可见。把表定义写在使用点之后，前面就是 `nil`。

**正确做法**：新增表/函数后，**核对一遍行号顺序**（定义行 < 首次使用行）。校验脚本可以打印所有关键符号的行号。

### 7.2 `table.concat`、`#` 对稀疏表的行为

- `table.concat(t, sep)` 单元素不插分隔符（见 4.2）。
- `#t` 对**含 nil 的稀疏表**结果未定义，不能用来判长度或数量。要自己数。

### 7.3 兼容性：避免 `goto` 与位运算符

老的 Lua（5.1）没有 `goto`/`::label::` 与位运算符（`&` `|` `<<` `>>`）。虽然 MAME 0.289 用的 Lua 版本较新，但为兼容性避免使用是稳妥的。校验脚本可以扫一遍确认 0 处。

### 7.4 用 `pcall` 包住可能抛错的外部调用

`ioport:token_to_input_type` / `type_seq` / `field:input_seq` 在字段不存在时可能抛错。一律 `pcall`，失败就当「拿不到」，不要让它冒泡打断整帧绘制。

---

## 八、工程纪律（不吃亏的几条）

### 8.1 三处哈希一致 ≠ 文件正确

见 1.1。哈希只证明副本同步。**内容合法性要单独校验**：编码、JSON 能解析、Lua 能 `load()`。

### 8.2 版本号有三处锚点，改完必须逐一核对

`init.lua` 里的 `version = 'X.Y.Z'`、`plugin.json` 的 `plugin.plugin.version`、迭代记录里的版本段落。三处不一致会让「用户看到的版本」与「代码里的版本」对不上，排查时极其误导。

### 8.3 每份归档放三件，缺一不可

`init.lua` + `plugin.json` + 迭代记录。只放代码，将来不知道当时为什么改；只放记录，回滚不了。

### 8.4 迭代记录末尾保留「下次改动模板」区块

每次在模板**之前**插入新段落，模板本身不动。这样下次改动的格式永远统一。

### 8.5 诊断用的临时改动，验证完必须明确还原

例：为拿到 START 的 token 形态，临时把 `dump_tokens` 的 types 过滤从「只打 SELECT」改成「也打 `^START`」。验证完要还原，并在迭代记录里写明「已还原」，否则这段调试代码会跟着发布出去。

### 8.6 校验脚本本身也会有 bug，别盲信

真实遇到过的校验脚本缺陷：
- 正则只有 2 个捕获组，代码取 `group(3)` → `IndexError: no such group`。
- `extract_calls` 的 names 列表里同一个函数名写了两次 → 数量统计翻倍。
- 只读的诊断页不该要求「有可调项」。
- 期望值本身写错（把 `Kbd Left` 的期望写成 `Left`，实际是 `L`）。

**做法**：校验失败时，先判断「代码错」还是「脚本错」。用反证脚本验证校验器本身可信（喂它一个已知坏文件，看它报不报）。

### 8.7 需求要落到「N 个预设选一个」的形态

见 2.6。MAME 菜单没有文本输入，任何「自定义」都要先转译成预设档位再动手。开工前先跟用户确认档位有哪些、每档长什么样，比写完再返工便宜得多。

### 8.8 `emu.add_machine_frame_notifier` 的返回值必须存起来

**症状**：插件能启动，`startplugin()` 里的第一行日志正常打出，然后**再也没有任何输出**——没有报错、没有绘制、什么都不发生。

**根因**：`emu.add_machine_frame_notifier(cb)` 返回的是一个订阅对象，**必须持有引用**，否则会被 GC 回收，回调从此不再被调用。

**正确做法**：

```lua
local frame_subscription = nil          -- ★ 文件级 local，别写进函数里
frame_subscription = emu.add_machine_frame_notifier(process_frame)
```

`register_frame_done` / `add_machine_reset_notifier` / `add_machine_stop_notifier` 同理。

**验证方法**：启动日志里补一行把返回值打出来（`emu.print_verbose('[probe] sub=' .. tostring(sub))`），能看到 `sol.util::notifier_subscription: 0x...` 就说明持有成功。

---

## 附：快速检查清单（发布前）

- [ ] `plugin.json` 首字节 `7B`，无 BOM；`json.loads` 能解析；`plugin.plugin.version` 正确
- [ ] `init.lua` 无 BOM、全 LF、能 `load()` 通过
- [ ] 版本号三处一致（init.lua / plugin.json / 迭代记录）
- [ ] 菜单：`actions[#list]` 下标正确、有 `back` 处理、行数不浮动
- [ ] 新增档位有**唯一性断言**（彼此不同）
- [ ] 新增档位**默认值互不相同**（默认就撞色/撞名 = 功能等于没做）
- [ ] 菜单里没有画「预览色块」之类的假视觉（菜单无法上色，见 2.6b）
- [ ] 新增设置项：`default_settings` / `serialize` / `apply_kv` 白名单**三处都加了**
- [ ] 新增设置项有一条「写盘 → 新实例重读 → 值不变」的闭环用例
- [ ] **配置写在 `<homepath>/<插件名>/`，不在插件目录**（见 5.5）
- [ ] **旧配置搬迁**：目标已存在不覆盖、回读一致才删源、早于首次 `load_settings()`（见 5.6）
- [ ] 搬迁有专项用例（至少覆盖「目标已存在」「非配置文件不被误搬」两个场景）
- [ ] 语义单元有整词保护（不被长度规则截断）
- [ ] 新增表/函数的作用域顺序核对过（定义早于使用）
- [ ] 四套校验（静态 / lupa 真跑 / 列数与输入模型 / 绘制诊断）全过
- [ ] 跑过一次真实 MAME 日志（关键路径有打点）
- [ ] 临时诊断代码已还原
- [ ] 归档三件齐全；本地 / 部署侧 / 归档哈希一致
- [ ] 迭代记录新段落已加，末尾模板保留
