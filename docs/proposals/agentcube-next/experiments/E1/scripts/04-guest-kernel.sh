#!/usr/bin/env bash
# E1 step 04: build the PVM guest kernel from the PVM project's kernel tree with
# its pinned config, using its build script. The result is left under
# /build/pvm/artifacts; step 05 puts it where Kata looks for it.
set -euo pipefail
GUEST_REPO=https://github.com/virt-pvm/linux
# Head of branch pvm-612 on 2026-11-25. The PVM project does not pin this commit.
GUEST_COMMIT=${GUEST_COMMIT:-9a5f15e83e894eeb4f8e56dbb146d325d405e754}
CTX=/build/pvm/context
OUT=/build/pvm/artifacts/vmlinux.pvm
JOBS=${PVM_JOBS:-$(nproc)}

tarball=/build/pvm/cache/linux-$GUEST_COMMIT.tar.gz
if [[ ! -s "$tarball" ]]; then
  curl -fL --retry 3 -sS -o "$tarball.part" "$GUEST_REPO/archive/$GUEST_COMMIT.tar.gz"
  mv "$tarball.part" "$tarball"
fi
echo "## source"
ls -l "$tarball" | awk '{print $5, $9}'
sha256sum "$tarball"
recorded=$(zcat "$tarball" 2>/dev/null | git get-tar-commit-id || true)
echo "commit recorded in the tarball: $recorded"
[[ "$recorded" == "$GUEST_COMMIT" ]]
rm -rf /build/pvm/src/guest && mkdir -p /build/pvm/src/guest
tar -C /build/pvm/src/guest --strip-components=1 -xzf "$tarball"
echo "kernel version of the tree: $(make -s -C /build/pvm/src/guest kernelversion)"

echo "## config (pinned by the PVM project, checksum verified by its script)"
"$CTX/scripts/guest/resolve-guest-config.sh" /build/pvm/configs/kata-guest.config
cat /build/pvm/configs/kata-guest.config.sha256 /build/pvm/configs/kata-guest.config.source

echo "## build (PVM project's scripts/guest/build-guest-kernel.sh, $JOBS jobs)"
start=$(date +%s)
if ! PVM_JOBS=$JOBS "$CTX/scripts/guest/build-guest-kernel.sh" /build/pvm/src/guest /build/pvm/configs/kata-guest.config "$OUT" \
    > /build/pvm/logs/guest-kernel-build.log 2>&1; then
  echo "build failed; last lines of the build log:"
  tail -40 /build/pvm/logs/guest-kernel-build.log
  exit 1
fi
echo "build seconds: $(( $(date +%s) - start ))"
grep -c -i 'warning:' /build/pvm/logs/guest-kernel-build.log | sed 's/^/compiler warnings in the build log: /' || true
tail -3 /build/pvm/logs/guest-kernel-build.log

echo "## result"
ls -l "$OUT" | awk '{print $5, $9}'
file -b "$OUT"
cat "$OUT.uname"
cat /build/pvm/artifacts/guest-kernel.sha256
cat /build/pvm/artifacts/guest-kernel.manifest
grep -E '^CONFIG_(PVM_GUEST|X86_PIE|RANDOMIZE_BASE|X86_5LEVEL|PARAVIRT|KVM_GUEST|LOCALVERSION|VIRTIO_FS|VIRTIO_BLK|VIRTIO_PMEM|FUSE_DAX)=' /build/pvm/build/guest-kernel/.config
