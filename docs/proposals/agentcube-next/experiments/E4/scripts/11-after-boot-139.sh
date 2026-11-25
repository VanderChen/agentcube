#!/usr/bin/env bash
# E2: checks after a reboot.
#   EXPECT=149   the fallback: original kernel, nothing of the experiments running
#   EXPECT=139   the PVM host: load kvm-pvm, mount the XFS file, allow this boot
set -uo pipefail
EXPECT=${EXPECT:?149 or 139}
rc=0
echo "kernel: $(uname -r)"
echo "cmdline: $(cat /proc/cmdline)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) up_since=$(uptime -s)"
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
[[ $(uname -r) == 6.8.0-$EXPECT-generic ]] || { echo "UNEXPECTED KERNEL"; rc=1; }
grep -q 'BOOT_IMAGE=' /proc/cmdline || { echo "did not come through the boot loader"; rc=1; }
echo "## what started by itself at this boot"
echo "allow file: $(ls /run/e2-allow 2> /dev/null || echo absent)"
for u in docker.service docker.socket containerd.service ssh.service systemd-resolved.service; do printf '%s: %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null | sed -n 1p)"; done
systemctl list-units 'cube-sandbox*' --no-legend --no-pager | awk '{print $1, $3, $4}' | sed -n '1,30p'
systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c -E ' active ' | sed 's/^/cube-sandbox units active: /'
lsmod | grep -E '^kvm' || echo "no kvm module loaded"
ls -l /dev/kvm 2>&1 | cut -c1-80
mountpoint -q /data/cubelet && echo "/data/cubelet mounted" || echo "/data/cubelet not mounted"
echo "tc filters on eth0: ingress $(tc filter show dev eth0 ingress 2>/dev/null | wc -l) lines, egress $(tc filter show dev eth0 egress 2>/dev/null | wc -l) lines; qdiscs: $(tc qdisc show dev eth0 | awk '{print $2}' | sort | uniq -c | tr -s ' \n' ' ')"
echo "iptables E2-IN chain: $(iptables -S E2-IN 2>/dev/null | wc -l) rules"
echo "listening, not loopback: $(ss -H -lntup | awk '{print $1, $5, $7}' | grep -v -E ' (127\.[0-9.]+(%[a-z0-9]+)?|\[::1\]):' | sed -E 's/users:\(\("([^"]+)".*/\1/; s/ ([0-9]{1,3}\.){3}[0-9]{1,3}(%[a-z0-9]+)?:/ <v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | sort -u | tr '\n' ';')"
systemctl --failed --no-legend --no-pager | cut -c1-120; echo "(end failed units)"
if [[ $EXPECT == 139 && $rc == 0 ]]; then
  echo "## make it a PVM host again"
  grep -qw nokaslr /proc/cmdline || { echo "nokaslr missing"; rc=1; }
  modprobe kvm-pvm && lsmod | grep -E '^kvm' && ls -l /dev/kvm || rc=1
  if [[ -e /var/lib/e2/cubelet.xfs ]] && ! mountpoint -q /data/cubelet; then
    mount -o loop,noatime /var/lib/e2/cubelet.xfs /data/cubelet && df -hT /data/cubelet | tail -1 || rc=1
  fi
  touch /run/e2-allow
  systemctl start docker.socket docker.service && echo "docker: $(systemctl is-active docker.service)" || rc=1
  echo "tainted=$(cat /proc/sys/kernel/tainted)"
fi
exit "$rc"
