#!/usr/bin/env bash
# E4 step 01: add a one-shot boot entry that is E0's PVM host entry (e0-pvm-139)
# with extra kernel parameters appended. The default entry is not touched.
#   ID=<entry id> EXTRA="<parameters to append>"
set -euo pipefail
ID=${ID:?entry id}
EXTRA=${EXTRA:?parameters to append}
install -d -m 0755 /root/exp/E4
grep -q "menuentry_id_option 'e0-pvm-139'" /boot/grub/grub.cfg
[[ -e /root/exp/E4/40_custom.before ]] || cp -a /etc/grub.d/40_custom /root/exp/E4/40_custom.before
python3 - "$ID" "$EXTRA" <<'PY'
import re, sys
new_id, extra = sys.argv[1], sys.argv[2]
path = "/etc/grub.d/40_custom"
custom = open(path).read()
assert "'%s'" % new_id not in custom, "entry already present"
m = re.search(r"menuentry 'E0 PVM host[^\n]*\$menuentry_id_option 'e0-pvm-139' \{\n.*?\n\}\n", custom, re.S)
assert m, "the e0-pvm-139 entry was not found in 40_custom"
block = m.group(0)
block, n1 = re.subn(r"menuentry 'E0 PVM host: [^']*'", "menuentry 'E4 PVM host: Linux 6.8.0-139-generic nokaslr %s'" % extra, block)
block, n2 = re.subn(r"\$menuentry_id_option 'e0-pvm-139'", "$menuentry_id_option '%s'" % new_id, block)
block, n3 = re.subn(r"(?m)^(\s*linux\s+/boot/vmlinuz-6\.8\.0-139-generic .*?)\s*$", lambda mm: mm.group(1) + " " + extra, block)
assert (n1, n2, n3) == (1, 1, 1), (n1, n2, n3)
open(path, "w").write(custom.rstrip("\n") + "\n\n# E4 (AgentCube 000-5): E0's PVM host entry with extra parameters. Select with: grub-reboot %s\n" % new_id + block)
PY
update-grub 2>&1 | tail -1
grub-script-check /boot/grub/grub.cfg && echo "grub.cfg syntax ok"
sed -n "/menuentry_id_option '$ID'/,/^}/p" /boot/grub/grub.cfg | grep -E '^\s*(linux|initrd)\s' | sed -E 's/^\s*//; s/root=UUID=[0-9a-f-]+/root=UUID=<uuid>/' | fold -w 190
grep -c 'set default="gnulinux-advanced-.*6.8.0-149-generic' /boot/grub/grub.cfg | sed 's/^/default entry is 6.8.0-149 by id (1 = yes): /'
grep -o "menuentry_id_option 'e[0-9][^']*'" /boot/grub/grub.cfg | sed "s/menuentry_id_option //" | tr '\n' ' '; echo
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
