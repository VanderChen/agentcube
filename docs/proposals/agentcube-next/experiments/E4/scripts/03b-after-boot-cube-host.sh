#!/usr/bin/env bash
# E4 step 03b: after booting CubeSandbox's PVM host kernel with a reduced parameter list.
set -uo pipefail
rc=0
echo "kernel: $(uname -r)"
sed -E 's/root=UUID=[0-9a-f-]+/root=UUID=<uuid>/' /proc/cmdline | fold -w 190
echo "up_since=$(uptime -s)"
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
[[ $(uname -r) == 6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e ]] || { echo "UNEXPECTED KERNEL"; exit 1; }
grep -c -w la57 /proc/cpuinfo | sed 's/^/logical CPUs with the la57 flag: /' || true
cat /sys/devices/system/clocksource/clocksource0/current_clocksource | sed 's/^/clocksource: /'
grep -E '^(meltdown|spectre_v2)' /dev/null; for v in meltdown spectre_v2; do printf '%s: %s\n' "$v" "$(cut -c1-70 /sys/devices/system/cpu/vulnerabilities/$v)"; done
echo "cube-sandbox units active: $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active ' || true); docker: $(systemctl is-active docker.service); allow file: $(ls /run/e2-allow 2> /dev/null || echo absent)"
echo "listening, not loopback: $(ss -H -lntup | awk '{print $1, $5, $7}' | grep -v -E ' (127\.[0-9.]+(%[a-z0-9]+)?|\[::1\]):' | sed -E 's/users:\(\("([^"]+)".*/\1/; s/ ([0-9]{1,3}\.){3}[0-9]{1,3}(%[a-z0-9]+)?:/ <v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | sort -u | tr '\n' ';')"
modprobe kvm_pvm; echo "modprobe kvm_pvm exit=$?"
lsmod | grep -E '^kvm' || rc=1
modinfo -n kvm_pvm; ls -l /dev/kvm || rc=1
echo "tainted=$(cat /proc/sys/kernel/tainted)"
dmesg --level=err,crit,alert,emerg | cut -c1-180 | tail -5; echo "(end of error-level kernel log)"
exit "$rc"
