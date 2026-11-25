#!/usr/bin/env bash
# E4 step 07: a second set of Kata configurations that use CubeSandbox's PVM
# guest kernel instead of the PVM project's, generated with the PVM project's
# script into its own directory. The E1 configurations are not touched.
# This is not a combination anybody documents; it is tried because step 06
# showed that this guest kernel boots the Kata guest image under Firecracker
# on CubeSandbox's host kernel.
set -euo pipefail
K=/usr/local/services/cubetoolbox/cube-kernel-scf/vmlinux-pvm
D=/etc/kata-containers/pvm-cube-guest
PVM_GUEST_KERNEL=$K KATA_CONFIG_DIR=$D /build/pvm/context/scripts/kata/configure-pvm-runtime.sh
strings "$K" | grep -m1 -E '^Linux version ' | cut -c1-120
ls -l "$D" | awk 'NR>1 {print $5, $9}'
