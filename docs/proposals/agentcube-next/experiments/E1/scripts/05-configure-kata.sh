#!/usr/bin/env bash
# E1 step 05: put the PVM guest kernel where Kata looks for it and generate the
# three PVM configurations with the PVM project's script.
set -euo pipefail
CTX=/build/pvm/context
SRC=/build/pvm/artifacts/vmlinux.pvm
DST=/opt/kata/share/kata-containers/vmlinux.pvm

[[ -s "$SRC" && -d /opt/kata/share/kata-containers ]]
install -m 0644 "$SRC" "$DST"
install -m 0644 "$SRC.uname" "$DST.uname"
sha256sum "$SRC" "$DST"

echo "## generate (PVM project's scripts/kata/configure-pvm-runtime.sh)"
"$CTX/scripts/kata/configure-pvm-runtime.sh"

echo "## what it changed against the release's own configurations"
D=/opt/kata/share/defaults/kata-containers/runtime-rs
for pair in "qemu:configuration-qemu-runtime-rs.toml" "clh:configuration-clh-runtime-rs.toml" "dragonball:configuration-dragonball.toml"; do
  name=${pair%%:*}; base=${pair#*:}
  echo "--- $name: $base -> /etc/kata-containers/pvm/configuration-$name-pvm.toml"
  diff "$D/$base" "/etc/kata-containers/pvm/configuration-$name-pvm.toml" || true
done

echo "## settings that matter for PVM, as generated"
grep -H -n -E '^(path|kernel|image|initrd|firmware|machine_type|kernel_params|block_device_driver|vm_rootfs_driver|shared_fs|default_vcpus|default_memory|default_maxvcpus) =' /etc/kata-containers/pvm/*.toml | sed 's#/etc/kata-containers/pvm/##'
grep -H -n -i -E 'phys_bits|phyaddr|max_phys' /etc/kata-containers/pvm/*.toml | sed 's#/etc/kata-containers/pvm/##' || echo "no physical-address-width setting in the generated files"
