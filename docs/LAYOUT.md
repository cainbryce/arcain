# Target layout

Decisions taken 2026-08-16: pure Arch, layout A, `sdb` wiped, EFI stub UKI on
the installed system as well as on the ISO, river replacing Hyprland.

## Disks

| Device | Model | Role after install |
| --- | --- | --- |
| `nvme0n1` | WD_BLACK SN770 1TB | ESP + root + hot Steam library |
| `sda` | Crucial MX500 1TB SATA | `/home` + cold Steam library + Ollama models |
| `sdb` | WD Blue 250G SATA | bulk media (was Windows, wiped) |
| `sdc` | WD Elements SE 1.8T USB | **retired as root**, becomes the backup target |

### nvme0n1 — OS

`nvme0n1` already has a **4098 MiB unallocated gap at the start of the disk**,
left behind when the Windows ESP was deleted. `parted` shows the partition
table starting at number 2. The ESP drops into that gap; `nvme0n1p2` is never
touched, so the 553 GiB Steam library on it does not move.

```
nvme0n1p1   1 MiB – 4098 MiB     ESP, FAT32, label ARCAIN_EFI
nvme0n1p2   4098 MiB – end       btrfs (existing, label 'games' -> relabel 'system')
              ├─ @              /
              ├─ @root          /root
              ├─ @srv           /srv
              ├─ @log           /var/log
              ├─ @cache         /var/cache
              ├─ @snapshots     /.snapshots
              ├─ SteamLibrary/  (existing, untouched)
              └─ .nvidia-shadercache/ (existing, untouched)
```

Root is ~45 GiB once `/var/cache` is trimmed with `paccache -rk1` (it is 45 GiB
today, almost entirely pacman package cache).

### sda — home

`sda1` is a whole-disk btrfs with 353 GiB free. Subvolumes get added next to the
existing data; no repartitioning.

```
sda1        btrfs (existing, label 'Files' -> relabel 'data')
              ├─ @home          /home        (~158 GiB, media excluded)
              ├─ SteamLibrary/  (existing, untouched)
              └─ OllamaModels/  (existing, untouched)
```

### sdb — media

Wiped. Single btrfs partition, bind-mounted into `$HOME` so XDG paths keep
working without symlinks:

```
sdb1        btrfs, label 'media'   -> /mnt/media
              ├─ Videos/        bind -> /home/cain/Videos   (137 GiB)
              ├─ Music/         bind -> /home/cain/Music     (53 GiB)
              └─ recordings/    OBS captures moved off the NVMe (89 GiB)
```

### sdc — backup

Reformatted as a single btrfs volume and used as a `btrfs send | receive`
target for `@` and `@home` snapshots. This machine has an unresolved silent
corruption history, so an off-root copy on a disk that can be unplugged is the
point, not capacity.

## Space check

| | Capacity | Used after migration | Free |
| --- | --- | --- | --- |
| nvme0n1p2 | 924 GiB | ~511 (root 45 + Steam 553, minus 89 GiB of recordings moved off) | ~413 |
| sda1 | 932 GiB | ~742 (home 158 + Steam 530 + Ollama 54) | ~190 |
| sdb1 | 232 GiB | ~190 (Videos + Music) | ~42 |
| sdc | 1.8 TiB | backups only | — |

## What this deletes

Three workarounds exist only because root is on a USB disk. They all go:

- `/etc/systemd/system/home-cain-.cache.mount` — bind `~/.cache` from the NVMe
- `/etc/systemd/system/usr-share-fonts.mount` — bind `/usr/share/fonts` from the NVMe
- `__GL_SHADER_DISK_CACHE_PATH=/mnt/games/.nvidia-shadercache` in `environment.d`
- `/etc/systemd/journald.conf.d/50-usb-limits.conf` — `SystemMaxUse=200M`

`/home/cain/.cache.usb-old` (47 GiB) is migration debris and is not carried over.

## Boot: EFI stub UKI, no boot loader

The installed system boots the same way the ISO does — firmware executes a
unified kernel image directly. No Limine, no GRUB, no systemd-boot.

```
/efi                                  ESP (nvme0n1p1)
  └─ EFI/Linux/
       ├─ arch-linux-zen.efi          default UKI
       └─ arch-linux-zen-fallback.efi -S autodetect, for hardware changes
/boot                                 plain directory on @, holds vmlinuz + initramfs
/etc/kernel/cmdline                   the command line, baked into .cmdline
```

mkinitcpio 41.1 builds these natively. `/etc/mkinitcpio.d/linux-zen.preset`:

```bash
ALL_kver="/boot/vmlinuz-linux-zen"

PRESETS=('default' 'fallback')

default_uki="/efi/EFI/Linux/arch-linux-zen.efi"

fallback_uki="/efi/EFI/Linux/arch-linux-zen-fallback.efi"
fallback_options="-S autodetect"
```

mkinitcpio calls `ukify` when it is installed and falls back to `objcopy`
otherwise, and reads the command line from `/etc/kernel/cmdline` or
`/etc/cmdline.d/` by default. `efibootmgr` then registers both images.

**Cost: no snapshot boot menu.** `limine-snapper-sync` currently exposes
bootable btrfs snapshots from the boot menu. With no boot loader there is no
menu to put them in. Recovery path becomes the arcain ISO: boot it, mount the
subvolume, roll back, reboot. The fallback UKI covers the other common case
(initramfs missing a driver after a hardware change), and the firmware's own
boot menu picks between the two.

## Desktop: river-classic

**The package is `river-classic`, not `river`.** Upstream split the name and
both halves are in `extra`, conflicting with each other:

| | `river` 0.4.8 | `river-classic` 0.3.17 |
| --- | --- | --- |
| upstream | isaacfreund.com/software/river | codeberg.org/river/river-classic |
| binaries | `river` | `river`, `riverctl`, `rivertile` |
| protocols | 6 new `stable/` XMLs (window-management, input-management, layer-shell, libinput-config, xkb-bindings, xkb-config) | `river-layout-v3.xml` |
| config | none shipped | `share/river-classic/example/init` |
| provides | — | `wayland-compositor` |
| depends | — | `sh` |

`river` alone is the protocol reference implementation: it ships **no
`riverctl`**, so it is driven by an external client speaking
`river-window-management-v1`. Installing it as a daily driver gives a
compositor with no way to bind a key or launch a terminal. The usable tiling
compositor is `river-classic`, and its `sh` dependency is the executable
`~/.config/river/init` config model.

Both are in official Arch `extra`, so this needs no AUR. Optional layout
generators `rivercarro` (0.6.0) and `wideriver` (1.3.1) are AUR-only, but
`river-classic` ships `rivertile`, so they are not required.

Switching from Hyprland drops
about fifteen `-git` AUR packages (`hyprland-git`, `aquamarine-git`,
`hyprutils-git`, `hyprlang-git`, `hyprgraphics-git`, `hyprwire-git`,
`hyprcursor-git`, `hyprwayland-scanner-git`, `hyprland-protocols-git`,
`hyprland-guiutils-git`, `hyprpicker-git`, `hyprshot-git`, `hyprtoolkit-git`,
`hyprqt6engine-git`, `xdg-desktop-portal-hyprland-git`) and replaces them with
`river-classic`, `xdg-desktop-portal-wlr`, and `wlr-randr`.

The 24-file Lua config does not port. river-classic is configured by an
executable `~/.config/river/init` that issues `riverctl` calls, and it uses
**tags** (a 32-bit mask) rather than workspaces, so `workspaces.lua`,
`games-workspace.lua` and the special-workspace behaviour need redesigning
rather than translating. Start from `/usr/share/river-classic/example/init`.

Scripts that break and need porting: `hypr-snap`, `hypr-bind-editor`,
`hypr-native-recorder`, `focus-or-launch` (all shell out to `hyprctl`).

Waybar stays — it has native `river/tags`, `river/window` and `river/mode`
modules. **These are river-classic-only.** They speak
`river-status-unstable-v1` / `river-control-unstable-v1`, which the new `river`
does not ship. See below.

### If we ever move to the new `river`

Not for this install, but recorded so the decision is not re-derived later.

The new `river` requires a window manager client — a normal Wayland client that
binds `river_window_manager_v1` from the registry. There is no privilege
handshake: `Server.zig:globalFilter` gates only the Xwayland global and
security-context clients, so the global is offered to everyone and
`WindowManager.zig:118` gives it to the first binder, sending `unavailable` to
the rest. That is also what makes hot-swapping a WM work.

The programming model is a double-buffered manage/render loop, not an IPC
command socket:

- **Window management state** (proposed dimensions, focus, fullscreen, key
  bindings, tiled edges) may only be changed between the `manage_start` event
  and the `manage_finish` request.
- **Rendering state** (position, stacking, borders, hide/show) may be changed
  in either sequence but is applied at `render_finish`.
- Touching either outside its sequence is the `sequence_order` protocol error,
  which disconnects the client.
- Nothing is pollable. There is no `hyprctl clients` equivalent — the WM holds
  the world model and events are deltas against it. `manage_dirty` is how the
  WM forces a sequence after a state change the compositor cannot see.
- Key bindings are synchronous: after a `pressed` event the compositor stops
  processing input until `manage_finish`, so WM latency is input latency.

Scale, from the upstream `tinyrwm` examples (spawn, close, cycle focus, exit,
click-to-focus + raise, super-drag move, super-rightdrag resize — floating,
single output, no tags): Janet 254 lines, Lua 415, Zig 464, Go 469, OCaml 522,
C 585, Rust 736.

Mandatory work beyond that before the desktop is usable here:

- **Layer shell.** `river-layer-shell-v1.xml`: "If the window manager does not
  bind this interface, the compositor should not allow clients to map layer
  surfaces." Until the WM binds `river_layer_shell_v1` and handles
  `non_exclusive_area` / `set_default` / `focus_exclusive`, waybar, swaybg,
  fuzzel, mako and scry render nothing. `tinyrwm` does not implement it.
- **Bar IPC.** Since waybar's river modules are dead on new river, the WM has
  to expose its own status channel and waybar needs a custom module. The
  community WM `rhine` implements a Hyprland-shaped IPC for exactly this.
- Tiling itself is two-phase: `propose_dimensions` in the manage sequence, the
  window answers with a `dimensions` event that may differ (terminals snap to
  cell size), then `river_node_v1.set_position` in the render sequence.

Everything else in this setup survives — verified against the symbols in the
`river` binary: wlr + ext foreign-toplevel, screencopy, ext-image-copy-capture
and export-dmabuf (OBS), session lock, wlr-output-management (kanshi,
wlr-randr), gamma control, pointer constraints, virtual keyboard/pointer,
tablet, text-input/input-method, xdg-decoration, Xwayland.

27 community window managers are already listed on the river wiki, seven of
them in Zig. Forking one is cheaper than greenfield.

Upstream river has a strict no-LLM policy covering all contributions including
bug reports, and the wiki lists AI-assisted window managers in a separate
table. It does not restrict use, but a WM built with AI assistance cannot be
upstreamed and bugs must be reported unassisted.

## Session: replacing uwsm

uwsm currently wraps the compositor in ten systemd units. A lighter launcher is
viable, but it must still bring up `graphical-session.target`, because these are
wired to it and will not start otherwise:

```
graphical-session.target.wants/      waybar.service, app-com.mitchellh.ghostty.service
graphical-session-pre.target.wants/  xdg-desktop-portal-rewrite-launchers.service
```

It must also keep `app-graphical.slice` or an equivalent cgroup split, since
`ananicy-cpp` rules and `systemd-oomd` both act per-cgroup.

Minimum viable replacement: set `XDG_CURRENT_DESKTOP=river` and the rest of the
environment, `systemctl --user import-environment`, start
`graphical-session-pre.target` then `graphical-session.target`, `exec river`,
and stop both targets on exit.
