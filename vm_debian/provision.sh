#!/bin/bash

set -exuo pipefail

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LANG=C

if [ "${EATMYDATA:-}" != 1 ]; then
  apt-get -qq update
  apt-get -qq install eatmydata
  exec env EATMYDATA=1 eatmydata -- "${BASH_SOURCE[0]}" "$@"
fi

umask 0022

echo vm.local >/etc/hostname
hostname -F /etc/hostname

apt-get -qq install \
  btrfs-progs \
  doas \
  e2fsprogs \
  gdisk \
  grub-pc \
  isc-dhcp-client \
  linux-image-amd64 \
  man-db \
  openntpd \
  openssh-server \
  systemd-sysv \
  wget \
  tzdata
apt-get clean
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

chattr -R +C /var/log/journal

cat <<EOF >/etc/dhcp/dhclient-enter-hooks.d/dns_settings
#!/bin/sh

make_resolv_conf() {
  :
}
EOF

user=debian
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
GRUB_TERMINAL="console serial"
GRUB_TIMEOUT=1
EOF

mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
uuid=$(grub-probe -t fs_uuid /)
echo "UUID=$uuid / btrfs autodefrag,compress=zstd,noatime,user_subvol_rm_allowed" >/etc/fstab
update-grub2
disk=$(grub-probe -t disk /)
grub-install --target=i386-pc --recheck "$disk"
umount -R /dev /sys /proc
