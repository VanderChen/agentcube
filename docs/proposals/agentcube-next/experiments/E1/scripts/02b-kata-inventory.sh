#!/usr/bin/env bash
# E1 step 02b: read-only inventory of the Kata installation. Split from step 02
# because the listing there stopped at a file the release does not ship.
set -uo pipefail
echo "## links in /usr/local/bin"
for f in containerd-shim-kata-v2 kata-runtime kata-collect-data.sh firecracker; do
  if [[ -e /usr/local/bin/$f || -L /usr/local/bin/$f ]]; then
    printf '%s -> %s\n' "/usr/local/bin/$f" "$(readlink -f "/usr/local/bin/$f")"
  else
    printf '%s: absent\n' "/usr/local/bin/$f"
  fi
done
cat /opt/kata/VERSION
/usr/local/bin/containerd-shim-kata-v2 --version
echo "## /opt/kata/bin"; ls /opt/kata/bin
echo "## /opt/kata/runtime-rs/bin"; ls /opt/kata/runtime-rs/bin
echo "## /opt/kata/libexec"; ls /opt/kata/libexec 2>&1
echo "## guest kernels and images shipped with the release"
ls -l /opt/kata/share/kata-containers | awk 'NR>1 {print $5, $9, $10, $11}'
echo "## configurations shipped with the release"
ls /opt/kata/share/defaults/kata-containers
echo "runtime-rs:"; ls /opt/kata/share/defaults/kata-containers/runtime-rs 2>&1
echo "## firmware"
ls -l /opt/kata/share/kata-qemu/qemu/qboot.rom 2>&1 | awk '{print $5, $9}'
echo "## VMM versions"
/opt/kata/bin/qemu-system-x86_64 --version | sed -n 1p
/opt/kata/bin/cloud-hypervisor --version
ls /opt/kata/bin/firecracker 2>/dev/null || echo "the release does not ship firecracker"
strings /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 2>/dev/null | grep -m3 -i -E 'dragonball.*[0-9]+\.[0-9]+\.[0-9]+' || echo "dragonball is built into the runtime-rs shim; no separate version string found"
echo "## size and services"
du -sh /opt/kata | cut -f1 | sed 's/^/size of \/opt\/kata: /'
ls -d /opt/kata.previous 2>/dev/null || echo "no /opt/kata.previous"
systemctl is-active containerd docker
ctr version | sed -n '1,8p'
