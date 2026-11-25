#!/usr/bin/env bash
# E3 step 10: leave CubeSandbox installed but dormant. Stop its units, stop its
# Docker containers and take away their restart policies, so that Docker can
# later be started without bringing them back.
set -uo pipefail
echo "## stop the units"
timeout 180 systemctl stop cube-sandbox-control.target cube-sandbox-compute.target 2>&1 | tail -2
units=$(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | awk '{print $1}')
if [[ -n "$units" ]]; then timeout 240 systemctl stop $units 2>&1 | tail -3; fi
echo "cube-sandbox units still active: $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active ')"
echo "## containers"
for c in $(docker ps -a --format '{{.Names}}'); do
  docker update --restart=no "$c" > /dev/null 2>&1
  docker stop -t 20 "$c" > /dev/null 2>&1
  printf '%s: restart=%s state=%s\n' "$c" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")" "$(docker inspect -f '{{.State.Status}}' "$c")"
done
echo "containers running: $(docker ps -q | wc -l)"
echo "## what is still there on this boot (a reboot follows)"
pgrep -a -f 'containerd-shim-cube|cube-runtime|cubelet|cubemaster|cube-api|cubeops|ops-agent' | cut -c1-100 || echo "no CubeSandbox process"
echo "tc filters on eth0: ingress $(tc filter show dev eth0 ingress 2> /dev/null | grep -c bpf), egress $(tc filter show dev eth0 egress 2> /dev/null | grep -c bpf) (CubeSandbox leaves them attached when it stops)"
ip -br link | awk '{print $1}' | grep -c -E '^(cube|192\.168\.)' | sed 's/^/CubeSandbox network devices left: /'
ss -H -lntup | awk '{print $1, $5, $7}' | grep -v -E ' (127\.[0-9.]+(%[a-z0-9]+)?|\[::1\]):' | sed -E 's/users:\(\("([^"]+)".*/\1/; s/ ([0-9]{1,3}\.){3}[0-9]{1,3}(%[a-z0-9]+)?:/ <v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | sort -u | tr '\n' ';'; echo
