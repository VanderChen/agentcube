#!/usr/bin/env bash
# E2 step 06: run the one-click installer with the PVM guest kernel selected.
# The full installer output stays on the VM in /root/e2/install.log.
set -uo pipefail
cd /root/e2/current || exit 1
[[ -e /run/e2-allow ]] || { echo "this boot is not allowed (touch /run/e2-allow first)"; exit 1; }
grep -q '^kvm_pvm ' /proc/modules || { echo "kvm_pvm is not loaded"; exit 1; }
mountpoint -q /data/cubelet || { echo "/data/cubelet is not mounted"; exit 1; }
ls .env 2> /dev/null && echo "a .env file exists and may override CUBE_PVM_ENABLE" || echo "no .env file in the bundle directory"
cat VERSION.txt 2> /dev/null | sed -n 1,3p
start=$(date +%s)
CUBE_PVM_ENABLE=1 timeout 2700 ./install.sh > /root/e2/install.log 2>&1 < /dev/null
rc=$?
echo "## install.sh exit=$rc after $(( $(date +%s) - start )) s; $(wc -l < /root/e2/install.log) lines in /root/e2/install.log"
echo "## lines about PVM, the node, the network and anything that went wrong"
grep -n -i -E 'pvm|node ip|primary network interface|cidr|error|fail|die|warn|not found|timed out|skipp' /root/e2/install.log | cut -c1-230 | sed -n '1,70p'
echo "## last 45 lines"
tail -45 /root/e2/install.log | cut -c1-230
exit "$rc"
