#!/usr/bin/env bash
# E4 step 01b: add a one-shot boot entry for CubeSandbox's PVM host kernel with a
# given parameter list instead of the long list its documentation asks for.
# It is E3's entry (e3-cube-pvm-host) with everything after "root=UUID=... ro" replaced.
#   ID=<entry id> PARAMS="<kernel parameters>"
set -euo pipefail
ID=${ID:?entry id}
PARAMS=${PARAMS:?kernel parameters}
install -d -m 0755 /root/exp/E4
python3 - "$ID" "$PARAMS" <<'PY'
import re, sys
new_id, params = sys.argv[1], sys.argv[2]
path = "/etc/grub.d/40_custom"
custom = open(path).read()
assert "'%s'" % new_id not in custom, "entry already present"
m = re.search(r"menuentry 'E3 CubeSandbox PVM host[^\n]*\$menuentry_id_option 'e3-cube-pvm-host' \{\n.*?\n\}\n", custom, re.S)
assert m, "the e3-cube-pvm-host entry was not found in 40_custom"
block = m.group(0)
block, n1 = re.subn(r"menuentry 'E3 CubeSandbox PVM host: [^']*'", "menuentry 'E4 CubeSandbox PVM host kernel with: %s'" % params, block)
block, n2 = re.subn(r"\$menuentry_id_option 'e3-cube-pvm-host'", "$menuentry_id_option '%s'" % new_id, block)
block, n3 = re.subn(r"(?m)^(\s*linux\s+\S+ root=UUID=\S+ ro) .*$", lambda mm: mm.group(1) + " " + params, block)
assert (n1, n2, n3) == (1, 1, 1), (n1, n2, n3)
open(path, "w").write(custom.rstrip("\n") + "\n\n# E4 (AgentCube 000-5): CubeSandbox's PVM host kernel with a reduced parameter list. Select with: grub-reboot %s\n" % new_id + block)
PY
update-grub 2>&1 | tail -1
grub-script-check /boot/grub/grub.cfg && echo "grub.cfg syntax ok"
sed -n "/menuentry_id_option '$ID'/,/^}/p" /boot/grub/grub.cfg | grep -E '^\s*(linux|initrd)\s' | sed -E 's/^\s*//; s/root=UUID=[0-9a-f-]+/root=UUID=<uuid>/' | fold -w 190
grep -c 'set default="gnulinux-advanced-.*6.8.0-149-generic' /boot/grub/grub.cfg | sed 's/^/default entry is 6.8.0-149 by id (1 = yes): /'
grep -o "menuentry_id_option 'e[0-9][^']*'" /boot/grub/grub.cfg | sed "s/menuentry_id_option //" | tr '\n' ' '; echo
