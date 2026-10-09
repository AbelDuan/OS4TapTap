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
DFLAG="$SHARE_DIR/double.flag"; DUMMY_FN="fpgesture_noop"; AUTH_FLAG="$SHARE_DIR/auth.block"
FP_EVDEV_NAME=${FPGESTURE_EVDEV_NAME:-uinput-xiaomi}

HOLD_CMD=""; DOUBLE_CMD=""
HOLD_MIN_MS=2000; HOLD_MAX_MS=3000; SUPPRESS_MS=800; POLL=0.05
QUIET_MS=250; STORM_MIN_EDGES=3; STORM_SPAN_MS=400; SETTLE_MS=700; POST_STORM_MS=2000; POST_AUTH_MS=600
NATIVE_DOUBLE=keep; prev_native=

DRY=0; EV=""
touching=0; down_ms=0; suppress=0
last_edge=0; burst_start=0; burst_edges=0; storm=0; swallow_next=0; pending_release=0; pending_dur=0
last_count=0; stat_edges=0; stat_acts=0
auth=0; auth_release=0           # 指纹使用期：接触未结束（手指没离开过）-> 不识别
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
      STORM_MIN_EDGES) STORM_MIN_EDGES=${val:-4} ;;
      STORM_SPAN_MS) STORM_SPAN_MS=${val:-700} ;;
      SETTLE_MS)     SETTLE_MS=${val:-700} ;;
      POST_STORM_MS) POST_STORM_MS=${val:-2000} ;;
      POST_AUTH_MS)  POST_AUTH_MS=${val:-600} ;;
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

log() { if [ "$DRY" = 1 ]; then echo "${t:-?} $*"; else echo "$(now_ms) $*" >> "$LOG"; fi; }

screen_off() {
  dumpsys power 2>/dev/null | grep -qE "Display Power: state=OFF|mScreenState=OFF|mHoldingDisplaySuspendBlocker=false" && { echo 1; return; }
  for f in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
    [ -r "$f" ] && { read b < "$f"; [ "${b:-0}" = "0" ] && { echo 1; return; }; }
  done
  echo 0
}

keyguard_locked() {
  dumpsys window 2>/dev/null | grep -q "isKeyguardShowing=true" && echo 1 || echo 0
}

# 硬性安全：黑屏 / 锁屏 / 指纹使用期 -> 一律不执行
blocked() {
  [ "$(screen_off)" = 1 ] && { echo 1; return; }
  [ "$(keyguard_locked)" = 1 ] && { echo 1; return; }
  [ "$auth" = 1 ] || [ -f "$AUTH_FLAG" ] && { echo 1; return; }
  echo 0
}

fire() { # fire <cmd> <name>
  [ -z "$1" ] && { log "  -> $2 (no action bound)"; return; }
  if [ "$(blocked)" = 1 ]; then log "  -> $2 blocked (screen off / locked / fp auth)"; return; fi
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

  # 解封判定：指纹识别完成 + 手指已抬起 + 冷却结束 -> 重新武装（吞掉解封那一刻的边沿）
  if [ "$auth" = 1 ] && [ "$auth_release" = 1 ] && { [ "$suppress" = 0 ] || [ "$t" -ge "$suppress" ]; }; then
    auth=0; auth_release=0; rm -f "$AUTH_FLAG" 2>/dev/null
    touching=0; pending_release=0; pending_dur=0
    log "fp auth done & finger lifted - re-armed"
    return
  fi

  # 指纹识别中：累计密集边沿；一旦足够密集 -> 进入「指纹使用期」(auth=1)
  if [ "$auth" = 0 ]; then
    if [ "$gap" -lt "$QUIET_MS" ]; then
      [ "$burst_start" = 0 ] && burst_start=$t
      burst_edges=$(( burst_edges + 1 ))
      if [ "$burst_edges" -ge "$STORM_MIN_EDGES" ] && [ $(( t - burst_start )) -ge "$STORM_SPAN_MS" ]; then
        storm=1; touching=0; pending_release=0
        auth=1; auth_release=0; touch "$AUTH_FLAG" 2>/dev/null
        suppress=$(( t + POST_STORM_MS ))
        log "storm/auth: ${burst_edges} edges over $(( t - burst_start ))ms (fingerprint in use) - suppressing"
      fi
      return
    fi
  fi

  # 指纹使用期内：
  #   - 仍密集(间隔小) -> 仍在指纹识别，吞掉
  #   - 出现安静间隔(gap 大) -> 手指抬起（识别完成），进入冷却，但不解封；
  #     若此前都没抬起过，则「手指从未离开」=本次抬起，合法；之后冷却结束才重新武装
  if [ "$auth" = 1 ]; then
    if [ "$gap" -lt "$QUIET_MS" ]; then
      return
    fi
    auth_release=1
    suppress=$(( t + POST_STORM_MS ))
    log "fp auth: finger lifted - cooling ${POST_STORM_MS}ms (must wait before re-arm)"
    return
  fi

  # 此处 gap>=QUIET_MS（未进入指纹期），正常手势处理
  burst_start=0; burst_edges=1

  # 冷却期内的边沿直接吞掉
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
  if [ "$dur" -lt "$HOLD_MIN_MS" ]; then
    log "ignored ${dur}ms (< HOLD_MIN_MS ${HOLD_MIN_MS} - too short / was a touch)"
  elif [ "$HOLD_MAX_MS" -gt "$HOLD_MIN_MS" ]; then
    if [ "$dur" -le "$HOLD_MAX_MS" ]; then log "hold ${dur}ms"; fire "$HOLD_CMD" hold
    else log "cancelled ${dur}ms (> HOLD_MAX_MS ${HOLD_MAX_MS} - mis-touch)"; fi
  else
    # HOLD_MIN_MS == HOLD_MAX_MS：达到即触发（超过也执行）
    log "hold ${dur}ms"; fire "$HOLD_CMD" hold
  fi
}

sample() { # sample <irq_count> <now_ms>
  cnt=$1; t=$2
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
  # 指纹使用期解封（无新边沿也要能解封）：已看到抬起且冷却结束
  if [ "$auth" = 1 ] && [ "$auth_release" = 1 ] && [ "$suppress" != 0 ] && [ "$t" -ge "$suppress" ]; then
    auth=0; auth_release=0; rm -f "$AUTH_FLAG" 2>/dev/null
    touching=0; pending_release=0; pending_dur=0
    log "fp auth done & finger lifted - re-armed"
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
        # blocked() 会查 AUTH_FLAG / 黑屏 / 锁屏，故指纹识别中、熄屏、锁屏都不会触发
        dcmd=$(grep '^DOUBLE_CMD ' "$CONF" 2>/dev/null | head -1 | cut -d' ' -f2-)
        echo $(( $(now_ms) + SUPPRESS_MS )) > "$DFLAG"
        if [ -n "$dcmd" ]; then log "double tap (BTN_C from HAL)"; fire "$dcmd" double
        else log "double tap (BTN_C from HAL) - no DOUBLE_CMD set"; fi
        ;;
    esac
  done &
}

apply_native() {
  # 模块自己执行双击动作时，必须清掉系统原生绑定，否则一次双击会触发两个动作
  [ -n "$DOUBLE_CMD" ] && NATIVE_DOUBLE=noop
  [ "$NATIVE_DOUBLE" = "$prev_native" ] && return 0
  case "$NATIVE_DOUBLE" in
    noop)  # 占位：系统不认识这个函数名 -> 不动作；但设置非空 -> HAL 继续上报双击键码
      if [ "$(settings get system fingerprint_double_tap)" != "$DUMMY_FN" ]; then
        settings put system fingerprint_double_tap "$DUMMY_FN" && log "native double-tap = dummy '$DUMMY_FN' (keep HAL reporting, no system action)"
      fi
      prev_native=noop ;;
    off)   settings delete system fingerprint_double_tap 2>/dev/null; prev_native=off
           log "native double-tap binding removed (双击由系统原生处理)" ;;
    torch) settings put system fingerprint_double_tap turn_on_torch 2>/dev/null; prev_native=torch
           log "native double-tap = torch" ;;
    *)     prev_native=keep ;;
  esac
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
    auth=0; auth_release=0; rm -f "$AUTH_FLAG" 2>/dev/null
    last_count=0; STUB_LOCKED=0; STUB_OFF=0; }
  keyguard_locked() { echo "$STUB_LOCKED"; }
  screen_off() { echo "$STUB_OFF"; }
  HOLD_CMD=x; DOUBLE_CMD=
  HOLD_MIN_MS=2000; HOLD_MAX_MS=3000; SUPPRESS_MS=800
  POST_STORM_MS=2000; QUIET_MS=250; STORM_MIN_EDGES=3; STORM_SPAN_MS=400; POST_AUTH_MS=600

  # 区间内长按 -> 触发
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

  # 指纹认证风暴 -> 完全抑制，不得打出幻影
  rst; sample 1 30000; sample 2 30150; sample 3 30300; sample 4 30450; sample 5 30600; sample 6 30750
  chk "auth storm suppressed" "" "$EV"

  # 风暴结束 + 手指抬起 + 冷却后，再来一次长按必须正常
  rst; sample 1 30000; sample 2 30150; sample 3 30300; sample 4 30450; sample 5 30600
  sample 6 31000            # 安静 gap -> 风暴结束 + 抬起(auth_release=1, 冷却到 33000)
  sample 7 33200            # 冷却结束 -> 重新武装
  sample 8 33500           # 新一次长按按下（gap>=250）
  sample 9 35800           # 松手（dur=2300）
  sample 9 36050           # 确认（quiet 250）
  chk "after auth + finger lifted, hold works" "hold " "$EV"

  # 风暴结束(抬起)但仍在冷却/指纹使用期内 -> 不响应
  rst; sample 1 50000; sample 2 50150; sample 3 50300; sample 4 50450; sample 5 50600
  sample 6 51000           # 安静 -> 风暴结束 + 抬起(auth_release=1, 冷却到 53000)
  sample 7 51500           # 冷却期内的一次新边沿 -> 必须被抑制
  sample 8 51750
  chk "auth-just-ended cooldown suppresses" "" "$EV"

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
