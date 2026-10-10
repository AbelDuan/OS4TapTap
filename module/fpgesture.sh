#!/system/bin/sh
# fpgesture - side fingerprint key gestures (Xiaomi lhasa / HyperOS 4)
#
# Signal: /proc/interrupts counter of xiaomi_fp_irq. One touch = 2 edges
#   (down at contact, up at release) - measured live: a 2s hold reads 1985ms.
#
# Config: plain "KEY value" lines, no quoting. Reloaded every ~2s, so the web UI
#   changes actions without restarting anything.
#     HOLD_CMD / DOUBLE_CMD   shell command (empty = no action)
#     HOLD_MIN_MS / HOLD_MAX_MS  long-press window: release duration in
#        [HOLD_MIN_MS, HOLD_MAX_MS] fires the hold action. If both are equal
#        (e.g. 2000 = 2000), any press >= that value fires (no upper clamp).
#        Shorter = ignored (was just a touch); longer = ignored (mis-touch).
#     DOUBLE_CMD  action for the system double-tap (HAL reports BTN_C); empty
#        = let the system-native double-tap behavior stand.
#
# Hard safety (always on, no per-gesture toggle):
#     1) 黑屏 / 锁屏  -> 不执行任何动作
#     2) 指纹识别中（传感器密集 IRQ 风暴）-> 不调用任何动作
#     3) 指纹识别完成后，手指若从未离开过按钮 -> 不识别
#
# usage: fpgesture.sh run|stop|restart|selftest|replay <file>|probe

CONF=${FPGESTURE_CONF:-/data/adb/fpgesture/config}
LOG=${FPGESTURE_LOG:-/data/adb/fpgesture/events.log}
IRQ=${FPGESTURE_IRQ:-/proc/interrupts}
IRQ_NAME=${FPGESTURE_IRQ_NAME:-xiaomi[-_]fp}
PIDF=${FPGESTURE_PID:-/data/adb/fpgesture/fpgesture.pid}
SHARE_DIR=/data/adb/fpgesture
DFLAG="$SHARE_DIR/double.flag"; DUMMY_FN="fpgesture_noop"
FP_EVDEV_NAME=${FPGESTURE_EVDEV_NAME:-uinput-xiaomi}

HOLD_CMD=""; DOUBLE_CMD=""
HOLD_MIN_MS=2000; HOLD_MAX_MS=3000; SUPPRESS_MS=800; POLL=0.05
QUIET_MS=250; STORM_MIN_EDGES=10; STORM_SPAN_MS=400; POST_STORM_MS=2000
MEASURE_OFFSET=60              # 采样量化补偿：实测 2s 长按只读出 ~1985ms（50ms 轮询误差），补偿后回到真实时长
NATIVE_DOUBLE=keep; prev_native=
LOG_ENABLED=0                  # 事件日志开关：0=关闭（默认，零日志开销），1=写入 events.log

DRY=0; EV=""
touching=0; down_ms=0; suppress=0
last_edge=0; burst_start=0; burst_edges=0; storm=0; swallow_next=0; pending_release=0; pending_dur=0
last_count=0; stat_edges=0; stat_acts=0
auth=0; auth_expire=0             # 指纹使用期：瞬时记忆，仅冷却窗内有效，超时自动解除（不落盘，不会卡死）
watcher_pid=""

load() {
  [ -f "$CONF" ] || return 0
  while IFS= read -r line; do
    key=${line%% *}; val=${line#* }
    [ "$key" = "$line" ] && val=""
    case "$key" in
      HOLD_CMD)      HOLD_CMD=$val ;;
      DOUBLE_CMD)    DOUBLE_CMD=$val ;;
      HOLD_MIN_MS)   HOLD_MIN_MS=${val:-2000} ;;
      HOLD_MAX_MS)   HOLD_MAX_MS=${val:-3000} ;;
      SUPPRESS_MS)   SUPPRESS_MS=${val:-800} ;;
      POLL)          POLL=${val:-0.05} ;;
      QUIET_MS)      QUIET_MS=${val:-250} ;;
      STORM_MIN_EDGES) STORM_MIN_EDGES=${val:-10} ;;
      STORM_SPAN_MS) STORM_SPAN_MS=${val:-700} ;;
      POST_STORM_MS) POST_STORM_MS=${val:-2000} ;;
      MEASURE_OFFSET) MEASURE_OFFSET=${val:-60} ;;
      LOG_ENABLED)     LOG_ENABLED=${val:-0} ;;
      FP_EVDEV_NAME) FP_EVDEV_NAME=${val:-uinput-xiaomi} ;;
      NATIVE_DOUBLE) NATIVE_DOUBLE=${val:-keep} ;;
    esac
  done < "$CONF"
}

now_ms() {
  read u _ < /proc/uptime
  i=${u%.*}; f=${u#*.}
  echo $(( i * 1000 + ${f}00 / 100 ))
}

# 日志：DRY（selftest/replay）时打印到 stdout；实机默认关闭（LOG_ENABLED=0），
# 打开时才读 /proc/uptime 并写 events.log——关闭时零额外开销。
log() {
  if [ "$DRY" = 1 ]; then echo "${t:-?} $*"
  elif [ "$LOG_ENABLED" = 1 ]; then echo "$(now_ms) $*" >> "$LOG"
  fi
}

screen_off() {
  # 主判据：Display Power 状态。mWakefulness=Dozing 是息屏显示(AOD)状态，屏幕仍在显示内容
  # 不算黑屏；Asleep 才是真黑屏。mHoldingDisplaySuspendBlocker 在 AOD/亮屏下会误报，不用。
  # 一次 dumpsys 抓全部字段（避免每次手势跑 2 次 binder dump）。
  pw=$(dumpsys power 2>/dev/null)
  echo "$pw" | grep -qE "Display Power: state=OFF|mScreenState=OFF|mWakefulness=Asleep" && { echo 1; return; }
  echo "$pw" | grep -qE "Display Power: state=ON|mScreenState=ON|mWakefulness=Awake" && { echo 0; return; }
  for f in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
    [ -r "$f" ] && { read b < "$f"; [ "${b:-0}" = "0" ] && { echo 1; return; }; }
  done
  echo 0
}

keyguard_locked() {
  # 小米 HyperOS：解锁后 isKeyguardShowing 可能仍为 true（keyguard 窗口残留），
  # 但 isKeyguardOccluded=true 表示已被内容遮住（实际已解锁可见）-> 不算锁。
  # 一次 dumpsys 抓两个字段。
  w=$(dumpsys window 2>/dev/null)
  echo "$w" | grep -q "isKeyguardShowing=true" || { echo 0; return; }
  echo "$w" | grep -q "isKeyguardOccluded=true" && { echo 0; return; }
  echo 1
}

# 硬性安全：黑屏 / 锁屏 / 指纹使用期（瞬时，仅在冷却窗内）-> 一律不执行
blocked() {
  [ "$(screen_off)" = 1 ] && { echo 1; return; }
  [ "$(keyguard_locked)" = 1 ] && { echo 1; return; }
  [ "$auth" = 1 ] && { echo 1; return; }
  echo 0
}

fire() { # fire <cmd> <name>   [name: hold | double]
  [ -z "$1" ] && { log "  -> $2 (no action bound)"; return; }
  # 硬性安全：黑屏 / 锁屏 -> 一律不执行（含长按）。逐项打印拦因，便于定位。
  if [ "$(screen_off)" = 1 ]; then log "  -> $2 blocked (screen OFF)"; return; fi
  if [ "$(keyguard_locked)" = 1 ]; then log "  -> $2 blocked (KEYGUARD locked)"; return; fi
  # 指纹使用期(auth)：只拦双击（指纹解锁时摸键弹两下=误触风险高）。
  # 长按不拦——长按是用户主动持续按压，物理上必然触发指纹认证，若拦则长按永远失效。
  if [ "$2" = double ] && [ "$auth" = 1 ]; then log "  -> double blocked (fp auth in progress)"; return; fi
  stat_acts=$(( stat_acts + 1 ))
  log "  -> $2: $1"
  [ "$DRY" = 1 ] && { EV="$EV$2 "; return; }
  ( sh -c "$1" >/dev/null 2>&1 & )
}

edge() { # edge <now_ms> - one IRQ edge
  t=$1
  stat_edges=$(( stat_edges + 1 ))
  gap=$(( t - last_edge )); [ "$last_edge" = 0 ] && gap=999999
  last_edge=$t

  # auth 期间：不吞 IRQ 边沿、不改 touching——长按识别不受任何影响。
  # auth 只用于「双击」fire 拦截；解除由 sample() 按 auth_expire 定时处理。
  if [ "$auth" = 1 ]; then
    if [ "$gap" -lt "$QUIET_MS" ]; then
      auth_expire=$(( t + POST_STORM_MS ))     # 仍密集：往后延（供双击拦截参考）
    fi
    # 不 return、不改 touching：继续走下方正常手势处理
  fi

  # 认证风暴检测：仅供「双击」fire 拦截参考（auth 置 1 后由 sample() 定时解除）。
  # 不吞 IRQ 边沿——尤其"刚结束一次指纹触摸"后立刻长按：认证的余波边沿会把
  # last_edge 推进到很新，若长按按下边沿 gap<QUIET 就被静默吞掉，按下状态丢失
  # 导致长按识别成 0ms/短触。这里先把边沿当作可能的按下（设 touching/down_ms），
  # 只有 burst 达到认证风暴阈值才撤销（认证本身不构成长按）。
  if [ "$gap" -lt "$QUIET_MS" ]; then
    [ "$burst_start" = 0 ] && burst_start=$t
    burst_edges=$(( burst_edges + 1 ))
    if [ "$touching" = 0 ]; then
      touching=1; down_ms=$t; last_activity=$t
    else
      last_activity=$t
    fi
    if [ "$burst_edges" -ge "$STORM_MIN_EDGES" ] && [ $(( t - burst_start )) -ge "$STORM_SPAN_MS" ]; then
      storm=1
      auth=1; auth_expire=$(( t + POST_STORM_MS ))
      log "storm/auth: ${burst_edges} edges over $(( t - burst_start ))ms (fingerprint in use)"
      touching=0; down_ms=0; last_activity=0    # 认证风暴：撤销误设的按下
    fi
    return
  fi

  # 正常手势处理（此处 gap>=QUIET_MS）
  burst_start=0; burst_edges=1

  if [ "$swallow_next" = 1 ]; then swallow_next=0; log "swallowed edge after reset"; return; fi
  if [ "$suppress" != 0 ] && [ "$t" -lt "$suppress" ]; then log "suppressed edge (cooldown)"; return; fi

  # 上一次的抬起还在等确认：若此刻又来了边沿 -> 那个"抬起"是假的
  if [ "$pending_release" != 0 ]; then
    log "release invalidated (edge ${gap}ms after release) - pair discarded"
    pending_release=0; pending_dur=0
    suppress=$(( t + SUPPRESS_MS ))          # 抑制整段（含官方双击的第二下）
    touching=1; down_ms=$t                    # 这个边沿其实是新触摸的按下
    return
  fi

  # 按下 / 抬起
  if [ "$touching" = 0 ]; then
    if [ "$gap" -lt "$QUIET_MS" ]; then
      log "spurious edge (gap ${gap}ms) ignored"; return
    fi
    touching=1; down_ms=$t
  else
    dur=$(( t - down_ms )); touching=0
    pending_release=$t; pending_dur=$dur
    log "release ${dur}ms (waiting ${QUIET_MS}ms quiet to confirm)"
  fi
}

confirm_release() { # confirm_release <dur>
  dur=$1
  # 补偿采样量化（50ms 轮询）造成的读数偏低，让"真实 2 秒"≈读出 1985ms 也能稳定触发
  adj=$(( dur + MEASURE_OFFSET ))
  if [ "$adj" -lt "$HOLD_MIN_MS" ]; then
    log "ignored ${dur}ms (adj ${adj}ms < HOLD_MIN_MS ${HOLD_MIN_MS} - too short / was a touch)"
  elif [ "$HOLD_MAX_MS" -gt "$HOLD_MIN_MS" ]; then
    if [ "$adj" -le "$HOLD_MAX_MS" ]; then log "hold ${adj}ms (raw ${dur}ms)"; fire "$HOLD_CMD" hold
    else log "cancelled ${adj}ms (raw ${dur}ms > HOLD_MAX_MS ${HOLD_MAX_MS} - mis-touch)"; fi
  else
    # HOLD_MIN_MS == HOLD_MAX_MS：达到即触发（超过也执行）
    log "hold ${adj}ms (raw ${dur}ms)"; fire "$HOLD_CMD" hold
  fi
}

sample() { # sample <irq_count> <now_ms>
  cnt=$1; t=$2
  # 指纹使用期独立定时解除：按 auth_expire，不依赖新边沿（否则用户停手后 auth
  # 永久卡死）。解除时保留 touching——用户可能正按着做长按，不能破坏按下状态。
  if [ "$auth" = 1 ] && [ "$t" -ge "$auth_expire" ]; then
    auth=0; burst_start=0; burst_edges=0
    log "fp auth window expired - re-armed (idle)"
  fi
  # 双击已由 evdev 键码确认 -> 抑制 IRQ 路径，避免把双击误判成长按
  if [ -f "$DFLAG" ]; then
    exp=$(cat "$DFLAG" 2>/dev/null); rm -f "$DFLAG"
    case "$exp" in ''|*[!0-9]*) ;; *) if [ "$exp" -gt "$t" ]; then
        suppress=$exp; touching=0; pending_release=0
        log "double confirmed by evdev -> IRQ path suppressed $(( exp - t ))ms"
    fi ;; esac
  fi
  delta=$(( cnt - last_count )); last_count=$cnt
  while [ "$delta" -gt 0 ]; do edge "$t"; delta=$(( delta - 1 )); done
  # 抬起确认：安静满 QUIET_MS 才结算
  if [ "$pending_release" != 0 ] && [ $(( t - pending_release )) -ge "$QUIET_MS" ]; then
    d=$pending_dur; pending_release=0; pending_dur=0
    confirm_release "$d"
  fi
  # 失配安全网
  if [ "$touching" = 1 ] && [ $(( t - down_ms )) -gt 8000 ]; then
    log "state reset: down for $(( t - down_ms ))ms with no release (desync guard)"
    touching=0; swallow_next=1
  fi
}

irq_count() {
  awk -v n="$IRQ_NAME" '$NF ~ n { s=0; for (i=2; i<=NF; i++) { if ($i !~ /^[0-9]+$/) break; s += $i } print s+0; exit }' "$IRQ"
}

refresh_packages() {
  [ -d "$SHARE_DIR" ] || return 0
  pm list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$SHARE_DIR/packages.txt" 2>/dev/null
}

double_watcher() { # 双击：系统出键码（evdev BTN_C），模块出功能
  [ -z "$DOUBLE_CMD" ] && return 0
  # 先清掉可能残留的 getevent 读取者：两个 watcher 会让一次双击触发两次
  for p in $(ps -A -o PID,ARGS 2>/dev/null | awk '$2=="getevent" && $3=="-lt" {print $1}'); do
    kill "$p" 2>/dev/null && log "killed stale getevent pid=$p"
  done
  dev=""
  for d in /dev/input/event*; do
    n=$(getevent -i "$d" 2>/dev/null | grep -m1 'name:' | sed 's/.*name: *"//; s/".*//')
    [ "$n" = "$FP_EVDEV_NAME" ] && { dev=$d; break; }
  done
  [ -z "$dev" ] && { log "double: evdev '$FP_EVDEV_NAME' not found"; return 0; }
  log "double watcher on $dev (BTN_C)"
  getevent -lt "$dev" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"BTN_C"*"DOWN"*)
        # 黑屏 / 锁屏 时由 fire()->blocked() 拦截；指纹识别中 HAL 通常不会上报双击键码
        dcmd=$(grep '^DOUBLE_CMD ' "$CONF" 2>/dev/null | head -1 | cut -d' ' -f2-)
        echo $(( $(now_ms) + SUPPRESS_MS )) > "$DFLAG"
        if [ -n "$dcmd" ]; then log "double tap (BTN_C from HAL)"; fire "$dcmd" double
        else log "double tap (BTN_C from HAL) - no DOUBLE_CMD set"; fi
        ;;
    esac
  done &
}

apply_native() {
  # 双击策略由 DOUBLE_CMD 决定，而不是 NATIVE_DOUBLE 这个残留字段：
  #   - DOUBLE_CMD 非空：模块自己执行双击动作 -> 必须把系统原生绑定覆盖成占位名，
  #     否则系统会再触发一次（一次双击触发两次）。
  #   - DOUBLE_CMD 为空（默认）：双击完全交给系统原生。若此前被我们写成了占位名
  #     (fpgesture_noop) 或曾用 off 删掉(读到空)，这里自愈恢复成系统默认(turn_on_torch)。
  # 性能：只在状态切换时跑 settings（binder 调用）；状态不变则零开销。
  want=keep
  [ -n "$DOUBLE_CMD" ] && want=noop
  [ "$want" = "$prev_native" ] && return 0
  if [ "$want" = noop ]; then
    cur=$(settings get system fingerprint_double_tap 2>/dev/null)
    if [ "$cur" != "$DUMMY_FN" ]; then
      settings put system fingerprint_double_tap "$DUMMY_FN" 2>/dev/null \
        && log "native double-tap = dummy '$DUMMY_FN' (module handles double via evdev)"
    fi
  else
    cur=$(settings get system fingerprint_double_tap 2>/dev/null)
    if [ "$cur" = "$DUMMY_FN" ] || [ -z "$cur" ]; then
      settings put system fingerprint_double_tap turn_on_torch 2>/dev/null \
        && log "native double-tap restored to system default (turn_on_torch) - 双击交系统原生"
    fi
  fi
  prev_native=$want
}

run() {
  load
  apply_native
  # 防重复实例：两个守护进程会把手势动作触发两次（重复 = 双触发）
  if [ -f "$PIDF" ]; then
    old=$(cat "$PIDF" 2>/dev/null)
    case "$old" in ''|*[!0-9]*) ;; *)
      if [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
        log "duplicate daemon pid=$old alive - terminating"
        kill "$old" 2>/dev/null; sleep 1
        kill -0 "$old" 2>/dev/null && kill -9 "$old" 2>/dev/null
      fi ;;
    esac
  fi
  for p in $(ps -A -o PID,ARGS 2>/dev/null | awk '$2=="sh" && $3 ~ /\/fpgesture\.sh$/ && $4=="run" { print $1 }'); do
    [ "$p" = "$$" ] && continue
    kill "$p" 2>/dev/null && log "killed duplicate daemon pid=$p"
    sleep 1
    kill -0 "$p" 2>/dev/null && { kill -9 "$p" 2>/dev/null; log "duplicate pid=$p needed SIGKILL"; }
  done
  echo $$ > "$PIDF"
  log "start hold=${HOLD_MIN_MS}-${HOLD_MAX_MS}ms double=system-native(BTN_C) locked/screenoff/auth blocked"
  last_count=$(irq_count)
  [ -z "$last_count" ] && { log "FATAL: no '$IRQ_NAME' in $IRQ"; exit 1; }
  log "irq baseline=$last_count"
  refresh_packages &
  double_watcher; watcher_pid=$!
  n=0
  while :; do
    sleep "$POLL"
    sample "$(irq_count)" "$(now_ms)"
    n=$(( n + 1 ))
    [ $(( n % 40 )) -eq 0 ] && {
      load; apply_native
      if [ -n "$DOUBLE_CMD" ]; then
        { [ -z "$watcher_pid" ] || ! kill -0 "$watcher_pid" 2>/dev/null; } && { double_watcher; watcher_pid=$!; log "double watcher (re)started pid=$watcher_pid"; }
      elif [ -n "$watcher_pid" ]; then
        kill "$watcher_pid" 2>/dev/null; watcher_pid=""; log "double watcher stopped (no DOUBLE_CMD)"
      fi
    }
  done
}

probe() {
  echo "-- $IRQ lines --"; grep -iE "xiaomi|finger" "$IRQ" 2>/dev/null | head -6
  echo "-- irq_count --"; irq_count
}

replay() {
  DRY=1; load
  last_count=$(head -1 "$1" | awk '{print $2}')
  while read t c; do [ -z "$t" ] && continue; sample "$c" "$t"; done < "$1"
  echo "replay done: edges=$stat_edges actions=$stat_acts"
}

selftest() {
  DRY=1; ok=0; bad=0
  chk() { if [ "$2" = "$3" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "FAIL want='$2' got='$3'"; fi; }
  rst() { EV=""; touching=0; down_ms=0; suppress=0
    last_edge=0; burst_start=0; burst_edges=0; storm=0; swallow_next=0; pending_release=0; pending_dur=0
    auth=0; auth_expire=0; last_count=0; STUB_LOCKED=0; STUB_OFF=0; }
  keyguard_locked() { echo "$STUB_LOCKED"; }
  screen_off() { echo "$STUB_OFF"; }
  HOLD_CMD=x; DOUBLE_CMD=
  HOLD_MIN_MS=2000; HOLD_MAX_MS=3000; SUPPRESS_MS=800; MEASURE_OFFSET=60
  POST_STORM_MS=2000; QUIET_MS=250; STORM_MIN_EDGES=10; STORM_SPAN_MS=400

  # 区间内长按 -> 触发（实测 2s 长按读 ~1985ms，+60 补偿后过 2000 阈值）
  rst; sample 1 1000; sample 2 1020; sample 3 3020; sample 3 3300
  chk "hold in range" "hold " "$EV"

  # 太短（原本是轻触）-> 不执行
  rst; sample 1 1000; sample 2 1020; sample 3 1500; sample 3 1800
  chk "too short ignored" "" "$EV"

  # 太长（误触取消）-> 不执行
  rst; sample 1 5000; sample 2 5020; sample 3 9020; sample 3 9500
  chk "too long cancelled" "" "$EV"

  # 相等区间 2000=2000：>=2000 即触发
  rst; HOLD_MIN_MS=2000; HOLD_MAX_MS=2000
  sample 1 10000; sample 2 10020; sample 3 12020; sample 3 12300
  chk "equal range fires at >=2000" "hold " "$EV"

  # 黑屏 -> 不执行
  rst; STUB_OFF=1
  sample 1 1000; sample 2 1020; sample 3 3020; sample 3 3300
  chk "screen off blocked" "" "$EV"

  # 锁屏 -> 不执行
  rst; STUB_LOCKED=1
  sample 1 1000; sample 2 1020; sample 3 3020; sample 3 3300
  chk "locked blocked" "" "$EV"

  # 指纹认证风暴（≥10 密集边沿且跨 400ms）-> 完全抑制，不得打出幻影
  rst; sample 1 30000; sample 2 30150; sample 3 30300; sample 4 30450; sample 5 30600; sample 6 30750
  sample 7 30900; sample 8 31050; sample 9 31200; sample 10 31350; sample 11 31500; sample 12 31650
  chk "auth storm suppressed" "" "$EV"

  # 风暴后冷却窗（POST_STORM_MS 从风暴起点算起）结束，再来一次长按必须正常
  rst; sample 1 30000; sample 2 30150; sample 3 30300; sample 4 30450; sample 5 30600; sample 6 30750
  sample 7 30900; sample 8 31050; sample 9 31200; sample 10 31350; sample 11 31500; sample 12 31650
  # 风暴起点 ~31350，冷却到 31350+2000=33350；之后新一次长按必须正常
  sample 12 34000          # cnt 不变：仅推进时间触发 auth 解除（无新边沿）
  sample 13 34300          # 新一次长按按下（gap>=250）
  sample 14 36600          # 松手（dur=2300，+60=2360 过 2000）
  sample 14 36850          # 确认（quiet 250）
  chk "after auth cooldown, hold works" "hold " "$EV"

  # 真实用户场景（本次修复核心）：刚结束一次指纹触摸（认证风暴，余波边沿把
  # last_edge 推进到很新）-> 立刻长按，按下边沿 gap<QUIET 也可能被当作余波。
  # 必须仍能识别长按（认证结束后手指已离开，auth 窗内长按按下要能捕获）。
  rst; sample 1 50000; sample 2 50150; sample 3 50300; sample 4 50450; sample 5 50600; sample 6 50750
  sample 7 50900; sample 8 51050; sample 9 51200; sample 10 51350; sample 11 51500; sample 12 51650
  # 风暴触发 auth=1 并撤销误设的按下（touching=0）
  sample 13 51900             # 认证余波/长按按下（gap=250 恰达阈值，走正常路径 -> 按下）
  sample 14 54300             # 松手（dur=2400，+60=2460 过 2000）
  sample 14 54550             # 确认（quiet 250）
  chk "hold right after fp auth still fires" "hold " "$EV"

  # 双击交给系统原生（HAL 自己报 BTN_C）-> 我们不得出手
  rst; sample 1 6000; sample 2 6060; sample 3 6120; sample 4 6180; sample 4 7000
  chk "double-tap left to native" "" "$EV"

  echo "selftest: ok=$ok bad=$bad"
  [ "$bad" = 0 ]
}

case "$1" in
  probe)    probe ;;
  selftest) selftest ;;
  replay)   replay "$2" ;;
  stop)     [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; echo stopped ;;
  restart)  [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; sleep 1
            setsid "$0" run </dev/null >/dev/null 2>&1 & echo restarted ;;
  *)        run ;;
esac
