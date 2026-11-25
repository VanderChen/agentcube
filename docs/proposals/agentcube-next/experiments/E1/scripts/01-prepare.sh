#!/usr/bin/env bash
# E1 step 01: build dependencies, and the PVM project's scripts at a pinned commit.
set -euo pipefail
PVM_CONTEXT_REPO=https://github.com/virt-pvm/pvm-context
PVM_CONTEXT_COMMIT=${PVM_CONTEXT_COMMIT:-276edd0cb249ac2ad892e9296f9e566a8db3bd97}

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
# The list is the PVM project's scripts/guest/prepare-ubuntu-24.04.sh, without
# containerd and rpm2cpio (already installed) and without linux-headers-generic
# (the kernel meta packages are held on this VM).
packages=(bc bison build-essential busybox-static curl dwarves file flex git jq kmod
  libelf-dev libssl-dev cpio pkg-config python3 rsync tar xz-utils zstd)

echo "## apt: what this install will change"
apt-get -o DPkg::Lock::Timeout=120 update -qq
apt-get -s install --no-install-recommends "${packages[@]}" | grep -E '^(Inst|Remv) ' | awk '{print $1, $2, $3, $4}' | sort > /tmp/e1-apt-plan.txt || true
grep -c '^Inst' /tmp/e1-apt-plan.txt | sed 's/^/packages to install or upgrade: /' || true
grep -c '^Remv' /tmp/e1-apt-plan.txt | sed 's/^/packages to remove: /' || true
echo "upgrades of packages that are already installed:"
while read -r _ name _; do
  dpkg-query -W -f='${Status}\n' "$name" 2>/dev/null | grep -q 'install ok installed' && grep -E "^Inst $name " /tmp/e1-apt-plan.txt
done < /tmp/e1-apt-plan.txt || true
echo "(end of upgrades)"
if grep -E '^(Inst|Remv) linux-(image|modules|headers)' /tmp/e1-apt-plan.txt; then
  echo "the plan touches kernel packages; stopping"; exit 1
fi

echo "## apt: install"
apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends "${packages[@]}" > /tmp/e1-apt-install.log 2>&1 || { tail -30 /tmp/e1-apt-install.log; exit 1; }
tail -3 /tmp/e1-apt-install.log
gcc --version | sed -n 1p; make --version | sed -n 1p; pahole --version; busybox | sed -n 1p
apt-mark showhold | tr '\n' ' '; echo
echo "## apt: last transaction in the apt history (the package list of this step when it installed anything)"
awk '/^Start-Date/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' /var/log/apt/history.log | fold -w 200

echo "## boot configuration is unchanged"
awk '/^menuentry /{n++} n==1 && /^[[:space:]]*linux[[:space:]]/{print; exit}' /boot/grub/grub.cfg | sed 's/^[[:space:]]*/entry 0: /'
grep -E '^GRUB_DEFAULT=' /etc/default/grub

echo "## PVM project scripts"
install -d -m 0755 /build/pvm/{artifacts,build,cache,logs,src,configs}
tarball=/build/pvm/cache/pvm-context-$PVM_CONTEXT_COMMIT.tar.gz
if [[ ! -s "$tarball" ]]; then
  curl -fsSL --retry 3 -o "$tarball.part" "$PVM_CONTEXT_REPO/archive/$PVM_CONTEXT_COMMIT.tar.gz"
  mv "$tarball.part" "$tarball"
fi
sha256sum "$tarball"
recorded=$(zcat "$tarball" 2>/dev/null | git get-tar-commit-id || true)
echo "commit recorded in the tarball: $recorded"
[[ "$recorded" == "$PVM_CONTEXT_COMMIT" ]]
rm -rf /build/pvm/context && mkdir /build/pvm/context
tar -C /build/pvm/context --strip-components=1 -xzf "$tarball"
ls /build/pvm/context /build/pvm/context/scripts
echo "## pins the PVM project uses"
cat /build/pvm/context/pins/guest-config.env
grep -E '^(KATA_VERSION|KATA_ARCHIVE_URL|KATA_ARCHIVE_SHA256|FIRECRACKER_VERSION|FIRECRACKER_ARCHIVE_URL|FIRECRACKER_ARCHIVE_SHA256|PVM_HOST_CMDLINE)=' /build/pvm/context/configs/ubuntu-24.04-basic.env
