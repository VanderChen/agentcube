#!/usr/bin/env bash
# E4 step 03: after booting the Ubuntu PVM host with extra parameters.
#   EXPECT_PARAMS="nokaslr no5lvl ..."   parameters that must be on the command line
set -uo pipefail
EXPECT_PARAMS=${EXPECT_PARAMS:-nokaslr no5lvl}
rc=0
echo "kernel: $(uname -r)"
sed -E 's/root=UUID=[0-9a-f-]+/root=UUID=<uuid>/' /proc/cmdline | fold -w 190
echo "up_since=$(uptime -s)"
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
[[ $(uname -r) == 6.8.0-139-generic ]] || { echo "UNEXPECTED KERNEL"; exit 1; }
for p in $EXPECT_PARAMS; do grep -qw -- "$p" /proc/cmdline && echo "parameter present: $p" || { echo "parameter MISSING: $p"; rc=1; }; done
echo "## paging"
grep -c -w la57 /proc/cpuinfo | sed 's/^/logical CPUs with the la57 flag: /' || true
grep -m1 -E '^address sizes' /proc/cpuinfo
dmesg | grep -i -E 'la57|5-level|no5lvl' | cut -c1-160 | sed -n '1,4p'
echo "## what started by itself"
for u in docker.service containerd.service ssh.service; do printf '%s: %s\n' "$u" "$(systemctl is-active "$u" 2> /dev/null | sed -n 1p)"; done
echo "cube-sandbox units active: $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active ' || true); allow file: $(ls /run/e2-allow 2> /dev/null || echo absent)"
echo "listening, not loopback: $(ss -H -lntup | awk '{print $1, $5, $7}' | grep -v -E ' (127\.[0-9.]+(%[a-z0-9]+)?|\[::1\]):' | sed -E 's/users:\(\("([^"]+)".*/\1/; s/ ([0-9]{1,3}\.){3}[0-9]{1,3}(%[a-z0-9]+)?:/ <v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | sort -u | tr '\n' ';')"
echo "## PVM module"
modprobe kvm-pvm; echo "modprobe kvm-pvm exit=$?"
lsmod | grep -E '^kvm' || rc=1
modinfo -n kvm_pvm; ls -l /dev/kvm || rc=1
dmesg | grep -i -E '\bkvm\b|pvm' | grep -v -E 'kvm-clock|kvm-guest|Booting paravirt|Hypervisor detected|ommand line' | cut -c1-180 | tail -5
echo "tainted=$(cat /proc/sys/kernel/tainted)"
dmesg --level=err,crit,alert,emerg | cut -c1-180 | tail -5; echo "(end of error-level kernel log)"
exit "$rc"
