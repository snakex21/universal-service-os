#!/bin/sh
# Bootstrap disposable WinPE; the original full CBS packages service the target.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fail() { printf '[WINDOWS7_NVME] STOP: %s\n' "$1" >&2; exit 1; }
[ "$#" = 3 ] || fail 'expected original boot WIM, boot index and guarded staging path'
boot=$1; index=$2; stage=$3
work=${WORK_ROOT:?WORK_ROOT is required}
[ "$work" != / ] && [ -f "$work/.usos-work" ] && [ "$stage" = "$work/.usos-win7-stage" ] && [ -d "$stage/USOS" ] || fail 'invalid WORK staging path'
assets="$SCRIPT_DIR/windows7-nvme"; reader="$SCRIPT_DIR/pe-file-version"
original="$stage/nvme-original"; overlay="$stage/nvme-bootstrap"; commands="$stage/nvme-update.txt"; u="$stage/USOS"
mkdir "$original" "$overlay"
: >"$commands"
# A single extraction supplies all version comparisons. Missing inbox NVMe is
# expected on stock SP1; the three existing component anchors are mandatory.
wimlib-imagex extract "$boot" "$index" "@$assets/paths.txt" --dest-dir="$original" --preserve-dir-structure --nullglob --no-acls || fail 'cannot inspect original WinPE components'
resolve_original() {
 find "$original" -type f | awk -v root="$original/" -v wanted="$1" 'tolower($0)==tolower(root wanted){print; n++} END{if(n>1)exit 1}'
}
read_version() { "$reader" "$1" || fail "cannot read the original file version: $1"; }
branch_for() {
 set -- $1
 [ "$#" = 4 ] && [ "$1 $2 $3" = '6 1 7601' ] || fail 'NVMe requires Windows 7 SP1 components'
 if [ "$4" -ge 20000 ]; then printf ldr; else printf gdr; fi
}
older_than() {
 awk -v a="$1" -v b="$2" 'BEGIN{split(a,x," ");split(b,y," ");for(i=1;i<=4;i++){if(x[i]<y[i])exit 0;if(x[i]>y[i])exit 1}exit 1}'
}
port=$(resolve_original Windows/System32/drivers/storport.sys) || fail 'ambiguous Storport component'
[ -n "$port" ] || fail 'original Storport component is missing'
port_version=$(read_version "$port")
case "$port_version" in
 '6 1 7600 '*) printf '[WINDOWS7_NVME] RTM media retained; native NVMe needs SP1\n'; exit 0 ;;
esac
nvme_branch=$(branch_for "$port_version")
tab=$(printf '\t')
for group in classpnp storport setup; do
 case "$group" in
  classpnp) anchor=Windows/System32/drivers/Classpnp.sys ;;
  storport) anchor=Windows/System32/drivers/storport.sys ;;
  setup) anchor=sources/winsetup.dll ;;
 esac
 current=$(resolve_original "$anchor") || fail "ambiguous $group component"
 [ -n "$current" ] || fail "original $group component is missing"
 version=$(read_version "$current"); branch=$(branch_for "$version")
 required=$("$reader" "$assets/bootstrap/$branch/$anchor") || fail 'invalid pinned bootstrap component'
 if ! older_than "$version" "$required"; then
  printf '[WINDOWS7_NVME] %s already current: %s\n' "$group" "$version"
  continue
 fi
 printf '[WINDOWS7_NVME] %s: %s -> %s (%s)\n' "$group" "$version" "$required" "$branch"
 awk -F '\t' -v branch="$branch" -v group="$group" '$1==branch&&$2==group' "$assets/files.tsv" |
 while IFS="$tab" read -r row_branch row_group relative proposed; do
  [ -n "$relative" ] || fail 'invalid bootstrap file inventory'
  previous=$(resolve_original "$relative") || fail "ambiguous original component: $relative"
  if [ -n "$previous" ] && [ "$proposed" != - ]; then
   previous_version=$(read_version "$previous")
   older_than "$previous_version" "$proposed" || continue
  fi
  destination="$overlay/$relative"
  mkdir -p "$(dirname -- "$destination")"
  cp "$assets/bootstrap/$branch/$relative" "$destination"
  printf 'add "%s" "/%s"\n' "$destination" "$relative" >>"$commands"
 done
done
existing_nvme=$(resolve_original Windows/System32/drivers/stornvme.sys) || fail 'ambiguous existing NVMe driver'
if [ -n "$existing_nvme" ]; then
 existing_version=$(read_version "$existing_nvme"); nvme_branch=$(branch_for "$existing_version")
 required=$("$reader" "$assets/nvme/$nvme_branch/stornvme.sys") || fail 'invalid pinned NVMe driver'
 if older_than "$existing_version" "$required"; then
  destination="$overlay/Windows/System32/drivers/stornvme.sys"
  mkdir -p "$(dirname -- "$destination")"; cp "$assets/nvme/$nvme_branch/stornvme.sys" "$destination"
  printf 'add "%s" /Windows/System32/drivers/stornvme.sys\n' "$destination" >>"$commands"
 fi
 printf '[WINDOWS7_NVME] Existing inbox driver retained with its service configuration\n'
else
 mkdir "$u/nvme"
 cp "$assets/nvme/$nvme_branch/"* "$u/nvme/"
 : >"$u/nvme-load.flag"
fi
mkdir "$u/updates"
cp "$assets/updates/"*.cab "$u/updates/"
cp "$SCRIPT_DIR/usos-win7-nvme.exe" "$u/usos-win7-nvme.exe"
cp "$SCRIPT_DIR/usos-win7-unattend.exe" "$u/usos-win7-unattend.exe"
: >"$u/nvme-enabled.flag"
printf '[WINDOWS7_NVME] Bootstrap ready; full KB2990941 + KB3087873 packages staged for native Setup\n'
