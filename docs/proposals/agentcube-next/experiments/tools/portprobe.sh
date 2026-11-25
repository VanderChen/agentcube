#!/usr/bin/env bash
# From this machine, try to open TCP connections to the experiment VM's
# address, to see which ports are reachable from outside. The address is read
# from the ssh configuration at run time and is not printed or stored.
#
#   tools/portprobe.sh <experiment> <label> <port>...
set -uo pipefail
[[ $# -ge 3 ]] || { echo "usage: $0 <experiment> <label> <port>..." >&2; exit 2; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dir="$here/../$1" label=$2; shift 2
addr=$(ssh -G "${VM_HOST:-cpu}" | awk '$1 == "hostname" {print $2}')
started=$(date -u +%FT%TZ)
{
  printf '# %s | port probe %s | from the development machine to the VM (address not shown)\n' "$started" "$label"
  for port in "$@"; do
    if timeout 5 bash -c "exec 3<>/dev/tcp/$addr/$port" 2> /dev/null; then echo "tcp/$port: OPEN"; else echo "tcp/$port: closed or filtered"; fi
  done
  echo
} | tee -a "$dir/log-$label.txt"
printf '%s | port probe %s | tools/portprobe.sh %s | log-%s.txt\n' "$started" "$label" "$*" "$label" >> "$dir/commands-as-run.txt"
