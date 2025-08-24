#!/usr/bin/env bash
set -euo pipefail

# ===================== defaults you can change =====================
TZ="Asia/Kolkata"
LOCALE="en_US.UTF-8"
HOSTNAME="arkagrawal"

MAKE_USER=true
USERNAME="arkagrawal"

INSTALL_GNOME=true   # GNOME + GDM
INSTALL_BT=true      # bluez + bluez-utils
INSTALL_TLP=true     # laptop battery optimizer

# Optional swapfile (ext4 roots only). 0 = skip.
SWAPFILE_GIB=0
# ==================================================================

ok()   { printf "\n\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m%s\033[0m\n" "$*"; }
err()  { printf "\n\033[1;31m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { err "Missing: $1"; exit 1; }; }

for c in lsblk mount umount mkfs.ext4 mkfs.btrfs pacstrap arch-chroot genfstab grub-install grub-mkconfig; do
  need "$c"
done

ok "=== Arch Installer (MANUAL ROOT/ESP) — GNOME/Wi-Fi/BT/Audio/TLP ==="
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTLABEL,PARTFLAGS,MOUNTPOINT

# ------------------ optional Wi-Fi connect in LIVE ISO ------------------
echo
read -rp "Wi-Fi SSID (press Enter to skip): " WIFI_SSID
if [[ -n "${WIFI_SSID}" ]]; then
  read -srp "Wi-Fi password: " WIFI_PASS; echo
  if command -v iwctl >/dev/null 2>&1; then
    WLAN_DEV="$(iwctl device list 2>/dev/null | awk '/wlan|wifi|station/ {print $2; exit}')"
    [[ -z "${WLAN_DEV}" ]] && WLAN_DEV="wlan0"
    set +e
    iwctl --passphrase "${WIFI_PASS}" station "${WLAN_DEV}" connect "${WIFI_SSID}" >/dev/null 2>&1
    RC=$?
    set -e
    if (( RC != 0 )) && command -v nmcli >/dev/null 2>&1; then
      warn "iwctl failed, trying nmcli…"
      nmcli dev wifi connect "${WIFI_SSID}" password "${WIFI_PASS}" || warn "nmcli also failed."
    fi
  fi
  ping -c1 -W2 archlinux.org >/dev/null 2>&1 && ok "Internet OK" || warn "No Internet; pacstrap may fail."
fi
# ------------------------------------------------------------------------

# ---------------------- choose root partition ---------------------------
echo
read -rp "Root partition device (e.g. /dev/sda7) [default: /dev/sda7]: " ROOT
ROOT="${ROOT:-/dev/sda7}"
[[ -b "$ROOT" ]] || { err "Device $ROOT not found."; exit 1; }

# format or keep
echo
read -rp "Format $ROOT? [yes/no] (default: yes): " DOFMT
DOFMT="${DOFMT:-yes}"
FS="ext4"
if [[ "$DOFMT" =~ ^[Yy] ]]; then
  read -rp "Filesystem for $ROOT [ext4/btrfs] (default: ext4): " FS
  FS="${FS:-ext4}"
  if [[ "$FS" == "ext4" ]]; then
    warn "Formatting $ROOT as ext4 (data will be lost)."
    read -rp "Type EXACTLY: I UNDERSTAND  → " CONF
    [[ "$CONF" == "I UNDERSTAND" ]] || { err "Confirmation failed."; exit 1; }
    mkfs.ext4 -F "$ROOT"
  elif [[ "$FS" == "btrfs" ]]; then
    warn "Formatting $ROOT as btrfs (simple flat layout)."
    warn "Note: swapfile on btrfs is not created by this script."
    read -rp "Type EXACTLY: I UNDERSTAND  → " CONF
    [[ "$CONF" == "I UNDERSTAND" ]] || { err "Confirmation failed."; exit 1; }
    mkfs.btrfs -f "$ROOT"
  else
    err "Unsupported FS '$FS'. Use ext4 or btrfs."; exit 1
  fi
else
  ok "Keeping existing filesystem on $ROOT."
  # detect FS if keeping
  FS="$(lsblk -no FSTYPE "$ROOT" || echo ext4)"
fi

# ----------------------- choose EFI (ESP) partition ---------------------
echo
read -rp "EFI (ESP) partition (vfat) [default: /dev/sda1]: " ESP
ESP="${ESP:-/dev/sda1}"
[[ -b "$ESP" ]] || { err "Device $ESP not found."; exit 1; }

# Final guard prompt
echo
warn "We will mount:"
echo "  ROOT → $ROOT  (fs: $FS)"
echo "  ESP  → $ESP   (mounted at /boot/efi; NOT formatted)"
read -rp $'\nType EXACTLY: YES PROCEED  → ' GO
[[ "$GO" == "YES PROCEED" ]] || { err "Aborted."; exit 1; }

# ---------------------------- mount targets -----------------------------
ok "Mounting target…"
mount "$ROOT" /mnt

# ensure /boot exists on root and is clean
mkdir -p /mnt/boot
# If /boot/grub is a stray file from previous attempts, remove it
if [[ -f /mnt/boot/grub ]]; then
  warn "/boot/grub is a file — removing to avoid grub-install conflict."
  rm -f /mnt/boot/grub
fi
mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi
# ------------------------------------------------------------------------

# ---------------------------- install base ------------------------------
ok "Installing base system (this may take a few minutes)…"
BASE_PKGS=(base linux linux-firmware vim nano networkmanager grub efibootmgr os-prober intel-ucode)
AUDIO_PKGS=(pipewire pipewire-alsa pipewire-pulse wireplumber)
BT_PKGS=();     $INSTALL_BT   && BT_PKGS=(bluez bluez-utils)
LAPTOP_PKGS=(); $INSTALL_TLP  && LAPTOP_PKGS=(tlp)
GUI_PKGS=();    $INSTALL_GNOME && GUI_PKGS=(gnome gdm)

pacstrap /mnt "${BASE_PKGS[@]}" "${AUDIO_PKGS[@]}" "${BT_PKGS[@]}" "${LAPTOP_PKGS[@]}" "${GUI_PKGS[@]}"
# ------------------------------------------------------------------------

# ------------------------------ fstab -----------------------------------
ok "Generating fstab…"
genfstab -U /mnt >> /mnt/etc/fstab
# ------------------------------------------------------------------------

# -------------------------- configure system ----------------------------
ok "Configuring system in chroot…"
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
$INSTALL_BT   && systemctl enable bluetooth || true
$INSTALL_TLP  && systemctl enable tlp       || true
$INSTALL_GNOME && systemctl enable gdm      || true

# Ensure /boot/grub is a directory (not a file)
if [ -f /boot/grub ]; then
  rm -f /boot/grub
fi
mkdir -p /boot/grub

# GRUB + Windows detection
if ! grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub 2>/dev/null; then
  echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
else
  sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
os-prober || true
grub-mkconfig -o /boot/grub/grub.cfg

# Optional swapfile for ext4 roots
if [ "${SWAPFILE_GIB}" -gt 0 ] && grep -q 'ext4' <(findmnt -nro FSTYPE /); then
  echo "Creating ${SWAPFILE_GIB}G swapfile on ext4 root…"
  fallocate -l ${SWAPFILE_GIB}G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

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
# ------------------------------------------------------------------------

ok "Unmounting…"
umount -R /mnt || true

ok "Done! Reboot to GRUB (Arch + Windows)."
echo "Run:  reboot"