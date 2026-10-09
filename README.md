# 指纹键手势 (fpgesture) — KernelSU 模块

侧边指纹键（电源键上的电容指纹，`xiaomi_fp_irq`）在**亮屏解锁态**下识别 **长按 / 双击**，
分别执行你自定义的动作。带 WebUI 配置界面。

设备：Xiaomi `lhasa` / HyperOS 4 (Android 17) · KernelSU v3.3.0

## 安装 / 打开界面

- 已安装到 `/data/adb/modules/fpgesture/`（本机为直接安装，无需重启）。
- **界面**：KernelSU 管理器 → 模块 → **指纹键手势** → 右上角「打开」（WebUI）。
  若管理器里还没出现，退出管理器重进一次（它启动时扫描 `/data/adb/modules`）。
- 分发包：`/sdcard/Download/fpgesture-v1.13.zip`（可在管理器里「从存储安装」，用于重装/分享）。
- 卸载：管理器里删除本模块（`uninstall.sh` 会顺手停掉守护进程）。

## 界面能配什么

| 手势 | 默认 | 可选项 |
|---|---|---|
| 长按 | 小爱同学（助手） | 手电筒 / 截屏 / 回桌面 / 返回 / 下拉通知栏 / 播放暂停 / 上一首·下一首 / 音量± / 相机 / **搜索（全局搜索）** / **小爱同学（助手）** / **小爱记忆（记忆页）** / **打开指定应用** / **自定义 shell 命令** |
| 双击 | 系统原生（不动作） | 双击**由系统原生处理**：指纹 HAL 上报 `BTN_C` 键码，系统按自己的 `fingerprint_double_tap` 绑定执行；模块不推断、也不设 ms |

参数：

- **`长按起点 HOLD_MIN_MS`（默认 2000ms）**：松手时长 ≥ 它才有可能是长按。
- **`长按终点 HOLD_MAX_MS`（默认 3000ms）**：松手时长落在 `[起点, 终点]` 内才执行长按；
  **短于起点** = 太短（原"轻触"已移除，按一下不算手势）；**长于终点** = 误触取消，不执行。
- **区间写法**：把起点和终点设成相等（如 `2000 = 2000`）即"到该值立即触发"，超过也照常执行；
  设成 `[2000, 3000]` 则 2.0s~3.0s 之间松手触发，3s 以上的长压视为误触不响应。
- 双击不再有 `DOUBLE_MS`——双击完全交给系统原生键码，模块不设置窗口。

## 工作原理（都是实测，不是推测）

- **信号**：`/proc/interrupts` 里 `xiaomi_fp_irq` 的计数，50ms 轮询。**一次触摸 = 2 个 IRQ 边沿**
  （按下 1 个、抬起 1 个）；实测 2 秒长按读数为 1985ms（误差 15ms）。
- **判定**：按下边沿记时间，抬起边沿算时长 → 落进长按区间 `[HOLD_MIN_MS, HOLD_MAX_MS]` 才判为长按；
  双击不在这里判定（见下）。
- **双击**：指纹 HAL 通过 evdev 上报 `BTN_C` 键码（`/dev/input/eventX` 中名为 `uinput-xiaomi` 的设备），
  模块后台起一个 `getevent` 监听识别 `BTN_C DOWN`，**但默认只把事件交给系统原生绑定**（`fingerprint_double_tap`），
  不自己设动作，也不设 ms 窗口。
- **动作**：以 root 执行 shell 命令（`input` / `am` / `monkey` / `cmd` / 直接写 LED sysfs）。
- **硬性安全（无开关，永远生效）**：① 黑屏 / 锁屏 一律不执行任何动作；
  ② 指纹识别中（传感器密集 IRQ 风暴）不调用任何动作；③ 指纹识别完成后手指从未离开过按钮 → 不识别。
- **热加载**：守护进程每 ~2 秒重读 `/data/adb/fpgesture/config`，界面改完约 2 秒生效，无需重启。
- **参数写法**：配置文件是纯 `KEY value` 一行一个（无引号），界面按此生成；不要手写 shell 注释。

## 目录

```
/data/adb/modules/fpgesture/     # 模块本体（root:root）
  module.prop  service.sh  uninstall.sh  action.sh  customize.sh
  fpgesture.sh                   # 守护进程（含 selftest/replay/probe/stop/restart）
  config.default                 # 首次运行的默认配置
  webroot/index.html             # WebUI（KSU 管理器渲染，走 ksu.exec 桥）
/data/adb/fpgesture/             # 运行时数据
  config        # 界面写、守护进程读（热加载）
  events.log    # 识别与执行日志（界面上「最近识别」就是它）
  packages.txt  # 应用列表（守护启动时用 pm list packages -3 刷新）
  fpgesture.pid
```

## 已知边界（不是没做，是做不了）

- **滑动方向**：内核/框架都不上报方向信息，只有指纹厂商库读 SPI 才有 → 无法做左右滑动手势。
- **三击/多击**：指纹 HAL 在你第二下时就锁定「双击」并触发动作，**第三下无法作为独立手势**
  （你在真机上已经实测确认过）。
- **锁屏手势**：已**硬性移除**——黑屏 / 锁屏（无论亮否）一律不执行任何动作，且界面不再提供"锁屏时也生效"开关。
- 依赖调试级安全前提：需要 root（KSU）读取 `/proc/interrupts` 与执行动作。

## 验证状态

| 项 | 状态 |
|---|---|
| 识别（长按/双击）+ 动作执行 | ✅ 真机实测（截屏、手电筒、日志逐条比对） |
| 长按区间判定（太短不执行 / 区间内执行 / 太长误触取消 / 相等区间即触发） | ✅ 守护进程 selftest 10/10（含这几条） |
| 硬性安全（黑屏 / 锁屏 / 指纹识别中 / 识别后手指未离开） | ✅ 守护进程 selftest 覆盖（含这四条用例） |
| 配置热加载 | ✅ 真机实测（约 2 秒生效） |
| WebUI 逻辑（解析→重建→保存，无单击 / 无 DOUBLE_MS） | ✅ Node + 假 DOM/假 KSU 桥自检通过 |
| 开机自启（`service.sh`） | ⚠️ 已安装、内容已核对；本机禁重启，**开机路径未实测** |
| WebUI 在管理器 WebView 里的渲染 | ⚠️ 需你在管理器点「打开」亲眼确认 |

## 小爱记忆 / 小爱同学（2026-10-06 实测）

**触发链路（证据来自真机日志）**：

```
W/MiuiInputKeyEventLog: keyCode:98 down:true deviceId:6 → shortcut:fingerprint_double_tap trigger function:turn_on_torch
W/MiuiInputKeyEventLog: shortcut:three_gesture_up trigger function:launch_ai_memory result:true
I/MiuiInputKeyEventLog: launchVoiceAssistant from three_gesture_up
I/ActivityManager: Intent { act=android.intent.action.ASSIST pkg=com.miui.voiceassist
                    cmp=com.miui.voiceassist/com.xiaomi.voiceassistant.VoiceService (has extras) }
应用侧: query.origin = com.miui.voiceassist.query&&three_gesture_up
```

- MIUI 用一张「**键码 → 快捷名 → 功能名**」表分发：`settings system` 里的
  `fingerprint_double_tap` / `three_gesture_up` / `long_press_power_key` / `double_click_power_key` /
  `key_combination_power_volume_down` / `long_press_home_key` 存的就是**功能名**
  （`turn_on_torch` / `screen_shot` / `launch_voice_assistant` / `launch_ai_memory` …）。
- **指纹双击 = keyCode 98（KEYCODE_BUTTON_C）**，所以直接把绑定值写成 `launch_ai_memory`，
  系统自己的分发器就会在双击时唤起小爱记忆——模块就是用的这条路（`NATIVE_DOUBLE aimemory`）。
- 小爱同学（助手）：`am start-foreground-service -a android.intent.action.ASSIST
  -n com.miui.voiceassist/com.xiaomi.voiceassistant.VoiceService`（实测能拉起该服务并进入语音流程）。

**已知边界**：

- 用 `input keyevent 98` **注入不会触发**该分发器（日志显示注入事件 `deviceId:-1`，但没有 `shortcut:` 行）
  → MIUI 按输入设备门控，所以「小爱记忆」目前只能走**系统原生绑定**（双击），不能用任意 shell 命令触发。
- `ACTION_ASSIST` 携带的「来源」extra 名未知（探测 11 个候选键，应用侧均记录为 `&&null`）——
  想让它像三指上滑那样进入记忆模式，还需要继续挖该 extra。

### 小爱记忆为什么做不成「任意手势触发」（2026-10-07 结论）

小爱记忆不是独立入口，而是**小爱同学的一个模式**，由系统 assist-session 传下去的「来源」决定：
应用侧日志为 `getLaunchSource=android.intent.action.ASSIST&&three_gesture_up`。

三条排除性验证（都不是猜）：

1. **31 个候选 extra 键 + 真值 `three_gesture_up`** 一次性打进 `ACTION_ASSIST` 服务启动 →
   应用侧仍记录 `&&null`（小爱只认系统给的来源，不认外部 extra）。
2. **注入 keyCode 98**（KEYCODE_BUTTON_C，指纹双击的键码）→ `MiuiInputKeyEventLog` 能看到注入事件
   （`deviceId:-1`）但**没有 `shortcut:` 分发行** → MIUI 按输入设备门控。
3. **三指上滑不走键码分发**（日志里该路径没有 keyCode 行）→ 无法用 `input` 复刻该手势。

因此：**「小爱同学」可以由模块任意手势触发**（`am start-foreground-service -a android.intent.action.ASSIST
-n com.miui.voiceassist/com.xiaomi.voiceassistant.VoiceService`，已实测能拉起）；
**「小爱记忆」目前只能保留系统三指上滑**。若要强行映射，只能走 LSPosed hook（本机已装 `zygisk_lsposed`），
代价是要手写 smali 打包一个 Xposed 模块。

### 小爱记忆的「接口」（2026-10-07 实测，正解）

小爱把记忆做成了工具方法，定义在 `assets/app_tools.json`：

```json
{ "name": "write_memory", "method": "writeMemory", "class": "com.xiaomi.voiceassistant.UIAgentServiceForOSBot" }
{ "name": "read_memory",  "method": "readMemory",  "class": "com.xiaomi.voiceassistant.UIAgentServiceForOSBot" }
```

- `UIAgentServiceForOSBot.readMemory/writeMemory` 是 **bound-service 的 AIDL 接口**，shell 无法直接绑定调用；
- 但记忆界面本身可以被**直接启动**（非导出组件对 uid 0 放行），实测有效：

```sh
am start -n com.miui.voiceassist/com.xiaomi.voiceassistant.settings.MemorySettingActivity
# → topResumedActivity = com.miui.voiceassist/com.xiaomi.voiceassistant.settings.MemorySettingActivity
```

- 这就是模块里「**小爱记忆（管理页·非记忆岛）**」这个动作的实现：任意手势都能绑。
  ⚠️ 它是**记忆管理页**，不是三指那个「直接记忆/记忆岛」。
- 边界：三指上滑唤起的那个**浮动「记忆岛」**是小爱进程自己绘制的 overlay，没有可启动的组件入口；
  模块打开的是同一功能的**记忆管理页**（列表/详情）。相关 Activity 还有
  `MemoryImageActivity` / `MemoryVideoActivity` / `MemoryLoginActivity`（明细页，不适合做入口）。

### 三指「直接记忆（记忆岛）」的穷尽排查（2026-10-07）

记忆岛由系统 assist-session 路径下发、应用侧按来源 `three_gesture_up` 进入。**外部复现全部失败**，逐条记录：

| 路线 | 结果 |
|---|---|
| `ACTION_ASSIST` + 31 个候选 extra（含真值 `three_gesture_up`） | 应用侧恒为 `getLaunchSource=…&&null` |
| `am start-foreground-service … -i three_gesture_up`（Intent identifier） | 意图带 `id=` 发出，应用无反应 |
| `input keyevent 98`（指纹双击键码） | `MiuiInputKeyEventLog` 可见但**无 `shortcut:` 分发行**（设备门控） |
| `CliCommandService`（`osbot.action.CLI_COMMAND`） | 是 **shell 风格命令 + 白名单**（`settings dnd on` 之类），不含记忆入口 |
| `PUSH_QUERY`（ShareReceiverActivity） | 显式组件能启动，但无任何应用侧反应 |
| `island.ACTION_OPEN` / `ACTION_MEMORY_ISLAND_VIEW` 等广播 | 广播投递成功（result=0），应用无反应 |
| 直接启动 `MemorySettingActivity` | ✅ 能打开，但那是**记忆管理页**，不是记忆岛 |

**剩余唯一有戏的路线**：LSPosed hook（本机已装 `zygisk_lsposed`）——hook 小爱读取来源/展示记忆岛的那处逻辑，
把任意来源当作 `three_gesture_up`。代价：要手写 smali + 打包 Xposed 模块（容器无 Android 构建链）。

### 小窗 / 分屏：为什么不能做成 shell 动作（2026-10-07 实测结论）

两者都是 **SystemUI 内部转场**，只有 LSPosed 在 SystemUI 进程内才调得到：

| 功能 | 真实入口（HyperOS 4） | shell 可行性 |
|---|---|---|
| 双分屏 | `startIconDragSplitScreen(pi, hotArea=1/2, reason)`（`MultiTaskingHotAreaController`） | ❌ |
| 小窗 | `MulWinSwitchTransition.startIconDragFreeform` → `MiuiMultiWindowUtils.getActivityOptions(ctx,pkg,true,x,y)` + `startTransition(ANIMATION_ICON_DRAG_TO_FREEFORM)` | ❌ |

已排除的 shell 路线：

- `am start --windowingMode 3/4/6/100/101` → MIUI **全部忽略**（窗口模式里始终没有 3/4）。
- `am start --windowingMode 5`（freeform）→ 会产生 `mWindowingMode=5` 的窗口，但**没有 bounds**（`am` 不支持 `--bounds`），**不渲染成小窗**（曾误把它当通过，实机确认未生效）。
- `cmd window` → 只有 size/density/folded-area/scaling，无分屏/小窗入口。
- 已安装的 LSPosed 模块 `com.abel.os4freeformx`（v0.4.44）→ 开发期点火口 `PickActivity`/`FIRE:` **已删除**；`StoreProvider.call` 只支持 `getAll/getCfg/put/get` 配置读写。

**可行路线**：给该 LSPosed 模块的 SystemUI hook 增加一个**动态广播接收器**（如 `com.abel.os4freeformx.action.FIRE` + `--es mode split|freeform|mini`），
fpgesture 就能用一条 `am broadcast` 触发双分屏/小窗。容器里可离线重建（`build.sh` 即为 arm64 无 gradle 场景写的，`aapt2/zipalign/apksigner` 均在），
装完需重启 SystemUI 生效（非重启设备）。

## 2026-10-07 修复：长按被误触发（解锁后 / 两次点按相隔较久）

**现象**：① 指纹解锁之后，紧接着会触发一次长按；② 点一下、过一会儿再点，也会被判成长按。

**根因**：分类器原本假设「一次触摸 = 2 个 IRQ 边沿」并靠**奇偶配对**判定。
指纹**认证/解锁期间传感器会打出一串密集 IRQ**（轮询），只要总数是奇数，
配对就整体错位 —— 于是「上一次的抬起」被当成「下一次的按下」，
两次触摸之间的**空档**被量成 1500–3000ms，正好落进长按区间。两个现象同一根因。

**修法（三层，selftest 10/10，含这两条用例）**：

| 层 | 参数 | 规则 |
|---|---|---|
| 风暴过滤 | `QUIET_MS 250` `STORM_MIN_EDGES 4` `STORM_SPAN_MS 700` | 密集边沿（间隔 <250ms）累计 ≥4 个且持续 ≥700ms → 判为认证/扫描风暴，**抑制并复位**，直到出现一次安静间隔 |
| 按下门槛 | `QUIET_MS 250` | 「按下」必须前一段安静 ≥250ms（手指确实离开过）才算；否则视为余波/伪边沿，忽略且不动状态 |
| 失配安全网 | `MAX_HOLD_MS + 500` | 按下状态超时无抬起 → 强制复位，并**吞掉下一个边沿**（防止抬起被当成按下） |

**双击改为延迟结算**：真实双击与认证风暴在前 3~4 个边沿上**本质不可分**，所以动作延迟到「串结束」或
`SETTLE_MS 700` 兜底结算，且**风暴优先**（风暴已判定则取消结算，不打幻影双击）。

## 2026-10-07 v1.7：双击交回系统原生 + 指纹使用期屏蔽（按用户要求）

用户反馈「双击经常误触、单按/长触也误触」，根因是**模块自己用 IRQ 配对推断双击/长按**，而传感器会打孤立 IRQ。

**策略（三条屏蔽）**：

| 要求 | 实现 | 参数 |
|---|---|---|
| 锁屏时屏蔽 | 按下瞬间查 keyguard，锁屏丢弃 | `ONLY_UNLOCKED 1` |
| **任何用指纹时**屏蔽 | 认证/解锁在传感器上表现为**密集 IRQ 风暴** → 风暴期内抑制 | `STORM_MIN_EDGES 3` `STORM_SPAN_MS 400` |
| **用完后屏蔽 1~2 秒** | 风暴结束再挂冷却 | `POST_STORM_MS 2000` |

**双击交回系统原生**：模块**不再推断双击**（`DOUBLE_CMD` 恒空），WebUI 的双击卡片改为「系统原生绑定」选择器
（手电筒 / 不执行 / 不改动 → 写 `NATIVE_DOUBLE`）。副作用符合预期：原生双击本身也是密集边沿 →
被判为"用指纹" → 抑制 + 冷却，因此**双击只触发官方那一次**，不会叠模块动作。

**抬起验证模型**：一次触摸的「抬起」必须随后有 `QUIET_MS 250` 的安静；若抬起后立刻又来边沿，
说明那个抬起是假的（其实是下一次按下）→ **整对丢弃并短暂抑制**。这同时解决：
孤立 IRQ 造成的配对错位、以及我们的动作叠在原生双击上。

**WebUI 保存无损**：页面现在读写全部键（含 `QUIET_MS`/`STORM_*`/`SETTLE_MS`/`POST_STORM_MS` 等 daemon 内部参数），
保存不再把它们抹掉。

## 2026-10-07 v1.8：修复「两个守护进程同时运行」= 动作双触发

**发现**：反复 `restart` 会留下孤儿守护进程（pidfile 只记录最新那个），实测机器上**同时跑了 2 个**。
两个进程都在读同一个 IRQ 计数器 → **每个手势动作被执行两次**（手电筒切两次看不出变化、
截屏出两张、小爱被唤起两次），并且会显著加重"误触"的主观感受。

**修法**：守护进程启动时自清重复实例；匹配必须**按字段精确**（`$2=="sh" && $3 ~ /\/fpgesture\.sh$/ && $4=="run"`），
否则命令行里含同样字样的 shell（例如 agent 自己执行的命令）会被误杀 —— 这一点在本项目里踩过三次。

复核：`ps` 计数 = 1，pidfile 与实际进程一致。

## 2026-10-07 v1.9：双击改为「系统出键码、模块出功能」

用户要求：双击要**由模块定义功能**，但**用系统自己的键码**（不要模块靠 IRQ 推断）。

**实现**：指纹 HAL 的双击会在 **`/dev/input/event6`（`uinput-xiaomi`）** 上报 **`BTN_C`**（已用
`getevent -pl /dev/input/event6` 确认该设备的能力表含 `KEY_HOME/KEY_POWER/KEY_MENU/KEY_BACK/BTN_C`）。
模块在守护进程里起一个后台监听：

```
getevent -lt <按名字解析出的 fp evdev> | while read line; do case "$line" in *BTN_C*DOWN*) 执行 DOUBLE_CMD ;; esac; done &
```

要点：

- **按设备名解析节点**（`FP_EVDEV_NAME uinput-xiaomi`），不写死 `event6`（重启后编号可能变）。
- 只匹配 `DOWN`，避免抬起再触发一次。
- 双击同时受「锁屏时也生效」策略约束。
- **必须清掉系统原生绑定**（`NATIVE_DOUBLE off` → `settings delete system fingerprint_double_tap`），
  否则一次双击会同时触发系统动作和模块动作。守护进程在 `DOUBLE_CMD` 非空时强制置 `off`。
- IRQ 风暴过滤同时把双击的密集边沿挡掉，所以轻触/长触不会和双击抢触发。

**锁屏动作**：预设名从「锁屏（熄屏+锁屏）」改为「**锁屏**」（行为不变：`input keyevent 223`）。

## 2026-10-07 v1.10：双击链路补齐 + 一处自我更正

**双击（v1.9 引入）为什么一开始无效**：`DOUBLE_CMD` 非空时，`apply_native` 会把系统绑定
`settings delete` 成 `null` —— 实测**绑定为 null 时指纹 HAL 不再上报双击键码**，于是 `getevent` 什么也收不到。

**修法**：改用**占位函数名** `fpgesture_noop` 写进 `fingerprint_double_tap` —— 设置非空（HAL 继续上报键码），
但系统不认识这个函数名（`result:false`，不执行任何动作），所以一次双击只触发模块动作。
同时双击命中后会写一个标志文件，**通知 IRQ 路径抑制**（否则双击的密集边沿会被误判成轻触，实测日志出现过
`release 26ms -> tap`）。

**自我更正**：v1.8 里我声称"两个守护进程同时运行 = 动作双触发"，**这个结论是错的**。
`ps -A -o PID,ARGS` 里第二行其实是守护进程自己的**管道/后台子 shell**（子进程会继承父进程的 cmdline）。
用 PPID 复核：`9350(PPID 17355) = 真守护进程`、`9443(PPID 9350) = 它自己的子 shell`、`9438(PPID 9350) = getevent watcher`
—— 从头到尾只有**一个**守护进程。重复实例守卫保留（作为廉价的保险），但"双触发"这个根因**不成立**。

## v1.11 / v1.12：双击链路完成（用户验收通过 2026-10-07）

双击最终形态：**系统出键码（指纹 HAL 在 evdev 上报 `BTN_C`），模块出功能**。三个环节都有日志证据：

| 环节 | 证据 |
|---|---|
| HAL 上报键码 | `getevent -lt /dev/input/event6` 收到 `BTN_C DOWN` |
| watcher 识别 | `events.log: double tap (BTN_C from HAL)` |
| 现读配置并执行 | `events.log: -> double: <DOUBLE_CMD>`（触发时从 config 现读） |

**两个关键缺陷（都在实测中被抓出来）**：

1. **watcher 不随配置热加载启动**：`double_watcher` 原本只在守护进程启动时起一次；启动时 `DOUBLE_CMD` 为空则永远不起。
   修法：主循环热加载处管理 watcher 生命周期（非空且未运行 → 起；变空 → 停）。
2. **watcher 用的是旧命令**：watcher 是后台子 shell，父 shell 热加载后的 `DOUBLE_CMD` 它**看不见**（shell 变量不跨进程），
   而"重启 watcher"条件又只在 watcher 未运行时触发 → 一直用启动时的旧命令。
   修法：**触发那一刻从 config 文件现读**（`grep '^DOUBLE_CMD ' | cut -d' ' -f2-`）。
   自证方式：用假 `getevent` 测试桩（PATH 前置）模拟一次 `BTN_C`，日志显示执行了**测试前刚写进 config 的值**，无需真手指。

**另一个隐患**：watcher "停止"时只杀管道 shell，`getevent` 子进程存活 → 会出现两个读取者（一次双击触发两次）。
修法：每次启动 watcher 前先清掉所有 `getevent -lt` 读取者。

**双击与系统绑定的关系**：`DOUBLE_CMD` 非空时，`apply_native` 写**占位函数名** `fpgesture_noop` ——
设置非空（HAL 继续上报键码），但系统不认识这个函数名（`result:false`，不执行动作），所以一次双击只触发模块动作。

## v1.13：移除单击 + 长按改区间 + 硬性安全一刀切（2026-10-08）

**① 移除单击（轻触）功能**：用户反馈"太容易误触"。`TAP_CMD` / `TAP_MAX_MS` / `TAP_LOCKED`
全部删除；现在短按（< `HOLD_MIN_MS`）**什么都不做**，不再触发截屏等动作。手势集收敛为
**长按（模块执行）+ 双击（系统原生）**。

**② 长按改"起点~终点"区间**：
- 新增 `HOLD_MIN_MS`（默认 2000）/ `HOLD_MAX_MS`（默认 3000），取代原先的 `HOLD_MS` 单分界。
- 松手时长落在 `[起点, 终点]` 内才执行长按；设成**相等**（如 `2000=2000`）即"到该值立即触发"，
  超过也照常执行；短于起点 / 长于终点都不执行（误触取消）。
- WebUI 的「判定区间」卡片改为这两个数字输入；`DOUBLE_MS` 输入框移除（双击交给系统，无需窗口）。

**③ 双击彻底交给系统原生**：`DOUBLE_CMD` 默认空 + `NATIVE_DOUBLE off`。
双击由指纹 HAL 上报 `BTN_C` 键码、走系统自己的 `fingerprint_double_tap` 分发，模块不再推断双击、也不设 ms。

**④ 硬性安全一刀切（无开关）**：按用户要求，锁屏开关全部删除，改为全局硬屏蔽——
- 黑屏 `OR` 锁屏（亮屏也锁） → 不执行任何动作；
- 指纹识别中（传感器密集 IRQ 风暴） → 不调用任何动作；
- 指纹识别完成后、手指**从未离开**过按钮 → 不识别（必须等手指抬起并经冷却后才重新武装）。

守护进程 `blocked()` 合并了三类丢弃条件，`edge()`/`sample()` 用 `auth` 状态机跟踪"指纹使用期"，
并在看到一次安静间隔（手指抬起）后才进入冷却、冷却结束后才 `re-arm`。selftest 用例覆盖全部四条。

**⑤ WebUI 跟随系统深浅色**：原来写死 `color-scheme: dark` + 硬编码深底，现在全部抽成 CSS 变量，
用 `@media (prefers-color-scheme: light|dark)` 跟随系统，WebView 切换系统主题时自动重绘。

## 发布

- **当前稳定版：v1.13**（模块 zip：`dist/fpgesture-v1.13.zip`）
- 安装：KernelSU 管理器 → 模块 → 从本地安装 zip → 重启（模块自启 `service.sh`）
- 配置：KSU 管理器 → 模块 → 指纹键手势 →「打开」→ WebUI
