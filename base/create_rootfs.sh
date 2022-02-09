#!/bin/bash

set -euo pipefail

if [[ ${V:-} = 1 ]]; then
  set -x
fi

SCRIPT_DIR=$(readlink -e "$(dirname "${BASH_SOURCE[0]}")")
WORK_DIR=$(mktemp -d)

OPT_VARIANT=full
OPT_RELEASE=testing
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
  rm -rf "${WORK_DIR}"

  if [[ $1 != 0 ]]; then
    rm -rf "${OPT_INSTALL_DIR}"
  fi
}

usage() {
  echo "Usage: ${BASH_SOURCE[0]} [--variant <minimal|nodoc|full>] [--release <stable|testing|unstable>] <installation directory>"
  exit 1
}

parse_command_line_arguments() {
  local args
  args=$(getopt -n "${BASH_SOURCE[0]}" -o '' --longoptions 'variant:,release:,help' -- "$@")
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
      --release)
        case $2 in
          bullseye | stable | bookworm | testing | sid | unstable)
            OPT_RELEASE="$2"
            ;;
          *)
            usage
            ;;
        esac
        shift 2
        ;;
      --)
        if [[ -z ${2:-} ]]; then
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
  mkdir -p "${OPT_INSTALL_DIR}"{/etc/dpkg/dpkg.cfg.d,/etc/apt}
  echo 'force-unsafe-io' >"${OPT_INSTALL_DIR}/etc/dpkg/dpkg.cfg.d/force_unsafe_io"

  {
    echo "APT::Default-Release \"${OPT_RELEASE}\";"

    if [[ ${OPT_VARIANT} = "minimal" ]]; then
      echo "APT::Install-Recommends \"0\";"
    else
      echo "APT::Install-Recommends \"1\";"
    fi
    echo "APT::Install-Suggests \"0\";"
    echo "Acquire::Languages none;"
  } >"${OPT_INSTALL_DIR}/etc/apt/apt.conf"
}

install_packages() {
  wget --no-verbose --output-document "${WORK_DIR}/archive-key-11.asc" https://ftp-master.debian.org/keys/archive-key-11.asc
  (cd "${WORK_DIR}" && sha256sum --check --strict "${SCRIPT_DIR}/SHA256SUMS")
  gpg --import --keyring "${WORK_DIR}/keyring" --no-default-keyring "${WORK_DIR}/archive-key-11.asc"

  if [[ ${OPT_VARIANT} = "minimal" ]]; then
    debootstrap --keyring="${WORK_DIR}/keyring" --variant=minbase --force-check-gpg \
      --include=ca-certificates,busybox-static --exclude=e2fsprogs,tzdata \
      "${OPT_RELEASE}" "${OPT_INSTALL_DIR}"
  else
    debootstrap --keyring="${WORK_DIR}/keyring" --force-check-gpg \
      --include=ca-certificates,vim-tiny --exclude=e2fsprogs,tzdata \
      "${OPT_RELEASE}" "${OPT_INSTALL_DIR}"
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

  {
    echo "deb https://deb.debian.org/debian ${OPT_RELEASE} main contrib non-free"

    if [[ ${OPT_RELEASE} != unstable ]] && [[ ${OPT_RELEASE} != sid ]]; then
      echo "deb https://security.debian.org/debian-security ${OPT_RELEASE}-security main contrib non-free"
      echo "deb https://deb.debian.org/debian ${OPT_RELEASE}-updates main contrib non-free"
    fi
  } >"${OPT_INSTALL_DIR}/etc/apt/sources.list"

  if [[ ${OPT_VARIANT} != "full" ]]; then
    for p in "${doc_dirs[@]}" "${locale_dirs[@]}"; do
      printf "path-exclude=%s/*\n" "${p}" >>"${OPT_INSTALL_DIR}/etc/dpkg/dpkg.cfg.d/nodoc"
      rm -rf "${OPT_INSTALL_DIR:?}/${p}/"*
    done
  fi

  echo 'nameserver 1.0.0.1' >"${OPT_INSTALL_DIR}/etc/resolv.conf"

  rm -rf "${OPT_INSTALL_DIR:?}"{/var/cache/apt,/var/lib/apt/lists}/*
}

main() {
  install_signal_handlers
  umask 0022

  parse_command_line_arguments "$@"
  prepare_installation_directory
  install_packages
  configure_system
  sync -f "${OPT_INSTALL_DIR}"

  echo "${OPT_RELEASE} installed successfully in ${OPT_INSTALL_DIR}"
}

main "$@"
