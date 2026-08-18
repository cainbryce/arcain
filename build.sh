#!/usr/bin/env bash
# Build the arcain ISO.
#
#   ./build.sh            build into ./out, work dir ./work
#   ./build.sh -c         remove ./work and ./out first
#   ./build.sh -o /path   write the ISO somewhere else
#
# mkarchiso needs root: it pacstraps a full system, makes device nodes, and
# runs mkinitcpio inside the chroot. Everything else here runs as the invoking
# user so the ISO and checksums are not left owned by root.

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly project_dir
readonly profile_dir="${project_dir}/profile"
work_dir="${project_dir}/work"
out_dir="${project_dir}/out"
clean=0

readonly host_deps=(
    'mkarchiso:archiso'
    'ukify:systemd-ukify'
    'mkfs.fat:dosfstools'
    'mcopy:mtools'
    'xorriso:libisoburn'
)

msg()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; exit 1; }

while getopts 'co:w:h' opt; do
    case "${opt}" in
        c) clean=1 ;;
        o) out_dir="$(realpath -m -- "${OPTARG}")" ;;
        w) work_dir="$(realpath -m -- "${OPTARG}")" ;;
        h) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) exit 1 ;;
    esac
done

# --- privilege --------------------------------------------------------------
# Interactively that means sudo. In CI the build already runs as root inside a
# container image that ships no sudo at all, so escalation has to be a no-op
# there rather than a missing command.
if (( EUID == 0 )); then
    as_root=()
else
    command -v sudo &>/dev/null || die 'not running as root and sudo is not installed'
    as_root=(sudo)
fi
readonly as_root

# --- host dependencies ------------------------------------------------------
missing=()
for dep in "${host_deps[@]}"; do
    command -v "${dep%%:*}" &>/dev/null || missing+=("${dep##*:}")
done
(( ${#missing[@]} )) && die "missing host packages: ${missing[*]}
install with: sudo pacman -S ${missing[*]}"

# --- work dir ---------------------------------------------------------------
if (( clean )); then
    msg "removing ${work_dir} and ${out_dir}"
    "${as_root[@]}" rm -rf -- "${work_dir}" "${out_dir}"
fi
mkdir -p -- "${work_dir}" "${out_dir}"

# The work dir churns through a full pacstrap plus a squashfs pass every build.
# On btrfs that is worst-case copy-on-write fragmentation, so mark it nodatacow.
# chattr +C only takes effect on files created after the flag is set, which is
# why this runs before mkarchiso puts anything in there.
if [[ "$(stat -f -c %T -- "${work_dir}")" == 'btrfs' ]]; then
    if chattr +C -- "${work_dir}" 2>/dev/null; then
        msg "work dir marked nodatacow (btrfs)"
    else
        msg "warning: could not set +C on ${work_dir}"
    fi
fi

# --- build ------------------------------------------------------------------
msg "building from ${profile_dir}"
start=${SECONDS}
"${as_root[@]}" mkarchiso -v -w "${work_dir}" -o "${out_dir}" -- "${profile_dir}"
"${as_root[@]}" chown -R -- "$(id -u):$(id -g)" "${out_dir}"

iso="$(find "${out_dir}" -maxdepth 1 -name 'arcain-*.iso' -printf '%T@ %p\n' \
    | sort -rn | head -1 | cut -d' ' -f2-)"
[[ -n "${iso}" ]] || die "build finished but no ISO found in ${out_dir}"

# --- verify -----------------------------------------------------------------
# This box has a documented history of silent corruption on large writes, so an
# ISO is not trusted until it has been read back off the platter. iflag=direct
# bypasses the page cache, otherwise the read is answered from RAM and proves
# nothing about what actually landed on disk.
msg "verifying ${iso##*/} (O_DIRECT read-back)"
written="$(sha256sum -- "${iso}" | cut -d' ' -f1)"
if readback="$(dd if="${iso}" bs=1M iflag=direct status=none | sha256sum | cut -d' ' -f1)"; then
    [[ "${written}" == "${readback}" ]] \
        || die "CHECKSUM MISMATCH — the ISO on disk differs from what was written.
  page cache: ${written}
  disk:       ${readback}
Do not write this image to a USB stick. Rebuild and check dmesg."
    verdict='sha256 verified against an uncached read'
else
    # Not every filesystem implements O_DIRECT — overlayfs in a CI container,
    # tmpfs, some network mounts. Failing to read is not the same as reading
    # something different, so this warns rather than aborting; the integrity
    # claim is simply void for that build.
    printf '\033[1;33m::\033[0m %s\n' \
        'O_DIRECT read-back is unsupported here — ISO integrity NOT verified' >&2
    verdict='sha256 computed from cache only — NOT verified against disk'
fi

printf '%s  %s\n' "${written}" "${iso##*/}" > "${iso}.sha256"

msg "done in $(( (SECONDS - start) / 60 ))m$(( (SECONDS - start) % 60 ))s"
printf '   %s  (%s)\n' "${iso}" "$(du -h -- "${iso}" | cut -f1)"
printf '   %s\n' "${verdict}"
printf '\n   test:  ./test.sh\n   write: sudo dd if=%s of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync\n' "${iso}"
