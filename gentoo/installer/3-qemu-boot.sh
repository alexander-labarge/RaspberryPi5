#!/bin/bash

# Ensure script is run as root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Default values for parameters
TARGET_DRIVE=${1:-/dev/sdb}
ROOT_PARTITION="${TARGET_DRIVE}3"
BOOT_PARTITION="${TARGET_DRIVE}1"
GENTOO_MOUNT="/mnt/gentoo"

# Function to install necessary packages
install_packages() {
    apt update
    apt install -y qemu qemu-system qemu-system-arm qemu-user-static libguestfs-tools
    if [ $? -eq 0 ]; then
        echo "Necessary packages installed successfully."
    else
        echo "Failed to install necessary packages." >&2
        exit 1
    fi
}

# Function to mount the partitions
mount_partitions() {
    mkdir -p $GENTOO_MOUNT
    mount $ROOT_PARTITION $GENTOO_MOUNT
    if [ $? -ne 0 ]; then
        echo "Failed to mount root partition." >&2
        exit 1
    fi
    mkdir -p $GENTOO_MOUNT/boot
    mount $BOOT_PARTITION $GENTOO_MOUNT/boot
    if [ $? -ne 0 ]; then
        echo "Failed to mount boot partition." >&2
        exit 1
    fi
}

# Function to unmount the partitions
unmount_partitions() {
    umount $GENTOO_MOUNT/boot
    umount $GENTOO_MOUNT
}

# Function to run QEMU emulation
run_qemu() {
    qemu-system-aarch64 \
        -M virt \
        -cpu cortex-a72 \
        -smp 4 \
        -m 4096 \
        -drive file=${TARGET_DRIVE},format=raw,if=none,id=hd0 \
        -device virtio-blk-drive,drive=hd0 \
        -kernel $GENTOO_MOUNT/boot/kernel8.img \
        -append "root=PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_PARTITION}) rootfstype=ext4 fsck.repair=yes rootwait splash plymouth.ignore-serial-consoles cfg80211.ieee80211_regdom=US" \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-device,netdev=net0 \
        -serial mon:stdio \
        -display gtk
}
qemu-system-aarch64 -nographic -machine virt,gic-version=max -m 512M -cpu max -smp 4
# Main script execution
install_packages
mount_partitions

echo "QEMU setup complete. Now attempting to boot the ARM64 system with QEMU..."
run_qemu

unmount_partitions
