#!/usr/bin/env bash
# E2 step 08b: read-only. Step 08 failed at template creation with
# "expected: VsockServerReady, actual: VmShutdown". Collect what the VMM, the
# shim (which carries the guest console) and the host kernel logged about it.
set -uo pipefail
TPL=${TPL:-tpl-02b6fc70febf4fea8f8547dc}
SINCE=${SINCE:-2026-11-25 03:35:20}
echo "## log files"
ls -l /data/log/*/ 2> /dev/null | awk 'NF>=9 {print $5, $6, $7, $8, $9} /^\/data/ {print}' | cut -c1-120
for f in /data/log/CubeVmm/vmm.log /data/log/CubeShim/cube-shim-req.log; do
  echo
  echo "## $f: $(wc -l < "$f" 2> /dev/null) lines; lines for $TPL: $(grep -c -F "$TPL" "$f" 2> /dev/null)"
done
echo
echo "## VMM log, lines for this template (long fields cut)"
grep -F "$TPL" /data/log/CubeVmm/vmm.log 2> /dev/null | cut -c1-420 | tail -45
echo
echo "## VMM log, anything about MSR, CPUID, KVM errors, exits, panics, triple faults (whole file)"
grep -n -i -E 'msr|cpuid|kvm_|ioctl|panic|fault|shutdown|reset|error|failed|unsupported|pvm|exit reason' /data/log/CubeVmm/vmm.log 2> /dev/null | cut -c1-360 | tail -40
echo
echo "## shim log: guest console and errors for this template"
grep -F "$TPL" /data/log/CubeShim/cube-shim-req.log 2> /dev/null | cut -c1-360 | tail -60
echo
echo "## template build container output"
ls -l "/data/log/template/${TPL}_0/" 2>&1 | cut -c1-120
for f in stdout stderr; do [[ -s "/data/log/template/${TPL}_0/$f" ]] && { echo "--- $f"; tail -30 "/data/log/template/${TPL}_0/$f" | cut -c1-300; }; done
echo
echo "## Cubelet request log for this template: errors"
grep -F "$TPL" /data/log/Cubelet/Cubelet-req.log 2> /dev/null | grep -i -E 'error|fail|shutdown' | cut -c1-500 | tail -8
echo
echo "## host kernel log since $SINCE"
journalctl -k -b --no-pager -q --since "$SINCE" -o short-monotonic | grep -v -E 'IN=.*OUT=' | cut -c1-220 | tail -30
echo "(end)"
echo "## hypervisor binary and its version"
ls -l /usr/local/services/cubetoolbox/cube-shim/ /usr/local/services/cubetoolbox/cube-hypervisor* 2> /dev/null | awk 'NF>=9 {print $5, $9, $10, $11}' | cut -c1-140 | sed -n '1,20p'
for b in /usr/local/bin/cube-runtime /usr/local/services/cubetoolbox/cube-shim/bin/cube-runtime; do [[ -x $b ]] && { "$b" --version 2>&1 | sed -n '1,3p' | cut -c1-160; break; }; done
