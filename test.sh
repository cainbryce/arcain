#!/usr/bin/env bash
# Boot the most recent arcain ISO in QEMU under OVMF.
#
#   ./test.sh                 boot the live environment
#   ./test.sh -d              attach ./scratch.qcow2 (40G, created on demand)
#                             so an install can be rehearsed end to end
#   ./test.sh -s              enable Secure Boot — expected to FAIL, the UKI
#                             is unsigned; run it to see what that looks like
#   ./test.sh -i foo.iso      boot a specific image
#   ./test.sh -m 8G -c 6      RAM / cores
#
# No BIOS mode: this profile builds no BIOS boot mode, so a BIOS test would
# just hang on "no bootable device" and prove nothing.
#
# This drives qemu directly rather than calling archiso's run_archiso, which
# has no way to attach a scratch disk (its -d flag switches the ISO itself
# from cdrom to hd emulation) and hardcodes 3 GB of RAM.

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly project_dir
readonly ovmf_code='/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd'
readonly ovmf_vars='/usr/share/edk2/x64/OVMF_VARS.4m.fd'

iso=''
disk=''
mem='4G'
cores=4
secureboot=0

die() { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; exit 1; }

while getopts 'i:dm:c:sh' opt; do
    case "${opt}" in
        i) iso="${OPTARG}" ;;
        d) disk="${project_dir}/scratch.qcow2" ;;
        m) mem="${OPTARG}" ;;
        c) cores="${OPTARG}" ;;
        s) secureboot=1 ;;
        h) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) exit 1 ;;
    esac
done

if [[ -z "${iso}" ]]; then
    # '|| true': find exits non-zero when out/ does not exist yet, and under
    # 'set -e' with pipefail that aborts the script silently instead of falling
    # through to the "run ./build.sh first" message below.
    iso="$(find "${project_dir}/out" -maxdepth 1 -name 'arcain-*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2- || true)"
fi
[[ -f "${iso}" ]] || die "no ISO found — run ./build.sh first"
command -v qemu-system-x86_64 &>/dev/null || die "qemu-system-x86_64 not found — install 'qemu-desktop'"
[[ -f "${ovmf_code}" ]] || die "${ovmf_code} not found — install 'edk2-ovmf'"

# OVMF variables are per-VM writable state (boot entries, Secure Boot keys),
# so each run gets a throwaway copy of the pristine template.
vars_copy="$(mktemp -t arcain-ovmf-vars.XXXXXX.fd)"
trap 'rm -f -- "${vars_copy}"' EXIT
cp -- "${ovmf_vars}" "${vars_copy}"

qemu_args=(
    -machine 'type=q35,smm=on,accel=kvm'
    -cpu host
    -smp "${cores}"
    -m "${mem}"
    -name 'arcain,process=arcain'
    -global 'ICH9-LPC.disable_s3=1'
    -vga virtio
    -display sdl
    -device qemu-xhci -device usb-kbd -device usb-tablet
    -device 'virtio-net-pci,romfile=,netdev=net0'
    -netdev 'user,id=net0,hostfwd=tcp::60022-:22'
    -device 'virtio-scsi-pci,id=scsi0'
    -device 'scsi-cd,bus=scsi0.0,drive=cd0'
    -drive "id=cd0,if=none,format=raw,media=cdrom,read-only=on,file=${iso}"
    -boot 'order=d,menu=on,reboot-timeout=5000'
    -serial stdio
    -no-reboot
    -drive "if=pflash,format=raw,unit=0,file=${ovmf_code},read-only=on"
    -drive "if=pflash,format=raw,unit=1,file=${vars_copy}"
)

if (( secureboot )); then
    printf ':: Secure Boot ON — the UKI is unsigned, firmware should reject it\n'
    qemu_args+=(-global 'driver=cfi.pflash01,property=secure,value=on')
else
    qemu_args+=(-global 'driver=cfi.pflash01,property=secure,value=off')
fi

if [[ -n "${disk}" ]]; then
    [[ -f "${disk}" ]] || { printf ':: creating %s\n' "${disk##*/}"; qemu-img create -f qcow2 -- "${disk}" 40G; }
    qemu_args+=(
        -device 'scsi-hd,bus=scsi0.0,drive=hd0'
        -drive "id=hd0,if=none,format=qcow2,file=${disk}"
    )
fi

printf ':: booting %s (%s, %s cores)\n' "${iso##*/}" "${mem}" "${cores}"
exec qemu-system-x86_64 "${qemu_args[@]}"
