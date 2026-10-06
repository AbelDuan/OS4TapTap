# 指纹键手势 (fpgesture) — KernelSU 模块

侧边指纹键（电源键上的电容指纹，`xiaomi_fp_irq`）在**亮屏解锁态**下识别 **轻触 / 长按 / 双击**，
分别执行你自定义的动作；每个手势可单独设定「锁屏时是否生效」。带 WebUI 配置界面。

设备：Xiaomi `lhasa` / HyperOS 4 (Android 17) · KernelSU v3.3.0

## 安装 / 打开界面

- 已安装到 `/data/adb/modules/fpgesture/`（本机为直接安装，无需重启）。
- **界面**：KernelSU 管理器 → 模块 → **指纹键手势** → 右上角「打开」（WebUI）。
  若管理器里还没出现，退出管理器重进一次（它启动时扫描 `/data/adb/modules`）。
- 分发包：`/sdcard/Download/fpgesture-v1.0.zip`（可在管理器里「从存储安装」，用于重装/分享）。
- 卸载：管理器里删除本模块（`uninstall.sh` 会顺手停掉守护进程）。

## 界面能配什么

| 手势 | 默认 | 可选项 |
|---|---|---|
| 轻触 | 截屏 | 手电筒 / 截屏 / 回桌面 / 返回 / 下拉通知栏 / 播放暂停 / 上一首·下一首 / 音量± / 相机 / **搜索（全局搜索）** / **小爱同学（助手）** / **小爱记忆（记忆页）** / **打开指定应用** / **自定义 shell 命令** |
| 长按 | 手电筒开关 | 同上 |
| 双击 | 手电筒（系统原生绑定） | 同上；选了普通动作时模块会自动关掉系统原生绑定，避免一次双击触发两次 |

参数：

- `长按分界 HOLD_MS`（默认 1400ms）：短于它 = 轻触，长于它 = 长按。
- `长按上限 MAX_HOLD_MS`（默认 3000ms）：**超过就不执行任何动作**——误触时多按一会儿再松手即可取消。
- `双击窗口 DOUBLE_MS`（默认 400ms）：两下之间的最大间隔。

## 工作原理（都是实测，不是推测）

- **信号**：`/proc/interrupts` 里 `xiaomi_fp_irq` 的计数，50ms 轮询。**一次触摸 = 2 个 IRQ 边沿**
  （按下 1 个、抬起 1 个）；实测 2 秒长按读数为 1985ms（误差 15ms）。
- **判定**：按下边沿记时间，抬起边沿算时长 → 落进轻触/长按区间；两次轻触落在 `DOUBLE_MS` 内 = 双击。
- **动作**：以 root 执行 shell 命令（`input` / `am` / `monkey` / `cmd` / 直接写 LED sysfs）。
- **锁屏策略**：每次触摸的「按下瞬间」会查一次 keyguard 状态，锁屏时按各手势开关决定是否丢弃。
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
- **锁屏手势**：默认全部关闭（你要求防误触）；要开启就在界面里打开对应开关。
- 依赖调试级安全前提：需要 root（KSU）读取 `/proc/interrupts` 与执行动作。

## 验证状态

| 项 | 状态 |
|---|---|
| 识别（轻触/长按/双击）+ 动作执行 | ✅ 真机实测（截屏、手电筒、日志逐条比对） |
| 长按上限取消 / 每手势锁屏开关 | ✅ 逻辑自检 7/7（含这两项） |
| 配置热加载 | ✅ 真机实测（约 2 秒生效） |
| WebUI 逻辑（解析→重建→保存） | ✅ Node + 假 DOM/假 KSU 桥自检通过（含 UTF-8 base64 编码修正） |
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
