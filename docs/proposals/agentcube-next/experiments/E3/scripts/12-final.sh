#!/usr/bin/env bash
# E3 step 12: final arrangement on the Ubuntu PVM host. Docker runs normally
# again (its guard is removed; the only CubeSandbox container left has no
# restart policy). CubeSandbox stays installed and guarded: it does not start
# at boot, and on this boot the permission file is removed as well.
set -uo pipefail
S=/etc/systemd/system
echo "## Docker containers before releasing the guard"
for c in $(docker ps -a --format '{{.Names}}'); do printf '%s restart=%s state=%s\n' "$c" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")" "$(docker inspect -f '{{.State.Status}}' "$c")"; done
bad=$(for c in $(docker ps -a --format '{{.Names}}'); do docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c"; done | grep -c -v -E '^(no|)$' || true)
[[ "$bad" == 0 ]] || { echo "$bad container(s) would restart with Docker; not releasing the guard"; exit 1; }
for d in docker.service.d docker.socket.d; do rm -f "$S/$d/10-e2-guard.conf"; rmdir "$S/$d" 2> /dev/null || true; done
systemctl daemon-reload
rm -f /run/e2-allow
mountpoint -q /data/cubelet && umount /data/cubelet
echo "## result"
ls "$S"/*/10-e2-guard.conf
for u in docker.service docker.socket cube-sandbox-control.target cube-sandbox-cubelet.service; do
  printf '%s: enabled=%s active=%s guarded=%s\n' "$u" "$(systemctl is-enabled "$u" 2> /dev/null | sed -n 1p)" "$(systemctl is-active "$u" 2> /dev/null | sed -n 1p)" \
    "$(systemctl show -p DropInPaths --value "$u" | grep -q 10-e2-guard.conf && echo yes || echo no)"
done
echo "allow file: $(ls /run/e2-allow 2> /dev/null || echo absent); /data/cubelet: $(mountpoint -q /data/cubelet && echo mounted || echo 'not mounted')"
echo "## the guard still refuses CubeSandbox on this boot"
systemctl start cube-sandbox-cubelet.service 2>&1 | cut -c1-200; sleep 1
printf 'cube-sandbox-cubelet.service after a start request: active=%s, condition met=%s\n' "$(systemctl is-active cube-sandbox-cubelet.service)" "$(systemctl show -p ConditionResult --value cube-sandbox-cubelet.service)"
systemctl list-timers 'e2-deadman-*' --all --no-legend --no-pager | grep -c e2-deadman | sed 's/^/dead-man timers: /'
