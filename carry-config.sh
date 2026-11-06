#!/bin/sh
# carry-config.sh - keep your package selections when you change the target device.
#
# Run it in the root of the ImmortalWrt tree (where .config and scripts/ are).
#
#   1) While the OLD target's .config is in place (SAX1V1K), save the choices once:
#        sh carry-config.sh save sax1v1k
#
#   2) Build a new .config for the new device from the saved choices:
#        sh carry-config.sh apply sax1v1k mediatek filogic xiaomi_redmi-router-ax6000-stock
#      (the other AX6000 variant, for a custom U-Boot, is:  ...-ubootmod)
#
#   3) Check it and save:   make menuconfig
#
#   sh carry-config.sh show sax1v1k    list what was saved
#
# What "save" keeps: every package/option you set that differs from the old
# target's defaults (it uses scripts/diffconfig.sh), WITHOUT the target and
# device lines and WITHOUT packages that only make sense on the old hardware
# (Qualcomm Wi-Fi drivers and firmware, board files). Everything is stored under
# ./my-configs/ . Your .config is backed up before "apply" replaces it.
#
# "apply" tells you at the end which saved packages did NOT survive on the new
# target (not available there, or dropped by a dependency), so nothing is lost silently.

STORE=${STORE:-my-configs}
MAKE=${MAKE:-make}
DIFFCONFIG=${DIFFCONFIG:-./scripts/diffconfig.sh}

# Packages that belong to the old hardware, not to your choices. Edit if needed.
HW_EXCLUDE=${HW_EXCLUDE:-'ath11k|ath12k|ath10k|ipq-wifi|ipq[0-9]|kmod-ath($|[0-9=_])|kmod-qcom|qca-|nss-|kmod-gpio-button-hotplug|kmod-leds-gpio'}

die() { echo "error: $*" >&2; exit 1; }

# names of the target directories (ath79, mediatek, qualcommax, x86 ...)
target_regex() {
	for _d in target/linux/*/; do
		_n=$(basename "$_d")
		case "$_n" in generic|files|patches*|README*) continue ;; esac
		printf '%s|' "$_n"
	done | sed 's/|$//'
}

# stdin: a diffconfig. stdout: the same without target/device selection lines
# and without old-hardware packages.
filter_common() {
	_t=$(target_regex)
	grep -v -E "^CONFIG_TARGET_($_t)(_[A-Za-z0-9]+)?(_DEVICE_[^=]*)?=y\$" \
	| grep -v -E '^CONFIG_TARGET_(DEVICE_|BOARD|SUBTARGET|PROFILE|ARCH_PACKAGES|MULTI_PROFILE|PER_DEVICE_ROOTFS)' \
	| grep -v -E "(CONFIG_PACKAGE_[^=# ]*($HW_EXCLUDE))" \
	| grep -v -E '^CONFIG_(ARCH|CPU_TYPE|DEFAULT_TARGET_OPTIMIZATION|TARGET_ARCH_PACKAGES)'
}

cmd_save() {
	[ -n "$1" ] || die "usage: $0 save NAME"
	[ -f .config ] || die ".config not found - run this in the ImmortalWrt tree"
	[ -x "$DIFFCONFIG" ] || [ -f "$DIFFCONFIG" ] || die "$DIFFCONFIG not found"
	mkdir -p "$STORE" tmp
	cp .config "$STORE/$1.full.config"
	sh "$DIFFCONFIG" > "$STORE/$1.diff" || die "diffconfig failed (build the host tools first: make defconfig)"
	filter_common < "$STORE/$1.diff" > "$STORE/$1.common"
	_all=$(grep -c . "$STORE/$1.diff")
	_kept=$(grep -c . "$STORE/$1.common")
	_apps=$(grep -c '^CONFIG_PACKAGE_luci-app-.*=[ym]$' "$STORE/$1.common")
	echo "saved in $STORE/:"
	echo "  $1.full.config  the complete old .config (backup)"
	echo "  $1.diff         what differs from the old target's defaults ($_all lines)"
	echo "  $1.common       the part carried to other devices ($_kept lines, $_apps luci apps)"
	echo
	echo "left out as old-hardware or target selection:"
	grep -v -x -F -f "$STORE/$1.common" "$STORE/$1.diff" | sed 's/^/  /'
}

cmd_show() {
	[ -f "$STORE/$1.common" ] || die "$STORE/$1.common not found"
	echo "luci apps:"
	grep -E '^CONFIG_PACKAGE_luci-app-.*=[ym]$' "$STORE/$1.common" | sed 's/CONFIG_PACKAGE_//; s/^/  /'
	echo "other lines: $(grep -vc -E '^CONFIG_PACKAGE_luci-app-' "$STORE/$1.common")"
}

cmd_apply() {
	_n=$1; _t=$2; _s=$3; _dev=$4
	[ -n "$_n" ] && [ -n "$_t" ] && [ -n "$_s" ] && [ -n "$_dev" ] ||
		die "usage: $0 apply NAME TARGET SUBTARGET DEVICE   e.g. apply sax1v1k mediatek filogic xiaomi_redmi-router-ax6000-stock"
	[ -f "$STORE/$_n.common" ] || die "$STORE/$_n.common not found - run '$0 save $_n' first"
	[ -d "target/linux/$_t" ] || die "unknown target '$_t' (see target/linux/)"

	[ -f .config ] && cp .config ".config.before-apply-$(date +%Y%m%d-%H%M%S)" && echo "old .config backed up as .config.before-apply-*"
	{
		echo "CONFIG_TARGET_$_t=y"
		echo "CONFIG_TARGET_${_t}_$_s=y"
		echo "CONFIG_TARGET_${_t}_${_s}_DEVICE_$_dev=y"
		cat "$STORE/$_n.common"
	} > .config
	$MAKE defconfig >/dev/null 2>&1 || die "'make defconfig' failed"

	grep -q "^CONFIG_TARGET_${_t}_${_s}_DEVICE_$_dev=y" .config ||
		echo "WARNING: device '$_dev' was not accepted - check the name (grep DEVICE_ target/linux/$_t/image/*.mk)"

	echo
	echo "carried over: $(grep -c -E '^CONFIG_PACKAGE_luci-app-.*=[ym]$' .config) luci apps selected now"
	_lost=$(grep -E '^CONFIG_PACKAGE_.*=[ym]$' "$STORE/$_n.common" | while read -r _l; do
		_k=${_l%%=*}
		grep -q -E "^$_k=[ym]\$" .config || echo "${_k#CONFIG_PACKAGE_}"
	done)
	if [ -n "$_lost" ]; then
		echo
		echo "NOT selected on the new target (not available there, or a dependency dropped it):"
		echo "$_lost" | sed 's/^/  /'
	else
		echo "every saved package is still selected"
	fi
	echo
	echo "Next:  make menuconfig   (check, then save)"
}

case "$1" in
save)  shift; cmd_save "$@" ;;
apply) shift; cmd_apply "$@" ;;
show)  shift; cmd_show "$@" ;;
filter) filter_common ;;      # for testing: stdin -> stdout
*)     sed -n '2,26p' "$0" ;;
esac
