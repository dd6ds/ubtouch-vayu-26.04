#!/bin/bash
# Collect boot logs from a vayu that hangs at the Ubuntu Touch splash (no adb).
# Phone in FASTBOOT mode (hold Power + Vol- ~10 s until fastboot appears).
# Boots OrangeFox temporarily (nothing is flashed), mounts /data/ubuntu.img and:
#   - pulls pstore (kernel log of the hung boot), /var/log, the systemd journal
#   - enables a persistent journal, so the NEXT hung boot leaves logs behind
# Usage: ./debug-boot.sh [path/to/orangefox.img]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OFOX=${1:-$(ls "$HERE"/images/orangefox-*.img "$HERE"/vayu-ubuntu-touch-26.04-flashkit/images/orangefox-*.img 2>/dev/null | head -1)}
[ -f "$OFOX" ] || { echo "OrangeFox image not found, pass it as argument"; exit 1; }
OUT="$HERE/bootlogs-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"

wait_recovery() { for i in $(seq 1 90); do adb devices | grep -q "recovery$" && return 0; sleep 1; done; echo "no adb recovery device"; exit 1; }

echo "==> waiting for fastboot"; fastboot devices | grep -q . || { echo "phone not in fastboot mode"; exit 1; }
echo "==> booting OrangeFox (temporary): $OFOX"
fastboot boot "$OFOX"
wait_recovery; sleep 5

echo "==> pstore (kernel log of the previous boot)"
adb shell 'ls /sys/fs/pstore/ 2>/dev/null'
adb pull /sys/fs/pstore "$OUT/pstore" >/dev/null 2>&1 || echo "   (pstore empty - a forced reset from the hang usually fills it)"

echo "==> mounting /data and ubuntu.img"
adb shell 'umount /data 2>/dev/null; mount -t ext4 /dev/block/by-name/userdata /data' || true
adb shell 'mkdir -p /tmp/ut && mount -o loop,rw /data/ubuntu.img /tmp/ut && echo mounted'
adb shell 'cat /tmp/ut/etc/system-image/channel.ini 2>/dev/null | grep -E "build_number|version_detail"' | tee "$OUT/channel.txt"
adb shell 'ls -la /data/' > "$OUT/data-ls.txt"

echo "==> pulling logs"
adb shell 'cd /tmp/ut/var/log && tar -cf /tmp/varlog.tar . 2>/dev/null; ls -la /tmp/varlog.tar'
adb pull /tmp/varlog.tar "$OUT/varlog.tar" >/dev/null && (mkdir -p "$OUT/varlog" && tar -xf "$OUT/varlog.tar" -C "$OUT/varlog" && rm "$OUT/varlog.tar")
adb shell 'ls /data/user-data 2>/dev/null; ls /data/android-data 2>/dev/null | head' > "$OUT/data-dirs.txt" || true

# UT redirects /var/log to /data/system-data (writable paths) - the real logs are there
echo "==> pulling /data/system-data/var/log (journal, lightdm)"
adb shell 'cd /data/system-data/var/log 2>/dev/null && tar -cf /tmp/sdlog.tar . 2>/dev/null'
adb pull /tmp/sdlog.tar "$OUT/sdlog.tar" >/dev/null 2>&1 && mkdir -p "$OUT/system-data-log" && tar -xf "$OUT/sdlog.tar" -C "$OUT/system-data-log" && rm "$OUT/sdlog.tar"
adb shell 'cat /data/user-data/phablet/.xsession-errors 2>/dev/null' > "$OUT/xsession-errors.txt" || true

# core dumps written by the DEBUG build (build-2604.sh, /usr/local/sbin/vayu-coresave)
echo "==> pulling core dumps (/data/vayu-cores)"
if adb shell 'ls /data/vayu-cores/*.core' >/dev/null 2>&1; then
  adb pull /data/vayu-cores "$OUT/cores" >/dev/null
  ls -lh "$OUT/cores"
  adb shell 'rm -f /data/vayu-cores/*'   # make room for the next crashes
else
  echo "   none (image built with DEBUG=0, or nothing crashed yet)"
fi

echo "==> enabling persistent journal (takes effect on the next boot)"
adb shell 'mkdir -p /tmp/ut/var/log/journal && chmod 2755 /tmp/ut/var/log/journal; ls -ld /tmp/ut/var/log/journal'

adb shell 'sync; umount /tmp/ut; umount /data' || true
echo
echo "Logs: $OUT"
ls -R "$OUT" | head -50
if command -v journalctl >/dev/null && ls "$OUT"/system-data-log/journal/*/*.journal >/dev/null 2>&1; then
  journalctl -D "$OUT"/system-data-log/journal -b 0 --no-pager -p warning > "$OUT/journal-warnings.txt" 2>&1 || true
  echo "journal (warnings+): $OUT/journal-warnings.txt"
fi
echo
echo "Next: 'adb reboot' -> let it hang ~5 min -> Power+Vol- 10 s into fastboot -> run this script again."
