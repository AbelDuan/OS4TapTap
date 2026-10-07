#!/system/bin/sh
# fpgesture v3 - side fingerprint key gestures (Xiaomi lhasa / HyperOS 4)
#
# Signal: /proc/interrupts counter of xiaomi_fp_irq. One touch = 2 edges
#   (down at contact, up at release) - measured live: a 2s hold reads 1985ms.
#
# Config: plain "KEY value" lines, no quoting. Reloaded every ~2s, so the web UI
#   changes actions without restarting anything.
#     TAP_CMD / HOLD_CMD / DOUBLE_CMD   shell command (empty = no action)
#     HOLD_MS 1400      >= this = long press
#     MAX_HOLD_MS 3000  longer = mis-touch, ignored (press longer to cancel)
#     DOUBLE_MS 400     two taps inside this window = double tap
#     TAP_LOCKED/HOLD_LOCKED/DOUBLE_LOCKED   1 = also fire while locked
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

TAP_CMD=""; HOLD_CMD=""; DOUBLE_CMD=""
TAP_MAX_MS=800; HOLD_MS=1500; MAX_HOLD_MS=3000; DOUBLE_MS=400; SUPPRESS_MS=800; POLL=0.05
QUIET_MS=250; STORM_MIN_EDGES=3; STORM_SPAN_MS=400; SETTLE_MS=700; POST_STORM_MS=2000
TAP_LOCKED=0; HOLD_LOCKED=0; DOUBLE_LOCKED=0; ONLY_UNLOCKED=1; NATIVE_DOUBLE=keep; prev_native=

DRY=0; EV=""
touching=0; down_ms=0; suppress=0
last_edge=0; burst_start=0; burst_edges=0; storm=0; swallow_next=0; pending_release=0; pending_dur=0
ct_locked=0; last_count=0; stat_edges=0; stat_acts=0
watcher_pid=""

load() {
  [ -f "$CONF" ] || return 0
  while IFS= read -r line; do
    key=${line%% *}; val=${line#* }
    [ "$key" = "$line" ] && val=""
    case "$key" in
      TAP_CMD)       TAP_CMD=$val ;;
      HOLD_CMD)      HOLD_CMD=$val ;;
      DOUBLE_CMD)    DOUBLE_CMD=$val ;;
      TAP_MAX_MS)    TAP_MAX_MS=${val:-800} ;;
      HOLD_MS)       HOLD_MS=${val:-1500} ;;
      MAX_HOLD_MS)   MAX_HOLD_MS=${val:-3000} ;;
      DOUBLE_MS)     DOUBLE_MS=${val:-400} ;;
      SUPPRESS_MS)   SUPPRESS_MS=${val:-800} ;;
      POLL)          POLL=${val:-0.05} ;;
      QUIET_MS)      QUIET_MS=${val:-250} ;;
      STORM_MIN_EDGES) STORM_MIN_EDGES=${val:-4} ;;
      STORM_SPAN_MS) STORM_SPAN_MS=${val:-700} ;;
      SETTLE_MS)     SETTLE_MS=${val:-700} ;;
      POST_STORM_MS) POST_STORM_MS=${val:-2000} ;;
      FP_EVDEV_NAME) FP_EVDEV_NAME=${val:-uinput-xiaomi} ;;
      TAP_LOCKED)    TAP_LOCKED=${val:-0} ;;
      HOLD_LOCKED)   HOLD_LOCKED=${val:-0} ;;
      DOUBLE_LOCKED) DOUBLE_LOCKED=${val:-0} ;;
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

keyguard_locked() {
  dumpsys window 2>/dev/null | grep -q "isKeyguardShowing=true" && echo 1 || echo 0
}

fire() { # fire <cmd> <name>
  if [ -z "$1" ]; then log "  -> $2 (no action bound)"; EV="$EV$2 "; return; fi
  stat_acts=$(( stat_acts + 1 ))
  log "  -> $2: $1"
  [ "$DRY" = 1 ] && { EV="$EV$2 "; return; }
  ( sh -c "$1" >/dev/null 2>&1 & )
}

edge() { # edge <now_ms> - one IRQ edge; 按下/抬起 + 抬起必须被"安静"验证
  t=$1
  stat_edges=$(( stat_edges + 1 ))
  gap=$(( t - last_edge )); [ "$last_edge" = 0 ] && gap=999999
  last_edge=$t

  # --- 风暴过滤：密集边沿持续过久 = 指纹认证/扫描，不是人手势 ---
  if [ "$gap" -lt "$QUIET_MS" ]; then
    [ "$burst_start" = 0 ] && burst_start=$t
    burst_edges=$(( burst_edges + 1 ))
    if [ "$storm" = 0 ] && [ "$burst_edges" -ge "$STORM_MIN_EDGES" ] && [ $(( t - burst_start )) -ge "$STORM_SPAN_MS" ]; then
      storm=1; touching=0; pending_release=0; suppress=$(( t + POST_STORM_MS ))
      log "storm: ${burst_edges} edges over $(( t - burst_start ))ms (auth/scan?) - suppressing"
    fi
  else
    if [ "$storm" = 1 ]; then
      storm=0
      suppress=$(( t + POST_STORM_MS ))
      log "storm ended - cooling down ${POST_STORM_MS}ms (fingerprint was in use)"
    fi
    burst_start=0; burst_edges=1
  fi
  [ "$storm" = 1 ] && return
  [ "$swallow_next" = 1 ] && { swallow_next=0; log "swallowed edge after reset"; return; }
  [ "$suppress" != 0 ] && [ "$t" -lt "$suppress" ] && { log "suppressed edge"; return; }

  # --- 上一次的抬起还在等确认：若此刻又来了边沿 → 那个"抬起"是假的 ---
  if [ "$pending_release" != 0 ]; then
    log "release invalidated (edge ${gap}ms after release) - pair discarded"
    pending_release=0; pending_dur=0
    suppress=$(( t + SUPPRESS_MS ))          # 抑制整段（含官方双击的第二下）
    touching=1; down_ms=$t                    # 这个边沿其实是新触摸的按下
    return
  fi

  # --- 按下 / 抬起 ---
  if [ "$touching" = 0 ]; then
    if [ "$gap" -lt "$QUIET_MS" ]; then
      log "spurious edge (gap ${gap}ms) ignored"; return
    fi
    touching=1; down_ms=$t
    if [ "$ONLY_UNLOCKED" = 1 ]; then ct_locked=$(keyguard_locked); else ct_locked=0; fi
  else
    dur=$(( t - down_ms )); touching=0
    pending_release=$t; pending_dur=$dur
    log "release ${dur}ms (waiting ${QUIET_MS}ms quiet to confirm)"
  fi
}

confirm_release() { # confirm_release <dur>
  dur=$1
  if [ "$dur" -le "$TAP_MAX_MS" ]; then
    if [ "$ct_locked" = 1 ] && [ "$TAP_LOCKED" != 1 ]; then log "tap ${dur}ms ignored (locked)"
    else log "tap ${dur}ms"; fire "$TAP_CMD" tap; fi
  elif [ "$dur" -ge "$HOLD_MS" ] && [ "$dur" -le "$MAX_HOLD_MS" ]; then
    if [ "$ct_locked" = 1 ] && [ "$HOLD_LOCKED" != 1 ]; then log "hold ${dur}ms ignored (locked)"
    else log "hold ${dur}ms"; fire "$HOLD_CMD" hold; fi
  elif [ "$dur" -gt "$MAX_HOLD_MS" ]; then
    log "cancelled ${dur}ms (> ${MAX_HOLD_MS}ms - mis-touch)"
  else
    log "dead zone ${dur}ms (${TAP_MAX_MS}~${HOLD_MS}) ignored"
  fi
}

sample() { # sample <irq_count> <now_ms>
  cnt=$1; t=$2
  # 双击已由 evdev 键码确认 → 抑制 IRQ 路径，避免把双击误判成轻触
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
  if [ "$touching" = 1 ] && [ $(( t - down_ms )) -gt $(( MAX_HOLD_MS + 500 )) ]; then
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
        echo $(( $(now_ms) + SUPPRESS_MS )) > "$DFLAG"
        if [ "$ONLY_UNLOCKED" = 1 ] && [ "$(keyguard_locked)" = 1 ]; then log "double ignored (locked)"
        else log "double tap (BTN_C from HAL)"; fire "$DOUBLE_CMD" double; fi
        ;;
    esac
  done &
}

apply_native() {
  # 模块自己执行双击动作时，必须清掉系统原生绑定，否则一次双击会触发两个动作
  [ -n "$DOUBLE_CMD" ] && NATIVE_DOUBLE=noop # 双击由本进程接管时，关掉系统原生绑定，避免一次双击触发两次
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
  # ① pidfile 里那个若还活着，先请它退出（SIGTERM，1 秒后仍在就 SIGKILL）
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
  # ② 再按字段精确扫一遍（只认「sh <本脚本绝对路径> run」三字段全等，避免误杀命令行含同样字样的 shell）
  for p in $(ps -A -o PID,ARGS 2>/dev/null | awk '$2=="sh" && $3 ~ /\/fpgesture\.sh$/ && $4=="run" { print $1 }'); do
    [ "$p" = "$$" ] && continue
    kill "$p" 2>/dev/null && log "killed duplicate daemon pid=$p"
    sleep 1
    kill -0 "$p" 2>/dev/null && { kill -9 "$p" 2>/dev/null; log "duplicate pid=$p needed SIGKILL"; }
  done
  echo $$ > "$PIDF"
  log "start tap<=${TAP_MAX_MS}ms hold=${HOLD_MS}-${MAX_HOLD_MS}ms double=${DOUBLE_MS}ms locked(t/h/d)=${TAP_LOCKED}/${HOLD_LOCKED}/${DOUBLE_LOCKED}"
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
last_edge=0; burst_start=0; burst_edges=0; storm=0; swallow_next=0; pending_release=0; pending_dur=0; ct_locked=0; last_count=0; STUB_LOCKED=0; }
  keyguard_locked() { echo "$STUB_LOCKED"; }
  TAP_CMD=x; HOLD_CMD=x; DOUBLE_CMD=x
  TAP_MAX_MS=800; HOLD_MS=1500; MAX_HOLD_MS=3000; DOUBLE_MS=400; SUPPRESS_MS=800
  TAP_LOCKED=0; HOLD_LOCKED=0; DOUBLE_LOCKED=0

  rst; sample 0 1000; sample 1 1020; sample 2 1120; sample 2 1600
  chk "tap" "tap " "$EV"

  rst; sample 0 2000; sample 1 2020; sample 2 4020; sample 2 4400
  chk "hold" "hold " "$EV"

  rst; sample 0 5000; sample 1 5020; sample 2 9020; sample 2 9500
  chk "too long cancelled" "" "$EV"

  rst; sample 0 12000; sample 1 12020; sample 2 13020; sample 2 13500
  chk "dead zone ignored" "" "$EV"

  # 现象①：认证风暴（密集且持续 >1.2s）→ 完全抑制，不得打出幻影双击
  rst; i=0; while [ $i -lt 12 ]; do sample $((i+1)) $((30000 + i*150)); i=$((i+1)); done
  chk "auth storm suppressed" "" "$EV"

  # 现象②：风暴后 2s 冷却期内不响应；冷却后再点必须正常（且不得被判成长按）
  sample 13 32000; sample 14 32300; sample 14 34300
  sample 15 36000; sample 16 36300; sample 16 38300
  chk "cooldown swallows first touch, later tap works" "tap " "$EV"

  # 双击交给系统原生（HAL 自己报 306）→ 我们不得出手
  rst; sample 1 6000; sample 2 6060; sample 3 6120; sample 4 6180; sample 4 7000
  chk "double-tap left to native" "" "$EV"

  rst; STUB_LOCKED=1; sample 0 10000; sample 1 10020; sample 2 10120; sample 2 10400; sample 2 10800
  chk "locked tap blocked" "" "$EV"

  rst; STUB_LOCKED=1; TAP_LOCKED=1; sample 0 11000; sample 1 11020; sample 2 11120; sample 2 11400; sample 2 11800
  TAP_LOCKED=0
  chk "locked tap allowed" "tap " "$EV"

  rst; STUB_LOCKED=1; sample 0 12000; sample 1 12020; sample 2 14020; sample 2 14400
  chk "locked hold blocked" "" "$EV"

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
