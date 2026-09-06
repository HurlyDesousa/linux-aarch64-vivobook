#!/bin/sh
# Rebuild ALWAYS_START qebspil + main-fail file/efivar log.
# Native aarch64: omit CROSS_COMPILE. Cross: aarch64-linux-gnu-.
set -eu
PIN=8e4d9e676a3b3afe136cda9b953a2139ff1a32d0
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKDIR=${WORKDIR:-/tmp/qebspil-main-fail-log}
CROSS=${CROSS_COMPILE:-}

if [ "$(uname -m)" != aarch64 ] && [ -z "$CROSS" ]; then
	CROSS=aarch64-linux-gnu-
fi

rm -rf "$WORKDIR"
git clone --recursive https://github.com/stephan-gh/qebspil.git "$WORKDIR"
git -C "$WORKDIR" checkout "$PIN"
git -C "$WORKDIR" submodule update --init --recursive
patch -d "$WORKDIR" -p1 --forward --batch < "$HERE/0001-main-fail-file-and-efivar-log.patch"
make -C "$WORKDIR" CROSS_COMPILE="$CROSS" QEBSPIL_ALWAYS_START=1 -j"$(nproc)"
cp -f "$WORKDIR/out/qebspilaa64.efi" "$HERE/qebspilaa64.efi"
echo "built $HERE/qebspilaa64.efi"
ls -l "$HERE/qebspilaa64.efi"
