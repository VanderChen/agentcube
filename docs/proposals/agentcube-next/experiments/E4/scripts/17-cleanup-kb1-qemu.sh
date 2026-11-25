#!/usr/bin/env bash
# E4 step 17: remove what the failed QEMU run of step 08 left in containerd.
# The review of the E4 record found one container record in namespace e1
# (kb1-qemu) in the final state. A later KB-1 run with QEMU would fail on the
# name. Nothing else is touched; a task that still exists is left alone.
set -uo pipefail
NS=${NS:-e1}
ID=${ID:-kb1-qemu}
show() {
  echo "containers in $NS: $(ctr -n "$NS" containers ls -q | tr '\n' ' ')"
  echo "tasks in $NS: $(ctr -n "$NS" tasks ls -q | tr '\n' ' ')"
  echo "snapshots in $NS: $(ctr -n "$NS" snapshots ls | awk 'NR>1 {print $1}' | tr '\n' ' ')"
  echo "shim processes for $ID: $(pgrep -f "containerd-shim-kata-v2.*-id $ID" | wc -l)"
  for p in "/run/kata/$ID" "/run/kata-containers/shared/sandboxes/$ID" "/sys/fs/cgroup/$NS/$ID" \
           "/run/containerd/io.containerd.runtime.v2.task/$NS/$ID"; do
    if [[ -e "$p" ]]; then echo "exists: $p"; else echo "absent: $p"; fi
  done
}
echo "kernel: $(uname -r), up since $(uptime -s)"
echo "## before"
show
echo "## remove"
if ctr -n "$NS" tasks ls -q | grep -qx "$ID"; then echo "a task still exists for $ID; not touching it"; exit 1; fi
if ctr -n "$NS" containers ls -q | grep -qx "$ID"; then
  ctr -n "$NS" containers rm "$ID"; echo "containers rm exit=$?"
else
  echo "no container record named $ID"
fi
if ctr -n "$NS" snapshots ls | awk 'NR>1 {print $1}' | grep -qx "$ID"; then
  ctr -n "$NS" snapshots rm "$ID"; echo "snapshots rm exit=$?"
else
  echo "no snapshot named $ID"
fi
echo "## after"
show
left=$(ctr -n "$NS" containers ls -q | grep -cx "$ID" || true)
[[ "$left" == 0 ]]
