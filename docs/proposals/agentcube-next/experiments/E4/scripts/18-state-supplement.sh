#!/usr/bin/env bash
# E4 step 18: read-only. Items that the records state about the final state but
# that step 16 did not print, and host settings that the comparison of E4 did
# not record. Both gaps were found by the review of the E4 record.
# Rules are counted, not printed, so that no address ends up in the output.
set -uo pipefail
count() { grep -c "$1" || true; }
echo "## kernel"
echo "$(uname -r), up since $(uptime -s)"
echo "## automatic updates"
for u in apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
  printf '%s: enabled=%s active=%s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null | sed -n 1p)" "$(systemctl is-active "$u" 2>/dev/null | sed -n 1p)"
done
grep -h -E 'Update-Package-Lists|Unattended-Upgrade ' /etc/apt/apt.conf.d/* 2>/dev/null | sort -u
echo "held packages: $(apt-mark showhold | wc -l)"
echo "## packet filter (rules that are not chain policies, per table)"
for t in filter nat mangle raw; do
  printf 'iptables %s: %s rules; chains: %s\n' "$t" "$(iptables -t "$t" -S 2>/dev/null | count '^-A')" \
    "$(iptables -t "$t" -S 2>/dev/null | awk '$1=="-N"{print $2}' | tr '\n' ' ')"
  printf 'ip6tables %s: %s rules\n' "$t" "$(ip6tables -t "$t" -S 2>/dev/null | count '^-A')"
done
echo "INPUT: $(iptables -S INPUT | sed -n 1p); rules: $(iptables -S INPUT | count '^-A')"
echo "DOCKER-USER rules: $(iptables -S DOCKER-USER 2>/dev/null | count '^-A')"
echo "E2-IN chain present: $(iptables -S E2-IN > /dev/null 2>&1 && echo yes || echo no)"
echo "## dead-man and guard"
echo "dead-man timers: $(systemctl list-timers 'e2-deadman-*' --all --no-legend --no-pager | count e2-deadman)"
ls /etc/systemd/system/*/10-e2-guard.conf 2>/dev/null
echo "allow file: $(ls /run/e2-allow 2>/dev/null || echo absent)"
echo "## what CubeSandbox and the SDK created outside the install directory"
for p in /data/CubeMaster /data/cube-shim /data/snapshot_pack /data/cubeops /data/cube-shared /data/shared /data/cubelet /data/log \
         /root/.config/uv /root/e2/venv /root/e2/quickstart /root/e2/quickstart-e4; do
  if [[ -e "$p" ]]; then echo "exists: $p ($(du -sh "$p" 2>/dev/null | cut -f1))"; else echo "absent: $p"; fi
done
echo "entries under /data: $(ls /data | tr '\n' ' ')"
echo "docker networks: $(docker network ls --format '{{.Name}}' | tr '\n' ' ')"
echo "docker containers: $(docker ps -a --format '{{.Names}}:{{.State}}' | tr '\n' ' ')"
echo "## containerd"
for ns in $(ctr namespaces ls -q); do
  echo "namespace $ns: containers=$(ctr -n "$ns" containers ls -q | wc -l) tasks=$(ctr -n "$ns" tasks ls -q | wc -l)"
done
echo "## settings of this host (Ubuntu PVM host, entry e0-pvm-139) that E4 did not record"
for m in kvm kvm_pvm; do
  for f in /sys/module/$m/parameters/*; do
    [[ -r "$f" ]] && printf '%s.%s=%s\n' "$m" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
done
echo "clocksource: $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
echo "cpus with the la57 flag: $(grep -c -w la57 /proc/cpuinfo || true)"
for f in /sys/devices/system/cpu/vulnerabilities/*; do printf '%s: %s\n' "$(basename "$f")" "$(cat "$f")"; done
exit 0
