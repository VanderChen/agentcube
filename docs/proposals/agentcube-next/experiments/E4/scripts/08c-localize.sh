#!/usr/bin/env bash
# E2 step 08c: localize the failure of step 08 (the VM reset as soon as its
# vCPU started). Two guest kernels, each booted directly by two VMMs that are
# known to work on this host from E1, without CubeSandbox or Kata in between:
#
#   guest kernels: CubeSandbox's vmlinux-pvm (6.6.117, OpenCloudOS PVM guest)
#                  the PVM project's 6.12.33 guest built in E1 (control: boots)
#   VMMs:          upstream Cloud Hypervisor (the one Kata 4.2.0 ships; CubeSandbox's VMM is a fork of it)
#                  Firecracker 1.17.0
#
# No root disk is given to Cloud Hypervisor, so a kernel that boots ends in
# "unable to mount root" and resets after that; a kernel that cannot run under
# this host's PVM resets at once without printing anything.
# Only CubeSandbox's own VMM cannot be run this way: it is built into its shim.
set -uo pipefail
W=/root/e2/localize
install -d -m 0755 "$W"
CUBE_K=/usr/local/services/cubetoolbox/cube-kernel-scf/vmlinux-pvm
PVM_K=/opt/kata/share/kata-containers/vmlinux.pvm
CLH=/opt/kata/bin/cloud-hypervisor
ROOTFS=$(readlink -f /opt/kata/share/kata-containers/kata-containers.img)
klines() { journalctl -k -b --no-pager -q | wc -l; }
show() { # name
  local n=$1
  for c in ttyS0 hvc0; do
    local f="$W/$n.$c"
    if [[ -s "$f" ]]; then
      echo "  console $c: $(wc -l < "$f") lines"
      grep -a -m1 -E 'Linux version' "$f" | cut -c1-150 | sed 's/^/    first: /'
      grep -a -E 'Hypervisor detected|Booting paravirtualized|PVM|pvm|Kernel panic|VFS: (Cannot|Unable)|Run /sbin/init|systemd\[1\]: Detected|Reached target' "$f" | cut -c1-150 | sed -n '1,8p' | sed 's/^/    /'
      echo "    last: $(tail -n 1 "$f" | tr -d '\r' | cut -c1-150)"
    else
      echo "  console $c: empty"
    fi
  done
}

for pair in "cube-guest:$CUBE_K" "pvm-guest:$PVM_K"; do
  name=clh-${pair%%:*}; kernel=${pair#*:}
  echo "=== upstream Cloud Hypervisor $($CLH --version | awk '{print $2}') + $kernel ==="
  rm -f "$W/$name".*
  before=$(klines); t0=$(date +%s%N)
  timeout -s KILL 30 "$CLH" --kernel "$kernel" \
    --cmdline "console=hvc0 console=ttyS0 earlyprintk=ttyS0 reboot=k panic=1" \
    --cpus boot=1,max_phys_bits=46 --memory size=512M \
    --serial "file=$W/$name.ttyS0" --console "file=$W/$name.hvc0" \
    --log-file "$W/$name.log" -v > "$W/$name.out" 2>&1 < /dev/null
  rc=$?
  echo "  exit=$rc after $(( ($(date +%s%N) - t0) / 1000000 )) ms"
  show "$name"
  echo "  VMM log, exits and errors:"
  grep -a -i -E 'reset|shutdown|error|exit|fault|panic' "$W/$name.log" "$W/$name.out" 2> /dev/null | sed -E 's/^[^:]+://' | cut -c1-200 | sed -n '1,8p' | sed 's/^/    /'
  echo "  host kernel log lines added:"
  journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | cut -c1-200 | sed -n '1,6p' | sed 's/^/    /'
done

for pair in "cube-guest:$CUBE_K" "pvm-guest:$PVM_K"; do
  name=fc-${pair%%:*}; kernel=${pair#*:}
  echo "=== Firecracker $(firecracker --version | sed -n 1p | awk '{print $2}') + $kernel ==="
  rm -f "$W/$name".*
  cat > "$W/$name.json" <<JSON
{
  "boot-source": {"kernel_image_path": "$kernel",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda1 ro rootfstype=ext4 systemd.unit=kata-containers.target"},
  "drives": [{"drive_id": "rootfs", "path_on_host": "$ROOTFS", "is_root_device": false, "is_read_only": true}],
  "machine-config": {"vcpu_count": 1, "mem_size_mib": 512, "smt": false, "track_dirty_pages": false}
}
JSON
  before=$(klines); t0=$(date +%s%N)
  timeout -s KILL 20 firecracker --no-api --config-file "$W/$name.json" > "$W/$name.ttyS0" 2>&1 < /dev/null
  rc=$?
  echo "  exit=$rc after $(( ($(date +%s%N) - t0) / 1000000 )) ms (137 means it was still running when the 20 s limit stopped it)"
  : > "$W/$name.hvc0"
  show "$name"
  echo "  Firecracker's own lines about the vCPU or an exit:"
  grep -a -E 'exit|Exit|reset|Reset|shutdown|Shutdown|error|Error|fault' "$W/$name.ttyS0" | grep -v -E '^\[ +[0-9.]+\]' | cut -c1-200 | sed -n '1,6p' | sed 's/^/    /'
  echo "  host kernel log lines added:"
  journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | cut -c1-200 | sed -n '1,6p' | sed 's/^/    /'
done
echo
echo "## the two guest kernels"
for k in "$CUBE_K" "$PVM_K"; do
  echo "$k"
  strings "$k" | grep -m1 -E '^Linux version ' | cut -c1-140 | sed 's/^/  /'
  sha256sum "$k" | cut -c1-64 | sed 's/^/  sha256 /'
  readelf -h "$k" 2> /dev/null | grep -E 'Entry point|Type:' | sed -E 's/^ +/  /'
  readelf -lW "$k" 2> /dev/null | awk '$1=="LOAD" {print "  LOAD vaddr=" $3, "paddr=" $4, "memsz=" $6}' | sed -n '1,4p'
  readelf -n "$k" 2> /dev/null | grep -c -i -E 'Xen|PVH' | sed 's/^/  ELF notes mentioning Xen or PVH: /'
done
pgrep -a -f 'cloud-hypervisor|firecracker' | cut -c1-100 || echo "no VMM process left"
echo "tainted=$(cat /proc/sys/kernel/tainted)"
