#!/usr/bin/env bash
# E2 step 04: download the one-click bundle, check it against the digest GitHub
# publishes for the release asset, unpack it, and show what it will use.
# Nothing is installed in this step.
set -euo pipefail
VERSION=${VERSION:-v0.8.0}
NAME=cube-sandbox-one-click-$VERSION-amd64.tar.gz
URL=https://github.com/TencentCloud/CubeSandbox/releases/download/$VERSION/$NAME
EXPECT_SHA256=${EXPECT_SHA256:?pass the digest GitHub shows for the asset}
DIR=/root/e2
install -d -m 0755 "$DIR"; cd "$DIR"
if [[ ! -s "$NAME" ]]; then
  curl -fL --retry 3 -sS -o "$NAME.part" "$URL"
  mv "$NAME.part" "$NAME"
fi
ls -l "$NAME" | awk '{print $5, $9}'
printf '%s  %s\n' "$EXPECT_SHA256" "$NAME" | sha256sum -c -
rm -rf "$DIR/bundle" && mkdir "$DIR/bundle"
tar -C "$DIR/bundle" -xzf "$NAME"
top=$(find "$DIR/bundle" -mindepth 1 -maxdepth 1 -type d | sed -n 1p)
echo "unpacked to: $top"
ln -sfn "$top" "$DIR/current"
cd "$top"
echo "## top level"; ls
echo "## release manifest and versions"
for f in VERSION version.txt release-manifest.json manifest.json; do [[ -f $f ]] && { echo "--- $f"; cut -c1-400 "$f" | sed -n '1,25p'; }; done
find . -maxdepth 3 -iname '*manifest*' -o -maxdepth 3 -iname 'VERSION*' | sed -n '1,12p'
echo "## image names and switches the installer defaults to (env.example)"
grep -n -E '^(#\s*)?(CUBE_PROXY_COREDNS_IMAGE|CUBE_SANDBOX_MYSQL_IMAGE|CUBE_SANDBOX_REDIS_IMAGE|WEB_UI_IMAGE|CUBE_SANDBOX_MINIO_IMAGE|CUBE_SANDBOX_CUBE_PROXY_IMAGE|CUBE_SANDBOX_CUBE_LCM_IMAGE|CUBE_SANDBOX_CUBE_EGRESS_IMAGE|MIRROR|CUBE_PVM_ENABLE|CUBE_SANDBOX_MINIO_ENABLED|ONE_CLICK_ENABLE_S3LVOL|CUBE_SANDBOX_NETWORK_CIDR|ONE_CLICK_DEPLOY_ROLE)=' env.example | cut -c1-200
echo "## every registry path that appears in the bundle's scripts"
grep -r -o -h -E '[a-z0-9.-]+\.tencentcloudcr\.com/[A-Za-z0-9_./-]+(:[A-Za-z0-9_.-]+)?' --include='*.sh' --include='*.example' --include='*.yaml' --include='*.template' --include='*.env' . 2>/dev/null | sort | uniq -c | sort -rn | sed -n '1,25p'
echo "## packaged payload"
find . -maxdepth 3 -type f -size +5M -printf '%s %p\n' | sort -rn | sed -n '1,15p'
du -sh . | cut -f1 | sed 's/^/unpacked size: /'
