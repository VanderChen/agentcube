#!/usr/bin/env bash
# E3: after booting CubeSandbox's PVM host kernel. Nothing of CubeSandbox or
# Docker is started here; that happens only after the firewall is back.
set -uo pipefail
EXPECT=${EXPECT:-6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e}
rc=0
echo "kernel: $(uname -r)"
cat /proc/cmdline | fold -w 190
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) up_since=$(uptime -s)"
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
[[ $(uname -r) == "$EXPECT" ]] || { echo "UNEXPECTED KERNEL"; exit 1; }
echo "## what started by itself"
echo "allow file: $(ls /run/e2-allow 2> /dev/null || echo absent)"
for u in docker.service docker.socket containerd.service ssh.service systemd-resolved.service systemd-networkd.service; do printf '%s: %s\n' "$u" "$(systemctl is-active "$u" 2> /dev/null | sed -n 1p)"; done
echo "cube-sandbox units active: $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active ' || true)"
systemctl --failed --no-legend --no-pager | cut -c1-120; echo "(end failed units)"
echo "## CPU and paging as this kernel sees them"
grep -m1 -E '^model name' /proc/cpuinfo; grep -m1 -E '^address sizes' /proc/cpuinfo
grep -c -w la57 /proc/cpuinfo | sed 's/^/logical CPUs with la57: /' || true
grep -m1 -o -w -E 'svm|vmx|hypervisor' /proc/cpuinfo | sort -u | tr '\n' ' '; echo
cat /sys/devices/system/clocksource/clocksource0/current_clocksource | sed 's/^/clocksource: /'
dmesg | grep -i -E 'kaslr|pti|page table isolation|5-level|clearcpuid|tsc: |Linux version' | cut -c1-170 | sed -n '1,10p'
echo "## PVM module"
lsmod | grep -E '^kvm' || echo "no kvm module loaded yet"
before=$(dmesg | wc -l)
modprobe kvm_pvm; echo "modprobe kvm_pvm exit=$?"
lsmod | grep -E '^kvm' || rc=1
modinfo -n kvm_pvm kvm 2>&1 | cut -c1-140
ls -l /dev/kvm || rc=1
dmesg | tail -n +"$((before + 1))" | cut -c1-200 | sed -n '1,12p'; echo "(end of kernel log lines added by modprobe)"
echo "tainted=$(cat /proc/sys/kernel/tainted)"
echo "## error-level kernel log of this boot"
dmesg --level=err,crit,alert,emerg | cut -c1-200 | tail -12; echo "(end)"
echo "## storage and firewall tooling"
if [[ -e /var/lib/e2/cubelet.xfs ]] && ! mountpoint -q /data/cubelet; then mount -o loop,noatime /var/lib/e2/cubelet.xfs /data/cubelet || rc=1; fi
df -hT /data/cubelet | tail -1
iptables -S INPUT > /dev/null 2>&1 && echo "iptables works on this kernel" || { echo "iptables does NOT work on this kernel"; rc=1; }
ip6tables -S INPUT > /dev/null 2>&1 && echo "ip6tables works on this kernel" || echo "ip6tables does not work on this kernel (IPv6 is disabled by the boot parameters)"
ip -br addr show eth0 | awk '{print $1, $2, NF-2, "addresses"}'
exit "$rc"
