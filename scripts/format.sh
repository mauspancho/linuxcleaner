#!/usr/bin/env bash
# Aplica formato automático a scripts, reglas y archivos de configuración.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ROOT_DIR

cd "${ROOT_DIR}"

# Permite ejecutar este script directamente después de `make setup`.
LOCAL_TOOLS="${ROOT_DIR}/.tools/bin"
LOCAL_NODE_BIN="${ROOT_DIR}/node_modules/.bin"
if [[ -d ${LOCAL_TOOLS} ]]; then
  PATH="${LOCAL_TOOLS}:${LOCAL_NODE_BIN}:${PATH}"
  export PATH
fi

warn() {
  printf '[AVISO] %s\n' "$*" >&2
}

have() {
  command -v "$1" > /dev/null 2>&1
}

collect_shell_files() {
  {
    printf '%s\n' ./cleaner.sh
    find . \
      -type f \
      \( -name '*.sh' -o -name '*.bash' \) \
      -not -path './node_modules/*' \
      -not -path './.tools/*' \
      -print
  } | sort -u
}

format_shell() {
  local -a files=()
  local file

  if ! have shfmt; then
    warn "shfmt no está disponible; se omite el formato de scripts."
    return 0
  fi

  while IFS= read -r file; do
    files+=("${file}")
  done < <(collect_shell_files)

  shfmt --write "${files[@]}"
  printf '[OK] Scripts formateados con shfmt.\n'
}

format_prettier() {
  if ! have prettier; then
    warn "Prettier no está disponible; se omite el formato general."
    return 0
  fi

  prettier --write .
  printf '[OK] Archivos formateados con Prettier.\n'
}

format_eslint() {
  if ! have eslint; then
    warn "ESLint no está disponible; se omite la corrección de reglas."
    return 0
  fi

  eslint --fix "polkit/**/*.rules" "scripts/**/*.mjs" "tests/**/*.mjs" "eslint.config.mjs"
  printf '[OK] Reglas y scripts JavaScript revisados con ESLint.\n'
}

main() {
  format_shell
  format_prettier
  format_eslint
  printf '[OK] Formato completado.\n'
}

main "$@"
