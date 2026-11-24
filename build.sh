#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Build script stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

workspace=$(pwd -P)
source_dir="$workspace/fanchmwrt"
source_pin=11b65ca6a58dc7fad27eef196b391789195393b8
feed_pin=59c6b967e611a8c8562f3fd17eaa6aec9977f071
nikki_pin=aaf46bf02a9ab2b5a8ab3fcaa5f84c99e56585bf
honk_pin=c2923aa7651ed3c9ea6887ca50605c290313205e

checkout() {
  git init -q "$2"
  git -C "$2" fetch -q --depth 1 "$1" "$3"
  git -C "$2" checkout -q --detach FETCH_HEAD
  test "$(git -C "$2" rev-parse HEAD)" = "$3"
}

checkout https://github.com/fanchmwrt/fanchmwrt.git "$source_dir" "$source_pin"
cd "$source_dir"
# Keep upstream feed revisions. Use GitHub's OpenWrt mirrors for the same commits.
sed -E "s@https://git.openwrt.org/(feed|project)/@https://github.com/openwrt/@; /^src-git fanchmwrt /s/$/^$feed_pin/" \
  feeds.conf.default > feeds.conf
./scripts/feeds update -a
test "$(git -C feeds/fanchmwrt rev-parse HEAD)" = "$feed_pin"
cp -a feeds_patches/. feeds/
./scripts/feeds install -a
# This optional LuCI app creates a Kconfig cycle between the two WeeChat flavors.
rm -f package/feeds/luci/luci-app-weechat

checkout https://github.com/nikkinikki-org/OpenWrt-nikki.git "$workspace/nikki-source" "$nikki_pin"
checkout https://github.com/kenzok8/openwrt-honk.git "$workspace/honk-source" "$honk_pin"
cp -a "$workspace/nikki-source/"{nikki,luci-app-nikki,mihomo-meta} package/
cp -a "$workspace/honk-source/"{honk,luci-app-honk} package/

cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_netcore_n60-pro=y
CONFIG_IPV6=y
CONFIG_KERNEL_NET_NS=y
CONFIG_KERNEL_CGROUPS=y
CONFIG_KERNEL_CGROUP_BPF=y
CONFIG_KERNEL_DEBUG_INFO=y
# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_PACKAGE_mihomo-meta=y
CONFIG_PACKAGE_luci-app-nikki=y
CONFIG_PACKAGE_luci-app-honk=y
EOF
make defconfig

for option in TARGET_DEVICE_mediatek_filogic_DEVICE_netcore_n60-pro IPV6 USE_APK \
  KERNEL_DEBUG_INFO_BTF KERNEL_CGROUP_BPF PACKAGE_kmod-shortcut-fe PACKAGE_luci-app-fwx-fastnat \
  PACKAGE_kmod-fwx PACKAGE_fwxd PACKAGE_luci-theme-fanchmwrt PACKAGE_odhcp6c PACKAGE_odhcpd-ipv6only \
  PACKAGE_mihomo-meta PACKAGE_nikki PACKAGE_luci-app-nikki PACKAGE_honk PACKAGE_luci-app-honk \
  PACKAGE_kmod-sched-bpf PACKAGE_kmod-veth PACKAGE_kmod-nft-queue; do
  grep -qx "CONFIG_${option}=y" .config || { echo "Missing build option: $option" >&2; exit 1; }
done

assert_package_source() {
  local name="$1" file="$2"
  awk -v name="$name" -v file="$file" '
    $1 == "Source-Makefile:" { path = $2 }
    $1 == "Package:" && $2 == name {
      print name, path
      count++
      if (path != file) wrong = 1
    }
    END { exit (count != 1 || wrong) }
  ' tmp/.packageinfo
}
assert_package_source kmod-shortcut-fe package/fcm/shortcut-fe/Makefile
assert_package_source luci-app-fwx-fastnat package/feeds/fanchmwrt/luci-app-fwx-fastnat/Makefile
assert_package_source nikki package/nikki/Makefile
assert_package_source luci-app-nikki package/luci-app-nikki/Makefile
assert_package_source mihomo-meta package/mihomo-meta/Makefile
assert_package_source honk package/honk/Makefile
assert_package_source luci-app-honk package/luci-app-honk/Makefile

make -j8 download 2>&1 | tee "$workspace/download.log"
if [ "${N60_PREFLIGHT_ONLY:-false}" = true ]; then
  exit 0
fi
make -j"$(nproc)" V=s 2>&1 | tee "$workspace/build.log"

target=bin/targets/mediatek/filogic
mapfile -t images < <(find "$target" -maxdepth 1 -name '*netcore_n60-pro*squashfs-sysupgrade.itb')
test "${#images[@]}" = 1
image="${images[0]}"
test -s "$image"
candidate="$workspace/candidate"
mkdir -p "$candidate"
cp "$image" "$candidate/"
(cd "$candidate" && sha256sum ./*sysupgrade.itb > SHA256SUMS)
test "$(stat -c %s "$image")" -lt $((0x7a80000))
manifest="${image%-netcore_n60-pro-squashfs-sysupgrade.itb}.manifest"
test -s "$manifest"
cp "$manifest" "$candidate/"
for package in kmod-shortcut-fe luci-app-fwx-fastnat kmod-fwx fwxd luci-theme-fanchmwrt \
  nikki luci-app-nikki mihomo-meta honk luci-app-honk odhcp6c odhcpd-ipv6only; do
  grep -q "^$package - " "$manifest" || { echo "Missing image package: $package" >&2; exit 1; }
done
if grep -Eq '^(luci-app-(openclash|daede?|bandix|adguardhome|mosdns)|dae|daed|mosdns|adguardhome|bandix) - ' "$manifest"; then
  echo 'An unrequested third-party package is in the image.' >&2
  exit 1
fi

output="$workspace/firmware"
mkdir -p "$output"
staging_dir/host/bin/fwtool -i "$output/n60-pro-metadata.json" "$image"
jq -e '.supported_devices | index("netcore,n60-pro") != null' "$output/n60-pro-metadata.json"
kernel_config=$(find build_dir/target-*/linux-mediatek_filogic -type f -path '*/linux-6.12.*/.config' -print -quit)
test -n "$kernel_config"
cp "$kernel_config" "$candidate/kernel.config"
cp "$output/n60-pro-metadata.json" "$candidate/"
for option in IPV6 DEBUG_INFO_BTF BPF_SYSCALL BPF_JIT CGROUP_BPF NET_NS; do
  grep -qx "CONFIG_${option}=y" "$kernel_config"
done
readelf -SW "$(dirname "$kernel_config")/vmlinux" | grep -E '[[:space:]]\.BTF[[:space:]]' >/dev/null

root_node=$(fdtget -l "$image" /images | awk '/^rootfs[-@]/ { print }')
test -n "$root_node"
offset=$(fdtget -tu "$image" "/images/$root_node" data-position)
size=$(fdtget -tu "$image" "/images/$root_node" data-size)
rootfs="$workspace/n60-pro-root.squashfs"
dd if="$image" of="$rootfs" iflag=skip_bytes,count_bytes skip="$offset" count="$size" bs=1M status=none
root="$workspace/verified-root"
# Extract the checked paths so a non-root runner need not create /dev/console.
staging_dir/host/bin/unsquashfs4 -no-progress -d "$root" "$rootfs" \
  etc/init.d/fastnat etc/init.d/nikki etc/init.d/honk etc/config/fastnat etc/config/nikki etc/config/honk \
  usr/bin/honk-core usr/bin/mihomo usr/libexec/mihomo lib/netifd/proto/dhcpv6.sh lib/modules \
  usr/lib/lua/luci/controller/fwx_fastnat.lua usr/share/doona/index.html
for item in etc/init.d/fastnat etc/init.d/nikki etc/init.d/honk usr/bin/honk-core \
  usr/libexec/mihomo lib/netifd/proto/dhcpv6.sh; do
  test -x "$root/$item"
done
test -L "$root/usr/bin/mihomo"
test -s "$root/usr/lib/lua/luci/controller/fwx_fastnat.lua"
test -s "$root/etc/config/fastnat"
test -s "$root/usr/share/doona/index.html"
test -n "$(find "$root/lib/modules" -name 'shortcut-fe-cm.ko*' -print -quit)"
grep -F "option enabled '0'" "$root/etc/config/honk"
sed -n "/^config config 'config'/,/^config /p" "$root/etc/config/nikki" | grep -F "option 'enabled' '0'"

cp "$image" "$manifest" "$output/"
cp .config "$output/build.config"
cp "$kernel_config" "$output/kernel.config"
cp "$target/"{feeds.buildinfo,version.buildinfo} "$output/"
printf 'FanchmWrt %s\nFanchmWrt packages %s\nNikki %s\nHonk %s\n' \
  "$source_pin" "$feed_pin" "$nikki_pin" "$honk_pin" > "$output/source-revisions.txt"
(cd "$output" && sha256sum ./*sysupgrade.itb > SHA256SUMS)
