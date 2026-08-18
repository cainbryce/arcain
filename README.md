# arcain

A custom Arch Linux ISO: pure Arch, `linux-zen` only, EFI stub boot only.

Personal install medium, rescue toolkit, and portable workstation in one image.
Built with `mkarchiso` from a fork of the upstream `releng` profile.

```sh
sudo pacman -S archiso systemd-ukify qemu-desktop edk2-ovmf mtools
./build.sh          # -> out/arcain-YYYY.MM.DD-x86_64.iso
./test.sh           # boot it in QEMU under OVMF
./test.sh -d        # ...with a scratch disk, to rehearse an install
```

## What "EFI stub only" means here

There is no bootloader on this image. No syslinux, no GRUB, no systemd-boot.
Firmware loads a single Unified Kernel Image — a PE binary containing the
kernel, the initramfs, and the kernel command line in one file — from
`\EFI\BOOT\BOOTX64.EFI` on the El Torito EFI system partition.

**archiso has no `uefi.efistub` boot mode.** Verified against archiso 89; the
complete set is `bios.syslinux{,.eltorito,.mbr}`, `uefi.grub`,
`uefi.systemd-boot`, plus deprecated aliases that only `return 1`.

This profile adds the boot mode itself. `mkarchiso` *sources* `profiledef.sh`
into its own shell and then dispatches boot modes purely by function name:

| function | role | missing |
| --- | --- | --- |
| `_validate_requirements_bootmode_<name>` | host dependency checks | warning |
| `_make_bootmode_<name>` | build the boot files | hard error |
| `_add_xorrisofs_options_<name>` | ISO layout options | silently skipped |

So defining `_make_bootmode_uefi.efistub` in `profiledef.sh` registers the mode.
That is an extension point, not a hack — but it is an *undocumented* one, so a
future archiso release can break it. `profiledef.sh` is where to look first if a
build starts failing after an `archiso` upgrade.

### Why the UKI is built on the host, not in the chroot

The command line has to be baked in, because firmware passes none to an EFI
stub. archiso finds its own medium with `archisosearchuuid=`, whose value is the
ISO 9660 modification date that `mkarchiso` stamps at image creation time —
unknowable from inside the pacstrap chroot.

`_make_bootmode_*` runs at exactly the right moment: after `_make_packages`
(so `${pacstrap_dir}/boot` holds the kernel and initramfs), before
`_cleanup_pacstrap_dir` (so that tree still has `linuxx64.efi.stub` too), and
after `iso_uuid` is set. So the profile reuses
releng's exact known-good command line instead of guessing at `archisolabel=`.

### What it costs

- **One boot entry, no menu.** No memtest, no accessibility entry, no
  `nomodeset` fallback, no "boot from disk". On a machine that will not come
  up, there is nothing to edit.
- **Mitigation:** `edk2-shell` is on the image. Outside Secure Boot,
  `systemd-stub` reads EFI LoadOptions and appends them to the baked-in command
  line, so launching `BOOTX64.EFI` from the shell with arguments works.
- **No BIOS boot at all.** Anything older than roughly 2012 will not boot this.
- **Secure Boot fails.** The UKI is unsigned. `./test.sh -s` demonstrates it.
  Signing with `sbctl` is a later phase.

## Layout

```
profile/
├── profiledef.sh          image attributes + the custom uefi.efistub boot mode
├── packages.x86_64        one per line; '#' and blank lines ignored
├── pacman.conf            repos used to BUILD the image (not the live system's)
└── airootfs/              overlay, copied in BEFORE packages install
    └── etc/
        ├── mkinitcpio.conf.d/archiso.conf     HOOKS — mandatory
        ├── mkinitcpio.d/linux-zen.preset      filename must match pkgbase
        ├── passwd, shadow                     passwordless root, see below
        └── systemd/...                        autologin, networkd, resolved
build.sh                   mkarchiso wrapper + integrity verification
test.sh                    QEMU/OVMF harness
verify-iso.sh              static checks on a finished image
capture-system.sh          snapshot this machine's /etc into system/
system/                    captured config, package lists, enabled units (encrypted)
docs/SECRETS.md            why system/ is encrypted, and how to unlock it
LICENSE                    GPL-3.0
docs/LAYOUT.md             target layout for the installed system
.github/workflows/build.yml   CI: build + verify, release on tag
```

`airootfs/` ownership and permissions are **not** preserved — everything is
flattened to root:root, 644 for files and 755 for directories. Anything needing
different bits goes in `file_permissions` in `profiledef.sh`.

## Deltas from releng

**Boot:** `syslinux/`, `grub/`, `efiboot/` deleted along with their packages
(`syslinux`, `grub`, `refind`, `memtest86+`, `memtest86+-efi`) and the units
they needed (`choose-mirror`, which reads a `mirror=` boot parameter that can no
longer be passed).

**Kernel:** `linux` → `linux-zen`, and `linux.preset` renamed to
`linux-zen.preset` with all three paths retargeted. The preset filename must
match the package base or the mkinitcpio pacman hook never fires.

**initramfs:** the four `archiso_pxe_*` hooks dropped (no netboot build mode
exists here), and `xz -9e` → `zstd -19`. The initramfs ends up in a PE section
that nothing recompresses, and rebuild time dominates while iterating on a
profile. `microcode` stays — it embeds amd-ucode/intel-ucode *into* the
initramfs, which is what keeps a single-file UKI viable.

**airootfs (squashfs):** `xz -Xbcj x86` → `zstd -19`, same reasoning at the
image level: noticeably faster to build, slightly larger, and decompression on
the live system gets faster too.

**Dead-on-arrival units removed.** Anything gated on a kernel parameter is
unreachable when the command line is frozen into the image. `choose-mirror`
(`mirror=`) and `livecd-alsa-unmuter` + `livecd-sound`
(`ConditionKernelCommandLine=accessibility=on`) are gone; the `accessibility=`
branch in `root/.zlogin` is gone. `root/.automated_script.sh` stays — its
`script=` parameter *is* reachable, via LoadOptions from the UEFI shell, and
it is the natural hook for autorunning the installer later.

**Dropped:** `archinstall` (arcain installs with its own script), VM guest
agents (`open-vm-tools`, `virtualbox-guest-utils-nox`, `hyperv`, `cloud-init`),
dial-up and legacy WAN (`ppp`, `pptpclient`, `wvdial`, `xl2tpd`, `linux-atm`,
`modemmanager`, `usb_modeswitch`), accessibility (`brltty`, `espeakup`,
`livecd-sounds` — there is no boot menu entry to invoke them from), legacy
filesystems (`jfsutils`, `nilfs-utils`, `gpart`), PXE/network-boot support
(`nbd`, `dnsmasq`, `darkhttpd`, `nfs-utils`, `mkinitcpio-nfs-utils`,
`open-iscsi`), smartcard (`pcsclite`, `openpgp-card-tools`), legacy Broadcom
Wi-Fi (`b43-fwcutter`, `broadcom-wl`), and `clonezilla`/`partimage`
(`partclone` + `ddrescue` + `fsarchiver` cover the same ground).

**Added:** `git`, `wget`, `htop`, `jq`, `ripgrep`, `fd`, `tree`, `unzip`,
`p7zip`, `pciutils`, `qemu-guest-agent`.

## Security

`airootfs/etc/shadow` contains `root::14871::::::` — an **empty password
field**, meaning root logs in with no password, and `getty@tty1` autologins.
This is upstream archiso's default and is the right call for a boot-once
install medium.

It is the wrong call for a stick you carry around. Anyone who picks it up gets
root on the live environment, and through it read access to every unencrypted
filesystem in whatever machine they plug it into. Before using this as a
portable workstation, put a real hash in that field:

```sh
openssl passwd -6            # paste the result as field 2 of etc/shadow
```

and drop `airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf`.

## Build integrity

`build.sh` marks the work directory `chattr +C` on btrfs (a full pacstrap plus
a squashfs pass per build is worst-case copy-on-write fragmentation), and after
the build re-reads the finished ISO with `iflag=direct` and compares SHA-256
against the page-cache value. `O_DIRECT` is the point: a normal re-read is
answered from RAM and proves nothing about what reached the disk. On a
mismatch it refuses to hand you the image.

## Continuous integration

`.github/workflows/build.yml`, two jobs.

**`build`** runs on every push to `main`, every pull request, and every tag. It
runs in an `archlinux:latest` container with `--privileged`, because `pacstrap`
bind-mounts `/proc`, `/sys` and `/dev` into the chroot and the default container
capability set has no `CAP_SYS_ADMIN`. `SOURCE_DATE_EPOCH` is pinned to the
commit date, so a given commit always yields the same `iso_version` and
`iso_label` rather than whatever day the build ran. Then `./build.sh`,
`./verify-iso.sh`, and the ISO plus its checksum go up as an artifact.

**`release`** needs `build`, and is skipped unless the ref is a tag. It pulls
the artifact and publishes it with `gh release create`, using
`secrets.GITHUB_TOKEN` and `contents: write`. Tag it to ship:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

There is no boot test in CI. GitHub's runners expose no KVM, and `test.sh` asks
for `accel=kvm`; a TCG boot would work but costs 10–20 minutes a run. What
`verify-iso.sh` checks instead, all against the finished image rather than the
work directory: the checksum sidecar, that `xorriso` can read it, the
`ARCAIN_*` volume label, exactly one El Torito UEFI image and no BIOS image, an
EFI system partition in the GPT, `/EFI/BOOT/BOOTX64.EFI` and `shellx64.efi`
inside the ESP, `archisobasedir=` and `archisosearchuuid=` baked into the UKI's
`.cmdline` section, and a package list that has `linux-zen` and none of `linux`,
`grub`, `syslinux`, `refind`, `memtest86+` or `archinstall`.

## Status

- [x] Phase 1 — profile: EFI stub boot mode, zen kernel, pruned package set
- [x] Phase 2 — `build.sh` + `test.sh` + `verify-iso.sh`, CI build and release
- [ ] Phase 3 — `arcain-install` (skeleton in
      `profile/airootfs/usr/local/bin/arcain-install`)
- [ ] Phase 4 — portable workstation layer (persistence, dotfiles)
- [x] btrfs subvolume layout and mount options (`docs/LAYOUT.md`)
- [x] snapshots — [`arcain-snap`](https://github.com/cainbryce/arcain-snap), its own repo
- [ ] Phase 5 — Secure Boot signing with `sbctl`

## A note on `system/`

`system/` holds state captured off a running machine and is **encrypted at rest**
with git-crypt. Clone and build without unlocking it — `profile/` is plaintext
and the ISO does not depend on `system/`. See [docs/SECRETS.md](docs/SECRETS.md).

## Reference

`~/Sources/archiso` (upstream clone) — `docs/README.profile.rst` for the
profile contract, `archiso/mkarchiso` for what actually happens.
