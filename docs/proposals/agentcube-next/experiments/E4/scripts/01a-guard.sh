#!/usr/bin/env bash
# E2 boot guard. Makes "any reboot gives back a quiet, reachable machine" true
# even with CubeSandbox installed and enabled: its units, and Docker (whose
# containers have restart policies), only start when /run/e2-allow exists.
# /run is a tmpfs, so the permission is gone after every boot, whatever caused it.
#
#   MODE=install         write the drop-ins (before CubeSandbox is installed) and allow this boot
#   MODE=allow           allow this boot and start Docker
#   MODE=release-docker  remove the guard from Docker only (after the CubeSandbox containers are disarmed)
#   MODE=status          show what is guarded and whether this boot is allowed
set -euo pipefail
MODE=${MODE:-status}
S=/etc/systemd/system
# systemd reads "cube-sandbox-.service.d" for every unit named cube-sandbox-*.service.
cube_dirs=(cube-sandbox-.service.d cube-sandbox-.target.d cube-sandbox-.timer.d)
docker_dirs=(docker.service.d docker.socket.d)
write() {
  install -d -m 0755 "$S/$1"
  printf '%s\n' '# E2 (AgentCube 000-5): do not start at boot. Allowed for the current boot by: touch /run/e2-allow' \
    '[Unit]' 'ConditionPathExists=/run/e2-allow' > "$S/$1/10-e2-guard.conf"
}
case "$MODE" in
  install)
    for d in "${cube_dirs[@]}" "${docker_dirs[@]}"; do write "$d"; done
    touch /run/e2-allow
    systemctl daemon-reload
    echo "guard installed and this boot allowed at $(date -u +%FT%TZ)"
    ;;
  allow)
    touch /run/e2-allow
    systemctl start docker.socket docker.service
    echo "this boot allowed at $(date -u +%FT%TZ)"
    ;;
  release-docker)
    for d in "${docker_dirs[@]}"; do rm -f "$S/$d/10-e2-guard.conf"; rmdir "$S/$d" 2>/dev/null || true; done
    systemctl daemon-reload
    echo "Docker is no longer guarded"
    ;;
  status) ;;
  *) echo "MODE must be install, allow, release-docker or status" >&2; exit 2 ;;
esac
echo "## guard files"
ls "$S"/*/10-e2-guard.conf 2>/dev/null || echo "none"
echo "## this boot: $(ls /run/e2-allow 2> /dev/null || echo 'not allowed (no /run/e2-allow)')"
echo "## units and the drop-ins systemd applies to them"
for u in docker.service docker.socket $(systemctl list-unit-files 'cube-sandbox*' --no-legend 2>/dev/null | awk '{print $1}'); do
  printf '%s: enabled=%s active=%s guarded=%s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null | sed -n 1p)" "$(systemctl is-active "$u" 2>/dev/null | sed -n 1p)" \
    "$(systemctl show -p DropInPaths --value "$u" | grep -q 10-e2-guard.conf && echo yes || echo NO)"
done
