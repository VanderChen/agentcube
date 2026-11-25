#!/usr/bin/env bash
# E1 step 10: read-only. State of the VM at the end of E1 and what E1 added.
set -uo pipefail
echo "## kernel and PVM"
uname -r; cat /proc/cmdline
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"; uptime -s
lsmod | grep -E '^(kvm|vhost|vsock|vmw_vsock)' ; ls -l /dev/kvm
echo "tainted=$(cat /proc/sys/kernel/tainted)"
echo "## host kernel log of this boot"
echo "error level and above:"; journalctl -k -b -p err --no-pager -q | cut -c1-200 | tail -10; echo "(end)"
echo "lines matching BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode: $(journalctl -k -b --no-pager -q | grep -c -E 'BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode')"
echo "kvm lines, grouped:"
journalctl -k -b --no-pager -q -o cat | grep -E '^kvm' | sed -E 's/\[[0-9]+\]/[pid]/; s/vcpu[0-9]+/vcpuN/' | sort | uniq -c | cut -c1-200
echo "## boot configuration"
awk '/^menuentry /{n++} n==1 && /^[[:space:]]*linux[[:space:]]/{print; exit}' /boot/grub/grub.cfg | sed 's/^[[:space:]]*/entry 0: /'
grep -E '^GRUB_DEFAULT=' /etc/default/grub; grub-editenv /boot/grub/grubenv list; echo "kexec_loaded=$(cat /sys/kernel/kexec_loaded)"
apt-mark showhold | tr '\n' ' '; echo
echo "## what E1 added"
cat /opt/kata/VERSION; du -sh /opt/kata /build/pvm /build/pvm/* 2>/dev/null
ls -l /etc/kata-containers/pvm | awk 'NR>1 {print $5, $9}'
for f in containerd-shim-kata-v2 firecracker; do printf '%s -> %s\n' "/usr/local/bin/$f" "$(readlink -f /usr/local/bin/$f)"; done
sha256sum /opt/kata/share/kata-containers/vmlinux.pvm /usr/local/bin/firecracker /build/pvm/cache/* | cut -c1-150
echo "apt transactions of 2026-11-25 (command lines):"
grep -E '^(Start-Date: 2026-11-25|Commandline)' /var/log/apt/history.log | cut -c1-200
echo "## containerd"
ctr namespaces ls
for ns in $(ctr namespaces ls -q); do
  echo "namespace $ns: containers=$(ctr -n "$ns" container ls -q | wc -l) tasks=$(ctr -n "$ns" task ls | tail -n +2 | wc -l) images=$(ctr -n "$ns" image ls -q | wc -l) snapshots=$(ctr -n "$ns" snapshot ls | tail -n +2 | wc -l)"
done
ctr -n e1 image ls -q
echo "## leftovers"
pgrep -a -f 'containerd-shim-kata|qemu-system|cloud-hypervisor|virtiofsd|firecracker' | cut -c1-120 || echo "no shim, VMM, virtiofsd or firecracker process"
ls /run/kata 2>/dev/null | sed 's/^/\/run\/kata\/: /'
ls /run/kata-containers/shared/sandboxes 2>/dev/null | sed 's/^/\/run\/kata-containers\/shared\/sandboxes\/: /'
ls /sys/fs/cgroup/e1 2>/dev/null | grep -v -E '^(cgroup|cpu|memory|io|pids|hugetlb|rdma|misc|cpuset)\.' | sed 's/^/cgroup \/e1\/: /'
ls /sys/fs/cgroup/default 2>/dev/null | grep -v -E '^(cgroup|cpu|memory|io|pids|hugetlb|rdma|misc|cpuset)\.' | sed 's/^/cgroup \/default\/: /'
echo "containerd 'might be leaked' errors today: $(journalctl -u containerd --since today --no-pager -q -o cat | grep -c -F 'might be leaked')"
echo "## services and resources"
systemctl is-active docker containerd ssh; systemctl --failed --no-legend | cut -c1-120; echo "(end failed units)"
docker ps -a --format '{{.Names}}' | wc -l | sed 's/^/docker containers: /'
free -m | sed -n 2p; df -h / | tail -1
