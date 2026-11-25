#!/usr/bin/env bash
# E3 step 01: install CubeSandbox's PVM host kernel next to the existing ones
# and add a one-shot boot entry for it. The default entry and the global
# kernel parameters are not touched. No reboot in this step.
set -euo pipefail
NAME=linux-image-6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e_6.6.117-gbc75224fca7e-1_amd64.deb
URL=https://github.com/TencentCloud/CubeSandbox/releases/download/kernel-release-261012-1/$NAME
EXPECT_SHA256=${EXPECT_SHA256:?pass the digest GitHub shows for the asset}
KVER=6.6.117-opencloudos9.cubesandbox.pvm.host-gbc75224fca7e
# deploy/pvm/grub/host_grub_config.sh @ 41748bb7 (v0.8.0), without its two console= settings
# and without net.ifnames=0, which the VM's own parameters already carry.
CUBE_PARAMS="quiet elevator=noop vconsole.keymap=us crashkernel=1800M-64G:256M,64G-128G:512M,128G-486G:768M,486G-972G:1024M,972G-:2048M vconsole.font=latarcyrheb-sun16 biosdevname=0 intel_idle.max_cstate=1 intel_pstate=disable cgroup.memory=nokmem transparent_hugepage=never ipv6.disable=1 systemd.unified_cgroup_hierarchy=1 clearcpuid=27,28,54,57,104,107,118,120,122,131,152,158,193,196,198,199,200,201,214,215,225,241,249,250,254,289,292,295,297,299,302,306,307,309,311,312,317,321,322,323,389,416,418,425,513,514,517,518,520,521,522,523,524,526,534,537,539,540,580 clocksource=tsc pti=off no5lvl mitigations=on spec_store_bypass_disable=prctl retbleed=off kvm.nx_huge_pages=never tsc=reliable kmem_cache.max_num=0 kmem_cache.sleep_ms=0 idle=halt processor.max_cstate=1"
install -d -m 0755 /root/e3; cd /root/e3

echo "## package"
if [[ ! -s "$NAME" ]]; then curl -fL --retry 3 -sS -o "$NAME.part" "$URL"; mv "$NAME.part" "$NAME"; fi
ls -l "$NAME" | awk '{print $5, $9}'
printf '%s  %s\n' "$EXPECT_SHA256" "$NAME" | sha256sum -c -
dpkg-deb -f "$NAME" Package Version Architecture Depends Maintainer | cut -c1-200
dpkg-deb -c "$NAME" | awk '{print $6}' | grep -E '^\./(boot/|lib/modules/[^/]+/$|etc/)' | sed -n '1,12p'
dpkg-deb -I "$NAME" | grep -E 'preinst|postinst|prerm|postrm' | cut -c1-120 || true

echo "## install"
cp -a /boot/grub/grub.cfg /root/e3/grub.cfg.before
cp -a /etc/grub.d/40_custom /root/e3/40_custom.before
DEBIAN_FRONTEND=noninteractive dpkg -i "$NAME" > /root/e3/dpkg.log 2>&1 || { tail -30 /root/e3/dpkg.log; exit 1; }
tail -12 /root/e3/dpkg.log | cut -c1-200
[[ -s /boot/initrd.img-$KVER ]] || { echo "no initramfs was generated; generating"; update-initramfs -c -k "$KVER" 2>&1 | tail -3; }
ls -l /boot | awk '/6\.6\.117/ {print $5, $9, $10, $11}'
ls /lib/modules

echo "## kernel configuration, items that matter here"
cfg=/boot/config-$KVER
grep -E '^CONFIG_(KVM|KVM_PVM|KVM_AMD|KVM_INTEL|PVM_GUEST|SCSI_VIRTIO|VIRTIO_NET|VIRTIO_PCI|VIRTIO_BLK|BLK_DEV_SD|EXT4_FS|XFS_FS|SECURITY_APPARMOR|RANDOMIZE_BASE|X86_5LEVEL|DEBUG_INFO_BTF|NF_TABLES|NFT_COMPAT|NETFILTER_XT_MATCH_CONNTRACK|BLK_DEV_LOOP|MODULE_SIG_FORCE|NET_CLS_BPF|NET_SCH_INGRESS|VETH|BRIDGE|OVERLAY_FS|CGROUP_BPF|MEMCG|IPV6|USERFAULTFD)=' "$cfg" | tr '\n' ' '; echo
echo "## drivers this VM needs to boot and get on the network"
ok=1
for m in virtio_pci virtio_scsi sd_mod ext4 virtio_net; do
  if grep -q -E "/$m\.ko" "/lib/modules/$KVER/modules.builtin"; then where="built in"
  elif lsinitramfs "/boot/initrd.img-$KVER" | grep -q -E "/$m\.ko"; then where="in the initramfs"
  elif find "/lib/modules/$KVER" -name "$m.ko*" | grep -q .; then where="module on disk, NOT in the initramfs"; [[ $m == virtio_net ]] || ok=0
  else where="MISSING"; ok=0; fi
  echo "$m: $where"
done
find "/lib/modules/$KVER" -name 'kvm*.ko*' | sed "s#/lib/modules/$KVER/##" | tr '\n' ' '; echo
[[ $ok == 1 ]] || { echo "a driver needed for booting is missing; stopping"; exit 1; }

echo "## the default entry is still the pinned 6.8.0-149"
grep -E '^GRUB_DEFAULT=' /etc/default/grub | cut -c1-170
grep -c 'set default="gnulinux-advanced-.*6.8.0-149-generic' /boot/grub/grub.cfg | sed 's/^/grub.cfg lines selecting 6.8.0-149 by id: /'
grep -o "menuentry_id_option '[^']*'" /boot/grub/grub.cfg | sed "s/menuentry_id_option //" | tr '\n' ' '; echo
grub-editenv /boot/grub/grubenv list; echo "(end grubenv)"

echo "## one-shot entry e3-cube-pvm-host"
python3 - "$KVER" "$CUBE_PARAMS" <<'PY'
import re, sys
kver, cube = sys.argv[1], sys.argv[2]
cfg = open("/boot/grub/grub.cfg").read()
m = re.search(r"\tmenuentry 'Ubuntu, with Linux %s' .*?\n\t}\n" % re.escape(kver), cfg, re.S)
assert m, "generated entry for %s not found" % kver
block = "\n".join(l[1:] if l.startswith("\t") else l for l in m.group(0).splitlines()) + "\n"
block, n1 = re.subn(r"menuentry 'Ubuntu, with Linux %s'" % re.escape(kver), "menuentry 'E3 CubeSandbox PVM host: Linux %s'" % kver, block)
block, n2 = re.subn(r"\$menuentry_id_option 'gnulinux-%s-advanced-[^']*'" % re.escape(kver), "$menuentry_id_option 'e3-cube-pvm-host'", block)
block, n3 = re.subn(r"(?m)^(\s*linux\s+/boot/vmlinuz-%s .*?)\s*$" % re.escape(kver), lambda mm: mm.group(1) + " " + cube, block)
assert (n1, n2, n3) == (1, 1, 1), (n1, n2, n3)
custom = open("/etc/grub.d/40_custom").read()
assert "e3-cube-pvm-host" not in custom, "entry already present"
open("/etc/grub.d/40_custom", "w").write(custom.rstrip("\n") + "\n\n# E3 (AgentCube 000-5): one-shot entry for CubeSandbox's PVM host kernel. Select with: grub-reboot e3-cube-pvm-host\n" + block)
PY
update-grub 2>&1 | tail -1
grub-script-check /boot/grub/grub.cfg && echo "grub.cfg syntax ok"
sed -n "/menuentry_id_option 'e3-cube-pvm-host'/,/^}/p" /boot/grub/grub.cfg | grep -E '^\s*(linux|initrd)\s' | sed 's/^\s*//' | fold -w 190
grep -c 'set default="gnulinux-advanced-.*6.8.0-149-generic' /boot/grub/grub.cfg | sed 's/^/after update-grub, grub.cfg lines selecting 6.8.0-149 by id: /'
sed -n "/menuentry_id_option 'e0-pvm-139'/,/^}/p" /boot/grub/grub.cfg | grep -c -E '^\s*linux\s.*nokaslr' | sed 's/^/the E0 entry e0-pvm-139 is still there (1 = yes): /'
