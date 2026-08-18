#!/usr/bin/env bash
# SC2034: every variable here is read by mkarchiso, not by this file.
# SC2154: the boot mode functions below read mkarchiso's globals, which exist
#         in the shell this file gets sourced into.
# shellcheck disable=SC2034,SC2154

iso_name="arcain"
iso_label="ARCAIN_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="cain <https://cainb.org>"
iso_application="arcain live/rescue/install medium"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arcain"
buildmodes=('iso')
bootmodes=('uefi.efistub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/usr/local/bin/arcain-install"]="0:0:755"
)

# ---------------------------------------------------------------------------
# Custom boot mode: uefi.efistub
#
# archiso has no EFI stub boot mode. It does not need one: mkarchiso sources
# this file into its own shell and then dispatches boot modes purely by
# function name, so defining the three functions below registers the mode:
#
#   _validate_requirements_bootmode_<name>   optional, warns if missing
#   _make_bootmode_<name>                    required, hard error if missing
#   _add_xorrisofs_options_<name>            optional
#
# By the time _make_bootmode_* runs, mkarchiso has installed the kernel and
# initramfs into ${pacstrap_dir}/boot, has not yet torn that tree down, and has
# set ${iso_uuid}. That is everything a unified kernel image needs.
#
# The globals used below — pacstrap_dir, work_dir, iso_uuid, efibootimg,
# pkg_list, bootmode, uefi_arch — all belong to mkarchiso. There is no
# ${boot_dir}: mkarchiso stages boot files under ${pacstrap_dir}/boot and
# copies them out to ${isofs_dir} in _make_boot_on_iso9660.
# ---------------------------------------------------------------------------

_validate_requirements_bootmode_uefi.efistub() {
    local tool

    if [[ ! -v uefi_arch["$arch"] ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': UEFI boot is not supported on the '${arch}' architecture!" 0
    fi

    # ukify: systemd-ukify. mkfs.fat: dosfstools. mmd/mcopy: mtools.
    for tool in ukify mkfs.fat mmd mcopy; do
        if ! command -v "${tool}" &>/dev/null; then
            (( validation_error=validation_error+1 ))
            _msg_error "Validating '${bootmode}': '${tool}' is not available on this host!" 0
        fi
    done

    # shellcheck disable=SC2076
    if [[ ! " ${pkg_list[*]} " =~ ' linux-zen ' ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': 'linux-zen' is not in the package list!" 0
    fi
}

_make_bootmode_uefi.efistub() {
    local _stub _cmdline _ukidir _efi_name

    _msg_info "Building unified kernel image for EFI stub booting..."

    _stub="${pacstrap_dir}/usr/lib/systemd/boot/efi/linux${uefi_arch[$arch],,}.efi.stub"
    [[ -e "${_stub}" ]] || _msg_error "EFI stub not found: ${_stub}" 1

    # An EFI stub is launched by the firmware with no command line, so the
    # command line has to be baked into the image as a .cmdline section.
    # archisosearchuuid matches the ISO 9660 modification date that mkarchiso
    # is about to stamp on this very image, so the hook finds its own medium
    # regardless of the volume label or the device it was written to.
    _cmdline="archisobasedir=${install_dir} archisosearchuuid=${iso_uuid}"

    _ukidir="${work_dir}/efistub"
    _efi_name="BOOT${uefi_arch[$arch]^^}.EFI"
    install -d -m 0755 -- "${_ukidir}/EFI/BOOT"

    ukify build \
        --linux="${pacstrap_dir}/boot/vmlinuz-linux-zen" \
        --initrd="${pacstrap_dir}/boot/initramfs-linux-zen.img" \
        --stub="${_stub}" \
        --cmdline="${_cmdline}" \
        --os-release="@${pacstrap_dir}/usr/lib/os-release" \
        --output="${_ukidir}/EFI/BOOT/${_efi_name}"

    # edk2-shell based UEFI shell. With a single hardcoded boot entry this is
    # the only way to boot with a modified command line: launch the UKI from
    # the shell and pass arguments, which systemd-stub reads from LoadOptions
    # and appends to the baked-in command line (ignored under Secure Boot).
    if [[ -e "${pacstrap_dir}/usr/share/edk2-shell/${uefi_arch[$arch],,}/Shell_Full.efi" ]]; then
        install -m 0644 -- "${pacstrap_dir}/usr/share/edk2-shell/${uefi_arch[$arch],,}/Shell_Full.efi" \
            "${_ukidir}/shell${uefi_arch[$arch],,}.efi"
    fi

    # Size and create the FAT image that becomes the EFI system partition,
    # then populate it. The kernel and initramfs are inside the UKI, so unlike
    # systemd-boot there is nothing else to copy: no _make_boot_on_fat.
    efiboot_files=("${_ukidir}/")
    _make_efibootimg
    mcopy -s -i "${efibootimg}" "${_ukidir}/EFI" '::/'
    if compgen -G "${_ukidir}/shell"*'.efi' >/dev/null; then
        mcopy -i "${efibootimg}" "${_ukidir}/shell"*'.efi' '::/'
    fi

    _msg_info "Done! EFI stub boot set up successfully."
}

_add_xorrisofs_options_uefi.efistub() {
    # Attaches efiboot.img as GPT partition 2 with the EFI system partition
    # type GUID and registers it as the El Torito UEFI boot image. Identical
    # wiring to the stock UEFI boot modes; only the payload differs.
    _add_common_xorrisofs_options_uefi
}
