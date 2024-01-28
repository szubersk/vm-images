#!/bin/bash

set -euo pipefail

[[ ${V-} != 1 ]] || set -x

if [[ ${EATMYDATA-} != 1 ]]; then
  exec env EATMYDATA=1 eatmydata -- "${BASH_SOURCE[0]}" "$@"
fi

umask 0022

trap 'trap "" ABRT HUP INT PIPE QUIT TERM EXIT; umount -R /dev /sys /proc' EXIT
mount --make-private -t devtmpfs devtmpfs /dev
mount --make-private -t proc proc /proc
mount --make-private -t sysfs sysfs /sys

echo vm.local >/etc/hostname
hostname -F /etc/hostname

cat <<EOF >/etc/kernel-img.conf
do_symlinks = no
EOF

dpkg_arch=$(dpkg --print-architecture)
kernel_pkg=linux-image-cloud-$dpkg_arch
opendoas_pkg=opendoas
user=debian

. /etc/os-release
# shellcheck disable=SC2154
if [[ $ID == ubuntu ]]; then
  kernel_pkg=linux-image-virtual
  user=ubuntu
  opendoas_pkg=opendoas
  [[ ${VERSION_CODENAME-} != focal ]] || opendoas_pkg=sudo
  [[ ${VERSION_CODENAME-} != jammy ]] || opendoas_pkg=doas
fi

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LANG=C
apt-get -qq update
apt-get -qq dist-upgrade
apt-get -qq install --no-install-recommends \
  btrfs-progs \
  gdisk \
  "grub-efi-$dpkg_arch" \
  initramfs-tools \
  isc-dhcp-client \
  "$kernel_pkg" \
  man-db \
  "$opendoas_pkg" \
  openntpd \
  openssh-server \
  systemd-sysv \
  wget \
  zstd
apt-get clean

chattr +C /var/log/journal

cat <<EOF >/etc/dhcp/dhclient-enter-hooks.d/dns_settings
#!/bin/sh

make_resolv_conf() {
  :
}
EOF

groupadd --gid 1000 "$user"
useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home "$user"
[[ $opendoas_pkg != sudo ]] || usermod --append --groups sudo "$user"
{
  echo "$user"
  echo "$user"
} | passwd "$user"

if [[ $opendoas_pkg == opendoas ]]; then
  {
    echo "permit keepenv nopass root"
    echo "permit keepenv nopass $user"
  } >/etc/doas.conf
  chmod 0600 /etc/doas.conf
  doas -C /etc/doas.conf
else
  sed -i '/^%/ s@ALL$@NOPASSWD: ALL@g' /etc/sudoers
fi

cat <<EOF >/etc/default/openntpd
# /etc/default/openntpd

# Append '-s' to set the system time when starting in case the offset
# between the local clock and the servers is more than 180 seconds.
# For other options, see man ntpd(8).
DAEMON_OPTS="-s -f /etc/openntpd/ntpd.conf"
EOF

cat <<EOF >/etc/openntpd/ntpd.conf
servers pool.ntp.org
sensor *
EOF

cp -a /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount
systemctl enable vm-init.service ssh.service tmp.mount
systemctl set-default multi-user.target

cat <<EOF >/etc/default/grub
GRUB_CMDLINE_LINUX="quiet console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 net.ifnames=1 processor.max_cstate=0 systemd.show_status=true systemd.unified_cgroup_hierarchy=false"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_DEFAULT=0
GRUB_DISABLE_LINUX_PARTUUID=false
GRUB_DISABLE_LINUX_UUID=false
GRUB_TERMINAL="console serial"
GRUB_TIMEOUT=1
EOF

{
  uuid=$(grub-probe -t fs_uuid /)
  echo "UUID=$uuid / btrfs autodefrag,compress=zstd,lazytime,noatime,user_subvol_rm_allowed"
  uuid=$(grub-probe -t fs_uuid /boot)
  echo "UUID=$uuid /boot vfat defaults"
} | column -t >/etc/fstab

update-grub2

if [[ $dpkg_arch == amd64 ]]; then
  grub-install --recheck --no-uefi-secure-boot --target "x86_64-efi" --efi-directory=/boot --bootloader-id=boot
else
  grub-install --recheck --no-uefi-secure-boot --efi-directory=/boot --bootloader-id=boot
fi

efi=$(echo /boot/EFI/boot/grub*.efi)
mv "$efi" "${efi/grub/boot}"

rm -rf /tmp/* /var/tmp/* /var/log/journal/*
