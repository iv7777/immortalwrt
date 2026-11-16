#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Set up a host LLVM/clang toolchain for OpenWrt's "Use host LLVM toolchain"
# BPF option (CONFIG_BPF_TOOLCHAIN_HOST).
#
# What it does:
#   1. reads the LLVM version this tree builds (tools/llvm-bpf/Makefile)
#   2. looks for a matching host LLVM (same major version, >= that version)
#   3. if missing, installs it from apt.llvm.org (Debian/Ubuntu only)
#   4. makes sure the *unversioned* tools OpenWrt looks for exist
#      (clang llc opt llvm-dis llvm-strip), creating symlinks if needed
#   5. with --config, points .config at it and runs `make defconfig`
#
# include/bpf.mk only searches for "clang", "clang-13" and "clang-12", so on
# Debian/Ubuntu the toolchain prefix must be /usr/lib/llvm-<major>, whose bin/
# directory holds the unversioned names.

set -euo pipefail

PROG=${0##*/}
TREE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOOLS="clang llc opt llvm-dis llvm-strip"

DO_CONFIG=0
DO_DEFCONFIG=1
DO_INSTALL=1
CHECK_ONLY=0
PREFIX=""

usage() {
	cat <<EOF
Usage: $PROG [options]

  --check          only report the required/installed versions, change nothing
  --config         write the BPF toolchain settings to .config and run
                   'make defconfig' (a backup is saved as .config.bak-llvm)
  --prefix DIR     use this existing LLVM prefix (DIR/bin/clang ...) instead
                   of searching for / installing one
  --no-install     never install packages; fail if no suitable LLVM is found
  --no-defconfig   with --config: edit .config but do not run 'make defconfig'
  --tree DIR       OpenWrt tree to use (default: $TREE)
  -h, --help       show this help
EOF
}

die()  { echo "$PROG: error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "$PROG: warning: $*" >&2; }

while [ $# -gt 0 ]; do
	case $1 in
	--check)        CHECK_ONLY=1 ;;
	--config)       DO_CONFIG=1 ;;
	--prefix)       [ $# -ge 2 ] || die "--prefix needs an argument"; PREFIX=$2; shift ;;
	--no-install)   DO_INSTALL=0 ;;
	--no-defconfig) DO_DEFCONFIG=0 ;;
	--tree)         [ $# -ge 2 ] || die "--tree needs an argument"; TREE=$(cd "$2" && pwd); shift ;;
	-h|--help)      usage; exit 0 ;;
	*)              usage >&2; die "unknown option: $1" ;;
	esac
	shift
done

# ---------------------------------------------------------------- version --

MK="$TREE/tools/llvm-bpf/Makefile"
[ -f "$MK" ] || die "$MK not found (is --tree an ImmortalWrt tree?)"

REQ_VER=$(sed -n 's/^PKG_VERSION:=[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*$/\1/p' "$MK" | head -n1)
[ -n "$REQ_VER" ] || die "cannot read PKG_VERSION from $MK"
MAJOR=${REQ_VER%%.*}

info "tree: $TREE"
info "LLVM version built by this tree: $REQ_VER (major $MAJOR)"

# Echo the clang version of prefix $1 (e.g. 22.1.8), or nothing on failure.
clang_version() {
	"$1/bin/clang" --version 2>/dev/null | sed -n '1s/.*clang version \([0-9][0-9.]*\).*/\1/p'
}

# 0 if $1 >= $2 (dotted versions)
version_ge() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Validate prefix $1. Prints the reason on stderr and returns 1 if unusable.
# Same checks bpf.mk relies on: all unversioned tools present, clang knows
# the bpf target, llc has the BPF backend.
check_prefix() {
	local p=$1 t v
	for t in $TOOLS; do
		[ -x "$p/bin/$t" ] || { echo "$p/bin/$t missing" >&2; return 1; }
	done
	v=$(clang_version "$p")
	[ -n "$v" ] || { echo "cannot run $p/bin/clang" >&2; return 1; }
	[ "${v%%.*}" = "$MAJOR" ] || { echo "$p has clang $v, need major $MAJOR" >&2; return 1; }
	"$p/bin/clang" --target=bpfel -dM -E - </dev/null 2>/dev/null | grep -q __clang_major__ ||
		{ echo "$p/bin/clang does not support the bpf target" >&2; return 1; }
	"$p/bin/llc" --version 2>/dev/null | grep -qw bpfel ||
		{ echo "$p/bin/llc has no BPF backend" >&2; return 1; }
	if ! version_ge "$v" "$REQ_VER"; then
		warn "$p has clang $v, older than $REQ_VER used by this tree (continuing)"
	fi
	return 0
}

# Directories that may hold LLVM $MAJOR with unversioned tools.
candidates() {
	echo "/usr/lib/llvm-$MAJOR"
	echo "/usr/lib64/llvm$MAJOR"
	echo "/usr/lib/llvm$MAJOR"
	echo "$TREE/llvm-bpf-host"
}

# Create $TREE/llvm-bpf-host/bin with unversioned symlinks to the versioned
# tools (clang-22, llc-22, ...) when the distro prefix lacks unversioned ones.
make_symlink_prefix() {
	local d=$TREE/llvm-bpf-host t src
	rm -rf "$d"; mkdir -p "$d/bin"
	for t in $TOOLS; do
		src=$(command -v "$t-$MAJOR" || true)
		[ -n "$src" ] || { rm -rf "$d"; return 1; }
		ln -s "$src" "$d/bin/$t"
	done
	echo "$d"
}

find_prefix() {
	local p
	while read -r p; do
		[ -d "$p/bin" ] || continue
		if check_prefix "$p" 2>/dev/null; then echo "$p"; return 0; fi
	done < <(candidates)
	# Versioned tools present (clang-22 ...) but no unversioned prefix?
	if command -v "clang-$MAJOR" >/dev/null 2>&1; then
		p=$(make_symlink_prefix) && check_prefix "$p" 2>/dev/null && { echo "$p"; return 0; }
	fi
	return 1
}

# --------------------------------------------------------------- install ---

run_root() {
	if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

install_llvm() {
	command -v apt-get >/dev/null 2>&1 ||
		die "automatic install only supports Debian/Ubuntu (apt). Install clang/llvm $MAJOR yourself and rerun with --prefix DIR"
	[ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1 || die "need root or sudo to install packages"

	local tmp
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT

	info "downloading https://apt.llvm.org/llvm.sh"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL https://apt.llvm.org/llvm.sh -o "$tmp/llvm.sh"
	elif command -v wget >/dev/null 2>&1; then
		wget -q https://apt.llvm.org/llvm.sh -O "$tmp/llvm.sh"
	else
		die "need curl or wget"
	fi

	# llvm.sh adds the apt.llvm.org repository for this distro and installs
	# clang/lld/lldb for the requested major version.
	info "installing LLVM $MAJOR via apt.llvm.org (llvm.sh)"
	run_root bash "$tmp/llvm.sh" "$MAJOR"

	# Make sure opt/llvm-dis/llvm-strip (package llvm-N) are there too.
	info "installing clang-$MAJOR and llvm-$MAJOR"
	run_root apt-get install -y "clang-$MAJOR" "llvm-$MAJOR"
}

# ------------------------------------------------------------------ main ---

if [ -n "$PREFIX" ]; then
	PREFIX=$(cd "$PREFIX" 2>/dev/null && pwd) || die "--prefix directory does not exist"
	check_prefix "$PREFIX" || die "$PREFIX is not a usable LLVM prefix"
else
	if PREFIX=$(find_prefix); then
		info "found host LLVM $(clang_version "$PREFIX") in $PREFIX"
	else
		info "no suitable host LLVM $MAJOR found"
		if [ "$CHECK_ONLY" -eq 1 ]; then
			echo "Run without --check to install it."
			exit 1
		fi
		[ "$DO_INSTALL" -eq 1 ] || die "not installed and --no-install given"
		install_llvm
		PREFIX=$(find_prefix) || die "LLVM $MAJOR installed but no usable prefix found; use --prefix DIR"
		info "installed host LLVM $(clang_version "$PREFIX") in $PREFIX"
	fi
fi

info "toolchain prefix: $PREFIX"
for t in $TOOLS; do
	printf '    %-12s %s\n' "$t" "$("$PREFIX/bin/$t" --version 2>&1 | grep -m1 -i 'version' || true)"
done

if [ "$CHECK_ONLY" -eq 1 ]; then
	exit 0
fi

if [ "$DO_CONFIG" -ne 1 ]; then
	cat <<EOF

Not touching .config. To use it, rerun with --config, or set:
  CONFIG_DEVEL=y
  CONFIG_BPF_TOOLCHAIN_HOST=y
  CONFIG_BPF_TOOLCHAIN_HOST_PATH="$PREFIX"
EOF
	exit 0
fi

CFG="$TREE/.config"
[ -f "$CFG" ] || die "$CFG not found; run 'make menuconfig' (or copy your config and 'make defconfig') first"

cp -p "$CFG" "$CFG.bak-llvm"
info "backed up .config to .config.bak-llvm"

# Drop every BPF toolchain / LLVM selection and set the host one. DEVEL must
# be on or the BPF toolchain choice is not honoured (it is hidden otherwise).
sed -i -E '/^(# )?CONFIG_(DEVEL|BPF_TOOLCHAIN_[A-Z_]+|USE_LLVM_[A-Z_]+)([= ]|$)/d' "$CFG"
cat >>"$CFG" <<EOF
CONFIG_DEVEL=y
CONFIG_BPF_TOOLCHAIN_HOST=y
CONFIG_BPF_TOOLCHAIN_HOST_PATH="$PREFIX"
EOF

if [ "$DO_DEFCONFIG" -eq 1 ]; then
	info "running make defconfig"
	make -C "$TREE" defconfig >/dev/null
	grep -q '^CONFIG_USE_LLVM_HOST=y' "$CFG" ||
		die "CONFIG_USE_LLVM_HOST=y is not set after defconfig; check .config (backup: .config.bak-llvm)"
	if grep -q '^CONFIG_USE_LLVM_BUILD=y' "$CFG"; then
		die "CONFIG_USE_LLVM_BUILD is still set after defconfig; check .config (backup: .config.bak-llvm)"
	fi
fi

info ".config now contains:"
grep -E '^CONFIG_(DEVEL|BPF_TOOLCHAIN_|USE_LLVM_)' "$CFG" | sed 's/^/    /'

cat <<EOF

Done. Rebuild packages that already compiled BPF objects, e.g.:
  make package/network/services/unetd/{clean,compile} V=s
then run your normal 'make -j\$(nproc)'.
EOF
