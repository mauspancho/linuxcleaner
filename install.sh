#!/usr/bin/env bash
# Instalador y desinstalador de LinuxCleaner.
#
# Copia el ejecutable y la regla de PolicyKit a las rutas del sistema, aplica
# propietario root:root y permisos estrictos (0755/0644) y recarga polkit.
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR}"
readonly APP_NAME="LinuxCleaner"

readonly BINARY_SOURCE="${REPO_ROOT}/cleaner.sh"
readonly RULE_SOURCE="${REPO_ROOT}/polkit/50-linuxcleaner.rules"
readonly DESKTOP_SOURCE="${REPO_ROOT}/desktop/linuxcleaner.desktop"
readonly ICON_SOURCE="${REPO_ROOT}/desktop/linuxcleaner.svg"

# Rutas fijas de instalación. La regla de PolicyKit contiene esta misma ruta,
# por lo que no se permite instalar el ejecutable en otro lugar.
readonly INSTALL_BINDIR="/usr/local/bin"
readonly INSTALL_BINARY="${INSTALL_BINDIR}/linuxcleaner"
readonly INSTALL_RULEDIR="/etc/polkit-1/rules.d"
readonly INSTALL_RULE="${INSTALL_RULEDIR}/50-linuxcleaner.rules"
# La entrada .desktop y el icono en /usr/share hacen que la aplicación aparezca
# en el lanzador de cualquier entorno de escritorio compatible con freedesktop.
readonly INSTALL_APPDIR="/usr/share/applications"
readonly INSTALL_DESKTOP="${INSTALL_APPDIR}/linuxcleaner.desktop"
readonly INSTALL_THEMEDIR="/usr/share/icons/hicolor"
readonly INSTALL_ICONDIR="${INSTALL_THEMEDIR}/scalable/apps"
readonly INSTALL_ICON="${INSTALL_ICONDIR}/linuxcleaner.svg"

# DESTDIR permite preparar una instalación en un directorio temporal para
# pruebas o empaquetado. Sin esta variable se instala en el sistema real.
DESTDIR="${DESTDIR:-}"
DRY_RUN=0
UNINSTALL=0
SKIP_RELOAD=0

TARGET_BINDIR=""
TARGET_BINARY=""
TARGET_RULEDIR=""
TARGET_RULE=""
TARGET_APPDIR=""
TARGET_DESKTOP=""
TARGET_ICONDIR=""
TARGET_ICON=""

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[AVISO] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat << 'EOF'
Uso: install.sh [OPCIONES]

Instala LinuxCleaner en /usr/local/bin/linuxcleaner, su regla de PolicyKit en
/etc/polkit-1/rules.d/50-linuxcleaner.rules y una entrada en el lanzador de
aplicaciones (/usr/share/applications). También puede desinstalarlo.

Opciones:
  -n, --dry-run        Muestra las acciones sin modificar el sistema.
  -u, --uninstall      Desinstala el ejecutable, la regla y la entrada del
                       lanzador.
      --destdir RUTA   Instala bajo RUTA en lugar de la raíz del sistema.
                       Pensado para pruebas y empaquetado; no recarga polkit.
      --no-reload      No recargar el servicio polkit al terminar.
  -h, --help           Muestra esta ayuda.

Ejemplos:
  sudo ./install.sh
  sudo ./install.sh --uninstall
  ./install.sh --dry-run
  ./install.sh --destdir /tmp/prueba
EOF
}

run() {
  if ((DRY_RUN)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

normalize_destdir() {
  if [[ -z ${DESTDIR} ]]; then
    return 0
  fi

  [[ ${DESTDIR} == /* ]] || die "--destdir debe ser una ruta absoluta."

  while [[ ${DESTDIR} == */ && ${DESTDIR} != "/" ]]; do
    DESTDIR="${DESTDIR%/}"
  done

  # Un destino igual a la raíz equivale a una instalación real.
  if [[ ${DESTDIR} == "/" ]]; then
    DESTDIR=""
  fi
}

compute_targets() {
  TARGET_BINDIR="${DESTDIR}${INSTALL_BINDIR}"
  TARGET_BINARY="${DESTDIR}${INSTALL_BINARY}"
  TARGET_RULEDIR="${DESTDIR}${INSTALL_RULEDIR}"
  TARGET_RULE="${DESTDIR}${INSTALL_RULE}"
  TARGET_APPDIR="${DESTDIR}${INSTALL_APPDIR}"
  TARGET_DESKTOP="${DESTDIR}${INSTALL_DESKTOP}"
  TARGET_ICONDIR="${DESTDIR}${INSTALL_ICONDIR}"
  TARGET_ICON="${DESTDIR}${INSTALL_ICON}"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -n | --dry-run)
        DRY_RUN=1
        ;;
      -u | --uninstall)
        UNINSTALL=1
        ;;
      --no-reload)
        SKIP_RELOAD=1
        ;;
      --destdir)
        [[ $# -ge 2 ]] || die "Falta el valor para --destdir."
        DESTDIR="$2"
        shift
        ;;
      --destdir=*)
        DESTDIR="${1#*=}"
        ;;
      --)
        shift
        break
        ;;
      *)
        usage >&2
        die "Opción no reconocida: $1"
        ;;
    esac
    shift
  done

  if (($# > 0)); then
    die "Argumentos no reconocidos: $*"
  fi
}

require_root() {
  if ((EUID != 0)); then
    die "Se requieren privilegios de root. Ejecuta: sudo ./${SCRIPT_NAME}"
  fi
}

validate_sources() {
  local file
  local -a required=("${BINARY_SOURCE}" "${RULE_SOURCE}" "${DESKTOP_SOURCE}" "${ICON_SOURCE}")

  for file in "${required[@]}"; do
    [[ -f ${file} ]] || die "Falta el archivo requerido: ${file}"
  done

  bash -n "${BINARY_SOURCE}" || die "El ejecutable tiene errores de sintaxis Bash."

  # Evita instalar una regla que no coincida con la ruta real del ejecutable.
  grep -Fq "var PROGRAM = \"${INSTALL_BINARY}\";" "${RULE_SOURCE}" \
    || die "La regla no define PROGRAM con ${INSTALL_BINARY}."
  grep -Fq "var COMMAND_LINE = \"${INSTALL_BINARY} --privileged-clean\";" "${RULE_SOURCE}" \
    || die "La regla no define COMMAND_LINE con ${INSTALL_BINARY} --privileged-clean."

  # La entrada del lanzador debe apuntar al ejecutable instalado y a su icono.
  grep -Fxq "[Desktop Entry]" "${DESKTOP_SOURCE}" \
    || die "La entrada de escritorio no tiene la sección [Desktop Entry]."
  grep -Fxq "Type=Application" "${DESKTOP_SOURCE}" \
    || die "La entrada de escritorio no declara Type=Application."
  grep -Fxq "Exec=${INSTALL_BINARY}" "${DESKTOP_SOURCE}" \
    || die "La entrada de escritorio no ejecuta ${INSTALL_BINARY}."
  grep -Fxq "Icon=linuxcleaner" "${DESKTOP_SOURCE}" \
    || die "La entrada de escritorio no usa el icono linuxcleaner."

  if command -v node > /dev/null 2>&1; then
    node "${REPO_ROOT}/scripts/validate-rules.mjs" "${RULE_SOURCE}" \
      || die "La validación de la regla de PolicyKit falló."
  else
    warn "Node.js no está disponible; se omite la validación JavaScript de la regla."
  fi
}

check_runtime_dependencies() {
  if ! command -v zenity > /dev/null 2>&1; then
    warn "zenity no está instalado; la interfaz gráfica no funcionará."
  fi

  if ! type -P pkexec > /dev/null 2>&1; then
    warn "pkexec no está instalado; no se podrá elevar privilegios."
  fi
}

backup_target() {
  local target="$1"
  local timestamp="$2"
  local backup

  [[ -e ${target} ]] || return 0

  backup="${target}.bak.${timestamp}"
  if [[ -e ${backup} ]]; then
    backup="${backup}-$$"
  fi

  run cp -a -- "${target}" "${backup}"
  log "Copia de seguridad: ${backup}"
}

ensure_directory() {
  local directory="$1"

  # No cambia los permisos de directorios del sistema que ya existen.
  if [[ -d ${directory} ]]; then
    return 0
  fi

  run install -d -m 0755 -- "${directory}"
}

install_binary() {
  local timestamp="$1"

  log "Instalando ${APP_NAME} en ${TARGET_BINARY}"
  ensure_directory "${TARGET_BINDIR}"
  backup_target "${TARGET_BINARY}" "${timestamp}"
  run install -m 0755 -- "${BINARY_SOURCE}" "${TARGET_BINARY}"

  if ((EUID == 0)) && [[ -z ${DESTDIR} ]]; then
    run chown root:root -- "${TARGET_BINARY}"
  fi
}

install_rule() {
  local timestamp="$1"

  log "Instalando la regla de PolicyKit en ${TARGET_RULE}"
  ensure_directory "${TARGET_RULEDIR}"
  backup_target "${TARGET_RULE}" "${timestamp}"
  run install -m 0644 -- "${RULE_SOURCE}" "${TARGET_RULE}"

  if ((EUID == 0)) && [[ -z ${DESTDIR} ]]; then
    run chown root:root -- "${TARGET_RULE}"
  fi
}

install_desktop_entry() {
  local timestamp="$1"

  log "Instalando la entrada del lanzador en ${TARGET_DESKTOP}"
  ensure_directory "${TARGET_APPDIR}"
  backup_target "${TARGET_DESKTOP}" "${timestamp}"
  run install -m 0644 -- "${DESKTOP_SOURCE}" "${TARGET_DESKTOP}"

  if ((EUID == 0)) && [[ -z ${DESTDIR} ]]; then
    run chown root:root -- "${TARGET_DESKTOP}"
  fi
}

install_icon() {
  local timestamp="$1"

  log "Instalando el icono en ${TARGET_ICON}"
  ensure_directory "${TARGET_ICONDIR}"
  backup_target "${TARGET_ICON}" "${timestamp}"
  run install -m 0644 -- "${ICON_SOURCE}" "${TARGET_ICON}"

  if ((EUID == 0)) && [[ -z ${DESTDIR} ]]; then
    run chown root:root -- "${TARGET_ICON}"
  fi
}

refresh_desktop_caches() {
  local icon_cache_tool

  if [[ -n ${DESTDIR} ]]; then
    log "Instalación en DESTDIR: no se actualizan las cachés del escritorio."
    return 0
  fi

  # Actualiza el índice de aplicaciones que usan algunos lanzadores. No es
  # imprescindible: los entornos de escritorio también leen los archivos
  # .desktop directamente.
  if command -v update-desktop-database > /dev/null 2>&1; then
    run update-desktop-database -q "${INSTALL_APPDIR}" \
      || warn "No se pudo actualizar el índice de aplicaciones."
  else
    warn "update-desktop-database no está disponible; se omite el índice de aplicaciones."
  fi

  for icon_cache_tool in gtk-update-icon-cache gtk4-update-icon-cache; do
    if command -v "${icon_cache_tool}" > /dev/null 2>&1; then
      run "${icon_cache_tool}" -q -t -f "${INSTALL_THEMEDIR}" \
        || warn "No se pudo actualizar la caché de iconos."
      return 0
    fi
  done

  warn "No se encontró gtk-update-icon-cache; se omite la caché de iconos."
}

reload_polkit() {
  local unit

  if ((SKIP_RELOAD)); then
    log "Recarga de polkit omitida (--no-reload)."
    return 0
  fi

  if [[ -n ${DESTDIR} ]]; then
    log "Instalación en DESTDIR: no se recarga polkit."
    return 0
  fi

  if ((DRY_RUN)); then
    run systemctl try-reload-or-restart polkit
    return 0
  fi

  if ! command -v systemctl > /dev/null 2>&1; then
    warn "systemctl no está disponible; no se pudo recargar polkit."
    return 0
  fi

  for unit in polkit polkitd; do
    if systemctl is-active --quiet "${unit}" 2> /dev/null; then
      if systemctl try-reload-or-restart "${unit}"; then
        log "${unit}.service recargado."
      else
        warn "No se pudo recargar ${unit}.service. Revisa: journalctl -u ${unit}"
      fi
      return 0
    fi
  done

  warn "No se encontró un servicio polkit activo; no se recargó la configuración."
}

uninstall() {
  log "Desinstalando ${APP_NAME}"

  if [[ -e ${TARGET_BINARY} ]]; then
    run rm -f -- "${TARGET_BINARY}"
    log "Eliminado: ${TARGET_BINARY}"
  else
    log "No existe: ${TARGET_BINARY}"
  fi

  if [[ -e ${TARGET_RULE} ]]; then
    run rm -f -- "${TARGET_RULE}"
    log "Eliminado: ${TARGET_RULE}"
  else
    log "No existe: ${TARGET_RULE}"
  fi

  if [[ -e ${TARGET_DESKTOP} ]]; then
    run rm -f -- "${TARGET_DESKTOP}"
    log "Eliminado: ${TARGET_DESKTOP}"
  else
    log "No existe: ${TARGET_DESKTOP}"
  fi

  if [[ -e ${TARGET_ICON} ]]; then
    run rm -f -- "${TARGET_ICON}"
    log "Eliminado: ${TARGET_ICON}"
  else
    log "No existe: ${TARGET_ICON}"
  fi

  refresh_desktop_caches
  reload_polkit
  log "Desinstalación completada."
}

main() {
  local timestamp

  parse_args "$@"
  normalize_destdir
  compute_targets

  if ((EUID == 0)) && [[ -n ${DESTDIR} ]]; then
    warn "Se está usando --destdir como root; asegúrate de que ${DESTDIR} sea de confianza."
  fi

  if ((UNINSTALL)); then
    if ((DRY_RUN == 0)) && [[ -z ${DESTDIR} ]]; then
      require_root
    fi
    uninstall
    return 0
  fi

  validate_sources
  check_runtime_dependencies

  if ((DRY_RUN == 0)) && [[ -z ${DESTDIR} ]]; then
    require_root
  fi

  timestamp="$(date +%Y%m%d-%H%M%S)"
  install_binary "${timestamp}"
  install_rule "${timestamp}"
  install_desktop_entry "${timestamp}"
  install_icon "${timestamp}"
  refresh_desktop_caches
  reload_polkit
  log "Instalación completada."
}

main "$@"
