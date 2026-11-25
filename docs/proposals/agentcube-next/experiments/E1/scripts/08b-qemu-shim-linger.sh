#!/usr/bin/env bash
# E1 step 08b: step 08 marked QEMU as FAIL because the shim process was still
# there 5 seconds after the container was deleted. Find out whether it is a
# leak or a slow exit: look at the old shim, then repeat the QEMU case and
# watch for up to WATCH seconds after deletion.
set -uo pipefail
NS=${NS:-e1}
IMAGE=${IMAGE:-docker.io/library/busybox:1.36}
CONF=${CONF:-/etc/kata-containers/pvm}
WATCH=${WATCH:-90}
HYPERVISORS=${HYPERVISORS:-qemu}

echo "## the shim that was left by step 08 (kb1-qemu)"
pgrep -a -f 'containerd-shim-kata-v2 -id kb1-qemu' | cut -c1-160 || echo "gone now"
pgrep -a -f 'qemu-system|virtiofsd|cloud-hypervisor' | cut -c1-120 || echo "no VMM or virtiofsd process"
ls /run/kata 2>/dev/null | sed 's/^/\/run\/kata: /'; ls /run/kata-containers/shared/sandboxes 2>/dev/null | sed 's/^/shared sandboxes: /'
ctr -n "$NS" container ls -q | sed 's/^/container record: /'
ctr -n "$NS" task ls | tail -n +2 | sed 's/^/task: /'

for h in $HYPERVISORS; do
  id="linger-$h"
  echo
  echo "=== $h: create, exec, delete, then watch the processes for up to $WATCH s ==="
  timeout 180 ctr -n "$NS" run -d --runtime io.containerd.kata.v2 --runtime-config-path "$CONF/configuration-$h-pvm.toml" \
    "$IMAGE" "$id" sleep 3600 2>&1 | cut -c1-300
  timeout 60 ctr -n "$NS" task exec --exec-id probe "$id" uname -r
  echo "processes before deletion:"; pgrep -a -f "$id" | cut -c1-110
  t0=$(date +%s%N)
  ctr -n "$NS" task kill -s SIGKILL "$id" 2>&1 | cut -c1-200
  for _ in $(seq 1 100); do
    st=$(ctr -n "$NS" task ls | awk -v id="$id" '$1==id {print $3}')
    [[ "$st" == STOPPED || -z "$st" ]] && break
    sleep 0.2
  done
  ctr -n "$NS" task rm "$id" 2>&1 | cut -c1-200
  ctr -n "$NS" container rm "$id" 2>&1 | cut -c1-200
  echo "deleted after $(( ($(date +%s%N) - t0) / 1000000 )) ms"
  gone=""
  last=""
  for _ in $(seq 1 $((WATCH * 2))); do
    now=$(pgrep -f "$id" | while read -r p; do ps -o comm= -p "$p"; done | sort | uniq -c | tr -s ' \n' ' ')
    if [[ "$now" != "$last" ]]; then
      echo "+$(( ($(date +%s%N) - t0) / 1000000 )) ms: ${now:-no process left}"
      last=$now
    fi
    [[ -z "$now" ]] && { gone=yes; break; }
    sleep 0.5
  done
  [[ -n "$gone" ]] || { echo "still present after $WATCH s:"; pgrep -a -f "$id" | cut -c1-160; }
  ls -d "/run/kata/$id" "/run/kata-containers/shared/sandboxes/$id" 2>/dev/null | sed 's/^/left on disk: /' || true
  journalctl -u containerd --since "-3 min" --no-pager -q -o cat | grep -F "$id" | tail -6 | cut -c1-260
done
