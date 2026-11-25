#!/usr/bin/env bash
# E1 step 03: install the Firecracker release the PVM project tests against.
# Firecracker is used here only for the PVM project's direct-boot check, not as a Kata hypervisor.
set -euo pipefail
CTX=/build/pvm/context
# shellcheck source=/dev/null
source "$CTX/configs/ubuntu-24.04-basic.env"
echo "FIRECRACKER_VERSION=$FIRECRACKER_VERSION"
echo "FIRECRACKER_ARCHIVE_URL=$FIRECRACKER_ARCHIVE_URL"
echo "FIRECRACKER_ARCHIVE_SHA256=$FIRECRACKER_ARCHIVE_SHA256"

archive=/build/pvm/cache/$(basename "$FIRECRACKER_ARCHIVE_URL")
if [[ ! -s "$archive" ]]; then
  curl -fL --retry 3 -sS -o "$archive.part" "$FIRECRACKER_ARCHIVE_URL"
  mv "$archive.part" "$archive"
fi
ls -l "$archive" | awk '{print $5, $9}'
printf '%s  %s\n' "$FIRECRACKER_ARCHIVE_SHA256" "$archive" | sha256sum -c -
"$CTX/scripts/firecracker/install-firecracker.sh" "$archive" "$FIRECRACKER_VERSION"
sha256sum /usr/local/bin/firecracker
