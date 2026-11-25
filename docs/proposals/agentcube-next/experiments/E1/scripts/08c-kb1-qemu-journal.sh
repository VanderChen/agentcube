#!/usr/bin/env bash
# E1 step 08c: read-only. What containerd and the shim logged about kb1-qemu
# (the sandbox whose shim outlived the deletion in step 08), and what is left of it.
set -uo pipefail
ID=${ID:-kb1-qemu}
SINCE=${SINCE:-2026-11-25 03:03:40}
UNTIL=${UNTIL:-2026-11-25 03:05:00}
echo "## journal lines of containerd mentioning $ID: first 6, last 30"
journalctl -u containerd --since "$SINCE" --until "$UNTIL" --no-pager -q -o short-precise | grep -F "$ID" > /tmp/e1-journal.txt
wc -l < /tmp/e1-journal.txt | sed 's/^/lines: /'
sed -n '1,6p' /tmp/e1-journal.txt | cut -c1-260
echo "..."
tail -30 /tmp/e1-journal.txt | cut -c1-330
echo "## warnings and errors among them"
grep -i -E 'level=(warn|error)|ERR[O]|WARN|error|failed|timeout' /tmp/e1-journal.txt | cut -c1-330 | head -30
echo "## what is left"
ls -la "/run/kata-containers/shared/sandboxes/$ID" 2>&1 | head -8
find "/run/kata-containers/shared/sandboxes/$ID" 2>/dev/null | head -20
grep -F "$ID" /proc/mounts | cut -c1-200 || echo "no mount mentions $ID"
ls -d "/run/kata/$ID" "/run/containerd/io.containerd.runtime.v2.task/e1/$ID" 2>&1 | cut -c1-200
