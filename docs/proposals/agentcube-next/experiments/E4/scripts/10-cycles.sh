#!/usr/bin/env bash
# E2 step 10: create a sandbox from the template, run code in it, delete it; repeated.
# Uses the template and the SDK script of step 09. The times are observations, not a benchmark.
set -uo pipefail
W=${W:-/root/e2/quickstart}
CYCLES=${CYCLES:-10}
tpl=$(cat "$W/template-id") || exit 1
before=$(journalctl -k -b --no-pager -q | wc -l)
echo "template: $tpl; cycles: $CYCLES; host kernel: $(uname -r)"
export E2B_API_URL=http://127.0.0.1:3000 E2B_API_KEY=e2b_000000 CUBE_TEMPLATE_ID="$tpl" SSL_CERT_FILE=/root/.local/share/mkcert/rootCA.pem
cd "$W" && timeout 1200 /root/e2/venv/bin/python sdk_run.py "$CYCLES"
rc=$?
echo "sdk exit=$rc"
echo "## sandboxes left"
curl -fsS -m 10 http://127.0.0.1:3000/sandboxes -H 'X-API-Key: e2b_000000' 2>&1 | cut -c1-300; echo
pgrep -a -f 'cube-hypervisor|cloud-hypervisor|cube-shim|containerd-shim-cube' | cut -c1-140 | sed -n '1,8p' || echo "no hypervisor or shim process"
echo "## host kernel log lines added"
journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | grep -v -E 'IN=.*OUT=' > /tmp/e2-klog.txt
wc -l < /tmp/e2-klog.txt | sed 's/^/lines: /'
sed -E 's/^\[[ 0-9.]+\] //; s/[0-9]+/N/g' /tmp/e2-klog.txt | sort | uniq -c | sort -rn | sed -n '1,10p' | cut -c1-200
grep -c -E 'BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode' /tmp/e2-klog.txt | sed 's/^/lines matching the error patterns: /'
echo "tainted=$(cat /proc/sys/kernel/tainted)"
exit "$rc"
