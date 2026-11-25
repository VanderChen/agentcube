#!/usr/bin/env bash
# E2 step 07: read-only. What the installer left running, and whether it uses the PVM guest kernel.
set -uo pipefail
T=/usr/local/services/cubetoolbox
echo "## units"
systemctl list-units 'cube-sandbox*' --all --no-legend --no-pager | awk '{print $1, $2, $3, $4}' | sed 's/^●//'
echo "active: $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active '); failed: $(systemctl list-units 'cube-sandbox*' --all --no-legend --no-pager | grep -c ' failed ')"
echo "enabled at boot: $(systemctl list-unit-files 'cube-sandbox*' --no-legend --no-pager | awk '$2=="enabled" {print $1}' | tr '\n' ' ')"
echo "## PVM switch and the guest kernel in use"
grep -E '^(CUBE_PVM_ENABLE|MIRROR|ONE_CLICK_ENABLE_S3LVOL|ONE_CLICK_DEPLOY_ROLE|CUBE_SANDBOX_NETWORK_CIDR|CUBE_SANDBOX_ETH_NAME|CUBE_SANDBOX_MINIO_ENABLED)=' "$T/.one-click.env"
grep -c -E '^CUBE_SANDBOX_NODE_IP=' "$T/.one-click.env" | sed 's/^/node IP lines in .one-click.env (value not shown): /'
ls -l "$T/cube-kernel-scf/" | awk 'NR>1 {print $5, $9, $10, $11}'
for f in "$T"/cube-kernel-scf/vmlinux*; do printf '%s  %s  %s\n' "$(sha256sum "$f" | cut -c1-64)" "$f" "$(strings "$f" | grep -m1 -E '^Linux version ' | cut -c1-110)"; done
cmp -s "$T/cube-kernel-scf/vmlinux" "$T/cube-kernel-scf/vmlinux-pvm" 2> /dev/null && echo "the active vmlinux is byte-identical to vmlinux-pvm" || echo "the active vmlinux is NOT identical to a file named vmlinux-pvm (or that file is absent)"
echo "## component versions"
cat "$T/VERSION.txt" 2> /dev/null | sed -n 1,3p
for b in "$T/Cubelet/bin/cubelet" "$T/CubeMaster/bin/cubemaster" "$T/CubeMaster/bin/cubemastercli"; do [[ -x $b ]] && printf '%s: %s\n' "$b" "$("$b" --version 2>&1 | sed -n 1p | cut -c1-120)"; done
ls "$T" | tr '\n' ' '; echo
echo "## the installer's own check"
if [[ -x "$T/scripts/one-click/quickcheck.sh" ]]; then timeout 120 "$T/scripts/one-click/quickcheck.sh" 2>&1 | cut -c1-200 | tail -40; echo "quickcheck exit=${PIPESTATUS[0]}"; else echo "no quickcheck.sh"; fi
echo "## API"
curl -fsS -m 10 http://127.0.0.1:3000/health 2>&1 | cut -c1-300; echo
timeout 30 "$T/CubeMaster/bin/cubemastercli" template list --json 2>&1 | cut -c1-400 | sed -n '1,12p'
echo "## containers"
docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}' | cut -c1-200
docker ps -a --format '{{.Names}}' | while read -r c; do printf '%s restart=%s network=%s\n' "$c" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")" "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c")"; done
echo "## sockets listening on something other than loopback"
ss -H -lntup | awk '{print $1, $5, $7}' | grep -v -E ' (127\.[0-9.]+(%[a-z0-9]+)?|\[::1\]):' | sed -E 's/users:\(\("([^"]+)".*/\1/' | sort -u |
  sed -E 's/ ([0-9]{1,3}\.){3}[0-9]{1,3}(%[a-z0-9]+)?:/ <v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | cut -c1-100
echo "## what CubeSandbox did to the uplink and to DNS"
tc qdisc show dev eth0 | awk '{print $2}' | sort | uniq -c | tr -s ' \n' ' '; echo
tc filter show dev eth0 ingress 2> /dev/null | grep -E 'filter|bpf' | cut -c1-160 | sed -n '1,6p'
tc filter show dev eth0 egress 2> /dev/null | grep -E 'filter|bpf' | cut -c1-160 | sed -n '1,6p'
ip -br link | awk '{print $1, $2}' | tr '\n' ';'; echo
ip -4 route | grep -v -E 'eth0|docker0' | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<v4>/g' | cut -c1-120
resolvectl status cube-dns0 2> /dev/null | grep -E 'Scopes|DNS Domain|Current DNS' | sed -E 's/^ +//' | cut -c1-100
a=$(getent ahostsv4 test.cube.app | awk 'NR==1 {print $1}'); n=$(sed -n 's/^CUBE_SANDBOX_NODE_IP=//p' "$T/.one-click.env" | sed -n 1p)
[[ -n "$a" && "$a" == "$n" ]] && echo "test.cube.app resolves to the node IP" || echo "test.cube.app does NOT resolve to the node IP (got: ${a:+something else}${a:-nothing})"
getent ahostsv4 github.com > /dev/null && echo "ordinary DNS still works (github.com resolves)" || echo "ordinary DNS is BROKEN"
sysctl -n net.ipv4.ip_forward net.ipv4.conf.eth0.rp_filter net.ipv4.conf.all.rp_filter | tr '\n' ' ' | sed 's/^/ip_forward, eth0.rp_filter, all.rp_filter: /'; echo
echo "## firewall still in place"
iptables -S INPUT | sed -n 1,4p; iptables -S E2-IN | wc -l | sed 's/^/E2-IN rules: /'; iptables -S DOCKER-USER | sed -n 1,4p
echo "## host kernel log since the install began"
journalctl -k -b --no-pager -q --since "${SINCE:--20 min}" -o short-monotonic | grep -v -E 'audit|IN=|veth|docker0|br-' | cut -c1-200 | tail -25
echo "(end)"
journalctl -k -b --no-pager -q | grep -c -E 'BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode' | sed 's/^/kernel log lines matching the error patterns, this boot: /'
free -m | sed -n 2p; df -h / /data/cubelet | tail -2
