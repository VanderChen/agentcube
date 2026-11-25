#!/usr/bin/env bash
# KB-1 for each hypervisor (E1 step 08; in E4 the configuration directory is chosen with CONF). A long-running container from an image
# (so the snapshotter and the shared file system are exercised), one command
# executed in it, the host-side processes and their cgroups, then deletion.
set -uo pipefail
NS=${NS:-e1}
IMAGE=${IMAGE:-docker.io/library/busybox:1.36}
CONF=${CONF:-/etc/kata-containers/pvm}
HYPERVISORS=${HYPERVISORS:-qemu dragonball clh}
BAD='BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode'
ms() { echo $(( ($2 - $1) / 1000000 )); }

ctr -n "$NS" image ls -q | grep -qx "$IMAGE" || ctr -n "$NS" image pull "$IMAGE" > /dev/null
ctr -n "$NS" image ls | awk 'NR==1 || /busybox/' | cut -c1-170
echo "host kernel: $(uname -r)"
echo "shim: $(/usr/local/bin/containerd-shim-kata-v2 --version)"
echo "guest kernel configured: $(sed -n 's/^kernel = //p' "$CONF"/configuration-clh-pvm.toml | tr -d '"')"

overall=0
for h in $HYPERVISORS; do
  id="kb1-$h"
  cfg="$CONF/configuration-$h-pvm.toml"
  echo
  echo "=== $h ($cfg) ==="
  before=$(journalctl -k -b --no-pager -q | wc -l)
  result=PASS
  t0=$(date +%s%N)
  if ! timeout 180 ctr -n "$NS" run -d --runtime io.containerd.kata.v2 --runtime-config-path "$cfg" \
      "$IMAGE" "$id" sleep 3600 > /tmp/e1-run.out 2>&1; then
    echo "create failed:"; cut -c1-600 /tmp/e1-run.out
    result=FAIL
  else
    t1=$(date +%s%N)
    echo "create and start: $(ms "$t0" "$t1") ms"
    ctr -n "$NS" task ls | awk -v id="$id" 'NR==1 || $1==id'

    echo "-- command executed in the sandbox"
    t2=$(date +%s%N)
    out=$(timeout 60 ctr -n "$NS" task exec --exec-id probe "$id" sh -c \
      'echo "guest kernel: $(uname -r)"; echo "guest arch: $(uname -m)"; echo "guest cpus: $(nproc)"; grep -m1 "address sizes" /proc/cpuinfo; grep -m1 MemTotal /proc/meminfo; echo "guest cmdline: $(cat /proc/cmdline)"; echo "guest kernel log lines mentioning pvm:"; dmesg 2>/dev/null | grep -i pvm | head -5; echo kb1-exec-ok' 2>&1)
    rc=$?
    t3=$(date +%s%N)
    echo "$out" | cut -c1-400
    echo "exec exit=$rc, $(ms "$t2" "$t3") ms"
    guest=$(echo "$out" | sed -n 's/^guest kernel: //p')
    if [[ $rc -ne 0 || "$out" != *kb1-exec-ok* ]]; then result=FAIL; fi
    if [[ -z "$guest" || "$guest" == "$(uname -r)" ]]; then
      echo "the kernel in the sandbox is not different from the host's"; result=FAIL
    else
      echo "kernel in the sandbox ($guest) differs from the host's ($(uname -r))"
    fi

    echo "-- processes on the host that belong to this sandbox, and their cgroups"
    shim=$(pgrep -f "containerd-shim-kata-v2.*$id" | head -1)
    pids=$( { pgrep -f "$id"; [[ -n "$shim" ]] && pgrep -P "$shim"; } | sort -un)
    for p in $pids; do
      [[ -r /proc/$p/cgroup ]] || continue
      printf 'pid=%s ppid=%s comm=%s rss_kb=%s threads=%s\n' "$p" "$(ps -o ppid= -p "$p" | tr -d ' ')" \
        "$(ps -o comm= -p "$p")" "$(ps -o rss= -p "$p" | tr -d ' ')" "$(ps -o nlwp= -p "$p" | tr -d ' ')"
      printf '  args: %s\n' "$(ps -o args= -p "$p" | cut -c1-330)"
      printf '  cgroup: %s\n' "$(tr '\n' ' ' < /proc/$p/cgroup)"
    done
    echo "-- KVM on the host"
    lsmod | grep -E '^kvm'
    ls /sys/kernel/debug/kvm 2>/dev/null | grep -c -E '^[0-9]+-[0-9]+$' | sed 's/^/VMs listed in debugfs: /'

    echo "-- delete"
    t4=$(date +%s%N)
    ctr -n "$NS" task kill -s SIGKILL "$id" 2>&1 | cut -c1-200
    for _ in $(seq 1 100); do
      st=$(ctr -n "$NS" task ls | awk -v id="$id" '$1==id {print $3}')
      [[ "$st" == STOPPED || -z "$st" ]] && break
      sleep 0.2
    done
    ctr -n "$NS" task rm "$id" 2>&1 | cut -c1-200
    ctr -n "$NS" container rm "$id" 2>&1 | cut -c1-200
    t5=$(date +%s%N)
    echo "delete: $(ms "$t4" "$t5") ms"
    left=""
    for _ in $(seq 1 25); do left=$(pgrep -f "$id" | tr '\n' ' '); [[ -z "$left" ]] && break; sleep 0.2; done
    if [[ -n "$left" ]]; then
      echo "processes left after deletion:"; pgrep -a -f "$id" | cut -c1-200; result=FAIL
    else
      echo "no process of this sandbox is left"
    fi
  fi
  ctr -n "$NS" container ls -q | grep -x "$id" && { echo "container record left"; result=FAIL; }
  echo "-- host kernel log lines added"
  journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" > /tmp/e1-klog.txt
  cut -c1-220 /tmp/e1-klog.txt | head -30
  echo "(end, $(wc -l < /tmp/e1-klog.txt) lines)"
  if grep -Eq "$BAD" /tmp/e1-klog.txt; then echo "host kernel reported an error"; result=FAIL; fi
  echo "KB1_${h^^}=$result"
  [[ $result == PASS ]] || overall=1
done
echo
echo "tainted=$(cat /proc/sys/kernel/tainted)"
exit "$overall"
