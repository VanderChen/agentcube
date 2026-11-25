#!/usr/bin/env bash
# E2 step 08: the PVM project's CubeSandbox test, unchanged: create a template
# from an image (boots a microVM and snapshots it), create a sandbox from the
# template (restores the snapshot), wait until it is running, delete both.
# Two settings differ from its defaults because of this VM: where the
# CubeSandbox env file is, and the template image (its default registry is not
# reachable from here; the same upstream image is taken from Docker Hub).
set -uo pipefail
CTX=/build/pvm/context
export CUBE_ENV_FILE=/usr/local/services/cubetoolbox/.one-click.env
export PVM_SHARED_ROOT=/root/e2/pvm-shared
export LOG_DIR=/root/e2/pvm-project-test
export CUBE_TEMPLATE_IMAGE=${CUBE_TEMPLATE_IMAGE:-docker.io/library/redis:7-alpine}
MODE=${MODE:-all}
install -d -m 0755 "$PVM_SHARED_ROOT/scripts" "$LOG_DIR"
before=$(journalctl -k -b --no-pager -q | wc -l)
start=$(date +%s)
timeout 1500 "$CTX/scripts/cubesandbox-pvm-test.sh" "$MODE" > "$LOG_DIR/run.out" 2>&1
rc=$?
echo "## PVM project's scripts/cubesandbox-pvm-test.sh $MODE: exit=$rc after $(( $(date +%s) - start )) s (image: $CUBE_TEMPLATE_IMAGE)"
echo "## its output (repeated status lines collapsed)"
uniq -c "$LOG_DIR/run.out" | cut -c1-260 | tail -60
echo "## files it wrote"
ls -l "$LOG_DIR" | awk 'NR>1 {print $5, $9}'
for f in template-status.json restore-create.json restore-state.json; do [[ -s "$LOG_DIR/$f" ]] && { echo "--- $f"; cut -c1-700 "$LOG_DIR/$f"; echo; }; done
echo "## host kernel log lines added"
journalctl -k -b --no-pager -q -o short-monotonic | tail -n +"$((before + 1))" | grep -v -E 'IN=.*OUT=' | cut -c1-220 | tail -30
echo "(end)"
echo "tainted=$(cat /proc/sys/kernel/tainted)"
exit "$rc"
