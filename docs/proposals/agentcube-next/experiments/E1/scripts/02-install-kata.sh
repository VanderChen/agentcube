#!/usr/bin/env bash
# E1 step 02: install the Kata release the PVM project tests against, with its installer.
set -euo pipefail
CTX=/build/pvm/context
# shellcheck source=/dev/null
source "$CTX/configs/ubuntu-24.04-basic.env"
echo "KATA_VERSION=$KATA_VERSION"
echo "KATA_ARCHIVE_URL=$KATA_ARCHIVE_URL"
echo "KATA_ARCHIVE_SHA256=$KATA_ARCHIVE_SHA256"

archive=/build/pvm/cache/$(basename "$KATA_ARCHIVE_URL")
if [[ ! -s "$archive" ]]; then
  curl -fL --retry 3 -sS -o "$archive.part" "$KATA_ARCHIVE_URL"
  mv "$archive.part" "$archive"
fi
ls -l "$archive" | awk '{print $5, $9}'
printf '%s  %s\n' "$KATA_ARCHIVE_SHA256" "$archive" | sha256sum -c -

echo "## install (PVM project's scripts/kata/install-kata.sh; it restarts containerd)"
"$CTX/scripts/kata/install-kata.sh" "$archive"

echo "## what was installed"
ls -l /usr/local/bin/containerd-shim-kata-v2 /usr/local/bin/kata-runtime 2>&1 | awk '{print $9, $10, $11}'
ls /opt/kata/bin /opt/kata/runtime-rs/bin 2>&1
ls -l /opt/kata/share/kata-containers | awk '{print $5, $9, $10, $11}'
ls /opt/kata/share/defaults/kata-containers /opt/kata/share/defaults/kata-containers/runtime-rs 2>&1
ls -l /opt/kata/share/kata-qemu/qemu/qboot.rom | awk '{print $5, $9}'
/opt/kata/bin/qemu-system-x86_64 --version | sed -n 1p
/opt/kata/bin/cloud-hypervisor --version
ls /opt/kata/bin/firecracker 2>&1 || true
du -sh /opt/kata | cut -f1 | sed 's/^/size of \/opt\/kata: /'
systemctl is-active containerd docker
