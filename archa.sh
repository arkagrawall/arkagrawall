#!/usr/bin/env bash
set -euo pipefail

# === Default partitions ===
ROOT="${1:-/dev/sda7}"    # Arch root partition
ESP="${2:-/dev/sda1}"     # EFI System Partition

echo "[INFO] Mounting root (${ROOT}) and ESP (${ESP})..."
mount | grep -q " on /mnt " || mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mount | grep -q " on /mnt/boot/efi " || mount "$ESP" /mnt/boot/efi

# Check if /mnt/boot/grub is a file, remove it
if [[ -f /mnt/boot/grub ]]; then
    echo "[WARN] /mnt/boot/grub is a FILE — removing to avoid conflict..."
    rm -f /mnt/boot/grub
fi
mkdir -p /mnt/boot/grub

echo "[INFO] Entering chroot to fix GRUB..."
arch-chroot /mnt /bin/bash <<'CHROOT'
set -euo pipefail

# Ensure os-prober can run
if ! grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub 2>/dev/null; then
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
else
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
fi

echo "[INFO] Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB

echo "[INFO] Detecting other OS..."
os-prober || true

echo "[INFO] Generating grub.cfg..."
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT

echo "[SUCCESS] GRUB fixed successfully!"
echo "You can now run:  umount -R /mnt && reboot"