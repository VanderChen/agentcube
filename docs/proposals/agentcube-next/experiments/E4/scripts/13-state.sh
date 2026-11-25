#!/usr/bin/env bash
# E3 step 13: read-only. State of the VM at the end of E1 to E3.
set -uo pipefail
S=/etc/systemd/system
echo "## kernel and PVM"
uname -r; cat /proc/cmdline; echo "boot_id=$(cat /proc/sys/kernel/random/boot_id) up_since=$(uptime -s)"
lsmod | grep -E '^kvm'; modinfo -n kvm_pvm; ls -l /dev/kvm; echo "tainted=$(cat /proc/sys/kernel/tainted)"
echo "## boot configuration"
grep -E '^GRUB_(DEFAULT|CMDLINE_LINUX)=' /etc/default/grub | cut -c1-180
grep -m1 'set default="gnulinux' /boot/grub/grub.cfg | sed 's/^[[:space:]]*//' | cut -c1-170
grep -o "menuentry_id_option '[^']*'" /boot/grub/grub.cfg | sed "s/menuentry_id_option //" | tr '\n' ' '; echo
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"; echo "kexec_loaded=$(cat /sys/kernel/kexec_loaded)"
ls /boot | grep -E '^vmlinuz-' | tr '\n' ' '; echo; ls -l /boot/vmlinuz /boot/vmlinuz.old 2> /dev/null | awk '{print $9, $10, $11}'
apt-mark showhold | tr '\n' ' '; echo
dpkg -l 'linux-image*' | awk '/^[hi]i/ {print $1, $2, $3}'
echo "## guard"
ls "$S"/*/10-e2-guard.conf 2> /dev/null || echo "no guard files"
echo "this boot: $(ls /run/e2-allow 2> /dev/null || echo 'not allowed (no /run/e2-allow)')"
for u in docker.service docker.socket cube-sandbox-control.target cube-sandbox-cubelet.service cube-sandbox-cube-templatecenter.service cube-sandbox-logrotate.timer; do
  printf '%s: enabled=%s active=%s guarded=%s\n' "$u" "$(systemctl is-enabled "$u" 2> /dev/null | sed -n 1p)" "$(systemctl is-active "$u" 2> /dev/null | sed -n 1p)" \
    "$(systemctl show -p DropInPaths --value "$u" | grep -q 10-e2-guard.conf && echo yes || echo no)"
done
echo "cube-sandbox units active: $(systemctl list-units 'cube-sandbox*' --no-legend --no-pager | grep -c ' active ')"
systemctl list-timers 'e2-deadman-*' --all --no-legend --no-pager | grep -c e2-deadman | sed 's/^/dead-man timers: /'
cat /root/exp/E2/deadman.log 2> /dev/null | sed 's/^/deadman.log: /' || true; [[ -s /root/exp/E2/deadman.log ]] || echo "the dead-man action never ran"
echo "## network"
echo "tc filters on eth0: ingress $(tc filter show dev eth0 ingress 2> /dev/null | grep -c bpf), egress $(tc filter show dev eth0 egress 2> /dev/null | grep -c bpf); qdiscs: $(tc qdisc show dev eth0 | awk '{print $2}' | sort | uniq -c | tr -s ' \n' ' ')"
ip -br link | awk '{print $1, $2}' | tr '\n' ';'; echo
echo "E2-IN chain rules: iptables $(iptables -S E2-IN 2> /dev/null | wc -l), ip6tables $(ip6tables -S E2-IN 2> /dev/null | wc -l)"
resolvectl status 2> /dev/null | grep -c 'cube.app' | sed 's/^/resolver entries for cube.app: /'
getent ahostsv4 github.com > /dev/null && echo "ordinary DNS works" || echo "ordinary DNS is BROKEN"
echo "listening, not loopback:"; ss -H -lntup | awk '{print $1, $5, $7}' | grep -v -E ' (127\.[0-9.]+(%[a-z0-9]+)?|\[::1\]):' | sed -E 's/users:\(\("([^"]+)".*/\1/; s/ ([0-9]{1,3}\.){3}[0-9]{1,3}(%[a-z0-9]+)?:/ <v4>:/; s/\[[0-9a-f:]+\]/[<v6>]/' | sort -u
echo "## Docker and containerd"
systemctl is-active docker containerd | tr '\n' ' '; echo
docker ps -a --format '{{.Names}} | {{.Status}} | restart={{.Label "none"}}' 2> /dev/null | cut -c1-100
for c in $(docker ps -a --format '{{.Names}}' 2> /dev/null); do printf '%s restart=%s\n' "$c" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")"; done
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' 2> /dev/null | sort | cut -c1-120
for ns in $(ctr namespaces ls -q); do echo "containerd namespace $ns: containers=$(ctr -n "$ns" container ls -q | wc -l) images=$(ctr -n "$ns" image ls -q | wc -l)"; done
echo "## what the experiments left on disk"
du -sh /opt/kata /build/pvm /usr/local/services/cubetoolbox /data/log /var/lib/e2 /root/e0 /root/e2 /root/e3 /root/exp /etc/kata-containers /etc/cube /etc/cube-sandbox 2> /dev/null
ls -ls /var/lib/e2/cubelet.xfs | awk '{print "sparse XFS file: allocated", $1, "KiB"}'
mountpoint -q /data/cubelet && echo "/data/cubelet: mounted" || echo "/data/cubelet: not mounted"
ls /usr/local/bin | tr '\n' ' '; echo
ls "$S" | grep -E 'cube|e2|docker' | tr '\n' ' '; echo
grep -E '^(Start-Date: 2026-11-25|Commandline)' /var/log/apt/history.log | cut -c1-170
grep -E '^2026-11-25 .* (install|remove|purge) ' /var/log/dpkg.log | awk '{print $3}' | sort | uniq -c | tr -s ' \n' ' '; echo
echo "## health"
systemctl --failed --no-legend --no-pager | cut -c1-120; echo "(end failed units)"
journalctl -k -b --no-pager -q | grep -c -E 'BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode' | sed 's/^/kernel log lines matching the error patterns, this boot: /'
free -m | sed -n 2p; df -h / | tail -1
