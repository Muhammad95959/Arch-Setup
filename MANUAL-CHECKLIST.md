# Manual checklist — fresh Arch install

Companion to `post-install.sh`. Principle: **no secrets in git**.
Everything secret below is restored by hand and never committed to
`Arch-Setup/` or `DotFiles/`.

## 0. Pre-requirements (live USB)

- Boot Arch ISO, connect network, partition + format:
  - ESP (vfat, `/boot`), swap, btrfs `ROOT`, ext4 `HOME`.
- Create btrfs subvolumes `@`, `@log`, `@pkg`, `@/.snapshots`.
- See `templates/fstab.example` — fill in real UUIDs from `blkid`,
  then `cp templates/fstab.example /etc/fstab` (adjust mountpoints).
- `pacstrap` base system, `genfstab -U /mnt >> /mnt/etc/fstab`
  (verify against the example: `nofail` on `/mnt/Disk_*` so boot never hangs).
- `arch-chroot`, create user `muhammad`, then continue below.

## 1. Bootloader (manual, once per disk)

- `bootctl install` (script only runs `bootctl update --graceful`).
- `post-install.sh §5` renders `root=UUID=…` into
  `/boot/loader/entries/arch.conf` from `findmnt -no UUID /`.
  Verify: `cat /boot/loader/entries/arch.conf`.
- `snapper-systemd-boot.sh` auto-detects the UUID at runtime
  (hardcoded value inside is fallback/reference only).

## 2. Run the script

```sh
git clone https://github.com/Muhammad95959/Arch-Backup.git ~/Arch-Setup
cd ~/Arch-Setup
./post-install.sh
```

- `§15` clones `DotFiles` over HTTPS and `stow`s it to `$HOME`.
  Afterwards you may `git remote set-url origin git@github.com:Muhammad95959/DotFiles.git`
  once SSH keys exist (see §3).
- `§16` root symlinks require `§15` (they point at `/home/muhammad/.config/*`).
- Re-login/reboot for `libvirt`, `flutter`, `sambauser` groups.

## 3. Secrets — restore by hand, never commit

- **SSH**: copy `~/.ssh/{id_ed25519,id_ed25519.pub,known_hosts}` from backup,
  `chmod 700 ~/.ssh; chmod 600 ~/.ssh/id_ed25519`.
- **GPG**: `~/.gnupg/` from backup; verify with `gpg --list-secret-keys`.
- **Passwords**: `~/.password-store/` from backup (`pass`).
- **Samba**: `sudo smbpasswd -a muhammad` (interactive; script detects
  existing entry via `pdbedit -L` and skips).
- **Wifi**: `sudo cp <backup>/*.nmconnection /etc/NetworkManager/system-connections/`,
  `sudo chmod 600` them. Live names: `Black Pearl`, `Mi 9T`, `Saif al-Islam`.
- **Browsers**: sign in to Brave/Firefox sync (profiles under
  `~/.config/BraveSoftware`, `~/.mozilla` are not in `DotFiles`).
- **Hosts/disks**: `/mnt/Disk_C`, `/mnt/Disk_D` need their real UUIDs
  in `/etc/fstab` (see `fstab.example` placeholders).

## 4. Heavy data — re-download / re-import, not backed up

- **Snapper snapshots**: start empty; `snapper -c root create-config /`
  only if `/etc/snapper/configs/root` is missing (repo ships a copy).
- **Waydroid**: script runs `waydroid init -s GAPPS`; image + `/var/lib/waydroid`
  re-downloads (~GBs). Then set up device manually.
- **VMs/containers**: re-import `/var/lib/libvirt/images`, re-pull
  `docker`/`distrobox` images, re-init `postgres`/`mongo`/`valkey` data.
- **Printers**: re-add CUPS printers (service is socket-activated via
  `cups.socket`/`cups.path`; `start-services.service` starts the socket).
- **Phone/tools**: re-auth `flutter`/`dart`/`gh`, JetBrains Toolbox login,
  `plocate-updatedb`, `reflector` mirrorlist refresh.
- **User data**: `~/Backgrounds`, `~/Projects`, `~/Scripts`, `~/Downloads`,
  `~/Android/Sdk`, `~/.var` (flatpak data) from external backup.

## 5. Verify

- `comm -23 <(sort native-packages.txt aur-packages.txt | sort -u) <(pacman -Qqe | sort)` → empty.
- `sudo diff -r root/boot root/usr root/etc/systemd root/etc/samba root/etc/greetd root/etc/booster.yaml root/etc/environment root/etc/hostname root/etc/hosts root/etc/locale.conf /` (expect only `arch.conf` UUID rendered; `templates/` is never copied).
- `systemctl is-enabled kanata.service systemd-timesyncd switch-to-tty1-shutdown.service start-services.service snapper-cleanup.timer snapper-systemd-boot.path greetd.service`.
- `gsettings get org.gnome.desktop.interface gtk-theme` → `Tokyonight-Dark`.
- Reboot, check `snapper-systemd-boot.sh` generated `/boot/loader/entries/snapper-*.conf`.
