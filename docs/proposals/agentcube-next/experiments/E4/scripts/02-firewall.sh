#!/usr/bin/env bash
# E2 step 02: the VM has a public address and CubeSandbox opens ports without
# authentication (API, proxy, web UI, MySQL, Redis). For the time of the
# experiment, drop new inbound connections on the uplink except ssh.
# The rules are not saved anywhere; a reboot removes them.
#
#   MODE=apply | remove | status
#
# Not covered: CubeSandbox maps sandbox ports to host ports on the uplink with
# eBPF at the tc layer, which runs before these rules. See PLAN.md.
set -euo pipefail
MODE=${MODE:-status}
IF=${UPLINK:-eth0}
incomplete=""

apply_one() {
  local ipt=$1 icmp=$2 dhcp=$3
  $ipt -N E2-IN 2>/dev/null || $ipt -F E2-IN
  $ipt -A E2-IN -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  $ipt -A E2-IN -p tcp --dport 22 -j RETURN
  $ipt -A E2-IN -p "$icmp" -j RETURN
  $ipt -A E2-IN -p udp --dport "$dhcp" -j RETURN
  $ipt -A E2-IN -j DROP
  $ipt -C INPUT -i "$IF" -j E2-IN 2>/dev/null || $ipt -I INPUT 1 -i "$IF" -j E2-IN
  # Ports published by Docker are forwarded, not delivered to INPUT.
  if $ipt -S DOCKER-USER > /dev/null 2>&1; then
    $ipt -C DOCKER-USER -i "$IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null ||
      $ipt -I DOCKER-USER 1 -i "$IF" -m conntrack --ctstate NEW -j DROP
  elif [[ $ipt == iptables* ]] && command -v docker > /dev/null 2>&1; then
    # Docker creates this chain when it starts. In E3 the rules were applied
    # before Docker was started, this rule was skipped without a word, and
    # the ports Docker published were open until the script was run again.
    echo "DOCKER-USER does not exist: start Docker first, then apply again. Ports published by Docker are NOT covered." >&2
    incomplete=1
  fi
}
remove_one() {
  local ipt=$1
  while $ipt -D INPUT -i "$IF" -j E2-IN 2>/dev/null; do :; done
  while $ipt -D DOCKER-USER -i "$IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null; do :; done
  $ipt -F E2-IN 2>/dev/null || true
  $ipt -X E2-IN 2>/dev/null || true
}

case "$MODE" in
  apply)  apply_one "iptables -w 10" icmp 68; apply_one "ip6tables -w 10" ipv6-icmp 546; echo "applied at $(date -u +%FT%TZ)${incomplete:+ (INCOMPLETE)}" ;;
  remove) remove_one "iptables -w 10"; remove_one "ip6tables -w 10"; echo "removed at $(date -u +%FT%TZ)" ;;
  status) ;;
  *) echo "MODE must be apply, remove or status" >&2; exit 2 ;;
esac
for ipt in iptables ip6tables; do
  echo "## $ipt"
  $ipt -S INPUT | cut -c1-140
  $ipt -S E2-IN 2>/dev/null | cut -c1-140 || echo "no E2-IN chain"
  $ipt -S DOCKER-USER 2>/dev/null | cut -c1-140 || echo "no DOCKER-USER chain"
done
echo "## sockets listening on something other than loopback (address:port and process)"
ss -H -lntup | awk '{print $1, $5, $7}' | grep -v -E ' (127\.[0-9.]+(%[a-z0-9]+)?|\[::1\]):' | sed -E 's/users:\(\("([^"]+)".*/\1/' | sort -u |
  sed -E 's/ ([0-9]{1,3}\.){3}[0-9]{1,3}(%[a-z0-9]+)?:/ <v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | cut -c1-100
[[ -z "$incomplete" ]] || exit 3
