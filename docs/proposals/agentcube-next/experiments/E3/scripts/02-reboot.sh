#!/usr/bin/env bash
# E3: stop CubeSandbox and reboot through the boot loader into one named entry, once.
#   ENTRY=e3-cube-pvm-host | e0-pvm-139
set -euo pipefail
ENTRY=${ENTRY:?boot entry id}
grep -q "menuentry_id_option '$ENTRY'" /boot/grub/grub.cfg
echo "now: $(uname -r) boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "## stop CubeSandbox"
timeout 120 systemctl stop cube-sandbox-control.target cube-sandbox-compute.target 2>&1 | tail -2 || true
units=$(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | awk '{print $1}')
if [[ -n "$units" ]]; then timeout 180 systemctl stop $units 2>&1 | tail -3 || true; fi
echo "cube-sandbox units still active: $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active ' || true)"
pgrep -a -f 'containerd-shim-cube|cube-runtime|qemu-system|cloud-hypervisor|firecracker|containerd-shim-kata' | cut -c1-100 || echo "no sandbox process is running"
echo "## reboot"
kexec -u 2> /dev/null || true
[[ $(cat /sys/kernel/kexec_loaded) == 0 ]]
grub-reboot "$ENTRY"
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
grep -c 'set default="gnulinux-advanced-.*6.8.0-149-generic' /boot/grub/grub.cfg | sed 's/^/default entry is 6.8.0-149 by id (1 = yes): /'
ls /etc/systemd/system/docker.service.d/10-e2-guard.conf /etc/systemd/system/cube-sandbox-.service.d/10-e2-guard.conf
sync
(sleep 2; SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot) > /dev/null 2>&1 &
disown
echo "reboot scheduled at $(date -u +%FT%TZ)"
