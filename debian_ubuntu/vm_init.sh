#!/bin/bash

set -exuo pipefail

setup_network_interfaces() {
  # shellcheck disable=SC2312
  while read -r iface; do
    local pid_file lease_file service_name
    pid_file="/run/dhclient.${iface}.pid"
    lease_file="/var/lib/dhcp/dhclient.${iface}.leases"
    service_name="dhclient@${iface}.service"

    if ! systemctl try-restart "$service_name"; then
      systemd-run --slice=system.slice \
        "--unit=dhclient@$iface" \
        "--property=PIDFile=$pid_file" \
        "--property=ExecStop=/sbin/dhclient -x -pf $pid_file" \
        "--property=Restart=on-failure" \
        /sbin/dhclient -4 -v -i -I \
        -pf "$pid_file" \
        -lf "$lease_file" \
        "$iface"
    fi
  done < <(ip -4 -o link | awk "-F: " '/link\/ether/ { if (match($0, /NO-CARRIER/) == 0) print $2 }')
}

configure_etc_networking() {
  local hostname="vm.local"
  local resolver="1.0.0.1"

  # /etc/hosts
  cat >/etc/hosts <<EOF
127.0.0.1 localhost $hostname

::1       localhost ip6-localhost ip6-loopback $hostname
EOF

  # /etc/hostname
  echo "$hostname" >/etc/hostname
  hostname -F /etc/hostname

  # /etc/resolv.conf
  echo "nameserver $resolver" >/etc/resolv.conf
}

resize_boot_partition() {
  local disk part_no
  disk=$(grub-probe -t disk /)
  part_no=$(grub-probe -t drive / | sed -rn 's@.*gpt([0-9]+).*@\1@p')

  growpart.sh "$disk" "$part_no"
  btrfs filesystem resize max /
}

main() {
  local first_boot_done=0 state_file="/var/lib/vm_init.firstbootdone" pids=()

  if [[ -e $state_file ]]; then
    first_boot_done=1
  fi

  setup_network_interfaces &
  pids+=($!)
  resize_boot_partition &
  pids+=($!)

  if [[ $first_boot_done != 1 ]]; then
    configure_etc_networking &
    pids+=($!)
  fi

  for p in "${pids[@]}"; do wait "$p"; done

  if [[ $first_boot_done != 1 ]]; then
    touch "$state_file"
  fi
}

main "$@"
