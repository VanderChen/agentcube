#!/usr/bin/env bash
# E1 step 00: confirm the VM is a PVM host before anything else. Read-only,
# except that it loads kvm-pvm when the module is not loaded yet.
set -euo pipefail

echo "## kernel"
uname -r
cat /proc/cmdline
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
[[ $(uname -r) == 6.8.0-139-generic ]] || { echo "not the PVM host kernel; enter it first (see E0/RECORD.md section 7)"; exit 1; }
grep -qw nokaslr /proc/cmdline || { echo "nokaslr is missing"; exit 1; }

echo "## PVM module"
if ! grep -q '^kvm_pvm ' /proc/modules; then
  echo "kvm_pvm not loaded; loading it"
  modprobe kvm-pvm
fi
lsmod | grep -E '^kvm'
modinfo -n kvm kvm-pvm
ls -l /dev/kvm
echo "tainted=$(cat /proc/sys/kernel/tainted)"

echo "## CPU"
grep -m1 -E '^model name' /proc/cpuinfo
grep -m1 -E '^address sizes' /proc/cpuinfo
grep -c -w la57 /proc/cpuinfo | sed 's/^/logical CPUs with la57: /'
nproc

echo "## resources"
free -m | sed -n 1,2p
df -h / | tail -1

echo "## fallback boot path"
awk '/^menuentry /{n++} n==1 && /^[[:space:]]*linux[[:space:]]/{print; exit}' /boot/grub/grub.cfg | sed 's/^[[:space:]]*/entry 0: /'
grub-editenv /boot/grub/grubenv list
echo "kexec_loaded=$(cat /sys/kernel/kexec_loaded)"

echo "## runtimes present before E1"
for t in docker containerd ctr runc kata-runtime containerd-shim-kata-v2 firecracker qemu-system-x86_64 cloud-hypervisor gcc make; do
  printf '%s: %s\n' "$t" "$(command -v "$t" || echo -)"
done
systemctl is-active docker containerd
docker ps -a --format '{{.Names}}' | wc -l | sed 's/^/docker containers: /'
ls -d /opt/kata /build/pvm 2>/dev/null || echo "no /opt/kata, no /build/pvm"
