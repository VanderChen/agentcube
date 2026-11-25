#!/usr/bin/env bash
# E1 step 08d: read-only. The full text of the teardown error containerd logged
# for kb1-qemu, and whether the same error appeared for the other sandboxes so far.
set -uo pipefail
SINCE=${SINCE:-2026-11-25 03:03:00}
journalctl -u containerd --since "$SINCE" --no-pager -q -o short-precise > /tmp/e1-journal-all.txt
echo "## 'might be leaked' errors since $SINCE, by sandbox"
grep -F 'might be leaked' /tmp/e1-journal-all.txt | grep -o -E 'id=[A-Za-z0-9-]+|sandbox-[A-Za-z0-9-]+' | sort | uniq -c || true
grep -c -F 'might be leaked' /tmp/e1-journal-all.txt | sed 's/^/total: /'
echo "## full text of each"
grep -F 'might be leaked' /tmp/e1-journal-all.txt | fold -w 230
echo "## shim start and disconnect times per sandbox (how long each shim lived after the kill)"
grep -E 'connecting to shim|shim disconnected' /tmp/e1-journal-all.txt | sed -E 's/ localhost containerd\[[0-9]+\]: time="[^"]+"//; s/address=.*//' | cut -c1-140
echo "## leftovers on disk"
ls /run/kata-containers/shared/sandboxes 2>/dev/null | sed 's/^/shared dir left: /'
ls /run/kata 2>/dev/null | sed 's/^/run dir left: /'
exit 0
