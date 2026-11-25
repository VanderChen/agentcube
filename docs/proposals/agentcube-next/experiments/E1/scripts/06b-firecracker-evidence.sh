#!/usr/bin/env bash
# E1 step 06b: read-only. Step 06 ended with exit 1 from the PVM project's
# script. This prints the saved guest console in full and re-applies that
# script's checks one by one, so that the verdict can be read from evidence.
set -uo pipefail
out=/build/pvm/logs/firecracker-pvm-test.out
[[ -s "$out" ]] || { echo "no saved output"; exit 1; }
sha256sum "$out"

echo "## the three checks in scripts/firecracker-pvm-test.sh, applied to the saved output"
if grep -Eq 'Linux version .*pvm' "$out"; then echo "check 1 (banner matches 'Linux version .*pvm'): yes"; else echo "check 1 (banner matches 'Linux version .*pvm'): NO"; fi
grep -m1 -E 'Linux version' "$out" | cut -c1-200
echo "   the kernel was built here as root@$(hostname) with an empty CONFIG_LOCALVERSION, so the banner has no 'pvm' in it:"
grep -E '^CONFIG_LOCALVERSION=' /build/pvm/build/guest-kernel/.config
if grep -Eq 'Reached target .*kata-containers.target|ttRPC server started' "$out"; then echo "check 2 (kata-agent became ready): yes"; else echo "check 2 (kata-agent became ready): NO"; fi
grep -E 'Reached target .*kata-containers.target|ttRPC server started' "$out" | cut -c1-200
echo "check 3 (host kernel log has none of refcount|WARNING:|BUG:|Oops|general protection|Call Trace): see the host lines in log-06-firecracker-boot.txt"

echo "## is the guest really a PVM guest? lines of the guest console that say so"
grep -n -i -E 'hypervisor detected|paravirtualized|pvm|kvm-clock|clocksource:|tsc:|la57|5-level|x86/mm|Memory: |smp: Brought up|virtio_blk|EXT4-fs \(vda' "$out" | cut -c1-200 | head -40
echo "## firecracker exit status"
grep -n -E 'firecracker status|exit_code' "$out" | cut -c1-200
echo "   124 is the status of timeout(1): the test lets the guest run for FIRECRACKER_TIMEOUT seconds and then stops it"

echo "## full guest console and firecracker log (saved by step 06)"
cat "$out"
