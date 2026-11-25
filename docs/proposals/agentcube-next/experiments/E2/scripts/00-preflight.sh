#!/usr/bin/env bash
# E2 step 00: read-only. What the CubeSandbox one-click installer will meet on this VM.
set -uo pipefail
echo "## PVM host"
uname -r; grep -q '^kvm_pvm ' /proc/modules && echo "kvm_pvm loaded" || echo "kvm_pvm NOT loaded"; ls -l /dev/kvm
echo "## installer preflight items"
echo "glibc: $(ldd --version 2>&1 | sed -n 1p)"
echo "memory kB: $(awk '/MemTotal/ {print $2}' /proc/meminfo)"
echo "filesystem under /data/cubelet: $(df -T / | awk 'NR==2 {print $2}') (the installer requires xfs)"
ls -d /data /data/cubelet 2>&1 | sed 's/^/  /'
command -v mkfs.xfs || echo "mkfs.xfs: not installed"
echo "cgroup: $(stat -fc %T /sys/fs/cgroup); controllers: $(cat /sys/fs/cgroup/cgroup.controllers); subtree_control: $(cat /sys/fs/cgroup/cgroup.subtree_control)"
systemctl is-active multipathd.service multipathd.socket 2>&1 | tr '\n' ' ' | sed 's/^/multipathd service, socket: /'; echo
echo "bpffs: $(df -T /sys/fs/bpf 2>/dev/null | awk 'NR==2 {print $2}')"
ls -la /sys/kernel/btf/vmlinux | awk '{print "BTF:", $5, $9}'
docker --version; docker compose version 2>&1 | sed -n 1p; command -v docker-compose || echo "docker-compose: not installed"
cat /etc/docker/daemon.json 2>/dev/null || echo "no /etc/docker/daemon.json"
echo "## DNS on the host"
command -v resolvectl; systemctl is-active systemd-resolved
ls -l /etc/resolv.conf | awk '{print $9, $10, $11}'
resolvectl status 2>/dev/null | grep -E 'Link|Current Scopes|DNS Domain|resolv.conf mode' | sed -E 's/(DNS Servers?:).*/\1 <not shown>/' | cut -c1-120
echo "## network"
ip -br link | awk '{print $1, $2}'
ip -4 route | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<v4>/g' | cut -c1-120
ip -4 addr show scope global | grep -c inet | sed 's/^/global IPv4 addresses: /'
ip -4 addr show | grep -E '192\.168\.' || echo "no 192.168.x.x address on the host (the default CubeSandbox network is 192.168.0.0/18)"
tc qdisc show dev eth0 | cut -c1-120
tc filter show dev eth0 ingress 2>/dev/null | wc -l | sed 's/^/tc ingress filter lines on eth0: /'
echo "## sockets listening now (address:port and process)"
ss -H -lntup | awk '{print $1, $5, $7}' | sed -E 's/users:\(\("([^"]+)".*/\1/' | sort -u | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}%?[a-z0-9]*:/<v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | cut -c1-100
echo "## firewall now"
iptables -S | sed -n '1,30p' | cut -c1-140
iptables -S | wc -l | sed 's/^/iptables filter rules: /'
ip6tables -S | wc -l | sed 's/^/ip6tables filter rules: /'
lsmod | grep -E '^(nf_conntrack|ip6_tables|ip_tables|nf_tables|xt_conntrack) ' | awk '{print $1}' | tr '\n' ' '; echo
dpkg -l iptables-persistent netfilter-persistent 2>/dev/null | grep -E '^ii' || echo "no persistent firewall package"
echo "## how the uplink is configured"
ls /etc/systemd/network/ /etc/netplan/ 2>/dev/null
grep -h -E '^(DHCP|Address|Gateway|IPv6AcceptRA)' /etc/systemd/network/*.network 2>/dev/null | sed -E 's/=.*[0-9a-f:.]{6,}.*/=<address>/' | sort | uniq -c
echo "## registries the installer and the tests pull from"
for u in https://cube-sandbox-image.tencentcloudcr.com/v2/ https://cube-sandbox-int.tencentcloudcr.com/v2/ https://github.com/TencentCloud/CubeSandbox/releases/download/v0.8.0/cube-sandbox-one-click-v0.8.0-amd64.tar.gz https://astral.sh/uv/install.sh https://pypi.org/simple/e2b-code-interpreter/; do
  printf '%s -> ' "$u"; curl -s -o /dev/null -m 15 -I -L -w '%{http_code}\n' "$u"
done
echo "## existing CubeSandbox bits"
ls -d /usr/local/services/cubetoolbox /etc/cube 2>&1 | sed 's/^/  /'
systemctl list-unit-files 'cube-sandbox*' --no-legend | wc -l | sed 's/^/cube-sandbox unit files: /'
df -h / | tail -1; free -m | sed -n 2p
