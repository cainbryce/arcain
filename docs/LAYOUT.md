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
              ├─ @tmp           /var/tmp
              ├─ @containers    /var/lib/containers
              ├─ @snapshots     /.snapshots
              ├─ @steam         /mnt/steam           (was SteamLibrary/)
              └─ @shadercache   /mnt/shadercache     (was .nvidia-shadercache/)
```

Root is ~45 GiB once `/var/cache` is trimmed with `paccache -rk1` (it is 45 GiB
today, almost entirely pacman package cache).

### sda — home

`sda1` is a whole-disk btrfs with 353 GiB free. Subvolumes get added next to the
existing data; no repartitioning.

```
sda1        btrfs (existing, label 'Files' -> relabel 'data')
              ├─ @home          /home                (~158 GiB, media excluded)
              ├─ @home-cache    /home/cain/.cache
              ├─ @steam-sata    /mnt/steam-sata      (was SteamLibrary/)
              └─ @ollama        /var/lib/ollama      (was OllamaModels/)
```

### sdb — media

Wiped. Single btrfs partition. Subvolumes mount straight onto the XDG paths —
no bind mounts and no symlinks, because a subvolume can be mounted anywhere:

```
sdb1        btrfs, label 'media'
              ├─ @videos        /home/cain/Videos            (137 GiB)
              ├─ @music         /home/cain/Music              (53 GiB)
              └─ @recordings    /home/cain/Videos/recordings  (89 GiB, OBS)
```

The current disk has roughly 60 GiB of loose `.mkv` files sitting directly in
the root of `nvme0n1p2` alongside `recordings/`; both land in `@recordings`.

### sdc — backup

Reformatted as a single btrfs volume and used as a `btrfs send | receive`
target for `@` and `@home` snapshots. This machine has an unresolved silent
corruption history, so an off-root copy on a disk that can be unplugged is the
point, not capacity.

## Subvolume policy

A subvolume has to earn its place by satisfying at least one of three tests.
Everything else stays a plain directory, because each extra subvolume is one
more thing to mount, snapshot, prune and send.

1. **It must survive a rollback.** Logs from the boot that broke are the reason
   you are rolling back; restoring them along with `/usr` throws away the
   evidence.
2. **It needs different mount options.** Compression and copy-on-write
   behaviour are set per mount, so anything wanting different settings needs to
   be separately mountable.
3. **It is snapshotted or backed up on its own schedule.**

The layout is **flat**: every subvolume is a direct child of subvolid 5, named
`@…`, and nothing is nested inside `@`. A nested subvolume appears as an empty
directory inside its parent's snapshot, which makes `btrfs send` streams
confusing and turns rollback into a multi-step operation instead of a rename.

Two things deliberately stay *inside* `@`:

- **`/var/lib/pacman`.** A rollback that restores `/usr` but not the package
  database leaves a system whose database lies about what is installed. This is
  the most common btrfs-on-Arch mistake and it is silent until the next upgrade.
- **`/boot`.** The initramfs and `/usr/lib/modules/<version>` have to move
  together, so the plain `/boot` directory rides along with `@`.

### Promoting the existing directories is nearly free

`SteamLibrary/`, `.nvidia-shadercache/` and `OllamaModels/` are plain
directories today. Turning them into subvolumes does **not** require copying
553 GiB around: reflink copies work across subvolumes within one btrfs
filesystem, so

```sh
btrfs subvolume create /mnt/system/@steam
cp -a --reflink=always /mnt/system/SteamLibrary/. /mnt/system/@steam/
rm -rf /mnt/system/SteamLibrary
```

shares every extent and finishes in seconds at no extra space. The catch is
that this only holds while the target keeps copy-on-write — see below.

## Mount options

| subvolumes | options |
| --- | --- |
| `@`, `@root`, `@srv`, `@log`, `@snapshots` | `noatime,compress=zstd:1,ssd,discard=async,space_cache=v2` |
| `@cache`, `@tmp`, `@containers`, `@home`, `@home-cache` | same |
| `@steam`, `@steam-sata`, `@ollama`, `@videos`, `@music`, `@recordings` | `noatime,compress=no,ssd,discard=async,space_cache=v2` |
| `@shadercache` | `noatime,compress=no,nodatacow` |

**`compress=zstd:1`, not the current `zstd:3`.** Level 1 costs far less CPU per
write for a modest ratio loss, and a root filesystem is dominated by small
already-mixed files and by build trees that get rewritten constantly. Level 3
is worth keeping only if the filesystem is space-constrained, and none of these
are.

**`compress=no` on the bulk data.** Game assets, GGUF weights and H.264 captures
are already compressed. btrfs does heuristically bail out on incompressible
extents, so the win is modest, but it is free.

**`nodatacow` almost nowhere.** It is the obvious "make it fast" knob and it is
the wrong one here: `nodatacow` also disables checksumming, and this machine has
an unresolved silent-corruption history (`btrfs-incident-2026-07-09` is still
sitting on the NVMe). Checksums are the only thing that would catch a repeat.
It also defeats the reflink promotion above. So it is set on exactly one
subvolume, `@shadercache`, whose entire contents are a regenerable GPU cache.

**No `autodefrag`.** It rewrites extents, which unshares them from every
snapshot that referenced them, so on a snapshotted root it shows up as steady
unexplained space growth.

**No qgroups.** They make every write account against a quota tree and are the
classic cause of multi-second commit stalls on large filesystems. Nothing here
needs them: retention is by count and age, not by space accounting. This is
also the main reason snapper is not the answer — see below.

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

## Snapshots

### Why not snapper

snapper is already installed on the current system, and it is already doing
almost nothing. Its `root` config has `TIMELINE_CREATE="no"` and `QGROUP=""`,
and `snap-pac` is not installed, so nothing creates snapshots automatically.
What made it worth having was `limine-snapper-sync` putting bootable snapshots
in the Limine menu — and the EFI stub decision deletes the boot menu, so that
integration goes with it.

What is left is a D-Bus daemon, an XML config per subvolume, a cleanup timer,
and a cleanup algorithm whose space-aware modes want qgroups enabled.

| | snapper + snap-pac | btrbk | own script |
| --- | --- | --- | --- |
| packages beyond `btrfs-progs` | `snapper`, `snap-pac`, dbus, boost | `btrbk`, perl | none |
| daemon | yes | no | no |
| pacman pre/post | via `snap-pac` | no | one hook file |
| retention | timeline algorithm | count/age per interval | count/age per tag |
| wants qgroups | for space-aware cleanup | no | no |
| `send`/`receive` to `sdc` | no | yes, incremental + resumable | has to be written |
| rollback | manual | manual | manual |

Rollback is manual in all three, because there is no boot menu to select a
snapshot from. That removes the one thing snapper was doing for this machine,
and the remaining requirement — pre/post pacman snapshots, a timeline with
retention, and incremental `btrfs send` to the backup disk — is a few hundred
lines against `btrfs-progs`, which is a hard dependency of the install anyway.

**Decision: `arcain-snap`, in this repo.** btrbk is the honest runner-up and is
the right answer for anyone who wants a maintained tool; its incremental
send/receive with resume is the part that is genuinely fiddly to reimplement.

### Layout

Snapshots are read-only subvolumes under `@snapshots`, grouped by config:

```
/.snapshots/
  ├─ root/
  │    ├─ 2026-08-18T13-05-00Z-pre/       @ before a pacman transaction
  │    ├─ 2026-08-18T13-07-11Z-post/      @ after it
  │    └─ 2026-08-18T14-00-00Z-timeline/
  └─ home/
       └─ 2026-08-18T14-00-00Z-timeline/
```

UTC, sortable, tag in the name. Each carries a small `info` file recording the
source subvolume, the tag, the pacman command line for `pre`/`post`, and the
parent used for the last successful `send`.

### Schedule

- **`pre` / `post`** — two pacman hooks. This is the snapshot that actually gets
  used: an upgrade that breaks the system is the common case, and `pre` is a
  known-good point from thirty seconds earlier.
- **`timeline`** — one hourly timer.
- **Retention** — the last 10 `pre`/`post` pairs, then 24 hourly, 7 daily, 4
  weekly. Pruned by count and age, never by space accounting.
- **`backup`** — a daily timer running `btrfs send -p` of the newest `root` and
  `home` snapshots to `sdc`, falling back to a full send when no common parent
  can be found on the target. `sdc` is expected to be absent; a missing target
  is a skip, not a failure.

### Rolling back, and the one thing that does not roll back

With no boot loader there is no menu, so recovery runs from the arcain ISO:
boot it, mount subvolid 5, rename `@` out of the way, snapshot the chosen
read-only snapshot back into place as a writable `@`, reboot.

**The UKI is not on btrfs.** It lives on the FAT ESP, so rolling `@` back to
before a kernel upgrade restores `/usr/lib/modules/<old>` and `/boot/vmlinuz`
while the ESP still holds a unified kernel image built from the *new* kernel.
That image will boot and then fail to find its modules.

Two mitigations, both already in this design:

- the `fallback` UKI is built with `-S autodetect`, so it carries a superset of
  modules and is the entry to pick from the firmware boot menu after a rollback;
- from the ISO, `arch-chroot` into the restored `@` and run `mkinitcpio -P` to
  rebuild both UKIs against the kernel that is actually installed there.

`arcain-snap rollback` prints this sequence rather than performing it, because
it has to run against a filesystem that is not the one it booted from.

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
