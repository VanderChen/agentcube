#!/usr/bin/env bash
# E3 step 09: read-only. What the VMM, the shim and the host kernel logged
# while templates and sandboxes were created on CubeSandbox's own PVM host kernel.
set -uo pipefail
SINCE=${SINCE:-2026-11-25 03:45:00}
V=/data/log/CubeVmm/vmm.log
echo "## host"
uname -r; lsmod | grep -E '^kvm'; echo "tainted=$(cat /proc/sys/kernel/tainted)"
echo "## VMM log since the host kernel was switched (the E2 failure is earlier in the same file)"
total=$(wc -l < "$V"); first=$(grep -n -m1 -F 'tpl-5b0a841ee9a24d7494191a95' "$V" | cut -d: -f1)
echo "lines in file: $total; first line of the E3 template: ${first:-none}"
tail -n +"${first:-1}" "$V" > /tmp/e3-vmm.txt
echo "levels: $(grep -o -E ' --- (INFO|WARN|ERROR) --- ' /tmp/e3-vmm.txt | sort | uniq -c | tr -s ' \n' ' ')"
echo "VM instances: $(cut -d' ' -f1 /tmp/e3-vmm.txt | sort -u | wc -l)"
echo "-- lines about MSRs (E0 found that kvm-pvm on the Ubuntu host refuses to set MSR 0x3a on AMD; #2254 makes the VMM tolerate that)"
grep -i -E 'msr' /tmp/e3-vmm.txt | sed -E 's/^[^ ]+ --- [0-9]+ --- //' | sed -E 's/0x[0-9a-f]{6,}/0xN/g' | sort | uniq -c | sort -rn | cut -c1-230 | sed -n '1,12p'
echo "(end; $(grep -c -i msr /tmp/e3-vmm.txt) lines mention MSR)"
echo "-- WARN and ERROR lines, grouped"
grep -E ' --- (WARN|ERROR) --- ' /tmp/e3-vmm.txt | sed -E 's/^[^ ]+ --- [0-9]+ --- //; s/[0-9a-f]{8,}/N/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | cut -c1-220 | sed -n '1,14p'
echo "-- snapshot and restore events, grouped"
grep -i -E 'snapshot|restor' /tmp/e3-vmm.txt | sed -E 's/^[^ ]+ --- [0-9]+ --- (INFO|WARN|ERROR) --- //; s#/[A-Za-z0-9_./-]+#PATH#g; s/[0-9]+(\.[0-9]+)?(ms|µs|s)\b/T/g; s/[0-9a-f]{8,}/N/g; s/[0-9]+/N/g' | sort | uniq -c | sort -rn | cut -c1-200 | sed -n '1,12p'
echo "-- vCPU exits other than normal shutdown"
grep -E 'VmExit|Shutdown because|triple|panic' /tmp/e3-vmm.txt | sed -E 's/^[^ ]+ --- [0-9]+ --- //' | sort | uniq -c | cut -c1-200 | sed -n '1,8p'; echo "(end)"
echo "## shim log: error lines since $SINCE"
grep -i -E 'fail|error' /data/log/CubeShim/cube-shim-req.log | grep -v -F 'tpl-02b6fc70febf4fea8f8547dc' | cut -c1-260 | tail -6; echo "(end; lines for the E2 template excluded)"
echo "## host kernel log of this boot"
echo "lines: $(dmesg | wc -l); matching BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode: $(dmesg | grep -c -E 'BUG:|WARNING:|Oops|general protection|Call Trace|non-PVM mode')"
dmesg | grep -E 'BUG:|WARNING:|Oops|general protection|Call Trace' | cut -c1-200 | sed -n '1,5p'
echo "kvm and pvm lines:"; dmesg | grep -i -E '\bkvm|pvm' | grep -v -E 'kvm-clock|kvm-guest|Booting paravirt|Hypervisor detected|Command line|command line' | sed -E 's/\[[0-9]+\]/[pid]/' | cut -c1-200 | sort -k3 | uniq -c -f2 | sed -n '1,10p'; echo "(end)"
echo "error level and above:"; dmesg --level=err,crit,alert,emerg | cut -c1-200 | tail -8; echo "(end)"
echo "## templates and sandboxes now"
timeout 30 /usr/local/services/cubetoolbox/CubeMaster/bin/cubemastercli template list --json 2>&1 | grep -E '"(template_id|status|image_info)"' | cut -c1-200
curl -fsS -m 10 http://127.0.0.1:3000/sandboxes -H 'X-API-Key: e2b_000000' 2>&1 | cut -c1-200; echo
df -h /data/cubelet | tail -1; free -m | sed -n 2p
