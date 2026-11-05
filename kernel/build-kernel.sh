#!/bin/bash
# Builds the vayu kernel 4.14.221-perf+ and the device overlay tarball
#   -> ../out/device_vayu_usrmerge.tar.xz   (used by ../build-2404.sh)
#
# Kernel = UBports vayu port kernel (4.14.190-halium, halium-11.0 branch, commit 1b904fcc2)
#        + linux-stable 4.14.191 ... 4.14.221 (incremental merge, conflicts resolved by hand)
#        + CONFIG_LOCALVERSION="-perf+"
# all contained in vayu-4.14.190-halium-to-4.14.221-perf.patch.xz next to this script.
#
# Needs: git curl xz python3 make gcc bc bison flex cpio libssl-dev (openssl headers)
# Disk:  ~12 GB (Android clang/gcc prebuilts ~5 GB are downloaded once into ./work)
set -e
umask 022
cd "$(dirname "$(readlink -f "$0")")"
HERE=$PWD
W=$HERE/work
KREPO=https://gitlab.com/ubports/porting/community-ports/android11/xiaomi-poco-x3-pro/kernel-xiaomi-sm8150.git
KBRANCH=halium-11.0
KBASE=1b904fcc2
PORT=https://gitlab.com/ubports/porting/community-ports/android11/xiaomi-poco-x3-pro/xiaomi-vayu.git
TOOLS=https://gitlab.com/ubports/porting/community-ports/halium-generic-adaptation-build-tools.git
PATCH=$HERE/vayu-4.14.190-halium-to-4.14.221-perf.patch.xz

for t in git curl xz python3 make gcc bc bison flex cpio; do
  command -v $t >/dev/null || { echo "missing tool: $t"; exit 1; }
done
[ -f /usr/include/openssl/ssl.h ] || { echo "missing openssl headers (libssl-dev / openssl-devel)"; exit 1; }
step() { echo; echo "==> $*"; }
mkdir -p $W/downloads $W/hostbin

step "kernel source ($KBRANCH @ $KBASE) + 4.14.221 patch"
K=$W/downloads/kernel-xiaomi-sm8150
if [ ! -d $K/.git ]; then
  git clone -q --depth 50 -b $KBRANCH $KREPO $K
fi
git -C $K rev-parse -q --verify "$KBASE^{commit}" >/dev/null || git -C $K fetch -q --unshallow
git -C $K checkout -q -f $KBASE
git -C $K clean -fdq
xzcat $PATCH | git -C $K apply --whitespace=nowarn -
grep -q '^SUBLEVEL = 221' $K/Makefile

step "vayu port + halium build tools"
[ -d $W/port/.git ] || git clone -q --depth 1 $PORT $W/port
[ -d $W/port/build/.git ] || git clone -q --depth 1 -b halium-11 $TOOLS $W/port/build

step "host helpers (mkbootimg, python2 shim for mkdtboimg.py)"
[ -x $W/hostbin/mkbootimg ] || { curl -fsSL https://raw.githubusercontent.com/LineageOS/android_system_tools_mkbootimg/lineage-19.1/mkbootimg.py -o $W/hostbin/mkbootimg; chmod +x $W/hostbin/mkbootimg; }
[ -f $W/hostbin/mkdtboimg3.py ] || curl -fsSL 'https://android.googlesource.com/platform/system/libufdt/+/refs/heads/main/utils/src/mkdtboimg.py?format=TEXT' | base64 -d > $W/hostbin/mkdtboimg3.py
# the kernel calls "python2 .../mkdtboimg.py" (py2 only) -> use the python3 AOSP version
cat > $W/hostbin/python2 <<'EOF'
#!/bin/bash
case "$1" in */mkdtboimg.py) shift; exec python3 "$(dirname "$0")/mkdtboimg3.py" "$@";; esac
exec python3 "$@"
EOF
chmod +x $W/hostbin/python2
command -v python >/dev/null || ln -sf "$(command -v python3)" $W/hostbin/python

step "building kernel + device tarball (takes a while)"
cd $W/port
rm -rf out
PATH=$W/hostbin:$PATH ./build/build.sh -b $W
VER=$(xzcat out/device_vayu_usrmerge.tar.xz | tar -tf - | sed -n 's|^system/usr/lib/modules/\([^/]*\)/$|\1|p' | head -1)
echo "kernel release: $VER"
[ "$VER" = "4.14.221-perf+" ]

mkdir -p $HERE/../out
cp out/device_vayu_usrmerge.tar.xz out/device_vayu_usrmerge.tar.build $HERE/../out/
step "Done -> build/out/device_vayu_usrmerge.tar.xz (kernel $VER)"
echo "Now run ../build-2404.sh to build the flash kit with this kernel."
