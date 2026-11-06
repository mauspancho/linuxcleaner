#!/usr/bin/env bash
# Ejecuta todas las comprobaciones del proyecto.
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

STRICT=0
if [[ ${1:-} == "--strict" ]]; then
  STRICT=1
elif [[ -n ${1:-} ]]; then
  printf '[ERROR] Opción no reconocida: %s\n' "$1" >&2
  exit 2
fi

MISSING_TOOLS=()

warn() {
  printf '[AVISO] %s\n' "$*" >&2
}

fail() {
  printf '[FALLO] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '[OK] %s\n' "$*"
}

have() {
  command -v "$1" > /dev/null 2>&1
}

require_tool() {
  local tool="$1"

  if have "${tool}"; then
    return 0
  fi

  MISSING_TOOLS+=("${tool}")
  if ((STRICT)); then
    return 1
  fi

  warn "Herramienta no encontrada: ${tool} (se omite)"
  return 1
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

collect_rule_files() {
  find ./polkit -maxdepth 1 -type f -name '*.rules' -print | sort
}

check_bash_syntax() {
  local file

  while IFS= read -r file; do
    bash -n "${file}" || fail "Sintaxis Bash inválida: ${file}"
  done < <(collect_shell_files)

  ok "Sintaxis Bash (bash -n)"
}

check_shellcheck() {
  local -a files=()

  require_tool shellcheck || return 0

  while IFS= read -r file; do
    files+=("${file}")
  done < <(collect_shell_files)

  shellcheck --format=gcc "${files[@]}" || fail "ShellCheck encontró problemas."
  ok "ShellCheck"
}

check_shfmt() {
  local -a files=()

  require_tool shfmt || return 0

  while IFS= read -r file; do
    files+=("${file}")
  done < <(collect_shell_files)

  shfmt --diff "${files[@]}" || fail "shfmt encontró diferencias de formato."
  ok "Formato de scripts (shfmt)"
}

check_rules() {
  local -a files=()

  require_tool node || return 0

  while IFS= read -r file; do
    files+=("${file}")
  done < <(collect_rule_files)

  if ((${#files[@]} == 0)); then
    fail "No se encontraron reglas .rules."
  fi

  node scripts/validate-rules.mjs "${files[@]}" || fail "Validación de reglas .rules."
  ok "Sintaxis y registro de reglas .rules"
}

check_prettier() {
  require_tool prettier || return 0

  prettier --check . || fail "Prettier encontró archivos sin formatear."
  ok "Formato general (Prettier)"
}

check_eslint() {
  require_tool eslint || return 0

  eslint "polkit/**/*.rules" "scripts/**/*.mjs" "tests/**/*.mjs" "eslint.config.mjs" \
    || fail "ESLint encontró problemas."
  ok "ESLint"
}

check_executables() {
  local file

  for file in cleaner.sh install.sh; do
    if [[ ! -x ${file} ]]; then
      fail "El archivo ${file} debe ser ejecutable."
    fi
  done

  ok "Permisos de ejecución"
}

report_missing_tools() {
  if ((${#MISSING_TOOLS[@]} == 0)); then
    return 0
  fi

  printf '[FALLO] Faltan herramientas: %s\n' "${MISSING_TOOLS[*]}" >&2
  printf '        Ejecuta: make setup\n' >&2
  exit 1
}

main() {
  check_bash_syntax
  check_shellcheck
  check_shfmt
  check_rules
  check_prettier
  check_eslint
  check_executables

  if ((STRICT)); then
    report_missing_tools
  fi

  ok "Todas las comprobaciones pasaron."
}

main "$@"
