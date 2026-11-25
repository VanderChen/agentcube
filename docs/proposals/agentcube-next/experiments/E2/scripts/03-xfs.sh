#!/usr/bin/env bash
# E2 step 03: the installer requires /data/cubelet on XFS and the VM's only
# disk is ext4. Give it an XFS file system in a sparse file, mounted through a
# loop device. Not added to fstab: after a reboot it is simply not mounted.
set -euo pipefail
IMG=${IMG:-/var/lib/e2/cubelet.xfs}
SIZE=${SIZE:-120G}
if mountpoint -q /data/cubelet; then
  echo "/data/cubelet is already a mount point"
else
  install -d -m 0755 "$(dirname "$IMG")" /data/cubelet
  [[ -e "$IMG" ]] || truncate -s "$SIZE" "$IMG"
  blkid "$IMG" > /dev/null 2>&1 || mkfs.xfs -q -L e2cubelet "$IMG"
  mount -o loop,noatime "$IMG" /data/cubelet
fi
findmnt -n -o SOURCE,FSTYPE,OPTIONS /data/cubelet | cut -c1-160
df -hT /data/cubelet | tail -1
xfs_info /data/cubelet | grep -o -E '(reflink|crc|bigtime)=[0-9]' | tr '\n' ' '; echo
ls -ls "$IMG" | awk '{print "sparse file: allocated", $1, "KiB of", $6, "bytes"}'
grep -c cubelet /etc/fstab | sed 's/^/fstab entries mentioning cubelet: /' || true
