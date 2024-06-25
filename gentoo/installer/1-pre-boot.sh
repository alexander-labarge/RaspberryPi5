#!/bin/bash

# Ensure script is run as root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Default values for parameters
TARGET_DRIVE=${1:-/dev/sdb}
BOOT_SIZE=${2:-256M}
SWAP_SIZE=${3:-8G}
STAGE3_URL=${4:-https://distfiles.gentoo.org/releases/arm64/autobuilds/20240623T231913Z/stage3-arm64-systemd-20240623T231913Z.tar.xz}
PORTAGE_SNAPSHOT_URL=${5:-https://distfiles.gentoo.org/snapshots/portage-20240624.tar.bz2}
HOSTNAME=${6:-gentoo-pi5-router}
ROOT_PASSWORD_HASH=${7:-$(openssl passwd -6 "skywalker")}
CMDLINE_CONSOLE=${8:-"console=tty1"}
CMDLINE_EXTRA=${9:-"dwc_otg.lpm_enable=0 rootfstype=ext4 rootwait"}
CONFIG_AUDIO=${10:-"dtparam=audio=on"}
CONFIG_OVERLAY=${11:-"dtoverlay=vc4-kms-v3d-pi5"}
CONFIG_MAX_FRAMEBUFFERS=${12:-"max_framebuffers=2"}
CONFIG_FW_KMS_SETUP=${13:-"disable_fw_kms_setup=1"}
CONFIG_64BIT=${14:-"arm_64bit=1"}
CONFIG_OVERSCAN=${15:-"disable_overscan=1"}
CONFIG_ARM_BOOST=${16:-"arm_boost=1"}
CONFIG_OTG_MODE=${17:-"otg_mode=1"}
CONFIG_PCIE=${18:-"dtparam=pciex1"}
CONFIG_PCIE_GEN=${19:-"dtparam=pciex1_gen=3"}
CONFIG_USB_POWER=${20:-"usb_max_current_enable=1"}
USERNAME=${21:-skywalker}
PASSWORD=${22:-skywalker}
EXTRA_PACKAGES=${23:-""}

# Help function
function display_help() {
    echo "Usage: $0 [TARGET_DRIVE] [BOOT_SIZE] [SWAP_SIZE] [STAGE3_URL] [PORTAGE_SNAPSHOT_URL] [HOSTNAME] [ROOT_PASSWORD_HASH] [CMDLINE_CONSOLE] [CMDLINE_EXTRA] [CONFIG_AUDIO] [CONFIG_OVERLAY] [CONFIG_MAX_FRAMEBUFFERS] [CONFIG_FW_KMS_SETUP] [CONFIG_64BIT] [CONFIG_OVERSCAN] [CONFIG_ARM_BOOST] [CONFIG_OTG_MODE] [CONFIG_PCIE] [CONFIG_PCIE_GEN] [CONFIG_USB_POWER] [USERNAME] [PASSWORD] [EXTRA_PACKAGES]"
    echo
    echo "Arguments:"
    echo "  TARGET_DRIVE         The target drive to install Gentoo (default: /dev/sda)"
    echo "  BOOT_SIZE            The size of the boot partition (default: 256M)"
    echo "  SWAP_SIZE            The size of the swap partition (default: 8G)"
    echo "  STAGE3_URL           The URL to download the stage3 tarball (default: https://distfiles.gentoo.org/releases/arm64/autobuilds/20240623T231913Z/stage3-arm64-systemd-20240623T231913Z.tar.xz)"
    echo "  PORTAGE_SNAPSHOT_URL The URL to download the portage snapshot (default: https://distfiles.gentoo.org/snapshots/portage-20240624.tar.bz2)"
    echo "  HOSTNAME             The hostname for the new system (default: gentoo-pi5-router)"
    echo "  ROOT_PASSWORD_HASH   The hashed root password (default: hashed 'skywalker')"
    echo "  CMDLINE_CONSOLE      The console parameter for cmdline.txt (default: console=tty1)"
    echo "  CMDLINE_EXTRA        Additional parameters for cmdline.txt (default: dwc_otg.lpm_enable=0 rootfstype=ext4 rootwait cma=256M@256M net.ifnames=0)"
    echo "  CONFIG_AUDIO         The audio parameter for config.txt (default: dtparam=audio=on)"
    echo "  CONFIG_OVERLAY       The overlay parameter for config.txt (default: dtoverlay=vc4-kms-v3d)"
    echo "  CONFIG_MAX_FRAMEBUFFERS The max framebuffers parameter for config.txt (default: max_framebuffers=2)"
    echo "  CONFIG_FW_KMS_SETUP  The firmware KMS setup parameter for config.txt (default: disable_fw_kms_setup=1)"
    echo "  CONFIG_64BIT         The 64-bit mode parameter for config.txt (default: arm_64bit=1)"
    echo "  CONFIG_OVERSCAN      The overscan parameter for config.txt (default: disable_overscan=1)"
    echo "  CONFIG_ARM_BOOST     The ARM boost parameter for config.txt (default: arm_boost=1)"
    echo "  CONFIG_OTG_MODE      The OTG mode parameter for config.txt (default: otg_mode=1)"
    echo "  CONFIG_PCIE          The PCIe parameter for config.txt (default: dtparam=pciex1)"
    echo "  CONFIG_PCIE_GEN      The PCIe generation parameter for config.txt (default: dtparam=pciex1_gen=3)"
    echo "  CONFIG_USB_POWER     The USB power parameter for config.txt (default: usb_max_current_enable=1)"
    echo "  USERNAME             The username to create (default: skywalker)"
    echo "  PASSWORD             The password for the created user (default: skywalker)"
    echo "  EXTRA_PACKAGES       Additional packages to install in the Gentoo system (default: \"\")"
    exit 0
}

# Display help if requested
if [[ $1 == "-h" || $1 == "--help" ]]; then
    display_help
fi

# Function to unmount any partitions on the target drive
unmount_partitions_on_drive() {
    partprobe ${TARGET_DRIVE}
    local drive=$1
    local partitions=$(lsblk -ln -o NAME,MOUNTPOINT | grep "^$(basename $drive)" | awk '{print $2}' | grep "/")
    
    if [ -n "$partitions" ]; then
        for partition in $partitions; do
            umount -f $partition || umount -l $partition
            if [ $? -eq 0 ]; then
                echo "Unmounted $partition successfully."
            else
                echo "Failed to unmount $partition." >&2
                exit 1
            fi
        done
    fi
}

# Unmount any partitions on the target drive
unmount_partitions_on_drive $TARGET_DRIVE

# Ensure necessary tools are installed
apt-get update && apt-get install -y qemu-user-static debootstrap wget git parted curl tree vim neofetch
if [ $? -eq 0 ]; then
    echo "Necessary tools installed successfully."
else
    echo "Failed to install necessary tools." >&2
    exit 1
fi

# Create /mnt/gentoo if it does not exist
mkdir -p /mnt/gentoo
if [ $? -eq 0 ]; then
    echo "/mnt/gentoo directory created successfully."
else
    echo "Failed to create /mnt/gentoo directory." >&2
    exit 1
fi

# Function to create partitions
create_partitions() {
    echo "WARNING: This will destroy all data on ${TARGET_DRIVE}."
    read -p "Are you sure you want to proceed? (y/N): " confirm

    if [[ $confirm != [yY] && $confirm != [yY][eE][sS] ]]; then
        echo "Operation aborted."
        exit 1
    fi

    {
        echo g # Create a new GPT partition table
        echo n # New partition (EFI System)
        echo   # Default partition number 1
        echo   # Default first sector
        echo +${BOOT_SIZE} # Last sector, size of 256MB for the boot partition
        echo n # New partition (Linux filesystem)
        echo   # Default partition number 2
        echo   # Default first sector
        echo +${SWAP_SIZE} # Last sector, size of 8GB for the swap partition
        echo n # New partition (Linux filesystem)
        echo   # Default partition number 3
        echo   # Default first sector
        echo   # Use remaining space for the root filesystem
        echo t # Change partition type
        echo 1 # Select first partition
        echo 11 # MSFT FAT NOT EFI
        echo t # Change partition type
        echo 2 # Select second partition
        echo 19 # Set type to Linux swap
        echo w # Write changes and exit
    } | fdisk ${TARGET_DRIVE}
}

# Function to format partitions and get UUIDs
format_partitions() {
    mkfs.vfat ${TARGET_DRIVE}1 # Boot partition
    UUID_BOOT=$(blkid -s UUID -o value ${TARGET_DRIVE}1)
    if [ $? -eq 0 ]; then
        echo "Boot partition formatted successfully."
    else
        echo "Failed to format boot partition." >&2
        exit 1
    fi
    mkswap --pagesize 16384 ${TARGET_DRIVE}2 # Swap partition with specific page size
    UUID_SWAP=$(blkid -s UUID -o value ${TARGET_DRIVE}2)
    if [ $? -eq 0 ]; then
        echo "Swap partition formatted successfully."
    else
        echo "Failed to format swap partition." >&2
        exit 1
    fi
    yes | mkfs.ext4 ${TARGET_DRIVE}3 # Root filesystem
    UUID_ROOT=$(blkid -s UUID -o value ${TARGET_DRIVE}3)
    if [ $? -eq 0 ]; then
        echo "Root partition formatted successfully."
    else
        echo "Failed to format root partition." >&2
        exit 1
    fi
}

# Function to mount partitions and install Gentoo base system
install_gentoo() {
    mount ${TARGET_DRIVE}3 /mnt/gentoo
    if [ $? -eq 0 ]; then
        echo "Root partition mounted successfully."
    else
        echo "Failed to mount root partition." >&2
        exit 1
    fi
    cd /mnt/gentoo
    wget $STAGE3_URL -O stage3.tar.xz
    if [ $? -eq 0 ]; then
        echo "Stage3 tarball downloaded successfully."
    else
        echo "Failed to download stage3 tarball." >&2
        exit 1
    fi
    tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
    if [ $? -eq 0 ]; then
        echo "Stage3 tarball extracted successfully."
    else
        echo "Failed to extract stage3 tarball." >&2
        exit 1
    fi
}

# Function to install portage snapshot
install_portage_snapshot() {
    mkdir -p /mnt/gentoo/var/db/repos/gentoo
    cd /mnt/gentoo/var/db/repos/gentoo
    wget $PORTAGE_SNAPSHOT_URL -O portage.tar.bz2
    if [ $? -eq 0 ]; then
        echo "Portage snapshot downloaded successfully."
    else
        echo "Failed to download portage snapshot." >&2
        exit 1
    fi
    tar xpf portage.tar.bz2 --strip-components=1
    if [ $? -eq 0 ]; then
        echo "Portage snapshot extracted successfully."
    else
        echo "Failed to extract portage snapshot." >&2
        exit 1
    fi
}

# Function to install kernel and firmware
install_kernel_firmware() {
    git clone --depth=1 https://github.com/raspberrypi/firmware.git
    if [ $? -eq 0 ]; then
        echo "Firmware repository cloned successfully."
    else
        echo "Failed to clone firmware repository." >&2
        exit 1
    fi
    mount ${TARGET_DRIVE}1 /mnt/gentoo/boot
    if [ $? -eq 0 ]; then
        echo "Boot partition mounted successfully."
    else
        echo "Failed to mount boot partition." >&2
        exit 1
    fi
    cp firmware/boot/{bcm2712-rpi-5-b.dtb,fixup_cd.dat,fixup.dat,start_cd.elf,start.elf,bootcode.bin,kernel8.img} /mnt/gentoo/boot/
    cp -r firmware/boot/overlays /mnt/gentoo/boot/
    if [ $? -eq 0 ]; then
        echo "Firmware files copied successfully."
    else
        echo "Failed to copy firmware files." >&2
        exit 1
    fi
    # Copy modules
    cp -r firmware/modules /mnt/gentoo/lib/
    if [ $? -eq 0 ]; then
        echo "Kernel modules copied successfully."
    else
        echo "Failed to copy kernel modules." >&2
        exit 1
    fi
}

# Function to set up cmdline.txt and config.txt
setup_boot_config() {
    # Create cmdline.txt line by line
    echo "root=/dev/mmcblk0p3" > /mnt/gentoo/boot/cmdline.txt
    echo "${CMDLINE_CONSOLE}" >> /mnt/gentoo/boot/cmdline.txt
    echo "${CMDLINE_EXTRA}" >> /mnt/gentoo/boot/cmdline.txt

    # Create config.txt
    {
        echo "${CONFIG_AUDIO}"
        echo "${CONFIG_OVERLAY}"
        echo "${CONFIG_MAX_FRAMEBUFFERS}"
        echo "${CONFIG_FW_KMS_SETUP}"
        echo "${CONFIG_64BIT}"
        echo "${CONFIG_OVERSCAN}"
        echo "${CONFIG_ARM_BOOST}"
        echo "[cm4]"
        echo "${CONFIG_OTG_MODE}"
        echo "[all]"
        echo "${CONFIG_PCIE}"
        echo "${CONFIG_PCIE_GEN}"
        echo "${CONFIG_USB_POWER}"
    } > /mnt/gentoo/boot/config.txt

    echo "Boot configuration files created:"
    echo "  - /mnt/gentoo/boot/cmdline.txt"
    echo "  - /mnt/gentoo/boot/config.txt"
}

# Function to copy WiFi and Bluetooth firmware
copy_firmware() {
    git clone --depth=1 https://github.com/RPi-Distro/firmware-nonfree.git
    if [ $? -eq 0 ]; then
        echo "WiFi firmware repository cloned successfully."
    else
        echo "Failed to clone WiFi firmware repository." >&2
        exit 1
    fi
    mkdir -p /mnt/gentoo/lib/firmware/brcm
    cp firmware-nonfree/debian/config/brcm80211/cypress/cyfmac43455-sdio-standard.bin /mnt/gentoo/lib/firmware/brcm/brcmfmac43455-sdio.bin
    cp firmware-nonfree/debian/config/brcm80211/cypress/cyfmac43455-sdio.clm_blob /mnt/gentoo/lib/firmware/brcm/brcmfmac43455-sdio.clm_blob
    cp firmware-nonfree/debian/config/brcm80211/brcm/brcmfmac43455-sdio.txt /mnt/gentoo/lib/firmware/brcm/

    git clone --depth=1 https://github.com/RPi-Distro/bluez-firmware.git
    if [ $? -eq 0 ]; then
        echo "Bluetooth firmware repository cloned successfully."
    else
        echo "Failed to clone Bluetooth firmware repository." >&2
        exit 1
    fi
    cp bluez-firmware/debian/firmware/broadcom/BCM4345C0.hcd /mnt/gentoo/lib/firmware/brcm/
}

# Function to create a symlink if it does not already exist
create_symlink() {
    local target_file=$1
    local symlink_name=$2

    # Check if the symlink already exists
    if [ -L "$symlink_name" ] || [ -e "$symlink_name" ]; then
        echo "Symlink $symlink_name already exists. Skipping."
    else
        # Create the symlink
        ln -s "$target_file" "$symlink_name"
        echo "Created symlink: $symlink_name -> $target_file"
    fi
}

# Function to set up symlinks for firmware
setup_firmware_symlinks() {
    cd /mnt/gentoo/lib/firmware/brcm/

    # Check if the directory change was successful
    if [ $? -ne 0 ]; then
        echo "Failed to navigate to the firmware directory. Exiting."
        exit 1
    fi

    # Create necessary symlinks for Raspberry Pi 5
    create_symlink "brcmfmac43455-sdio.bin" "brcmfmac43455-sdio.raspberrypi,5-model-b.bin"
    create_symlink "brcmfmac43455-sdio.clm_blob" "brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob"
    create_symlink "brcmfmac43455-sdio.txt" "brcmfmac43455-sdio.raspberrypi,5-model-b.txt"
    create_symlink "BCM4345C0.hcd" "BCM4345C0.raspberrypi,5-model-b.hcd"
}

# Function to create fstab
create_fstab() {
    cat <<EOF > /mnt/gentoo/etc/fstab
# <fs>      <mountpoint> <type>  <opts>          <dump/pass>
/dev/mmcblk0p3 /            ext4    noatime         0 1
/dev/mmcblk0p1 /boot        vfat    noatime,noauto,nodev,nosuid,noexec  1 2
/dev/mmcblk0p2 none         swap    defaults        0 0
EOF
}

# Main script execution
create_partitions
if [ $? -eq 0 ]; then
    echo "Partitions created successfully."
else
    echo "Failed to create partitions." >&2
    exit 1
fi

format_partitions
if [ $? -eq 0 ]; then
    echo "Partitions formatted successfully."
else
    echo "Failed to format partitions." >&2
    exit 1
fi

install_portage_snapshot
if [ $? -eq 0 ]; then
    echo "Portage snapshot installed successfully."
else
    echo "Failed to install portage snapshot." >&2
    exit 1
fi

install_gentoo
if [ $? -eq 0 ]; then
    echo "Gentoo base system installed successfully."
else
    echo "Failed to install Gentoo base system." >&2
    exit 1
fi

install_kernel_firmware
if [ $? -eq 0 ]; then
    echo "Kernel and firmware installed successfully."
else
    echo "Failed to install kernel and firmware." >&2
    exit 1
fi

setup_boot_config
if [ $? -eq 0 ]; then
    echo "Boot configuration files created successfully."
else
    echo "Failed to create boot configuration files." >&2
    exit 1
fi

copy_firmware
if [ $? -eq 0 ]; then
    echo "WiFi and Bluetooth firmware copied successfully."
else
    echo "Failed to copy WiFi and Bluetooth firmware." >&2
    exit 1
fi

setup_firmware_symlinks
if [ $? -eq 0 ]; then
    echo "Firmware symlinks created successfully."
else
    echo "Failed to create firmware symlinks." >&2
    exit 1
fi

# Backup the shadow file before making changes
cp /mnt/gentoo/etc/shadow /mnt/gentoo/etc/shadow.backup

# Replace the root password hash directly in the shadow file
sed -i "s|^root:[^:]*:|root:${ROOT_PASSWORD_HASH}:|g" /mnt/gentoo/etc/shadow

# Set the hostname
echo "${HOSTNAME}" > /mnt/gentoo/etc/hostname

# Create fstab
create_fstab
if [ $? -eq 0 ]; then
    echo "fstab created successfully."
else
    echo "Failed to create fstab." >&2
    exit 1
fi

# Unmount the target drive, boot partition first
echo "Attempting to unmount /mnt/gentoo/boot first..."
if umount /mnt/gentoo/boot; then
    echo "Boot partition unmounted successfully."
else
    echo "Failed to unmount boot partition. Attempting forced unmount..."
    umount -lf /mnt/gentoo/boot
fi

echo "Attempting to unmount /mnt/gentoo..."
if umount -R /mnt/gentoo; then
    echo "Drive unmounted successfully."
else
    echo "Failed to unmount the drive. Attempting forced unmount..."
    unmount_partitions_on_drive $TARGET_DRIVE
fi

echo "Gentoo installation for the Raspberry Pi 5 is complete for Drive: ${TARGET_DRIVE}."
echo "Please boot the system and run 2-post-boot.sh to complete the installation."
