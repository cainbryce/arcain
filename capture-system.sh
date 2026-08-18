#!/usr/bin/env bash
# capture-system.sh — snapshot this machine's /etc customizations into system/
#
#   ./capture-system.sh          capture into ./system
#   ./capture-system.sh -n       dry run, list what would be captured
#
# The dotfiles repo covers $HOME and nothing else, so every system-level tuning
# decision on this box lives only on the root filesystem. This pulls the ones
# that matter into the repo, where the installer can replay them onto a fresh
# install and git can keep history of them.
#
# SECRETS ARE NOT CAPTURED. NetworkManager connection profiles hold Wi-Fi PSKs
# in plaintext, /etc/shadow holds password hashes, and /etc/ssh holds host keys.
# None are copied. The installer prompts for those instead.

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly project_dir
readonly dest="${project_dir}/system"
dry=0

msg() { printf '\033[1;34m::\033[0m %s\n' "$*"; }

[[ "${1:-}" == '-n' ]] && dry=1

# Files copied verbatim into system/etc/... — paths are relative to /.
# Anything listed here that does not exist on this host is skipped quietly, so
# the same list works on a machine that has already been rebuilt from it.
readonly files=(
    # kernel + memory tuning
    etc/sysctl.d/99-cain-perf.conf
    etc/sysctl.d/99-watchdog.conf
    etc/systemd/zram-generator.conf

    # block layer + zram behaviour
    etc/udev/rules.d/30-zram.rules
    etc/udev/rules.d/60-nvme-scheduler.rules
    etc/udev/rules.d/99-openlinkhub.rules

    # GPU + capture devices
    etc/modprobe.d/nvidia.conf
    etc/modprobe.d/v4l2loopback.conf

    # realtime audio + gamemode privileges
    etc/security/limits.d/10-gamemode.conf
    etc/security/limits.d/20-audio.conf
    etc/security/limits.d/99-realtime-privileges.conf

    # build environment
    etc/makepkg.conf.d/99-cain-builddir.conf
    etc/makepkg.conf.d/rust.conf

    # initramfs + package manager
    etc/mkinitcpio.conf
    etc/pacman.conf

    # services written by hand
    etc/systemd/system/nvidia-power-limit.service
    etc/systemd/system/ollama.service
    etc/systemd/system/searxng-rama.service
    etc/systemd/system/searxng-rama.service.d/hardening.conf
    etc/systemd/system/searxng-rama.service.d/hardening-extra.conf

    # process scheduling
    etc/ananicy.d/99-cain-dev.rules

    # snapshots
    etc/snapper/configs/root

    # file sharing (iPhone/SMB3)
    etc/samba/smb.conf

    # locale + console
    etc/locale.conf
    etc/vconsole.conf
    etc/locale.gen

    # local scripts
    usr/local/bin/mkinitcpio
    usr/local/bin/pacman-remove-orphans
    usr/local/bin/phone-vnc-firewall
    usr/local/bin/remove-nvidia
)

capture_file() {
    local src="/$1" out="${dest}/$1"
    [[ -e "${src}" ]] || return 0
    if (( dry )); then printf '  %s\n' "$1"; return 0; fi
    install -Dm644 -- "${src}" "${out}"
}

capture_generated() {
    # State that lives in a database rather than a file, re-derived on capture.
    local out="${dest}/generated"
    (( dry )) && { printf '  generated/{packages,ufw-rules,units,identity}\n'; return 0; }
    install -d -m 755 -- "${out}"

    # Explicitly-installed packages only; dependencies come back on their own.
    pacman -Qqen > "${out}/packages-repo.txt"
    pacman -Qqem > "${out}/packages-aur.txt"

    # ufw's own files are binary-ish and version-coupled; the rule list is not.
    if command -v ufw &>/dev/null; then
        sudo ufw status numbered > "${out}/ufw-rules.txt" 2>/dev/null || true
    fi

    # Enabled units, so the installer knows what to `systemctl enable`.
    systemctl list-unit-files --state=enabled --no-pager --no-legend \
        | awk '{print $1}' > "${out}/units-system.txt"
    systemctl --user list-unit-files --state=enabled --no-pager --no-legend \
        | awk '{print $1}' > "${out}/units-user.txt"

    # Machine identity that is not worth a file each.
    {
        printf 'hostname=%s\n' "$(hostnamectl --static)"
        printf 'timezone=%s\n' "$(timedatectl show -p Timezone --value)"
        printf 'user=%s\n' "$(id -un 1000)"
        printf 'shell=%s\n' "$(getent passwd 1000 | cut -d: -f7)"
        printf 'groups=%s\n' "$(id -Gn 1000 | tr ' ' ',')"
    } > "${out}/identity.txt"
}

(( dry )) && msg 'dry run — would capture:'
for f in "${files[@]}"; do capture_file "${f}"; done
capture_generated

if (( dry )); then
    exit 0
fi

msg "captured $(find "${dest}" -type f | wc -l) files into system/"
printf '   repo packages: %s   AUR: %s\n' \
    "$(wc -l < "${dest}/generated/packages-repo.txt")" \
    "$(wc -l < "${dest}/generated/packages-aur.txt")"
printf '   NOT captured (secrets): NetworkManager profiles, shadow, ssh host keys\n'
