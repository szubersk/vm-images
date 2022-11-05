#!/bin/bash

set -exuo pipefail

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

kernel_pkg=linux-image-amd64
(
  . /etc/os-release
  # shellcheck disable=SC2154
  [[ $ID != ubuntu ]]
) || kernel_pkg=linux-image-generic

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LANG=C
apt-get -qq update
apt-get -qq dist-upgrade
apt-get -qq install \
  btrfs-progs \
  doas \
  e2fsprogs \
  gdisk \
  grub-pc \
  isc-dhcp-client \
  "$kernel_pkg" \
  man-db \
  openntpd \
  openssh-server \
  systemd-sysv \
  wget \
  tzdata
apt-get clean
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/* /var/log/journal/*

chattr -R +C /var/log/journal

cat <<EOF >/etc/dhcp/dhclient-enter-hooks.d/dns_settings
#!/bin/sh

make_resolv_conf() {
  :
}
EOF

user=debian
(
  . /etc/os-release
  [[ $ID != ubuntu ]]
) || user=ubuntu
groupadd --gid 1000 "$user"
useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home "$user"
{
  echo "$user"
  echo "$user"
} | passwd "$user"
{
  echo "permit nopass root"
  echo "permit nopass $user"
} >/etc/doas.conf
chmod 0600 /etc/doas.conf
doas -C /etc/doas.conf

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

uuid=$(grub-probe -t fs_uuid /)
echo "UUID=$uuid / btrfs autodefrag,compress=zstd,lazytime,noatime,user_subvol_rm_allowed" >/etc/fstab
update-grub2
disk=$(grub-probe -t disk /)
grub-install --target=i386-pc --recheck "$disk"
