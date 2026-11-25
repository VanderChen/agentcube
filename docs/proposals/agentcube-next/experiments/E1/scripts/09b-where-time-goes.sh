#!/usr/bin/env bash
# E1 step 09b: an observation, not a benchmark. Creating a sandbox took about
# 8 seconds with every hypervisor in step 09, while the direct Firecracker boot
# in step 06 had the agent ready about 2 seconds after start. For one sandbox
# per hypervisor, read the guest's own clock right after creation and the
# guest kernel log, to see how much of the time is spent inside the guest.
set -uo pipefail
NS=${NS:-e1}
IMAGE=${IMAGE:-docker.io/library/busybox:1.36}
CONF=${CONF:-/etc/kata-containers/pvm}
HYPERVISORS=${HYPERVISORS:-qemu dragonball clh}

for h in $HYPERVISORS; do
  id="time-$h"
  echo
  echo "=== $h ==="
  t0=$(date +%s%N)
  timeout 180 ctr -n "$NS" run -d --runtime io.containerd.kata.v2 --runtime-config-path "$CONF/configuration-$h-pvm.toml" \
    "$IMAGE" "$id" sleep 3600 2>&1 | cut -c1-300
  t1=$(date +%s%N)
  echo "host: create and start took $(( (t1 - t0) / 1000000 )) ms"
  timeout 60 ctr -n "$NS" task exec --exec-id probe "$id" sh -c '
    echo "guest: uptime when the first command ran: $(cut -d" " -f1 /proc/uptime) s"
    echo "guest: kernel log, selected lines:"
    dmesg | grep -E "Linux version|Run /sbin/init|Freeing unused kernel image \(initmem\)|systemd\[1\]: (Detected|Queued start job|Reached target|Started kata-agent)|EXT4-fs \(.*\): mounted|virtiofs|random: crng init done|clocksource: Switched|smp: Brought up|Memory: " | cut -c1-150 | head -24
    echo "guest: last kernel log line: $(dmesg | tail -1 | cut -c1-120)"
  ' 2>&1
  echo "host: shim log lines with their times (start of the VM, agent connection, container creation):"
  journalctl -t kata --since "-25 s" --no-pager -q -o short-precise 2>/dev/null | grep -F "$id" | sed -E 's/^[A-Za-z]+ [0-9]+ //; s/ localhost kata\[[0-9]+\]://' | cut -c1-150 | head -14
  ctr -n "$NS" task kill -s SIGKILL "$id" > /dev/null 2>&1
  for _ in $(seq 1 100); do
    st=$(ctr -n "$NS" task ls | awk -v id="$id" '$1==id {print $3}')
    [[ "$st" == STOPPED || -z "$st" ]] && break
    sleep 0.2
  done
  ctr -n "$NS" task rm "$id" > /dev/null 2>&1
  ctr -n "$NS" container rm "$id" > /dev/null 2>&1
done
echo
for _ in $(seq 1 150); do pgrep -f 'containerd-shim-kata' > /dev/null || break; sleep 0.2; done
pgrep -a -f 'containerd-shim-kata|qemu-system|cloud-hypervisor|virtiofsd' | cut -c1-120 || echo "no shim, VMM or virtiofsd process left"
