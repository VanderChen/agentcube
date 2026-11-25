#!/usr/bin/env bash
# E1 step 07: the PVM project's Kata smoke test: one container per hypervisor
# (QEMU, Dragonball, Cloud Hypervisor) through containerd's ctr, runtime-rs shim.
set -uo pipefail
CTX=/build/pvm/context
echo "shim: $(readlink -f /usr/local/bin/containerd-shim-kata-v2)"
containerd --version
before=$(journalctl -k -b --no-pager -q | wc -l)

"$CTX/scripts/kata-pvm-test-all.sh" "${1:-all}" > /build/pvm/logs/kata-pvm-test-all.out 2>&1
rc=$?
echo "## PVM project's scripts/kata-pvm-test-all.sh exit=$rc"
echo "(full copy on the VM at /build/pvm/logs/kata-pvm-test-all.out)"
cut -c1-240 /build/pvm/logs/kata-pvm-test-all.out | head -150

echo "## host kernel log lines added during the test"
journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | cut -c1-220 | head -60
echo "(end)"
echo "## leftovers"
ctr containers ls -q | head; ctr tasks ls | tail -n +2 | head
pgrep -a -f 'containerd-shim-kata|qemu-system|cloud-hypervisor|virtiofsd' | cut -c1-160 || echo "no shim, VMM or virtiofsd process left"
echo "tainted=$(cat /proc/sys/kernel/tainted)"
exit "$rc"
