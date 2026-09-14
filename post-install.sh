#!/usr/bin/env bash
# ===============================================================
# Arch Linux Post-Install Script
# ===============================================================
set -euo pipefail

# ── Helpers ────────────────────────────────────────────────────
log() { echo -e "\n\e[1;34m==> $*\e[0m"; }
ok() { echo "    ✓ $*"; }
skip() { echo "    → $* (already done, skipping)"; }
fail() {
  echo -e "\e[1;31m✗ $*\e[0m" >&2
  exit 1
}

BACKUP_ROOT="$(cd "$(dirname "$0")" && pwd)/root"

# ── 1. Pacman tweaks ───────────────────────────────────────────
log "Pacman configuration"
sudo sed -Ei '/Color/s/^#//' /etc/pacman.conf
sudo sed -Ei 's/#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
ok "Color + parallel downloads enabled"

# ── 2. System update ───────────────────────────────────────────
log "System update"
sudo pacman -Syu --noconfirm

# ── 3. AUR helper (paru) ───────────────────────────────────────
log "Installing paru"
if ! command -v paru &>/dev/null; then
  tmp=$(mktemp -d)
  git clone https://aur.archlinux.org/paru.git "$tmp/paru"
  (cd "$tmp/paru" && makepkg -si --noconfirm)
  rm -rf "$tmp"
  ok "paru installed"
else
  skip "paru"
fi

# ── 4. Packages ────────────────────────────────────────────────
log "Installing native packages"
paru -S --needed --noconfirm - <native-packages.txt

log "Installing AUR packages"
paru -S --needed --noconfirm - <aur-packages.txt

# ── 5. Copy config/root files ──────────────────────────────────
log "Copying root-level config files"

# The repo's `root/` tree mirrors the destination filesystem layout
# (paths relative to /). Copy it over recursively.
sudo cp -r --preserve=mode,timestamps "$BACKUP_ROOT/." /

# Make /usr/local/bin scripts executable
sudo chmod +x /usr/local/bin/{bilal,confet,hyprland-minimizer,snapper-systemd-boot.sh}

# Render machine-specific boot entry (fresh disks have a new root UUID)
ROOT_UUID="$(findmnt -no UUID / 2>/dev/null || true)"
if [[ -n "$ROOT_UUID" ]]; then
  sudo sed -Ei -e "s/@ROOT_UUID@/$ROOT_UUID/" -e "s/root=UUID=[^ ]+/root=UUID=$ROOT_UUID/" \
    /boot/loader/entries/arch.conf || true
  ok "Boot entry → root UUID $ROOT_UUID"
else
  echo "    ! Could not detect root UUID, edit /boot/loader/entries/arch.conf manually"
fi

# Rebuild initramfs with booster (11M, zstd, host-specific)
if command -v booster &>/dev/null; then
  log "Building booster image"
  kver=$(for d in /usr/lib/modules/[0-9]*; do
    basename "$d"
    break
  done)
  sudo booster build --force --kernel-version "$kver" /boot/booster-linux.img 2>&1 | tail -n 5 || sudo booster build 2>&1 | tail -n 5
fi
sudo bootctl update --graceful 2>/dev/null || true

# ── 6. Shell ───────────────────────────────────────────────────
log "Shell configuration"

ZSH_PATH="$(command -v zsh)"
if [[ "${SHELL:-}" == "$ZSH_PATH" ]]; then
  skip "default shell is already zsh"
else
  chsh -s "$ZSH_PATH"
  ok "Default shell → zsh"
fi

if [[ "$(readlink -f /usr/bin/sh 2>/dev/null || true)" == "$(readlink -f /usr/bin/dash)" ]]; then
  skip "/usr/bin/sh already points to dash"
else
  sudo ln -sfT dash /usr/bin/sh
  ok "/usr/bin/sh → dash"
fi

# ── 7. Systemd tweaks ──────────────────────────────────────────
log "Systemd configuration"
sudo sed -Ei "s/#DefaultTimeoutStopSec=90s/DefaultTimeoutStopSec=3s/" \
  /etc/systemd/system.conf
if grep -Eq "^CriticalPowerAction=" /etc/UPower/UPower.conf; then
  sudo sed -Ei 's/^CriticalPowerAction=.*/CriticalPowerAction=PowerOff/' \
    /etc/UPower/UPower.conf
else
  echo "CriticalPowerAction=PowerOff" | sudo tee -a /etc/UPower/UPower.conf >/dev/null
fi
ok "Stop timeout 3 s, critical power action → PowerOff"

# Locale (en_US.UTF-8 only; /etc/locale.gen is owned by glibc so patch in place)
if grep -Eq "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
  skip "locale en_US.UTF-8 already enabled"
else
  sudo sed -Ei 's/^#?(en_US.UTF-8 UTF-8)/\1/' /etc/locale.gen
  sudo locale-gen
  ok "Locale → en_US.UTF-8"
fi

# ── 8. Snapper + systemd-boot ──────────────────────────────────
log "Snapper + systemd-boot"
sudo systemctl daemon-reload
sudo systemctl enable snapper-cleanup.timer
sudo systemctl enable --now snapper-systemd-boot.path
sudo /usr/local/bin/snapper-systemd-boot.sh || true
sudo bootctl update --graceful 2>/dev/null || true
ok "Snapper + systemd-boot"

# ── 9. GTK dark mode ───────────────────────────────────────────
log "GTK dark mode"
gsettings set org.gnome.desktop.interface color-scheme prefer-dark
gsettings set org.gnome.desktop.interface gtk-theme Tokyonight-Dark
sudo flatpak override --filesystem="$HOME/.local/share/themes"
ok "Done"

# ── 10. Virtualization (KVM/libvirt) ───────────────────────────
log "Virtualization setup"
# qemu-full, virt-manager, virt-viewer, dnsmasq already in native-packages.txt (§4)

if id -nG "$(whoami)" | grep -qw libvirt; then
  skip "$(whoami) already in libvirt group"
else
  sudo usermod -aG libvirt "$(whoami)"
  ok "Added $(whoami) to libvirt group (re-login for it to take effect)"
fi

# flutter-bin (AUR §4) creates the flutter group; just ensure membership
if getent group flutter &>/dev/null; then
  if id -nG "$(whoami)" | grep -qw flutter; then
    skip "$(whoami) already in flutter group"
  else
    sudo usermod -aG flutter "$(whoami)"
    ok "Added $(whoami) to flutter group"
  fi
fi

# ── 11. Samba ──────────────────────────────────────────────────
log "Samba setup"
# samba NOT enabled at boot (manual start: systemctl start smb nmb)

if getent group sambauser &>/dev/null; then
  skip "sambauser group"
else
  sudo groupadd -r sambauser
  ok "sambauser group created"
fi

if id -nG muhammad 2>/dev/null | grep -qw sambauser; then
  skip "muhammad already in sambauser group"
else
  sudo gpasswd -a muhammad sambauser
  ok "muhammad added to sambauser"
fi

if sudo pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx muhammad; then
  skip "samba password for muhammad already set"
else
  sudo smbpasswd -a muhammad
  ok "samba password set for muhammad"
fi

ok "Samba configured (start manually with 'systemctl start smb nmb')"

# ── 12. Remaining services ─────────────────────────────────────
log "Handling services"
sudo systemctl disable NetworkManager.service avahi-daemon.service \
  bluetooth.service upower.service auto-cpufreq.service \
  vnstat.service sshd.service cups.service nmb.service \
  smb.service libvirtd.service waydroid-container.service
for svc in kanata.service systemd-timesyncd switch-to-tty1-shutdown.service start-services.service; do
  sudo systemctl enable --now "$svc" && ok "$svc"
done
sudo waydroid init -s GAPPS 2>/dev/null || true
ok "waydroid GAPPS"

# ── 13. Global npm packages ────────────────────────────────────
log "Global npm packages"
sudo npm install -g neovim live-server typescript tsx free-coding-models
ok "neovim, live-server, typescript, tsx, free-coding-models"

# ── 14. Flatpak apps ───────────────────────────────────────────
log "Flatpak apps"
flatpak install -y --noninteractive flathub \
  io.github._0xzer0x.qurancompanion \
  net.sapples.LiveCaptions
ok "Flatpak apps installed"

# ── 15. DotFiles (home config, no secrets) ─────────────────────
log "DotFiles"
# Secrets are NEVER cloned or stowed: ~/.ssh, ~/.gnupg, ~/.password-store,
# browser profiles, and wifi connections are manual (see MANUAL-CHECKLIST.md).
if [[ -d "$HOME/DotFiles/.git" ]]; then
  skip "DotFiles already cloned"
else
  git clone https://github.com/Muhammad95959/DotFiles.git "$HOME/DotFiles"
  ok "DotFiles cloned"
fi
if command -v stow &>/dev/null; then
  # Pre-create package dirs so stow links the files inside them,
  # never the dirs themselves (fresh $HOME has no ~/.config at all).
  mkdir -p "$HOME/.config" "$HOME/.local/share"
  (cd "$HOME/DotFiles" &&
    for src in .config/*/ .local/share/*/; do
      [[ -d "$src" ]] || continue
      mkdir -p "$HOME/$src"
    done &&
    stow --no-folding --restow --target="$HOME" .) \
    && ok "DotFiles stowed → \$HOME" \
    || echo "    ! stow reported conflicts — resolve manually, then re-run"
else
  fail "stow not found (should come from native-packages.txt)"
fi

# ── 16. Root account symlinks ──────────────────────────────────
log "Root user symlinks"
# Requires §15: symlinks point at /home/muhammad/.config + .local/share + .zshenv
sudo bash -s <<'ROOT'
  set -euo pipefail

  USER_HOME=/home/muhammad
  mkdir -p /root/.config /root/.local/share
  rm -rf \
    /root/.local/share/nvim /root/.local/share/fonts /root/.local/share/themes \
    /root/.config/nvim /root/.config/zsh \
    /root/.config/gtk-{2,3,4}.0 \
    /root/.config/{kanata,yazi} \
    /root/.zshenv /root/.zshrc \
    /root/.fonts /root/.icons /root/.themes

  for d in gtk-2.0 gtk-3.0 gtk-4.0 kanata nvim yazi zsh; do
    ln -sfn "$USER_HOME/.config/$d" /root/.config/
  done
  for d in fonts themes; do
    ln -sfn "$USER_HOME/.local/share/$d" /root/.local/share/
  done
  ln -sfn "$USER_HOME/.local/share/nvim" /root/.local/share/
  ln -sfn "$USER_HOME/.zshenv" /root/
  echo "    ✓ Root symlinks created"
ROOT

# ── Done ──────────────────────────────────────────────────────
log "All done! Re-login (or reboot) for group changes to take effect."
