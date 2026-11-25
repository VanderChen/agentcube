#!/usr/bin/env bash
# E0 post-check G: read-only, run after E1 to E3. The audit of the E0 record
# found statements whose evidence had only been looked at on screen and never
# saved. This re-reads them from the VM. The VM has changed since E0 (E1 to E3),
# so only things that later steps did not touch are checked here.
set -uo pipefail
echo "## tools installed in E0 phase A (versions)"
dpkg-query -W -f='${Package} ${Version} ${Status}\n' kexec-tools msr-tools rpm2cpio rpm-common librpm9t64 librpmio9t64 liblua5.3-0 cpio 2>&1
echo "## apt transactions on 2026-11-25 before 02:30 (E0)"
awk '/^Start-Date: 2026-11-25  02:[012]/ {p=1} /^Start-Date: 2026-11-25  0(2:[3-5]|[3-9])/ {p=0} p' /var/log/apt/history.log | grep -E '^(Start-Date|Commandline|End-Date)' | cut -c1-200
echo "packages installed by dpkg between 02:04 and 02:13: $(grep -c -E '^2026-11-25 02:(0[4-9]|1[0-3]):[0-9]+ install ' /var/log/dpkg.log); upgraded: $(grep -c -E '^2026-11-25 02:(0[4-9]|1[0-3]):[0-9]+ upgrade ' /var/log/dpkg.log)"
echo "## the apt-daily run that held the dpkg lock at 02:04"
journalctl --no-pager -q -o short-iso --since "2026-11-25 02:04:00" --until "2026-11-25 02:04:20" -u apt-daily.service -u apt-daily.timer -u apt-daily-upgrade.timer -u unattended-upgrades.service 2> /dev/null | sed -E 's/ localhost / /' | cut -c1-150
echo "what it downloaded into the apt cache (files changed between 02:04:00 and 02:04:30):"
find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -newerct '2026-11-25 02:04:00' ! -newerct '2026-11-25 02:04:30' -printf '%f\n' | sort | sed -E 's/_[^_]*_(amd64|all)\.deb$//' | tr '\n' ' '; echo
find /var/cache/apt/archives -maxdepth 1 -name '*.deb' -newerct '2026-11-25 02:04:00' ! -newerct '2026-11-25 02:04:30' | wc -l | sed 's/^/count: /'
apt-cache policy linux-image-generic | grep -E 'Installed|Candidate' | tr -s ' ' | tr '\n' ';'; echo
dpkg-query -W -f='${Package} ${Version} ${Status}\n' linux-generic 2>&1; apt-mark showhold | grep -c -x linux-generic | sed 's/^/linux-generic held (1 = yes): /'
echo "## kexec-tools: what could load a kernel by itself"
debconf-show kexec-tools 2> /dev/null
cat /etc/default/kexec 2> /dev/null | grep -v '^#' | grep .
systemctl list-unit-files --no-legend --no-pager '*kexec*' | awk '{print $1, $2}' | tr '\n' ';'; echo
echo "## PVM modules: installed files against the package payload"
for m in kvm.ko kvm-pvm.ko; do cmp "/root/e0/x/lib/modules/6.8.0-139-generic/updates/pvm-oot/$m" "/lib/modules/6.8.0-139-generic/updates/pvm-oot/$m" && echo "$m: installed file is byte-identical to the file in the package"; done
sha256sum /root/e0/pvm-kmod.rpm | cut -c1-64
echo "## side effects of installing Docker and Kind in phase D"
for u in docker.service docker.socket containerd.service; do printf '%s enabled at boot: %s\n' "$u" "$(systemctl is-enabled "$u" 2> /dev/null | sed -n 1p)"; done
getent group docker | cut -d: -f1,3
stat -c '%y %n' /etc/group /etc/cni/net.d /opt/containerd /root/.kube/config /root/.kube/cache 2>&1 | cut -c1-19,36- 
kubectl config get-contexts --no-headers 2> /dev/null | wc -l | sed 's/^/kube contexts left: /'
echo "## files the cloud's boot helper rewrites at each boot (not changed by the experiments)"
stat -c '%y %n' /etc/fstab /etc/systemd/network/*.network 2>&1 | cut -c1-19,36-
echo "## boot files and E0's copies"
stat -c '%y %s %n' /etc/default/grub /root/e0/default-grub.orig /root/exp/E2/default-grub.before-pin /etc/grub.d/40_custom /root/e0/40_custom.orig 2>&1 | cut -c1-19,36-
cmp /root/e0/default-grub.orig /root/exp/E2/default-grub.before-pin && echo "E0's copy of /etc/default/grub equals the copy E2 took before pinning the default: nothing changed it in between"
