#!/bin/sh
# Guest half of tools/build_csmwrap.ps1: runs as root inside the Alpine virt
# live VM (tools/csmwrap_build/run_build_vm.py). Input: /w (lock.env,
# patches/*.patch, this script). Output: a tar written to /dev/vdb.
#
# 1. installs the pinned toolchain from the pinned Alpine branch,
# 2. clones CSMWrap at the pinned commit and checks every submodule commit,
# 3. writes the deterministic source archive (what USOS ships as the source),
# 4. builds from that archive: unpatched 3.1.2 (functional check against the
#    upstream release) and 3.1.2-usos1 (patches applied), usos1 twice to
#    check that the build is repeatable,
# 5. records toolchain versions and SHA-256 of everything.
set -eu
W=/w
. "$W/lock.env"
OUT=/out
rm -rf "$OUT" /b && mkdir -p "$OUT" /b
log() { echo "[usos-csmwrap] $*"; }

log 'network: DHCP on eth0 (QEMU user networking)'
ip link set eth0 up
udhcpc -q -n -i eth0 >/dev/null
log "apk: Alpine $ALPINE_BRANCH"
printf '%s/%s/main\n%s/%s/community\n' "$ALPINE_MIRROR" "$ALPINE_BRANCH" "$ALPINE_MIRROR" "$ALPINE_BRANCH" >/etc/apk/repositories
apk update -q --no-progress
# shellcheck disable=SC2086
apk add -q --no-progress $APK_PACKAGES
apk info -v 2>/dev/null | sort >"$OUT/apk-installed.txt"
for p in $APK_PACKAGES; do
    case "$p" in *=*) grep -qx "$(echo "$p" | sed 's/=/-/')" "$OUT/apk-installed.txt" || { log "FAIL pinned package $p not installed"; exit 3; } ;; esac
done

cd /b
if [ -f "$W/source.tar.xz" ]; then
    # Offline build (build kit): the deterministic source archive of an
    # earlier online run (tools/vendor/csmwrap/3.1.2-src) instead of git.
    log "source: pinned archive $(sha256sum "$W/source.tar.xz" | cut -d' ' -f1) (offline, no git clone)"
    cp "$W/source.tar.xz" "$OUT/$SRC_DIR-src.tar.xz"
    echo "offline: submodule commits as pinned in lock.json" >"$OUT/submodules.txt"
else
log "source: $CSMWRAP_URL $CSMWRAP_COMMIT"
git clone -q "$CSMWRAP_URL" git-src
cd git-src
git -c advice.detachedHead=false checkout -q "$CSMWRAP_COMMIT"
[ "$(git rev-parse HEAD)" = "$CSMWRAP_COMMIT" ] || { log 'FAIL CSMWrap commit'; exit 4; }
git submodule -q update --init --recursive
git submodule status --recursive >"$OUT/submodules.txt"
echo "$SUBMODULES" | tr ' ' '\n' | while IFS='=' read -r path commit; do
    [ -n "$path" ] || continue
    got=$(git -C "$path" rev-parse HEAD)
    [ "$got" = "$commit" ] || { log "FAIL submodule $path is $got, pinned $commit"; exit 5; }
done
# SeaBIOS takes its version from .git or .version; a source tree has no .git.
git -C seabios describe --always --tags >seabios/.version
log "seabios .version: $(cat seabios/.version)"
cd /b
mv git-src "$SRC_DIR"
tar --sort=name --mtime="@$SOURCE_EPOCH" --owner=0 --group=0 --numeric-owner --format=gnu \
    --exclude=.git -cf - "$SRC_DIR" | xz -9 -T1 >"$OUT/$SRC_DIR-src.tar.xz"
fi

build() { # name version [patches...]
    name=$1; version=$2; shift 2
    rm -rf "/b/$name" && mkdir -p "/b/$name"
    xz -dc "$OUT/$SRC_DIR-src.tar.xz" | tar -xf - -C "/b/$name"
    cd "/b/$name/$SRC_DIR"
    for p in "$@"; do log "$name: patch $(basename "$p")"; patch -p1 --no-backup-if-mismatch <"$p"; done
    log "$name: make BUILD_VERSION=$version"
    make -j"$(nproc)" ARCH=x86_64 BUILD_VERSION="$version" >"$OUT/build-$name.log" 2>&1 || { tail -50 "$OUT/build-$name.log"; exit 6; }
    cp bin-x86_64/csmwrap.efi "$OUT/csmwrapx64-$name.efi"
    cp seabios/out/Csm16.bin "$OUT/Csm16-$name.bin"
    cp seabios/out/vgabios.bin "$OUT/vgabios-$name.bin"
    cd /b
}
build upstream "$UPSTREAM_VERSION"
# shellcheck disable=SC2046
build usos1 "$USOS_VERSION" $(ls "$W"/patches/*.patch | sort)
# shellcheck disable=SC2046
build usos1-repeat "$USOS_VERSION" $(ls "$W"/patches/*.patch | sort)
cp "$W"/patches/*.patch "$OUT/"

{
    echo "uname: $(uname -srm)"
    echo "gcc: $(gcc --version | head -1)"
    echo "ld: $(ld --version | head -1)"
    echo "objcopy: $(objcopy --version | head -1)"
    echo "nasm: $(nasm -v)"
    echo "xxd: $(xxd -v 2>&1 | head -1)"
    echo "make: $(make --version | head -1)"
    echo "python3: $(python3 --version)"
    echo "git: $(git --version)"
    echo "tar: $(tar --version | head -1)"
    echo "xz: $(xz --version | head -1)"
} >"$OUT/toolchain.txt"
cd "$OUT" && sha256sum -- * | grep -v ' SHA256SUMS$' >SHA256SUMS
cat toolchain.txt SHA256SUMS
cmp -s csmwrapx64-usos1.efi csmwrapx64-usos1-repeat.efi && log 'usos1 build repeatable: yes' || log 'usos1 build repeatable: NO'

log 'writing output tar to /dev/vdb'
tar -cf /dev/vdb -C "$OUT" .
sync
log 'GUEST-BUILD-PASS'
