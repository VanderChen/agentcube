#!/usr/bin/env bash
# E3 step 14: remove the scratch files the experiment scripts left in /tmp on the VM.
# Nothing else is removed: what the experiments installed is listed in the records and left in place.
set -uo pipefail
ls -la /tmp/e1-* /tmp/e2-* /tmp/e3-* 2> /dev/null | awk '{print $5, $9}'
rm -f /tmp/e1-* /tmp/e2-* /tmp/e3-*
ls /tmp/e1-* /tmp/e2-* /tmp/e3-* 2> /dev/null | wc -l | sed 's/^/scratch files left: /'
ls /tmp | grep -v -E '^(systemd-private|snap-private|\.)' | sed -n '1,12p'
