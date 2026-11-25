#!/usr/bin/env bash
# E2 dead-man switch. A timer that reboots the VM unless it is cancelled.
# It covers the case "ssh is lost while the machine keeps running": nobody can
# log in to fix it, so the machine reboots by itself. What makes the reboot
# safe is the boot guard of 01a-guard.sh: after any boot, CubeSandbox and
# Docker stay off until they are allowed again.
#
#   MODE=arm MINUTES=30   start a new timer, check it, then stop the older ones (no gap in coverage)
#   MODE=cancel           stop all timers; run only when the experiment is quiet again
#   MODE=status           show the timers
#
# Each mode is run by tools/vmrun.sh over a NEW ssh connection, so a
# successful run is also the proof that ssh still works.
set -euo pipefail
MODE=${MODE:-status}
MINUTES=${MINUTES:-30}
install -d -m 0755 /root/exp/E2
cat > /root/exp/E2/deadman-action.sh <<'ACTION'
#!/bin/bash
# Runs only when an E2 dead-man timer was not replaced or cancelled in time.
exec >> /root/exp/E2/deadman.log 2>&1
echo "=== fired $(date -u +%FT%TZ) on $(uname -r); guard files: $(ls /etc/systemd/system/*/10-e2-guard.conf 2>/dev/null | wc -l); allow file: $(ls /run/e2-allow 2>&1)"
grub-editenv /boot/grub/grubenv unset next_entry
kexec -u 2>/dev/null
sync
SYSTEMCTL_SKIP_AUTO_KEXEC=1 systemctl reboot
# If the orderly shutdown hangs on some unit, force it.
sleep 180
echo "orderly reboot did not finish in 180 s; forcing"
sync
systemctl reboot --force --force
ACTION
chmod 0755 /root/exp/E2/deadman-action.sh

timers() { systemctl list-timers 'e2-deadman-*' --all --no-legend --no-pager | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^e2-deadman-.*\.timer$/) print $i}'; }

case "$MODE" in
  arm)
    ls /etc/systemd/system/docker.service.d/10-e2-guard.conf > /dev/null 2>&1 ||
      echo "WARNING: the boot guard is not installed; a reboot would start CubeSandbox and Docker again"
    old=$(timers)
    new="e2-deadman-$(date +%s)"
    systemd-run --quiet --unit="$new" --description="E2 dead-man switch" \
      --on-active="${MINUTES}min" --timer-property=AccuracySec=1s /root/exp/E2/deadman-action.sh
    systemctl is-active --quiet "$new.timer" || { echo "the new timer is not active; older timers left in place"; exit 1; }
    echo "armed $new for $MINUTES minutes at $(date -u +%FT%TZ)"
    for t in $old; do systemctl stop "$t" && echo "stopped older $t"; done
    ;;
  cancel)
    for t in $(timers); do systemctl stop "$t" && echo "stopped $t at $(date -u +%FT%TZ)"; done
    ;;
  status) ;;
  *) echo "MODE must be arm, cancel or status" >&2; exit 2 ;;
esac
echo "## timers"
systemctl list-timers 'e2-deadman-*' --all --no-legend --no-pager | sed -E 's/ +/ /g' | cut -c1-150
[[ -n "$(timers)" ]] || echo "none"
echo "## has the action ever started?"
if [[ -s /root/exp/E2/deadman.log ]]; then cat /root/exp/E2/deadman.log; else echo "no"; fi
systemctl list-units 'e2-deadman-*.service' --all --no-legend --no-pager | cut -c1-120
