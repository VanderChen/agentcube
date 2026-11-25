#!/usr/bin/env bash
# E3: allow this boot and start Docker and CubeSandbox. Refuses to run unless
# the firewall of E2 is in place and a dead-man timer is armed.
set -uo pipefail
T=/usr/local/services/cubetoolbox
iptables -C INPUT -i eth0 -j E2-IN 2> /dev/null || { echo "the firewall is not in place; not starting"; exit 1; }
systemctl list-timers 'e2-deadman-*' --no-legend --no-pager | grep -q e2-deadman || { echo "no dead-man timer is armed; not starting"; exit 1; }
grep -q '^kvm_pvm ' /proc/modules && [[ -c /dev/kvm ]] || { echo "no PVM /dev/kvm; not starting"; exit 1; }
mountpoint -q /data/cubelet || { echo "/data/cubelet is not mounted; not starting"; exit 1; }
touch /run/e2-allow
systemctl start docker.socket docker.service; echo "docker: $(systemctl is-active docker.service)"
start=$(date +%s)
systemctl start cube-sandbox-control.target; echo "start cube-sandbox-control.target exit=$?"
ok=1
for _ in $(seq 1 60); do
  if timeout 120 "$T/scripts/one-click/quickcheck.sh" > /root/e3/quickcheck.out 2>&1; then ok=0; break; fi
  sleep 5
done
echo "quickcheck $([[ $ok == 0 ]] && echo OK || echo FAILED) after $(( $(date +%s) - start )) s"
tail -6 /root/e3/quickcheck.out | cut -c1-200
echo "cube-sandbox units: active $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active '), failed $(systemctl list-units 'cube-sandbox*' --all --no-legend --no-pager | grep -c ' failed ')"
systemctl list-units 'cube-sandbox*' --all --no-legend --no-pager | grep ' failed ' | cut -c1-120
ls -l "$T/cube-kernel-scf/vmlinux" | awk '{print $9, $10, $11}'
exit "$ok"
