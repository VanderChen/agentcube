#!/usr/bin/env bash
# E2: name the default boot entry instead of relying on "entry 0 is 6.8.0-149".
# The default stays the kernel the VM came with; only the way it is selected changes.
set -euo pipefail
KVER=${KVER:-6.8.0-149-generic}
install -d -m 0755 /root/exp/E2
uuid=$(grep -o -m1 "gnulinux-simple-[0-9a-f-]*" /boot/grub/grub.cfg | sed 's/gnulinux-simple-//')
id="gnulinux-advanced-$uuid>gnulinux-$KVER-advanced-$uuid"
grep -q "menuentry_id_option 'gnulinux-advanced-$uuid'" /boot/grub/grub.cfg
grep -q "menuentry_id_option 'gnulinux-$KVER-advanced-$uuid'" /boot/grub/grub.cfg
echo "entry to pin: $id"
[[ -e /root/exp/E2/default-grub.before-pin ]] || cp -a /etc/default/grub /root/exp/E2/default-grub.before-pin
cp -a /boot/grub/grub.cfg /root/exp/E2/grub.cfg.before-pin
echo "before: $(grep -E '^GRUB_DEFAULT=' /etc/default/grub)"
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$id\"|" /etc/default/grub
echo "after:  $(grep -E '^GRUB_DEFAULT=' /etc/default/grub)"
diff /root/exp/E2/default-grub.before-pin /etc/default/grub | sed 's/^/  /' || true
update-grub 2>&1 | tail -2
grub-script-check /boot/grub/grub.cfg && echo "grub.cfg syntax ok"
echo "## how grub.cfg selects the default now"
grep -n -B3 -A3 'set default=' /boot/grub/grub.cfg | cut -c1-170 | sed -n '1,16p'
echo "## the pinned entry"
awk -v want="gnulinux-$KVER-advanced-$uuid" 'index($0, "menuentry_id_option \047" want "\047") {p=1} p && /^[[:space:]]*(linux|initrd)[[:space:]]/ {print} p && /^[[:space:]]*}/ {exit}' /boot/grub/grub.cfg | sed 's/^[[:space:]]*//' | cut -c1-160
echo "## the rest of grub.cfg is unchanged apart from the default line"
diff <(grep -v 'set default=' /root/exp/E2/grub.cfg.before-pin) <(grep -v 'set default=' /boot/grub/grub.cfg) > /dev/null && echo "yes" || { echo "NO:"; diff /root/exp/E2/grub.cfg.before-pin /boot/grub/grub.cfg | head -20; }
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"
apt-mark showhold | tr '\n' ' '; echo
