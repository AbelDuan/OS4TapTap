#!/system/bin/sh
echo "===== A. keyguard candidates (dumpsys window) ====="
dumpsys window 2>/dev/null | grep -iE 'isKeyguard|KeyguardShowing|mDreamingLockscreen|mShowingLockscreen|showingLockscreen|mSystemUIShowing|mAwake|mScreenOnFully|mInteractive' | head -20
echo ""
echo "===== B. screen state (dumpsys power) ====="
dumpsys power 2>/dev/null | grep -iE 'Display Power|mScreenState|mHoldingDisplay|mWakefulness|mInteractive' | head -10
echo ""
echo "===== C. backlight files ====="
for f in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
  [ -r "$f" ] && { read b < "$f"; echo "$f = $b"; }
done
echo ""
echo "===== D. keyguard service state ====="
dumpsys activity 2>/dev/null | grep -iE 'keyguard|locked' | head -8
echo ""
echo "===== E. fpgesture live config ====="
cat /data/adb/fpgesture/config 2>/dev/null
echo ""
echo "===== F. fpgesture pid/proc ====="
cat /data/adb/fpgesture/fpgesture.pid 2>/dev/null; echo ""
ps -A -o PID,PPID,ARGS | grep -E 'fpgesture|getevent' | grep -v grep
echo ""
echo "===== G. recent events.log (all lines incl. storm/auth) ====="
grep -E 'storm|auth|blocked|re-armed|suppress' /data/adb/fpgesture/events.log 2>/dev/null | tail -30
