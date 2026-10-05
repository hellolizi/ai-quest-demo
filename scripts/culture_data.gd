extends Node
## 文化圈数据（Autoload 名字：CultureData）
##
## 世界里有好几个「文化圈」：每个文化圈有自己的主城、建筑风格、配色、语言、世界观，
## 以及一套对应的基础地点和乡亲。新游戏时随机落在一个文化圈里出生，
## 所以每个玩家的出生地、初始剧情、身边的人都不一样。
##
## 语言：不同文化圈说的话不一样。玩家听不懂外语时，台词会显示成外语原文；
## 想听懂有两条路——跟当地人学（学 3 次掌握），或者用「通译符」道具；
## 通译符还能转赠给别人，让别人也能听懂你的话。
##
## 家的 id 固定是 "village"、坐标固定 (0,0)，这样地图/寻路的既有逻辑无需改动；
## 变的只是它的名字、样子、住的人和说的话。

## 主城的固定 id（WorldData / world_map / quest_manager 等多处按这个 id 找「家」）
const HOME_ID := "village"

## 当前所在的文化圈 id
var current_id := "qingshi"

## 各类地点在地名末尾用的通名（区域化生成拼名字用）
const KIND_SUFFIX := {
	"village": ["村", "屯", "坞", "寨"],
	"mine": ["矿洞", "矿窟", "古矿"],
	"shrine": ["小庙", "神祠", "古刹"],
	"forest": ["森林", "密林", "林地"],
	"ruin": ["废坊", "遗迹", "荒村"],
	"bridge": ["石桥", "木桥", "栈桥"],
	"camp": ["贼窝", "营寨", "匪寨", "据点"],
	# city 不在各文化圈的 kinds 里——AI 不会直接生成城市，
	# 城市是村子恰好落在平原上时升级出来的（见 LocationGenerator._finalize）。
	"city": ["城", "镇", "邑", "府"],
}

var _rng := RandomNumberGenerator.new()

var CULTURES: Dictionary = {
	"qingshi": {
		"id": "qingshi",
		"name": "青石村",
		"realm": "中原山村",
		"style": "依山而建的中原山村，青瓦木梁、飞檐翘角，院墙用青石垒成。",
		"roof": "curved",
		"dress": "头戴竹编斗笠或插木簪束发，靛蓝或青色粗布交领短衫，腰间系麻绳、挂火镰，下着绑腿长裤，脚穿草鞋。",
		"language": "zhongyuan",
		"language_name": "中原话",
		"script": "山川云石林木风火水土金木水火土天地日月星辰江河湖海花鸟鱼虫刀剑斧锤耕读渔猎村路桥庙矿林桑麻粟麦米酒茶药春秋冬夏东南西北高低远近",
		"worldview": "一个叫「青石村」的宁静小村庄，四面环山，村人靠采矿、采药和打猎为生，说话慢条斯理，最重人情。",
		"palette": {
			"grass": Color(0.16, 0.24, 0.17), "path": Color(0.35, 0.29, 0.20),
			"tree": Color(0.13, 0.34, 0.19), "tree_dark": Color(0.10, 0.26, 0.15),
			"trunk": Color(0.28, 0.20, 0.13), "rock": Color(0.36, 0.37, 0.36),
			"rock_dark": Color(0.24, 0.25, 0.25), "house": Color(0.46, 0.35, 0.25),
			"roof": Color(0.55, 0.24, 0.18), "cave": Color(0.05, 0.05, 0.06),
			"deck": Color(0.42, 0.32, 0.22), "shrine": Color(0.52, 0.20, 0.18),
		},
		"spawn": Vector2(0, 40),
		"home_sites": [
			{"id": "village", "name": "青石村", "kind": "village", "desc": "村子中心，铁匠和村长都住在这里。"},
			{"id": "mine", "name": "北岭矿洞", "kind": "mine", "desc": "村子正北面山脚下的矿洞，传闻深处有会发光的矿石。"},
			{"id": "shrine", "name": "山腰小庙", "kind": "shrine", "desc": "半山腰上无人打理的小庙，药师常来这里采药。"},
			{"id": "forest", "name": "幽影森林", "kind": "forest", "desc": "村子东边的密林，白天也显得昏暗，猎户常在此出没。"},
			{"id": "mill", "name": "废弃磨坊", "kind": "ruin", "desc": "村子西边多年无人使用的磨坊，风车早已停转。"},
			{"id": "bridge", "name": "断石桥", "kind": "bridge", "desc": "村子南边横跨溪流的旧石桥，夜里常有人听见水声里的动静。"},
		],
		"kinds": ["village", "mine", "shrine", "forest", "ruin", "bridge"],
		"name_words": ["青石", "幽影", "北岭", "断石", "落霞", "石泉"],
		"npcs": [
			{
				"name": "铁匠 老张", "role": "村里唯一的铁匠",
				"personality": "直来直去、话少，三句不离打铁；嘴上不饶人，其实是个热心肠。",
				"greetings": ["哟，又是你。站远点，火星子烫人。", "炉子刚生上，有事快说。", "这铁得趁热打，话也一样，有啥说啥。", "打铁没巧劲，全凭一锤一锤砸出来。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "村长 阿婆", "role": "见多识广的老村长",
				"personality": "温和絮叨，把全村人都当自家孩子，一说起村子的事就停不下来。",
				"greetings": ["孩子，慢点儿走，别摔着。", "来来，坐。村里的事啊，奶奶说上一天都说不完。", "这村子看着小，底下的故事三天三夜说不完。", "出门在外，先把肚子填饱，别的都好说。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "猎户 铁蛋", "role": "常年待在林子里的猎户",
				"personality": "沉默警惕，习惯独来独往，惜字如金，但说出口的都是要紧话。",
				"greetings": ["……（他扫了你一眼，点了点头）", "林子里的东西，不是谁都看得懂。", "上山不带火折子，等于送死。", "……你说，我听着。"],
				"offset": Vector2(1200, -40),
			},
			{
				"name": "药师 素问", "role": "上山采药的药师",
				"personality": "文静克制、慢条斯理，喜欢拿药草打比方，说话留有余地。",
				"greetings": ["你气色不错，看来最近没少走动。", "有些病啊，急不得，得慢慢养——人也是一样。", "药有药性，人有脾性，都得顺着来。", "你先坐会儿，我把这剂药分好再说。"],
				"offset": Vector2(980, -690),
			},
		],
	},
	"anvil": {
		"id": "anvil",
		"name": "铁砧镇",
		"realm": "西陲石堡",
		"style": "一座石墙高筑的边境小镇，尖顶陡坡屋顶、灰石外墙，铁匠铺的炉火终日不熄。",
		"roof": "gable",
		"dress": "粗皮护肩配灰褐粗布短打，胸前围一条沾着煤灰的铁匠皮围裙，腰系宽皮带挂铁钳，脚蹬厚底皮靴。",
		"language": "anvil",
		"language_name": "铁砧话",
		"script": "abcdefghijklmnopqrstuvwxyz",
		"worldview": "一座叫「铁砧镇」的边境石堡小镇，靠锻铁与商路贸易立镇，镇上人说话直来直去，认理认账。",
		"palette": {
			"grass": Color(0.20, 0.26, 0.20), "path": Color(0.40, 0.37, 0.32),
			"tree": Color(0.16, 0.32, 0.22), "tree_dark": Color(0.11, 0.24, 0.16),
			"trunk": Color(0.30, 0.24, 0.18), "rock": Color(0.44, 0.44, 0.46),
			"rock_dark": Color(0.28, 0.29, 0.31), "house": Color(0.50, 0.48, 0.45),
			"roof": Color(0.33, 0.34, 0.42), "cave": Color(0.05, 0.05, 0.06),
			"deck": Color(0.44, 0.40, 0.34), "shrine": Color(0.42, 0.42, 0.50),
		},
		"spawn": Vector2(0, 50),
		"home_sites": [
			{"id": "village", "name": "铁砧镇", "kind": "village", "desc": "镇子广场，铁匠铺和镇务所都在这儿。"},
			{"id": "mine", "name": "黑岩矿坑", "kind": "mine", "desc": "镇北黑岩山下的老矿坑，越挖越深，据说底下有富铁矿脉。"},
			{"id": "shrine", "name": "石像礼拜堂", "kind": "shrine", "desc": "半山上的一座石像礼拜堂，石匠们路过都会进去歇脚祈祷。"},
			{"id": "forest", "name": "灰桦林", "kind": "forest", "desc": "镇西的灰桦林，木料供全镇盖房与烧炭。"},
			{"id": "mill", "name": "废弃锯木场", "kind": "ruin", "desc": "镇东废弃的锯木场，水车早已停转，只剩满地木屑。"},
			{"id": "bridge", "name": "老石拱桥", "kind": "bridge", "desc": "镇南横跨急流的石拱桥，桥栏上刻满了过路旅人的名字。"},
		],
		"kinds": ["village", "mine", "ruin", "shrine", "bridge"],
		"name_words": ["铁砧", "炉火", "煤岭", "锤山", "焦土", "铁桥"],
		"npcs": [
			{
				"name": "铁匠 汉斯", "role": "镇上唯一还掌着大炉的铁匠",
				"personality": "嗓门大、性子急，干活利落；认死理，可对熟人掏心掏肺。",
				"greetings": ["嘿！站远些，火星子可不长眼。", "要打什么，直说，别磨蹭。", "铁得趁热打，人也得趁热说事。", "这把锤子跟了我二十年，比你懂事。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "镇长 玛尔塔", "role": "铁砧镇的镇长",
				"personality": "威严沉稳、说话算数，张口闭口都是镇子的规矩、账目和商路。",
				"greetings": ["欢迎来到铁砧镇，先把靴子上的泥跺干净。", "镇子能撑到今天，靠的是规矩，不是运气。", "商队一来，账就得算清楚，疏忽不得。", "你若是路过，就多留两日，镇上缺人手。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "猎人 卡尔", "role": "常年进山的猎人",
				"personality": "沉默寡言、警觉，习惯一个人待着，但认路一流。",
				"greetings": ["……（他抬了抬下巴，算是打过招呼）", "山里的路，走一次就记住。", "别踩断枝，会把东西引过来。", "你要走远路？跟紧我。"],
				"offset": Vector2(1080, -40),
			},
			{
				"name": "草药师 莉娜", "role": "采药的草药师",
				"personality": "文静爱皱眉，凡事讲证据，喜欢拿草药的性子打比方。",
				"greetings": ["你脸色发白，走的路不少吧。", "草有草性，人有脾性，急不来。", "这味药得晒足七天，少一天都不成。", "先坐下，我把药分好再听你说。"],
				"offset": Vector2(960, -680),
			},
		],
	},
	"dune": {
		"id": "dune",
		"name": "沙丘驿站",
		"realm": "流沙商道",
		"style": "一片土黄圆顶的沙漠驿站，夯土墙、圆顶、厚檐，为的是挡住风沙与烈日。",
		"roof": "dome",
		"dress": "土黄或月白的长袍裹身，头缠同色头巾、巾尾遮住口鼻挡沙，腰缠宽布带，脚穿软底布靴。",
		"language": "dune",
		"language_name": "沙语",
		"script": "абвгдежзийклмнопрстуфхцчшщыэюя",
		"worldview": "一座叫「沙丘驿站」的沙漠商旅驿站，靠一口水井和驼队生意过活，商队来来往往，谁都不多问谁的来路。",
		"palette": {
			"grass": Color(0.52, 0.44, 0.28), "path": Color(0.60, 0.50, 0.32),
			"tree": Color(0.34, 0.38, 0.22), "tree_dark": Color(0.24, 0.28, 0.16),
			"trunk": Color(0.40, 0.32, 0.20), "rock": Color(0.55, 0.48, 0.36),
			"rock_dark": Color(0.40, 0.34, 0.25), "house": Color(0.62, 0.52, 0.36),
			"roof": Color(0.50, 0.36, 0.24), "cave": Color(0.10, 0.08, 0.06),
			"deck": Color(0.55, 0.44, 0.30), "shrine": Color(0.58, 0.44, 0.30),
		},
		"spawn": Vector2(0, 60),
		"home_sites": [
			{"id": "village", "name": "沙丘驿站", "kind": "village", "desc": "驿站的水井边，驼队和旅人都在这儿歇脚。"},
			{"id": "mine", "name": "盐晶洞窟", "kind": "mine", "desc": "驿站西边的盐晶洞，洞壁的结晶在日光下泛着白光。"},
			{"id": "shrine", "name": "风神石堆", "kind": "shrine", "desc": "沙丘顶上的风神石堆，牧人路过都会添一块石头。"},
			{"id": "forest", "name": "枯胡杨林", "kind": "forest", "desc": "驿站东边的枯胡杨林，是方圆百里唯一还有点绿意的地方。"},
			{"id": "mill", "name": "废弃水车坊", "kind": "ruin", "desc": "驿站西边废弃的水车坊，井水干涸后就再没转过。"},
			{"id": "bridge", "name": "流沙木桥", "kind": "bridge", "desc": "驿站南边横跨干河沟的旧木桥，桥板踩上去咯吱作响。"},
		],
		"kinds": ["village", "mine", "ruin", "shrine", "bridge"],
		"name_words": ["沙丘", "风蚀", "孤驼", "黄沙", "尘鸣", "干河"],
		"npcs": [
			{
				"name": "驼夫 阿岩", "role": "驿站的老驼夫",
				"personality": "豪爽健谈，走南闯北见得多，一说起沙漠里的路就滔滔不绝。",
				"greetings": ["来来来，先喝口水，沙子里走一天了。", "这条道我闭着眼都能走，就是风向刁钻。", "驼队明早出发，你搭不搭一程？", "沙漠里的规矩就一条：别离水井太远。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "泉眼主 娜仁", "role": "守着水井的驿站长",
				"personality": "精明泼辣、说一不二，井水就是她的命根子。",
				"greetings": ["水是命，先记着这条。", "旅人来了就歇，账回头再算。", "谁要是往井里丢东西，我可不答应。", "你要往深处走？先把水囊灌满。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "猎手 巴图", "role": "沙丘里的猎手",
				"personality": "寡言冷峻，认得风沙里的每一种痕迹。",
				"greetings": ["……（他眯眼看了看你来的方向）", "风要变了，早点回。", "沙上这道印，是昨夜过的狼。", "跟着我的脚印走，别乱踩。"],
				"offset": Vector2(1100, -40),
			},
			{
				"name": "草药婆 其其格", "role": "熬药的草药婆",
				"personality": "慢悠悠、神神叨叨，总说草药比人更懂道理。",
				"greetings": ["你看这草，晒了三日就服软了。", "人急，火就旺，药就熬糊了。", "坐下歇歇，我给你熬一碗解乏的。", "草知道的事，比你以为的多。"],
				"offset": Vector2(950, -700),
			},
		],
	},
	"isles": {
		"id": "isles",
		"name": "潮汐渔港",
		"realm": "东海群岛",
		"style": "依海而立的渔村，茅草屋顶、木桩高脚屋，门前的跳板随潮水涨落，海风里全是咸味。",
		"roof": "thatch",
		"dress": "靛蓝或月白的粗布短褂、裤脚高高卷起，腰间缠一段渔网绳挂鱼钩，头系布巾，赤脚或趿木屐。",
		"language": "isler",
		"language_name": "汐岛语",
		"script": "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん",
		"worldview": "一个叫「潮汐渔港」的海岛渔村，靠打鱼、采珠与晒盐过活，岛民看天吃饭、以海为神，说话都带着潮声的起伏。",
		"palette": {
			"grass": Color(0.18, 0.30, 0.28), "path": Color(0.46, 0.42, 0.34),
			"tree": Color(0.14, 0.36, 0.28), "tree_dark": Color(0.10, 0.27, 0.21),
			"trunk": Color(0.32, 0.24, 0.16), "rock": Color(0.42, 0.44, 0.44),
			"rock_dark": Color(0.28, 0.30, 0.31), "house": Color(0.60, 0.52, 0.38),
			"roof": Color(0.52, 0.42, 0.26), "cave": Color(0.06, 0.07, 0.08),
			"deck": Color(0.50, 0.40, 0.28), "shrine": Color(0.40, 0.30, 0.36),
		},
		"spawn": Vector2(0, 45),
		"home_sites": [
			{"id": "village", "name": "潮汐渔港", "kind": "village", "desc": "港湾边的村子，渔船和晒网架都停在这儿。"},
			{"id": "mine", "name": "海蚀矿洞", "kind": "mine", "desc": "岛北崖壁下的海蚀洞，涨潮时灌进海水，退潮才进得去。"},
			{"id": "shrine", "name": "海神祠", "kind": "shrine", "desc": "崖顶的小海神祠，出海前岛民都来敬一炷香。"},
			{"id": "forest", "name": "红树林", "kind": "forest", "desc": "村子东边的红树林，根须泡在浅滩里，是掏蟹摸螺的好去处。"},
			{"id": "mill", "name": "废弃渔坊", "kind": "ruin", "desc": "村子西边废弃的渔坊，鱼干架还立着，却再没人来晒鱼。"},
			{"id": "bridge", "name": "木栈桥", "kind": "bridge", "desc": "村子南边伸进海里的木栈桥，夜里浪打上来，木板咯吱作响。"},
		],
		"kinds": ["village", "bridge", "ruin", "shrine", "forest"],
		"name_words": ["潮汐", "盐风", "渔火", "浪礁", "归舸", "海雾"],
		"npcs": [
			{
				"name": "渔夫 阿海", "role": "村里的老渔夫",
				"personality": "嗓门洪亮、性子直，一张口就是潮汐、风向和鱼群，笑起来像浪拍礁石。",
				"greetings": ["哟，赶上涨潮了？搭把手收网！", "今天的风不对，鱼都沉底喽。", "海这东西，你敬它三分，它让你三分。", "走，跟我出海，让你见识见识什么叫浪。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "岛主 阿婆金", "role": "管着港口的岛主",
				"personality": "精明泼辣、嗓门大，把整座岛的船和人头都记在心里，做事干脆。",
				"greetings": ["外乡人？我们不问来路，只问你会不会晕船。", "这港口的规矩就一条：出海前先拜海神。", "岛小，事多，谁家的网破了都来找我。", "你若要留，先帮我数数今早回来的船。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "采珠人 阿汐", "role": "潜海采珠的姑娘",
				"personality": "沉默利落、眼神清亮，憋气比谁都久，说起海底的事眼睛发亮。",
				"greetings": ["……（她甩了甩湿发，冲你点点头）", "海底比岸上安静，也比岸上危险。", "红树林那边的水，你别乱蹚。", "你下过水吗？深吸一口气，跟着我。"],
				"offset": Vector2(1200, -40),
			},
			{
				"name": "海药婆 阿婆螺", "role": "用海草海贝配药的老太",
				"personality": "慢条斯理、神神叨叨，说海里的东西才最懂治人的道理。",
				"greetings": ["你脚底沾了海腥气，是不是走远路了？", "海草泡三日，发了才好入药。", "急什么，潮水都是慢慢涨的。", "坐，我给你熬一碗去湿的汤。"],
				"offset": Vector2(950, -690),
			},
		],
	},
	"frost": {
		"id": "frost",
		"name": "霜牙雪堡",
		"realm": "北境雪原",
		"style": "高耸尖顶的石砌雪堡，陡峭的尖塔与厚重的石墙，为的是不让积雪把屋顶压塌。",
		"roof": "spire",
		"dress": "厚重毛皮披风与护耳皮帽，内衬深蓝厚绒衣，脖子裹紧围巾，手戴皮手套，脚蹬毛边长靴。",
		"language": "frost",
		"language_name": "霜国语",
		"script": "αβγδεζηθικλμνξοπρστυφχψω",
		"worldview": "一座叫「霜牙雪堡」的北境石堡，长冬无夏，靠围猎、采矿与守着山口要道过活，堡里人寡言、守约、耐得住寒。",
		"palette": {
			"grass": Color(0.72, 0.78, 0.82), "path": Color(0.55, 0.58, 0.62),
			"tree": Color(0.16, 0.28, 0.26), "tree_dark": Color(0.11, 0.20, 0.19),
			"trunk": Color(0.30, 0.24, 0.20), "rock": Color(0.52, 0.56, 0.60),
			"rock_dark": Color(0.36, 0.40, 0.44), "house": Color(0.58, 0.60, 0.64),
			"roof": Color(0.30, 0.36, 0.48), "cave": Color(0.06, 0.08, 0.11),
			"deck": Color(0.48, 0.50, 0.54), "shrine": Color(0.44, 0.50, 0.62),
		},
		"spawn": Vector2(0, 55),
		"home_sites": [
			{"id": "village", "name": "霜牙雪堡", "kind": "village", "desc": "堡子的中心广场，熔炉和堡务厅都在这儿。"},
			{"id": "mine", "name": "冰晶矿坑", "kind": "mine", "desc": "堡北冻土下的矿坑，越往里越冷，据说埋着会发光的冰晶。"},
			{"id": "shrine", "name": "霜神祭坛", "kind": "shrine", "desc": "半山上的霜神祭坛，猎人进山前都会来默祷片刻。"},
			{"id": "forest", "name": "黑杉林", "kind": "forest", "desc": "堡东的黑杉林，枝叶压着积雪，是堡里过冬的柴火来源。"},
			{"id": "mill", "name": "废弃猎屋", "kind": "ruin", "desc": "堡西废弃的猎屋，屋顶塌了一角，屋里的柴还码得整整齐齐。"},
			{"id": "bridge", "name": "冰河石桥", "kind": "bridge", "desc": "堡南横跨冰河的石桥，桥面常年结着一层薄冰。"},
		],
		"kinds": ["village", "mine", "ruin", "shrine", "forest"],
		"name_words": ["霜牙", "冰封", "雪岭", "寒潭", "白桦", "冻湖"],
		"npcs": [
			{
				"name": "铸剑师 奥拉夫", "role": "守着熔炉的铸剑师",
				"personality": "寡言沉稳、手上全是烫疤，认定一件事就闷头做到底。",
				"greetings": ["……离炉子近点，冻不坏你。", "铁要趁冷淬，人要趁静想。", "这活计急不得，一锤错全废。", "有事说，我手上停不下来。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "堡主 斯诺里", "role": "守山口的雪堡堡主",
				"personality": "威严克制、惜字如金，张口就是山口、粮草与人手。",
				"greetings": ["进了堡子，就是堡子的人。", "长冬难熬，靠的是粮和人心。", "山口那边不太平，别一个人去。", "要留下就多帮着劈点柴。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "猎手 芬", "role": "雪原上的独行猎手",
				"personality": "沉默警觉、来去无声，能在雪地上认出一夜前的足迹。",
				"greetings": ["……（他哈出一口白气，偏头看你）", "雪把脚印盖住，命就靠鼻子找。", "别踩雪檐，底下是空的。", "跟我走，踩我踩过的地方。"],
				"offset": Vector2(1160, -40),
			},
			{
				"name": "草药师 伊尔玛", "role": "取暖棚里配药的草药师",
				"personality": "文静耐烦、凡事讲个火候，喜欢拿熬药比作过日子。",
				"greetings": ["手这么凉，进来烤烤火。", "药得慢熬，日子也得慢过。", "你鼻尖冻红了，先喝口热的。", "坐近点，别让火灭了。"],
				"offset": Vector2(940, -720),
			},
		],
	},
	"steppe": {
		"id": "steppe",
		"name": "长风牧原",
		"realm": "万里草原",
		"style": "逐水草而居的游牧营盘，四坡平缓的毡顶搭在木架上，好拆好搬，风一吹就是一整天。",
		"roof": "hip",
		"dress": "宽大开襟长袍配绣花彩边腰带，肩搭皮袄、头戴尖顶毡帽，脚蹬高筒皮靴，腰间挂着马刀。",
		"language": "steppe",
		"language_name": "长风语",
		"script": "ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎㅏㅑㅓㅕㅗㅛㅜㅠㅡㅣ",
		"worldview": "一个叫「长风牧原」的草原营盘，靠放牧、换马和盐湖取盐过活，牧人豪爽好客、敬天敬祖宗，走到哪儿都当自家人。",
		"palette": {
			"grass": Color(0.42, 0.44, 0.24), "path": Color(0.54, 0.48, 0.30),
			"tree": Color(0.26, 0.34, 0.18), "tree_dark": Color(0.19, 0.26, 0.13),
			"trunk": Color(0.36, 0.28, 0.18), "rock": Color(0.50, 0.46, 0.36),
			"rock_dark": Color(0.36, 0.33, 0.26), "house": Color(0.60, 0.54, 0.40),
			"roof": Color(0.50, 0.44, 0.30), "cave": Color(0.08, 0.07, 0.06),
			"deck": Color(0.52, 0.46, 0.32), "shrine": Color(0.56, 0.48, 0.34),
		},
		"spawn": Vector2(0, 50),
		"home_sites": [
			{"id": "village", "name": "长风牧原", "kind": "village", "desc": "营盘中央的篝火地，牧人换马议事都在这儿。"},
			{"id": "mine", "name": "盐湖矿场", "kind": "mine", "desc": "营盘北边盐湖旁的取盐场，白花花的盐堆得像小丘。"},
			{"id": "shrine", "name": "长生石堆", "kind": "shrine", "desc": "高岗上的长生石堆，每块石头都是一次祈愿，骑手路过必添一块。"},
			{"id": "forest", "name": "河谷柳林", "kind": "forest", "desc": "营盘东边河谷里的柳林，是放牧歇脚、饮马打水的地方。"},
			{"id": "mill", "name": "废弃羊栏", "kind": "ruin", "desc": "营盘西边废弃的羊栏，木栅倒了一半，风从缝里呜呜地过。"},
			{"id": "bridge", "name": "草原木桥", "kind": "bridge", "desc": "营盘南边横跨浅河的旧木桥，过桥就是更远的牧场。"},
		],
		"kinds": ["village", "shrine", "ruin", "bridge", "forest"],
		"name_words": ["长风", "牧原", "苍狼", "野马", "天苍", "草海"],
		"npcs": [
			{
				"name": "牧人 巴特尔", "role": "看管马群的牧人",
				"personality": "豪爽爱笑、嗓门大，一开口就是马、草场和天气。",
				"greetings": ["来得好！先喝碗马奶酒暖暖。", "今年的草长得好，马都养膘了。", "看那匹黑马没有？方圆百里再找不出第二匹。", "你要赶远路？跟我挑匹马。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "长者 额吉", "role": "牧原上最年长的长者",
				"personality": "慈祥沉静、见多识广，说起祖辈传下的规矩就停不下来。",
				"greetings": ["孩子，坐下歇歇脚。", "咱们牧人的规矩，是祖辈用命换来的。", "风往哪儿吹，草就往哪儿长——人也一样。", "留一晚吧，篝火边的话最好听。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "猎手 苏赫", "role": "猎狼的草原猎手",
				"personality": "寡言利落、眼尖手稳，认得草原上每一声鸟叫的含义。",
				"greetings": ["……（他勒住马，上下打量你）", "狼要来了，夜里别离羊群太远。", "那道烟不是好兆头，绕开走。", "上马，我带你抄近路。"],
				"offset": Vector2(1140, -40),
			},
			{
				"name": "巫医 其其格", "role": "熬奶药看病的巫医",
				"personality": "慢悠悠、半是医生半是祭司，总说药和天时讲究的是缘分。",
				"greetings": ["你气色发虚，赶路赶急了吧。", "药引子得配天时，急不来。", "坐下，我一口一口喂你。", "先把这碗热汤喝了，再说别的。"],
				"offset": Vector2(940, -700),
			},
		],
	},
	"sky": {
		"id": "sky",
		"name": "云上浮空城",
		"realm": "云端浮岛",
		"style": "悬于云端的浮空石城，水晶尖顶簇拥着白石台基，靠风与光维系，低头便是无尽的云海。",
		"roof": "crystal",
		"dress": "素白与浅紫的层叠长袍，衣料泛着微光，袖口领缘镶银线，外披半透薄纱斗篷，戴水晶额饰。",
		"language": "sky",
		"language_name": "云顶语",
		"script": "अआइईउऊएऐओऔकखगघचछजझटठडढतथदधनपफबभमयरलवशषसह",
		"worldview": "一座叫「云上浮空城」的悬空之城，靠汲取风与光为生，城民清冷骄傲、崇尚秩序与技艺，把地面上的人称作「足下之人」。",
		"palette": {
			"grass": Color(0.44, 0.52, 0.62), "path": Color(0.66, 0.68, 0.76),
			"tree": Color(0.30, 0.46, 0.52), "tree_dark": Color(0.22, 0.36, 0.44),
			"trunk": Color(0.42, 0.38, 0.44), "rock": Color(0.66, 0.68, 0.74),
			"rock_dark": Color(0.50, 0.52, 0.60), "house": Color(0.78, 0.78, 0.84),
			"roof": Color(0.56, 0.50, 0.74), "cave": Color(0.10, 0.11, 0.16),
			"deck": Color(0.70, 0.70, 0.76), "shrine": Color(0.62, 0.56, 0.78),
		},
		"spawn": Vector2(0, 45),
		"home_sites": [
			{"id": "village", "name": "云上浮空城", "kind": "village", "desc": "浮岛的中央广场，晶塔与风语台都耸立在这儿。"},
			{"id": "mine", "name": "星尘矿窟", "kind": "mine", "desc": "浮岛底部的星尘矿窟，凿下来的碎石会在夜里微微发亮。"},
			{"id": "shrine", "name": "光之神殿", "kind": "shrine", "desc": "岛顶的光之神殿，四面通透，日光穿过晶壁洒下一地虹彩。"},
			{"id": "forest", "name": "浮空林", "kind": "forest", "desc": "岛东的浮空林，树根悬在云上，叶子随风朝同一个方向梳。"},
			{"id": "mill", "name": "废弃风车台", "kind": "ruin", "desc": "岛西废弃的风车台，扇叶断了一片，还在吱呀地空转。"},
			{"id": "bridge", "name": "虹桥", "kind": "bridge", "desc": "岛南连接另一块浮石的虹桥，桥下就是万丈云海。"},
		],
		"kinds": ["village", "shrine", "ruin", "bridge"],
		"name_words": ["云上", "浮光", "星穹", "风语", "虚白", "天阶"],
		"npcs": [
			{
				"name": "铸晶师 莱恩", "role": "给晶塔塑形的铸晶师",
				"personality": "清冷专注、讲究分寸，眼里容不下半点歪斜，说话像在念公式。",
				"greetings": ["站稳，你踩到晶脉了。", "晶塔的角度差一分，整座城就偏一分。", "风从东来，今天不适合铸晶。", "你有什么事？简短些，我的手不能停。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "城主 薇拉", "role": "统领浮空城的城主",
				"personality": "骄傲克制、条理分明，把城的秩序看得比什么都重。",
				"greetings": ["你从地面来？抬头看看，这才是世界该有的样子。", "浮空城能悬着，靠的是规矩，不是侥幸。", "风与光都要计着用，一寸也浪费不得。", "既然来了，就学着守我们的秩序。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "云猎手 凯尔", "role": "在云海间狩猎的猎手",
				"personality": "沉默孤高、动作轻得像风，习惯了独来独往。",
				"greetings": ["……（他立在桥边，没回头）", "云底下不全是空的，有些东西会往上飘。", "别靠桥栏太近，风会推你。", "跟着我的步子，别看脚下。"],
				"offset": Vector2(1200, -40),
			},
			{
				"name": "医师 瑟琳", "role": "研究晶露的医师",
				"personality": "细致冷静、凡事要个原理，喜欢拿矿物与晶体打比方。",
				"greetings": ["你的脉搏偏快，是恐高吧。", "晶体要多纯才透光，人也要多静才安宁。", "这味药得避光存着，见光就失了性。", "坐下，我先看看你的气色。"],
				"offset": Vector2(950, -720),
			},
		],
	},
	"ember": {
		"id": "ember",
		"name": "熔岩熔炉",
		"realm": "地底熔岩",
		"style": "地底熔岩间的锻炉城，平顶厚墙顶着铁铸的穹架，炉火把岩壁烤得通红，空气里都是铁与火的味道。",
		"roof": "flat",
		"dress": "深色厚皮围裙与金属护臂，赤膊或穿背心、外罩一层耐火披肩，腰系挂满铁锤的宽工具带，脚穿铁头厚靴。",
		"language": "ember",
		"language_name": "熔炉语",
		"script": "ابتثجحخدذرزسشصضطظعغفقكلمنهوي",
		"worldview": "一座叫「熔岩熔炉」的地底锻炉城，靠开采熔铁与锻造兵器过活，城民粗豪实诚、认手艺认力气，谁的锤子响谁就说话算数。",
		"palette": {
			"grass": Color(0.20, 0.14, 0.12), "path": Color(0.34, 0.24, 0.20),
			"tree": Color(0.24, 0.18, 0.14), "tree_dark": Color(0.16, 0.12, 0.10),
			"trunk": Color(0.22, 0.16, 0.13), "rock": Color(0.30, 0.24, 0.22),
			"rock_dark": Color(0.18, 0.14, 0.13), "house": Color(0.34, 0.28, 0.26),
			"roof": Color(0.44, 0.22, 0.14), "cave": Color(0.08, 0.05, 0.05),
			"deck": Color(0.36, 0.28, 0.24), "shrine": Color(0.58, 0.26, 0.14),
		},
		"spawn": Vector2(0, 50),
		"home_sites": [
			{"id": "village", "name": "熔岩熔炉", "kind": "village", "desc": "炉城中央的大炉台，锻锤声和火光从不停歇。"},
			{"id": "mine", "name": "熔铁矿坑", "kind": "mine", "desc": "城北的熔铁矿坑，岩浆的余温把矿脉烘得发红，采一块烫一块。"},
			{"id": "shrine", "name": "炉神神龛", "kind": "shrine", "desc": "岩壁凿出的炉神神龛，龛前一盏长明火，从没熄过。"},
			{"id": "forest", "name": "灰烬林", "kind": "forest", "desc": "城东的灰烬林，树是烧焦的化石木，枝干漆黑，却仍立得笔直。"},
			{"id": "mill", "name": "废弃熔炉", "kind": "ruin", "desc": "城西废弃的熔炉，炉膛早已冷透，只剩一地炉渣。"},
			{"id": "bridge", "name": "熔岩石桥", "kind": "bridge", "desc": "城南横跨岩浆沟的石桥，桥面被烤得发烫，走上去得小跑。"},
		],
		"kinds": ["village", "mine", "ruin", "bridge"],
		"name_words": ["熔岩", "炉心", "炎脊", "赤炭", "焦岩", "火谷"],
		"npcs": [
			{
				"name": "大匠 格罗姆", "role": "掌着大炉的锻主",
				"personality": "粗豪爽直、力气大嗓门也大，认手艺认力气，最看不上磨磨蹭蹭。",
				"greetings": ["站远点！这铁水可不管你是谁。", "有什么活？直说，别耽误我开锤。", "锤子响不响，良心知道。", "你这胳膊没劲，想学打铁得先练几年。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "炉城城主 莫尔", "role": "管着炉城矿脉的城主",
				"personality": "沉稳威严、说一不二，张口闭口都是矿脉、炉温和人手。",
				"greetings": ["进了炉城，先学会别喊烫。", "这城能立住，靠的是一炉一炉烧出来的。", "矿脉要是断了，城就冷了。", "你要留下，就下坑去干两天活。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "猎岩者 图恩", "role": "在岩缝里猎兽的猎手",
				"personality": "沉默粗粝、皮糙肉厚，认得岩缝里每一种爬行的东西。",
				"greetings": ["……（他舔了舔干裂的嘴唇，点头）", "岩缝里的东西，比火还毒。", "别碰那条岩脉，烫。", "跟紧点，脚下留神。"],
				"offset": Vector2(1160, -40),
			},
			{
				"name": "药匠 哈娜", "role": "用矿粉配药的药匠",
				"personality": "利落干脆、不废话，喜欢拿淬火比作治病，火候错了就全废。",
				"greetings": ["你脸被烤红了，先躲开炉子。", "药和淬火一个理，过一分就废。", "这味矿粉得研细了才下得去。", "坐下，手伸出来我看看。"],
				"offset": Vector2(940, -700),
			},
		],
	},
	"grove": {
		"id": "grove",
		"name": "幽语之林",
		"realm": "精灵林海",
		"style": "与巨树共生的林间聚落，宽大的树冠屋搭在枝杈上，藤蔓回廊把它们连成一片，屋子都长在树冠层里。",
		"roof": "canopy",
		"dress": "叶绿与棕褐的藤编长衫，肩披树叶织成的披肩，腰间缠藤蔓束带，赤足，发间插着枝叶与野花。",
		"language": "grove",
		"language_name": "林语",
		"script": "אבגדהוזחטיכלמנסעפצקרשת",
		"worldview": "一个叫「幽语之林」的精灵林间聚落，与古树共享阳光与河水，族人亲近草木、敬畏生死，说话轻缓，连脚步都怕惊了林子。",
		"palette": {
			"grass": Color(0.14, 0.30, 0.18), "path": Color(0.36, 0.32, 0.22),
			"tree": Color(0.12, 0.36, 0.20), "tree_dark": Color(0.08, 0.26, 0.15),
			"trunk": Color(0.28, 0.22, 0.14), "rock": Color(0.34, 0.36, 0.32),
			"rock_dark": Color(0.22, 0.24, 0.22), "house": Color(0.38, 0.32, 0.22),
			"roof": Color(0.20, 0.40, 0.22), "cave": Color(0.05, 0.07, 0.05),
			"deck": Color(0.36, 0.30, 0.20), "shrine": Color(0.34, 0.46, 0.30),
		},
		"spawn": Vector2(0, 45),
		"home_sites": [
			{"id": "village", "name": "幽语之林", "kind": "village", "desc": "林间聚落的中心空地，古树和树廊都汇在这儿。"},
			{"id": "mine", "name": "根系矿洞", "kind": "mine", "desc": "聚落北边巨树的根下，盘根错节间露出一线发亮的矿石。"},
			{"id": "shrine", "name": "月神林龛", "kind": "shrine", "desc": "林间空地的月神林龛，用活树编成，月色好的夜里最灵。"},
			{"id": "forest", "name": "幽语林", "kind": "forest", "desc": "聚落东边的幽语林，风穿过叶子像是有谁在低语。"},
			{"id": "mill", "name": "废弃树屋", "kind": "ruin", "desc": "聚落西边废弃的树屋，藤梯断了半截，树却还好好地长着。"},
			{"id": "bridge", "name": "藤桥", "kind": "bridge", "desc": "聚落南边横跨溪流的藤桥，走上去会轻轻晃，藤却又牢又韧。"},
		],
		"kinds": ["village", "forest", "shrine", "ruin", "bridge"],
		"name_words": ["幽语", "苔影", "藤篱", "鹿鸣", "古木", "萤溪"],
		"npcs": [
			{
				"name": "树匠 艾隆", "role": "把屋子长在树上的树匠",
				"personality": "温和耐心、慢工出细活，把树当活物商量着来，从不硬砍。",
				"greetings": ["轻点声，树还睡着呢。", "屋子不是盖出来的，是树长出来的。", "这根枝再弯一点，明年就能住了。", "来，我教你怎么听树的响动。"],
				"offset": Vector2(180, 40),
			},
			{
				"name": "守望者 瑟兰", "role": "守护整片林子的守望者",
				"personality": "沉静庄严、惜字如金，对林子和族人的事看得比命还重。",
				"greetings": ["你脚下的根，比这座村子还老。", "林子养我们，我们也守着林子。", "别在林里生火，那是犯忌的。", "既然来了，就学着我们走路。"],
				"offset": Vector2(-210, 130),
			},
			{
				"name": "叶影猎手 凯兰", "role": "藏在叶影里的猎手",
				"personality": "沉默警觉、来去无声，能在树影间辨出最轻的脚步。",
				"greetings": ["……（他从树影里现出身，静静看你）", "林子会告诉你，谁来过。", "别踩断枝，声音传得比你想的远。", "跟着我的影子走。"],
				"offset": Vector2(1180, -40),
			},
			{
				"name": "草医 莉薇", "role": "采林草配药的草医",
				"personality": "轻柔安静、凡事随缘，总说草是有脾气的，得顺着它来。",
				"greetings": ["你身上有尘土气，坐下歇歇。", "草有脾性，顺着它才活得成。", "这味叶子得趁露水摘，晚了就苦了。", "先喝口花露，我慢慢同你说。"],
				"offset": Vector2(950, -710),
			},
		],
	},
	# ------------------------------------------------------------------
	# 通天福地：全世界独一份的秘境，不属于任何常规文化圈。
	# 它不参与随机出生 / 区域生成（all_ids 里被排除），只有 LocationGenerator.ensure_tianfu()
	# 会在开局时确定性地把它落在世界里，永远只有一处。
	# language 留空 = 这里的人说的话玩家天然听得懂，不设语言隔阂。
	"tianfu": {
		"id": "tianfu",
		"name": "通天福地",
		"realm": "云外秘境",
		"style": "悬在云海尽头的秘境仙宫：白玉为阶、琉璃作瓦，绯色纱幔层层垂落，暖金灯火与漫天花瓣一同浮动，一砖一瓦都透着撩人的旖旎。",
		"roof": "dome",
		"dress": "薄如蝉翼的绯色与紫色鲛纱，衣料轻薄半透明，剪裁大胆到极点：深V低胸、露肩露背、纤腰镂空、高开衩至腿根，曼妙身段在纱下若隐若现；周身只缀着金链、珠翠与垂坠流苏，随动作轻轻晃动，性感撩人、风情万种。",
		"language": "",
		"language_name": "",
		"script": "",
		"worldview": "传说中藏在云海尽头的「通天福地」，只有极少数有缘人找得到。此地富庶得难以想象：遍地奇珍异宝、金银堆积如山，随手一份馈赠都够凡人受用半生。住在这里的人个个绝色倾城、衣着撩人、性情大胆恣意，最懂人间风月，也最爱逗弄与厚待远来的客人。",
		"palette": {
			"grass": Color(0.30, 0.17, 0.24), "path": Color(0.52, 0.36, 0.34),
			"tree": Color(0.40, 0.18, 0.30), "tree_dark": Color(0.27, 0.11, 0.21),
			"trunk": Color(0.36, 0.23, 0.22), "rock": Color(0.64, 0.54, 0.50),
			"rock_dark": Color(0.44, 0.35, 0.34), "house": Color(0.70, 0.52, 0.46),
			"roof": Color(0.74, 0.26, 0.46), "cave": Color(0.09, 0.04, 0.09),
			"deck": Color(0.60, 0.45, 0.40), "shrine": Color(0.80, 0.36, 0.54),
		},
		"spawn": Vector2(0, 40),
		"home_sites": [],
		"kinds": ["village"],
		"name_words": ["通天", "云绯", "琉璃", "旖旎", "落樱", "暖金"],
		"npcs": [
			{
				"name": "花魁 云绯", "role": "福地里最有名的花魁",
				"personality": "大胆热烈、逢场作戏却最重情，最会撩人，句句都带三分挑逗七分真心。",
				"greetings": ["哟，稀客。走近些呀，让我好好瞧瞧你——这张脸，倒挺合我眼缘。", "别站那么远嘛，我又不会吃了你。……嗯，站近了看，更顺眼了。", "你脸红什么？我这还没说什么呢。", "想要点福地的见面礼？过来，陪我多坐一会儿就有了。"],
				"offset": Vector2(0, -20),
			},
			{
				"name": "舞姬 月婵", "role": "以舞待客的舞姬",
				"personality": "身段撩人、笑靥如花，最爱拿眼波勾人，说话半真半假，看你脸红就开心。",
				"greetings": ["远客来了，要不要看我跳一支？我跳起来，可比站着好看多了。", "别只盯着看呀，说句话嘛，人家好想知道你心里在想什么。", "你这一路风尘仆仆的，来，我替你理理衣领——手可不许乱动哦。", "福地里什么都多，唯独像你这样有意思的人不常见。"],
				"offset": Vector2(170, 30),
			},
			{
				"name": "琴师 雪绫", "role": "抚琴的绝色琴师",
				"personality": "清冷矜贵、惜字如金，越是不动声色，越是勾人，偶尔一句便让人心里发烫。",
				"greetings": ["……坐。听我弹完这一曲再说话。", "你的心跳，比我的琴还乱。", "别急着走。福地难得留客，我更难得留人。", "我这琴弦，只为听得懂的人松一分——你，听懂了吗？"],
				"offset": Vector2(-170, 20),
			},
			{
				"name": "侍女 阿棠", "role": "贴身伺候的侍女",
				"personality": "活泼黏人、口无遮拦，一口一个「公子」，递茶送水都要挨得很近。",
				"greetings": ["公子回来啦！阿棠给你备了热茶，还有……别的，你要不要猜猜看？", "靠这么近说话，公子不会介意吧？我就当你默认了啊。", "福地里宝贝多，公子看上哪样，直说便是——包括我伺候你那一份耐心。", "哎呀，公子别躲呀，鬓角沾了花瓣，阿棠替你摘了。"],
				"offset": Vector2(90, -110),
			},
			{
				"name": "福地主人 霓裳", "role": "通天福地的主人",
				"personality": "风情万种又深不可测，把你当稀客相待，一颦一笑都像赏赐，也像试探。",
				"greetings": ["稀客。能寻到通天福地，你身上必有点与旁人不同的东西。", "来者是客，何况是你这样的客人。本座向来，厚待看得上眼的人。", "福地什么都缺得了，唯独不缺宝贝与美人——你想要哪样，尽管开口。", "留下来吧。这云海之上，本座说了算，你说了……也算。"],
				"offset": Vector2(-90, -100),
			},
		],
	},
}


func _ready() -> void:
	_rng.randomize()


## 常规文化圈 id 列表：随机出生、区域文化分配、建筑图鉴生成都只认这些。
## 通天福地（tianfu）是全世界独一份的秘境，不参与这些常规流程，故在此排除。
func all_ids() -> Array:
	var out: Array = []
	for cid in CULTURES:
		if str(cid) != "tianfu":
			out.append(cid)
	return out


func exists(cid: String) -> bool:
	return CULTURES.has(cid)


func get_culture(cid: String) -> Dictionary:
	var c = CULTURES.get(cid, null)
	if typeof(c) == TYPE_DICTIONARY:
		return c
	return {}


# ---------------------------------------------------------------- 当前文化圈

func home() -> Dictionary:
	return get_culture(current_id)


func village_name() -> String:
	return str(home().get("name", "村庄"))


func spawn_point() -> Vector2:
	var p = home().get("spawn", Vector2(0, 40))
	return p as Vector2


func worldview_block() -> String:
	return worldview_of(current_id)


func worldview_of(cid: String) -> String:
	return str(get_culture(cid).get("worldview", ""))


func style_of(cid: String) -> String:
	return str(get_culture(cid).get("style", ""))


## 该文化圈的衣着打扮描述（生成人物外观 / 立绘提示词用）
func dress_of(cid: String) -> String:
	return str(get_culture(cid).get("dress", ""))


func culture_name_of(cid: String) -> String:
	return str(get_culture(cid).get("name", ""))

func language_of_culture(cid: String) -> String:
	return str(get_culture(cid).get("language", ""))


func language_name_of(cid: String) -> String:
	return str(get_culture(cid).get("language_name", ""))


## 按语言 id 反查语言显示名（玩家已知语言列表用）
func language_name(lang: String) -> String:
	for cid in CULTURES:
		if str(CULTURES[cid].get("language", "")) == lang:
			return str(CULTURES[cid].get("language_name", lang))
	return lang


func palette_of(cid: String) -> Dictionary:
	var pal = get_culture(cid).get("palette", null)
	if typeof(pal) == TYPE_DICTIONARY:
		return pal
	return get_culture("qingshi").get("palette", {})


func house_shape_of(cid: String) -> String:
	return str(get_culture(cid).get("roof", "curved"))


func starting_npcs() -> Array:
	var list = home().get("npcs", [])
	if typeof(list) == TYPE_ARRAY:
		return list
	return []


## 某文化圈的家园地标（含母村，全部不带坐标；坐标由 WorldData.HOME_LAYOUT 统一给出）
func home_sites(cid: String) -> Array:
	var out: Array = []
	var sites = get_culture(cid).get("home_sites", [])
	if typeof(sites) != TYPE_ARRAY:
		return out
	for s in (sites as Array):
		if typeof(s) == TYPE_DICTIONARY:
			out.append((s as Dictionary).duplicate())
	return out


## 该 biome（文化圈）能生成的地点类型 —— 「MC 式」：地形决定会出现什么样的聚落
func kinds_of(cid: String) -> Array:
	var k = get_culture(cid).get("kinds", null)
	var out: Array = []
	if typeof(k) == TYPE_ARRAY and not (k as Array).is_empty():
		out = (k as Array).duplicate()
	else:
		out = ["village", "mine", "shrine", "forest", "ruin", "bridge"]
	# 坏人据点是世界通有的——任何文化圈都可能有，加在副本上，别污染原始数据
	if not out.has("camp"):
		out.append("camp")
	return out


## 该 biome 的取名用字（区域化生成时拼地名的词根）
func name_words_of(cid: String) -> Array:
	var w = get_culture(cid).get("name_words", null)
	if typeof(w) == TYPE_ARRAY and not (w as Array).is_empty():
		return w
	return [str(get_culture(cid).get("name", "无名"))]


## 由「该 biome 的词根 + 该类型的通名」拼出一个地名（区域化生成的兜底取名）
func compose_name(cid: String, kind: String, salt: int) -> String:
	var words := name_words_of(cid)
	var suffix: Array = KIND_SUFFIX.get(kind, ["之地"])
	var w := str(words[absi(salt) % words.size()])
	return w + str(suffix[absi(salt / words.size()) % suffix.size()])


# ---------------------------------------------------------------- 切换 / 开局

func set_current(cid: String) -> void:
	if exists(cid):
		current_id = cid


## 把世界切换到这个文化圈（重建基础地点）
func apply_to_world(cid: String) -> void:
	set_current(cid)
	WorldData.set_culture(current_id)


## 新游戏：随机挑一个文化圈出生
func new_game() -> String:
	var ids := all_ids()
	current_id = str(ids[_rng.randi_range(0, ids.size() - 1)])
	WorldData.set_culture(current_id)
	return current_id


## 打听新地点时，多数落回本文化圈，偶尔会带出别处文化圈的地方 → 于是玩家会遇到听不懂的外语
func pick_generation_culture() -> String:
	var ids := all_ids()
	if _rng.randf() < 0.6:
		return current_id
	var others: Array = []
	for id in ids:
		if str(id) != current_id:
			others.append(str(id))
	if others.is_empty():
		return current_id
	return str(others[_rng.randi_range(0, others.size() - 1)])


# ---------------------------------------------------------------- 语言

## 把一句中文「译」成某语言的样子：同字同译，标点和空白原样保留。
## 玩家听不懂时就用它显示外语原文（让「听不懂」这件事看得见）。
func foreignize(text: String, lang: String) -> String:
	var pool := _script_pool(lang)
	if pool == "":
		return text
	var salt := absi(hash(lang))
	var out := ""
	for i in text.length():
		var ch := text[i]
		if _is_kept(ch):
			out += ch
			continue
		out += pool[absi(hash(ch) + salt) % pool.length()]
	return out


func _script_pool(lang: String) -> String:
	for cid in CULTURES:
		if str(CULTURES[cid].get("language", "")) == lang:
			return str(CULTURES[cid].get("script", ""))
	return ""


## 标点、空白、数字等原样保留，只把「字」换成外语字符
func _is_kept(ch: String) -> bool:
	if ch == " " or ch == "\n" or ch == "\t":
		return true
	return "，。！？、；：（）「」《》…—·,.!?;:()\"'-—0123456789".contains(ch)


# ---------------------------------------------------------------- 存档

func to_save() -> Dictionary:
	return {"culture": current_id}


func from_save(data: Dictionary) -> void:
	var cid := str(data.get("culture", current_id))
	if exists(cid):
		current_id = cid
