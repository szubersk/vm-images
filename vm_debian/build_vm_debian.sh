#!/bin/bash

set -euo pipefail

if [[ ${V:-} = 1 ]]; then
  set -x
fi

SCRIPT_DIR=$(readlink -e "$(dirname "${BASH_SOURCE[0]}")")

TO_RELEASE=()
TO_REMOVE=()
MOUNT_POINT=

install_signal_handlers() {
  for sig in ABRT HUP INT PIPE QUIT TERM; do
    trap 'cleanup "$?"; trap - '"$sig"' && kill -s '"$sig"' $$' "$sig"
  done

  # shellcheck disable=SC2154
  trap 'ec=$?; cleanup "$ec"; exit "$ec"' EXIT
}

disable_signal_handlers() {
  trap '' ABRT HUP INT PIPE QUIT TERM EXIT
}

cleanup() {
  set +e
  disable_signal_handlers

  pkill -9 -P $$ &>/dev/null
  sleep 1
  umount -R "${TO_REMOVE[@]}" &>/dev/null

  for l in "${TO_RELEASE[@]}"; do
    losetup -d "${l}" &>/dev/null
  done

  rm -rf "${TO_REMOVE[@]}"
}

create_partitions_and_fs() {
  local disk_image=$1
  truncate -s 2G "$disk_image"
  sgdisk -Z -a1 -n1:34:2047 -t1:ef02 -a2048 -n2 -t2:8300 "$disk_image" >/dev/null

  local loop_dev
  loop_dev=$(losetup -Pf --show "$disk_image")
  TO_RELEASE+=("$loop_dev")
  MOUNT_POINT=$(mktemp -d)
  TO_REMOVE+=("$MOUNT_POINT")

  mkfs.btrfs --force --nodiscard --metadata single --checksum crc32c --features no-holes --runtime-features free-space-tree --label rootfs "${loop_dev}p2" >/dev/null
  mount "${loop_dev}p2" "$MOUNT_POINT"
  btrfs subvolume create "$MOUNT_POINT/root" >/dev/null
  btrfs subvolume set-default "$MOUNT_POINT/root"
  umount -R "$MOUNT_POINT"
  mount -o "autodefrag,compress=zstd,noatime" "${loop_dev}p2" "$MOUNT_POINT"
}

install_base_os() {
  "$SCRIPT_DIR/../base/create_rootfs.sh" "$MOUNT_POINT"

  install -o 0 -g 0 -m 0644 /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
  install -o 0 -g 0 -m 0644 "$SCRIPT_DIR/vm-init.service" "$MOUNT_POINT/etc/systemd/system/vm-init.service"
  install -o 0 -g 0 -m 0755 -t "$MOUNT_POINT/usr/local/sbin" "$SCRIPT_DIR"/{growpart.sh,vm_init.sh}
  install -o 0 -g 0 -m 0755 "$SCRIPT_DIR/provision.sh" "$MOUNT_POINT/provision.sh"

  env -i HOME=/root TERM="$TERM" PATH='/usr/sbin:/usr/bin' \
    http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" no_proxy="${no_proxy:-}" \
    chroot "$MOUNT_POINT" /provision.sh
}

main() {
  install_signal_handlers

  if [[ ${UNSHARED:-} != 1 ]]; then
    if [[ $(id -u || :) != 0 ]]; then
      echo >&2 "Please run as root!"
      exit 1
    fi

    exec env UNSHARED=1 unshare --mount --mount-proc --uts "${BASH_SOURCE[0]}" "$@"
  fi

  local disk_image=$1
  create_partitions_and_fs "$disk_image"
  install_base_os

  echo "$disk_image built OK"
}

main "$@"
