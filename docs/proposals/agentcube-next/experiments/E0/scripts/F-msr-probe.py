# Copyright The Volcano Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# E0 supplementary probe F, exactly as it ran on the VM at 2026-11-25T02:28:04Z (python3, as root).
# Extracted from commands-as-run.txt so that it can be read and reused as a file.
# It creates a VM and one vCPU, runs no guest code, and reads and writes a few MSRs through KVM.
import fcntl, os, struct, errno
KVM_CREATE_VM, KVM_CREATE_VCPU = 0xAE01, 0xAE41
KVM_GET_MSR_INDEX_LIST, KVM_GET_MSR_FEATURE_INDEX_LIST = 0xC004AE02, 0xC004AE0A
KVM_GET_MSRS, KVM_SET_MSRS = 0xC008AE88, 0x4008AE89
kvm = os.open("/dev/kvm", os.O_RDWR)
def index_list(code):
    n = 2048
    buf = bytearray(struct.pack("I", n) + bytes(4 * n))
    fcntl.ioctl(kvm, code, buf)
    cnt = struct.unpack_from("I", buf)[0]
    return list(struct.unpack_from("%dI" % cnt, buf, 4))
lst = index_list(KVM_GET_MSR_INDEX_LIST)
feat = index_list(KVM_GET_MSR_FEATURE_INDEX_LIST)
print("KVM_GET_MSR_INDEX_LIST: %d MSRs; contains 0x3a: %s" % (len(lst), 0x3a in lst))
print("KVM_GET_MSR_FEATURE_INDEX_LIST: %d MSRs; contains 0x3a: %s" % (len(feat), 0x3a in feat))
vm = fcntl.ioctl(kvm, KVM_CREATE_VM, 0)
vcpu = fcntl.ioctl(vm, KVM_CREATE_VCPU, 0)
def get(idx):
    buf = bytearray(struct.pack("II", 1, 0) + struct.pack("IIQ", idx, 0, 0))
    try:
        n = fcntl.ioctl(vcpu, KVM_GET_MSRS, buf)
    except OSError as e:
        return "errno=%s" % errno.errorcode.get(e.errno, e.errno), None
    return n, struct.unpack_from("Q", buf, 16)[0]
def put(idx, val):
    buf = bytearray(struct.pack("II", 1, 0) + struct.pack("IIQ", idx, 0, val))
    try:
        return fcntl.ioctl(vcpu, KVM_SET_MSRS, buf)
    except OSError as e:
        return "errno=%s" % errno.errorcode.get(e.errno, e.errno)
print("columns: msr | in index list | GET processed (1 = ok) | value | SET same value back, processed (1 = accepted, 0 = rejected)")
for name, idx in [("IA32_FEATURE_CONTROL 0x3a", 0x3a), ("control: IA32_TSC 0x10", 0x10), ("control: EFER 0xc0000080", 0xC0000080), ("control: STAR 0xc0000081", 0xC0000081), ("control: IA32_APICBASE 0x1b", 0x1B)]:
    n, val = get(idx)
    back = put(idx, val) if val is not None and n == 1 else "skipped"
    print("%-28s | %-5s | %s | %s | %s" % (name, idx in lst, n, "-" if val is None else hex(val), back))
n0 = put(0x3a, 0)
print("SET 0x3a = 0 explicitly, processed:", n0)
os.close(vcpu); os.close(vm); os.close(kvm)
print("closed")
