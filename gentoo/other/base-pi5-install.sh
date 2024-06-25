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
CMDLINE_CONSOLE=${7:-"console=tty1"}
CMDLINE_EXTRA=${8:-"dwc_otg.lpm_enable=0 rootfstype=ext4 rootwait cma=256M@256M net.ifnames=0"}
CONFIG_AUDIO=${9:-"dtparam=audio=on"}
CONFIG_OVERLAY=${10:-"dtoverlay=vc4-kms-v3d-pi5"}
CONFIG_MAX_FRAMEBUFFERS=${11:-"max_framebuffers=2"}
CONFIG_FW_KMS_SETUP=${12:-"disable_fw_kms_setup=1"}
CONFIG_64BIT=${13:-"arm_64bit=1"}
CONFIG_OVERSCAN=${14:-"disable_overscan=1"}
CONFIG_ARM_BOOST=${15:-"arm_boost=1"}
CONFIG_OTG_MODE=${16:-"otg_mode=1"}
CONFIG_PCIE=${17:-"dtparam=pciex1"}
CONFIG_PCIE_GEN=${18:-"dtparam=pciex1_gen=3"}
CONFIG_USB_POWER=${19:-"usb_max_current_enable=1"}
USERNAME=${20:-skywalker}
PASSWORD=${21:-C0ntroll3d}
EXTRA_PACKAGES=${22:-""}

# Help function
function display_help() {
    echo "Usage: $0 [TARGET_DRIVE] [BOOT_SIZE] [SWAP_SIZE] [STAGE3_URL] [PORTAGE_SNAPSHOT_URL] [HOSTNAME] [CMDLINE_CONSOLE] [CMDLINE_EXTRA] [CONFIG_AUDIO] [CONFIG_OVERLAY] [CONFIG_MAX_FRAMEBUFFERS] [CONFIG_FW_KMS_SETUP] [CONFIG_64BIT] [CONFIG_OVERSCAN] [CONFIG_ARM_BOOST] [CONFIG_OTG_MODE] [CONFIG_PCIE] [CONFIG_PCIE_GEN] [CONFIG_USB_POWER] [USERNAME] [PASSWORD] [EXTRA_PACKAGES]"
    echo
    echo "Arguments:"
    echo "  TARGET_DRIVE         The target drive to install Gentoo (default: /dev/sdb)"
    echo "  BOOT_SIZE            The size of the boot partition (default: 256M)"
    echo "  SWAP_SIZE            The size of the swap partition (default: 8G)"
    echo "  STAGE3_URL           The URL to download the stage3 tarball (default: https://distfiles.gentoo.org/releases/arm64/autobuilds/20240623T231913Z/stage3-arm64-systemd-20240623T231913Z.tar.xz)"
    echo "  PORTAGE_SNAPSHOT_URL The URL to download the portage snapshot (default: https://distfiles.gentoo.org/snapshots/portage-20240624.tar.bz2)"
    echo "  HOSTNAME             The hostname for the new system (default: gentoo-pi5-router)"
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
    echo "  PASSWORD             The password for the created user (default: C0ntroll3d)"
    echo "  EXTRA_PACKAGES       Additional packages to install in the Gentoo system (default: \"\")"
    exit 0
}

# Display help if requested
if [[ $1 == "-h" || $1 == "--help" ]]; then
    display_help
fi

# Function to unmount any partitions on the target drive
unmount_partitions_on_drive() {
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
    parted --script $TARGET_DRIVE mklabel gpt
    parted --script $TARGET_DRIVE mkpart primary fat32 1MiB ${BOOT_SIZE}
    parted --script $TARGET_DRIVE set 1 boot on
    parted --script $TARGET_DRIVE mkpart primary linux-swap ${BOOT_SIZE} $(echo "${BOOT_SIZE} + ${SWAP_SIZE}" | bc)
    parted --script $TARGET_DRIVE mkpart primary ext4 $(echo "${BOOT_SIZE} + ${SWAP_SIZE}" | bc) 100%
    partprobe $TARGET_DRIVE
}

# Function to format partitions and get UUIDs
format_partitions() {
    mkfs.vfat -F 32 ${TARGET_DRIVE}1
    if [ $? -eq 0 ]; then
        echo "Boot partition formatted successfully."
    else
        echo "Failed to format boot partition." >&2
        exit 1
    fi
    mkswap ${TARGET_DRIVE}2
    UUID_SWAP=$(blkid -s UUID -o value ${TARGET_DRIVE}2)
    if [ $? -eq 0 ]; then
        echo "Swap partition formatted successfully."
    else
        echo "Failed to format swap partition." >&2
        exit 1
    fi
    yes | mkfs.ext4 ${TARGET_DRIVE}3
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
}

# Function to set up cmdline.txt and config.txt
setup_boot_config() {
    # Create cmdline.txt
    echo "$CMDLINE_CONSOLE root=UUID=${UUID_ROOT} $CMDLINE_EXTRA" > /mnt/gentoo/boot/cmdline.txt

    # Create config.txt
    {
        echo "$CONFIG_AUDIO"
        echo "$CONFIG_OVERLAY"
        echo "$CONFIG_MAX_FRAMEBUFFERS"
        echo "$CONFIG_FW_KMS_SETUP"
        echo "$CONFIG_64BIT"
        echo "$CONFIG_OVERSCAN"
        echo "$CONFIG_ARM_BOOST"
        echo "[cm4]"
        echo "$CONFIG_OTG_MODE"
        echo "[all]"
        echo "$CONFIG_PCIE"
        echo "$CONFIG_PCIE_GEN"
        echo "$CONFIG_USB_POWER"
    } > /mnt/gentoo/boot/config.txt

    echo "Boot configuration files created:"
    echo "  - /mnt/gentoo/boot/cmdline.txt"
    echo "  - /mnt/gentoo/boot/config.txt"
}

# Function to set up system configuration
setup_system() {
    # Bind necessary filesystems
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev

    # Copy DNS info
    cp /etc/resolv.conf /mnt/gentoo/etc/

    # Ensure binfmt_misc is mounted
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc

    # Register qemu-aarch64 interpreter
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff:/usr/bin/qemu-aarch64-static:CF' > /proc/sys/fs/binfmt_misc/register
    fi

    # Chroot and set up the system
    chroot /mnt/gentoo /bin/bash <<EOF_CHROOT
# Update environment
source /etc/profile
export PS1='(chroot) \[\033[0;31m\]\u\[\033[1;31m\]@\h \[\033[1;34m\]\w \$ \[\033[m\]'

# Uncomment the lines for en_US ISO-8859-1 and en_US.UTF-8 UTF-8 locales
sed -i '/en_US ISO-8859-1/s/^#//g' /etc/locale.gen
sed -i '/en_US.UTF-8 UTF-8/s/^#//g' /etc/locale.gen

locale-gen

# Sync and update portage
eselect news read

# Update make.conf
cat <<EOF_MAKECONF > /etc/portage/make.conf
COMMON_FLAGS="-mcpu=cortex-a76+crc+crypto -mtune=cortex-a76 -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
CHOST="aarch64-unknown-linux-gnu"
LC_MESSAGES=C.utf8
ACCEPT_LICENSE="*"
MAKEOPTS="-j5"
EOF_MAKECONF

# Create necessary directories for package configurations
mkdir -p /etc/portage/package.use
mkdir -p /etc/portage/package.accept_keywords
echo ">=net-wireless/wpa_supplicant-2.10-r4 dbus" > /etc/portage/package.use/networkmanager

# Sync portage tree
emerge --sync

# Update world set
emerge -uDN @world

# Install essential packages
USE="-modemmanager -ppp -gtk-doc -introspection -concheck" emerge --verbose --autounmask-continue=y net-misc/networkmanager
emerge --verbose --autounmask-continue=y net-misc/openssh net-misc/chrony app-admin/sudo wget git parted curl tree vim neofetch ${EXTRA_PACKAGES}

# Set up NetworkManager
systemctl enable NetworkManager

# Set up OpenSSH
systemctl enable sshd
sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
echo "SSH root login has been disabled."

# Add user
useradd -m -G users,wheel -s /bin/bash ${USERNAME}
echo -e "${PASSWORD}\n${PASSWORD}" | passwd ${USERNAME}
echo "User ${USERNAME} added and password set."

# Configure sudoers
echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
echo "Sudo configuration updated."

# Generate SSH host keys
ssh-keygen -A

# Set hostname
echo "${HOSTNAME}" > /etc/hostname

# Enable and start chrony for time synchronization
systemctl enable chronyd
systemctl start chronyd

EOF_CHROOT

    # Check for errors after chroot
    if [ $? -eq 0 ]; then
        echo "System configuration inside chroot completed successfully."
    else
        echo "System configuration inside chroot failed." >&2
        exit 1
    fi

    # Unmount bind mounts
    umount -l /mnt/gentoo/dev{/shm,/pts,}
    umount /mnt/gentoo/boot
    umount -R /mnt/gentoo
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

install_gentoo
if [ $? -eq 0 ]; then
    echo "Gentoo base system installed successfully."
else
    echo "Failed to install Gentoo base system." >&2
    exit 1
fi

install_portage_snapshot
if [ $? -eq 0 ]; then
    echo "Portage snapshot installed successfully."
else
    echo "Failed to install portage snapshot." >&2
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

setup_system
if [ $? -eq 0 ]; then
    echo "System configuration completed successfully."
else
    echo "Failed to complete system configuration." >&2
    exit 1
fi

echo "Gentoo installation for the Raspberry Pi 5 is complete for Drive: ${TARGET_DRIVE}."
