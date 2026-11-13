#!/bin/bash
# Builds a complete Ubuntu Touch 26.04 (EARLY, daily channel) flash kit for the Xiaomi Poco X3 Pro (vayu).
# Downloads everything that is needed, builds ubuntu.img without root (fakeroot + mke2fs -d).
#
#   ./build-2604.sh           -> ./vayu-ubuntu-touch-26.04-flashkit/
#   ./build-2604.sh --pack    -> additionally vayu-ubuntu-touch-26.04-flashkit.tar.zst
#
# Needs: curl wget python3 unzip fakeroot e2fsprogs(>=1.43) xz-utils [zstd for --pack]
# Disk:  ~16 GB free during the build (downloads are cached in ./dl)
set -e
umask 022
cd "$(dirname "$(readlink -f "$0")")"
HERE=$PWD
PACK=0; [ "$1" = "--pack" ] && PACK=1

# 26.04-1.x is a hidden early-test channel (forums.ubports.com/topic/12312). vayu is not in it,
# but the rootfs is generic: every android9plus device there ships the same rootfs tarball.
CH=${CH:-26.04-1.x/arm64/android9plus/daily}
REF_CANDIDATES="${REF:-FP5 Spacewar redfin yggdrasil}"   # first one found in the channel is used
SI=https://system-image.ubports.com
API=https://gitlab.com/api/v4/projects/36168575     # ubports .../xiaomi-poco-x3-pro/xiaomi-vayu
HAL=https://ci.ubports.com/job/UBportsCommunityPortsJenkinsCI/job/ubports%252Fporting%252Fcommunity-ports%252Fjenkins-ci%252Fgeneric_arm64/job/halium-11.0/lastSuccessfulBuild/artifact/halium_halium_arm64.tar.xz
DROID_REL=https://github.com/droidian-vayu/droidian-images/releases/download/snapshots
DROID_ZIP=droidian-UNOFFICIAL-phosh-phone-xiaomi_vayu-api30-arm64_20241118.zip
OFOX_URL=https://dl.orangefox.download/67f28343724ba9ed7374ce35   # OrangeFox R11.3 stable vayu
OFOX_SHA=5de5d482b02ced8a9416068314ac45aab94ea01c8a2e50589b2bc11b24dd72be  # its recovery.img
KIT=vayu-ubuntu-touch-26.04-flashkit
OUT=out-2604

REF=""
for r in $REF_CANDIDATES; do
  curl -fs -o /dev/null https://system-image.ubports.com/$CH/$r/index.json && { REF=$r; break; }
done
[ -n "$REF" ] || { echo "no reference device found in channel $CH (tried: $REF_CANDIDATES)"; exit 1; }
echo "channel: $CH   reference device for rootfs/version: $REF"

for t in curl wget python3 unzip fakeroot mke2fs xz sha256sum; do
  command -v $t >/dev/null || { echo "missing tool: $t"; exit 1; }
done
[ $PACK = 1 ] && { command -v zstd >/dev/null || { echo "missing tool: zstd"; exit 1; }; }

step() { echo; echo "==> $*"; }
rm -rf stage $OUT $KIT; mkdir -p $OUT dl out

# ---------------------------------------------------------------- downloads
# Kernel 4.14.221-perf+: run kernel/build-kernel.sh first, it puts its device tarball into out/.
# Without it the original port CI build (kernel 4.14.190-halium) is downloaded from GitLab.
if [ ! -f out/device_vayu_usrmerge.tar.xz ]; then
  step "vayu port: latest CI build (kernel 4.14.190-halium, boot.img, dtbo.img, device overlay)"
  echo "note: for kernel 4.14.221-perf+ run kernel/build-kernel.sh before this script"
  # (the /jobs API needs a login, /pipelines does not)
  JOB=$(curl -s "$API/pipelines?ref=master&status=success&per_page=20" | python3 -c "
import json,sys,urllib.request
for p in json.load(sys.stdin):
    jobs=json.load(urllib.request.urlopen('$API/pipelines/%d/jobs' % p['id']))
    for j in jobs:
        if j['name']=='build' and j['status']=='success' and any(a['file_type']=='archive' for a in j.get('artifacts',[])):
            print(j['id']); sys.exit()
sys.exit('no vayu CI build with artifacts found (expired?) - put out/device_vayu_usrmerge.tar.xz next to this script')")
  echo "CI build job: $JOB"
  curl -fsSL -o dl/build-artifact.zip "$API/jobs/$JOB/artifacts"
  unzip -o -q dl/build-artifact.zip 'out/*'
fi

KREL=$(xzcat out/device_vayu_usrmerge.tar.xz | tar -tf - | sed -n 's|^system/usr/lib/modules/\([^/]*\)/$|\1|p' | head -1)
echo "kernel in device overlay: ${KREL:-unknown}"

step "Ubuntu Touch rootfs ($CH)"
ROOTFS=$(curl -fs $SI/$CH/$REF/index.json | python3 -c "
import json,sys; d=json.load(sys.stdin); f=[i for i in d['images'] if i['type']=='full'][-1]
print([x['path'] for x in f['files'] if '/rootfs-' in x['path']][0])")
echo "$ROOTFS"
[ -f dl/$(basename $ROOTFS) ] || wget -q --show-progress $SI$ROOTFS -O dl/$(basename $ROOTFS)

step "Halium 11 generic arm64"
[ -f dl/halium_halium_arm64.tar.xz ] || wget -q --show-progress $HAL -O dl/halium_halium_arm64.tar.xz

step "Droidian vayu image (for vendor.img + vbmeta.img, ~2 GB)"
[ -f dl/$DROID_ZIP ] || wget -q --show-progress $DROID_REL/$DROID_ZIP -O dl/$DROID_ZIP
wget -q $DROID_REL/SHA256SUMS -O dl/droidian.SHA256SUMS
(cd dl && tr -d '\r' < droidian.SHA256SUMS | grep -F "20241118.zip" | head -1 | sed 's/ .*//' | sed "s|\$|  $DROID_ZIP|" | sha256sum -c -)
unzip -o -q -j dl/$DROID_ZIP data/vendor.img data/vbmeta.img -d dl/droidian

step "OrangeFox recovery R11.3 (vayu)"
for c in "$HERE/../orangefox" "$HERE/../vayu-ubuntu-touch-24.04-flashkit/build/dl"; do
  [ -f dl/OrangeFox-R11.3-Stable-vayu.zip ] || { [ -f "$c/OrangeFox-R11.3-Stable-vayu.zip" ] && cp "$c/OrangeFox-R11.3-Stable-vayu.zip" dl/; } || true
done
[ -f dl/OrangeFox-R11.3-Stable-vayu.zip ] || curl -fL -o dl/OrangeFox-R11.3-Stable-vayu.zip $OFOX_URL
unzip -o -q -j dl/OrangeFox-R11.3-Stable-vayu.zip recovery.img -d dl/orangefox
echo "$OFOX_SHA  dl/orangefox/recovery.img" | sha256sum -c -

# ---------------------------------------------------------------- build ubuntu.img
step "Building ubuntu.img"
# OS build info (Settings -> About -> OS build "26.04-1.x"): take the version tarball of the
# reference device from the same channel (build_number + version_detail with tag=26.04-1.x)
# and switch it to vayu. Without it the system only shows "Ubuntu Touch 26.04".
VERSION_TAR=$(curl -fs $SI/$CH/$REF/index.json | python3 -c "
import json,sys; d=json.load(sys.stdin); f=[i for i in d['images'] if i['type']=='full'][-1]
print([x['path'] for x in f['files'] if '/version-' in x['path']][0])")
rm -rf ver; mkdir -p ver
curl -fsSL $SI$VERSION_TAR | xzcat | tar -xf - -C ver
DEVICE_BUILD=$(cat out/device_vayu_usrmerge.tar.build 2>/dev/null | tr -d '[:space:]')
python3 - ver/system/etc/system-image/channel.ini vayu "${DEVICE_BUILD:-vayu}" <<'PYEOF'
import re, sys
p, dev, devbuild = sys.argv[1:]
s = open(p).read()
s = re.sub(r"(?m)^device: .*$", "device: " + dev, s)
s = re.sub(r"device=[^,\n]*", "device=" + devbuild, s)
open(p, "w").write(s)
PYEOF
grep -E "^(channel|device|build_number|version_detail):" ver/system/etc/system-image/channel.ini
grep -q "tag=" ver/system/etc/system-image/channel.ini
tar cJf dl/version.tar.xz -C ver --owner=root --group=root system; rm -rf ver
# Telephony fix: use ofono-binder-plugin + QTI IMS extension instead of ofono-ril-plugin.
# With the ril plugin, SMS that the network delivers over IMS never reach ofono
# (they only arrive in a burst after flight mode / reboot).
cat > dl/vayu-binder.conf <<'BINDER_CONF_EOF'
# ofono-binder-plugin configuration for Xiaomi Poco X3 Pro (vayu)
# The QTI extension (qtibinderpluginext) talks to vendor.qti.hardware.radio.ims::IImsRadio
# (imsradio0/imsradio1) so that SMS delivered over IMS are received.

[Settings]
ExpectSlots = slot1,slot2
SetRadioCapability = off

# slot defaults (apply to slot1 and slot2)
radioInterface = 1.4
extPlugin = qti
emptyPinQuery = false

[slot1]
path = /ril_0
slot = 0

[slot2]
path = /ril_1
slot = 1
BINDER_CONF_EOF
# DEBUG=1 (default while 26.04 is an early build): catch the first crashes of Lomiri & co.
# as core dumps in /userdata/vayu-cores (= /data/vayu-cores in OrangeFox), max. 3 cores.
# Fetch them with ./debug-boot.sh. DEBUG=0 ./build-2604.sh builds a clean image.
DEBUG=${DEBUG:-1}
rm -rf dl/debug; mkdir -p dl/debug
if [ "$DEBUG" = 1 ]; then
cat > dl/debug/vayu-coresave <<'CORESAVE_EOF'
#!/bin/sh
# kernel.core_pattern pipe handler: $1=pid $2=comm $3=signal; core arrives on stdin
PATH=/usr/sbin:/usr/bin:/sbin:/bin
D=/userdata/vayu-cores
mkdir -p "$D" || { cat >/dev/null; exit 0; }
if [ "$(ls "$D"/*.core 2>/dev/null | wc -l)" -ge 3 ]; then cat >/dev/null; exit 0; fi
B="$D/$(date +%s)-$2-$1"
cp "/proc/$1/maps" "$B.maps" 2>/dev/null
tr '\0' ' ' < "/proc/$1/cmdline" > "$B.cmdline" 2>/dev/null
echo "signal=$3 comm=$2 pid=$1" > "$B.info"
cat > "$B.core"
sync
CORESAVE_EOF
cat > dl/debug/90-vayu-coredump.conf <<'SYSCTL_EOF'
# vayu 26.04 debug build: send core dumps to /usr/local/sbin/vayu-coresave
kernel.core_pattern=|/usr/local/sbin/vayu-coresave %P %e %s
kernel.core_pipe_limit=4
SYSCTL_EOF
printf '[Service]\nLimitCORE=infinity\n' > dl/debug/90-vayu-core.conf
# LD_PRELOAD crash reporter (debug/vayucrash.c): writes ~/vayu-crash-N.txt with registers,
# backtrace and memory map when Lomiri crashes (independent of kernel.core_pattern).
if command -v aarch64-linux-gnu-gcc >/dev/null && [ -f "$HERE/debug/vayucrash.c" ]; then
  aarch64-linux-gnu-gcc -shared -fPIC -O1 -pthread -o dl/debug/libvayucrash.so "$HERE/debug/vayucrash.c"
  printf 'Environment=LD_PRELOAD=/usr/local/lib/libvayucrash.so\n' >> dl/debug/90-vayu-core.conf
else
  echo "note: aarch64-linux-gnu-gcc missing - no crash reporter in the debug image"
fi
fi
# qtmir fix (26.04): qtmir sets the panel scale to GridUnit/8 (vayu: 21/8 = 2.625). On the
# mir1 code path ScreensModel::updateInternal() then matches Mir DisplayBuffers to screens by
# comparing the buffer view_area (logical px, 411x914) with the screen geometry (physical px,
# 1080x2400) -> never matches -> PlatformScreen::m_renderTarget stays NULL -> Lomiri SEGV in
# PlatformScreen::makeCurrent(), endless restart loop at the boot splash.
# Patch: drop the width/height part of that comparison (top-left is still checked).
# vayu has a single panel and no video out, so the first screen at (0,0) is the right one.
cat > dl/fix-qtmir-scale.py <<'QTMIR_FIX_EOF'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
# cmp w23,w3 / b.ne / cmp w26,w0 / b.ne / cmp w20,w2 / b.ne / cmp w1,w27 / b.ne  (all b.ne -> same target)
sig = bytes.fromhex("ff02036b 61feff54 5f03006b 21feff54 9f02026b e1fdff54 3f001b6b a1fdff54".replace(" ", ""))
nop = bytes.fromhex("1f2003d5")
n = b.count(sig)
if n == 1:
    i = b.find(sig)
    b[i + 12:i + 16] = nop    # b.ne after cmp w26,w0  (right edge)
    b[i + 28:i + 32] = nop    # b.ne after cmp w1,w27  (bottom edge)
    print("qtmir scale fix 1 (DisplayBuffer matching) applied at file offset 0x%x" % i)
else:
    print("WARNING: qtmir scale fix 1: signature found %d times - qtmir changed, NOT patched" % n)
# Fix 2: DisplayConfigurationPolicy ctor: "scale = 1.0; if (GRID_UNIT_PX set) scale = GRID_UNIT_PX/8".
# The 26.04 mir1 (build 2026-11-12) now really applies that output scale (logical 411x914),
# while qtmir's mir1 path keeps rendering/input in physical pixels -> tiny cut-out picture
# and misplaced touch. NOP the branch so Mir always gets scale 1 (= effective 24.04 behaviour).
# GRID_UNIT_PX stays exported, so lomiri-ui-toolkit still sizes the UI with grid unit 21.
# fmov s0,#1.0 / tbnz w0,#0,<compute> / str s0,[x19]
sig2 = bytes.fromhex("00102e1e" "40030037" "600200bd")
n2 = b.count(sig2)
if n2 == 1:
    j = b.find(sig2)
    b[j + 4:j + 8] = nop
    print("qtmir scale fix 2 (Mir output scale = 1) applied at file offset 0x%x" % j)
else:
    print("WARNING: qtmir scale fix 2: signature found %d times - NOT patched" % n2)
open(p, "wb").write(b)
QTMIR_FIX_EOF
LIST="dl/$(basename $ROOTFS) dl/halium_halium_arm64.tar.xz out/device_vayu_usrmerge.tar.xz dl/version.tar.xz"
fakeroot -- bash -ec '
umask 022
mkdir -p stage; cd stage
first=1
for f in '"$LIST"'; do
  echo "extract $f"
  if [ $first = 1 ]; then
    xzcat ../$f | tar --numeric-owner -xf -; first=0
  else
    # overlays: keep existing dir modes and symlinks, strip group/other write from what they add
    xzcat ../$f | tar --numeric-owner --no-overwrite-dir --keep-directory-symlink -xf -
    xzcat ../$f | tar -tf - | grep "^system/." | sed "s|/$||" | while read p; do
      [ -L "$p" ] || [ -k "$p" ] || chmod go-w "$p" 2>/dev/null || true
    done
  fi
done
# telephony fix: ofono-binder-plugin (selected via device-info OfonoPlugin) + QTI IMS extension
install -m 644 ../dl/vayu-binder.conf system/etc/ofono/binder.conf
grep -q "^  OfonoPlugin:" system/etc/deviceinfo/devices/vayu.yaml || \
  sed -i "/^vayu:/a\\  OfonoPlugin: binder" system/etc/deviceinfo/devices/vayu.yaml
grep -q "^  OfonoPlugin: binder" system/etc/deviceinfo/devices/vayu.yaml
# qtmir scale fix (see fix-qtmir-scale.py above)
QTMIR_LIB=$(readlink -f system/usr/lib/aarch64-linux-gnu/libqt5mir1server.so.1 2>/dev/null || true)
if [ -f "$QTMIR_LIB" ]; then python3 ../dl/fix-qtmir-scale.py "$QTMIR_LIB"; else echo "note: libqt5mir1server.so.1 not found - qtmir scale fix skipped"; fi
# debug build: core dump capture (see DEBUG above)
if [ -f ../dl/debug/vayu-coresave ]; then
  install -D -m 755 ../dl/debug/vayu-coresave system/usr/local/sbin/vayu-coresave
  install -D -m 644 ../dl/debug/90-vayu-coredump.conf system/etc/sysctl.d/90-vayu-coredump.conf
  if [ -f ../dl/debug/libvayucrash.so ]; then
    install -D -m 644 ../dl/debug/libvayucrash.so system/usr/local/lib/libvayucrash.so
  fi
  for u in lomiri-full-greeter lomiri-full-shell lomiri-greeter; do
    install -D -m 644 ../dl/debug/90-vayu-core.conf system/etc/systemd/user/$u.service.d/90-vayu-core.conf
  done
  echo "debug: core dump capture installed"
fi
chmod 0755 system
SDV=$(ls system/usr/lib/*/systemd/libsystemd-shared-*.so system/usr/lib/systemd/libsystemd-shared-*.so 2>/dev/null | sed -n "s/.*shared-\([0-9]*\).*/\1/p" | head -1)
echo "systemd in rootfs: ${SDV:-unknown}"
if [ -n "$SDV" ] && [ "$SDV" -ge 256 ]; then echo "WARNING: systemd $SDV may not boot on the vayu 4.14 kernel"; fi
if [ -e system/var/lib/lxc/android/system.img ]; then mv system/var/lib/lxc/android/system.img system/var/lib/lxc/android/android-rootfs.img; fi
cp partitions/* ../'"$OUT"'/ 2>/dev/null || true
SZ=$(du -sm system | cut -f1); SZ=$((SZ+700))
echo "rootfs ${SZ}M"
truncate -s ${SZ}M ../'"$OUT"'/ubuntu.img
mkfs.ext4 -F -q -d system ../'"$OUT"'/ubuntu.img
'
rm -rf stage
e2fsck -fn $OUT/ubuntu.img >/dev/null

# ---------------------------------------------------------------- assemble kit
step "Assembling $KIT/"
mkdir -p $KIT/images $KIT/build/out
mv $OUT/ubuntu.img $OUT/boot.img $OUT/dtbo.img $KIT/images/
cp dl/droidian/vendor.img dl/droidian/vbmeta.img $KIT/images/
cp dl/orangefox/recovery.img $KIT/images/orangefox-R11.3-vayu-recovery.img
cp "$HERE/$(basename "$0")" $KIT/build/
if [ -f "$HERE/debug-boot.sh" ]; then install -m 755 "$HERE/debug-boot.sh" $KIT/debug-boot.sh; fi
cp out/device_vayu_usrmerge.tar.xz $KIT/build/out/
[ -f out/device_vayu_usrmerge.tar.build ] && cp out/device_vayu_usrmerge.tar.build $KIT/build/out/
if [ -d "$HERE/kernel" ]; then
  mkdir -p $KIT/build/kernel
  cp "$HERE"/kernel/build-kernel.sh "$HERE"/kernel/*.patch.xz $KIT/build/kernel/
fi
cat > $KIT/README.md <<'README_EN_EOF'
# Ubuntu Touch 26.04 for Xiaomi Poco X3 Pro (vayu) – Flash Kit

*Deutsche Version: [README.de.md](README.de.md)*

Unofficial Ubuntu Touch image for the Poco X3 Pro (codename **vayu**), built from:

| Part | Source |
|---|---|
| Rootfs | UBports **26.04-1.x daily** (Ubuntu 26.04), from system-image.ubports.com |
| Kernel / boot.img / dtbo.img / device overlay | Community port `ubports/porting/community-ports/android11/xiaomi-poco-x3-pro/xiaomi-vayu` (CI build 2026-10-19) |
| Halium | Halium 11 generic arm64 (UBports Jenkins) |
| vendor.img / vbmeta.img | Droidian vayu snapshot 2024-11-18 (MIUI vendor with Linux fixes) |
| Recovery | OrangeFox R11.3 stable for vayu (only booted temporarily, never installed) |
| Telephony | `ofono-binder-plugin` + QTI IMS extension instead of the port's default `ofono-ril-plugin` (needed to receive SMS, see [Troubleshooting](#troubleshooting)) |

> ⚠️ This is **not** an official UBports release and the device is **not** in the UBports installer.
> Flashing wipes **all data** on the phone. Use at your own risk.

> 🧪 **Early build.** 26.04-1.x is a hidden *daily* test channel of UBports. vayu is not part of it – this kit
> combines its generic rootfs with the vayu 24.04 port. Expect regressions (in the test thread e.g. Morph browser
> not starting, OpenStore/apps missing Qt5-era libraries). For daily use stay on the 24.04 kit.

## Hardware support

**Not yet tested on 26.04.** The status column shows what worked with the 26.04-2.2 kit on 2026-10-28 (same kernel, overlay, Halium and vendor) – re-test everything on 26.04.

| Function | Status |
|---|---|
| Wi-Fi | ❔ (24.04: ✅) |
| Bluetooth | ❔ (24.04: ✅) |
| Camera | ❔ (24.04: ✅) |
| Sound | ❔ (24.04: ✅) |
| Battery charging | ❔ (24.04: ✅) |
| Airplane mode | ❔ (24.04: ✅) |
| Hotspot | ❔ (24.04: ✅) |
| GPS | ❔ (24.04: ✅) |
| Mobile network / phone calls | ❔ (24.04: ✅) |
| SMS send / receive | ❔ (24.04: ✅) |
| Torchlight | ❔ (24.04: ✅) |
| Switching between cameras | ❔ (24.04: ✅) |
| Video | ❔ (24.04: ✅) |
| Data connection | ❔ (24.04: ✅) |
| PIN unlock | ❔ (24.04: ✅) |
| Volume control in calls | ❔ (24.04: ✅) |
| Battery percentage | ❔ (24.04: ✅) |
| Offline charging | ❔ (24.04: ✅) |
| SD card storage | ❔ (24.04: ✅) |
| Shutdown / Reboot | ❔ (24.04: ✅) |

<details><summary>Full feature matrix (layout of devices.ubuntu-touch.io)</summary>

✅ = works · ❔ = not tested yet

| Category | Feature | Status |
|---|---|---|
| Actors | Manual brightness | ❔ |
|  | Notification LED | ❔ |
|  | Torchlight | ❔ (24.04: ✅) |
|  | Vibration | ❔ |
| Camera | Flashlight | ❔ |
|  | Photo | ❔ (24.04: ✅) |
|  | Switching between cameras | ❔ (24.04: ✅) |
|  | Video | ❔ (24.04: ✅) |
| Cellular | Change audio routings | ❔ |
|  | Incoming, outgoing calls | ❔ (24.04: ✅) |
|  | Carrier info, signal strength | ❔ (24.04: ✅) |
|  | Data connection | ❔ (24.04: ✅) |
|  | Dual SIM functionality | ❔ |
|  | MMS in, out | ❔ |
|  | PIN unlock | ❔ (24.04: ✅) |
|  | SMS in, out | ❔ (24.04: ✅) |
|  | Voice in calls | ❔ (24.04: ✅) |
|  | LTE calling (VoLTE) | ❔ |
|  | Volume control in calls | ❔ (24.04: ✅) |
| Endurance | 24+ hours battery lifetime | ❔ |
|  | 7+ days stability | ❔ |
| GPU | Boot into UI | ❔ (24.04: ✅) |
|  | Hardware video playback | ❔ |
| Misc | AppArmor patches | ❔ |
|  | Battery percentage | ❔ (24.04: ✅) |
|  | Reset to factory defaults | ❔ |
|  | Offline charging | ❔ (24.04: ✅) |
|  | Online charging | ❔ (24.04: ✅) |
|  | Recovery image | ❔ |
|  | RTC time | ❔ |
|  | SD card storage | ❔ (24.04: ✅) |
|  | Shutdown / Reboot | ❔ (24.04: ✅) |
|  | Waydroid | ❔ |
|  | Wireless External monitor | ❔ |
| Network | Bluetooth | ❔ (24.04: ✅) |
|  | Flight mode | ❔ (24.04: ✅) |
|  | Hotspot | ❔ (24.04: ✅) |
|  | NFC | ❔ |
|  | WiFi | ❔ (24.04: ✅) |
| Sensors | Automatic brightness | ❔ |
|  | Double touch to wake | ❔ |
|  | Fingerprint reader | ❔ |
|  | GPS | ❔ (24.04: ✅) |
|  | Proximity | ❔ |
|  | Rotation | ❔ |
|  | Touchscreen | ❔ (24.04: ✅) |
| Sound | Earphones | ❔ |
|  | Loudspeaker | ❔ (24.04: ✅) |
|  | Microphone | ❔ (24.04: ✅) |
|  | Volume control | ❔ (24.04: ✅) |
| USB | ADB access | ❔ |
|  | MTP access | ❔ |

</details>

## Contents

```
flash.sh                  automated flashing script (Linux)
SHA256SUMS                checksums of the images
images/
  boot.img                UT kernel + halium initramfs
  dtbo.img                device tree overlay (matches the kernel)
  vbmeta.img              flashed with verification disabled
  vendor.img              Droidian vayu vendor
  orangefox-R11.3-vayu-recovery.img
  ubuntu.img              Ubuntu Touch 26.04 rootfs (copied to /data)
build/
  build-2604.sh           downloads + builds the complete kit, no root needed
  out/device_vayu_usrmerge.tar.xz
```

## Requirements & installation notes

Go through this list before you start – most failed installs come from a missing item here.

### Phone

- **Poco X3 Pro, codename `vayu`** (global/EEA model M2102J20SG). `flash.sh` aborts unless `fastboot getvar product` reports `vayu`.
- **Firmware base MIUI 12.5.x / Android 11** (check under *Settings → About phone*). Tested on MIUI 12.5.5 EEA.
  The kit only replaces boot, dtbo, vbmeta and vendor – the phone's own firmware partitions (modem, DSP, …) stay
  and have to match Halium 11. If the phone already runs MIUI 13/14 (Android 12/13), first flash a MIUI 12.5
  fastboot ROM for vayu with Xiaomi's `flash_all.sh`. Check `fastboot getvar anti` beforehand and never flash a ROM
  with a lower anti-rollback index than the phone reports.
- **Unlocked bootloader** (step 1) – plan for Xiaomi's waiting time of **168 hours (7 days)**.
- **Xiaomi account with a phone number** and a **SIM card with mobile data** to bind the account (step 1.1).
- **Battery at least 50 %** – the phone switches between bootloader, fastbootd and recovery and must not run out.
- **Back up everything**: unlocking and flashing wipe the internal storage completely.
  A microSD card is not touched, but remove it to be safe.

### Linux PC

- Linux with bash (developed on Linux Mint 22). `flash.sh` does not run on Windows; macOS is untested.
- Packages:

  | Distribution | Command |
  |---|---|
  | Debian / Ubuntu / Linux Mint | `sudo apt install adb fastboot android-sdk-platform-tools-common python3 python3-venv zstd` |
  | Fedora | `sudo dnf install android-tools python3 zstd` |
  | Arch / Manjaro | `sudo pacman -S android-tools android-udev python zstd` |

  `zstd` is only needed to unpack the `.tar.zst` release archive.
- **`fastboot` version 31 or newer** (`fastboot --version`) – older versions cannot switch to fastbootd
  (`fastboot reboot fastboot`), which is needed for `vendor.img`. If your distribution ships an older one, download
  Google's *SDK Platform-Tools* for Linux, unpack them and put them first in `PATH`:
  `export PATH="$HOME/platform-tools:$PATH"`.
- **USB permissions**: without a udev rule `fastboot devices` shows `no permissions`. The packages above
  (`android-sdk-platform-tools-common` / `android-udev`) install suitable rules. Otherwise create
  `/etc/udev/rules.d/51-android.rules`:

  ```
  SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0660", TAG+="uaccess"
  SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0660", TAG+="uaccess"
  ```

  then `sudo udevadm control --reload-rules && sudo udevadm trigger` and re-plug the phone.
- **USB cable / port**: a data cable, connected directly to the PC (no hub). If fastboot hangs or reports
  `FAILED (Status read failed)`, try a USB 2.0 port – the Xiaomi bootloader is picky with some USB 3 controllers.
- **Disk space**: about 6 GB for the unpacked kit, about 16 GB for a rebuild (see below).

### Pre-flight check

```bash
cd vayu-ubuntu-touch-26.04-flashkit
fastboot --version                       # 31 or newer
(cd images && sha256sum -c ../SHA256SUMS) # every line: OK
# phone in fastboot mode (power off, hold Vol- + Power), connected via USB:
fastboot devices                         # <serial>  fastboot
fastboot getvar product                  # product: vayu
fastboot getvar unlocked                 # unlocked: yes  (after step 1)
fastboot getvar anti                     # note the anti-rollback index
```

Time needed: unlocking up to 7 days (waiting time), flashing about 10 minutes, first boot 1–3 minutes.

---

## Step 1 – Unlock the bootloader (with miunlock in a Python venv)

Xiaomi's official Mi Unlock tool is Windows-only; **miunlock** is a Python reimplementation that works on Linux.

### 1.1 Prepare the Xiaomi account and the phone

1. The Xiaomi account **must have a phone number** attached, otherwise miunlock fails with
   `code 20041: your MI ID is not associated with a phone number`.
   Accounts that were created via *Sign in with Google* often have no phone number/password –
   in that case create a new Xiaomi account **registered with a phone number**.
2. On the phone: **Settings → About phone → All specs → tap "MIUI version" 7×** to enable developer mode
   (not "Kernel version" – that opens the CIT test menu).
3. **Settings → Additional settings → Developer options**:
   - enable **OEM unlocking** and **USB debugging**
   - sign in with the Xiaomi account (Settings → Mi Account)
4. Insert a **SIM card**, switch **Wi-Fi off** and **mobile data on**, then
   **Developer options → Mi Unlock status → Add account and device**. Wait for "Added successfully".
   The SIM can be removed afterwards.

### 1.2 Install miunlock in a venv

```bash
python3 -m venv ~/poco_X3_pro
source ~/poco_X3_pro/bin/activate
pip install miunlock          # no --user inside a venv!
```

### 1.3 Unlock

```bash
source ~/poco_X3_pro/bin/activate
adb reboot bootloader         # or: power off, hold Vol- + Power
fastboot devices              # must show the device
miunlock                      # log in with the SAME Xiaomi account
```

- First run usually returns `code 20036: Please unlock 168 hours later`.
  **Wait the full time (7 days) and do NOT add the account in Mi Unlock status again** – that restarts the timer.
- If miunlock prints a `notificationUrl`, open it in a browser, confirm your identity (SMS), then run miunlock again.
- After the waiting time run `miunlock` again; it fetches the signed token and unlocks the bootloader
  (if asked, run `fastboot oem unlock`). **The phone is wiped.**
- Check: `fastboot getvar unlocked` → `unlocked: yes`.

Useful checks: `fastboot getvar product` → `vayu`, `fastboot getvar anti` (anti-rollback index – never flash firmware older than it allows).

---

## Step 2 – Flash Ubuntu Touch

### 2a. Automatic

```bash
cd vayu-ubuntu-touch-26.04-flashkit
# phone in FASTBOOT mode (power off, hold Vol- + Power), connected via USB
./flash.sh
```

The script verifies checksums and the device, flashes everything, temporarily boots OrangeFox,
formats `/data` as ext4, copies `ubuntu.img` and reboots.
`./flash.sh --rootfs-only` only re-formats `/data` and copies a new `ubuntu.img` (e.g. after a rebuild).

### 2b. Manual

```bash
cd images
# bootloader fastboot
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

# vendor lives in the dynamic "super" partition -> needs fastbootd
fastboot reboot fastboot
fastboot getvar is-userspace          # must say: yes
fastboot flash vendor vendor.img

# boot OrangeFox temporarily
fastboot reboot bootloader
fastboot boot orangefox-R11.3-vayu-recovery.img

# in OrangeFox (adb shows "recovery"):
adb shell 'umount /data; umount /sdcard; mke2fs -F -t ext4 /dev/block/by-name/userdata'
adb shell 'mount -t ext4 /dev/block/by-name/userdata /data'
adb push ubuntu.img /data/ubuntu.img
adb shell 'sync; umount /data'
adb reboot
```

Notes:
- `fastboot flash vendor` in the normal bootloader fails with `Partition not found` – use fastbootd.
- `/data` is formatted as **ext4** (OrangeFox's "Format data" creates f2fs).
- MIUI 12.5.9 is **not** required; any MIUI 12.5 (Android 11) firmware works.

## Step 3 – First boot

The first boot takes 1–3 minutes, then the Ubuntu Touch welcome wizard appears.
See [Hardware support](#hardware-support) for what has been tested.

## Rebuilding the whole kit

A single script downloads and builds **everything** – it also works on its own, outside the kit:

```bash
./build/build-2604.sh          # -> ./build/vayu-ubuntu-touch-26.04-flashkit/
./build/build-2604.sh --pack   # additionally creates the .tar.zst + .sha256
```

Needs `curl wget python3 unzip fakeroot e2fsprogs (mke2fs >= 1.43) xz-utils` (`zstd` for `--pack`)
and about **16 GB** free disk space. **No root/sudo needed** (fakeroot + `mke2fs -d`).
Downloads are cached in `dl/` next to the script, so a second run is much faster.

What it does:
1. latest successful CI build of the vayu port (kernel, `boot.img`, `dtbo.img`, device overlay) –
   skipped if `out/device_vayu_usrmerge.tar.xz` already exists next to the script
   (GitLab deletes CI artifacts after ~30 days, so keep that file!)
2. current UBports **26.04-1.x daily** rootfs from system-image.ubports.com
3. Halium 11 generic arm64
4. Droidian vayu image (~2 GB, checksum verified) → `vendor.img`, `vbmeta.img`
5. OrangeFox R11.3 for vayu (checksum verified) → recovery image
6. builds `ubuntu.img`, writes `flash.sh`, `SHA256SUMS` and these READMEs

Then flash with `./flash.sh` (new install) or `./flash.sh --rootfs-only` (only a new `ubuntu.img`).

## Troubleshooting

| Problem | Fix |
|---|---|
| `adb: no devices` | enable USB debugging, accept the prompt, try another cable; udev rule for vendor `2717`/`18d1` |
| `no permissions` in `fastboot devices` | udev rule missing (see [Requirements](#requirements--installation-notes)), re-plug the phone |
| `fastboot reboot fastboot` fails / stays in bootloader | `fastboot` too old – use Google's current platform-tools (version 31+) |
| fastboot hangs / `FAILED (Status read failed)` | USB 2.0 port, no hub, different cable |
| miunlock `20041` | no phone number on the Xiaomi account (see 1.1) |
| miunlock `20036` | waiting time – do not re-add the account |
| `Partition not found` (vendor) | flash vendor from fastbootd (`fastboot reboot fastboot`) |
| boot loop / back to fastboot | re-check boot.img + dtbo.img, re-run `./flash.sh` |
| Back to Android | flash a MIUI fastboot ROM for vayu with Xiaomi's `flash_all.sh` (not `flash_all_lock`!) |
| SMS can be sent but not received; they only arrive in a burst after flight mode / reboot | the network delivers SMS over IMS, which `ofono-ril-plugin` does not receive – this kit already uses `ofono-binder-plugin`; for older installs see below |

### SMS fix for an existing installation

24.04 images built before 2026-10-31 still use `ofono-ril-plugin`. On the 1&1 network (and probably with other carriers that
deliver SMS over IMS) incoming SMS then stay in the network until the next re-registration. Switch to
`ofono-binder-plugin` + QTI IMS extension – the packages are already part of the rootfs:

```bash
# on the PC: save the BINDER_CONF_EOF block from build/build-2604.sh as binder.conf, then
adb push binder.conf /home/phablet/binder.conf
adb shell                       # phone unlocked and connected
# on the phone:
sudo mount -o remount,rw /
sudo install -m 644 ~/binder.conf /etc/ofono/binder.conf
sudo sed -i '/^vayu:/a\  OfonoPlugin: binder' /etc/deviceinfo/devices/vayu.yaml
device-info get OfonoPlugin     # must print: binder
sudo reboot
```

To undo: delete `/etc/ofono/binder.conf` and the `OfonoPlugin` line in `/etc/deviceinfo/devices/vayu.yaml`, then reboot.

## Credits

UBports, the vayu community porters (Verevka et al.), Droidian vayu team (`droidian-vayu` on GitHub),
OrangeFox Recovery, offici5l/MiUnlockTool (`miunlock`).
README_EN_EOF
cat > $KIT/README.de.md <<'README_DE_EOF'
# Ubuntu Touch 26.04 für Xiaomi Poco X3 Pro (vayu) – Flash-Kit

*English version: [README.md](README.md)*

Inoffizielles Ubuntu-Touch-Image für das Poco X3 Pro (Codename **vayu**), gebaut aus:

| Teil | Quelle |
|---|---|
| Rootfs | UBports **26.04-1.x daily** (Ubuntu 26.04), von system-image.ubports.com |
| Kernel / boot.img / dtbo.img / Device-Overlay | Community-Port `ubports/porting/community-ports/android11/xiaomi-poco-x3-pro/xiaomi-vayu` (CI-Build 19.10.2026) |
| Halium | Halium 11 generic arm64 (UBports Jenkins) |
| vendor.img / vbmeta.img | Droidian vayu Snapshot 18.11.2024 (MIUI-Vendor mit Linux-Fixes) |
| Recovery | OrangeFox R11.3 stable für vayu (wird nur temporär gestartet, nie installiert) |
| Telefonie | `ofono-binder-plugin` + QTI-IMS-Erweiterung statt des Port-Standards `ofono-ril-plugin` (nötig für SMS-Empfang, siehe [Fehlerbehebung](#fehlerbehebung)) |

> ⚠️ Das ist **kein** offizielles UBports-Release, das Gerät ist **nicht** im UBports-Installer.
> Das Flashen löscht **alle Daten** auf dem Telefon. Nutzung auf eigene Gefahr.

> 🧪 **Frühe Version.** 26.04-1.x ist ein versteckter *daily*-Testkanal von UBports. vayu ist dort nicht enthalten –
> dieses Kit kombiniert dessen generisches Rootfs mit dem vayu-24.04-Port. Mit Regressionen rechnen (im Testthread
> z. B. Morph-Browser startet nicht, OpenStore/Apps vermissen Qt5-Bibliotheken). Für den Alltag beim 24.04-Kit bleiben.

## Hardware-Unterstützung

**Unter 26.04 noch nicht getestet.** Die Statusspalte zeigt, was mit dem 26.04-2.2-Kit am 28.10.2026 funktionierte (gleicher Kernel, Overlay, Halium und Vendor) – unter 26.04 alles neu testen.

| Funktion | Status |
|---|---|
| WLAN | ❔ (24.04: ✅) |
| Bluetooth | ❔ (24.04: ✅) |
| Kamera | ❔ (24.04: ✅) |
| Ton / Lautsprecher | ❔ (24.04: ✅) |
| Akku laden | ❔ (24.04: ✅) |
| Flugmodus | ❔ (24.04: ✅) |
| Hotspot | ❔ (24.04: ✅) |
| GPS | ❔ (24.04: ✅) |
| Mobilfunk / Telefonieren | ❔ (24.04: ✅) |
| SMS senden / empfangen | ❔ (24.04: ✅) |
| Taschenlampe | ❔ (24.04: ✅) |
| Kamerawechsel (vorne/hinten) | ❔ (24.04: ✅) |
| Video | ❔ (24.04: ✅) |
| Mobile Daten | ❔ (24.04: ✅) |
| SIM-PIN entsperren | ❔ (24.04: ✅) |
| Lautstärke im Gespräch | ❔ (24.04: ✅) |
| Akkustand in Prozent | ❔ (24.04: ✅) |
| Laden im ausgeschalteten Zustand | ❔ (24.04: ✅) |
| SD-Karte | ❔ (24.04: ✅) |
| Ausschalten / Neustart | ❔ (24.04: ✅) |

<details><summary>Vollständige Feature-Matrix (Aufbau wie auf devices.ubuntu-touch.io)</summary>

✅ = funktioniert · ❔ = noch nicht getestet

| Kategorie | Funktion | Status |
|---|---|---|
| Actors | Manual brightness | ❔ |
|  | Notification LED | ❔ |
|  | Torchlight | ❔ (24.04: ✅) |
|  | Vibration | ❔ |
| Camera | Flashlight | ❔ |
|  | Photo | ❔ (24.04: ✅) |
|  | Switching between cameras | ❔ (24.04: ✅) |
|  | Video | ❔ (24.04: ✅) |
| Cellular | Change audio routings | ❔ |
|  | Incoming, outgoing calls | ❔ (24.04: ✅) |
|  | Carrier info, signal strength | ❔ (24.04: ✅) |
|  | Data connection | ❔ (24.04: ✅) |
|  | Dual SIM functionality | ❔ |
|  | MMS in, out | ❔ |
|  | PIN unlock | ❔ (24.04: ✅) |
|  | SMS in, out | ❔ (24.04: ✅) |
|  | Voice in calls | ❔ (24.04: ✅) |
|  | LTE calling (VoLTE) | ❔ |
|  | Volume control in calls | ❔ (24.04: ✅) |
| Endurance | 24+ hours battery lifetime | ❔ |
|  | 7+ days stability | ❔ |
| GPU | Boot into UI | ❔ (24.04: ✅) |
|  | Hardware video playback | ❔ |
| Misc | AppArmor patches | ❔ |
|  | Battery percentage | ❔ (24.04: ✅) |
|  | Reset to factory defaults | ❔ |
|  | Offline charging | ❔ (24.04: ✅) |
|  | Online charging | ❔ (24.04: ✅) |
|  | Recovery image | ❔ |
|  | RTC time | ❔ |
|  | SD card storage | ❔ (24.04: ✅) |
|  | Shutdown / Reboot | ❔ (24.04: ✅) |
|  | Waydroid | ❔ |
|  | Wireless External monitor | ❔ |
| Network | Bluetooth | ❔ (24.04: ✅) |
|  | Flight mode | ❔ (24.04: ✅) |
|  | Hotspot | ❔ (24.04: ✅) |
|  | NFC | ❔ |
|  | WiFi | ❔ (24.04: ✅) |
| Sensors | Automatic brightness | ❔ |
|  | Double touch to wake | ❔ |
|  | Fingerprint reader | ❔ |
|  | GPS | ❔ (24.04: ✅) |
|  | Proximity | ❔ |
|  | Rotation | ❔ |
|  | Touchscreen | ❔ (24.04: ✅) |
| Sound | Earphones | ❔ |
|  | Loudspeaker | ❔ (24.04: ✅) |
|  | Microphone | ❔ (24.04: ✅) |
|  | Volume control | ❔ (24.04: ✅) |
| USB | ADB access | ❔ |
|  | MTP access | ❔ |

</details>

## Inhalt

```
flash.sh                  automatisches Flash-Skript (Linux)
SHA256SUMS                Prüfsummen der Images
images/
  boot.img                UT-Kernel + Halium-Initramfs
  dtbo.img                Device-Tree-Overlay (passend zum Kernel)
  vbmeta.img              wird mit deaktivierter Verifizierung geflasht
  vendor.img              Droidian-vayu-Vendor
  orangefox-R11.3-vayu-recovery.img
  ubuntu.img              Ubuntu-Touch-26.04-Rootfs (kommt nach /data)
build/
  build-2604.sh           lädt + baut das komplette Kit, ohne root
  out/device_vayu_usrmerge.tar.xz
```

## Voraussetzungen & Installationshinweise

Diese Liste vor dem Start durchgehen – die meisten fehlgeschlagenen Installationen scheitern an einem Punkt hier.

### Telefon

- **Poco X3 Pro, Codename `vayu`** (Global-/EEA-Modell M2102J20SG). `flash.sh` bricht ab, wenn `fastboot getvar product` nicht `vayu` meldet.
- **Firmware-Basis MIUI 12.5.x / Android 11** (prüfen unter *Einstellungen → Über das Telefon*). Getestet mit MIUI 12.5.5 EEA.
  Das Kit ersetzt nur boot, dtbo, vbmeta und vendor – die Firmware-Partitionen des Telefons (Modem, DSP, …) bleiben
  und müssen zu Halium 11 passen. Läuft bereits MIUI 13/14 (Android 12/13), vorher ein MIUI-12.5-Fastboot-ROM für
  vayu mit Xiaomis `flash_all.sh` flashen. Vorher `fastboot getvar anti` prüfen und nie ein ROM mit niedrigerem
  Anti-Rollback-Index flashen, als das Telefon meldet.
- **Entsperrter Bootloader** (Schritt 1) – Xiaomis Wartezeit von **168 Stunden (7 Tage)** einplanen.
- **Xiaomi-Konto mit Telefonnummer** und eine **SIM-Karte mit mobilen Daten** zum Verknüpfen des Kontos (Schritt 1.1).
- **Akku mindestens 50 %** – das Telefon wechselt zwischen Bootloader, fastbootd und Recovery und darf nicht ausgehen.
- **Alles sichern**: Entsperren und Flashen löschen den internen Speicher vollständig.
  Eine microSD-Karte wird nicht angefasst, sicherheitshalber trotzdem entnehmen.

### Linux-PC

- Linux mit bash (entwickelt unter Linux Mint 22). `flash.sh` läuft nicht unter Windows; macOS ist ungetestet.
- Pakete:

  | Distribution | Befehl |
  |---|---|
  | Debian / Ubuntu / Linux Mint | `sudo apt install adb fastboot android-sdk-platform-tools-common python3 python3-venv zstd` |
  | Fedora | `sudo dnf install android-tools python3 zstd` |
  | Arch / Manjaro | `sudo pacman -S android-tools android-udev python zstd` |

  `zstd` wird nur zum Entpacken des `.tar.zst`-Release-Archivs gebraucht.
- **`fastboot` ab Version 31** (`fastboot --version`) – ältere Versionen können nicht nach fastbootd wechseln
  (`fastboot reboot fastboot`), das für `vendor.img` nötig ist. Liefert die Distribution eine ältere Version,
  Googles *SDK Platform-Tools* für Linux herunterladen, entpacken und vorne in den `PATH` setzen:
  `export PATH="$HOME/platform-tools:$PATH"`.
- **USB-Rechte**: Ohne udev-Regel zeigt `fastboot devices` nur `no permissions`. Die Pakete oben
  (`android-sdk-platform-tools-common` / `android-udev`) bringen passende Regeln mit. Sonst
  `/etc/udev/rules.d/51-android.rules` anlegen:

  ```
  SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0660", TAG+="uaccess"
  SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0660", TAG+="uaccess"
  ```

  danach `sudo udevadm control --reload-rules && sudo udevadm trigger` und das Telefon neu anstecken.
- **USB-Kabel / -Port**: ein Datenkabel, direkt am PC (kein Hub). Hängt fastboot oder meldet
  `FAILED (Status read failed)`, einen USB-2.0-Port probieren – der Xiaomi-Bootloader ist mit manchen USB-3-Controllern heikel.
- **Speicherplatz**: ca. 6 GB für das entpackte Kit, ca. 16 GB für einen Neubau (siehe unten).

### Check vor dem Flashen

```bash
cd vayu-ubuntu-touch-26.04-flashkit
fastboot --version                       # 31 oder neuer
(cd images && sha256sum -c ../SHA256SUMS) # jede Zeile: OK
# Telefon im Fastboot-Modus (ausschalten, Leiser + Power halten), per USB verbunden:
fastboot devices                         # <Seriennummer>  fastboot
fastboot getvar product                  # product: vayu
fastboot getvar unlocked                 # unlocked: yes  (nach Schritt 1)
fastboot getvar anti                     # Anti-Rollback-Index notieren
```

Zeitbedarf: Entsperren bis zu 7 Tage (Wartezeit), Flashen ca. 10 Minuten, erster Start 1–3 Minuten.

---

## Schritt 1 – Bootloader entsperren (mit miunlock im Python-venv)

Xiaomis offizielles Mi-Unlock-Tool gibt es nur für Windows. **miunlock** ist eine Python-Nachbildung, die unter Linux läuft.

### 1.1 Xiaomi-Konto und Telefon vorbereiten

1. Am Xiaomi-Konto **muss eine Telefonnummer hinterlegt** sein, sonst meldet miunlock
   `code 20041: your MI ID is not associated with a phone number`.
   Konten, die per *Mit Google anmelden* erstellt wurden, haben oft keine Telefonnummer und kein Passwort –
   dann ein neues Xiaomi-Konto **mit Telefonnummer registrieren**.
2. Am Telefon: **Einstellungen → Über das Telefon → Alle Spezifikationen → 7× auf „MIUI-Version" tippen**
   (nicht auf „Kernel-Version" – das öffnet das CIT-Testmenü).
3. **Einstellungen → Weitere Einstellungen → Entwickleroptionen**:
   - **OEM-Entsperrung** und **USB-Debugging** einschalten
   - mit dem Xiaomi-Konto anmelden (Einstellungen → Mi-Konto)
4. **SIM-Karte** einlegen, **WLAN aus**, **mobile Daten an**, dann
   **Entwickleroptionen → Mi Unlock status → Konto und Gerät hinzufügen**. Auf „Erfolgreich hinzugefügt" warten.
   Die SIM kann danach wieder raus.

### 1.2 miunlock im venv installieren

```bash
python3 -m venv ~/poco_X3_pro
source ~/poco_X3_pro/bin/activate
pip install miunlock          # im venv KEIN --user!
```

### 1.3 Entsperren

```bash
source ~/poco_X3_pro/bin/activate
adb reboot bootloader         # oder: ausschalten, Leiser + Power halten
fastboot devices              # Gerät muss erscheinen
miunlock                      # mit DEMSELBEN Xiaomi-Konto anmelden
```

- Beim ersten Mal kommt meist `code 20036: Please unlock 168 hours later`.
  **Die volle Zeit (7 Tage) abwarten und das Konto NICHT erneut unter Mi Unlock status hinzufügen** – sonst startet die Wartezeit neu.
- Gibt miunlock eine `notificationUrl` aus: im Browser öffnen, Identität bestätigen (SMS), dann miunlock erneut starten.
- Nach der Wartezeit `miunlock` erneut ausführen; es holt das signierte Token und entsperrt den Bootloader
  (falls gefragt: `fastboot oem unlock`). **Das Telefon wird dabei gelöscht.**
- Prüfen: `fastboot getvar unlocked` → `unlocked: yes`.

Nützlich: `fastboot getvar product` → `vayu`, `fastboot getvar anti` (Anti-Rollback-Index – nie ältere Firmware flashen, als er erlaubt).

---

## Schritt 2 – Ubuntu Touch flashen

### 2a. Automatisch

```bash
cd vayu-ubuntu-touch-26.04-flashkit
# Telefon im FASTBOOT-Modus (ausschalten, Leiser + Power halten), per USB verbunden
./flash.sh
```

Das Skript prüft Prüfsummen und Gerät, flasht alles, startet OrangeFox temporär,
formatiert `/data` als ext4, kopiert `ubuntu.img` und startet neu.
`./flash.sh --rootfs-only` formatiert nur `/data` neu und kopiert ein neues `ubuntu.img` (z. B. nach einem Neubau).

### 2b. Manuell

```bash
cd images
# Bootloader-Fastboot
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

# vendor liegt in der dynamischen „super"-Partition -> fastbootd nötig
fastboot reboot fastboot
fastboot getvar is-userspace          # muss "yes" sein
fastboot flash vendor vendor.img

# OrangeFox temporär starten
fastboot reboot bootloader
fastboot boot orangefox-R11.3-vayu-recovery.img

# in OrangeFox (adb zeigt "recovery"):
adb shell 'umount /data; umount /sdcard; mke2fs -F -t ext4 /dev/block/by-name/userdata'
adb shell 'mount -t ext4 /dev/block/by-name/userdata /data'
adb push ubuntu.img /data/ubuntu.img
adb shell 'sync; umount /data'
adb reboot
```

Hinweise:
- `fastboot flash vendor` im normalen Bootloader scheitert mit `Partition not found` – fastbootd verwenden.
- `/data` wird als **ext4** formatiert (OrangeFox' „Format data" erzeugt f2fs).
- MIUI 12.5.9 ist **nicht** nötig; jede MIUI-12.5-Firmware (Android 11) funktioniert.

## Schritt 3 – Erster Start

Der erste Start dauert 1–3 Minuten, dann erscheint der Ubuntu-Touch-Willkommensassistent.
Was bereits getestet wurde, steht unter [Hardware-Unterstützung](#hardware-unterstützung).

## Komplettes Kit neu bauen

Ein einziges Skript lädt und baut **alles** – es funktioniert auch allein, außerhalb des Kits:

```bash
./build/build-2604.sh          # -> ./build/vayu-ubuntu-touch-26.04-flashkit/
./build/build-2604.sh --pack   # zusätzlich .tar.zst + .sha256
```

Braucht `curl wget python3 unzip fakeroot e2fsprogs (mke2fs >= 1.43) xz-utils` (`zstd` für `--pack`)
und ca. **16 GB** freien Platz. **Kein root/sudo nötig** (fakeroot + `mke2fs -d`).
Downloads werden in `dl/` neben dem Skript zwischengespeichert, ein zweiter Lauf geht daher deutlich schneller.

Ablauf:
1. neuester erfolgreicher CI-Build des vayu-Ports (Kernel, `boot.img`, `dtbo.img`, Device-Overlay) –
   wird übersprungen, wenn `out/device_vayu_usrmerge.tar.xz` schon neben dem Skript liegt
   (GitLab löscht CI-Artefakte nach ca. 30 Tagen, diese Datei also aufheben!)
2. aktuelles UBports-**26.04-1.x-stable**-Rootfs von system-image.ubports.com
3. Halium 11 generic arm64
4. Droidian-vayu-Image (~2 GB, Prüfsumme geprüft) → `vendor.img`, `vbmeta.img`
5. OrangeFox R11.3 für vayu (Prüfsumme geprüft) → Recovery-Image
6. baut `ubuntu.img`, schreibt `flash.sh`, `SHA256SUMS` und diese READMEs

Danach mit `./flash.sh` (Neuinstallation) oder `./flash.sh --rootfs-only` (nur neues `ubuntu.img`) flashen.

## Fehlerbehebung

| Problem | Lösung |
|---|---|
| `adb: no devices` | USB-Debugging an, Abfrage bestätigen, anderes Kabel; udev-Regel für Vendor `2717`/`18d1` |
| `no permissions` bei `fastboot devices` | udev-Regel fehlt (siehe [Voraussetzungen](#voraussetzungen--installationshinweise)), Telefon neu anstecken |
| `fastboot reboot fastboot` schlägt fehl / bleibt im Bootloader | `fastboot` zu alt – aktuelle Platform-Tools von Google verwenden (ab Version 31) |
| fastboot hängt / `FAILED (Status read failed)` | USB-2.0-Port, kein Hub, anderes Kabel |
| miunlock `20041` | keine Telefonnummer am Xiaomi-Konto (siehe 1.1) |
| miunlock `20036` | Wartezeit – Konto nicht erneut hinzufügen |
| `Partition not found` (vendor) | vendor aus fastbootd flashen (`fastboot reboot fastboot`) |
| Bootschleife / zurück in Fastboot | boot.img + dtbo.img prüfen, `./flash.sh` erneut ausführen |
| Zurück zu Android | MIUI-Fastboot-ROM für vayu mit Xiaomis `flash_all.sh` flashen (nicht `flash_all_lock`!) |
| SMS senden geht, Empfang nicht; SMS kommen erst gesammelt nach Flugmodus / Neustart | das Netz stellt SMS über IMS zu, das `ofono-ril-plugin` nicht empfängt – dieses Kit nutzt bereits `ofono-binder-plugin`; für ältere Installationen siehe unten |

### SMS-Fix für eine bestehende Installation

24.04-Images, die vor dem 31.10.2026 gebaut wurden, nutzen noch `ofono-ril-plugin`. Im 1&1-Netz (und vermutlich bei anderen
Anbietern, die SMS über IMS zustellen) bleiben eingehende SMS dann bis zur nächsten Neuanmeldung im Netz hängen.
Umstellen auf `ofono-binder-plugin` + QTI-IMS-Erweiterung – die Pakete sind bereits im Rootfs enthalten:

```bash
# am PC: den Block BINDER_CONF_EOF aus build/build-2604.sh als binder.conf speichern, dann
adb push binder.conf /home/phablet/binder.conf
adb shell                       # Telefon entsperrt und verbunden
# auf dem Telefon:
sudo mount -o remount,rw /
sudo install -m 644 ~/binder.conf /etc/ofono/binder.conf
sudo sed -i '/^vayu:/a\  OfonoPlugin: binder' /etc/deviceinfo/devices/vayu.yaml
device-info get OfonoPlugin     # muss ausgeben: binder
sudo reboot
```

Rückgängig: `/etc/ofono/binder.conf` löschen und die Zeile `OfonoPlugin` in `/etc/deviceinfo/devices/vayu.yaml` entfernen, dann neu starten.

## Danksagung

UBports, die vayu-Community-Porter (Verevka u. a.), das Droidian-vayu-Team (`droidian-vayu` auf GitHub),
OrangeFox Recovery, offici5l/MiUnlockTool (`miunlock`).
README_DE_EOF
(cd $KIT/images && sha256sum *.img > ../SHA256SUMS)

cat > $KIT/flash.sh <<'FLASH'
#!/bin/bash
# Flash Ubuntu Touch 26.04 to a Xiaomi Poco X3 Pro (vayu).
# Start with the phone in FASTBOOT mode (power off, then hold Vol- + Power).
#   ./flash.sh               full install (boot, dtbo, vbmeta, vendor, userdata)
#   ./flash.sh --rootfs-only only re-format /data and copy ubuntu.img
# WARNING: wipes all data on the phone.
set -e
cd "$(dirname "$0")/images"
MODE=${1:-full}

step() { echo; echo "==> $*"; }
wait_fastboot() { for i in $(seq 1 90); do fastboot devices | grep -q . && return 0; sleep 1; done; echo "no fastboot device"; exit 1; }
# OrangeFox brings adb up, then re-inits the USB gadget a few seconds later
# (adb drops briefly), so wait until it has been visible for 10 s in a row.
wait_recovery() {
  local seen=0
  for i in $(seq 1 180); do
    if adb devices 2>/dev/null | grep -q "recovery$"; then seen=$((seen+1)); [ $seen -ge 10 ] && return 0
    else seen=0; fi
    sleep 1
  done
  echo "no stable adb recovery device"; exit 1
}
# adb with retry: waits for the recovery device before every attempt
radb() {
  for t in 1 2 3 4 5; do
    timeout 60 adb wait-for-recovery 2>/dev/null || true
    adb "$@" && return 0
    echo "  adb failed, retrying ($t/5)"; sleep 3
  done
  echo "adb $1 failed"; exit 1
}

command -v fastboot >/dev/null && command -v adb >/dev/null || { echo "install android-tools (adb/fastboot) first"; exit 1; }
sha256sum -c ../SHA256SUMS --quiet

# Resume: phone already sitting in OrangeFox -> skip straight to /data
if adb devices 2>/dev/null | grep -q "recovery$"; then
  step "Phone is already in recovery - skipping fastboot steps"
  MODE=--in-recovery
else
step "Waiting for phone in fastboot mode"
wait_fastboot
[ "$(fastboot getvar product 2>&1 | awk '/product:/{print $2}')" = vayu ] || { echo "not a vayu device"; exit 1; }
[ "$(fastboot getvar unlocked 2>&1 | awk '/unlocked:/{print $2}')" = yes ] || { echo "bootloader is locked"; exit 1; }

if [ "$MODE" != "--rootfs-only" ]; then
  step "Flashing boot, dtbo, vbmeta (bootloader fastboot)"
  fastboot flash boot boot.img
  fastboot flash dtbo dtbo.img
  fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

  step "Rebooting to fastbootd to flash vendor (dynamic partition)"
  fastboot reboot fastboot
  sleep 5; wait_fastboot
  [ "$(fastboot getvar is-userspace 2>&1 | awk '/is-userspace:/{print $2}')" = yes ] || { echo "not in fastbootd"; exit 1; }
  fastboot flash vendor vendor.img

  step "Back to bootloader"
  fastboot reboot bootloader
  sleep 5; wait_fastboot
fi

step "Temporarily booting OrangeFox recovery (not installed)"
fastboot boot orangefox-R11.3-vayu-recovery.img
fi
wait_recovery

step "Formatting /data as ext4"
radb shell 'umount /data 2>/dev/null; umount /sdcard 2>/dev/null; true'
radb shell 'mke2fs -F -t ext4 /dev/block/by-name/userdata >/dev/null 2>&1 && echo ok'
radb shell '{ grep -q " /data " /proc/mounts || mount -t ext4 /dev/block/by-name/userdata /data; } && df -h /data'

step "Copying ubuntu.img to /data (about 1 minute)"
radb push ubuntu.img /data/ubuntu.img
radb shell 'sync; umount /data'

step "Rebooting into Ubuntu Touch (first boot can take a few minutes)"
radb reboot
echo "Done."
FLASH
chmod +x $KIT/flash.sh $KIT/build/$(basename "$0")
rm -rf $OUT

if [ $PACK = 1 ]; then
  step "Packing $KIT.tar.zst"
  tar -cf - $KIT | zstd -T0 -12 --long=27 -q -f -o $KIT.tar.zst
  sha256sum $KIT.tar.zst > $KIT.tar.zst.sha256
fi

step "Done"
ls -lh $KIT $KIT/images
[ $PACK = 1 ] && ls -lh $KIT.tar.zst*
echo "Flash: cd $KIT && ./flash.sh   (phone in fastboot mode)"
