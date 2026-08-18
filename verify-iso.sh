#!/usr/bin/env bash
# verify-iso.sh — static checks on a built arcain ISO.
#
#   ./verify-iso.sh              check the newest ISO in ./out
#   ./verify-iso.sh -i foo.iso   check a specific image
#
# Everything here reads the finished image rather than the work directory, so
# what gets checked is the artifact that would actually be released. Nothing is
# booted; see test.sh for that.
#
# Exit status is the number of failed checks, so CI can gate on it directly.
# 125 means the script could not run at all.

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly project_dir

# Must match install_dir in profile/profiledef.sh.
readonly install_dir='arcain'

# Presence of any of these means a boot loader crept back into an image that is
# supposed to be EFI stub only, or that a deliberately dropped subsystem came
# back with a dependency.
readonly forbidden_packages=(
    grub syslinux refind memtest86+ memtest86+-efi archinstall linux
)

readonly deps=(
    'xorriso:libisoburn'
    'osirrox:libisoburn'
    'mdir:mtools'
    'mcopy:mtools'
    'fdisk:util-linux'
)

# GitHub's per-asset cap on a release.
readonly release_asset_limit=$(( 2 * 1024 * 1024 * 1024 ))

iso=''
iso_bytes=0
failed=0

msg() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()  { printf '   \033[1;32m ok \033[0m %s\n' "$*"; }
bad() { printf '   \033[1;31mFAIL\033[0m %s\n' "$*" >&2; failed=$(( failed + 1 )); }
die() { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; exit 125; }

while getopts 'i:h' opt; do
    case "${opt}" in
        i) iso="${OPTARG}" ;;
        h) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) exit 125 ;;
    esac
done

missing=()
for dep in "${deps[@]}"; do
    command -v "${dep%%:*}" &>/dev/null || missing+=("${dep##*:}")
done
(( ${#missing[@]} )) && die "missing host packages: ${missing[*]}"

if [[ -z "${iso}" ]]; then
    iso="$(find "${project_dir}/out" -maxdepth 1 -name 'arcain-*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2- || true)"
fi
[[ -f "${iso}" ]] || die 'no ISO found — run ./build.sh first'
iso="$(realpath -- "${iso}")"

tmp="$(mktemp -d -t arcain-verify.XXXXXX)"
trap 'rm -rf -- "${tmp}"' EXIT

msg "checking ${iso##*/} ($(du -h -- "${iso}" | cut -f1))"

# --- 1. the checksum sidecar build.sh wrote ---------------------------------
# It records a bare filename, so the check has to run from the ISO's directory.
if [[ -f "${iso}.sha256" ]]; then
    if (cd -- "${iso%/*}" && sha256sum -c --status -- "${iso##*/}.sha256"); then
        ok 'sha256 sidecar matches the image'
    else
        bad 'sha256 sidecar does not match the image'
    fi
else
    bad 'no .sha256 sidecar next to the image'
fi

# --- 2. it is a readable ISO 9660 image -------------------------------------
if xorriso -indev "${iso}" -toc >"${tmp}/toc.txt" 2>&1; then
    ok 'xorriso reads the image'
else
    bad 'xorriso cannot read the image'
fi

# --- 3. volume label ---------------------------------------------------------
# profiledef.sh builds it as ARCAIN_<YYYYMM>; the archiso hook does not depend
# on it (that is what archisosearchuuid is for) but a wrong label means
# profiledef.sh was edited without meaning to.
xorriso -indev "${iso}" -pvd_info >"${tmp}/pvd.txt" 2>&1 || true
if grep -q 'Volume Id.*ARCAIN_' "${tmp}/pvd.txt"; then
    ok "volume label $(grep -m1 'Volume Id' "${tmp}/pvd.txt" | sed 's/.*: *//')"
else
    bad 'volume label is not ARCAIN_*'
fi

# --- 4. El Torito: one UEFI image, no BIOS image ----------------------------
xorriso -indev "${iso}" -report_el_torito plain >"${tmp}/eltorito.txt" 2>&1 || true
uefi_imgs="$(grep -c 'boot img.*UEFI' "${tmp}/eltorito.txt" || true)"
bios_imgs="$(grep -c 'boot img.*BIOS' "${tmp}/eltorito.txt" || true)"
if (( uefi_imgs >= 1 )); then
    ok "El Torito carries ${uefi_imgs} UEFI boot image(s)"
else
    bad 'no UEFI El Torito boot image'
fi
if (( bios_imgs == 0 )); then
    ok 'no BIOS boot image (EFI stub only, as intended)'
else
    bad "${bios_imgs} BIOS boot image(s) present — bootmodes drifted"
fi

# --- 5. the appended GPT partition is an EFI system partition ---------------
if fdisk -l -- "${iso}" 2>/dev/null | grep -q 'EFI System'; then
    ok 'GPT advertises an EFI system partition'
else
    bad 'no EFI system partition in the partition table'
fi

# --- 6. the ESP actually contains the UKI at the fallback path --------------
osirrox -indev "${iso}" -extract_boot_images "${tmp}/boot/" >/dev/null 2>&1 || true
esp="$(find "${tmp}/boot" -type f \( -name '*uefi*.img' -o -name 'eltorito_img*' \) 2>/dev/null | head -1)"

if [[ -n "${esp}" ]] && mdir -/ -b -i "${esp}" '::/' >"${tmp}/esp.txt" 2>&1; then
    if grep -qi '/EFI/BOOT/BOOTX64.EFI' "${tmp}/esp.txt"; then
        ok 'ESP contains /EFI/BOOT/BOOTX64.EFI'
    else
        bad 'ESP has no /EFI/BOOT/BOOTX64.EFI — firmware would find nothing to run'
    fi
    if grep -qi '/shellx64.efi' "${tmp}/esp.txt"; then
        ok 'ESP contains shellx64.efi (the only route to a modified cmdline)'
    else
        bad 'ESP has no shellx64.efi — edk2-shell missing from the image'
    fi
else
    bad 'could not extract or read the El Torito EFI image'
    esp=''
fi

# --- 7. the command line is baked into the UKI ------------------------------
# Firmware passes none to an EFI stub, so a UKI without a .cmdline section
# boots into a kernel that cannot find its own medium.
if [[ -n "${esp}" ]] && mcopy -n -i "${esp}" '::/EFI/BOOT/BOOTX64.EFI' "${tmp}/uki.efi" 2>/dev/null; then
    if command -v ukify &>/dev/null && ukify inspect "${tmp}/uki.efi" >"${tmp}/uki.txt" 2>/dev/null; then
        src='ukify inspect'
    else
        # Fallback for hosts without systemd-ukify: read the strings straight
        # out of the PE file.
        grep -a -o 'archiso[a-z]*=[^[:space:]]*' "${tmp}/uki.efi" >"${tmp}/uki.txt" 2>/dev/null || true
        src='raw PE scan'
    fi
    for needle in "archisobasedir=${install_dir}" 'archisosearchuuid='; do
        if grep -qF "${needle}" "${tmp}/uki.txt"; then
            ok "UKI command line has ${needle} (${src})"
        else
            bad "UKI command line is missing ${needle}"
        fi
    done
else
    bad 'could not extract the UKI from the ESP'
fi

# --- 8. what actually got installed -----------------------------------------
if osirrox -indev "${iso}" -extract "/${install_dir}/pkglist.x86_64.txt" "${tmp}/pkglist.txt" \
        >/dev/null 2>&1 && [[ -s "${tmp}/pkglist.txt" ]]; then
    if grep -q '^linux-zen ' "${tmp}/pkglist.txt"; then
        ok "linux-zen $(grep -m1 '^linux-zen ' "${tmp}/pkglist.txt" | cut -d' ' -f2)"
    else
        bad 'linux-zen is not in the package list'
    fi
    for pkg in "${forbidden_packages[@]}"; do
        if grep -q "^${pkg} " "${tmp}/pkglist.txt"; then
            bad "package that should not be here: ${pkg}"
        fi
    done
    ok "$(wc -l < "${tmp}/pkglist.txt") packages on the image"
else
    bad "could not read /${install_dir}/pkglist.x86_64.txt from the image"
fi

# --- 9. release budget ------------------------------------------------------
# GitHub caps a single release asset at 2 GiB, and the CI release job uploads
# this file. Catching the overrun here names the cause; catching it in the
# release job just fails an upload after a full build.
iso_bytes="$(stat -c %s -- "${iso}")"
if (( iso_bytes < release_asset_limit )); then
    ok "$(( iso_bytes / 1048576 )) MiB, within the $(( release_asset_limit / 1073741824 )) GiB release asset limit"
else
    bad "$(( iso_bytes / 1048576 )) MiB exceeds GitHub's $(( release_asset_limit / 1073741824 )) GiB release asset limit"
fi

# --- verdict ----------------------------------------------------------------
if (( failed )); then
    printf '\n\033[1;31m::\033[0m %d check(s) failed\n' "${failed}" >&2
    exit "${failed}"
fi
msg 'all checks passed'
