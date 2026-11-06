#!/usr/bin/env bash
# Descarga ShellCheck y shfmt en .tools/bin sin usar sudo.
# Las versiones y sumas SHA-256 están fijadas para instalaciones reproducibles.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ROOT_DIR

readonly SHELLCHECK_VERSION="v0.11.0"
readonly SHFMT_VERSION="v3.14.1"
readonly TOOLS_DIR="${ROOT_DIR}/.tools"
readonly BIN_DIR="${TOOLS_DIR}/bin"

SHELLCHECK_ARCH=""
SHELLCHECK_SHA=""
SHFMT_ARCH=""
SHFMT_SHA=""
TMP_DIR=""

log() {
  printf '[INFO] %s\n' "$*"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

detect_platform() {
  case "$(uname -m)" in
    x86_64 | amd64)
      SHELLCHECK_ARCH="x86_64"
      SHELLCHECK_SHA="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
      SHFMT_ARCH="amd64"
      SHFMT_SHA="76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf"
      ;;
    aarch64 | arm64)
      SHELLCHECK_ARCH="aarch64"
      SHELLCHECK_SHA="12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588"
      SHFMT_ARCH="arm64"
      SHFMT_SHA="5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489"
      ;;
    *)
      die "Arquitectura no soportada: $(uname -m). Instala shellcheck y shfmt manualmente."
      ;;
  esac
}

check_requirements() {
  local cmd
  local -a required=(curl tar sha256sum install mktemp)

  for cmd in "${required[@]}"; do
    command -v "${cmd}" > /dev/null 2>&1 \
      || die "Falta el comando requerido: ${cmd}"
  done
}

download() {
  local url="$1"
  local destination="$2"

  log "Descargando ${url}"
  curl --fail --silent --show-error --location --retry 3 --output "${destination}" "${url}" \
    || die "No se pudo descargar ${url}"
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual

  actual="$(sha256sum "${file}" | cut -d' ' -f1)"
  [[ ${actual} == "${expected}" ]] \
    || die "Suma SHA-256 incorrecta para ${file}. Esperado: ${expected}. Obtenido: ${actual}."
}

shellcheck_is_installed() {
  local output

  [[ -x ${BIN_DIR}/shellcheck ]] || return 1
  output="$("${BIN_DIR}/shellcheck" --version 2> /dev/null || true)"
  [[ ${output} == *"version: ${SHELLCHECK_VERSION#v}"* ]]
}

shfmt_is_installed() {
  local output

  [[ -x ${BIN_DIR}/shfmt ]] || return 1
  output="$("${BIN_DIR}/shfmt" --version 2> /dev/null || true)"
  [[ ${output} == *"${SHFMT_VERSION#v}"* ]]
}

install_shellcheck() {
  local archive="${TMP_DIR}/shellcheck.tar.xz"
  local extracted="${TMP_DIR}/shellcheck-${SHELLCHECK_VERSION}"
  local url

  if shellcheck_is_installed; then
    log "ShellCheck ${SHELLCHECK_VERSION#v} ya está disponible."
    return 0
  fi

  url="https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.${SHELLCHECK_ARCH}.tar.xz"
  download "${url}" "${archive}"
  verify_sha256 "${archive}" "${SHELLCHECK_SHA}"
  tar -xJf "${archive}" -C "${TMP_DIR}"
  install -m 0755 "${extracted}/shellcheck" "${BIN_DIR}/shellcheck"
  log "ShellCheck instalado en ${BIN_DIR}/shellcheck"
}

install_shfmt() {
  local binary="${TMP_DIR}/shfmt"
  local url

  if shfmt_is_installed; then
    log "shfmt ${SHFMT_VERSION#v} ya está disponible."
    return 0
  fi

  url="https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_${SHFMT_ARCH}"
  download "${url}" "${binary}"
  verify_sha256 "${binary}" "${SHFMT_SHA}"
  install -m 0755 "${binary}" "${BIN_DIR}/shfmt"
  log "shfmt instalado en ${BIN_DIR}/shfmt"
}

main() {
  detect_platform
  check_requirements
  mkdir -p "${BIN_DIR}"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT

  install_shellcheck
  install_shfmt

  log "Herramientas listas. Añade ${BIN_DIR} al PATH o usa 'make setup'."
  "${BIN_DIR}/shellcheck" --version | head -n 2
  "${BIN_DIR}/shfmt" --version
}

main "$@"
