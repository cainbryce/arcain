#!/usr/bin/env bash
# filter-manifests.sh — derive pure-Arch install manifests from the captured state.
#
#   ./tools/filter-manifests.sh          write system/derived/
#
# system/generated/ is what IS installed on the donor machine, which runs
# CachyOS. The installed system will be pure Arch with linux-zen and no boot
# loader, so the captured lists cannot be replayed as-is. This encodes the
# mapping once, instead of re-deriving it by hand at install time:
#
#   - cachyos-* packaging, branding, mirrorlists, chwd, kernel manager: dropped
#   - linux-cachyos* kernels: replaced by linux-zen + headers + nvidia-open-dkms
#   - limine-*: dropped, the installed system boots an EFI stub UKI
#   - wine-cachyos*/proton-cachyos*: wine-staging (repo) + proton-ge-custom-bin (AUR)
#   - hypr*-git AUR packages: dropped, the desktop moves to river-classic
#   - everything else explicitly installed: kept, classified repo vs AUR
#     against the live core/extra/multilib databases
#
# Units get the same treatment: cachyos and limine units go, the USB-root
# workaround mounts go (docs/LAYOUT.md deletes them), NetworkManager stays
# (the ISO uses iwd+networkd, the installed desktop keeps NetworkManager).
#
# Output lands in system/derived/, which .gitattributes routes through
# git-crypt like the rest of system/.

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly project_dir
readonly gen="${project_dir}/system/generated"
readonly out="${project_dir}/system/derived"

msg() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; exit 1; }

[[ -r "${gen}/packages-repo.txt" ]] || die "no ${gen}/packages-repo.txt — is system/ locked?"
# git-crypt ciphertext starts \0GITCRYPT; a locked checkout must not be filtered.
head -c 9 "${gen}/packages-repo.txt" | grep -q 'GITCRYPT' && die 'system/ is git-crypt locked — unlock first'

command -v pacman &>/dev/null || die 'needs pacman to classify repo vs AUR'

install -d -m 755 -- "${out}"

# Names that exist in the pure-Arch repos, from the live sync DBs. CachyOS
# repos deliberately excluded from the classification.
arch_names="$(mktemp)"
trap 'rm -f -- "${arch_names}"' EXIT
pacman -Sl core extra multilib 2>/dev/null | awk '{print $2}' | sort -u > "${arch_names}"
[[ -s "${arch_names}" ]] || die 'pacman -Sl returned nothing — sync databases missing?'

# --- classification -----------------------------------------------------------
drop_re='^(cachyos-|chwd$|cachy-chroot$|iloader$|scx-manager$|gamescope-session-cachyos$|limine-)'
kernel_re='^linux-cachyos'
wine_re='^(wine-cachyos|proton-cachyos)'
# Everything hypr-prefixed in the AUR list goes, -git or not (hyprvoice-bin).
# hyprpolkitagent survives on its own: it is in extra, so it never reaches
# this AUR classification.
hypr_re='^(hypr|aquamarine-git$)'

declare -a repo_pkgs aur_pkgs dropped
repo_pkgs=() aur_pkgs=() dropped=()

while read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    if   [[ "${pkg}" =~ ${kernel_re} ]] || [[ "${pkg}" =~ ${drop_re} ]] \
      || [[ "${pkg}" =~ ${wine_re} ]]; then
        dropped+=("${pkg}")
    elif grep -qxF "${pkg}" "${arch_names}"; then
        repo_pkgs+=("${pkg}")
    else
        aur_pkgs+=("${pkg}")
    fi
done < "${gen}/packages-repo.txt"

# Replacements for what the mappings removed. Deduplicated on output, so a
# package already present in the captured list is harmless here.
repo_pkgs+=(linux-zen linux-zen-headers nvidia-open-dkms wine-staging)
aur_pkgs+=(proton-ge-custom-bin)

while read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    if [[ "${pkg}" =~ ${hypr_re} ]]; then
        dropped+=("${pkg}")
    else
        aur_pkgs+=("${pkg}")
    fi
done < "${gen}/packages-aur.txt"

printf '%s\n' "${repo_pkgs[@]}" | sort -u > "${out}/packages-repo.txt"
printf '%s\n' "${aur_pkgs[@]}"  | sort -u > "${out}/packages-aur.txt"
printf '%s\n' "${dropped[@]}"   | sort -u > "${out}/packages-dropped.txt"

# --- units --------------------------------------------------------------------
# scx_loader: sched-ext schedulers need a sched-ext kernel, which is a
# CachyOS patch set — linux-zen has no sched-ext, the service can never
# start. snapper-cleanup: arcain-snap prunes its own snapshots.
unit_drop_re='^(cachyos-|limine-|home-cain-\.cache\.mount|usr-share-fonts\.mount|scx_loader\.service|snapper-cleanup\.timer)'
grep -vE "${unit_drop_re}" "${gen}/units-system.txt" > "${out}/units-system.txt"
cp -- "${gen}/units-user.txt" "${out}/units-user.txt"

# arcain-snap replaces snapper on the installed system.
printf '%s\n' 'arcain-snap-timeline.timer' 'arcain-snap-backup.timer' >> "${out}/units-system.txt"
sort -u -o "${out}/units-system.txt" "${out}/units-system.txt"

msg "derived manifests in system/derived/"
printf '   repo: %s   aur: %s   dropped: %s   units: %s\n' \
    "$(wc -l < "${out}/packages-repo.txt")" \
    "$(wc -l < "${out}/packages-aur.txt")" \
    "$(wc -l < "${out}/packages-dropped.txt")" \
    "$(wc -l < "${out}/units-system.txt")"
printf '   dropped (verify nothing surprising): %s\n' \
    "$(paste -sd' ' "${out}/packages-dropped.txt" | cut -c1-120)..."
