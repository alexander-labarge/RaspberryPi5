#!/bin/bash

# Ensure script is run as root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Default values for parameters
USERNAME=${1:-skywalker}
PASSWORD=${2:-skywalker}
EXTRA_PACKAGES=${3:-""}

# Function to set up the system
setup_system() {
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
    systemctl start NetworkManager

    # Set up OpenSSH
    systemctl enable sshd
    systemctl start sshd
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

    # Enable and start chrony for time synchronization
    systemctl enable chronyd
    systemctl start chronyd
}

setup_system

echo "Post-first boot setup for Gentoo on Raspberry Pi 5 is complete."