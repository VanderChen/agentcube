#!/usr/bin/env bash
# E2: reboot through the boot loader.
#   TARGET=default   plain reboot; must come back on the pinned default (6.8.0-149)
#   TARGET=pvm       one-shot into the PVM host entry e0-pvm-139
set -euo pipefail
TARGET=${TARGET:?default or pvm}
kexec -u 2> /dev/null || true
echo "kexec_loaded=$(cat /sys/kernel/kexec_loaded)"
[[ $(cat /sys/kernel/kexec_loaded) == 0 ]]
echo "now: $(uname -r) boot_id=$(cat /proc/sys/kernel/random/boot_id)"
case "$TARGET" in
  default) grub-editenv /boot/grub/grubenv unset next_entry ;;
  pvm)     grep -q "menuentry_id_option 'e0-pvm-139'" /boot/grub/grub.cfg; grub-reboot e0-pvm-139 ;;
  *) echo "TARGET must be default or pvm" >&2; exit 2 ;;
esac
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
grep -m1 'set default=' /boot/grub/grub.cfg | sed 's/^[[:space:]]*//' | cut -c1-170
pgrep -a -f 'containerd-shim-kata|qemu-system|cloud-hypervisor|firecracker' | cut -c1-100 || echo "no sandbox is running"
sync
(sleep 2; SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot) > /dev/null 2>&1 &
disown
echo "reboot scheduled at $(date -u +%FT%TZ)"
