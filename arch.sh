cat > arch-dualboot-auto.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ================= USER OPTIONS =================
DISK="${1:-/dev/sda}"        # pass /dev/nvme0n1 if needed
ROOT_SIZE_GIB=40
HOME_SIZE_GIB=16
SWAP_SIZE_GIB=4
TZ="Asia/Kolkata"
LANG_LOCALE="en_US.UTF-8"
HOST="arkagrawal"
INSTALL_GNOME=true
INSTALL_BT=true
INSTALL_TLP=true
CREATE_USER=true
USERNAME="arkagrawal"
# ================================================

say()  { printf "\n\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m%s\033[0m\n" "$*"; }
err()  { printf "\n\033[1;31m%s\033[0m\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { err "Missing tool: $1"; exit 1; }; }

need lsblk; need parted; need awk; need sed; need mkfs.ext4; need mkswap

say "=== Arch Dual-Boot Installer (GNOME/Wi-Fi/BT/Audio/TLP) ==="
say "Target disk: ${DISK}"

# 0) Optional Wi-Fi connect in live ISO
say "Wi-Fi: enter SSID to connect now (or press Enter to skip):"
read -r WIFI_SSID
if [[ -n "${WIFI_SSID}" ]]; then
  read -srp "Wi-Fi password (hidden): " WIFI_PASS; echo
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
  ping -c1 -W2 archlinux.org >/dev/null 2>&1 && say "Internet OK" || warn "No Internet; pacstrap may fail."
else
  warn "Skipping Wi-Fi connect in live ISO."
fi

# 1) Show current layout
say "Current partition table:"
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,PARTLABEL,PARTFLAGS,MOUNTPOINT "${DISK}"

# 2) Detect existing EFI (reuse, do NOT format)
say "Detecting EFI (FAT32 + esp)…"
EFI_PART="$(lsblk -rno NAME,FSTYPE,PARTTYPENAME,PARTFLAGS "${DISK}" \
  | awk '$2 ~ /vfat|fat32/i && ($3 ~ /EFI System/ || $4 ~ /esp/) {print $1; exit}')"
[[ -z "${EFI_PART}" ]] && { err "EFI partition not found. Aborting for safety."; exit 1; }
EFI_DEV="/dev/${EFI_PART}"
say "EFI partition: ${EFI_DEV} (will be mounted at /boot, NOT formatted)"

# 3) Confirmation
warn "This creates 3 NEW partitions at the END of ${DISK} only (root/home/swap). Windows & EFI stay untouched."
read -rp $'\nType EXACTLY: YES I AM SURE  → ' CONF
[[ "${CONF}" == "YES I AM SURE" ]] || { err "Confirmation failed. Aborting."; exit 1; }

# 4) Must be GPT
parted -s "${DISK}" print | grep -qi 'Partition Table: gpt' \
  || { err "Disk is not GPT. Convert to GPT to keep UEFI intact."; exit 1; }

# 5) Check free space at disk tail
TOTAL_NEED=$(( ROOT_SIZE_GIB + HOME_SIZE_GIB + SWAP_SIZE_GIB ))
say "Need ~${TOTAL_NEED} GiB free at END of disk."
FREE_TAIL_GIB="$(parted -sm "${DISK}" unit GiB print free \
  | awk -F: '$1 ~ /^'"${DISK//\//\\/}"'/ && $7 ~ /free/ {gsub(/GiB/,"",$3); gsub(/GiB/,"",$2); sz=$3-$2; last=$0; size=sz} END{if(size){printf "%.0f", size}else{print 0}}')"
(( FREE_TAIL_GIB >= TOTAL_NEED )) || { err "Not enough tail space. Need ${TOTAL_NEED} GiB, have ${FREE_TAIL_GIB} GiB. Delete Fedora from Windows first."; exit 1; }
say "Free tail space OK: ${FREE_TAIL_GIB} GiB"

# 6) Create partitions at the end
say "Creating partitions…"
parted -s "${DISK}" \
  mkpart arch_root ext4 "-${TOTAL_NEED}GiB" "-$(( HOME_SIZE_GIB + SWAP_SIZE_GIB ))GiB" \
  mkpart arch_home ext4 "-$(( HOME_SIZE_GIB + SWAP_SIZE_GIB ))GiB" "-${SWAP_SIZE_GIB}GiB" \
  mkpart arch_swap linux-swap "-${SWAP_SIZE_GIB}GiB" "100%"

# 7) Identify them (last three parts)
readarray -t NEW_PARTS < <(lsblk -nrpo NAME,TYPE "${DISK}" | awk '$2=="part"{print $1}' | tail -n3)
ROOT_DEV="${NEW_PARTS[0]}"; HOME_DEV="${NEW_PARTS[1]}"; SWAP_DEV="${NEW_PARTS[2]}"
say "Root: ${ROOT_DEV} | Home: ${HOME_DEV} | Swap: ${SWAP_DEV}"

# 8) Make filesystems
mkfs.ext4 -F "${ROOT_DEV}"
mkfs.ext4 -F "${HOME_DEV}"
mkswap "${SWAP_DEV}"
swapon "${SWAP_DEV}"

# 9) Mount target
mount "${ROOT_DEV}" /mnt
mkdir -p /mnt/home && mount "${HOME_DEV}" /mnt/home
mkdir -p /mnt/boot && mount "${EFI_DEV}" /mnt/boot

# 10) Install base + drivers + tools
PKGS_BASE=(base linux linux-firmware vim nano networkmanager grub efibootmgr os-prober intel-ucode)
PKGS_AUDIO=(pipewire pipewire-alsa pipewire-pulse wireplumber)
PKGS_BT=(); $INSTALL_BT && PKGS_BT=(bluez bluez-utils)
PKGS_LAPTOP=(); $INSTALL_TLP && PKGS_LAPTOP=(tlp)
say "Installing base system…"
pacstrap /mnt "${PKGS_BASE[@]}" "${PKGS_AUDIO[@]}" "${PKGS_BT[@]}" "${PKGS_LAPTOP[@]}"

# 11) fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 12) Configure in chroot
arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc
grep -q '^${LANG_LOCALE} ' /etc/locale.gen || echo '${LANG_LOCALE} UTF-8' >> /etc/locale.gen
sed -i 's/^#\s*${LANG_LOCALE}/${LANG_LOCALE}/' /etc/locale.gen || true
locale-gen
echo 'LANG=${LANG_LOCALE}' > /etc/locale.conf
echo '${HOST}' > /etc/hostname

systemctl enable NetworkManager
$INSTALL_BT && systemctl enable bluetooth || true
$INSTALL_TLP && systemctl enable tlp || true

# GRUB with Windows detection
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

if ${CREATE_USER}; then
  pacman -S --noconfirm sudo
  id -u ${USERNAME} >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash ${USERNAME}
  echo "Set password for user ${USERNAME}:"
  passwd ${USERNAME}
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

if ${INSTALL_GNOME}; then
  pacman -S --noconfirm gnome gdm
  systemctl enable gdm
fi
CHROOT

umount -R /mnt || true
swapoff "${SWAP_DEV}" || true
say "=== SUCCESS ===  Reboot to GRUB (Arch + Windows).  Run:  reboot"
EOF

chmod +x arch-dualboot-auto.sh
# If your Windows disk is not /dev/sda, pass it (e.g., /dev/nvme0n1):
./arch-dualboot-auto.sh           # or: ./arch-dualboot-auto.sh /dev/nvme0n1
