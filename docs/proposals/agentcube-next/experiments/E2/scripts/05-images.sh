#!/usr/bin/env bash
# E2 step 05: make the base images the installer starts with docker available
# locally. Preflight showed that the registry they default to cannot be reached
# from this VM. For each image: use it if it is already present; else try the
# original name; else pull the same upstream image from Docker Hub and tag it
# with the name the installer expects.
set -uo pipefail
ENVFILE=${ENVFILE:-/root/e2/current/env.example}
hub_name() {
  case "$1" in
    */opensource/coredns/coredns:*) echo "docker.io/coredns/coredns:${1##*:}" ;;
    */opensource/mysql:*)           echo "docker.io/library/mysql:${1##*:}" ;;
    */opensource/redis:*)           echo "docker.io/library/redis:${1##*:}" ;;
    */opensource/openresty:*)       echo "docker.io/openresty/openresty:${1##*:}" ;;
    *) echo "" ;;
  esac
}
rc=0
for var in CUBE_PROXY_COREDNS_IMAGE CUBE_SANDBOX_MYSQL_IMAGE CUBE_SANDBOX_REDIS_IMAGE WEB_UI_IMAGE; do
  want=$(sed -n "s/^$var=//p" "$ENVFILE" | sed -n 1p)
  echo "== $var=$want"
  [[ -n "$want" ]] || { echo "not set in $ENVFILE"; rc=1; continue; }
  if docker image inspect "$want" > /dev/null 2>&1; then
    echo "already present"
  elif timeout 60 docker pull -q "$want" > /tmp/e2-pull.out 2>&1; then
    echo "pulled from the original registry"
  else
    echo "original registry: $(tr '\n' ' ' < /tmp/e2-pull.out | cut -c1-160) (or timed out after 60 s)"
    alt=$(hub_name "$want")
    [[ -n "$alt" ]] || { echo "no Docker Hub equivalent known"; rc=1; continue; }
    if timeout 300 docker pull -q "$alt" > /tmp/e2-pull.out 2>&1; then
      docker tag "$alt" "$want"
      echo "pulled $alt and tagged it as the expected name"
      docker image inspect "$alt" --format '  source digest: {{join .RepoDigests " "}}'
    else
      echo "Docker Hub: $(tr '\n' ' ' < /tmp/e2-pull.out | cut -c1-200)"; rc=1; continue
    fi
  fi
  docker image inspect "$want" --format '  id: {{.Id}}  created: {{.Created}}  size: {{.Size}}'
done
echo "## images now"
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | sort
exit "$rc"
