#!/bin/bash

set -euo pipefail

if [ "${V:-}" = "1" ]; then
  set -x
fi

if [ -z "${RELEASE:-}" ]; then
  RELEASE=testing
fi

trap 'cleanup' EXIT

SCRIPT_DIR="$(readlink -e "$(dirname "${BASH_SOURCE[0]}")")"
WORK_DIR="$(mktemp -d)"

cleanup() {
  set +e
  rm -rf "${WORK_DIR}"
}

main() {
  docs=(
    /usr/share/doc
    /usr/share/groff
    /usr/share/info
    /usr/share/linda
    /usr/share/lintian
    /usr/share/locale
    /usr/share/man
    /usr/share/zoneinfo
  )

  umask 0022

  mkdir -p "${1:?}"{/etc/dpkg/dpkg.cfg.d,/etc/apt}
  printf 'force-unsafe-io\n' >"${1:?}/etc/dpkg/dpkg.cfg.d/force_unsafe_io"
  printf "APT::Default-Release \"%s\";\nAPT::Install-Recommends \"0\";\nAPT::Install-Suggests \"0\";\nAcquire::Languages none;\n" "${RELEASE}" >"${1:?}/etc/apt/apt.conf"

  wget --no-verbose --output-document "${WORK_DIR}/archive-key-11.asc" https://ftp-master.debian.org/keys/archive-key-11.asc
  (cd "${WORK_DIR}" && sha256sum --check --strict "${SCRIPT_DIR}/SHA256SUMS")
  gpg --import --keyring "${WORK_DIR}/keyring" --no-default-keyring "${WORK_DIR}/archive-key-11.asc"

  debootstrap --keyring="${WORK_DIR}/keyring" --variant=minbase --include=ca-certificates,vim-tiny --force-check-gpg "${RELEASE}" "${1:?}"

  for p in "${docs[@]}"; do
    printf "path-exclude=%s/*\n" "${p}" >>"${1:?}/etc/dpkg/dpkg.cfg.d/nodoc"
    rm -rf "${1:?}/${p}/"*
  done

  printf "deb http://deb.debian.org/debian %s main contrib non-free\n" "${RELEASE}" >"${1:?}/etc/apt/sources.list"

  if [ "${RELEASE}" != "unstable" ] && [ "${RELEASE}" != "sid" ]; then
    printf "deb http://security.debian.org/debian-security %s-security main contrib non-free\ndeb http://deb.debian.org/debian %s-updates main contrib non-free\n" "${RELEASE}" "${RELEASE}" >>"${1:?}/etc/apt/sources.list"
  fi

  rm -rf "${1:?}"{/var/cache/apt/archives,/var/lib/apt/lists}/*
  sync -f "${1:?}"

  printf "\n%s OK\n" "$1"
}

main "$@"
