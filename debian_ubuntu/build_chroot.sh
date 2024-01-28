#!/bin/bash

set -euo pipefail

[[ ${V-} != 1 ]] || set -x

WORK_DIR=$(mktemp -d)

OPT_VARIANT=full
OPT_ARCH=$(dpkg --print-architecture)
OPT_RELEASE=unstable
OPT_INSTALL_DIR=

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
  rm -rf "$WORK_DIR" 2>/dev/null
  [[ $1 -eq 0 ]] || rm -rf "$OPT_INSTALL_DIR" 2>/dev/null
}

usage() {
  echo "Usage: ${BASH_SOURCE[0]} [--arch <amd64|arm64|...>] [--variant <minimal|nodoc|full>] [--release <stable|testing|unstable|focal|jammy|...>] <installation directory>"
  exit 1
}

parse_command_line_arguments() {
  local args
  args=$(getopt -n "${BASH_SOURCE[0]}" -o '' --longoptions 'arch:,variant:,release:,help' -- "$@")
  eval "set -- $args"
  while :; do
    case $1 in
      --variant)
        case $2 in
          minimal | nodoc | full)
            OPT_VARIANT="$2"
            ;;
          *)
            usage
            ;;
        esac
        shift 2
        ;;
      --arch)
        OPT_ARCH="$2"
        shift 2
        ;;
      --release)
        OPT_RELEASE="$2"
        shift 2
        ;;
      --)
        if [[ -z ${2-} ]]; then
          usage
        fi

        OPT_INSTALL_DIR="$2"
        break
        ;;
      *)
        usage
        ;;
    esac
  done
}

prepare_installation_directory() {
  mkdir -p "$OPT_INSTALL_DIR"{/etc/dpkg/dpkg.cfg.d,/etc/apt}
  echo 'force-unsafe-io' >"${OPT_INSTALL_DIR}/etc/dpkg/dpkg.cfg.d/force_unsafe_io"

  {
    echo "APT::AutoRemove::SuggestsImportant \"false\";"
    echo "APT::Default-Release \"${OPT_RELEASE}\";"
    if [[ $OPT_VARIANT == minimal ]]; then
      echo "APT::Install-Recommends \"0\";"
    else
      echo "APT::Install-Recommends \"1\";"
    fi
    echo "APT::Install-Suggests \"0\";"
    echo "APT::Update::Post-Invoke { \"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true\"; };"
    echo "Acquire::GzipIndexes \"true\";"
    echo "Acquire::Languages \"none\";"
    echo "DPkg::Post-Invoke { \"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true\"; };"
    echo "Dir::Cache::pkgcache \"\";"
    echo "Dir::Cache::srcpkgcache \"\";"
  } >"${OPT_INSTALL_DIR}/etc/apt/apt.conf"
}

install_packages() {
  gpg --homedir "$WORK_DIR" --keyring "${WORK_DIR}/keyring" \
    --no-default-keyring --keyserver hkps://keyserver.ubuntu.com \
    --recv-keys 0x73A4F27B8DD47936 0x871920D1991BC93C

  if [[ $OPT_VARIANT == minimal ]]; then
    $(command -v eatmydata || :) debootstrap --keyring="${WORK_DIR}/keyring" \
      --arch="$OPT_ARCH" \
      --variant=minbase --force-check-gpg \
      --include=ca-certificates,busybox-static \
      --exclude=e2fsprogs,tzdata \
      "$OPT_RELEASE" "$OPT_INSTALL_DIR"
  else
    $(command -v eatmydata || :) debootstrap --keyring="${WORK_DIR}/keyring" \
      --arch="$OPT_ARCH" \
      --force-check-gpg --include=ca-certificates,eatmydata,vim-tiny \
      "$OPT_RELEASE" "$OPT_INSTALL_DIR"
  fi
}

configure_system() {
  local doc_dirs=(
    /usr/share/doc
    /usr/share/groff
    /usr/share/info
    /usr/share/linda
    /usr/share/lintian
    /usr/share/man
  )
  local locale_dirs=(
    /usr/share/locale
  )

  if [[ $OPT_RELEASE != stable && $OPT_RELEASE != testing && $OPT_RELEASE != unstable ]]; then
    {
      if [[ $OPT_ARCH == i386 || $OPT_ARCH == amd64 ]]; then
        echo "deb http://archive.ubuntu.com/ubuntu $OPT_RELEASE main restricted universe multiverse"
        echo "deb http://archive.ubuntu.com/ubuntu ${OPT_RELEASE}-updates main restricted universe multiverse"
        echo "deb http://security.ubuntu.com/ubuntu ${OPT_RELEASE}-security main restricted universe multiverse"
      else
        echo "deb http://ports.ubuntu.com/ubuntu-ports $OPT_RELEASE main restricted universe multiverse"
        echo "deb http://ports.ubuntu.com/ubuntu-ports ${OPT_RELEASE}-security main restricted universe multiverse"
        echo "deb http://ports.ubuntu.com/ubuntu-ports ${OPT_RELEASE}-updates main restricted universe multiverse"
      fi
    } >"${OPT_INSTALL_DIR}/etc/apt/sources.list"
  elif [[ $OPT_RELEASE == unstable ]]; then
    {
      echo "Types: deb"
      echo "URIs: http://deb.debian.org/debian"
      echo "Suites: $OPT_RELEASE"
      echo "Components: main contrib non-free non-free-firmware"
      echo "Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg"
    } >"${OPT_INSTALL_DIR}/etc/apt/sources.list.d/debian.sources"
    rm -f "${OPT_INSTALL_DIR}/etc/apt/sources.list"
  else
    {
      echo "deb http://deb.debian.org/debian $OPT_RELEASE main contrib non-free"
      echo "deb http://security.debian.org/debian-security ${OPT_RELEASE}-security main contrib non-free"
      echo "deb http://deb.debian.org/debian ${OPT_RELEASE}-updates main contrib non-free"
    } >"${OPT_INSTALL_DIR}/etc/apt/sources.list"
  fi

  if [[ $OPT_VARIANT != full ]]; then
    for p in "${doc_dirs[@]}" "${locale_dirs[@]}"; do
      printf "path-exclude=%s/*\n" "${p}" >>"${OPT_INSTALL_DIR}/etc/dpkg/dpkg.cfg.d/nodoc"
      rm -rf "${OPT_INSTALL_DIR:?}/${p}/"*
    done
  fi

  echo 'nameserver 1.0.0.1' >"${OPT_INSTALL_DIR}/etc/resolv.conf"

  rm -rf "${OPT_INSTALL_DIR:?}"{/var/cache/apt,/var/lib/apt/lists}/* "${OPT_INSTALL_DIR:?}"/var/log/bootstrap.log
}

main() {
  install_signal_handlers
  umask 0022

  parse_command_line_arguments "$@"
  prepare_installation_directory
  install_packages
  configure_system
  sync -f "$OPT_INSTALL_DIR"

  echo "$OPT_RELEASE installed successfully in $OPT_INSTALL_DIR"
}

main "$@"
