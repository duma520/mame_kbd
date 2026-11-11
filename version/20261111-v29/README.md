# mame_kbd 插件截图：

<img width="1337" height="1033" alt="image" src="https://github.com/user-attachments/assets/1ca128ae-8ebf-4fea-bbd5-88a63ca2e8a3" />

<img width="1337" height="1033" alt="image" src="https://github.com/user-attachments/assets/0bb3c162-5286-4f5b-8812-8b257f907cd1" />

<img width="753" height="1033" alt="image" src="https://github.com/user-attachments/assets/9206fc8d-7d07-422b-94c5-2bfb262fb1d1" />

<img width="753" height="1033" alt="image" src="https://github.com/user-attachments/assets/b6b9b6c7-c3df-4016-870f-e639cacf44b8" />

<img width="753" height="1033" alt="image" src="https://github.com/user-attachments/assets/6b277b01-43ad-4704-a9e3-bb85643a5e10" />

<img width="753" height="1033" alt="image" src="https://github.com/user-attachments/assets/8ab1bc4d-6e19-46f2-a8e8-adfcf0ac5210" />

<img width="753" height="1033" alt="image" src="https://github.com/user-attachments/assets/ee18363d-8bd9-4e13-ad88-06c8c393843d" />

# MAME 按键对照插件 `mame_kbd` 完全说明书

**从零基础到高级应用完全指南**

> 适用插件：MAME / MAMEUI64 Plus 的 Lua 插件 `mame_kbd`  
> 当前说明版本：**v2.9.8**  
> 验证环境：MAMEUI 0.289（记录中多轮真机验证）  
> 本文档基于你提供的《MAME插件开发避坑指南》《软件升级迭代记录》、`init.lua`、`plugin.json` 整理。若与仓库最新代码不一致，以仓库最新代码和 `LICENSE` 为准。

---

## 封面信息

- **作者**：杜玛
- **版权**：永久
- **日期**：永久
- **邮箱**：不提供
- **开源许可证**：MIT（适用于插件源代码；本文档文字部分的转载与商业使用限制见下方版权声明）
- **GitHub**：https://github.com/duma520
- **网站**：https://github.com/duma520
- **项目地址**：https://github.com/duma520/mame_kbd
- **问题报告**：通过 GitHub Issues 提交
- **开发时间**：2026-11-8

**版权声明**  
© 永久 杜玛 保留所有权利。  
本文档内容未经书面许可不得转载或用于商业用途。  
我们不提供私人邮箱支持，所有技术支持都通过公开渠道进行，以便其他用户也能受益。  
插件源代码按 MIT 许可证授权；源码文件头如保留 BSD-3-Clause 等其它声明，以仓库根 `LICENSE` 与源码文件头为准。本文档文字部分的转载/商用限制不改变源代码许可证授予你的权利。

---

## 目录

1. 一分钟速览：这是什么、能做什么
2. 读者路线：不同人该怎么读
3. 零基础安装与启用
4. 第一次使用：进游戏、开菜单、看懂画面
5. 菜单总览：六页结构
6. 设置项逐项说明
   - 6.5 每行按键数 `per_row`（重点：`自动` 到底怎么算）← 不懂版式为什么变的看这里
7. 显示格式档位大全
8. 按键颜色与三态高亮
9. 配置文件、保存、重置与迁移
10. 常见问题与故障排查
11. 高级原理：数据模型与绘制机制
12. 开发者指南：API、代码结构、测试与探针
13. 部署/运维/打包指南
14. 测试与质量保证指南
15. 版本更新简介（v2.0.0 → v2.9.8）
16. FAQ：普通用户 30 问
17. 附录：菜单速查、档位表、颜色表、文件清单、术语表
18. 许可证与支持说明

---

# 1. 一分钟速览：这是什么、能做什么

`mame_kbd` 是一个 MAME / MAMEUI64 Plus 的 Lua 插件。它会在游戏画面下方显示 **P1～P4 四列按键对照表**，告诉你：

- 方向键：上/下/左/右分别绑定了什么；
- 选择、开始绑定了什么；
- 按钮 1～N 分别绑定了什么；
- 键盘、手柄、鼠标/光枪的绑定可以同时显示或按优先级显示；
- 你按下某个键时，对应格子会变色高亮；
- 如果被 `copilot2p` 之类的插件“镜像”带动，也会用不同颜色区分；
- 你可以自定义键名写法、方向字符、颜色、行距、边距、背景透明度等；
- 配置按 ROM 分开保存，也可以保存为“其他 ROM 通用默认”。

**一句话**：它是一个“看得见的按键说明书”，让玩家不用反复进 MAME 输入配置菜单就能知道当前游戏每个玩家怎么操作。

**适合谁**：

- 普通玩家：看按键、调显示、换颜色；
- 街机厅/家庭影院维护者：统一部署、统一默认配置；
- MAME 前端整合者：打包插件、检查编码和版本；
- 插件开发者：学习 MAME Lua 插件菜单、ioport 数据模型、绘制、持久化；
- 测试/QA：使用文档中的验证脚本和排错表；
- 文档/翻译人员：按术语表统一翻译。

---

# 2. 读者路线：不同人该怎么读

| 你是谁 | 建议阅读 | 你可以快速得到 |
|---|---|---|
| 普通玩家 | 第 3、4、5、6、7、8、10 章 | 安装、开菜单、调显示、排错 |
| 运维/部署人员 | 第 3、9、13、15 章 | 放文件、启用插件、配置目录、迁移、版本 |
| 插件开发者 | 第 11、12、14 章 + 附录 | 数据模型、API 坑、测试方法 |
| 测试/QA | 第 10、14、15 章 | 回归清单、验证脚本、版本差异 |
| 文档/翻译 | 第 6、7、8、17 章 | 设置名、档位名、术语表 |
| 想改代码的人 | 第 11、12 章 + 《避坑指南》 | 菜单下标、BOM、type_pressed、GC 等 |

---

# 3. 零基础安装与启用

## 3.1 你需要准备什么

- MAME 或 MAMEUI64 Plus（记录中验证为 MAMEUI 0.289）；
- 插件目录：通常是 `mameui\plugins\`；
- 插件本体两个文件：
  - `init.lua`
  - `plugin.json`
- 一个文本编辑器（建议支持 UTF-8 无 BOM、LF 换行）；
- 如果要启用插件，需要编辑 `ini\plugin.ini`。

## 3.2 正确目录结构

推荐：

```text
MAMEUI64 Plus!\mameui\
├─ mameui.exe
├─ plugins\
│  └─ mame_kbd\
│     ├─ init.lua
│     └─ plugin.json
├─ ini\
│  └─ plugin.ini
└─ mame_kbd\                ← 运行后自动生成，放配置
   ├─ settings_default.ini
   └─ settings_<rom>.ini
```

注意：

- **插件目录名**必须是 `mame_kbd`；
- `plugin.json` 里的 `"name"` 必须是 `mame_kbd`；
- 目录名、`name`、`ini\plugin.ini` 条目三者英文一致；
- 中文显示名只改 `description` 或菜单标题，不要改 `name`。

## 3.3 `plugin.json` 要求

当前文件内容类似：

```json
{
	"plugin": {
		"name": "mame_kbd",
		"description": "Show P1-P4 direction/select/start/button key bindings at the bottom of the screen",
		"version": "2.9.8",
		"author": "local",
		"type": "plugin",
		"start": "true"
	}
}
```

**关键要求**：

- 必须是 **UTF-8 无 BOM**；
- 首字节应为 `7B`，也就是 `{`；
- 不要用 Windows PowerShell 5.1 的 `Set-Content -Encoding UTF8` 写它，因为会带 BOM；
- 推荐 Python：

```python
import io
io.open(path, 'w', encoding='utf-8', newline='\n').write(text)
```

- 或 PowerShell 7 的 `-Encoding UTF8NoBOM`。

**为什么重要**：MAME 的 JSON 解析器不接受 UTF-8 BOM。带 BOM 时 MAMEUI 可能弹：

```text
Unable to parse plugin definition file plugins\mame_kbd\plugin.json.
Errors returned:
Invalid value.
```

插件选项里看不到它，日志里一行 `[mame_kbd]` 都没有。

## 3.4 启用插件

打开 `ini\plugin.ini`，确保有一行类似：

```text
mame_kbd            1
```

`1` 表示启用。不同 MAME 前端可能叫“插件选项/插件菜单”，但 `plugin.ini` 是常见位置。

> 注意：`Add-Content` 追加时如果上一行没有换行，可能把上一行粘坏。建议逐行重写或先确认换行。

## 3.5 安装后的最小验证

1. 完全退出 MAMEUI（包括托盘图标）；
2. 重启 MAMEUI；
3. 进任意游戏；
4. 按 `Tab`；
5. 找“插件选项”或“插件菜单”；
6. 应看到 `KBD 按键对照表`；
7. 进游戏画面下方应出现 P1～P4 列。

如果看不到插件：

- 检查 `plugin.json` 是否 BOM；
- 检查 `plugin.ini` 是否启用；
- 检查目录名是否为 `mame_kbd`；
- 检查 MAME 日志是否出现 `Starting plugin mame_kbd...`。

---

# 4. 第一次使用：进游戏、开菜单、看懂画面

## 4.1 画面布局

默认每列从上到下：

```text
P1
上:U  下:D  左:L  右:R
选择:...   开始:...
1:...  2:...  3:...
```

- 第 1 行：玩家标题 `P1`～`P4`；
- 第 2 行：方向键固定 4 格，顺序固定为 上/下/左/右；
- 第 3 行：选择/开始，固定两格；
- 之后：按钮行，按按钮数量自适应每行 1/2/3 格；
- 没有绑定时显示 `--` 或 `:-`；
- 按下时按颜色高亮。

## 4.2 菜单路径

常见路径：

```text
Tab → 插件选项 / 插件菜单 → KBD 按键对照表
```

主页有五个入口：

1. ▶ 显示设置
2. ▶ 显示格式
3. ▶ 外观微调
4. ▶ 按键颜色
5. ▶ 诊断信息

主页还有插件级操作：

- 保存为默认（其他 ROM 通用）
- 重置本 ROM（回落到默认）
- ↳ 上次操作

## 4.3 菜单操作键

- 上下：移动光标；
- 左右：调整可左右切换的项；
- 回车/选择：进入子页、切换开关、执行操作；
- `Esc` / `back`：返回上级；
- 每页底部还有 `← 返回上级` 可点。

菜单级支持 `lrrepeat`：按住左右键可连续走档，适合 30 档颜色和 7 档手柄格式。

## 4.4 修改会自动保存吗？

会。大多数设置切换后会写入当前 ROM 的：

```text
<homepath>/mame_kbd/settings_<rom>.ini
```

“保存为默认”写：

```text
<homepath>/mame_kbd/settings_default.ini
```

“重置本 ROM”删除当前 ROM 的 ini，让它回落到默认。

---

# 5. 菜单总览：六页结构

MAME 原生菜单不支持真正的子菜单，所以本插件用“菜单栈/按页 populate”的方式实现多页。

| 页 | 名称 | 作用 | 典型项 |
|---|---|---|---|
| 0 | 主页 | 入口 + 插件级操作 | 五个入口、保存默认、重置本 ROM、上次操作 |
| 1 | 显示设置 | 显示什么、怎么排 | 显示开关、列布局、标签语言、每行按键数（自动/1~16）、绑定显示、换行、选择/开始、高亮 |
| 2 | 显示格式 | 键名怎么写 | 修饰键格式、手柄格式、鼠标/光枪格式、手柄方向格式 |
| 3 | 外观微调 | 像素级布局 | 行距、底部边距、列间隙、背景不透明度、字符宽度估计 |
| 4 | 按键颜色 | 三态颜色 | 物理按下、镜像按下、同时按下 |
| 5 | 诊断信息 | 排查 | 当前 ROM、玩家数、P1～P4 明细、绘制统计、配置目录 |

**重要**：菜单只能改“有哪些行、行的文字、能不能左右调”，不能单独给某一行上色，也没有文本输入控件。所以颜色是预设档位，不是调色板；键名是档位，不是逐键起名。

---

# 6. 设置项逐项说明

下表是当前 `default_settings()` 的主要设置。默认值以 v2.9.8 为准。

| 键 | 默认值 | 作用 | 普通用户建议 | 开发者注意 |
|---|---|---|---|---|
| `show` | `true` | 是否显示对照表 | 开 | 关闭后 `draw_frame` 直接返回 |
| `layout` | `four` | `four` 固定四列；`auto` 仅显示有输入的玩家 | 3/2 人游戏建议 `auto` | `auto` 依赖 `present[pl]`，虚拟补位不能撑空列 |
| `label` | `zh` | `zh` 中文标签；`ascii` U/D/L/R | 中文用户 `zh` | 只影响标签，不影响绑定文本 |
| `per_row` | `auto` | 每行按钮格数；`auto` 或 `1`~`16` | 默认 `auto` | `auto` = 按当列可用宽度自适应：在「所有键名都能一行完整显示」的前提下取最大格数（上限 16，与单玩家按键上限对齐；放不下就减格，最低 1 格）。它会看实际键名长度，换过绑定后算出的格数可能变化；想要固定版式就手填 1~16 |
| `show_start` | `true` | 显示“选择/开始”行 | 开 | 无 START/SELECT 时仍保持版式 |
| `highlight` | `true` | 按下高亮 | 开 | 关闭时三色都不生效 |
| `seq_mode` | `first` | `first` 键盘+手柄；`priority` 手柄>键盘>鼠标；`full` 全部 | 想看全绑定用 `first`，窄屏用 `priority` | `priority` 返回单路，避免方向行误判两行 |
| `wrap` | `true` | 长键名自动换行 | 开 | 字号不能调小，只能换行 |
| `line_px` | `24` | 行距像素 | 面板太高就调小 | 10..64 |
| `bottom_px` | `28` | 距底部边距 | 默认 | 0..200 |
| `col_px` | `6` | 列间隙 | 默认 | 0..64 |
| `bg_alpha` | `200` | 背景不透明度 0..255 | 看不清可调高 | 0..255 |
| `char_px` | `15` | 半角字符宽度估计 | 截断多可调大；留白多可调小 | 4..32 |
| `mod_style` | `short` | 修饰键格式 | `LShft` | 4 档 |
| `joy_style` | `under` | 手柄格式 | `J1_B1` | 7 档 |
| `mouse_style` | `under` | 鼠标/光枪格式 | `M1_B1` | 5 档 |
| `dir_style` | `letter` | 手柄方向格式 | `U/D/L/R` | 6 档 |
| `hl_phys` | `green` | 物理按下颜色 | 绿 | 30 档颜色 id |
| `hl_mirror` | `blue` | 仅镜像颜色 | 蓝 | 30 档 |
| `hl_both` | `gold` | 同时按下颜色 | 金 | 30 档 |

## 6.1 列布局 `layout`

- `four`：永远画 P1～P4 四列，没人玩的列显示空/`--`；
- `auto`：只画有真实输入的玩家列。

`auto` 的判断不是问 MAME“这游戏几人”，而是看“该玩家有没有真实输入字段”。所以插件会做虚拟补位，但只给已经有真实字段的玩家补 SELECT/START，避免 3 人游戏画出第 4 列空列。

## 6.2 绑定显示 `seq_mode`

- `first`：键盘 + 手柄都显示，例如 `LCtl J1_B1`；
- `priority`：手柄 > 键盘 > 鼠标，只显示最高优先级那一路；
- `full`：显示 MAME 的完整序列名，通常最长。

例子：

```text
first    : 1:LCtl J1_B1
priority : 1:J1_B1        （有手柄）
priority : 1:LCtl         （无手柄，退键盘）
priority : 1:M1_B1        （只有鼠标）
```

## 6.3 字符宽度估计 `char_px`

MAME 的 UI 文字是固定字模，`draw_text` 没有字号参数，不能调小字号。`char_px` 是插件用来估算“一个半角字符占多少像素”的参数，用来决定是否截断/换行。

- 默认 15；
- 如果经常看到 `..` 截断，可调大；
- 如果格子里留白太多，可调小；
- 范围 4..32。

## 6.4 行距与边距

- `line_px`：每行高度；
- `bottom_px`：面板距底部；
- `col_px`：列与列之间空隙；
- `bg_alpha`：整条背景透明度。

如果面板挡住游戏画面，先调小 `line_px`，再调小 `bottom_px`。

## 6.5 每行按键数 `per_row`（重点：`自动` 到底怎么算）

这是最容易被误解的一项，单独讲清楚。

### 6.5.1 它控制什么

每个玩家那一列里，**一行放几个按键格**（另一维度是「几列」，见 `layout`）。

- `auto`（默认）：按当前分辨率、当前这一列的宽度**自动算**；
- `1`～`16`：强制每行这么多格，不管放不放得下。

上限 16 不是随手定的数——它正好等于 `MAX_BUTTON`，也就是**单个玩家最多 16 个按键**。再往上放开也没有第 17 个键可填，所以 16 就是理论上限。

### 6.5.2 `自动` 的三步算法

用一句话概括：**先量这一列有多宽，再量每个按键要完整显示需要多宽，最后算这一行能放几格。**

```text
① 取列宽
   col_w_px = (1 / 列数) × 屏幕宽 − 列间距
   ↑ 屏幕宽取自 render.ui_target.width，是当前实际分辨率，不是写死的

② 试算「如果一行放 pr 格，每格能放几个字符」
   maxw = (col_w_px / pr) / char_px

③ 逐个按键判断：所有键名都能单行完整放下 → 这一档成立
   从 pr = 2 开始往大试，一旦有按键放不下就停在上一档
   上限 min(16, 该玩家按键数)，最低 1 格兜底
```

三个要点：

1. **「完整显示」的判定标准与真实绘制用的是同一套**。放得下就是放得下，不会出现「自动算得下、画出来却补了 `..`」。
2. **格数越多格子越窄，单调性成立**，所以「一旦放不下就停」不会漏掉更优解。
3. **算出来的是格数，不是像素**。它随分辨率变化，1280 和 4K 下算出的格数不同，这是设计意图。

### 6.5.3 实测：分辨率越高，一行放下的格数越多

16 键机台，4 列布局，`per_row=auto`（所有档位截断数均为 0）：

| 屏幕宽度 | `自动` 算出格数 |
|---|---|
| 1920（1080p） | 2 |
| 3840（4K） | 5 |
| 7680 | 10 |
| 10240 | 14 |
| 15360 | **16**（封顶） |

8 键机台（如《X战警》这类标准六键街机布局）同样随宽度增长：

| 屏幕宽度 | `自动` 算出格数 |
|---|---|
| 640 / 1024 / 1280 | 1 |
| 1920 | 2 |
| 2560 | 3 |
| 3840 | 5 |
| 5120 | 7 |
| 7680 | 8（该机台按键上限） |

所以高分辨率不只是「格子变大」，而是**一行真的能塞下更多格**。如果你的屏幕够宽、机台按键够多，`自动` 一样能涨到 16 格。

### 6.5.4 和 `char_px` 的关系（重要）

`char_px` 是「一个半角字符占多少像素」的**估算值**（默认 15）。它是上面第 ② 步的分母。

| `char_px` | 后果 |
|---|---|
| 估**大**了 | 每格被认为「放不下」，`自动` 会**少算**格数（明明放得下却降档） |
| 估**小**了 | 每格被认为「放得下」，`自动` 会多算，实际绘制时被截断成 `..` |

为什么只能估算？因为 MAME 的 `container:draw_text` **没有返回文本宽度的接口**，只有固定点阵字模、也没有字号参数。默认 15 是照 1351px 宽四列时约 16px/半角取的保守值。

MAME 的字模是固定像素的（不随分辨率缩放），所以 `char_px` 保持常量是对的——分辨率升高 ⇒ 屏幕像素变多 ⇒ 能放更多字符 ⇒ `自动` 自动涨档，这个闭环成立。

### 6.5.5 两个容易搞反的地方

**① 想更宽松，要往「小」调，不是往「大」调**

格数越多，每格越窄。嫌挤的时候把格数调**小**（或设回 `自动`），调大只会更挤。

**② 手填 9 格以上，键名会被压成编号**

1080p 四列布局下，每行 16 格时每格只剩约 1 个字符宽，`1:LCtl Joy1_1` 这种必然放不下。此时插件会退化成只画按键编号（`1`、`2`…），**不是故障**。

> v2.9.8 修过这里的真实缺陷：早先的实现在极窄档会把整格画成**空白**（不是截断成 `..`，而是什么都不画），看起来像插件坏了。现在至少会画出编号。

### 6.5.6 什么时候该用手动档位

| 场景 | 建议 |
|---|---|
| 想每台机器版式一致、不随分辨率变 | 手填固定的 1～6 |
| 就是嫌格子太大、想紧凑一点 | 手填 3～4（先看 `自动` 现在是几格，别一步跨太大） |
| 只是想看清键名 | 保持 `自动` |
| 换过按键绑定后版式变了 | 正常现象——`自动` 看的是实际键名文本，改键后长度变了格数当然会变 |

---

# 7. 显示格式档位大全

## 7.1 修饰键格式 `mod_style`（4 档）

| id | 菜单显示 | 实际效果 | 说明 |
|---|---|---|---|
| `short` | `LShft` | `LShft / RShft / LCtl / RCtl / LAlt / RAlt` | 默认，最省位 |
| `zh` | `左Shft` | `左Shft / 右Shft` | 中文方位 |
| `hyphen` | `L-Shift` | `L-Shift / R-Shift` | 带连字符 |
| `full` | `全称` | `Left Shift / Right Shift` | MAME 原文，不缩写 |

注意：`full` 对单字方向仍可能显示 `L`，因为单字先走 ABBR 表。文档中写“全称”主要针对 `Left Shift` 这类两词组合。

## 7.2 手柄格式 `joy_style`（7 档）

| id | 菜单显示 | 按钮 1 示例 | 方向示例 | 说明 |
|---|---|---|---|---|
| `under` | `J1_B1` | `J1_B1` | `J1_U` | 默认，下划线分隔 |
| `plain` | `J1B1` | `J1B1` | `J1U` | 最省位 |
| `num` | `J1_1` | `J1_1` | `J1_U` | 按钮去 B；方向保持字母 |
| `zh` | `手柄1_1` | `手柄1_1` | `手柄1_U` | 中文设备名 |
| `joy` | `Joy1_1` | `Joy1_1` | `Joy1_U` | 英文前缀 |
| `abxy` | `J1A` | `J1A/J1B/J1X/J1Y/J1L1/J1R1/J1L2/J1R2` | `J1U` | 字母式无分隔 |
| `abxyu` | `J1_A` | `J1_A/J1_B/J1_X/J1_Y/J1_L1/J1_R1/J1_L2/J1_R2` | `J1_U` | 字母式有分隔 |

按钮 5～8 映射为 `L1/R1/L2/R2`。按钮 9 及以后仍用 `B<n>`，因为字母表只定义到 8。

## 7.3 鼠标/光枪格式 `mouse_style`（5 档）

| id | 菜单显示 | 示例 |
|---|---|---|
| `under` | `M1_B1` | `M1_B1`，光枪 `G1_B1` |
| `plain` | `M1B1` | `M1B1` |
| `num` | `M1_1` | `M1_1` |
| `zh` | `鼠标1_1` | `鼠标1_1`，光枪 `光枪1_1` |
| `mou` | `Mou1_1` | `Mou1_1` |

## 7.4 手柄方向格式 `dir_style`（6 档）

只作用于手柄方向，键盘方向仍走 `ABBR` 表。

| id | 菜单显示 | 实际效果 |
|---|---|---|
| `letter` | `U/D/L/R` | `J1_U / J1_D / J1_L / J1_R` |
| `word` | `Up/Dn/Lt/Rt` | `J1_Up / J1_Dn / J1_Lt / J1_Rt` |
| `arrow` | `↑/↓/←/→` | `J1_↑ / J1_↓ / J1_← / J1_→` |
| `arrown` | `↑↓←→` | `J1↑ / J1↓ / J1← / J1→` |
| `tri` | `▲/▼/◀/▶` | `J1_▲ / J1_▼ / J1_◀ / J1_▶` |
| `trin` | `▲▼◀▶` | `J1▲ / J1▼ / J1◀ / J1▶` |

**重要规则**：方向格的连接符只由 `dir_style` 决定，不被 `joy_style` 覆盖。`letter/word/arrow/tri` 带 `_`，`arrown/trin` 不带。这是 v2.8.7 修过的坑：早期用 `joy_style=abxy` 时六档看起来一样。

## 7.5 为什么没有“逐键自定义名称”

MAME 插件菜单只有“选一项”和“捕获按键”两种交互，官方 commonui 没有文本输入控件。所以不能做“让用户输入自定义名字”的界面。所有“自定义”都落成预设档位。

---

# 8. 按键颜色与三态高亮

## 8.1 三种状态

| 状态 | 默认颜色 | 含义 |
|---|---|---|
| 物理按下 | 绿 `#00FF66` | 你用手按着真实键/手柄 |
| 仅镜像按下 | 蓝 `#40C4FF` | 别的插件（如 `copilot2p`）通过 `set_value` 写入 |
| 同时按下 | 金 `#FFD23F` | 本格先被镜像带动，随后你又物理按下 |

## 8.2 判定原理（专业）

- `port:read()` 读**最终值**，包含程序化覆盖；
- `ioport:type_pressed(ty, pl)` 读**物理设备**状态，看不见 `set_value` 覆盖；
- `input:seq_pressed(seq)` 也读物理绑定，看不见覆盖；
- 按下判据用“`band(read, mask) ~= band(defvalue, mask)`”，与端口极性无关；
- “同时”用逐格时序标记：先出现“最终值真但物理假”记 `mirror_flag`，之后物理也真则判 `PRESS_BOTH`；
- 不采用“另一个玩家也按着同键”来侧推，避免把镜像源玩家误判成金色。

## 8.3 颜色页

菜单：`KBD 按键对照表 → 按键颜色`。

三行：

- 物理按下
- 镜像按下
- 同时按下

左右切换 30 档颜色。菜单里只显示“色名 #RRGGBB”，不画色块，因为菜单行无法单独上色。想看效果：进游戏按住键，看画面下方对照表。

## 8.4 30 档颜色表

| id | 名称 | 前景色 | 背景色 |
|---|---|---|---|
| `green` | 绿 | `0xFF00FF66` | `0xB0008020` |
| `green_l` | 浅绿 | `0xFF66FF9C` | `0xB02B6B41` |
| `green_d` | 深绿 | `0xFF00B84A` | `0xB0004D1F` |
| `lime` | 黄绿 | `0xFFB0FF3C` | `0xB04A6B19` |
| `mint` | 薄荷 | `0xFF6CFFC8` | `0xB02D6B54` |
| `cyan` | 青 | `0xFF4FE8D0` | `0xB0006058` |
| `aqua` | 水蓝 | `0xFF3CE8FF` | `0xB019616B` |
| `blue` | 蓝 | `0xFF40C4FF` | `0xB0003C80` |
| `blue_l` | 浅蓝 | `0xFF8CD8FF` | `0xB03A5A6B` |
| `blue_d` | 深蓝 | `0xFF1A78D0` | `0xB00B3257` |
| `azure` | 天青 | `0xFF7AA8FF` | `0xB033466B` |
| `indigo` | 靛 | `0xFF6C7CFF` | `0xB02D346B` |
| `purple` | 紫 | `0xFFD08CFF` | `0xB0503080` |
| `purple_l` | 浅紫 | `0xFFE8B8FF` | `0xB0614D6B` |
| `purple_d` | 深紫 | `0xFF9A4CD0` | `0xB0402057` |
| `magenta` | 洋红 | `0xFFFF5CE0` | `0xB06B275E` |
| `pink` | 粉 | `0xFFFF80C0` | `0xB0802050` |
| `rose` | 玫红 | `0xFFFF5C9E` | `0xB06B2742` |
| `red` | 红 | `0xFFFF5A5A` | `0xB0802020` |
| `red_l` | 浅红 | `0xFFFF8C8C` | `0xB06B3B3B` |
| `red_d` | 深红 | `0xFFD02A2A` | `0xB0571212` |
| `coral` | 珊瑚 | `0xFFFF7A5C` | `0xB06B3327` |
| `orange` | 橙 | `0xFFFFA040` | `0xB0805000` |
| `gold` | 金 | `0xFFFFD23F` | `0xB0806000` |
| `gold_l` | 浅金 | `0xFFFFE884` | `0xB06B6128` |
| `gold_d` | 暗金 | `0xFFD0A000` | `0xB0574300` |
| `yellow` | 黄 | `0xFFFFFF60` | `0xB0807000` |
| `white` | 白 | `0xFFFFFFFF` | `0xB0606060` |
| `silver` | 银 | `0xFFE0E0E0` | `0xB05E5E5E` |
| `gray` | 灰 | `0xFFA0A0A0` | `0xB0434343` |

---

# 9. 配置文件、保存、重置与迁移

## 9.1 配置放哪里

当前版本（v2.9.5 起）：

```text
<homepath>/mame_kbd/settings_default.ini
<homepath>/mame_kbd/settings_<rom>.ini
```

`homepath` 实测为 `.`，基准是 `mameui.exe` 所在目录。所以通常就是：

```text
MAMEUI64 Plus!\mameui\mame_kbd\
```

**不再放在插件目录**。插件目录放代码，升级/卸载/替换目录不会冲掉配置。

## 9.2 读取顺序

固定为：

1. 配置目录默认 `settings_default.ini`
2. 插件目录默认（只读兜底）
3. 配置目录本 ROM `settings_<rom>.ini`
4. 插件目录本 ROM（只读兜底）

本 ROM 必须最后读，才能盖过默认。

## 9.3 旧配置自动搬迁

`startplugin()` 开头调用 `migrate_legacy_configs()`，把插件目录下 `settings_*.ini` 搬到配置目录。

三条铁律：

1. **目标已存在不覆盖**：用户新保存的配置不能被旧文件反向覆盖；
2. **回读校验一致才删源**：写失败还删源 = 数据丢失；
3. **搬迁早于第一次 `load_settings()`**：否则这一轮读到的还是旧位置。

搬迁失败时，插件目录仍保留只读兜底，不至于全丢。

## 9.4 保存为默认

主页：`保存为默认（其他 ROM 通用）`，右侧显示 `写入 settings_default.ini`。

作用：把当前设置写成全局默认。已有自己 `settings_<rom>.ini` 的 ROM 不会被覆盖；要让它回落，用“重置本 ROM”。

## 9.5 重置本 ROM

主页：`重置本 ROM（回落到默认）`，右侧显示 `删除 settings_<rom>.ini`。

会同时尝试删除：

- 配置目录的本 ROM ini；
- 插件目录旧残留的本 ROM ini。

删完立即 `load_settings()` + `rebuild_bindings()`，界面当场变化。

## 9.6 INI 示例

```ini
show=1
layout=auto
label=zh
per_row=auto
show_start=1
highlight=1
seq_mode=first
line_px=24
bottom_px=28
col_px=6
bg_alpha=200
char_px=15
wrap=1
mod_style=short
joy_style=under
mouse_style=under
dir_style=letter
hl_phys=green
hl_mirror=blue
hl_both=gold
```

手写时值必须在白名单内，否则保留默认。

## 9.7 编码与换行

- 推荐 UTF-8 无 BOM；
- LF 换行；
- `plugin.json` 必须无 BOM；
- 配置 ini 也不建议 BOM；
- 不要用会加 BOM 的 PowerShell 5.1 `Set-Content -Encoding UTF8` 写 `plugin.json`。

---

# 10. 常见问题与故障排查

## 10.1 插件根本不加载

**症状**：MAMEUI 弹 `Unable to parse plugin definition file... Invalid value.`，插件列表没有，日志没有 `[mame_kbd]`。

**排查**：

1. 看 `plugin.json` 首字节是不是 `7B`；
2. 用 Python `json.loads` 解析；
3. 检查是否有 UTF-8 BOM / UTF-16 BOM / 结尾 NUL；
4. 检查目录名与 `name` 是否都是 `mame_kbd`；
5. 检查 `plugin.ini` 是否启用。

## 10.2 菜单里没有插件

- `plugin.ini` 条目是否 `mame_kbd 1`；
- 是否完全退出 MAMEUI（含托盘）后重启；
- 是否放错 `plugins` 目录；
- 是否 MAME 版本不兼容。

## 10.3 “开始”显示 `--`

- v2.8.9 已补虚拟 START；
- 确认版本 ≥ 2.8.9；
- 有些 ROM 的 START 只存在于 `ioport.types`，插件会补；
- 只给有真实字段的玩家补，避免空列。

## 10.4 3 人游戏仍画 4 列

- v2.8.8 已修；
- 确认 `layout=auto`；
- 确认版本 ≥ 2.8.8；
- 诊断页看 P4 是否“无输入”。

## 10.5 方向格式六档看起来一样

- v2.8.7 已修；
- 方向连接符只由 `dir_style` 决定；
- 确认版本 ≥ 2.8.7。

## 10.6 `J1_S`、`Joy1` 残字

- v2.8.1 已修；
- 语义单元整词保留；
- 确认版本 ≥ 2.8.1。

## 10.7 镜像不变蓝、同时不变金

- v2.9.1 已修；
- 确认版本 ≥ 2.9.1；
- 确认 `highlight` 开；
- 确认 `copilot2p` 真的在写入；
- 看日志 `[mame_kbd][press]` 的 `phys=`；
- 注意“同时”需要先出现镜像证据。

## 10.8 保存默认失败

- 配置目录不可写；
- `homepath` 异常；
- 检查 `<mameui>\mame_kbd\` 权限；
- 看 `last_msg` 是否“写入失败（目录不可写）”。

## 10.9 重置没生效

- 旧插件目录残留被读回；
- v2.9.5 会同时清两处；
- 确认版本；
- 手动检查配置目录与插件目录。

## 10.10 菜单光标跳行

- 菜单行数浮动；
- 本插件已用恒定占位 `last_msg or '—'`；
- 如果你改代码，不要按需增删行。

## 10.11 点 A 改了 B

- 菜单动作表下标错位；
- 必须 `actions[#list]`，不是 `#list + 1`；
- 官方 timecode 插件同此约定。

## 10.12 字号能调小吗

不能。MAME UI 文字是固定字模，`draw_text` 没有字号参数。只能缩写 + 换行 + 调布局。

## 10.12.1 版式为什么自己变了？一行几格到底谁决定的

如果你把「每行按键数」留在默认的 `自动`，那么**格数会随分辨率变、也会随键名长短变**，这是设计意图不是 bug。

`自动` 做的事：量出这一列的宽度 → 量出每个键名要完整显示需要多宽 → 算出这一行最多能放几格且都不被省略号截断。

- 屏幕更宽 → 格数更多（1080p 通常是 2 格，4K 约 5 格，更宽能到 16 格）；
- 同一个 ROM 换过按键绑定、键名变长 → 格数可能减少。

想要每次都一模一样，就把「每行按键数」设成固定数值（1～16）。

**注意方向**：格数越多，每格越窄。觉得挤要往**小**调，不是往大调。完整算法与实测数据见 [6.5 每行按键数](#65-每行按键数-per_row重点自动-到底怎么算)。

## 10.13 菜单能预览颜色吗

不能。菜单行不能单独上色。颜色页只显示色名和色值，实际效果看游戏画面下方。

## 10.14 真实按键高亮怎么确认

本机无法注入按键时，只能用户手动按键确认。渲染路径已通过强制点亮测试验证。

---

# 11. 高级原理：数据模型与绘制机制

## 11.1 两套输入数据

- `ioport.ports`：当前 ROM 实际声明的端口与字段，因游戏而异；
- `ioport.types`：MAME 通用输入分配表，`P1_SELECT`、`START1` 等槽位永远存在。

很多 ROM 的 `ports` 没有 START 字段，所以插件要从 `types` 补虚拟项。

## 11.2 token 解析

`parse_token()` 识别：

```text
P1_JOYSTICK_UP -> 玩家0, DIR, UP
P1_BUTTON3     -> 玩家0, BUTTON, BUTTON3
START1         -> 玩家0, START, START
SELECT2        -> 玩家1, SELECT, SELECT
P1_SELECT      -> 玩家0, SELECT, SELECT
```

玩家号从 token 尾部数字解析，不信 `field.player`，因为 `START1/COIN1` 的 `field.player` 恒为 0。

## 11.3 按下判定

- 最终值：`port:read()` 与 `mask`、`defvalue` 比较；
- 物理值：`ioport:type_pressed(ty, press_player)`；
- 镜像：最终值真、物理值假；
- 同时：先镜像后物理，逐格 `mirror_flag`。

## 11.4 绘制

- `register_frame_done(draw_frame)`；
- 往 `manager.machine.render.ui_container` 画；
- 坐标归一化 0..1；
- `draw_text(x, y, text, fg, bg)`；
- `draw_box` 画背景与边框；
- 每行先算 `need` 行数，再按行基线画，避免同行被画成多行。

## 11.5 菜单

- `emu.register_menu(callback, populate, title)`；
- `populate` 返回 `list, selection, menu_flags`；
- `menu_flags='lrrepeat'` 支持长按连发；
- 没有真子菜单，用 `menu_page` 变量按页构建；
- `actions[#list]` 对齐；
- 稀疏表不能用 `#actions == #list` 自检。

## 11.6 生命周期

```text
startplugin()
  → migrate_legacy_configs()
  → load_settings()
  → add_machine_frame_notifier(process_frame)
  → register_frame_done(draw_frame)
  → add_machine_reset_notifier(on_reset)
  → add_machine_stop_notifier(on_stop)
  → register_menu(...)
  → 启动自检 menu_items()
```

`frame_subscription` 等必须存文件级 local，否则被 GC，回调不触发。

---

# 12. 开发者指南：API、代码结构、测试与探针

## 12.1 代码结构（逻辑块）

| 区块 | 作用 |
|---|---|
| 位运算 `band` | Lua 5.1 兼容 |
| `parse_token` | token → 玩家/类别/语义 |
| `default_settings` | 默认设置 |
| `HL_COLORS` | 30 档颜色 |
| `config_dir/ensure_dir/settings_path` | 配置路径 |
| `serialize/apply_kv/load_settings` | INI 读写 |
| `migrate_legacy_configs` | 旧配置搬迁 |
| `ABBR/MOD_ABBR/JOY_MAP/DIR_STYLE_CHARS` | 缩写与档位 |
| `joy_short/mouse_short/seq_dual/seq_text` | 绑定文本 |
| `field_pressed/field_physical_pressed/press_state` | 三态判定 |
| `rebuild_bindings` | 采集字段、虚拟补位、整理数组 |
| `draw_frame` | 绘制 |
| `menu_items/menu_callback` | 六页菜单 |
| `startplugin` | 生命周期 |

## 12.2 关键坑（开发者必读）

1. `plugin.json` 不能带 BOM；
2. `actions[#list]` 不是 `#list+1`；
3. 稀疏表不能用 `#`；
4. `local` 不是 hoisted，定义早于使用；
5. `frame_subscription` 必须持有；
6. `set_value(1)` 有 1 帧延迟，必须每帧写；
7. `type_pressed` 读物理，`port:read()` 读最终；
8. 极性判据用 `defvalue` 同掩码比较；
9. 虚拟 START 的 `vpl` 传 0；
10. 只给有真实字段的玩家补虚拟项；
11. 方向连接符只听 `dir_style`；
12. 菜单行不能上色；
13. 菜单没有文本输入；
14. mock 语义错了测试会撒谎；
15. 三处哈希一致 ≠ 文件正确。

## 12.3 测试脚本

记录中使用的脚本：

| 脚本 | 作用 |
|---|---|
| `_check_lua.py` | 编码、语法、括号、五页/六页菜单结构、档位语义 |
| `_run_lua.py` | lupa 真跑插件生命周期、菜单、绘制 |
| `_verify_cols.py` | 4/3/2/1 人列数、无 START 字段边界 |
| `_diag8.py` | 方向六档字形、无残字、两两不同 |
| `_verify_highlight.py` | 物理绿/镜像蓝/同时金/防误判 |
| `_verify_colors.py` | 颜色持久化闭环 |
| `_verify_migrate.py` | 旧配置搬迁五场景 |

## 12.4 lupa 真跑

```python
from lupa import LuaRuntime
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(MOCK_PRELUDE)
exports = lua.eval('LOAD_PLUGIN')(open(INIT, encoding='utf-8').read())
exports['set_folder']('X:/plugins/mame_kbd')
exports['startplugin']()
```

mock 必须按真实 API 语义造，不能只造“够用的最小集”。

## 12.5 真机探针

拿不准 API 语义时，写临时探针插件进真机实测：

1. `scaffold/probe_plugin/`；
2. 部署到 `plugins\mame_kbd_probe\`；
3. `plugin.ini` 追加启用；
4. `Start-Process` 加 `-log -verbose`；
5. 日志 `Select-String '\[probe\]'`；
6. 验证完立刻删目录并摘掉 `plugin.ini` 行。

## 12.6 UNC 路径取日志

```powershell
net use Z: "\\Ds1821\hd" /persistent:no
$wd = 'Z:\ROM 街机\MAMEUI64 Plus!\mameui'
$t  = 'G:\Python_Code\mame_kbd\scaffold\_runlog'
$p = Start-Process -FilePath "$wd\mameui.exe" `
  -ArgumentList @($rom,'-log','-verbose','-window','-seconds_to_run','6',
                 '-noreadconfig','-nowriteconfig',
                 '-nvram_directory',"$t\nvram", '-cfg_directory',"$t\cfg",
                 '-snapshot_directory',"$t\snap", '-state_directory',"$t\sta") `
  -WorkingDirectory $wd `
  -RedirectStandardOutput "$t\out.txt" `
  -RedirectStandardError  "$t\err.txt" `
  -PassThru -NoNewWindow
$p | Wait-Process -Timeout 90
```

`-WorkingDirectory` 必须是 exe 所在目录。

---

# 13. 部署/运维/打包指南

## 13.1 发布前检查清单

- [ ] `plugin.json` 首字节 `7B`，无 BOM，`json.loads` 能解析；
- [ ] `init.lua` 无 BOM、全 LF、能 `load()`；
- [ ] 版本号三处一致：`init.lua`、`plugin.json`、迭代记录；
- [ ] 目录名 = `name` = `mame_kbd`；
- [ ] `plugin.ini` 条目正确；
- [ ] 配置目录不在插件目录；
- [ ] 旧配置迁移有专项用例；
- [ ] 新增设置项在 `default_settings` / `serialize` / `apply_kv` 三处都加；
- [ ] 新增档位有唯一性断言；
- [ ] 菜单行数不浮动；
- [ ] 临时诊断代码已还原；
- [ ] 归档三件：`init.lua` + `plugin.json` + 迭代记录；
- [ ] 本地/部署/归档哈希一致。

## 13.2 哈希与编码

哈希一致只证明副本同步，不证明内容合法。必须单独检查：

- UTF-8 BOM / UTF-16 BOM；
- 结尾 NUL；
- JSON 能解析；
- Lua 能加载；
- 首字节。

## 13.3 版本号三处

- `init.lua` 的 `version = '2.9.8'`；
- `plugin.json` 的 `plugin.plugin.version`；
- 迭代记录版本段落。

不一致会让“用户看到的版本”和“代码里的版本”对不上。

---

# 14. 测试与质量保证指南

## 14.1 回归矩阵

| 维度 | 用例 |
|---|---|
| 玩家数 | 4/3/2/1 人 |
| 无 START 字段 | 3stooges/tmnt |
| 有真实 START | xmen |
| 方向格式 | 6 档 × 7 手柄格式 |
| 手柄格式 | 7 档按钮 1～8 |
| 鼠标/光枪 | 5 档 |
| 颜色 | 30 档持久化 |
| 高亮 | 物理/镜像/同时/防误判/松开重按 |
| 迁移 | A 全新/B 升级/C 目标存在/D 混合/E 顺序 |
| 菜单 | 六页、返回、自检、长按连发 |

## 14.2 判据设计教训

- 只断言“某档输出什么”不够，还要断言“不同档必须彼此不同”；
- 空集上“两两不同”恒真，必须加“抓到空即失败”守卫；
- mock 与真实 API 差异会让测试假通过/假失败；
- 校验脚本本身也会有 bug，先判断“代码错”还是“脚本错”。

---

# 15. 版本更新简介（v2.0.0 → v2.9.8）

> 下面是“每次版本更新简介”，给普通用户看一句话，给维护者看关键点。详细记录见《软件升级迭代记录.md》。

| 版本 | 记录日期 | 一句话简介 | 关键点 |
|---|---|---|---|
| v2.0.0 | 20261108-v1 | 首发：四列显示 P1～P4 按键对照 | 定名 `mame_kbd`、方向/选择/开始/按钮、按下高亮、按 ROM 配置 |
| v2.1.0 | 20261108-v2 | 修 P4 横向溢出，加多词缩写 | `char_px` 标定 15、`shrink_words`、选择/开始标签优先 |
| v2.3.0 | 20261108-v3 | 修 P2～P4 开始不变色，补虚拟 SELECT，长键名换行 | `press_player`、`P1_SELECT` 虚拟项、`wrap`、行基线 |
| v2.4.0 | 20261108-v4 | 同时显示键盘与手柄两个绑定 | `seq_dual`、`joy_short`、方向行两行排版、全局方向高度 |
| v2.4.1 | 20261108-v5 | 修菜单下标错位 | `actions[#list]`、菜单自检 |
| v2.5.0 | 20261108-v6 | KBN 全量改名 KBD + 目录重整 | 菜单名、源码目录、脚手架、归档 |
| v2.6.0 | 20261108-v7 | 绑定显示增加“优先次序” | 手柄>键盘>鼠标、`priority`、鼠标/光枪缩写、修轴/HAT 捕获 bug |
| v2.7.0 | 20261108-v8 | 左右修饰键与手柄/鼠标统一下划线缩写 | `LShft/RShft/LCtl/RCtl`、`J1_B1`、`M1_B1` |
| v2.8.0 | 20261108-v9 | 菜单改多页 + 显示格式自定义 | 五页、`mod_style/joy_style/mouse_style`、保存默认/重置本 ROM、修连字符 bug |
| v2.8.1 | 20261109-v10 | 修 `J1_Sta` 被长度规则截断 | 语义单元整词保留、lupa 真跑、残字清零 |
| v2.8.2 | 20261109-v11 | 修 `plugin.json` BOM 导致插件不加载 | 去 BOM、首字节检查、编码校验第一项 |
| v2.8.3 | 20261109-v12 | 手柄格式新增字母式 ABXY 两档 | `J1A` / `J1_A`、按钮 5～8 映射 L1/R1/L2/R2 |
| v2.8.4 | 20261109-v13 | 方向键缩写改单字母 U/D/L/R | `Dn→D`、`Lt→L`、`Rt→R` |
| v2.8.5 | 20261109-v14 | 新增“手柄方向格式”四档 | letter/word/arrow/tri |
| v2.8.6 | 20261109-v15 | 方向格式补两个无连接符档 | `arrown` / `trin` |
| v2.8.7 | 20261109-v16 | 修方向格式六档看起来一样 | 连接符只听 `dir_style` |
| v2.8.8 | 20261109-v17 | 修“仅实际玩家”仍画空列 | 只给有真实字段玩家补虚拟槽位、末尾兜底 |
| v2.8.9 | 20261109-v18 | 补虚拟“开始”，修部分游戏 `开始:--` | `fill_virtual`、START 的 vpl=0、真实日志 |
| v2.9.0 | 20261109-v19 | 高亮区分物理/镜像/同时三色 | 初版三态，但 API 假设错 |
| v2.9.1 | 20261109-v20 | 修镜像蓝/同时金不出现 | `type_pressed` 物理、`port:read()` 最终、逐格时序标记 |
| v2.9.2 | 20261109-v21 | 新增“按键颜色”页，三色可自定义 | 10 档颜色、`hl_phys/hl_mirror/hl_both` |
| v2.9.3 | 20261109-v22 | 颜色 10→30 档，左右键可长按连发 | `lrrepeat`、色系分组 |
| v2.9.4 | 20261110-v23 | 保存默认/重置本 ROM/上次操作提升到主页 | 插件级操作放主页、右侧显示文件名 |
| v2.9.5 | 20261110-v24 | 配置改存 `mame_kbd/`，旧配置自动搬迁 | `config_dir`、`ensure_dir`、迁移三铁律 |
| v2.9.6 | 20261110-v25 | 主页两项右侧去掉目录前缀 | 只写文件名、诊断页显示配置目录 |
| v2.9.7 | 20261111-v26 | 每行按键数扩到 自动/1~6，「自动」改为按宽度自适应 | `PER_ROW_MAX`、`cell_fits_one_line`、`per_row_for(btns, col_w_px, px_per_char)` |
| v2.9.8 | 20261111-v27 | 每行按键数再扩到 自动/1~16，极窄档不再画空白格 | `PER_ROW_MAX=16`；`split_cell` 退化档改画按键编号 |
| v2.9.8（文档） | 20261111-v29 | 补「自动」算法详解 + 版式为什么自己变 | 新增 6.5 全节、FAQ 10.12.1；代码零改动 |

> 记录中从 v2.1.0 直接到 v2.3.0，未单列 v2.2.0 详情。

---

# 16. FAQ：普通用户 30 问

1. **插件装哪里？**  
   `mameui\plugins\mame_kbd\`，放 `init.lua` 和 `plugin.json`。

2. **怎么启用？**  
   `ini\plugin.ini` 加 `mame_kbd 1`，完全重启 MAMEUI。

3. **菜单在哪？**  
   `Tab → 插件选项/插件菜单 → KBD 按键对照表`。

4. **为什么看不到插件？**  
   先查 `plugin.json` BOM，再查 `plugin.ini`。

5. **为什么开始显示 `--`？**  
   升到 v2.8.9+；有些 ROM 的 START 只在 `types` 里。

6. **为什么 3 人游戏画 4 列？**  
   升到 v2.8.8+，并用 `layout=auto`。

7. **方向六档为什么一样？**  
   升到 v2.8.7+。

8. **`J1_S` 是什么？**  
   旧版截断 bug，升到 v2.8.1+。

9. **镜像为什么不变蓝？**  
   升到 v2.9.1+，确认 `highlight` 开。

10. **同时为什么不变金？**  
    需要先出现镜像证据，再物理按下。

11. **颜色怎么改？**  
    菜单 → 按键颜色，左右切 30 档。

12. **菜单里为什么没有色块？**  
    菜单行不能单独上色，看游戏画面。

13. **字号能调小吗？**  
    不能，MAME `draw_text` 无字号参数。

14. **配置在哪？**  
    `<mameui>\mame_kbd\settings_*.ini`。

15. **旧配置会丢吗？**  
    v2.9.5+ 自动搬迁，目标存在不覆盖。

16. **保存默认和重置本 ROM 区别？**  
    保存默认写全局默认；重置删本 ROM 专属配置。

17. **为什么保存默认失败？**  
    目录不可写，查 `mame_kbd` 目录权限。

18. **重置没生效？**  
    旧插件目录残留，v2.9.5 会清两处。

19. **菜单光标跳行？**  
    旧版行数浮动，新版已用恒定占位。

20. **点 A 改了 B？**  
    菜单下标错位，旧版 bug，升到 v2.4.1+。

21. **为什么键名被截成 `..`？**  
    格子太窄。把「每行按键数」调**小**（格数越多格子越窄，调大反而更糟），或设回 `auto` 让它自动降格；也可调小 `char_px`（字符宽估计，越小越省宽）、调大窗口分辨率。

22. **方向格被截断？**  
    窄窗正常，可调 `char_px`、窗口、行距。

23. **手柄和键盘都显示吗？**  
    `seq_mode=first` 默认都显示；`priority` 只显示最高优先级。

24. **鼠标/光枪能显示吗？**  
    能，`mouse_style` 5 档。

25. **支持几人？**  
    P1～P4。

26. **支持 MAME 哪个版本？**  
    记录验证 MAMEUI 0.289；其他版本可能菜单名称不同。

27. **能自动进游戏吗？**  
    不能，需要你进游戏按 Tab。

28. **能注入按键测试吗？**  
    本机 `SendInput` 被拒，真实高亮需手动按键确认。

29. **文档能转载吗？**  
    本文档文字未经书面许可不得转载或商用；代码按 MIT。

30. **怎么报问题？**  
    GitHub Issues：https://github.com/duma520/mame_kbd/issues

---

# 17. 附录

## 17.1 菜单速查

```text
主页
├─ ▶ 显示设置
├─ ▶ 显示格式
├─ ▶ 外观微调
├─ ▶ 按键颜色
├─ ▶ 诊断信息
├─ 保存为默认（其他 ROM 通用）   写入 settings_default.ini
├─ 重置本 ROM（回落到默认）       删除 settings_<rom>.ini
└─ ↳ 上次操作
```

## 17.2 文件清单

| 文件 | 作用 |
|---|---|
| `plugins/mame_kbd/init.lua` | 插件主代码 |
| `plugins/mame_kbd/plugin.json` | 插件定义，无 BOM |
| `ini/plugin.ini` | 启用插件 |
| `<mameui>/mame_kbd/settings_default.ini` | 全局默认配置 |
| `<mameui>/mame_kbd/settings_<rom>.ini` | 本 ROM 配置 |
| `scaffold/*.py` | 验证脚本（开发用） |
| `version/<日期>-vN/` | 归档三件 |

## 17.3 术语表

| 术语 | 含义 |
|---|---|
| ROM | 游戏名/系统名，如 `xmen` |
| ioport | MAME 输入端口 |
| token | 输入标识，如 `P1_BUTTON1` |
| `START1` | 1P 开始，type player 恒 0 |
| `P1_SELECT` | 通用选择槽位 |
| 虚拟补位 | 从 `ioport.types` 补没有字段的槽位 |
| 镜像 | 别的插件 `set_value` 写入 |
| `lrrepeat` | 菜单级长按连发 |
| BOM | 字节顺序标记，MAME JSON 不接受 |
| LF | 换行 `0x0A` |
| `port:read()` | 读最终值 |
| `type_pressed` | 读物理状态 |

## 17.4 MIT 许可证摘要

插件源代码按 MIT 许可证授权。MIT 允许使用、复制、修改、合并、发布、分发、再许可和/或销售软件副本，条件是保留版权声明和许可声明。软件按“原样”提供，不附带任何担保。

本文档文字部分的版权声明为：© 永久 杜玛 保留所有权利；未经书面许可不得转载或用于商业用途。该限制不改变源代码 MIT 许可证授予你的权利。

---

# 18. 许可证与支持说明

- **作者**：杜玛
- **版权**：永久
- **日期**：永久
- **开源许可证**：MIT（插件源代码）
- **GitHub**：https://github.com/duma520
- **项目地址**：https://github.com/duma520/mame_kbd
- **问题报告**：GitHub Issues
- **私人邮箱支持**：不提供
- **技术支持渠道**：公开渠道，便于其他用户受益
- **开发时间**：2026-11-8

**版权声明**  
© 永久 杜玛 保留所有权利。  
本文档内容未经书面许可不得转载或用于商业用途。  
插件源代码按 MIT 许可证授权；源码文件头如保留 BSD-3-Clause 等其它声明，以仓库根 `LICENSE` 与源码文件头为准。

---

**文档结束**
