#!/bin/bash

set -euo pipefail

[[ ${V-} != 1 ]] || set -x

SCRIPT_DIR=$(readlink -e "$(dirname "${BASH_SOURCE[0]}")")

OPT_ARCH=$(dpkg --print-architecture)
OPT_RELEASE=unstable
OPT_IMAGE_FILE=

TO_RELEASE=()
TO_REMOVE=()
TO_UNMOUNT=()
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
  local result=$1
  disable_signal_handlers

  pkill -9 -P $$ &>/dev/null
  sleep 1
  umount -R "${TO_UNMOUNT[@]}" &>/dev/null

  for l in "${TO_RELEASE[@]}"; do
    losetup -d "$l" &>/dev/null
  done

  rm -rf "${TO_REMOVE[@]}"
  [[ $result -eq 0 ]] || rm -f "$OPT_IMAGE_FILE"
}

usage() {
  echo "Usage: ${BASH_SOURCE[0]} [--arch <amd64|arm64|...>] [--release <stable|testing|unstable|focal|jammy|...>] <image file>"
  exit 1
}

parse_command_line_arguments() {
  local args
  args=$(getopt -n "${BASH_SOURCE[0]}" -o '' --longoptions 'arch:,release:,help' -- "$@")
  eval "set -- $args"
  while :; do
    case $1 in
      --arch)
        if [[ -z ${2-} ]]; then
          usage
        fi
        OPT_ARCH="$2"
        shift 2
        ;;
      --release)
        if [[ -z ${2-} ]]; then
          usage
        fi
        OPT_RELEASE="$2"
        shift 2
        ;;
      --)
        if [[ -z ${2-} ]]; then
          usage
        fi

        OPT_IMAGE_FILE="$2"
        break
        ;;
      *)
        usage
        ;;
    esac
  done
}

create_partitions_and_fs() {
  local disk_image=$1
  truncate -s 2G "$disk_image"
  sgdisk -Z -a1 -n1:34:2047 -t1:ef02 -a2048 -n2:2048:160M -t2:ef00 -n3 -t3:8300 "$disk_image" >/dev/null

  local loop_dev
  loop_dev=$(losetup -Pf --show "$disk_image")
  uefi_part="${loop_dev}p2"
  root_fs_part="${loop_dev}p3"
  partprobe "$loop_dev"
  TO_RELEASE+=("$loop_dev")
  MOUNT_POINT=$(mktemp -d)
  TO_REMOVE+=("$MOUNT_POINT")
  TO_UNMOUNT+=("${MOUNT_POINT}/boot" "$MOUNT_POINT")

  sleep 1
  mkfs.vfat -F32 "$uefi_part" >/dev/null
  mkfs.btrfs --force --nodiscard --metadata single --checksum crc32c --features no-holes --runtime-features free-space-tree --label rootfs "$root_fs_part" >/dev/null
  mount "$root_fs_part" "$MOUNT_POINT"
  btrfs subvolume create "$MOUNT_POINT/root" >/dev/null
  btrfs subvolume set-default "$MOUNT_POINT/root"
  umount -R "$MOUNT_POINT"
  mount -o "autodefrag,compress=zstd,noatime" "$root_fs_part" "$MOUNT_POINT"
  mkdir -m 0755 "${MOUNT_POINT}/boot"
  mount "$uefi_part" "${MOUNT_POINT}/boot"
}

install_base_os() {
  "$SCRIPT_DIR/build_chroot.sh" --arch "$OPT_ARCH" --release "$OPT_RELEASE" "$MOUNT_POINT"

  install -o 0 -g 0 -m 0644 /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
  install -o 0 -g 0 -m 0644 "$SCRIPT_DIR/vm-init.service" "$MOUNT_POINT/etc/systemd/system/vm-init.service"
  install -o 0 -g 0 -m 0755 -t "$MOUNT_POINT/usr/local/sbin" "$SCRIPT_DIR"/{growpart.sh,vm_init.sh}
  install -o 0 -g 0 -m 0755 "$SCRIPT_DIR/provision.sh" "$MOUNT_POINT/provision.sh"

  env -i HOME=/root TERM="$TERM" PATH='/usr/sbin:/usr/bin' \
    http_proxy="${http_proxy-}" https_proxy="${https_proxy-}" no_proxy="${no_proxy-}" \
    chroot "$MOUNT_POINT" /provision.sh
}

main() {
  install_signal_handlers
  parse_command_line_arguments "$@"

  if [[ ${UNSHARED-} != 1 ]]; then
    if [[ $(id -u || :) != 0 ]]; then
      echo >&2 "Please run as root!"
      exit 1
    fi

    exec env UNSHARED=1 unshare --mount --mount-proc --uts "${BASH_SOURCE[0]}" "$@"
  fi

  create_partitions_and_fs "$OPT_IMAGE_FILE"
  install_base_os

  echo "$OPT_IMAGE_FILE built OK"
}

main "$@"
