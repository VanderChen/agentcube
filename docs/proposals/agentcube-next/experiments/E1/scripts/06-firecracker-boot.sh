#!/usr/bin/env bash
# E1 step 06: the PVM project's direct-boot check. Firecracker boots the PVM
# guest kernel with the Kata guest image, without Kata or containerd.
# This is the first time guest code runs on this host.
set -uo pipefail
CTX=/build/pvm/context
rootfs=$(readlink -f /opt/kata/share/kata-containers/kata-containers.img)
echo "rootfs=$rootfs"
echo "guest kernel=$(cat /opt/kata/share/kata-containers/vmlinux.pvm.uname)"
before=$(journalctl -k -b --no-pager -q | wc -l)

# The PVM project's script clears the kernel ring buffer (dmesg -C). The journal keeps the lines.
PVM_MODULE=kvm_pvm FIRECRACKER_TIMEOUT=${FIRECRACKER_TIMEOUT:-45} PVM_ROOTFS="$rootfs" \
  "$CTX/scripts/firecracker-pvm-test.sh" "$CTX/scripts/firecracker-pvm.json" > /build/pvm/logs/firecracker-pvm-test.out 2>&1
rc=$?
echo "## PVM project's scripts/firecracker-pvm-test.sh exit=$rc"
echo "## its output: first 12 lines, lines that mention pvm or the agent, last 12 lines"
total=$(wc -l < /build/pvm/logs/firecracker-pvm-test.out)
echo "(total lines: $total; full copy on the VM at /build/pvm/logs/firecracker-pvm-test.out)"
head -12 /build/pvm/logs/firecracker-pvm-test.out | cut -c1-220
echo "..."
grep -n -i -E 'pvm|Linux version|kata-agent|kata-containers.target|ttRPC|panic|BUG|Oops|segfault|general protection' /build/pvm/logs/firecracker-pvm-test.out | cut -c1-220 | head -40
echo "..."
tail -12 /build/pvm/logs/firecracker-pvm-test.out | cut -c1-220

echo "## host kernel log lines added during the test"
journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | cut -c1-220
echo "(end)"
echo "tainted=$(cat /proc/sys/kernel/tainted)"
pgrep -a firecracker || echo "no firecracker process left"
exit "$rc"
