# AI Quest Demo

> 一个「世界、剧情、人物、美术全部由 AI 生成」的 2D 俯视开放世界实验，目标是做成**拥有无限个结局**的游戏。
>
> **当前状态：做了三天，连 0.1 都还不到。** 这是一个能跑、能玩、系统骨架基本齐全，但内容层很薄、大量地方还没做完的**早期原型**，不是可以拿来正常玩的游戏。请把它当作一个「技术可行性验证」来看。

---

## 一、这个项目的想法

- **世界**：无限大地图，走到哪生成到哪。
- **剧情**：主线、支线全部由 AI 生成，而不是预先写死的文本。
- **人物**：NPC 的名字、性格、身份、台词、关系、记忆都由 AI 现生成。
- **美术**：房屋、功能建筑、树、人物立绘、走路帧、攻击帧、奖励图标全部由 AI 生图。
- **结局**：不是 4 选 1，而是**无限个结局** —— 终极目标是让玩家自己写下想要的结局，AI 再去生成「达成这个结局所需要的全部内容」（章节、要见的人、要去的地方、要做的条件）。

**整个项目（代码、美术、文案）都是用 AI 做的，历时三天。**

目前真正做到的，是上面这些里面的一部分；**最后那条「玩家自撰结局」是整份代码里最没底、也最想做的部分**（详见第三节）。

---

## 二、现在能玩到的（已经实现）

### 世界
- 无限程序化大地图：Voronoi 区域划分 + 空间哈希 + 世界种子，同一个种子复原同一张图（`scripts/region_generator.gd`、`scripts/world_data.gd`）。
- 地形层：平滑值噪声海拔、溪流、海洋、沙滩、高山（`scripts/region_generator.gd`）。
- 流式加载：MC 式「走到哪生成哪」，含预生成半径（`scripts/location_generator.gd`）。
- **9 个常规文化圈 + 1 个通天福地**，各有自己的配色、屋顶样式、房屋形状、语言（`scripts/culture_data.gd`）。
- 地表渲染：区域色块、山体、道路、Y 排序遮挡、房屋/设施/宝箱/敌人（`scripts/world_map.gd`）。

### 人物
- NPC 生成：名字、身份、性格、环形站位、重名防护（`scripts/npc_generator.gd`）。
- NPC 记忆：对玩家的印象 + 最多 5 条关键记忆（`scripts/npc_memory.gd`）。
- NPC 好感度：聊天 +1、完成任务 +10（`scripts/quest_manager.gd`）。
- NPC 关系：8 种关系、每人上限 4 条、双向对称写入（`scripts/npc_relations.gd`）。
- 对话：AI 生成，prompt 里会注入 NPC 性格、玩家画像、记忆、关系、世界摘要、进行中任务、结局方向（`scripts/dialogue_generator.gd`）。
- 结婚 / 伴侣状态（`scripts/player_profile.gd`、`scripts/dialogue_ui.gd`）。

### 玩法
- 武器系统：挥击、暴击、吸血、锻造、材料（`scripts/weapon_data.gd`、`scripts/player.gd`）。
- 敌人：野生敌人 + 据点守兵（`scripts/enemy.gd`、`scripts/enemy_data.gd`）。
- 9 种功能建筑（锻造台 / 商铺 / 客栈 / 藏书阁 / 拍卖行 / 告示板 / 药铺 / 马厩 / 赌场），各有自己的交互界面（`scripts/facility.gd`、`scripts/facility_ui.gd`）。
- 室内系统：进屋后按房屋规格现搭房间，支持两层与楼梯（`scripts/interior.gd`、`scripts/interior_manager.gd`）。
- 语言系统：每个文化圈一种语言，学 3 次掌握，或用通译符。
- 任务系统：接取、追踪、导航箭头、完成存档（`scripts/quest_manager.gd`）。
- 主线：八幕弧结构 + 结局判定（`scripts/story_director.gd`）。
- 存读档：JSON 存档，20 秒自动存档 + 完成任务即存 + 关窗存档（`scripts/save_system.gd`）。

### AI 美术（已预生成，随仓库一起提交）
- 房屋：9 文化圈 × 3 变体 × 2 档
- 功能建筑：9 文化圈 × 9 种 × 2 档 = **162 张**
- 树：9 文化圈 × 3 种 = **27 张**
- 人物立绘、走路序列帧（一次出 12 格）、攻击序列帧、奖励图标
- 生成器：`scripts/portrait_generator.gd`、`walk_sheet_generator.gd`、`attack_sheet_generator.gd`、`building_generator.gd`、`reward_icon_generator.gd`
- 支持硅基流动 / 火山方舟 / 阿里云百炼三家接口（`scripts/llm_config.gd`）

### 工程
- **mock / llm 双模式**：所有生成器都支持「离线模板」和「真调模型」两条路，没有 API Key 也能完整跑起来（只是内容变糙）。
- **29 个离线 headless 探针**（`tools/`），不联网就能验证各系统没坏。

---

## 三、还没做 / 没做完的（重要，请先看这里）

### 1. 最关键的：「玩家自撰结局」这条线，还没真正试过
这是整个项目的**核心卖点**，也是**最不成熟**的一块。

- 代码里确实已经搭出了一条通路：玩家写下结局目标 → `story_director` 的 `goal_kind = custom` → 让 AI 生成达成它所需的八幕弧、终局落点与相关人物 → 按真实游玩数据推进进度（`scripts/story_director.gd:900`、`:350`、`:1248`）。
- 离线探针 `tools/story_goal_probe.gd` 能跑通（但走的是 **mock 兜底**，没有真调模型）。
- **但是：从来没有接过真实大模型，对着自己写的结局目标真正玩一遍。** 生成出来的章节到底顺不顺、终局落点会不会落到一个合理的地方、人物会不会前后矛盾——**全部没有验证过**。
- 所以「无限个结局」目前是一个**有骨架、没验证**的目标，不是已经实现的功能。

### 2. 结局远不到「无限」
- 结局类型是一个**封闭枚举**（`warden / wanderer / bridge / hermit / custom`，`scripts/story_director.gd:60`），预设结局只有 4 个。
- 主线**固定 8 章**（`MAX_CHAPTERS := 8`，`scripts/story_director.gd:29`），不是按故事需要动态伸缩。
- 终局链**固定 3 站**、距离写死 900 / 1800 / 3000 米（`scripts/story_director.gd:46`）。
- 这些都是硬编码常量，不是数据驱动的。

### 3. 支线任务非常单薄
- mock 模式只产出**一种形状**的任务：「去某地 → 回来复命」，据点地点有 50% 概率变成战斗任务（`scripts/quest_manager.gd:510`）。
- 标题模板 3 条、起因文案 4 条（`scripts/quest_manager.gd:526`）。**LLM 模式靠模型补内容，mock 模式重复感很强。**
- 任务之间**没有因果链**，一个任务不会影响另一个任务。
- 任务 schema 里预留了 `type: "main"`，但**代码从来没请求过主线任务**（`scripts/quest_manager.gd:348`）——主线完全走 `story_director` 另一套逻辑。

### 4. 「AI 生成世界」有一半是程序化，不是 AI
- 地形、河流、海洋、区域划分是**噪声 + Voronoi 算法**算出来的，不是 AI 生成的。
- AI 负责的是：地点名字、地点描述与布置、NPC、对话、剧情、美术素材。
- 如果你期待「连地形都是 AI 画的」，那还没做到。

### 5. 其他已知的坑
- **区域缓存不淘汰**（`scripts/region_generator.gd:76`）：一直往一个方向跑，内存会持续涨。
- **伴侣名不副实**：UI 上说伴侣「一直跟着你」，但**没有任何跟随 / 同伴代码**（`scripts/npc.gd` 里没有相关逻辑）。
- **攻击序列帧生成器配置不能热更新**：它没被纳入 `IMAGE_TARGETS`（`scripts/llm_config.gd:23`），运行时改生图设置它不跟着变。
- **没开生图时观感会明显退化**：房屋 / 树 / 道具会退回代码画的色块占位（`scripts/world_map.gd:932`）。
- **完全没有音频**：没有 BGM、没有音效。
- **没有 i18n**：所有 UI 和代码注释都是中文。
- **数值与平衡完全没调**：金币、伤害、血量都是随手写的。
- **只在 Windows 上测过**；渲染器用的是 `gl_compatibility`。
- **没有测试框架**，只有 29 个手写的离线探针。

### 6. 没有做的（明确不在这个版本里）
- 多存档槽 / 云存档
- 世界事件系统（`WorldState.flags` 是个占位，`scripts/world_state.gd:17`）
- 成就 / 图鉴收集
- 手柄支持、按键自定义
- 模组 / 数据驱动的剧情编辑

---

## 四、怎么跑起来

**环境**：Godot 4.7.x（本项目用 4.7.2 开发，渲染器 `GL Compatibility`），Windows。

1. 用 Godot 打开 `project.godot`，或者直接命令行跑：

```
godot --path . 
```

2. 配置 AI（可选）：

```
把 llm_config.cfg.example 复制成 llm_config.cfg
```

- **只想先看效果**：`[llm] mode="mock"`、`[image] mode="off"`。不联网、不花钱，用离线模板 + 程序化占位素材。
- **想用真 AI**：把 `[llm] mode` 改成 `"llm"` 并填上文本模型的 Key；想现场生图就把 `[image] mode` 改成 `"api"` 并填生图 Key。
- `llm_config.cfg` 已在 `.gitignore` 里，**不会被提交**。

> 仓库里已经带了一份预生成好的美术（`generated/`，约 80 MB），所以就算不配 Key、不开生图，画面也是 AI 画的那些素材。想重新生成可以用 `tools/gen_buildings.gd`、`tools/gen_trees.gd`、`tools/gen_npcs.gd` 等（**这些会真的调用接口花钱**）。

3. 离线自检（不联网、不花钱）：

```
godot --headless --path . --script res://tools/playthrough_probe.gd
```

---

## 五、目录结构

```
scripts/          游戏逻辑（26 个 autoload + 各系统脚本）
scenes/           场景（主场景、玩家、NPC、各类 UI）
tools/            29 个离线探针 + 4 个批量生图工具
generated/        预生成好的 AI 素材（建筑 / 树 / 立绘 / 奖励图标）
llm_config.cfg.example   配置模板（含 Key 的 llm_config.cfg 不提交）
project.godot     Godot 工程配置
```

---

## 六、接下来想做的

1. **把「玩家自撰结局」真正跑通**：接真实模型，从写下结局到走到结局走一遍，看它到底能不能自圆其说。
2. 让章节数和终局链**由 AI 按故事需要决定**，而不是写死 8 章 3 站。
3. 支线任务**多加几种形状**，并且让任务之间产生因果。
4. 区域缓存做淘汰，解决长时间游走的内存增长。
5. 把地形也纳入 AI 生成（现在是纯算法）。
6. 音频。

---

## 七、说明

- 这是一个**三天**做出来的原型，很多地方是「先让它能跑」的写法，代码质量和架构都不能细看。
- 项目目前**没有指定开源许可证**，转载 / 使用前请先联系作者。
- 仓库里的地图、人物、剧情均为 AI 生成，如有雷同纯属巧合。