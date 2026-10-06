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

TAP_CMD=""; HOLD_CMD=""; DOUBLE_CMD=""
TAP_MAX_MS=800; HOLD_MS=1500; MAX_HOLD_MS=3000; DOUBLE_MS=400; SUPPRESS_MS=800; POLL=0.05
QUIET_MS=250; STORM_MIN_EDGES=4; STORM_SPAN_MS=700; SETTLE_MS=700
TAP_LOCKED=0; HOLD_LOCKED=0; DOUBLE_LOCKED=0; NATIVE_DOUBLE=keep; prev_native=

DRY=0; EV=""
touching=0; down_ms=0; pending=0; suppress=0; in_suppress=0; swallow_up=0
last_edge=0; burst_start=0; burst_edges=0; storm=0; swallow_next=0; double_armed=0
ct_locked=0; last_count=0; stat_edges=0; stat_acts=0

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

edge() { # edge <now_ms> - one IRQ edge toggles the touch state
  t=$1
  stat_edges=$(( stat_edges + 1 ))
  gap=$(( t - last_edge ))
  [ "$last_edge" = 0 ] && gap=999999
  # --- 风暴过滤：密集边沿持续过久 = 指纹认证/扫描，不是人手势 ---
  if [ "$gap" -lt "$QUIET_MS" ]; then
    [ "$burst_start" = 0 ] && burst_start=$t
    burst_edges=$(( burst_edges + 1 ))
    if [ "$storm" = 0 ] && [ "$burst_edges" -ge "$STORM_MIN_EDGES" ] && [ $(( t - burst_start )) -ge "$STORM_SPAN_MS" ]; then
      storm=1; touching=0; pending=0; double_armed=0
      log "storm: ${burst_edges} edges over $(( t - burst_start ))ms (auth/scan?) - suppressing"
    fi
  else
    # 串结束 → 结算延迟的双击（串内判成风暴的，这里已清零，不会结算）
    if [ "$double_armed" != 0 ]; then
      double_armed=0
      if [ "$storm" = 1 ]; then log "double cancelled (storm)"
      elif [ "$ct_locked" = 1 ] && [ "$DOUBLE_LOCKED" != 1 ]; then log "double ignored (locked)"
      else log "double tap"; fire "$DOUBLE_CMD" double; fi
    fi
    [ "$storm" = 1 ] && { storm=0; log "storm ended"; }
    burst_start=0; burst_edges=1
  fi
  last_edge=$t
  [ "$storm" = 1 ] && return
  # --- 失配安全网：吞掉强制复位后的第一个边沿（否则抬起会被当成按下） ---
  [ "$swallow_next" = 1 ] && { swallow_next=0; log "swallowed edge after reset"; return; }
  # --- 按下门槛：必须前一段安静，否则是余波/伪边沿 ---
  if [ "$touching" = 0 ] && [ "$gap" -lt "$QUIET_MS" ] && [ "$pending" = 0 ]; then
    log "spurious edge (gap ${gap}ms) ignored"
    return
  fi
  if [ "$touching" = 0 ]; then
    touching=1; down_ms=$t; in_suppress=0
    [ "$suppress" != 0 ] && [ "$t" -lt "$suppress" ] && { in_suppress=1; return; }
    ct_locked=$(keyguard_locked)
    if [ "$pending" != 0 ]; then
      pending=0; suppress=$(( t + SUPPRESS_MS )); swallow_up=1; double_armed=$t
      log "double armed (settle at burst end)"
    else
      swallow_up=0
    fi
  else
    touching=0
    [ "$in_suppress" = 1 ] && { in_suppress=0; return; }
    [ "$swallow_up" = 1 ] && { swallow_up=0; return; }
    dur=$(( t - down_ms ))
    if [ "$dur" -le "$TAP_MAX_MS" ]; then
      log "tap ${dur}ms (pending)"; pending=$t
    elif [ "$dur" -ge "$HOLD_MS" ] && [ "$dur" -le "$MAX_HOLD_MS" ]; then
      if [ "$ct_locked" = 1 ] && [ "$HOLD_LOCKED" != 1 ]; then log "hold ${dur}ms ignored (locked)"
      else log "hold ${dur}ms"; fire "$HOLD_CMD" hold; fi
    elif [ "$dur" -gt "$MAX_HOLD_MS" ]; then
      log "cancelled ${dur}ms (> ${MAX_HOLD_MS}ms - mis-touch)"
    else
      log "dead zone ${dur}ms (${TAP_MAX_MS}~${HOLD_MS}) ignored"
    fi
  fi
}

sample() { # sample <irq_count> <now_ms>
  cnt=$1; t=$2
  delta=$(( cnt - last_count )); last_count=$cnt
  while [ "$delta" -gt 0 ]; do edge "$t"; delta=$(( delta - 1 )); done
  if [ "$double_armed" != 0 ] && [ $(( t - double_armed )) -ge "$SETTLE_MS" ]; then
    double_armed=0
    if [ "$storm" = 1 ]; then log "double cancelled (storm)"
    elif [ "$ct_locked" = 1 ] && [ "$DOUBLE_LOCKED" != 1 ]; then log "double ignored (locked)"
    else log "double tap"; fire "$DOUBLE_CMD" double; fi
  fi
  if [ "$touching" = 1 ] && [ $(( t - down_ms )) -gt $(( MAX_HOLD_MS + 500 )) ]; then
    log "state reset: down for $(( t - down_ms ))ms with no release (desync guard)"
    touching=0; pending=0; swallow_next=1
  fi
  if [ "$pending" != 0 ] && [ $(( t - pending )) -ge "$DOUBLE_MS" ]; then
    pending=0
    if [ "$ct_locked" = 1 ] && [ "$TAP_LOCKED" != 1 ]; then log "single tap ignored (locked)"
    else log "single tap"; fire "$TAP_CMD" tap; fi
  fi
}

irq_count() {
  awk -v n="$IRQ_NAME" '$NF ~ n { s=0; for (i=2; i<=NF; i++) { if ($i !~ /^[0-9]+$/) break; s += $i } print s+0; exit }' "$IRQ"
}

refresh_packages() {
  [ -d "$SHARE_DIR" ] || return 0
  pm list packages -3 2>/dev/null | sed 's/^package://' | sort -u > "$SHARE_DIR/packages.txt" 2>/dev/null
}

apply_native() { # 双击由本进程接管时，关掉系统原生绑定，避免一次双击触发两次
  [ "$NATIVE_DOUBLE" = "$prev_native" ] && return 0
  case "$NATIVE_DOUBLE" in
    off)   settings delete system fingerprint_double_tap 2>/dev/null; prev_native=off
           log "native double-tap binding removed (fpgesture handles it)" ;;
    torch) settings put system fingerprint_double_tap turn_on_torch 2>/dev/null; prev_native=torch
           log "native double-tap = torch" ;;
    *)     prev_native=keep ;;
  esac
}

run() {
  load
  apply_native
  echo $$ > "$PIDF"
  log "start tap<=${TAP_MAX_MS}ms hold=${HOLD_MS}-${MAX_HOLD_MS}ms double=${DOUBLE_MS}ms locked(t/h/d)=${TAP_LOCKED}/${HOLD_LOCKED}/${DOUBLE_LOCKED}"
  last_count=$(irq_count)
  [ -z "$last_count" ] && { log "FATAL: no '$IRQ_NAME' in $IRQ"; exit 1; }
  log "irq baseline=$last_count"
  refresh_packages &
  n=0
  while :; do
    sleep "$POLL"
    sample "$(irq_count)" "$(now_ms)"
    n=$(( n + 1 ))
    [ $(( n % 40 )) -eq 0 ] && { load; apply_native; }
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
  rst() { EV=""; touching=0; down_ms=0; pending=0; suppress=0; in_suppress=0; swallow_up=0
last_edge=0; burst_start=0; burst_edges=0; storm=0; swallow_next=0; double_armed=0; ct_locked=0; last_count=0; STUB_LOCKED=0; }
  keyguard_locked() { echo "$STUB_LOCKED"; }
  TAP_CMD=x; HOLD_CMD=x; DOUBLE_CMD=x
  TAP_MAX_MS=800; HOLD_MS=1500; MAX_HOLD_MS=3000; DOUBLE_MS=400; SUPPRESS_MS=800
  TAP_LOCKED=0; HOLD_LOCKED=0; DOUBLE_LOCKED=0

  rst; sample 0 1000; sample 1 1020; sample 2 1120; sample 2 1600
  chk "tap" "tap " "$EV"

  rst; sample 0 2000; sample 1 2020; sample 2 4020
  chk "hold" "hold " "$EV"

  rst; sample 0 5000; sample 1 5020; sample 2 9020; sample 2 9500
  chk "too long cancelled" "" "$EV"

  rst; sample 0 12000; sample 1 12020; sample 2 13020; sample 2 13500
  chk "dead zone ignored" "" "$EV"

  # 现象①：认证风暴（密集且持续 >1.2s）→ 完全抑制，不得打出幻影双击
  rst; i=0; while [ $i -lt 12 ]; do sample $((i+1)) $((30000 + i*150)); i=$((i+1)); done
  chk "auth storm suppressed" "" "$EV"

  # 现象②：风暴之后，两次相隔 2s 的点按必须各算一次轻触（不得被判成长按）
  sample 13 32000; sample 14 32300; sample 14 34300
  sample 15 36000; sample 16 36300; sample 16 38300
  chk "two taps after storm stay taps" "tap tap " "$EV"

  rst; sample 1 6000; sample 2 6060; sample 3 6120; sample 4 6180; sample 4 7000
  chk "double" "double " "$EV"

  rst; STUB_LOCKED=1; sample 0 10000; sample 1 10020; sample 2 10120; sample 2 10600
  chk "locked tap blocked" "" "$EV"

  rst; STUB_LOCKED=1; TAP_LOCKED=1; sample 0 11000; sample 1 11020; sample 2 11120; sample 2 11600
  TAP_LOCKED=0
  chk "locked tap allowed" "tap " "$EV"

  rst; STUB_LOCKED=1; sample 0 12000; sample 1 12020; sample 2 14020
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
