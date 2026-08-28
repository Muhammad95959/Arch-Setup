#!/usr/bin/env bash
# ===============================================================
# Arch Linux Post-Install Script
# ===============================================================
set -euo pipefail

# ── Helpers ────────────────────────────────────────────────────
log()  { echo -e "\n\e[1;34m==> $*\e[0m"; }
ok()   { echo    "    ✓ $*"; }
skip() { echo    "    → $* (already done, skipping)"; }
fail() { echo -e "\e[1;31m✗ $*\e[0m" >&2; exit 1; }

BACKUP_ROOT="$HOME/Arch-Backup/root"

# ── 1. Pacman tweaks ───────────────────────────────────────────
log "Pacman configuration"
sudo sed -Ei '/Color/s/^#//'                              /etc/pacman.conf
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
paru -S --needed --noconfirm - < native-packages.txt

log "Installing AUR packages"
paru -S --needed --noconfirm - < aur-packages.txt

# ── 5. Copy config/root files ──────────────────────────────────
log "Copying root-level config files"

# The repo's `root/` tree mirrors the destination filesystem layout
# (paths relative to /). Copy it over recursively.
sudo cp -r --preserve=mode,timestamps "$BACKUP_ROOT/." /

# Make /usr/local/bin scripts executable
sudo chmod +x /usr/local/bin/{bilal,confet,hyprland-minimizer,snapper-systemd-boot.sh}

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
sudo sed -Ei 's/CriticalPowerAction=HybridSleep/CriticalPowerAction=PowerOff/' \
  /etc/UPower/UPower.conf
ok "Stop timeout 3 s, critical power action → PowerOff"

# ── 8. Snapper + systemd-boot ──────────────────────────────────
log "Snapper + systemd-boot"
sudo systemctl daemon-reload
sudo systemctl enable snapper-cleanup.timer snapper-timeline.timer
sudo systemctl enable --now snapper-systemd-boot.path
sudo /usr/local/bin/snapper-systemd-boot.sh || true
sudo bootctl update --graceful 2>/dev/null || true
ok "Snapper + systemd-boot"

# ── 9. GTK dark mode ───────────────────────────────────────────
log "GTK dark mode"
gsettings set org.gnome.desktop.interface color-scheme prefer-dark
gsettings set org.gnome.desktop.interface gtk-theme Tokyonight-Dark
sudo flatpak override --filesystem="$HOME/.themes"
ok "Done"

# ── 10. Samba ──────────────────────────────────────────────────
log "Samba setup"
sudo systemctl enable --now smb nmb

sudo cp /usr/lib/systemd/system/{nmb,smb}.service /etc/systemd/system/
sudo sed -i 's/^Wants=network-online.target/Wants=network.target/' \
  /etc/systemd/system/nmb.service /etc/systemd/system/smb.service
sudo sed -i 's/^After=network.target network-online.target$/After=network.target/' \
  /etc/systemd/system/nmb.service
sudo sed -i 's/^After=network.target network-online.target nmb/After=network.target nmb/' \
  /etc/systemd/system/smb.service
sudo sed -i '/^\[Service\]$/i ExecStartPost=/usr/bin/systemctl start smb.service' \
  /etc/systemd/system/nmb.service
sudo sed -i '/^WantedBy=multi-user.target$/d' \
  /etc/systemd/system/nmb.service /etc/systemd/system/smb.service
sudo bash -c 'cat > /etc/systemd/system/nmb-delay.timer << "EOF"
[Unit]
Description=Delay nmb.service + smb.service until after boot

[Timer]
Unit=nmb.service
OnBootSec=5s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF'
sudo systemctl daemon-reload
sudo systemctl disable --now nmb.service smb.service 2>/dev/null || true
sudo systemctl enable --now nmb-delay.timer
ok "Samba services delayed 5s after boot via timer"

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

sudo systemctl restart smb nmb
ok "Samba running"

# ── 11. Virtualization (KVM/libvirt) ───────────────────────────
log "Virtualization setup"
paru -S --needed --noconfirm qemu-full virt-manager virt-viewer dnsmasq

sudo cp /usr/lib/systemd/system/libvirtd.service /etc/systemd/system/libvirtd.service
sudo sed -i '/^After=network.target$/d; /^After=remote-fs.target$/d' \
  /etc/systemd/system/libvirtd.service
sudo sed -i '/^WantedBy=multi-user.target$/d' \
  /etc/systemd/system/libvirtd.service
sudo bash -c 'cat > /etc/systemd/system/libvirtd.service.d/10-secret.conf << "EOF"
[Unit]
Requires=virt-secret-init-encryption.service
After=virt-secret-init-encryption.service

[Service]
Environment=SECRETS_ENCRYPTION_KEY=%d/secrets-encryption-key
LoadCredentialEncrypted=secrets-encryption-key:/var/lib/libvirt/secrets/secrets-encryption-key
EOF'
sudo bash -c 'cat > /etc/systemd/system/libvirtd-delay.timer << "EOF"
[Unit]
Description=Delay libvirtd.service until after boot

[Timer]
Unit=libvirtd.service
OnBootSec=5s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF'
sudo systemctl daemon-reload
sudo systemctl disable --now libvirtd.service 2>/dev/null || true
sudo systemctl disable --now libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null || true
sudo systemctl enable --now virtlogd.service virtlogd.socket 2>/dev/null || true
sudo systemctl enable --now libvirtd-delay.timer
ok "libvirtd delayed 5s after boot via timer"

sudo virsh net-autostart default
sudo virsh net-start default 2>/dev/null || true

if id -nG "$(whoami)" | grep -qw libvirt; then
  skip "$(whoami) already in libvirt group"
else
  sudo usermod -aG libvirt "$(whoami)"
  ok "Added $(whoami) to libvirt group (re-login for it to take effect)"
fi

# ── 12. Remaining services ─────────────────────────────────────
log "Enabling services"
for svc in auto-cpufreq cups kanata.service systemd-timesyncd vnstat.service bluetooth.service fprintd.service waydroid-container.service switch-to-tty1-shutdown.service; do
  sudo systemctl enable --now "$svc" && ok "$svc"
done
sudo waydroid init -s GAPPS 2>/dev/null || true
ok "waydroid GAPPS"

# ── 13. Global npm packages ────────────────────────────────────
log "Global npm/pnpm packages"
pnpm add -g neovim live-server typescript tsx free-coding-models
ok "neovim, live-server, typescript, tsx, free-coding-models"

# ── 14. Flatpak apps ───────────────────────────────────────────
log "Flatpak apps"
flatpak install -y --noninteractive flathub \
  io.github._0xzer0x.qurancompanion \
  net.sapples.LiveCaptions
ok "Flatpak apps installed"

# ── 15. Root account symlinks ──────────────────────────────────
log "Root user symlinks"
sudo bash -s <<'ROOT'
  set -euo pipefail

  SYSCTL_FILE=/etc/sysctl.d/99-sysctl.conf
  if [[ -f "$SYSCTL_FILE" ]] && grep -qx 'kernel.sysrq = 1' "$SYSCTL_FILE"; then
    echo "    → kernel.sysrq already set, skipping"
  else
    echo "kernel.sysrq = 1" >> "$SYSCTL_FILE"
    echo "    ✓ kernel.sysrq = 1 added"
  fi

  USER_HOME=/home/muhammad
  rm -rf \
    /root/.local/share/nvim /root/.config/nvim \
    /root/.zshrc /root/.config/zsh \
    /root/.themes /root/.icons /root/.fonts \
    /root/.config/gtk-{2,3,4}.0

  for d in gtk-2.0 gtk-3.0 gtk-4.0 kanata nvim yazi zsh; do
    ln -sfn "$USER_HOME/.config/$d" /root/.config/
  done
  for d in .fonts .icons .themes; do
    ln -sfn "$USER_HOME/$d" /root/
  done
  ln -sfn "$USER_HOME/.local/share/nvim" /root/.local/share/
  ln -sfn "$USER_HOME/.zshrc" /root/
  echo "    ✓ Root symlinks created"
ROOT

# ── Done ──────────────────────────────────────────────────────
log "All done! Re-login (or reboot) for group changes to take effect."
