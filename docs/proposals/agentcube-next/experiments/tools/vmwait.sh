#!/usr/bin/env bash
# Wait for the experiment VM to answer on a NEW ssh connection (after a reboot),
# and record what came back.
#
#   tools/vmwait.sh <experiment> <label>
#
# INITIAL: seconds to wait before the first try (default 20).
# TRIES: number of tries, 8 s apart, each with an 8 s connect timeout (default 45).
set -uo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <experiment> <label>" >&2; exit 2; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dir="$here/../$1" label=$2
host=${VM_HOST:-cpu}
started=$(date -u +%FT%TZ)
sleep "${INITIAL:-20}"
result="NOT REACHABLE after ${TRIES:-45} tries"; rc=1
for i in $(seq 1 "${TRIES:-45}"); do
  if out=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlMaster=no -o ControlPath=none "$host" \
      'echo "kernel=$(uname -r) boot_id=$(cat /proc/sys/kernel/random/boot_id) up_since=$(uptime -s | tr " " T)"' 2>/dev/null); then
    result="reachable on try $i at $(date -u +%FT%TZ): $out"; rc=0; break
  fi
  sleep 8
done
printf '# %s | wait %s\n%s\n\n' "$started" "$label" "$result" | tee -a "$dir/log-$label.txt"
printf '%s | wait %s | tools/vmwait.sh | %s | exit=%s | log-%s.txt\n' "$started" "$label" "$result" "$rc" "$label" >> "$dir/commands-as-run.txt"
exit "$rc"
