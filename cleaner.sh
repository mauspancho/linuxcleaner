#!/usr/bin/env bash
# LinuxCleaner: utilidad de mantenimiento para Linux con interfaz Zenity.
#
# Flujo normal:
#   1. Analiza el sistema como usuario sin privilegios.
#   2. Muestra un resumen y pide confirmación.
#   3. Ejecuta la limpieza como root mediante pkexec.
#   4. Muestra el progreso enviado por el proceso privilegiado.
#
# El modo --privileged-clean es interno: solo debe ejecutarse a través de
# pkexec y está restringido por polkit/50-linuxcleaner.rules.
set -Eeuo pipefail

readonly APP_NAME="linuxcleaner"
readonly APP_TITLE="LinuxCleaner"
readonly APP_VERSION="1.0.0"
readonly INSTALL_PATH="/usr/local/bin/linuxcleaner"
readonly LOG_FILE_DEFAULT="/var/log/linuxcleaner.log"
readonly JOURNAL_RETENTION_DAYS=7
readonly JOURNAL_RETENTION="7d"

# Rutas configurables para pruebas y para --scan. El modo privilegiado fuerza
# siempre las rutas de producción antes de borrar nada.
OS_RELEASE_FILE="${LINUXCLEANER_OS_RELEASE:-/etc/os-release}"
APT_CACHE_DIR="${LINUXCLEANER_APT_CACHE_DIR:-/var/cache/apt/archives}"
PACMAN_CACHE_DIR="${LINUXCLEANER_PACMAN_CACHE_DIR:-/var/cache/pacman/pkg}"

IFS=':' read -r -a DNF_CACHE_DIRS <<< "${LINUXCLEANER_DNF_CACHE_DIRS:-/var/cache/dnf:/var/cache/yum:/var/cache/libdnf5}"
IFS=':' read -r -a JOURNAL_DIRS <<< "${LINUXCLEANER_JOURNAL_DIRS:-/var/log/journal:/run/log/journal}"

DISTRO_ID=""
DISTRO_LIKE=""
DISTRO_PRETTY=""
DISTRO_FAMILY=""
CACHE_LABEL=""
ORPHAN_LABEL=""
CACHE_BYTES=0
ORPHAN_BYTES=0
ORPHAN_COUNT=0
JOURNAL_BYTES=0
JOURNAL_AVAILABLE=0
TOTAL_BYTES=0
DEBIAN_ORPHAN_PACKAGES=()
ARCH_ORPHAN_PACKAGES=()
LOG_FILE="${LINUXCLEANER_LOG:-${LOG_FILE_DEFAULT}}"
PKEXEC_BIN=""

SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SELF_PATH

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

log_line() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}" 2> /dev/null || true
}

emit_text() {
  printf '# %s\n' "$*"
}

emit_error() {
  # El mensaje se muestra en la barra de progreso y se envía por stderr para
  # que la interfaz pueda incluirlo en el diálogo de error.
  printf '# %s\n' "$*"
  printf '%s\n' "$*" >&2
}

emit_progress() {
  local percent="$1"
  local message="$2"

  printf '%s\n' "${percent}"
  emit_text "${message}"
}

format_bytes() {
  local bytes="${1:-0}"

  LC_ALL=C awk -v bytes="${bytes}" '
    BEGIN {
      if (bytes < 0) {
        bytes = 0;
      }
      split("B KB MB GB TB PB", units, " ");
      value = bytes;
      i = 1;
      while (value >= 1024 && i < 6) {
        value /= 1024;
        i++;
      }
      if (i == 1) {
        printf "%.0f %s", value, units[i];
      } else {
        printf "%.2f %s", value, units[i];
      }
    }
  '
}

sum_paths_bytes() {
  local -a paths=()
  local path

  for path in "$@"; do
    if [[ -d ${path} ]]; then
      paths+=("${path}")
    fi
  done

  if ((${#paths[@]} == 0)); then
    printf '0\n'
    return 0
  fi

  find "${paths[@]}" -xdev -type f -printf '%s\n' 2> /dev/null \
    | awk '{ total += $1 } END { printf "%.0f\n", total }' || true
}

sum_journal_old_bytes() {
  local -a paths=()
  local path

  for path in "${JOURNAL_DIRS[@]}"; do
    if [[ -d ${path} ]]; then
      paths+=("${path}")
    fi
  done

  if ((${#paths[@]} == 0)); then
    printf '0\n'
    return 0
  fi

  find "${paths[@]}" -xdev -type f -name '*.journal~' \
    -mtime +"${JOURNAL_RETENTION_DAYS}" -printf '%s\n' 2> /dev/null \
    | awk '{ total += $1 } END { printf "%.0f\n", total }' || true
}

debian_orphan_packages() {
  LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get -s autoremove --purge -y 2> /dev/null \
    | awk '/^(Remv|Purg)[[:space:]]/ { print $2 }' || true
}

sum_debian_packages() {
  local pkg size total=0

  for pkg in "$@"; do
    [[ -n ${pkg} ]] || continue
    size="$(LC_ALL=C dpkg-query -W -f='${Installed-Size}' "${pkg}" 2> /dev/null || true)"
    if [[ ${size} =~ ^[0-9]+$ ]]; then
      total=$((total + size * 1024))
    fi
  done

  printf '%s\n' "${total}"
}

fedora_orphan_data() {
  local output=""

  if command -v dnf > /dev/null 2>&1; then
    output="$(LC_ALL=C dnf -q repoquery --unneeded --installed --qf '%{name} %{installsize}' 2> /dev/null || true)"
    if [[ -z ${output} ]]; then
      output="$(LC_ALL=C dnf -q repoquery --unneeded --installed --queryformat '%{name} %{installsize}' 2> /dev/null || true)"
    fi
  fi

  printf '%s\n' "${output}"
}

arch_orphan_packages() {
  LC_ALL=C pacman -Qtdq 2> /dev/null || true
}

pacman_size_to_bytes() {
  LC_ALL=C awk -v size="${1}" '
    BEGIN {
      split(size, parts, " ");
      amount = parts[1] + 0;
      unit = parts[2];
      factor = 1;
      if (unit == "KiB") {
        factor = 1024;
      } else if (unit == "MiB") {
        factor = 1024 * 1024;
      } else if (unit == "GiB") {
        factor = 1024 * 1024 * 1024;
      } else if (unit == "TiB") {
        factor = 1024 * 1024 * 1024 * 1024;
      }
      printf "%.0f\n", amount * factor;
    }
  '
}

sum_arch_packages() {
  local pkg info size bytes total=0

  for pkg in "$@"; do
    info="$(LC_ALL=C pacman -Qi "${pkg}" 2> /dev/null || true)"
    size="$(awk -F': ' '/^Installed Size[[:space:]]*:/ { print $2; exit }' <<< "${info}")"
    if [[ -n ${size} ]]; then
      bytes="$(pacman_size_to_bytes "${size}")"
      if [[ ${bytes} =~ ^[0-9]+$ ]]; then
        total=$((total + bytes))
      fi
    fi
  done

  printf '%s\n' "${total}"
}

reset_scan() {
  DISTRO_ID=""
  DISTRO_LIKE=""
  DISTRO_PRETTY=""
  DISTRO_FAMILY=""
  CACHE_LABEL=""
  ORPHAN_LABEL=""
  CACHE_BYTES=0
  ORPHAN_BYTES=0
  ORPHAN_COUNT=0
  JOURNAL_BYTES=0
  JOURNAL_AVAILABLE=0
  TOTAL_BYTES=0
  DEBIAN_ORPHAN_PACKAGES=()
  ARCH_ORPHAN_PACKAGES=()
}

detect_distribution() {
  local key value

  DISTRO_ID=""
  DISTRO_LIKE=""
  DISTRO_PRETTY=""

  if [[ -r ${OS_RELEASE_FILE} ]]; then
    while IFS='=' read -r key value; do
      [[ -n ${key} && ${key} != \#* ]] || continue
      value="${value%\"}"
      value="${value#\"}"
      case ${key} in
        ID) DISTRO_ID="${value,,}" ;;
        ID_LIKE) DISTRO_LIKE="${value,,}" ;;
        PRETTY_NAME) DISTRO_PRETTY="${value}" ;;
        *) ;;
      esac
    done < "${OS_RELEASE_FILE}"
  fi

  case ${DISTRO_ID} in
    debian | ubuntu | linuxmint | pop | elementary | zorin | kali | raspbian | deepin)
      DISTRO_FAMILY="debian"
      ;;
    fedora | rhel | centos | rocky | almalinux | ol | amzn)
      DISTRO_FAMILY="fedora"
      ;;
    arch | manjaro | endeavouros | garuda | artix)
      DISTRO_FAMILY="arch"
      ;;
    *)
      case " ${DISTRO_LIKE} " in
        *" debian "* | *" ubuntu "*) DISTRO_FAMILY="debian" ;;
        *" fedora "* | *" rhel "*) DISTRO_FAMILY="fedora" ;;
        *" arch "*) DISTRO_FAMILY="arch" ;;
        *)
          if command -v apt-get > /dev/null 2>&1; then
            DISTRO_FAMILY="debian"
          elif command -v dnf > /dev/null 2>&1; then
            DISTRO_FAMILY="fedora"
          elif command -v pacman > /dev/null 2>&1; then
            DISTRO_FAMILY="arch"
          else
            DISTRO_FAMILY="unsupported"
          fi
          ;;
      esac
      ;;
  esac

  case ${DISTRO_FAMILY} in
    debian)
      CACHE_LABEL="Caché de APT"
      ORPHAN_LABEL="Paquetes huérfanos (autoremove)"
      ;;
    fedora)
      CACHE_LABEL="Caché de DNF"
      ORPHAN_LABEL="Paquetes huérfanos (dnf)"
      ;;
    arch)
      CACHE_LABEL="Caché de pacman"
      ORPHAN_LABEL="Paquetes huérfanos (pacman)"
      ;;
    *)
      CACHE_LABEL="Caché de paquetes"
      ORPHAN_LABEL="Paquetes huérfanos"
      ;;
  esac

  if command -v journalctl > /dev/null 2>&1; then
    JOURNAL_AVAILABLE=1
  else
    JOURNAL_AVAILABLE=0
  fi

  DISTRO_PRETTY="${DISTRO_PRETTY:-${DISTRO_ID:-Desconocida}}"
}

scan_cache() {
  case ${DISTRO_FAMILY} in
    debian) CACHE_BYTES="$(sum_paths_bytes "${APT_CACHE_DIR}")" ;;
    fedora) CACHE_BYTES="$(sum_paths_bytes "${DNF_CACHE_DIRS[@]}")" ;;
    arch) CACHE_BYTES="$(sum_paths_bytes "${PACMAN_CACHE_DIR}")" ;;
    *) CACHE_BYTES=0 ;;
  esac

  [[ ${CACHE_BYTES} =~ ^[0-9]+$ ]] || CACHE_BYTES=0
}

scan_orphans() {
  local size

  ORPHAN_COUNT=0
  ORPHAN_BYTES=0
  DEBIAN_ORPHAN_PACKAGES=()
  ARCH_ORPHAN_PACKAGES=()

  case ${DISTRO_FAMILY} in
    debian)
      mapfile -t DEBIAN_ORPHAN_PACKAGES < <(debian_orphan_packages)
      ORPHAN_COUNT=${#DEBIAN_ORPHAN_PACKAGES[@]}
      ORPHAN_BYTES="$(sum_debian_packages "${DEBIAN_ORPHAN_PACKAGES[@]}")"
      ;;
    fedora)
      while read -r _ size; do
        if [[ ${size} =~ ^[0-9]+$ ]]; then
          ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
          ORPHAN_BYTES=$((ORPHAN_BYTES + size))
        fi
      done < <(fedora_orphan_data)
      ;;
    arch)
      mapfile -t ARCH_ORPHAN_PACKAGES < <(arch_orphan_packages)
      ORPHAN_COUNT=${#ARCH_ORPHAN_PACKAGES[@]}
      ORPHAN_BYTES="$(sum_arch_packages "${ARCH_ORPHAN_PACKAGES[@]}")"
      ;;
    *) ;;
  esac

  [[ ${ORPHAN_BYTES} =~ ^[0-9]+$ ]] || ORPHAN_BYTES=0
}

scan_journal() {
  if ((JOURNAL_AVAILABLE == 0)); then
    JOURNAL_BYTES=0
    return 0
  fi

  JOURNAL_BYTES="$(sum_journal_old_bytes)"
  [[ ${JOURNAL_BYTES} =~ ^[0-9]+$ ]] || JOURNAL_BYTES=0
}

compute_total() {
  TOTAL_BYTES=$((CACHE_BYTES + ORPHAN_BYTES + JOURNAL_BYTES))
}

scan_all() {
  reset_scan
  detect_distribution

  if [[ ${DISTRO_FAMILY} == "unsupported" ]]; then
    return 0
  fi

  scan_cache
  scan_orphans
  scan_journal
  compute_total
}

write_scan_data() {
  local file="$1"

  {
    printf 'family\t%s\n' "${DISTRO_FAMILY}"
    printf 'distro\t%s\n' "${DISTRO_PRETTY}"
    printf 'cache_label\t%s\n' "${CACHE_LABEL}"
    printf 'cache_bytes\t%s\n' "${CACHE_BYTES}"
    printf 'orphan_label\t%s\n' "${ORPHAN_LABEL}"
    printf 'orphan_count\t%s\n' "${ORPHAN_COUNT}"
    printf 'orphan_bytes\t%s\n' "${ORPHAN_BYTES}"
    printf 'journal_bytes\t%s\n' "${JOURNAL_BYTES}"
    printf 'journal_available\t%s\n' "${JOURNAL_AVAILABLE}"
    printf 'total_bytes\t%s\n' "${TOTAL_BYTES}"
  } > "${file}"
}

read_scan_results() {
  local file="$1"
  local key value

  if [[ ! -f ${file} ]]; then
    return 1
  fi

  DISTRO_FAMILY="unsupported"
  DISTRO_PRETTY="Desconocida"
  CACHE_LABEL="Caché de paquetes"
  ORPHAN_LABEL="Paquetes huérfanos"
  CACHE_BYTES=0
  ORPHAN_BYTES=0
  ORPHAN_COUNT=0
  JOURNAL_BYTES=0
  JOURNAL_AVAILABLE=0
  TOTAL_BYTES=0

  while IFS=$'\t' read -r key value; do
    case ${key} in
      family) DISTRO_FAMILY="${value}" ;;
      distro) DISTRO_PRETTY="${value}" ;;
      cache_label) CACHE_LABEL="${value}" ;;
      cache_bytes) CACHE_BYTES="${value}" ;;
      orphan_label) ORPHAN_LABEL="${value}" ;;
      orphan_count) ORPHAN_COUNT="${value}" ;;
      orphan_bytes) ORPHAN_BYTES="${value}" ;;
      journal_bytes) JOURNAL_BYTES="${value}" ;;
      journal_available) JOURNAL_AVAILABLE="${value}" ;;
      total_bytes) TOTAL_BYTES="${value}" ;;
      *) ;;
    esac
  done < "${file}"

  [[ ${CACHE_BYTES} =~ ^[0-9]+$ ]] || CACHE_BYTES=0
  [[ ${ORPHAN_BYTES} =~ ^[0-9]+$ ]] || ORPHAN_BYTES=0
  [[ ${ORPHAN_COUNT} =~ ^[0-9]+$ ]] || ORPHAN_COUNT=0
  [[ ${JOURNAL_BYTES} =~ ^[0-9]+$ ]] || JOURNAL_BYTES=0
  [[ ${TOTAL_BYTES} =~ ^[0-9]+$ ]] || TOTAL_BYTES=0
  [[ ${JOURNAL_AVAILABLE} =~ ^[01]$ ]] || JOURNAL_AVAILABLE=0
  [[ ${DISTRO_FAMILY} =~ ^(debian|fedora|arch|unsupported)$ ]] || DISTRO_FAMILY="unsupported"

  if ((TOTAL_BYTES == 0)); then
    TOTAL_BYTES=$((CACHE_BYTES + ORPHAN_BYTES + JOURNAL_BYTES))
  fi
}

scan_with_progress() {
  local data_file="$1"

  reset_scan
  emit_progress 5 "Detectando la distribución..."
  detect_distribution

  if [[ ${DISTRO_FAMILY} == "unsupported" ]]; then
    write_scan_data "${data_file}"
    emit_progress 100 "Distribución no soportada."
    return 0
  fi

  emit_progress 20 "Calculando el tamaño de la caché de paquetes..."
  scan_cache
  emit_progress 50 "Buscando paquetes huérfanos..."
  scan_orphans
  emit_progress 80 "Calculando la caché de logs..."
  scan_journal
  compute_total
  write_scan_data "${data_file}"
  emit_progress 100 "Análisis completado."
}

build_summary() {
  local journal_text

  if ((JOURNAL_AVAILABLE == 1)); then
    journal_text="$(format_bytes "${JOURNAL_BYTES}")"
  else
    journal_text="no disponible"
  fi

  printf 'Distribución: %s\n\n' "${DISTRO_PRETTY}"
  printf '%s: %s\n' "${CACHE_LABEL}" "$(format_bytes "${CACHE_BYTES}")"
  printf '%s: %s (%s paquete(s))\n' "${ORPHAN_LABEL}" \
    "$(format_bytes "${ORPHAN_BYTES}")" "${ORPHAN_COUNT}"
  printf 'Caché de logs (%s): %s\n\n' "${JOURNAL_RETENTION}" "${journal_text}"
  printf 'Espacio total a liberar: %s (%s bytes)\n\n' \
    "$(format_bytes "${TOTAL_BYTES}")" "${TOTAL_BYTES}"
  printf '¿Deseas continuar?'
}

print_scan_report() {
  scan_all

  if [[ ${DISTRO_FAMILY} == "unsupported" ]]; then
    printf 'Distribución no soportada: %s\n' "${DISTRO_PRETTY}" >&2
    printf 'Se admiten Debian/Ubuntu, Fedora/RHEL y Arch Linux.\n' >&2
    return 1
  fi

  printf 'Distribución: %s (%s)\n' "${DISTRO_PRETTY}" "${DISTRO_FAMILY}"
  printf '%s: %s\n' "${CACHE_LABEL}" "$(format_bytes "${CACHE_BYTES}")"
  printf '%s: %s (%s paquete(s))\n' "${ORPHAN_LABEL}" \
    "$(format_bytes "${ORPHAN_BYTES}")" "${ORPHAN_COUNT}"
  if ((JOURNAL_AVAILABLE == 1)); then
    printf 'Caché de logs (%s): %s\n' "${JOURNAL_RETENTION}" "$(format_bytes "${JOURNAL_BYTES}")"
  else
    printf 'Caché de logs: journalctl no disponible\n'
  fi
  printf 'Total a liberar: %s (%s bytes)\n' \
    "$(format_bytes "${TOTAL_BYTES}")" "${TOTAL_BYTES}"
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" > /dev/null 2>&1 \
    || die "No se encontró el comando requerido: ${command_name}"
}

gui_info() {
  zenity --info \
    --title="${APP_TITLE}" \
    --width=560 \
    --no-markup \
    --modal \
    --text="$1"
}

gui_error() {
  zenity --error \
    --title="${APP_TITLE}" \
    --width=560 \
    --no-markup \
    --modal \
    --text="$1"
}

gui_question() {
  zenity --question \
    --title="Confirmar limpieza" \
    --width=580 \
    --no-markup \
    --modal \
    --default-cancel \
    --ok-label="Limpiar" \
    --cancel-label="Cancelar" \
    --text="$1"
}

run_scan_with_progress() {
  local data_file="$1"
  local -a statuses=()

  set +e
  scan_with_progress "${data_file}" \
    | zenity --progress \
      --title="${APP_TITLE}" \
      --text="Analizando el sistema..." \
      --percentage=0 \
      --auto-close \
      --no-cancel \
      --width=560
  statuses=("${PIPESTATUS[@]}")
  set -e

  if ((statuses[0] != 0 || statuses[1] != 0)); then
    gui_error "No se pudo completar el análisis del sistema."
    return 1
  fi

  if [[ ! -s ${data_file} ]]; then
    gui_error "El análisis no generó resultados."
    return 1
  fi
}

run_privileged_cleanup() {
  local error_file
  local error_text
  local pkexec_status
  local -a statuses=()

  error_file="$(mktemp)"

  set +e
  "${PKEXEC_BIN}" "${INSTALL_PATH}" --privileged-clean 2> "${error_file}" \
    | zenity --progress \
      --title="Limpiando el sistema" \
      --text="Preparando la limpieza..." \
      --percentage=0 \
      --auto-close \
      --no-cancel \
      --width=560
  statuses=("${PIPESTATUS[@]}")
  set -e

  pkexec_status=${statuses[0]}

  if ((pkexec_status != 0)); then
    error_text="$(cat "${error_file}" 2> /dev/null || true)"
    if [[ -z ${error_text} ]]; then
      error_text="pkexec terminó con el código ${pkexec_status}."
    fi
    gui_error "No se pudo completar la limpieza.

${error_text}

Registro: ${LOG_FILE_DEFAULT}" || true
    rm -f "${error_file}"
    return 1
  fi

  rm -f "${error_file}"

  gui_info "La limpieza ha finalizado correctamente.

Espacio calculado a liberar: $(format_bytes "${TOTAL_BYTES}") (${TOTAL_BYTES} bytes)

Registro: ${LOG_FILE_DEFAULT}" || true
}

run_gui() {
  local data_file
  local summary

  require_command zenity
  require_command pkexec

  if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
    die "No hay un entorno gráfico disponible (DISPLAY/WAYLAND_DISPLAY)."
  fi

  # La interfaz puede ejecutarse desde el repositorio, pero la limpieza
  # privilegiada se lanza siempre desde la copia instalada, porque esa es la
  # única ruta que autoriza la regla de PolicyKit.
  if [[ ! -x ${INSTALL_PATH} ]]; then
    gui_error "LinuxCleaner no está instalado en ${INSTALL_PATH}.

Ejecuta primero:

sudo ./install.sh

Después inicia la aplicación con: linuxcleaner"
    exit 1
  fi

  PKEXEC_BIN="$(type -P pkexec || true)"
  if [[ -z ${PKEXEC_BIN} ]]; then
    die "No se encontró el ejecutable pkexec en PATH."
  fi

  data_file="$(mktemp)"
  trap 'rm -f "${data_file}"' EXIT

  if ! run_scan_with_progress "${data_file}"; then
    exit 1
  fi

  if ! read_scan_results "${data_file}"; then
    gui_error "No se pudieron leer los resultados del análisis."
    exit 1
  fi

  rm -f "${data_file}"
  trap - EXIT

  if [[ ${DISTRO_FAMILY} == "unsupported" ]]; then
    gui_error "Distribución no soportada.

${DISTRO_PRETTY}

Se admiten Debian/Ubuntu, Fedora/RHEL y Arch Linux."
    exit 1
  fi

  if ((TOTAL_BYTES == 0)); then
    gui_info "No se encontró espacio recuperable en las categorías analizadas." || true
    exit 0
  fi

  summary="$(build_summary)"

  if ! gui_question "${summary}"; then
    exit 0
  fi

  run_privileged_cleanup
}

setup_log() {
  LOG_FILE="${LOG_FILE_DEFAULT}"

  # Evita seguir un enlace simbólico que pudiera apuntar a otro archivo.
  if [[ -L ${LOG_FILE} ]]; then
    LOG_FILE="/dev/null"
  elif ! { : >> "${LOG_FILE}"; } 2> /dev/null; then
    LOG_FILE="/dev/null"
  fi

  if [[ ${LOG_FILE} != "/dev/null" ]]; then
    chmod 0640 "${LOG_FILE}" 2> /dev/null || true
  fi
}

run_logged() {
  local description="$1"
  local rc=0

  shift
  log_line "Ejecutando: ${description}"
  "$@" < /dev/null >> "${LOG_FILE}" 2>&1 || rc=$?

  if ((rc != 0)); then
    log_line "Fallo (${rc}): ${description}"
  fi

  return "${rc}"
}

run_logged_yes() {
  local description="$1"
  local rc=0
  local -a statuses=()

  shift
  log_line "Ejecutando: ${description} (confirmación automática)"
  set +e
  # LC_ALL=C hace que las preguntas de pacman usen "y/N" y acepten la salida
  # de yes. Con un locale español pacman espera "s" y rechazaría "y".
  # La salida de error de yes se envía al registro: al terminar el comando,
  # yes recibe SIGPIPE y su mensaje "Tubería rota" no debe llegar a la interfaz.
  yes 2>> "${LOG_FILE}" | LC_ALL=C "$@" >> "${LOG_FILE}" 2>&1
  statuses=("${PIPESTATUS[@]}")
  set -e

  rc=${statuses[1]:-1}

  if ((rc != 0)); then
    log_line "Fallo (${rc}): ${description}"
  fi

  return "${rc}"
}

cleanup_orphans() {
  case ${DISTRO_FAMILY} in
    debian)
      run_logged "apt-get autoremove --purge" \
        env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
      ;;
    fedora)
      run_logged "dnf autoremove" dnf -y autoremove
      ;;
    arch)
      if ((${#ARCH_ORPHAN_PACKAGES[@]} == 0)); then
        return 0
      fi
      run_logged "pacman -Rns" pacman -Rns --noconfirm "${ARCH_ORPHAN_PACKAGES[@]}"
      ;;
    *)
      return 0
      ;;
  esac
}

cleanup_pacman_cache() {
  local before
  local after
  local rc=0

  before="$(sum_paths_bytes "${PACMAN_CACHE_DIR}")"
  run_logged_yes "pacman -Scc" pacman -Scc || rc=$?
  after="$(sum_paths_bytes "${PACMAN_CACHE_DIR}")"

  if ((rc == 0)); then
    return 0
  fi

  # pacman -Scc intenta borrar con unlink() los directorios temporales
  # download-XXXX que dejan las descargas parciales. unlink() falla en
  # directorios, así que pacman devuelve 1 aunque haya borrado todos los
  # paquetes. Se acepta como éxito si la caché quedó vacía o se redujo al
  # menos un 90 %, y se deja constancia en el registro.
  if ((after == 0 || after * 10 < before)); then
    log_line "pacman -Scc devolvió ${rc}, pero la caché pasó de ${before} a ${after} bytes."
    return 0
  fi

  log_line "La caché no se redujo lo suficiente (${before} -> ${after} bytes) tras el fallo ${rc}."
  return "${rc}"
}

cleanup_cache() {
  case ${DISTRO_FAMILY} in
    debian) run_logged "apt-get clean" apt-get clean ;;
    fedora) run_logged "dnf clean all" dnf clean all ;;
    # pacman -Scc pregunta "remove ALL files from cache? [y/N]". Con
    # --noconfirm respondería "No" (la opción por defecto) y no borraría nada,
    # así que se confirma explícitamente con "yes".
    arch) cleanup_pacman_cache ;;
    *) return 0 ;;
  esac
}

cleanup_journal() {
  run_logged "journalctl --vacuum-time=${JOURNAL_RETENTION}" \
    journalctl --vacuum-time="${JOURNAL_RETENTION}"
}

enforce_production_paths() {
  OS_RELEASE_FILE="/etc/os-release"
  APT_CACHE_DIR="/var/cache/apt/archives"
  PACMAN_CACHE_DIR="/var/cache/pacman/pkg"
  DNF_CACHE_DIRS=(/var/cache/dnf /var/cache/yum /var/cache/libdnf5)
  JOURNAL_DIRS=(/var/log/journal /run/log/journal)
  LOG_FILE="${LOG_FILE_DEFAULT}"
}

assert_privileged_context() {
  local owner
  local parent

  # Fija un PATH seguro antes de invocar utilidades externas.
  export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
  umask 022

  if ((EUID != 0)); then
    die "El modo privilegiado solo puede ejecutarse como root."
  fi

  if [[ ${SELF_PATH} != "${INSTALL_PATH}" ]]; then
    die "El modo privilegiado solo se permite desde ${INSTALL_PATH}."
  fi

  owner="$(stat -c '%u' "${SELF_PATH}" 2> /dev/null || true)"
  if [[ ${owner} != "0" ]]; then
    die "El ejecutable debe pertenecer a root: ${SELF_PATH}"
  fi

  if [[ -n "$(find "${SELF_PATH}" -maxdepth 0 -perm /022 -print -quit 2> /dev/null || true)" ]]; then
    die "El ejecutable no debe ser escribible por grupo u otros: ${SELF_PATH}"
  fi

  parent="$(dirname -- "${SELF_PATH}")"
  owner="$(stat -c '%u' "${parent}" 2> /dev/null || true)"
  if [[ ${owner} != "0" ]]; then
    die "El directorio del ejecutable debe pertenecer a root: ${parent}"
  fi

  if [[ -n "$(find "${parent}" -maxdepth 0 -perm /022 -print -quit 2> /dev/null || true)" ]]; then
    die "El directorio del ejecutable no debe ser escribible por grupo u otros: ${parent}"
  fi
}

privileged_clean() {
  if (($# != 0)); then
    die "El modo privilegiado no acepta argumentos adicionales."
  fi

  assert_privileged_context
  enforce_production_paths
  setup_log
  log_line "Inicio de la limpieza (usuario original: ${PKEXEC_UID:-desconocido})"

  emit_progress 0 "Iniciando la limpieza..."
  scan_all

  if [[ ${DISTRO_FAMILY} == "unsupported" ]]; then
    emit_error "Distribución no soportada. No se realizaron cambios."
    log_line "Distribución no soportada."
    exit 1
  fi

  emit_progress 8 "Sistema analizado: ${DISTRO_PRETTY}"

  if ((ORPHAN_COUNT > 0)); then
    emit_progress 12 "Purgando ${ORPHAN_COUNT} paquete(s) huérfano(s)..."
    if ! cleanup_orphans; then
      emit_error "Error al purgar paquetes huérfanos. Revisa ${LOG_FILE}."
      log_line "La limpieza se detuvo al purgar paquetes huérfanos."
      exit 1
    fi
  fi
  emit_progress 40 "Paquetes huérfanos procesados."

  if ((CACHE_BYTES > 0)); then
    emit_progress 45 "Limpiando ${CACHE_LABEL} ($(format_bytes "${CACHE_BYTES}"))..."
    if ! cleanup_cache; then
      emit_error "Error al limpiar la caché de paquetes. Revisa ${LOG_FILE}."
      log_line "La limpieza se detuvo al limpiar la caché de paquetes."
      exit 1
    fi
  fi
  emit_progress 75 "Caché de paquetes limpiada."

  if ((JOURNAL_AVAILABLE == 1 && JOURNAL_BYTES > 0)); then
    emit_progress 80 "Depurando la caché de logs (${JOURNAL_RETENTION})..."
    if ! cleanup_journal; then
      emit_text "Aviso: no se pudo depurar la caché de logs. Revisa ${LOG_FILE}."
      log_line "No se pudo depurar la caché de logs."
    fi
  fi
  emit_progress 95 "Caché de logs procesada."

  emit_progress 100 "Limpieza completada."
  log_line "Fin de la limpieza."
}

usage() {
  cat << 'EOF'
Uso: linuxcleaner [OPCIONES]

Sin opciones abre la interfaz gráfica: analiza el sistema, muestra el espacio
que se puede liberar y pide confirmación antes de limpiar.

Opciones:
  --scan              Analiza el sistema y muestra el resumen en la terminal
                      (no requiere instalar la aplicación).
  --privileged-clean  Modo interno para pkexec. No usar manualmente.
  -h, --help          Muestra esta ayuda.
  -V, --version       Muestra la versión.

Distribuciones soportadas:
  Debian/Ubuntu (APT), Fedora/RHEL (DNF) y Arch Linux (pacman).
EOF
}

main() {
  case "${1:-}" in
    --privileged-clean)
      shift
      privileged_clean "$@"
      ;;
    --scan)
      if (($# != 1)); then
        die "--scan no acepta argumentos adicionales."
      fi
      print_scan_report
      ;;
    -h | --help)
      usage
      ;;
    -V | --version)
      printf '%s %s\n' "${APP_NAME}" "${APP_VERSION}"
      ;;
    "")
      run_gui
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
