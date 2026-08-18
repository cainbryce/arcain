# Encrypted machine state

`system/` is captured off a running machine by `capture-system.sh`. It is not
secret in the password sense — `capture-system.sh` deliberately skips
NetworkManager PSKs, `/etc/shadow` and ssh host keys — but it identifies the
machine precisely:

| file | what it gives away |
| --- | --- |
| `generated/identity.txt` | hostname, username, shell, all 15 group memberships |
| `generated/ufw-rules.txt` | LAN subnet, per-host IPs, every open port |
| `generated/packages-*.txt` | complete 911-package software inventory |
| `etc/samba/smb.conf` | hostname, username, wireless interface, LAN allow-list, share paths |
| `etc/systemd/system/*.service` | service layout and home paths |

Published as-is that is a usable reconnaissance profile, and publishing is not
reversible — GitHub caches, forks and scrapers keep copies.

So the repo is public and `system/` is encrypted at rest with
[git-crypt](https://github.com/AGWA/git-crypt). The working tree stays
plaintext: `capture-system.sh` writes normal files and reads normal files, and
only the blobs git stores are ciphertext. Nothing in the build or the installer
has to know about this.

## Why git-crypt and not sops

Both work. The difference is where the plaintext lives.

git-crypt is a clean/smudge filter, so the working tree is plaintext and the
repo is ciphertext — `capture-system.sh` is untouched. sops encrypts the file
itself, so the plaintext only exists while you are editing, and every producer
and consumer of `system/` would have to learn to call `sops`. For a directory
that is regenerated wholesale by a script, transparency wins.

sops is the better answer if you want a maintained tool with age keys and
structure-preserving encryption, and it is worth revisiting if git-crypt's low
maintenance activity becomes a problem. git-crypt is GPG-only and removing a
key does not re-encrypt history.

## How it was set up

Already done — recorded so it can be rebuilt, and so the ordering constraint is
not rediscovered the hard way. Access is granted to GPG key
`EE509FAC493C419D`; adding another machine means adding its key (step 4).

```sh
sudo pacman -S --needed git-crypt git-filter-repo
```

### 1. Remove the plaintext from every existing commit

git-crypt encrypts from the moment it is configured. It does nothing about what
is already committed, and `system/` is in the initial commit.

```sh
cd ~/Projects/arcain
git filter-repo --path system --invert-paths --force
```

Rewrites every hash. Safe here because nothing has been pushed.

### 2. Turn on encryption, and commit that first

```sh
git-crypt init
git add .gitattributes
git commit -m "Encrypt captured machine state at rest"
```

Order matters. `.gitattributes` has to be in place *before* `system/` is added
again, or the plaintext goes straight back into the history.

### 3. Re-add the captured state

```sh
./capture-system.sh
git add system
git commit -m "Re-add captured machine state, encrypted"
```

### 4. Grant access

Per-host GPG keys, which is the "allowed hosts" model:

```sh
git-crypt add-gpg-user <KEY_ID>          # once per machine that may read it
```

Or one symmetric key, simpler for a single person with several machines:

```sh
git-crypt export-key ~/arcain-crypt.key  # move to the other hosts out of band
```

Never commit that key file. It is not in `.gitignore` because it should not
live in the working tree at all.

### 5. Verify before pushing

Do not skip this. The failure mode is silent — an unencrypted `system/` looks
completely normal in the working tree.

```sh
git-crypt status | awk '{print $1}' | sort | uniq -c   # 'encrypted:' count == files in system/

# The stored blob must be git-crypt's binary format, not readable text.
# od, not xxd: xxd ships with vim and is not always installed.
git show HEAD:system/generated/identity.txt | head -c 10 | od -c -A none
#   \0 G I T C R Y P T \0    correct
#   h o s t n a m e = c      STOP, it is plaintext
```

And the check that does not depend on reading the filter right — grep the whole
object database, across every ref, for things that must not be in it:

```sh
for needle in 'hostname=cain-cachy' '192.168.5' 'valid users = cain'; do
    git grep -I -c "$needle" $(git rev-list --all) -- system
done
```

Only then:

```sh
gh repo create arcain --public --source=. --remote=origin --push
```

## Working with it afterwards

On a machine that has been granted access:

```sh
git clone git@github.com:cainbryce/arcain.git
cd arcain
git-crypt unlock                    # GPG
git-crypt unlock ~/arcain-crypt.key # symmetric key
```

Without unlocking, `system/` reads as binary garbage and everything else in the
repo works normally — the ISO still builds, since `profile/` is not encrypted.

`git-crypt lock` puts it back.
