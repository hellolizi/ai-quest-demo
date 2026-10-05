extends Node
## 主线导演（Autoload 名字：StoryDirector）
##
## 负责把「无限剧情、无限结局」落到可玩的东西上：一章一章地往前推，
## 每章给玩家一个目标；达成后进入下一章；走完一章的长度就判定一个结局，
## 结局之后可以直接开新一轮（cycle），于是故事能一直写下去。
##
## 关键设计（沿用任务/地点/NPC 生成的老规矩）：
##   1. 能不能推进，由**代码用真实数据判定**（办成的事 / 走出新地方 / 攒下的情谊），
##      不交给 AI，避免 AI 说「你过关了」但其实什么也没发生；
##   2. AI 只负责「编内容」——这一章叫什么、开头发生什么、要去做什么；
##   3. 结局的**类型**：玩家在开局定过结局就用他定的（预设或自定义），
##      没定才由代码按真实数据选（封闭枚举）；AI 只写这个结局的正文；
##   4. 判定用的是累计值，只增不减，所以章节可以无限往上加，不会卡死。

signal chapter_started(chapter: Dictionary)
signal chapter_completed(chapter: Dictionary)
signal ending_reached(ending: Dictionary)
## 状态有任何变化都发一次，界面收到就重画
signal story_changed
## 开局「替玩家把这一程预备好」的进度：加载动画靠它一步步报进度
##   step 0 编主线 / 1 铺终局落点 / 2 写第一章 / 3 收尾
signal prepare_progress(step: int, text: String)
## 预备结束：ok=true 表示可以进主场景了；false 表示这次不用预备（如非自定义结局）
signal prepare_finished(ok: bool)

const MAX_RETRY := 1
## 一轮故事有几章；走完这些章就进结局
const MAX_CHAPTERS := 8
## ---- 节奏：把一轮大约撑到 2~3 小时 ----
## 每章至少办成这么多件支线（累计）。一件支线 = 接任务 + 走过去 + 做完 + 复命，
## 按玩家 240px/s 的脚程、支线落在 500 米内，一件大约 3 分钟上下。
const QUESTS_PER_CHAPTER := 2
## 每章至少走出这么多新地方（走出去探索，别一直待在村里）。
const LOCATIONS_PER_CHAPTER := 1
## 每章至少要攒下的情谊（好感总和）。一件支线给 +10，正好对上每章两件。
const AFFINITY_PER_CHAPTER := 20
## 最多记住看过的几个结局（存档用）
const ENDINGS_KEEP := 12
## 最多记住走过的几章回顾（存档用）
const CHAPTER_LOG_KEEP := 24

## ---- 终局链（借 MC「末影龙」的骨架：固定终极目标 + 层层推进 + 终局高潮）----
## 一条预设主线走到最后几章时，不再各写各的，而是钉死在同一条终局链上：
## 最后 FINAL_STEPS 章，每章走一站，每站都要真人去到一个真实存在的地方、见到一个真实存在的人。
const FINAL_STEPS := 3
## 三站距出生点的大致距离（米）——一站比一站远，越走越像「最后一程」
const FINAL_DISTANCES_M := [900.0, 1800.0, 3000.0]
## 距离的浮动范围（米）：在这一带里挑一块能落地的地
const FINAL_DIST_BAND_M := 350.0
## 米 → 像素
const PX_PER_METER := 20.0
## 挑远处格子用的确定性盐值（同一个世界永远挑到同一批地方）
const SALT_FINAL_BASE := 771923
## 一站等「人」就位最多等多久（秒）；等不到就把地点先记下，继续往下走，不卡死主线
const COMMIT_TIMEOUT := 12.0

## 结局类型 → 中文叫法（封闭枚举，由代码选，不让 AI 现编）
## "custom" 是玩家自己写的结局，不参与代码的数据判定。
const ENDING_NAMES := {
	"warden": "守望",
	"wanderer": "远行",
	"bridge": "架桥",
	"hermit": "独行",
	"custom": "心愿",
}

## 开局可选的预设结局（id 与 ENDING_NAMES 对齐；玩家不自定义时用这几条）
const PRESET_GOALS := [
	{"id": "warden", "name": "守望乡里", "desc": "留下来，守住这里的人和事，最后成为村子离不开的人。"},
	{"id": "wanderer", "name": "走向远方", "desc": "不停下脚步，一路往外走，最后把名字留在没人知道的地方。"},
	{"id": "bridge", "name": "架起桥梁", "desc": "把村子和外面的世界连起来，最后让两边都因你而热闹。"},
	{"id": "hermit", "name": "独自远游", "desc": "把该做的事都做完，却不与谁深交，最后一个人走自己的路。"},
]

## 主线弧：一条完整的「起—承—转—合」八幕。
## 有预设结局的玩家，整条主线就按对应那条弧走；自己写结局或没定结局的，走通用弧。
## 每一幕的字段：
##   act   —— 这一幕属于起 / 承 / 转 / 合哪一段
##   name  —— 幕名，2-6 字，有画面感
##   intro —— 这一幕开头发生了什么（离线兜底直接用；联网时喂给模型做骨架）
##   goal  —— 玩家这一幕要做成的事（离线兜底直接用）
##   beat  —— 这一幕的「戏眼」，一句话说清这一幕在整条线里的作用，喂给模型对齐，也让支线知道该往哪边铺垫
## 八幕之间前有铺垫、后有回收：第 1 幕抛出的旧事，会在后面几幕里一件件回响到第 8 幕。
const STORY_ARCS := {
	"warden": {
		"title": "归处",
		"acts": [
			{"act": "起", "name": "生分的门槛", "intro": "你刚到青石村，村口的人只当你是路过歇脚的。铺子里的老人问你歇几天，话里头没有留你的意思。", "goal": "在村里认认路，也让人先认认你。", "beat": "村里人还把你当外人，愿意搭话的人不多。"},
			{"act": "承", "name": "熄了的老炉", "intro": "村口那口老炉子熄了有些年头了。老人说，从前谁家有事都往炉边凑，如今谁也不记得上一回生火是什么时候。", "goal": "找找看，这口炉子当年是做什么用的。", "beat": "村里有些老规矩、老地方，正一点点被人忘掉。"},
			{"act": "承", "name": "断掉的一截桥", "intro": "村外那座小桥的桥板朽了，来往的脚夫宁可绕远路走，村里的东西也就慢慢卖不出去。可也有人说，绕远是好的——后山那边近来有伙山贼出没，近路，谁也不敢走。", "goal": "把桥这一头的事打听清楚，看看能不能接上。", "beat": "村子跟外头的路不太通，日子过得不声不响地闷；近路不敢走，是因为后山起了山贼。"},
			{"act": "承", "name": "各家的琐事", "intro": "东家丢了鸡，西家屋顶漏雨，祠堂的灯也灭了。这些小事从前都是各家自己扛，如今却都来找你。说着说着，总有人压低声音提一句后山的山贼——像是都等着你拿个主意。", "goal": "挨家挨户，把答应下的事办妥。", "beat": "村里人开始把难处交给你，把你当成能指望的人；而后山的山贼，正慢慢逼到眼皮底下。"},
			{"act": "转", "name": "山雨要来", "intro": "山里的雨一下就是七天，坡上的土松了，有人夜里听见后山响。老人说，这样的雨，从前冲垮过半个村子。更糟的是，有伙山贼专挑这样的雨夜在村外游荡，趁乱摸进守不住的人家。", "goal": "赶在雨最大之前，把要塌的地方看住；撞上趁火打劫的山贼，也得把他们打退。", "beat": "一场大雨要来，村外还有山贼趁乱打劫，村子可能守不住，人心开始发慌。"},
			{"act": "转", "name": "走还是留", "intro": "雨停了，塌了半间屋，山贼也没退远。几户人家合计着要搬走，说这地方待不下去了；也有人不肯走，说祖坟都在这儿。", "goal": "去听听走的人和留的人，各自是怎么说的。", "beat": "有人犹豫着要不要离开，村子眼瞅着要散；山贼没退，谁走谁留都更难了。"},
			{"act": "合", "name": "一盏一盏的灯", "intro": "你把这些天见过的人、跑过的路又想了一遍。有些事你既然管了，就得管到底——那口老炉，那座断桥，那些托付。", "goal": "把你答应过的事，一件一件都收个尾。", "beat": "玩家开始把散落的人和事，一件件拢回来。"},
			{"act": "合", "name": "守到天亮", "intro": "老人说，村子能不能立住，就看这几天有没有人肯替它熬一回夜。天快亮了，你站在村口，身后是一片还亮着的灯。可那伙贼人没走远，还在坡下转悠，谁也不敢合眼。", "goal": "把这一夜守过去——打退来犯的贼人，让村子安稳地睡到天亮。", "beat": "这是这一程的最后一夜，打退来犯的人、守住村子，你就是村子离不开的人。"},
		],
	},
	"wanderer": {
		"title": "门槛",
		"acts": [
			{"act": "起", "name": "迈出门槛", "intro": "你背起行囊站在村口。村里人问你往哪儿去，你说不上来，只知道不能停在这儿。", "goal": "先迈出村子，往第一处没去过的地方走。", "beat": "玩家正要离开村子，这是往外走的第一步。"},
			{"act": "承", "name": "无名坡", "intro": "翻过一道坡，四下里连个名字也没有。风把草压得低低的，回头已经看不见村子了。坡下的草里散着半截车辕、一个被踩烂的钱袋——这条道有人走，也有人在道上截人。", "goal": "在这一带认认路，也留神路上有没有人盯着。", "beat": "外面的地方大多没有名字，还得提防靠截道过活的人。"},
			{"act": "承", "name": "半途的信", "intro": "路边的石头下压着一封没送到的信，收信人的名字被雨水泡花了。写信的人大概也走了很远，可这封信到底没能送到——也许半道上就出了事。", "goal": "顺着信上的线索，看它本来要送到哪儿去。", "beat": "路上有别人留下的痕迹——只是有人走得到，有人半道就没了消息。"},
			{"act": "承", "name": "越走越偏", "intro": "越往外走，地名越生，人心越远。歇脚的人劝你回头，说再往前就是没人管的地界——前些日子有一队商客在那条道上被劫了，连人带货都没了下落。", "goal": "挑一条更远的路，走到底看看——顺道打听那伙劫道的人。", "beat": "玩家越走越远，开始有人劝他回头，前头还有劫道的传闻。"},
			{"act": "转", "name": "迷路", "intro": "一场大雾把指北的桩子都吞了，你绕了三天，回到的还是同一片林子。正是这团雾，把你送进了那伙劫道人的地界——他们专挑迷了路的行商下手，如今又把你围在了当中。", "goal": "从雾里走出去——先得把堵住去路的这伙劫道的人打退。", "beat": "玩家撞上过不去的坎，还得先打退这伙专劫迷路人的匪徒，才谈得上往前。"},
			{"act": "转", "name": "远来的客", "intro": "雾散后，你在一个没名字的落脚处遇上了另一个赶路的人。他说自己也在找路的尽头，还说你打退那伙劫道人的事，这条道上的人已经传开了——往后走这段路的人，能安生些了。", "goal": "和这个同样往外走的人，各走各的，还是搭一段。", "beat": "玩家遇见同路的人，也头一回尝到「自己走过，也让旁人好走」的滋味。"},
			{"act": "合", "name": "界碑", "intro": "你在一块半截的界碑前停下。碑上刻着的地名，村子里的老人从没提过。碑下的土是新翻的——像有人也走到过这里，又接着往前去了。自打那伙劫道的被打散，这条路才重新有了脚印。", "goal": "越过这块碑，把地图的边再往外推开一点。", "beat": "玩家走到地图的边缘，路上重新有了脚印，再往前就是没人记得的地方。"},
			{"act": "合", "name": "尽头之外", "intro": "路到头了，前面是一片没有名字的开阔地。你回头，村子成了身后一个小小的亮点，然后你转过身。", "goal": "走完这最后一段，把名字留在没人知道的地方。", "beat": "这是最后一程，走完，玩家就把自己走成了远方的人。"},
		],
	},
	"bridge": {
		"title": "两头",
		"acts": [
			{"act": "起", "name": "生人勿近", "intro": "村口来了几个外乡人，村里人把门关得紧紧的，谁也不肯先开口。两边隔着一条道，谁也不看谁。那道口上最近也不安生，夜里常有杂沓的脚步声来去，天亮又什么也寻不着。", "goal": "先去弄清楚，这两边到底在防着什么。", "beat": "村里人和外面的人互相提防，那道口上还透着不对劲。"},
			{"act": "承", "name": "通不通的货", "intro": "村里有东西卖不出去，外头有东西运不进来。中间就隔着一道说不清的规矩，谁也不敢先破。上回外乡人的一车货，就是在半道上被一伙人砸了、抢了，大伙儿这才都缩了回去。", "goal": "试试看，能不能让两头的货先通上。", "beat": "两边都缺对方的东西，可路上有人砸货抢货，谁都不敢先探头。"},
			{"act": "承", "name": "两难", "intro": "帮了外乡人，村里人就说你胳膊肘往外拐；帮着村里人，外乡人又觉得你不近人情。", "goal": "在两边的埋怨里，想个都能交代过去的法子。", "beat": "玩家夹在两头之间，两边都不讨好。"},
			{"act": "承", "name": "搭线", "intro": "你想起村里那个手艺最好的老人，又想起外乡人说过缺的那样东西——这两样，正好能凑到一块儿。可你留意到，每次刚有眉目，道口上就准出事：不是货被砸，就是有人两边传不是话。像是有人成心不想让这条道通。", "goal": "把这两头的人牵到一处，让他们自己开口。", "beat": "玩家开始牵线，却发现有人成心在两头之间搅浑水。"},
			{"act": "转", "name": "反目", "intro": "一笔说好的买卖黄了，两边都说是对方先变卦，眼看好不容易搭上的线又要断。你顺着线查下去，才明白一直是同一伙人在两头的道口挑事——砸货、传话、点火，就指望两边永远打不通。如今他们堵在道口，拦住过往的人不让走。", "goal": "去弄明白这笔买卖到底卡在哪儿；碰上那伙拦道挑事的人，也得先把场面镇住。", "beat": "好不容易搭上的桥眼看要塌，搅浑水的那伙人终于堵上了道口。"},
			{"act": "转", "name": "危桥", "intro": "一场大水冲塌了村外那座老桥。那伙挑事的人被打退之后，道口清静了，两头的人头一回站在了同一边——都想着怎么把桥修起来。", "goal": "趁两边劲头都还在，把修桥的事张罗起来。", "beat": "拦道的没了，一场灾祸反倒把两头的人推到了一起。"},
			{"act": "合", "name": "集市", "intro": "桥修好那天，有人在桥头摆起了摊子，村里人拎着东西出来，外乡人也赶了过来。道上再不见拦路的人，青石村头一回这样吵吵嚷嚷。", "goal": "把这场热闹操持起来，让两边都尝到甜头。", "beat": "道上通了，村子头一回热闹起来，两边的人站在了一处。"},
			{"act": "合", "name": "通途", "intro": "从村口往外看，那条道上的脚印，一半是往里走的，一半是往外走的。路还是那条路，只是再没有人在半道上拦货、传话了。", "goal": "把这条道上的事理顺，让两边长久地通下去。", "beat": "这是最后一程，把两头真正连成一条路。"},
		],
	},
	"hermit": {
		"title": "过客",
		"acts": [
			{"act": "起", "name": "一个人来", "intro": "你一个人到了青石村，不声不响地找了个落脚的地方。有人问你从哪儿来，你笑笑，没说。只在村口听说，近来村外那条路上流窜着几个歹人，专拣落单的人下手。", "goal": "把该安置的安置好，别欠下谁的人情。", "beat": "玩家刻意跟村里人保持距离，村外的路上却添了歹人。"},
			{"act": "承", "name": "借宿一宿", "intro": "夜里下了雨，有人敲门要借宿。你让了半间屋，天一亮那人就走了，留下一句谢，没留名字。", "goal": "帮过路的人一把，然后各走各的。", "beat": "玩家肯帮忙，但帮完就散，不留交情。"},
			{"act": "承", "name": "各取所需", "intro": "村里人找你帮忙，你从不白帮——做完事，拿该拿的，两清。日子久了，大家都说你这人可靠，可也说不亲近。只是如今托你去村外办事的人越来越少——那几个歹人还在路上晃，谁也不敢往远了走。", "goal": "把手上这些明码标价的事，一件件办完。", "beat": "玩家把帮忙当成一桩桩买卖，两清，不纠缠；村外的道却越来越不敢走。"},
			{"act": "承", "name": "路过", "intro": "你在村里来来去去，像一阵风。有人想留你吃顿饭，你说还有事，就走了。只有一次，你在路口瞥见几个生面孔蹲在那儿，见有人过来就哄笑起来——那几个歹人，已经晃到村口了。", "goal": "顺着自己的路往前走，不为谁多停。", "beat": "玩家总是路过，从不肯停下来深交；那几个歹人却晃到了村口。"},
			{"act": "转", "name": "牵绊", "intro": "有个孩子天天守在门口等你，说要跟你学认路。你想起自己也曾一个人走过很长很长的路。可这天，那几个晃到村口的歹人堵住了路，正欺负那孩子。", "goal": "先把这几个歹人打退，把孩子护下来，也把心里那点牵挂想清楚。", "beat": "玩家头一回被人真正惦记上，非出手不可，心里有了牵绊。"},
			{"act": "转", "name": "夜里的几句话", "intro": "那几个歹人被打退后，村里安生了，连孩子也敢在路口玩了。夜里，有人在你屋外坐了一夜，说有些话再不说就没机会了。你隔着一扇门听完了，终究没开门。", "goal": "这一夜的话，听进去多少，自己拿主意。", "beat": "玩家被推着往深里走一步，却仍不肯进门。"},
			{"act": "合", "name": "收尾", "intro": "你把这些天答应过的事一件件做完，把借来的东西还回去，把该说的话说清楚。", "goal": "把该了结的了结干净，不留尾巴。", "beat": "玩家开始把该做的事都收干净，准备离开。"},
			{"act": "合", "name": "独自远走", "intro": "天没亮你就出了村，谁也没惊动。身后是还没醒的村子——那条路上的歹人早散了，村口也太平了；身前是没走完的路，你还是一个人。", "goal": "不惊动任何人，走完自己这一程。", "beat": "这是最后一程，走完，玩家就一个人走自己的路。"},
		],
	},
}

## 通用弧：自己写结局、或没定结局时走这条。不偏向任何一种收尾，起承转合俱全。
const GENERIC_ARC := [
	{"act": "起", "name": "出发", "intro": "你到了青石村，日子刚起了个头，还不知道这一程会走到哪里去。只听说村外那片地方最近不太平，有伙人占着道，来往的人能绕就绕。", "goal": "先在村里安顿下来，认认人、认认路。", "beat": "玩家刚到，一切才刚开始；村外却有人占着道。"},
	{"act": "承", "name": "岔路口", "intro": "摆在面前的事忽然多了起来，往东有往东的麻烦，往西有往西的牵挂。可好几条线都卡在同一处——村外那条被占住的道，谁绕不过去。", "goal": "挑一件事先做起来，看看它能把你带到哪儿。", "beat": "玩家面前分出几条线，却都绕不开那条被占住的道。"},
	{"act": "承", "name": "试炼", "intro": "有些事不像看上去那么容易，跑一趟才知道里头有多少难处。要办的事正好在道那头，而占住这条道的，就是那伙早听说过的坏人——不把他们打退，这条路就通不了。", "goal": "先打退占道的这伙人，再把那件难办的事咬牙办成。", "beat": "玩家头一回碰上硬骨头，得靠真本事把这条路打通。"},
	{"act": "承", "name": "同行的人", "intro": "那条被占的道打通之后，走的路长了，身边慢慢多出几个同行的人——有那天一起把占道的坏人打退的，也有受了益来谢你的。有人帮你，也有人等着你帮。", "goal": "和这些同行的人，把关系处明白。", "beat": "玩家身边聚起了人，路不再是一个人走；当初打通的那条道，把人带到了他身边。"},
	{"act": "转", "name": "代价", "intro": "有件事你非做不可，可做了就得舍下另一样——两头都占着，反倒两头都落空。", "goal": "在两难里挑一头，担下该担的。", "beat": "玩家遇上两难，非得舍下一头不可。"},
	{"act": "转", "name": "抉择", "intro": "到了这一步，之前答应过谁、欠过谁、放不下谁，都摆到了台面上。连最早那场占道的祸事，也绕了一圈回来找你——当初打通的路，如今又要你再拿一次主意。", "goal": "做个了断，把心里那杆秤端平。", "beat": "玩家要把之前所有的牵扯，做一次总的了断；最早的战斗也回响到今天。"},
	{"act": "合", "name": "逼近", "intro": "一直挂在心上的那件事，终于也到了跟前。回头看看走过的路，走到这儿不容易。", "goal": "把手上的事都收束到最后一程上。", "beat": "玩家把各条线收拢，一步步逼近最后一步。"},
	{"act": "合", "name": "落点", "intro": "路走到这里，该有个落脚的地方了。这一程遇见的人、办过的事，都要有个交代；还有那条早先打通的、如今人来人往的道，也要有个交代。", "goal": "把这一程走完，给自己一个交代。", "beat": "这是最后一程，走完，这一段故事就落定了；打通的那条道，成了这段故事最后的注脚。"},
]

## 离线兜底结局（按代码选出的类型取一份）
const MOCK_ENDINGS := {
	"warden": {
		"title": "守望之人",
		"text": "你把青石村当成了自己的家。这些年村子长出的每一间屋、每一条路，你都走过；每一张新面孔，你都叫得出名字。天亮了，你仍旧站在村口，像一棵早就长在那儿的树。",
		"epilogue": "有人问你在等谁，你说：不等谁，就是舍不得走。",
	},
	"wanderer": {
		"title": "远行的人",
		"text": "你把村子能走的路都走遍了，又往更远处去了。地图的边缘一次又一次被你推开，青石村在你身后，成了一个小小的、发亮的点。",
		"epilogue": "你回头看了一眼，然后接着往前走——前面还有没名字的地方。",
	},
	"bridge": {
		"title": "架桥的人",
		"text": "你既没有只顾着往外跑，也没有只守在村里。你把外面的人带回了村子，又把村里的事带到了外面。青石村头一回这样热闹，连断了的桥都有人来修。",
		"epilogue": "后来的人说，那几年村子像是忽然通了电，其实通的是人。",
	},
	"hermit": {
		"title": "独行的人",
		"text": "你把该办的事都办完了，却没在谁那儿留下太深的话。村子照旧过着它的日子，你也照旧走你的路，像两条并排的溪，一时靠得近，一时又远了。",
		"epilogue": "有些故事不必有人记得，走过就是了。",
	},
}

## 终极目标模板（四条预设主线各一套）。
## 每一套给出：终极目标的名字与含义，以及终局链三站的幕名与台词骨架。
## 台词里的 {place} / {npc} 会被替换成**真实存在**的地点名与人名——
## 这就是「发任务即承诺」：任务写出来的地方和人，在任务发出的那一刻就已经在地图上了。
## 离线兜底直接用这套模板；联网时只把地点和人喂给模型，让它把话说得更活，落点仍由代码钉死。
const ULTIMATE_TEMPLATES := {
	"warden": {
		"name": "村子的根",
		"desc": "把村子最早的那点根收拢回来，让它不管过多少年，都还有人记得自己是从哪儿来的。",
		"steps": [
			{"name": "老根", "line": "往{place}去一趟，找{npc}。村子最开始的那截根，就埋在那儿。"},
			{"name": "旧账", "line": "再去{place}，{npc}手里还压着一本旧账，记着这些年谁家帮过谁家。"},
			{"name": "回来", "line": "最后回到{place}，见{npc}，把你这一路认下的名字，都带回村里。"},
		],
	},
	"wanderer": {
		"name": "路尽头的名字",
		"desc": "一路走到再没有名字的地方，把最后一段路走完，让「远方」不再只是别人嘴里的传说。",
		"steps": [
			{"name": "第一程", "line": "背上行囊，往{place}去，找{npc}问一句：再往前，还有路吗？"},
			{"name": "越界", "line": "走到{place}，见{npc}——他会告诉你，这地方再往外，是什么样子。"},
			{"name": "尽头", "line": "最后一程走到{place}，见{npc}。到这儿，你走过的路，就没有人再走过了。"},
		],
	},
	"bridge": {
		"name": "两头之约",
		"desc": "把村子和外面真正连成一条道，让两头的人从此不必再隔着一条道互相提防。",
		"steps": [
			{"name": "那一头", "line": "先往{place}去，见{npc}，弄清村外那一头到底想要什么。"},
			{"name": "说合", "line": "再跑一趟{place}，见{npc}，把两头的人都拉到一处，让他们自己开口。"},
			{"name": "通途", "line": "最后去{place}，跟{npc}把这条路上的规矩定下来——从此两头通着。"},
		],
	},
	"hermit": {
		"name": "一个人的路",
		"desc": "把该了结的都了结干净，谁的情也不欠，然后一个人走完最后一段路。",
		"steps": [
			{"name": "了结", "line": "去{place}找{npc}，把你欠下的、答应过的，一次说清。"},
			{"name": "归还", "line": "再到{place}，把{npc}那儿借来的东西、承下的情，都还回去。"},
			{"name": "别过", "line": "最后去{place}见{npc}一面，道个别——说完这句，你就该一个人上路了。"},
		],
	},
}

## 自定义结局用的终局链模板：玩家自己写的结局没有现成骨架，
## 这三站就是「把许下的心愿一步步走成真的」——终点仍由真实地点与真人钉死。
const CUSTOM_GOAL_TEMPLATE := {
	"name": "心之所向",
	"desc": "把玩家亲口许下的那个结局，一步一步走成真的。",
	"steps": [
		{"name": "启程", "line": "先往{place}去，找{npc}——这件事该从哪儿起头，他心里有数。"},
		{"name": "波折", "line": "再去{place}，{npc}手里还压着一道非过不可的坎。"},
		{"name": "如愿", "line": "最后回到{place}见{npc}，把你许下的那个结局，走成真的。"},
	],
}

var mode := "mock"
var api_base := "https://api.openai.com/v1"
var api_key := ""
var model := "gpt-4o-mini"

## 第几轮故事（看完结局可以开新一轮，一路往上加）
var cycle := 1
## 当前是这一轮的第几章；0 表示还没开始
var chapter := 0
## 当前章节的完整数据（界面直接读它）
var chapter_data: Dictionary = {}
## 最近一次结局
var ending: Dictionary = {}
## 这一轮是否已经走完
var finished := false
## 看过的结局流水（存档用）
var endings_seen: Array = []

## 玩家在开局定下的「目标结局」
##   goal_kind: "" 未设定 / "preset" 选了预设 / "custom" 自己写了一段
var goal_kind := ""
var goal_preset := ""
var goal_custom := ""

## 本轮主线走的是哪条弧（STORY_ARCS 的键，或 "generic"）。
## 按玩家定下的结局在开局锁定一次，之后整轮不改，保证每一幕都接得上。
var arc_key := ""
## 玩家自定义结局时，AI 现场编的那条八幕主线（贴着玩家写的结局走）。
## 空数组表示还没编出来（或不是自定义结局），此时回退到通用弧。
var custom_arc: Array = []
## 上面那条自定义主线的名字
var custom_arc_title := ""
## 开局预备（加载动画）的状态：{"active": true, "phase": "arc"|"commit"|"chapter"}
var _prepare: Dictionary = {}
## 本章里玩家促成的事（每完成一个支线就记一条），本轮会反馈进章节与结局的生成
var milestones: Array = []
## 走过的章节回顾（一轮走完若干章后，把这些串成一条线给结局和界面用）
var chapter_log: Array = []

var _http: HTTPRequest
var _busy := false
var _checking := false
var _ctx: Dictionary = {}

## 本轮的「终极目标」：三条终局链的真实落点 + 每一站要见的人。
## 空字典表示这一轮没有终极目标（自定义结局 / 没定结局，仍走原来那条弧）。
var ultimate_goal: Dictionary = {}
## 终局链进行到第几站（界面高亮用）
var goal_step := 0
## 「发任务即承诺」的状态机：把三站的地点与人一次性落实下来
var _commit: Dictionary = {}


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_load_config()
	# 玩家的任何一步进展，都可能让当前章节达成
	QuestManager.quest_completed.connect(_on_progress)
	WorldData.location_added.connect(_on_progress)
	NpcMemory.impression_changed.connect(_on_progress)
	# 「发任务即承诺」：终局链挑去的远处地点、安排的人，一落地就回报这里
	LocationGenerator.location_created.connect(_on_commit_location)
	NpcGenerator.npc_created.connect(_on_commit_npc)


func _load_config() -> void:
	# 配置统一由 LlmConfig 下发（res:// 默认 + user:// 玩家设置）
	LlmConfig.apply_to(self)
	print("[StoryDirector] 剧情模式 = %s" % mode)


# ---------------------------------------------------------------- 启动 / 推进

## 由主场景在 _ready 里调用。
## 为什么不在自己的 _ready 里起章节：StoryDirector 的 _ready 早于 SaveSystem 读档，
## 这时还不知道存档里已经推到第几章。读档会填好 chapter/finished，
## 所以这里只在「全新开始」时才起第一章。
func boot() -> void:
	if chapter > 0 or finished:
		return
	lock_arc()
	# 有预设结局的玩家：先把终极目标的三站真实落点落实（发任务即承诺），
	# 落实完再从头开始推章节。落实不出来就退回原来的弧，不至于卡死。
	if _try_start_ultimate_goal():
		return
	_begin_chapter(1)


## 看完一个结局后，开新一轮：章节从头开始，但判定值继续往上加。
## 主线弧不变（玩家定的结局没变），所以新一轮还是会顺着同一条线走到同一个落点。
func begin_new_cycle() -> void:
	cycle += 1
	finished = false
	ending = {}
	chapter = 0
	chapter_data = {}
	_ctx = {}
	# 终极目标沿用上一轮锁定的那条链（同一个结局，同一批地方与人），
	# 只把「去见过了」的进度清空，重新走一遍最后三站。
	if not ultimate_goal.is_empty():
		_reset_final_progress()
		_begin_chapter(1)
		return
	if _try_start_ultimate_goal():
		return
	_begin_chapter(1)


# ---------------------------------------------------------------- 开局预备（自定义结局）

## 自定义结局的玩家，进主场景前先在加载场景里把这一程预备好：
##   1. 用玩家写的结局当主题，现场编一条贴合的八幕主线；
##   2. 把终局链的三站真实地点与人落实下来（发任务即承诺）；
##   3. 写出第一章。
## 全程通过 prepare_progress 报进度，prepare_finished 收尾。
## 预设结局 / 没定结局不走这里（它们用现成模板，秒进）。
func prepare_custom_ending() -> void:
	if goal_kind != "custom" or goal_custom.strip_edges() == "":
		prepare_finished.emit(false)
		return
	# 已经推进过了（读档 / 重复进入），不用再预备
	if chapter > 0 or finished:
		prepare_finished.emit(true)
		return
	if bool(_prepare.get("active", false)):
		return
	_prepare = {"active": true, "phase": "arc"}
	lock_arc()
	prepare_progress.emit(0, "正在为你的心愿，推演一整条主线…")
	_generate_arc()


## 现场编一条弧：联网交给模型，离线退回通用弧
func _generate_arc() -> void:
	_ctx = {"action": "arc", "attempt": 0}
	if mode == "llm" and api_key != "":
		_call_llm()
	else:
		_finalize_arc(_mock_arc())


func _finalize_arc(data: Dictionary) -> void:
	_busy = false
	var ca := _sanitize_arc(data)
	if ca.is_empty():
		ca = _mock_arc()
	custom_arc = ca.get("acts", [])
	custom_arc_title = str(ca.get("title", "心愿"))
	arc_key = "generic"
	story_changed.emit()
	_prepare["phase"] = "commit"
	prepare_progress.emit(1, "主线已经定下，正在为你安排最后一程的三站…")
	if not _try_start_ultimate_goal():
		_prepare_begin_first_chapter()


func _mock_arc() -> Dictionary:
	return {"title": "心愿", "acts": GENERIC_ARC.duplicate(true)}


## 校验模型编的弧：必须是 8 幕、每幕 name/intro/goal 齐全；不合规返回 {}
func _sanitize_arc(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = raw
	var raw_acts = d.get("acts", null)
	if typeof(raw_acts) != TYPE_ARRAY:
		return {}
	var acts_in: Array = raw_acts
	if acts_in.size() < MAX_CHAPTERS:
		return {}
	var default_acts := ["起", "承", "承", "承", "转", "转", "合", "合"]
	var acts: Array = []
	for i in range(MAX_CHAPTERS):
		if typeof(acts_in[i]) != TYPE_DICTIONARY:
			return {}
		var a: Dictionary = acts_in[i]
		var nm := str(a.get("name", "")).strip_edges()
		var intro := str(a.get("intro", "")).strip_edges()
		var goal := str(a.get("goal", "")).strip_edges()
		if nm == "" or intro == "" or goal == "":
			return {}
		var act := str(a.get("act", "")).strip_edges()
		if act == "":
			act = default_acts[i]
		acts.append({
			"act": act,
			"name": nm,
			"intro": intro,
			"goal": goal,
			"beat": str(a.get("beat", "")).strip_edges(),
		})
	var title := str(d.get("title", "")).strip_edges()
	if title == "":
		title = "心愿"
	return {"title": title, "acts": acts}


## 终局落点都齐了、该写第一章了：先跟加载动画报一句，再起第一章
func _prepare_begin_first_chapter() -> void:
	if bool(_prepare.get("active", false)):
		_prepare["phase"] = "chapter"
		prepare_progress.emit(2, "世界已经就位，正在推开第一扇门…")
	_begin_chapter(1)


# ---------------------------------------------------------------- 主线弧

## 锁定本轮走哪条弧：玩家定的是哪个预设就走哪条，自定义/没定走通用弧。
## 只会锁一次（弧键已定就不再改），所以中途读档也不会换线。
func lock_arc() -> void:
	if arc_key != "":
		return
	if goal_kind == "preset" and STORY_ARCS.has(goal_preset):
		arc_key = goal_preset
	else:
		arc_key = "generic"


## 本轮这条弧的八幕
func current_arc() -> Array:
	lock_arc()
	# 自定义结局：用 AI 现场编的那条弧；还没编出来就先走通用弧
	if goal_kind == "custom" and not custom_arc.is_empty():
		return custom_arc
	if STORY_ARCS.has(arc_key):
		return (STORY_ARCS[arc_key] as Dictionary).get("acts", GENERIC_ARC)
	return GENERIC_ARC


## 本轮这条弧的名字（如「归处」「门槛」）；通用弧返回空串
func arc_title() -> String:
	lock_arc()
	if goal_kind == "custom" and not custom_arc.is_empty():
		return custom_arc_title
	if STORY_ARCS.has(arc_key):
		return str((STORY_ARCS[arc_key] as Dictionary).get("title", ""))
	return ""


## 当前这一章对应到弧里的那一幕。一轮 MAX_CHAPTERS 章正对八幕，一章一幕。
## 走到终局链那几章时，幕是从终极目标里取的真实一站。
func current_beat() -> Dictionary:
	var fi := _final_step_index(chapter)
	if fi >= 0:
		return _final_beat(fi)
	var arc := current_arc()
	if arc.is_empty():
		return {}
	var idx := (chapter - 1) % arc.size()
	if idx < 0:
		idx = 0
	return arc[idx]


# ---------------------------------------------------------------- 终局链

## 这一轮有没有锁定终极目标
func has_ultimate_goal() -> bool:
	return not ultimate_goal.is_empty()


func ultimate_goal_title() -> String:
	return str(ultimate_goal.get("name", ""))


func ultimate_goal_desc() -> String:
	return str(ultimate_goal.get("desc", ""))


## 终局链的每一站（真实地点 + 要见的人）
func ultimate_steps() -> Array:
	var s = ultimate_goal.get("steps", [])
	if typeof(s) != TYPE_ARRAY:
		return []
	return s


## 当前章落在终局链的第几站；不在终局链章节返回 -1
func current_final_index() -> int:
	return _final_step_index(chapter)


## 第 ch 章对应终局链的第几站。最后 FINAL_STEPS 章 = 最后几站。
func _final_step_index(ch: int) -> int:
	if ultimate_goal.is_empty() or ch <= 0:
		return -1
	var k := ultimate_steps().size()
	if k <= 0:
		return -1
	var first := MAX_CHAPTERS - k + 1
	if ch < first or ch > MAX_CHAPTERS:
		return -1
	return ch - first


## 终局链某一站的「幕」：起承转合里落在「合」上，用真实地点与人撑起来
func _final_beat(fi: int) -> Dictionary:
	var steps := ultimate_steps()
	if fi < 0 or fi >= steps.size():
		var arc := current_arc()
		if arc.is_empty():
			return {}
		return arc[arc.size() - 1]
	var st: Dictionary = steps[fi]
	return {
		"act": "合",
		"name": str(st.get("name", "终局")),
		"intro": _final_intro(st),
		"goal": _final_goal_text(st),
		"beat": str(st.get("line", "")),
	}


func _final_intro(st: Dictionary) -> String:
	var line := str(st.get("line", "")).strip_edges()
	if line != "":
		return line
	return "你动身往%s去。" % str(st.get("location_name", "那一头"))


## 这一章的目标文本：明确写出「往哪个方向、走多远、到哪个地方、见谁」——
## 这几个都来自真实地点与人，玩家照着走一定走得到。
func _final_goal_text(st: Dictionary) -> String:
	var place := str(st.get("location_name", ""))
	var who := str(st.get("npc_name", ""))
	var dir := str(st.get("direction", ""))
	var dist := int(st.get("distance_m", 0))
	if who != "":
		return "往%s走约 %d 米，到%s去见%s。" % [dir, dist, place, who]
	return "往%s走约 %d 米，到%s去一趟。" % [dir, dist, place]


## 逐站比对「这一站的人有没有去见过了」：聊过就算见过（PlayerProfile.talk_count 涨了）
func _sync_final_steps() -> void:
	if ultimate_goal.is_empty():
		return
	var changed := false
	var steps := ultimate_steps()
	for s in steps:
		var who := str((s as Dictionary).get("npc_name", ""))
		if who == "" or bool((s as Dictionary).get("done", false)):
			continue
		if PlayerProfile.talk_count(who) > int((s as Dictionary).get("talk_base", 0)):
			(s as Dictionary)["done"] = true
			changed = true
	# 当前站推进到第一个还没做完的位置
	var idx := steps.size()
	for i in range(steps.size()):
		if not bool((steps[i] as Dictionary).get("done", false)):
			idx = i
			break
	if idx != goal_step:
		goal_step = idx
		changed = true
	if changed:
		story_changed.emit()


## 开新一轮时，把终局链的进度清空（地点和人不变，重新走一遍）
func _reset_final_progress() -> void:
	goal_step = 0
	if ultimate_goal.is_empty():
		return
	for s in ultimate_steps():
		var who := str((s as Dictionary).get("npc_name", ""))
		if who == "":
			(s as Dictionary)["done"] = true
			continue
		(s as Dictionary)["done"] = false
		(s as Dictionary)["talk_base"] = PlayerProfile.talk_count(who)


## 主场景搭话时调这里：终局链可能正等着「去见某个人」，搭话即视为履约
func note_talk(_npc_name: String) -> void:
	if ultimate_goal.is_empty():
		return
	_sync_final_steps()
	_check_progress()


# ---------------------------------------------------------------- 发任务即承诺

## 有预设结局 / 自定义结局的玩家，开局就把终极目标的三站真实落点落实下来。
## 全部挑得到 → 启动承诺状态机、异步把地点与人造出来，返回 true；
## 有任何一站挑不到（世界太挤 / 全是海）→ 返回 false，退回原来的弧。
func _try_start_ultimate_goal() -> bool:
	if ultimate_goal.size() > 0 or not _commit.is_empty():
		return false
	var ok_kind := false
	if goal_kind == "preset" and STORY_ARCS.has(goal_preset):
		ok_kind = true
	elif goal_kind == "custom" and goal_custom.strip_edges() != "":
		ok_kind = true
	if not ok_kind:
		return false
	if _goal_template().is_empty():
		return false
	var used: Array = []
	var cells: Array = []
	for i in FINAL_STEPS:
		var d := float(FINAL_DISTANCES_M[i])
		var band := FINAL_DIST_BAND_M
		var salt := SALT_FINAL_BASE + i * 977 + (cycle - 1) * 131
		var cell = LocationGenerator.pick_far_cell(
			(d - band) * PX_PER_METER, (d + band) * PX_PER_METER, salt, used
		)
		if cell == null:
			return false
		var cv: Vector2i = cell
		used.append(cv)
		cells.append(cv)
	_commit = {
		"active": true,
		"cells": cells,
		"queue": cells.duplicate(),
		"results": [],
		"awaiting": false,
		"current_cell": Vector2i.ZERO,
		"pending_loc": {},
	}
	_busy = true
	_pump_commit()
	return true


## 一站一站地落实：挑好的格子逐个交给 LocationGenerator 强行生成地点，
## 地点一落地就给它安排一个人，人和地点都齐了才算这一站落实完。
func _pump_commit() -> void:
	if not bool(_commit.get("active", false)) or bool(_commit.get("awaiting", false)):
		return
	var queue: Array = _commit.get("queue", [])
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		# 关键：先把「正在等这一格」记下来，再发起生成——
		# mock 模式下 request_location_at 会同步回调，顺序反了状态机就卡死。
		_commit["current_cell"] = cell
		_commit["pending_loc"] = {}
		_commit["awaiting"] = true
		if LocationGenerator.request_location_at(cell):
			_arm_commit_timeout(cell)
			return
		# 这一格落不下去了，标记已处理，接着处理下一格
		_commit["awaiting"] = false
	_commit_done()


func _on_commit_location(loc: Dictionary) -> void:
	if not bool(_commit.get("active", false)) or not bool(_commit.get("awaiting", false)):
		return
	var pos: Vector2 = loc.get("pos", Vector2.ZERO)
	if RegionGenerator.cell_at(pos) != (_commit.get("current_cell", Vector2i.ZERO) as Vector2i):
		return
	# 地点是真的了，接着给它安排一个真实的人
	_commit["pending_loc"] = loc
	NpcGenerator.request_npc(loc)


func _on_commit_npc(npc: Dictionary) -> void:
	if not bool(_commit.get("active", false)) or not bool(_commit.get("awaiting", false)):
		return
	var pending: Dictionary = _commit.get("pending_loc", {})
	if pending.is_empty():
		return
	if str(npc.get("home_id", "")) != str(pending.get("id", "")):
		return
	var results: Array = _commit.get("results", [])
	results.append({"loc": pending, "npc": npc})
	_commit["pending_loc"] = {}
	_commit["awaiting"] = false
	call_deferred("_pump_commit")


## 等一站的人就位；超时了就把地点先记下（人不记），继续往下走，别把主线卡死
func _arm_commit_timeout(cell: Vector2i) -> void:
	var t := get_tree().create_timer(COMMIT_TIMEOUT)
	t.timeout.connect(_on_commit_timeout.bind(cell))


func _on_commit_timeout(cell: Vector2i) -> void:
	if not bool(_commit.get("active", false)) or not bool(_commit.get("awaiting", false)):
		return
	if (_commit.get("current_cell", Vector2i.ZERO) as Vector2i) != cell:
		return
	var pending: Dictionary = _commit.get("pending_loc", {})
	if not pending.is_empty():
		var results: Array = _commit.get("results", [])
		results.append({"loc": pending, "npc": {}})
	_commit["pending_loc"] = {}
	_commit["awaiting"] = false
	push_warning("[StoryDirector] 终局站点的人没能按时就位，先记下地点继续")
	call_deferred("_pump_commit")


func _commit_done() -> void:
	_commit["active"] = false
	var results: Array = _commit.get("results", [])
	_commit = {}
	if results.is_empty():
		# 一站都没落实出来 → 退回原来的弧
		_busy = false
		_prepare_begin_first_chapter()
		return
	_generate_goal(_goal_skeleton(results))


## 把落实结果转成「喂给模型 / 离线兜底」都要用的真实骨架
func _goal_skeleton(results: Array) -> Array:
	var skel: Array = []
	for r in results:
		var loc: Dictionary = (r as Dictionary).get("loc", {})
		var npc: Dictionary = (r as Dictionary).get("npc", {})
		skel.append({
			"location_id": str(loc.get("id", "")),
			"location_name": str(loc.get("name", "")),
			"location_kind": str(loc.get("kind", "")),
			"direction": str(loc.get("direction", "")),
			"distance_m": int(loc.get("distance_m", 0)),
			"npc_name": str(npc.get("name", "")),
			"npc_role": str(npc.get("role", "")),
		})
	return skel


func _generate_goal(skeleton: Array) -> void:
	_ctx = {"action": "goal", "attempt": 0, "skeleton": skeleton}
	if mode == "llm" and api_key != "":
		_call_llm()
	else:
		_finalize_goal(_mock_goal())


func _finalize_goal(data: Dictionary) -> void:
	_busy = false
	var skel: Array = _ctx.get("skeleton", [])
	var tpl: Dictionary = _goal_template()
	var tpl_steps: Array = tpl.get("steps", [])
	var gname := str(data.get("name", "")).strip_edges()
	if gname == "":
		gname = str(tpl.get("name", "这一程的尽头"))
	var gdesc := str(data.get("desc", "")).strip_edges()
	if gdesc == "":
		gdesc = str(tpl.get("desc", ""))
	var raw_steps = data.get("steps", [])
	var steps: Array = []
	for i in range(skel.size()):
		var s: Dictionary = skel[i]
		var rs: Dictionary = {}
		if typeof(raw_steps) == TYPE_ARRAY and i < (raw_steps as Array).size():
			if typeof((raw_steps as Array)[i]) == TYPE_DICTIONARY:
				rs = (raw_steps as Array)[i]
		var ti: Dictionary = {}
		if i < tpl_steps.size() and typeof(tpl_steps[i]) == TYPE_DICTIONARY:
			ti = tpl_steps[i]
		var sname := str(rs.get("name", "")).strip_edges()
		if sname == "":
			sname = str(ti.get("name", "第 %d 站" % (i + 1)))
		var line := str(rs.get("line", "")).strip_edges()
		# 接地校验：这一站的话必须点出真实地点名（有人时还要点出真实人名），
		# 不合规就退回模板兜底——保证台词里永远是世上真实存在的地方和人。
		if not _line_is_grounded(line, s):
			line = _fill_line(str(ti.get("line", "")), s)
		var who := str(s.get("npc_name", ""))
		steps.append({
			"no": i + 1,
			"name": sname,
			"line": line,
			"location_id": str(s.get("location_id", "")),
			"location_name": str(s.get("location_name", "")),
			"location_kind": str(s.get("location_kind", "")),
			"direction": str(s.get("direction", "")),
			"distance_m": int(s.get("distance_m", 0)),
			"npc_name": who,
			"npc_role": str(s.get("npc_role", "")),
			# 没人可去见的站直接算完成，免得主线死等一个不存在的人
			"done": who == "",
			"talk_base": PlayerProfile.talk_count(who) if who != "" else 0,
		})
	ultimate_goal = {
		"type": "custom" if goal_kind == "custom" else goal_preset,
		"name": gname,
		"desc": gdesc,
		"steps": steps,
	}
	goal_step = 0
	_sync_final_steps()
	story_changed.emit()
	_prepare_begin_first_chapter()


func _mock_goal() -> Dictionary:
	var skel: Array = _ctx.get("skeleton", [])
	var tpl: Dictionary = _goal_template()
	var tpl_steps: Array = tpl.get("steps", [])
	var steps: Array = []
	for i in range(skel.size()):
		var s: Dictionary = skel[i]
		var ti: Dictionary = {}
		if i < tpl_steps.size() and typeof(tpl_steps[i]) == TYPE_DICTIONARY:
			ti = tpl_steps[i]
		steps.append({
			"name": str(ti.get("name", "第 %d 站" % (i + 1))),
			"line": _fill_line(str(ti.get("line", "")), s),
		})
	return {
		"name": str(tpl.get("name", "这一程的尽头")),
		"desc": str(tpl.get("desc", "")),
		"steps": steps,
	}


## 把模板里的 {place} / {npc} 换成真实名字（没有人就换成一个泛称，句子照样通顺）
func _fill_line(line: String, sk: Dictionary) -> String:
	var who := str(sk.get("npc_name", "")).strip_edges()
	if who == "":
		who = "住在那儿的人"
	return line.replace("{place}", str(sk.get("location_name", ""))).replace("{npc}", who)


## 一句台词算不算「接地」：必须点出真实地点名；这一站有人时还必须点出真实人名
func _line_is_grounded(line: String, sk: Dictionary) -> bool:
	if line.strip_edges() == "":
		return false
	var place := str(sk.get("location_name", "")).strip_edges()
	if place != "" and not line.contains(place):
		return false
	var who := str(sk.get("npc_name", "")).strip_edges()
	if who != "" and not line.contains(who):
		return false
	return true


## 本轮终极目标用哪套模板：预设用对应那套，自定义用「心之所向」那套
func _goal_template() -> Dictionary:
	if goal_kind == "custom":
		return CUSTOM_GOAL_TEMPLATE
	return ULTIMATE_TEMPLATES.get(goal_preset, {})


# ---------------------------------------------------------------- 目标结局

## 玩家在开局定下的结局，贯穿所有章节的生成，也决定最后的落点。
## 这三样都只由存读档和开始菜单设置，游戏中途不改。

func has_goal() -> bool:
	if goal_kind == "custom":
		return goal_custom.strip_edges() != ""
	if goal_kind == "preset":
		return preset_name(goal_preset) != ""
	return false


## 选定一个预设结局；id 非法则忽略并返回 false
func set_goal_preset(id: String) -> bool:
	if preset_name(id) == "":
		return false
	goal_kind = "preset"
	goal_preset = id
	goal_custom = ""
	arc_key = id
	custom_arc = []
	custom_arc_title = ""
	story_changed.emit()
	return true


## 用玩家自己写的一段话当结局；空文本则忽略并返回 false
func set_goal_custom(text: String) -> bool:
	var t := text.strip_edges()
	if t == "":
		return false
	goal_kind = "custom"
	goal_custom = t
	goal_preset = ""
	arc_key = "generic"
	# 换了结局就作废上一条现场编的主线，等预备时重新编
	custom_arc = []
	custom_arc_title = ""
	ultimate_goal = {}
	_commit = {}
	story_changed.emit()
	return true


## 不设定结局，交回给代码按玩家的行为数据判定
func clear_goal() -> void:
	goal_kind = ""
	goal_preset = ""
	goal_custom = ""
	arc_key = "generic"
	custom_arc = []
	custom_arc_title = ""
	story_changed.emit()


## 预设 id → 名字；找不到返回空串
func preset_name(id: String) -> String:
	for g in PRESET_GOALS:
		if str(g.get("id", "")) == id:
			return str(g.get("name", ""))
	return ""


## 给界面看的一行：玩家正奔向的结局（没设定则空串）
func goal_summary() -> String:
	if goal_kind == "custom":
		return goal_custom.strip_edges()
	if goal_kind == "preset":
		return preset_name(goal_preset)
	return ""


## 给生成 prompt 用的一段话（没设定则空串）
func goal_block() -> String:
	if not has_goal():
		return ""
	if goal_kind == "custom":
		return "玩家早就说过，他想要的结局是：%s\n每一章都要朝这个结局靠拢，别跑偏。" % goal_custom.strip_edges()
	return "玩家选定的结局走向是「%s」：%s\n每一章都要朝这个结局靠拢。" % [
		preset_name(goal_preset), _preset_desc(goal_preset),
	]


## 给支线任务、NPC 台词生成用的一句中性描述：玩家正奔着的结局。
## 不带「每一章」这类主线措辞，让支线自然地朝这个方向铺垫；没设定则返回空串。
func goal_theme() -> String:
	if goal_kind == "custom":
		return goal_custom.strip_edges()
	if goal_kind == "preset":
		var d := _preset_desc(goal_preset)
		if d == "":
			return preset_name(goal_preset)
		return "「%s」——%s" % [preset_name(goal_preset), d]
	return ""


func _preset_desc(id: String) -> String:
	for g in PRESET_GOALS:
		if str(g.get("id", "")) == id:
			return str(g.get("desc", ""))
	return ""


## 最终用哪个结局类型：玩家定下的优先，没设定才按行为数据判定
func _ending_type_for_player() -> String:
	if goal_kind == "custom" and goal_custom.strip_edges() != "":
		return "custom"
	if goal_kind == "preset" and preset_name(goal_preset) != "":
		return goal_preset
	return _pick_ending_type()


func _on_progress(arg = null) -> void:
	# 支线任务完成时，信号会把任务本身带进来——这是「支线反馈进主线」的入口：
	# 把它记成这一章的里程碑，之后的章节、结局都会带上玩家真正做过的事。
	if typeof(arg) == TYPE_DICTIONARY:
		var q: Dictionary = arg
		if q.has("title") and q.has("source_npc"):
			_remember_milestone(q)
	_check_progress()


## 记一条「玩家在这一章促成的事」。同一件（同名同委托人）不重复记。
func _remember_milestone(quest: Dictionary) -> void:
	var title := str(quest.get("title", "")).strip_edges()
	if title == "":
		return
	var npc := str(quest.get("source_npc", "")).strip_edges()
	for m in milestones:
		if str(m.get("title", "")) == title and str(m.get("npc", "")) == npc:
			return
	var place := ""
	var loc_id := str(quest.get("target_location", ""))
	if loc_id != "":
		place = WorldData.name_of(loc_id)
	milestones.append({"title": title, "npc": npc, "place": place})
	story_changed.emit()


func _schedule_check() -> void:
	call_deferred("_check_progress")


## 推进判定：条件达成 → 完成本章 → 进下一章或进结局。
## 用 _checking 防止重入；用 _busy 保证「一次只生成一章」。
func _check_progress() -> void:
	if _checking:
		return
	_checking = true
	# 玩家可能刚好处在终局链的某一站：先去比一比「这一站要见的人见了没」
	_sync_final_steps()
	var guard := 0
	while not finished and not _busy and chapter > 0 and chapter_done() and guard < MAX_CHAPTERS + 2:
		guard += 1
		_advance()
	_checking = false


func _advance() -> void:
	var done_chapter := chapter_data.duplicate(true)
	# 这一章连同玩家在章里促成的事，一起留下一条回顾，供后续章节与结局引用
	chapter_log.append({
		"cycle": cycle,
		"chapter": chapter,
		"title": str(chapter_data.get("title", "")),
		"name": str(chapter_data.get("name", "")),
		"act": str(chapter_data.get("act", "")),
		"milestones": milestones.duplicate(true),
	})
	while chapter_log.size() > CHAPTER_LOG_KEEP:
		chapter_log.remove_at(0)
	chapter_completed.emit(done_chapter)
	if chapter >= MAX_CHAPTERS:
		_generate_ending()
	else:
		_begin_chapter(chapter + 1)


# ---------------------------------------------------------------- 目标判定

## 第 ch 章对应的是「整条故事线上的第几步」。跨轮次也一直往上加。
func _step_of(ch: int) -> int:
	return (cycle - 1) * MAX_CHAPTERS + ch


## 这一章要求玩家做到什么。用累计值，只增不减 → 可以无限推下去。
## 每章都在前一章的基础上再加「一章的量」（QUESTS_PER_CHAPTER 等），
## 于是每一章都要真干活，而不是靠之前攒下的数字躺着过关——
## 最后一项「本章促成的事」是每章新起的，逼玩家在这一章里真的动手做成一件事。
func _requirement_for(ch: int) -> Dictionary:
	var step := _step_of(ch)
	return {
		"quests_completed": step * QUESTS_PER_CHAPTER,
		"new_locations": maxi(1, step * LOCATIONS_PER_CHAPTER),
		"affinity_total": AFFINITY_PER_CHAPTER * step,
		"milestones": 1,
	}


## 给界面用的进度行：现在做到多少 / 需要多少 / 是否达标
func progress_rows() -> Array:
	var req := _requirement_for(chapter)
	var rows: Array = []

	var done_quests := PlayerProfile.quests_completed
	var want_quests := int(req["quests_completed"])
	rows.append({"label": "办成的事", "now": done_quests, "need": want_quests, "done": done_quests >= want_quests})

	var places := WorldData.runtime_count()
	var want_places := int(req["new_locations"])
	rows.append({"label": "走出来的新地方", "now": places, "need": want_places, "done": places >= want_places})

	var bond := NpcMemory.affinity_total()
	var want_bond := int(req["affinity_total"])
	rows.append({"label": "攒下的情谊", "now": bond, "need": want_bond, "done": bond >= want_bond})

	var want_ms := int(req.get("milestones", 1))
	rows.append({"label": "本章促成的事", "now": milestones.size(), "need": want_ms, "done": milestones.size() >= want_ms})

	# 终局章：多一条「去见某个人」的硬门槛——真见到人（搭过话）才算过这一站
	var fi := _final_step_index(chapter)
	if fi >= 0 and fi < ultimate_steps().size():
		var st: Dictionary = ultimate_steps()[fi]
		var who := str(st.get("npc_name", ""))
		if who != "":
			var seen := bool(st.get("done", false))
			rows.append({
				"label": "终局 · 去见 %s（%s）" % [who, str(st.get("location_name", ""))],
				"now": 1 if seen else 0,
				"need": 1,
				"done": seen,
			})

	return rows


func chapter_done() -> bool:
	if chapter == 0 or finished:
		return false
	for row in progress_rows():
		if not bool(row["done"]):
			return false
	return true


# ---------------------------------------------------------------- 章节 / 结局生成

func _begin_chapter(n: int) -> void:
	chapter = n
	chapter_data = {}
	# 新的一章，本章的里程碑从头数起（上一章的已存进 chapter_log）
	milestones = []
	_ctx = {"action": "chapter", "chapter": n, "attempt": 0}
	if mode == "llm" and api_key != "":
		_call_llm()
	else:
		_finalize_chapter(_mock_chapter(n))


func _generate_ending() -> void:
	_ctx = {"action": "ending", "attempt": 0}
	if mode == "llm" and api_key != "":
		_call_llm()
	else:
		_finalize_ending(_mock_ending())


func _finalize_chapter(data: Dictionary) -> void:
	_busy = false
	var n := int(_ctx.get("chapter", chapter))
	if n < 1:
		n = maxi(1, chapter)
	chapter = n
	var step := _step_of(n)
	var ch_name := str(data.get("name", "")).strip_edges()
	if ch_name == "":
		ch_name = str(_mock_chapter(n).get("name", "未命名"))
	# 这一章对应弧里的哪一幕：名字、起承转合的位置都以弧为准，联网生成也不会跑偏
	var beat := current_beat()
	chapter_data = {
		"index": n,
		"cycle": cycle,
		"step": step,
		"name": ch_name,
		"act": str(beat.get("act", "")),
		"beat": str(beat.get("beat", "")),
		"title": "第 %d 章 · %s" % [step, ch_name],
		"intro": str(data.get("intro", "")).strip_edges(),
		"goal": str(data.get("goal", "")).strip_edges(),
		"requirement": _requirement_for(n),
	}
	chapter_started.emit(chapter_data)
	story_changed.emit()
	_schedule_check()
	# 开局预备（加载动画）里写的这一章：第一章写好就算预备完成，可以进主场景了
	if bool(_prepare.get("active", false)):
		_prepare = {}
		prepare_progress.emit(3, "准备好了，这就出发。")
		prepare_finished.emit(true)


func _finalize_ending(data: Dictionary) -> void:
	_busy = false
	var etype := _ending_type_for_player()
	ending = {
		"type": etype,
		"type_name": str(ENDING_NAMES.get(etype, "结局")),
		"title": str(data.get("title", "")).strip_edges(),
		"text": str(data.get("text", "")).strip_edges(),
		"epilogue": str(data.get("epilogue", "")).strip_edges(),
		"cycle": cycle,
	}
	if str(ending["title"]) == "":
		ending["title"] = "第 %d 个结局" % cycle
	# 结局武器：预设结局给对应的那一把；自定义的现代结局现造一把枪械（图标交生图 AI）。
	var weapon_id := ""
	if etype == "custom":
		weapon_id = WeaponData.ensure_modern_weapon(goal_custom)
	else:
		weapon_id = WeaponData.preset_id_for_ending(etype)
	if weapon_id != "" and WeaponData.has_weapon_id(weapon_id):
		ending["weapon_id"] = weapon_id
		PlayerProfile.add_weapon(weapon_id)
		PlayerProfile.equip_weapon(weapon_id)
	finished = true
	endings_seen.append({"cycle": cycle, "type": etype, "title": ending["title"]})
	while endings_seen.size() > ENDINGS_KEEP:
		endings_seen.remove_at(0)
	ending_reached.emit(ending)
	story_changed.emit()


## 结局类型由玩家的真实数据选（不让 AI 定，免得每次都说同一个）。
##   wanderer 远行：往外走得比在村里攒的情谊多
##   warden   守望：在村里攒的情谊比往外走多
##   bridge   架桥：两头都做得不错，且比较均衡
##   hermit   独行：两样都平平
func _pick_ending_type() -> String:
	var explore := float(WorldData.runtime_count())
	var bond := float(NpcMemory.affinity_total()) / 20.0
	if explore > bond * 1.25:
		return "wanderer"
	if bond > explore * 1.25:
		return "warden"
	if explore >= 2.0 and bond >= 2.0:
		return "bridge"
	return "hermit"


func _mock_chapter(n: int) -> Dictionary:
	# 终局章：直接走终局链那一站（真实地点 + 真实的人），不再套弧里的幕
	var fi := _final_step_index(n)
	if fi >= 0:
		var fc: Dictionary = _final_beat(fi).duplicate(true)
		for key in ["name", "intro", "goal"]:
			if fc.has(key):
				fc[key] = _localize(str(fc[key]))
		return fc
	var arc := current_arc()
	if arc.is_empty():
		return {"name": "未命名", "intro": "", "goal": ""}
	var idx := (n - 1) % arc.size()
	if idx < 0:
		idx = 0
	var c: Dictionary = (arc[idx] as Dictionary).duplicate(true)
	for key in ["name", "intro", "goal"]:
		if c.has(key):
			c[key] = _localize(str(c[key]))
	return c


func _mock_ending() -> Dictionary:
	var etype := _ending_type_for_player()
	# 自定义结局：玩家写的就是他要的那句话，直接拿来当正文，不套模板
	if etype == "custom":
		return {
			"title": "如愿",
			"text": _localize(goal_custom.strip_edges()),
			"epilogue": "你想要的结局，终于成了真。",
		}
	var e: Dictionary = (MOCK_ENDINGS.get(etype, MOCK_ENDINGS["hermit"]) as Dictionary).duplicate(true)
	for key in ["title", "text", "epilogue"]:
		if e.has(key):
			e[key] = _localize(str(e[key]))
	# 把这一程真正做过的事收进结局正文，让结局是玩家自己走出来的，而不是套模板
	var recap := _recap_line()
	if recap != "":
		e["text"] = str(e["text"]) + "\n\n" + recap
	return e


## 用玩家这一程的真实数据，写一句「你做到了什么」的回顾（没有进展则空串）
func _recap_line() -> String:
	var done := PlayerProfile.quests_completed
	var places := WorldData.runtime_count()
	if done <= 0 and places <= 0:
		return ""
	var parts: PackedStringArray = []
	parts.append("这一程，你替村里办成了 %d 件事" % done)
	if places > 0:
		parts.append("走过 %d 个新地方" % places)
	var line := "、".join(parts) + "。"
	var names := _milestone_names()
	if names != "":
		line += "\n%s 托付你的事，你都一件件办妥了。" % names
	return line


## 这一程里托付过玩家的 NPC 名字（最多点三个，免得啰嗦）
func _milestone_names() -> String:
	var names: PackedStringArray = []
	for entry in chapter_log:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		for m in (entry as Dictionary).get("milestones", []):
			if typeof(m) != TYPE_DICTIONARY:
				continue
			var n := str((m as Dictionary).get("npc", "")).strip_edges()
			if n != "" and not names.has(n):
				names.append(n)
	for m in milestones:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var n2 := str((m as Dictionary).get("npc", "")).strip_edges()
		if n2 != "" and not names.has(n2):
			names.append(n2)
	if names.is_empty():
		return ""
	return "、".join(names.slice(0, mini(names.size(), 3)))


## 离线文本里写死了「青石村」，这里按当前文化圈换成真正的村名
func _localize(text: String) -> String:
	return text.replace("青石村", CultureData.village_name())


# ---------------------------------------------------------------- LLM 模式

func _system_prompt() -> String:
	var wv := CultureData.worldview_block()
	var action := str(_ctx.get("action", "chapter"))

	if action == "ending":
		var extra := ""
		if has_goal():
			extra = "\n4. 下面会写清楚这位玩家想要的结局。你必须把这个结局写出来，不许换成别的收尾。"
		return """你是一个 2D 冒险游戏的结局编剧。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- title: 字符串，这个结局的名字，2-8 个汉字
- text: 字符串，3-5 句中文，写这个结局里村子、人物和玩家最后怎么样了
- epilogue: 字符串，1-2 句中文，留给玩家回味的一句话

世界观：%s 不要引入现代或科幻元素。
要求：结局要收得住前面的铺垫，落点在这个村子的人和事上，不要喊口号。%s""" % [wv, extra]

	if action == "goal":
		return """你是一个 2D 冒险游戏的主线编剧。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- name: 字符串，这个「终极目标」的名字，3-8 个汉字，要有画面感
- desc: 字符串，1-2 句中文，说清这个终极目标到底要玩家成就什么
- steps: 数组，长度必须与下面给出的站数一样；每一项是 {"name": "2-4 个汉字的站名", "line": "1-2 句中文"}

世界观：%s 不要引入现代或科幻元素。

这是整条主线的最后一程，三站层层推进、一站比一站远，最后一站是整条线的高潮。下面给出的地方和人**都已经真实存在于地图上**：
%s

要求：
1. steps 的数量、顺序，必须与上面列出的站一一对应，不许增删；
2. 每一站的 line 必须原样点出那一站的地名%s，语气像说书人，具体、有画面；
3. 地名和人名一个字都不许改，也不许编造清单以外的地名或人名；
4. 不许提数字、任务、系统这些词。""" % [wv, _goal_skeleton_block(), "和那个人的人名" if _skeleton_has_npc() else ""]

	if action == "arc":
		return """你是一个 2D 冒险游戏的主线编剧。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- title: 字符串，这条主线的名字，2-6 个汉字
- acts: 数组，长度必须正好是 8；每一项是 {"act": "起/承/转/合 之一", "name": "2-6 个汉字的幕名", "intro": "2-4 句中文，这一幕开头发生了什么", "goal": "一句话，说明玩家这一幕要做成什么事", "beat": "一句话，说清这一幕在整条线里的作用"}

世界观：%s 不要引入现代或科幻元素。

这位玩家没有选现成的收尾，而是亲口写下了他想要的结局。请你为他量身编一条 8 幕的主线：
起承转合俱全，每一幕都朝那个结局推进，前后有铺垫、有回收，第 8 幕正好落在他写下的那个结局上。

要求：
1. acts 必须正好 8 幕，顺序对应 起、承、承、承、转、转、合、合；
2. 每一幕都要具体、有画面，像说书人，不要空泛口号；
3. 整条线要是一个完整的故事，不是八件互不相干的事；
4. 不许提数字、任务、系统这些词。""" % wv

	var n := int(_ctx.get("chapter", 1))
	var fi := _final_step_index(n)
	var view := _ultimate_block(fi) if fi >= 0 else _arc_block()
	var ground := _grounding_block()
	if ground != "":
		ground = "\n" + ground + "\n"
	return """你是一个 2D 冒险游戏的主线剧情编剧。
你只能输出一个 JSON 对象，不要输出任何解释文字，也不要使用 markdown 代码块。
JSON 的字段必须严格如下：
- name: 字符串，这一章的名字，2-6 个汉字，要有画面感
- intro: 字符串，2-4 句中文，交代这一章开头村子里发生了什么、为什么玩家得往前走
- goal: 字符串，一句话，说明玩家这一章要做成什么事

世界观：%s 不要引入现代或科幻元素。

这条主线是有起承转合的，你的这一章必须落在下面用 ★ 标出的那一幕（或那一站）上，承接前文，不许另起炉灶：
%s
%s
要求：
1. 你写的是「%s」这一章，name 与内容都要贴住它的戏眼，不要写成本幕之外的事；
2. 语气要像一个说书人，具体、有画面，不要空泛；
3. goal 只说「去做什么」，不要提数字、任务、系统这些词；
4. 若给了「玩家在本章已经促成的事」，让这一章的开头自然带上玩家做过的事，但不要逐条罗列；
5. 若这一幕的戏眼里有冲突（山贼、歹人、占了地盘的坏人趁乱打劫或拦路），就把这场架写具体：是谁、占了哪儿、为什么要动手；戏眼里没有冲突的幕不要硬加打斗。""" % [wv, view, ground, _beat_label()]


## 这一章在整条线里的说法：普通章说「第几幕」，终局章说「第几站」
func _beat_label() -> String:
	var fi := _final_step_index(int(_ctx.get("chapter", chapter)))
	if fi >= 0:
		return "终局 · 第 %d 站（共 %d 站）" % [fi + 1, ultimate_steps().size()]
	var beat := current_beat()
	return "第 %s 幕（%s）" % [str(beat.get("act", "")), str(beat.get("name", ""))]


## 终局链的「接地清单」：把这一站真实的地点与人摆给模型，谁也不许改、不许编
func _grounding_block() -> String:
	var fi := _final_step_index(int(_ctx.get("chapter", chapter)))
	if fi < 0 or fi >= ultimate_steps().size():
		return ""
	var st: Dictionary = ultimate_steps()[fi]
	var place := str(st.get("location_name", ""))
	var who := str(st.get("npc_name", ""))
	var lines: PackedStringArray = []
	lines.append("【必须接地】这一站要去的地方、要见的人，都已经真实存在，名字一个字都不许改：")
	if place != "":
		lines.append("  - 地方：%s（村子的%s方，约 %d 米外）" % [
			place, str(st.get("direction", "")), int(st.get("distance_m", 0)),
		])
	if who != "":
		lines.append("  - 要见的人：%s（%s）" % [who, str(st.get("npc_role", ""))])
	lines.append("intro 与 goal 里必须点出上面这个地名%s；不许编造清单以外的地名或人名。" % (
		"，也要点出这个人名" if who != "" else ""
	))
	return "\n".join(lines)


## 把整条「最后一程」摊开给模型看：一共几站、每站去哪见谁，标出当前站
func _ultimate_block(fi: int) -> String:
	var steps := ultimate_steps()
	if steps.is_empty():
		return ""
	var lines: PackedStringArray = []
	lines.append("这是本轮主线的最后一段——终极目标《%s》：%s" % [ultimate_goal_title(), ultimate_goal_desc()])
	lines.append("它一共 %d 站，一站比一站远，每一站都要真的到一个地方、见一个人：" % steps.size())
	for i in range(steps.size()):
		var st: Dictionary = steps[i]
		var mark := "★" if i == fi else "　"
		lines.append("%s 第 %d 站（%s）—— 往%s去，到%s见%s" % [
			mark, i + 1, str(st.get("name", "")), str(st.get("direction", "")),
			str(st.get("location_name", "")), str(st.get("npc_name", "")),
		])
	lines.append("（★ 就是你这一章要走的那一站）")
	return "\n".join(lines)


## goal 动作：把真实地点/人清单摆给模型（生成终极目标时用）
func _goal_skeleton_block() -> String:
	var skel: Array = _ctx.get("skeleton", [])
	if skel.is_empty():
		return "（没有可用的地点与人）"
	var lines: PackedStringArray = []
	for i in range(skel.size()):
		var s: Dictionary = skel[i]
		lines.append("  第 %d 站：到 %s（村子的%s方，约 %d 米外）去见 %s%s" % [
			i + 1, str(s.get("location_name", "")), str(s.get("direction", "")),
			int(s.get("distance_m", 0)), str(s.get("npc_name", "")),
			"（%s）" % str(s.get("npc_role", "")) if str(s.get("npc_role", "")) != "" else "",
		])
	return "\n".join(lines)


func _skeleton_has_npc() -> bool:
	for s in _ctx.get("skeleton", []):
		if typeof(s) == TYPE_DICTIONARY and str((s as Dictionary).get("npc_name", "")) != "":
			return true
	return false


## 把整条主线弧摊开给模型看：八幕全貌（标出当前幕）+ 已走过的章节 + 本章已促成的事。
func _arc_block() -> String:
	var arc := current_arc()
	if arc.is_empty():
		return ""
	var n := int(_ctx.get("chapter", chapter))
	var idx := (n - 1) % arc.size()
	if idx < 0:
		idx = 0
	var lines: PackedStringArray = []
	var title := arc_title()
	if title != "":
		lines.append("主线《%s》共 %d 幕：" % [title, arc.size()])
	else:
		lines.append("主线共 %d 幕：" % arc.size())
	for i in range(arc.size()):
		var a: Dictionary = arc[i]
		var mark := "★" if i == idx else "　"
		lines.append("%s 第 %d 幕（%s）%s —— %s" % [
			mark, i + 1, str(a.get("act", "")), str(a.get("name", "")), str(a.get("beat", "")),
		])
	lines.append("（★ 标出的，就是你这一章要写的那一幕）")

	if not chapter_log.is_empty():
		lines.append("")
		lines.append("已经走过的章节：")
		for entry in chapter_log:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var e: Dictionary = entry
			var ms: Array = e.get("milestones", [])
			var tail := ""
			if not ms.is_empty():
				tail = "（促成 %d 件事）" % ms.size()
			lines.append("  - %s%s" % [str(e.get("title", "")), tail])

	if not milestones.is_empty():
		lines.append("")
		lines.append("玩家在本章已经促成的事：")
		for m in milestones:
			if typeof(m) == TYPE_DICTIONARY:
				lines.append("  - %s" % _milestone_text(m))
	return "\n".join(lines)


## 结局要用的「这一程」小结：做过多少事、走过哪些章节、帮过哪些人
func _journey_block() -> String:
	var lines: PackedStringArray = []
	var recap := _recap_line()
	if recap != "":
		lines.append(recap)
	if not chapter_log.is_empty():
		lines.append("走过的章节：")
		for entry in chapter_log:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			lines.append("  - %s" % str((entry as Dictionary).get("title", "")))
	return "\n".join(lines)


## 一条里程碑的短描述，如「去溪边跑一趟、委托人 阿岩、去了 溪边」
func _milestone_text(m: Dictionary) -> String:
	var title := str(m.get("title", "")).strip_edges()
	var npc := str(m.get("npc", "")).strip_edges()
	var place := str(m.get("place", "")).strip_edges()
	var parts: PackedStringArray = [title]
	if npc != "":
		parts.append("委托人 %s" % npc)
	if place != "":
		parts.append("去了 %s" % place)
	return "、".join(parts)


## 生成终极目标时，告诉模型这个玩家奔的是什么结局（预设或自定义）
func _goal_theme_line() -> String:
	if goal_kind == "custom":
		return "玩家亲口写下的结局是：%s\n他这一整条主线，最后就要走到这个结局上。" % goal_custom.strip_edges()
	return "玩家选定的结局走向是「%s」：%s" % [preset_name(goal_preset), _preset_desc(goal_preset)]


func _user_prompt() -> String:
	var action := str(_ctx.get("action", "chapter"))

	if action == "arc":
		var atext := "请为这位玩家编一条 8 幕的主线。\n\n他亲口写下的结局是：%s\n整条主线的第 8 幕，必须正好走到这个结局上；前七幕要一步步把这件事铺垫出来。\n" % goal_custom.strip_edges()
		if _ctx.has("fix_hint"):
			atext += "\n上一次生成不合格，原因：%s\n请严格按字段要求重新生成一次。" % _ctx["fix_hint"]
		return atext

	if action == "goal":
		var gtext := "请为这个玩家写他的「终极目标」——这一整轮主线最后要去成就的事。\n\n"
		gtext += _goal_theme_line() + "\n"
		gtext += "\n这一程的最后三站会落在这几个地方、由这几个人陪你收尾（都已在世上）：\n%s" % _goal_skeleton_block()
		if _ctx.has("fix_hint"):
			gtext += "\n\n上一次生成不合格，原因：%s\n请严格按字段要求重新生成一次。" % _ctx["fix_hint"]
		return gtext

	if action == "ending":
		var probe := _ending_type_for_player()
		var flavor := {
			"warden": "这个玩家把心思都放在了村里的人身上，和人处得极近。",
			"wanderer": "这个玩家把心思都放在了往外走，走过很多没名字的地方。",
			"bridge": "这个玩家既往外走，也在村里和人处得不错，两边都沾。",
			"hermit": "这个玩家把事都办了，却没和谁走得太近，独来独往。",
			"custom": "这个玩家早就定下了自己想要的结局，别按常理替他收尾。",
		}
		var text := """请为这个玩家写一个「%s」气质的结局。

%s

村子现在的样子：
%s

玩家最近的经历：
%s""" % [
			str(ENDING_NAMES.get(probe, "独行")),
			str(flavor.get(probe, "")),
			_world_block(),
			_recent_block(),
		]
		if probe == "custom":
			text += "\n\n玩家亲口说过的结局是：%s\n这个结局必须写成他说的这个样子，不要另外发挥。" % goal_custom.strip_edges()
		# 把玩家这一程真正做过的事喂进去，让结局落在他自己走过的路上，而不是套模板
		var journey := _journey_block()
		if journey != "":
			text += "\n\n" + journey
		return text

	var req := _requirement_for(int(_ctx.get("chapter", 1)))
	var text := """请写这一章的开头与目标。

这一章里，玩家大致要做到：办成 %d 件事、走出 %d 个没名字的新地方、和村里人处出交情。

村子现在的样子：
%s

玩家最近的经历：
%s""" % [
		int(req["quests_completed"]),
		int(req["new_locations"]),
		_world_block(),
		_recent_block(),
	]
	var gb := goal_block()
	if gb != "":
		text += "\n\n" + gb
	if _ctx.has("fix_hint"):
		text += "\n\n上一次生成不合格，原因：%s\n请严格按字段要求重新生成一次。" % _ctx["fix_hint"]
	return text


func _world_block() -> String:
	var s := WorldState.summary()
	if s == "":
		return "（村子还算太平，没什么大事）"
	return s


func _recent_block() -> String:
	var ev: Array = PlayerProfile.recent_events
	if ev.is_empty():
		return "（玩家刚到村里不久）"
	var lines: PackedStringArray = []
	for e in ev:
		lines.append("- " + str(e))
	return "\n".join(lines)


func _call_llm() -> void:
	_busy = true
	var payload := {
		"model": model,
		"messages": [
			{"role": "system", "content": _system_prompt()},
			{"role": "user", "content": _user_prompt()},
		],
		"temperature": 1.0,
		"response_format": {"type": "json_object"},
	}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + api_key,
	])
	var err := _http.request(
		api_base + "/chat/completions",
		headers,
		HTTPClient.METHOD_POST,
		JSON.stringify(payload)
	)
	if err != OK:
		push_warning("[StoryDirector] 请求发起失败(%d)，回退离线剧情" % err)
		_busy = false
		_fallback()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var detail := body.get_string_from_utf8().left(300)
		push_warning("[StoryDirector] LLM 调用失败(result=%d, code=%d)：%s" % [result, response_code, detail])
		_busy = false
		_fallback()
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		push_warning("[StoryDirector] LLM 返回结构异常，回退离线剧情")
		_busy = false
		_fallback()
		return

	var content := str(parsed["choices"][0]["message"]["content"])
	var data = JSON.parse_string(_extract_json(content))
	if typeof(data) != TYPE_DICTIONARY:
		_retry_or_fallback("模型返回的内容不是合法 JSON 对象")
		return

	var problem := _validation_error(data)
	if problem != "":
		_retry_or_fallback(problem)
		return

	match str(_ctx.get("action", "chapter")):
		"ending":
			_finalize_ending(data)
		"goal":
			_finalize_goal(data)
		"arc":
			_finalize_arc(data)
		_:
			_finalize_chapter(data)


func _retry_or_fallback(reason: String) -> void:
	var attempt := int(_ctx.get("attempt", 0))
	if attempt < MAX_RETRY:
		_ctx["attempt"] = attempt + 1
		_ctx["fix_hint"] = reason
		push_warning("[StoryDirector] 生成不合格（%s），让模型重试一次" % reason)
		_call_llm()
		return
	push_warning("[StoryDirector] 重试仍不合格（%s），回退离线剧情" % reason)
	_busy = false
	_fallback()


func _fallback() -> void:
	match str(_ctx.get("action", "chapter")):
		"ending":
			_finalize_ending(_mock_ending())
		"goal":
			_finalize_goal(_mock_goal())
		"arc":
			_finalize_arc(_mock_arc())
		_:
			_finalize_chapter(_mock_chapter(int(_ctx.get("chapter", chapter))))


## 有的模型会把 JSON 包在 ```json ... ``` 里，这里剥掉
func _extract_json(raw: String) -> String:
	var text := raw.strip_edges()
	if text.begins_with("```"):
		var first_newline := text.find("\n")
		if first_newline != -1:
			text = text.substr(first_newline + 1)
		if text.ends_with("```"):
			text = text.substr(0, text.length() - 3)
	return text.strip_edges()


func _validation_error(data: Dictionary) -> String:
	var action := str(_ctx.get("action", "chapter"))
	if action == "ending":
		if str(data.get("title", "")).strip_edges() == "":
			return "缺少 title 字段"
		if str(data.get("text", "")).strip_edges() == "":
			return "缺少 text 字段"
		return ""
	if action == "goal":
		if str(data.get("name", "")).strip_edges() == "":
			return "缺少 name 字段"
		var raw = data.get("steps", null)
		if typeof(raw) != TYPE_ARRAY:
			return "缺少 steps 数组"
		var raw_steps: Array = raw
		var skel: Array = _ctx.get("skeleton", [])
		if raw_steps.size() != skel.size():
			return "steps 的站数不对（应 %d 站，实 %d 站）" % [skel.size(), raw_steps.size()]
		for i in range(skel.size()):
			if typeof(raw_steps[i]) != TYPE_DICTIONARY:
				return "第 %d 站不是对象" % (i + 1)
			if not _line_is_grounded(str((raw_steps[i] as Dictionary).get("line", "")), skel[i]):
				return "第 %d 站的话没有点出真实存在的地名或人名" % (i + 1)
		return ""
	if action == "arc":
		if str(data.get("title", "")).strip_edges() == "":
			return "缺少 title 字段"
		var raw_acts = data.get("acts", null)
		if typeof(raw_acts) != TYPE_ARRAY:
			return "缺少 acts 数组"
		var acts_list: Array = raw_acts
		if acts_list.size() != MAX_CHAPTERS:
			return "acts 必须是 8 幕（实 %d 幕）" % acts_list.size()
		for i in range(MAX_CHAPTERS):
			if typeof(acts_list[i]) != TYPE_DICTIONARY:
				return "第 %d 幕不是对象" % (i + 1)
			var a: Dictionary = acts_list[i]
			if str(a.get("name", "")).strip_edges() == "":
				return "第 %d 幕缺少 name" % (i + 1)
			if str(a.get("intro", "")).strip_edges() == "":
				return "第 %d 幕缺少 intro" % (i + 1)
			if str(a.get("goal", "")).strip_edges() == "":
				return "第 %d 幕缺少 goal" % (i + 1)
		return ""
	if str(data.get("name", "")).strip_edges() == "":
		return "缺少 name 字段"
	if str(data.get("intro", "")).strip_edges() == "":
		return "缺少 intro 字段"
	if str(data.get("goal", "")).strip_edges() == "":
		return "缺少 goal 字段"
	return ""


# ---------------------------------------------------------------- 存档

func to_save() -> Dictionary:
	return {
		"cycle": cycle,
		"chapter": chapter,
		"chapter_data": chapter_data.duplicate(true),
		"ending": ending.duplicate(true),
		"finished": finished,
		"endings_seen": endings_seen.duplicate(true),
		"goal_kind": goal_kind,
		"goal_preset": goal_preset,
		"goal_custom": goal_custom,
		"arc_key": arc_key,
		"custom_arc": {"title": custom_arc_title, "acts": custom_arc.duplicate(true)},
		"milestones": milestones.duplicate(true),
		"chapter_log": chapter_log.duplicate(true),
		"ultimate_goal": ultimate_goal.duplicate(true),
		"goal_step": goal_step,
	}


## 读档不发信号：读档发生在主场景就绪之前，界面自己在 _ready 里按状态刷新。
func from_save(data: Dictionary) -> void:
	cycle = maxi(1, int(data.get("cycle", 1)))
	chapter = clampi(int(data.get("chapter", 0)), 0, MAX_CHAPTERS)
	finished = bool(data.get("finished", false))
	var cd = data.get("chapter_data", null)
	if typeof(cd) == TYPE_DICTIONARY:
		chapter_data = (cd as Dictionary).duplicate(true)
	else:
		chapter_data = {}
	var e = data.get("ending", null)
	if typeof(e) == TYPE_DICTIONARY:
		ending = (e as Dictionary).duplicate(true)
	else:
		ending = {}
	endings_seen = []
	var list = data.get("endings_seen", [])
	if typeof(list) == TYPE_ARRAY:
		for item in (list as Array):
			if typeof(item) == TYPE_DICTIONARY:
				endings_seen.append(item)
	# 玩家定下的结局：做一次合法性收敛，坏数据/老存档一律当作没设定过
	goal_kind = str(data.get("goal_kind", ""))
	goal_preset = str(data.get("goal_preset", ""))
	goal_custom = str(data.get("goal_custom", "")).strip_edges()
	if goal_kind == "preset":
		if preset_name(goal_preset) == "":
			goal_kind = ""
	elif goal_kind == "custom":
		if goal_custom == "":
			goal_kind = ""
	elif goal_kind != "":
		goal_kind = ""
	if goal_kind != "preset":
		goal_preset = ""
	if goal_kind != "custom":
		goal_custom = ""
	# 主线弧：只认 STORY_ARCS 里的键或 "generic"；坏数据一律置空，交给 lock_arc 按结局重算
	arc_key = str(data.get("arc_key", ""))
	if arc_key != "generic" and not STORY_ARCS.has(arc_key):
		arc_key = ""
	# 自定义主线：逐项校验，坏数据清空（预备时会重新编一条）；
	# 非自定义结局不留这条弧，免得跟预设弧打架。
	custom_arc = []
	custom_arc_title = ""
	if goal_kind == "custom":
		var ca := _sanitize_arc(data.get("custom_arc", null))
		if not ca.is_empty():
			custom_arc_title = str(ca.get("title", ""))
			for a in ca.get("acts", []):
				custom_arc.append(a)
	# 本章里程碑：逐项校验，只收结构完整的条目
	milestones = []
	var ms_list = data.get("milestones", [])
	if typeof(ms_list) == TYPE_ARRAY:
		for item in (ms_list as Array):
			if typeof(item) == TYPE_DICTIONARY and str((item as Dictionary).get("title", "")).strip_edges() != "":
				milestones.append((item as Dictionary).duplicate(true))
	# 章节回顾：同样逐项校验
	chapter_log = []
	var log_list = data.get("chapter_log", [])
	if typeof(log_list) == TYPE_ARRAY:
		for item in (log_list as Array):
			if typeof(item) == TYPE_DICTIONARY:
				chapter_log.append((item as Dictionary).duplicate(true))
	while chapter_log.size() > CHAPTER_LOG_KEEP:
		chapter_log.remove_at(0)
	# 终极目标：逐项校验；地点必须真的还在世上（读档顺序保证 WorldData 已就绪），
	# 坏数据一律当作没有终极目标，交给 boot/lock_arc 重新算。
	ultimate_goal = _sanitize_ultimate(data.get("ultimate_goal", null))
	goal_step = clampi(int(data.get("goal_step", 0)), 0, maxi(0, ultimate_steps().size()))


## 校验存档里的终极目标：类型、名字、每一站的地点/人名是否还站得住
func _sanitize_ultimate(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = raw
	var type_id := str(d.get("type", ""))
	var name := str(d.get("name", "")).strip_edges()
	if name == "" or not (ULTIMATE_TEMPLATES.has(type_id) or type_id == "custom"):
		return {}
	var raw_steps = d.get("steps", null)
	if typeof(raw_steps) != TYPE_ARRAY:
		return {}
	var steps: Array = []
	for item in (raw_steps as Array):
		if typeof(item) != TYPE_DICTIONARY:
			return {}
		var s: Dictionary = item
		var lid := str(s.get("location_id", ""))
		if lid == "" or not WorldData.has_id(lid):
			return {}
		var who := str(s.get("npc_name", ""))
		steps.append({
			"no": int(s.get("no", steps.size() + 1)),
			"name": str(s.get("name", "")),
			"line": str(s.get("line", "")),
			"location_id": lid,
			"location_name": str(s.get("location_name", "")),
			"location_kind": str(s.get("location_kind", "")),
			"direction": str(s.get("direction", "")),
			"distance_m": int(s.get("distance_m", 0)),
			"npc_name": who,
			"npc_role": str(s.get("npc_role", "")),
			"done": bool(s.get("done", who == "")),
			"talk_base": int(s.get("talk_base", 0)),
		})
	if steps.is_empty():
		return {}
	return {
		"type": type_id,
		"name": name,
		"desc": str(d.get("desc", "")),
		"steps": steps,
	}
