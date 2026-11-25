#!/usr/bin/env bash
# Run one script of an experiment on the experiment VM and keep the audit trail.
#
#   tools/vmrun.sh <experiment> <step> <script> [KEY=VALUE ...]
#
# - <script> is a file under <experiment>/scripts/. It is copied to the VM as
#   /root/exp/<experiment>/scripts/<script> and run there with bash as root.
# - Output (stdout and stderr) is appended to <experiment>/log-<step>.txt.
# - One line per run is appended to <experiment>/commands-as-run.txt: UTC time,
#   step, script, sha256 of the script as run, extra environment, exit code.
# - The script as run is kept under <experiment>/scripts-as-run/<sha8>-<script>.
# - The addresses of the VM's uplink and of this machine as seen by the VM are
#   replaced in the output before it is written. They are read at run time and
#   never stored.
#
# VM_HOST selects the ssh host alias (default: cpu).
set -uo pipefail

[[ $# -ge 3 ]] || { echo "usage: $0 <experiment> <step> <script> [KEY=VALUE ...]" >&2; exit 2; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exp=$1 step=$2 script=$3
shift 3
dir="$here/../$exp"
src="$dir/scripts/$script"
[[ -f "$src" ]] || { echo "no such script: $src" >&2; exit 2; }
for kv in "$@"; do
  [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "not KEY=VALUE: $kv" >&2; exit 2; }
done

host=${VM_HOST:-cpu}
# ControlMaster/ControlPath: every invocation must be a new TCP connection, so that a
# successful run is also proof that new ssh connections still get through.
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o ControlMaster=no -o ControlPath=none)
remote_dir="/root/exp/$exp/scripts"
log="$dir/log-$step.txt"
sha=$(sha256sum "$src" | cut -c1-64)
started=$(date -u +%FT%TZ)
# Keep every version of a script that was actually run, so that a later edit
# does not erase what an earlier run executed.
install -d -m 0755 "$dir/scripts-as-run"
[[ -e "$dir/scripts-as-run/${sha:0:8}-$script" ]] || cp "$src" "$dir/scripts-as-run/${sha:0:8}-$script"

redact=$(ssh "${ssh_opts[@]}" "$host" \
  'ip -o addr show dev eth0 scope global 2>/dev/null | awk "{print \$4}" | cut -d/ -f1; echo "${SSH_CLIENT%% *}"' 2>/dev/null |
  awk 'NF { gsub(/[.]/, "[.]"); printf "s/%s/<address redacted>/g;", $0 }')
[[ -n "$redact" ]] || { echo "cannot reach $host" >&2; exit 1; }

ssh "${ssh_opts[@]}" "$host" "mkdir -p '$remote_dir' && cat > '$remote_dir/$script' && chmod 0755 '$remote_dir/$script'" < "$src" ||
  { echo "cannot copy script to $host" >&2; exit 1; }

envs=""
for kv in "$@"; do envs+="$(printf '%q ' "$kv")"; done
rc_file=$(mktemp)
{
  printf '# %s | step %s | scripts/%s | sha256 %s | env: %s\n' "$started" "$step" "$script" "$sha" "$*"
  ssh "${ssh_opts[@]}" "$host" "env $envs bash '$remote_dir/$script'" < /dev/null 2>&1
  rc=$?
  echo "$rc" > "$rc_file"
  printf '# exit=%s | %s\n\n' "$rc" "$(date -u +%FT%TZ)"
} | sed -u -E "$redact" | tee -a "$log"
rc=$(cat "$rc_file"); rm -f "$rc_file"
printf '%s | step %s | scripts/%s | sha256 %s | env: %s | exit=%s | log-%s.txt\n' \
  "$started" "$step" "$script" "$sha" "$*" "$rc" "$step" >> "$dir/commands-as-run.txt"
exit "$rc"
