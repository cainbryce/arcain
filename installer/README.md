# installer/

Files that get written to the **installed** system, authored here.

This is not `system/`. That directory is captured off the running machine by
`capture-system.sh` and is regenerated, so nothing in it should be hand-edited.
Everything here is written by hand and is the source of truth.

```
usr/local/bin/arcain-snap              btrfs snapshots, no daemon
etc/arcain/snap.conf                   what it snapshots and how long it keeps it
etc/systemd/system/arcain-snap-*.…     hourly timeline, daily send to the backup disk
etc/pacman.d/hooks/*-arcain-snap-*     pre/post snapshots around every transaction
```

Layout under `installer/` mirrors `/`, so installing it is a copy:

```sh
cp -a installer/etc installer/usr /
chmod 0755 /usr/local/bin/arcain-snap
systemctl enable --now arcain-snap-timeline.timer arcain-snap-backup.timer
```

`arcain-install` will do this; until it exists the copy above is the procedure.

## arcain-snap

Why it exists instead of snapper, what it snapshots, the retention policy, and
the rollback procedure are all in [`../docs/LAYOUT.md`](../docs/LAYOUT.md#snapshots).
Short version: the EFI stub boot design removes the boot menu, which was the
only thing snapper was providing here that `btrfs-progs` does not, so what is
left is a daemon and a set of XML configs earning nothing.

```
arcain-snap create [-t TAG] [-d DESC] [config...]
arcain-snap list   [config...]
arcain-snap prune  [config...]
arcain-snap backup [config...]
arcain-snap rollback SNAPSHOT      prints the procedure; run it from the ISO
```

Default retention per config is 24 hourly, 7 daily, 4 weekly and 20 pacman
pre/post — about a month of history in 35 snapshots. Manual snapshots (any tag
that is not `pre`, `post` or `timeline`) are never pruned.

`ARCAIN_SNAP_CONF` overrides the config path, which is how the retention logic
gets exercised against a throwaway tree.
