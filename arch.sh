cat > arch-install-manual-root.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ---------- defaults you can change ----------
TZ="Asia/Kolkata"
LOCALE="en_US.UTF-8"
HOSTNAME="arkagrawal"
MAKE_USER=true
USERNAME="arkagrawal"
INSTALL_GNOME=true
INSTALL_BT=true
INSTALL_TLP=true
# --------------------------------------------

ok()   { printf "\n\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m%s\033[0m\n" "$*"; }
err()  { printf "\n\033[1;31m%s\033[0m\n" "$*"; }

require() { command -v "$1" >/dev/null 2>&1 || { err "Missing: $1"; exit 1; }; }
for c in lsblk mount umount mkfs.ext4 mkfs.btrfs pacstrap arch-chroot genfstab grub-install grub-mkconfig; do require "$c"; done

echo
ok "=== Arch Installer (MANUAL ROOT PARTITION MODE) ==="
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTLABEL,PARTFLAGS,MOUNTPOINT

# ---- choose root partition (existing) ----
read -rp $'\nRoot partition device (e.g. /dev/sda7) [default: /dev/sda7]: ' ROOT
ROOT="${ROOT:-/dev/sda7}"
[[ -b "$ROOT" ]] || { err "Device $ROOT not found."; exit 1; }

# ---- format or keep? ----
echo
read -rp "Format $ROOT? [yes/no] (default: yes): " DOFMT
DOFMT="${DOFMT:-yes}"
FS="ext4"
if [[ "$DOFMT" =~ ^[Yy] ]]; then
  read -rp "Filesystem for $ROOT [ext4/btrfs] (default: ext4): " FS
  FS="${FS:-ext4}"
  if [[ "$FS" == "ext4" ]]; then
    warn "About to FORMAT $ROOT as ext4 (data will be lost)."
    read -rp "Type EXACTLY: I UNDERSTAND  → " CONF
    [[ "$CONF" == "I UNDERSTAND" ]] || { err "Confirmation failed."; exit 1; }
    mkfs.ext4 -F "$ROOT"
  elif [[ "$FS" == "btrfs" ]]; then
    warn "Formatting $ROOT as btrfs (simple single-volume root)."
    warn "Note: swapfile on btrfs is advanced; not created here."
    read -rp "Type EXACTLY: I UNDERSTAND  → " CONF
    [[ "$CONF" == "I UNDERSTAND" ]] || { err "Confirmation failed."; exit 1; }
    mkfs.btrfs -f "$ROOT"
  else
    err "Unsupported FS '$FS'. Use ext4 or btrfs."; exit 1;
  fi
else
  ok "Keeping existing filesystem on $ROOT."
fi

# ---- choose EFI partition ----
read -rp $'\nEFI (ESP) partition (vfat) [default: /dev/sda1]: ' ESP
ESP="${ESP:-/dev/sda1}"
[[ -b "$ESP" ]] || { err "Device $ESP not found."; exit 1; }

# final guard
echo
warn "We will mount:"
echo "  ROOT → $ROOT"
echo "  EFI  → $ESP (mounted at /boot; NOT formatted)"
read -rp $'\nType EXACTLY: YES PROCEED  → ' GO
[[ "$GO" == "YES PROCEED" ]] || { err "Aborted."; exit 1; }

# ---- mount ----
ok "Mounting target…"
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot

# ---- base packages ----
ok "Installing base system…"
BASE_PKGS=(base linux linux-firmware vim nano networkmanager grub efibootmgr os-prober intel-ucode)
AUDIO_PKGS=(pipewire pipewire-alsa pipewire-pulse wireplumber)
BT_PKGS=(); $INSTALL_BT && BT_PKGS=(bluez bluez-utils)
LAPTOP_PKGS=(); $INSTALL_TLP && LAPTOP_PKGS=(tlp)
GUI_PKGS=(); $INSTALL_GNOME && GUI_PKGS=(gnome gdm)

pacstrap /mnt "${BASE_PKGS[@]}" "${AUDIO_PKGS[@]}" "${BT_PKGS[@]}" "${LAPTOP_PKGS[@]}" "${GUI_PKGS[@]}"

# ---- fstab ----
ok "Generating fstab…"
genfstab -U /mnt >> /mnt/etc/fstab

# ---- configure in chroot ----
ok "Configuring in chroot…"
arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

grep -q '^${LOCALE} ' /etc/locale.gen || echo '${LOCALE} UTF-8' >> /etc/locale.gen
sed -i 's/^#\s*${LOCALE}/${LOCALE}/' /etc/locale.gen || true
locale-gen
echo 'LANG=${LOCALE}' > /etc/locale.conf

echo '${HOSTNAME}' > /etc/hostname

systemctl enable NetworkManager
$INSTALL_BT && systemctl enable bluetooth || true
$INSTALL_TLP && systemctl enable tlp || true
$INSTALL_GNOME && systemctl enable gdm || true

# GRUB + Windows detection
if ! grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub 2>/dev/null; then
  echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
else
  sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
fi
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
os-prober || true
grub-mkconfig -o /boot/grub/grub.cfg

echo "Set ROOT password:"
passwd

if ${MAKE_USER}; then
  pacman -S --noconfirm sudo
  id -u ${USERNAME} >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash ${USERNAME}
  echo "Set password for user ${USERNAME}:"
  passwd ${USERNAME}
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi
CHROOT

ok "Unmounting…"
umount -R /mnt || true

ok "Done! Reboot to GRUB (Arch + Windows)."
echo "Run:  reboot"
EOF

chmod +x arch-install-manual-root.sh