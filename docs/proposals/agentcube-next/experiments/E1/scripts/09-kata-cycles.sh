#!/usr/bin/env bash
# E1 step 09: create, execute, delete, repeated for each hypervisor.
# The times are observations on one machine, not a benchmark.
#
# A cycle passes when the container starts, the command runs in a sandbox with
# the expected kernel, the container and task records are removed, and every
# process of the sandbox is gone within LINGER seconds of the deletion. Step 08
# saw a shim outlive the deletion by more than 5 seconds once, so the time until
# the processes are gone is recorded, and containerd's "might be leaked" errors
# are counted per hypervisor.
set -uo pipefail
NS=${NS:-e1}
IMAGE=${IMAGE:-docker.io/library/busybox:1.36}
CONF=${CONF:-/etc/kata-containers/pvm}
HYPERVISORS=${HYPERVISORS:-qemu dragonball clh}
CYCLES=${CYCLES:-10}
LINGER=${LINGER:-60}
BAD='BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode'
ms() { echo $(( ($2 - $1) / 1000000 )); }

ctr -n "$NS" image ls -q | grep -qx "$IMAGE" || ctr -n "$NS" image pull "$IMAGE" > /dev/null
echo "host kernel: $(uname -r); cycles per hypervisor: $CYCLES"
expected=$(cat /opt/kata/share/kata-containers/vmlinux.pvm.uname)
echo "expected kernel in the sandbox: $expected"

overall=0
for h in $HYPERVISORS; do
  cfg="$CONF/configuration-$h-pvm.toml"
  echo
  echo "=== $h ==="
  before=$(journalctl -k -b --no-pager -q | wc -l)
  started=$(date '+%Y-%m-%d %H:%M:%S')
  pass=0
  creates=()
  echo "cycle | create_ms | exec_ms | delete_ms | processes_gone_ms | kernel in sandbox | result"
  for i in $(seq 1 "$CYCLES"); do
    id="cyc-$h-$i"
    result=PASS; note=""
    t0=$(date +%s%N)
    if ! timeout 180 ctr -n "$NS" run -d --runtime io.containerd.kata.v2 --runtime-config-path "$cfg" \
        "$IMAGE" "$id" sleep 3600 > /tmp/e1-run.out 2>&1; then
      result=FAIL; note="create: $(tr '\n' ' ' < /tmp/e1-run.out | cut -c1-300)"
    fi
    t1=$(date +%s%N)
    guest=""
    if [[ $result == PASS ]]; then
      out=$(timeout 60 ctr -n "$NS" task exec --exec-id probe "$id" sh -c 'uname -r; echo cycle-exec-ok' 2>&1); rc=$?
      guest=$(echo "$out" | sed -n 1p)
      if [[ $rc -ne 0 || "$out" != *cycle-exec-ok* || "$guest" != "$expected" ]]; then
        result=FAIL; note="exec rc=$rc: $(echo "$out" | tr '\n' ' ' | cut -c1-300)"
      fi
    fi
    t2=$(date +%s%N)
    ctr -n "$NS" task kill -s SIGKILL "$id" > /dev/null 2>&1
    for _ in $(seq 1 100); do
      st=$(ctr -n "$NS" task ls | awk -v id="$id" '$1==id {print $3}')
      [[ "$st" == STOPPED || -z "$st" ]] && break
      sleep 0.2
    done
    ctr -n "$NS" task rm "$id" > /dev/null 2>&1
    ctr -n "$NS" container rm "$id" > /dev/null 2>&1
    t3=$(date +%s%N)
    left=""
    for _ in $(seq 1 $((LINGER * 5))); do left=$(pgrep -f "$id" | tr '\n' ' '); [[ -z "$left" ]] && break; sleep 0.2; done
    t4=$(date +%s%N)
    gone=$(ms "$t3" "$t4")
    [[ -z "$left" ]] || { result=FAIL; gone=">${LINGER}000"; note="$note left: $(pgrep -f "$id" | while read -r q; do ps -o comm= -p "$q"; done | tr '\n' ' ')"; }
    ctr -n "$NS" container ls -q | grep -qx "$id" && { result=FAIL; note="$note container record left"; }
    echo "$i | $(ms "$t0" "$t1") | $(ms "$t1" "$t2") | $(ms "$t2" "$t3") | $gone | $guest | $result $note"
    creates+=("$(ms "$t0" "$t1")")
    [[ $result == PASS ]] && pass=$((pass + 1))
  done
  sorted=$(printf '%s\n' "${creates[@]}" | sort -n)
  echo "create_ms min/median/max: $(echo "$sorted" | sed -n 1p) / $(echo "$sorted" | sed -n "$(( (CYCLES + 1) / 2 ))p") / $(echo "$sorted" | tail -1)"
  journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" > /tmp/e1-klog.txt
  echo "host kernel log lines added: $(wc -l < /tmp/e1-klog.txt)"
  sed -E 's/^\[[ 0-9.]+\] //; s/[0-9]+/N/g' /tmp/e1-klog.txt | sort | uniq -c | sort -rn | head -8 | cut -c1-200
  klog=clean
  if grep -Eq "$BAD" /tmp/e1-klog.txt; then klog="ERRORS"; grep -E "$BAD" /tmp/e1-klog.txt | head -10 | cut -c1-220; fi
  leaks=$(journalctl -u containerd --since "$started" --no-pager -q -o cat | grep -F 'might be leaked' | grep -c -F "cyc-$h-")
  dirs=$(ls /run/kata-containers/shared/sandboxes 2>/dev/null | grep -c "^cyc-$h-")
  echo "containerd 'shim might be leaked' errors: $leaks; shared directories left behind: $dirs"
  echo "CYCLES_${h^^}=$pass/$CYCLES kernel_log=$klog shim_leak_errors=$leaks"
  [[ $pass -eq $CYCLES && $klog == clean ]] || overall=1
done
echo
echo "## leftovers"
ctr -n "$NS" container ls -q | wc -l | sed 's/^/containers in the namespace: /'
ctr -n "$NS" snapshot ls 2>/dev/null | tail -n +2 | wc -l | sed 's/^/snapshots in the namespace (image layers included): /'
pgrep -a -f 'containerd-shim-kata|qemu-system|cloud-hypervisor|virtiofsd' | cut -c1-160 || echo "no shim, VMM or virtiofsd process left"
echo "tainted=$(cat /proc/sys/kernel/tainted)"
free -m | sed -n 2p
exit "$overall"
