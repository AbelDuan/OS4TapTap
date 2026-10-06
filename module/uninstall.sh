#!/system/bin/sh
PIDF=/data/adb/fpgesture/fpgesture.pid
[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
rm -f "$PIDF"
exit 0
