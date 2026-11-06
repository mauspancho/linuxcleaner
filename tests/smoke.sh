#!/usr/bin/env bash
# Pruebas de humo de LinuxCleaner sin entorno gráfico ni privilegios de root.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly ROOT_DIR

cd "${ROOT_DIR}"

PASSED=0
FAILED=0
SKIPPED=0

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok    %s\n' "$*"
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'FALLO %s\n' "$*" >&2
}

skip() {
  SKIPPED=$((SKIPPED + 1))
  printf 'skip  %s\n' "$*"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local description="$3"

  if [[ ${haystack} == *"${needle}"* ]]; then
    pass "${description}"
  else
    fail "${description} (no se encontró: ${needle})"
  fi
}

assert_file_exists() {
  local file="$1"
  local description="$2"

  if [[ -f ${file} ]]; then
    pass "${description}"
  else
    fail "${description} (falta ${file})"
  fi
}

assert_not_exists() {
  local file="$1"
  local description="$2"

  if [[ ! -e ${file} ]]; then
    pass "${description}"
  else
    fail "${description} (existe ${file})"
  fi
}

assert_file_mode() {
  local file="$1"
  local expected="$2"
  local description="$3"
  local mode

  mode="$(stat -c '%a' "${file}" 2> /dev/null || true)"

  if [[ ${mode} == "${expected}" ]]; then
    pass "${description}"
  else
    fail "${description} (permisos ${mode:-desconocidos}, se esperaba ${expected})"
  fi
}

assert_same_file() {
  local expected="$1"
  local actual="$2"
  local description="$3"

  if cmp -s -- "${expected}" "${actual}"; then
    pass "${description}"
  else
    fail "${description} (el contenido no coincide)"
  fi
}

write_fake_command() {
  local directory="$1"
  local name="$2"
  local body="$3"

  printf '#!/usr/bin/env bash\n%s\n' "${body}" > "${directory}/${name}"
  chmod 0755 "${directory}/${name}"
}

test_structure() {
  assert_file_exists "cleaner.sh" "Existe el ejecutable principal"
  assert_file_exists "polkit/50-linuxcleaner.rules" "Existe la regla de PolicyKit"
  assert_file_exists "desktop/linuxcleaner.desktop" "Existe la entrada del lanzador"
  assert_file_exists "desktop/linuxcleaner.svg" "Existe el icono de la aplicación"
  assert_file_exists "install.sh" "Existe el instalador"
  assert_file_exists "README.md" "Existe la documentación"

  if [[ -x cleaner.sh ]]; then
    pass "cleaner.sh es ejecutable"
  else
    fail "cleaner.sh no es ejecutable"
  fi

  if [[ -x install.sh ]]; then
    pass "install.sh es ejecutable"
  else
    fail "install.sh no es ejecutable"
  fi
}

test_desktop_entry() {
  local entry output

  entry="$(cat desktop/linuxcleaner.desktop)"

  assert_contains "${entry}" "[Desktop Entry]" \
    "La entrada del lanzador declara la sección Desktop Entry"
  assert_contains "${entry}" $'Type=Application\n' \
    "La entrada del lanzador es de tipo Application"
  assert_contains "${entry}" $'Exec=/usr/local/bin/linuxcleaner\n' \
    "La entrada del lanzador ejecuta el binario instalado"
  assert_contains "${entry}" $'TryExec=/usr/local/bin/linuxcleaner\n' \
    "La entrada del lanzador comprueba el binario instalado"
  assert_contains "${entry}" $'Icon=linuxcleaner\n' \
    "La entrada del lanzador usa el icono instalado"
  assert_contains "${entry}" $'Terminal=false\n' \
    "La entrada del lanzador no abre una terminal"
  assert_contains "${entry}" "Categories=System;" \
    "La entrada del lanzador aparece en la categoría Sistema"

  if command -v desktop-file-validate > /dev/null 2>&1; then
    if output="$(desktop-file-validate desktop/linuxcleaner.desktop 2>&1)"; then
      pass "desktop-file-validate acepta la entrada del lanzador"
    else
      fail "desktop-file-validate rechaza la entrada del lanzador: ${output}"
    fi
  else
    skip "desktop-file-validate no está disponible; se omite la validación formal"
  fi
}

test_help_and_version() {
  local output

  output="$(bash ./cleaner.sh --help)"
  assert_contains "${output}" "Uso: linuxcleaner" "El ejecutable muestra la ayuda"

  output="$(bash ./cleaner.sh --version)"
  assert_contains "${output}" "linuxcleaner 1.0.0" "El ejecutable muestra la versión"

  output="$(bash ./install.sh --help)"
  assert_contains "${output}" "Uso: install.sh" "El instalador muestra la ayuda"
}

test_unknown_option() {
  local status=0

  if bash ./cleaner.sh --opcion-invalida > /dev/null 2>&1; then
    fail "Una opción inválida debe devolver un código de error"
  else
    status=$?
    if ((status == 2)); then
      pass "Las opciones inválidas devuelven el código 2"
    else
      fail "Código de salida inesperado para una opción inválida: ${status}"
    fi
  fi
}

test_scan_debian() {
  local tmp osr cache journal fakebin output
  local total_expected="4.00 MB"

  tmp="$(mktemp -d)"
  osr="${tmp}/os-release"
  cache="${tmp}/apt"
  journal="${tmp}/journal"
  fakebin="${tmp}/bin"

  mkdir -p "${cache}" "${journal}" "${fakebin}"

  cat > "${osr}" << 'EOF'
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu de prueba"
EOF

  truncate -s 1048576 "${cache}/paquete.deb"
  truncate -s 2097152 "${journal}/sistema@antiguo.journal~"
  touch -d '10 days ago' "${journal}/sistema@antiguo.journal~"

  write_fake_command "${fakebin}" "apt-get" \
    "printf 'Remv paquete-uno [1.0]\\nRemv paquete-dos [1.0]\\n'"
  write_fake_command "${fakebin}" "dpkg-query" "printf '512\\n'"

  if output="$(
    LINUXCLEANER_OS_RELEASE="${osr}" \
      LINUXCLEANER_APT_CACHE_DIR="${cache}" \
      LINUXCLEANER_JOURNAL_DIRS="${journal}" \
      PATH="${fakebin}:${PATH}" \
      bash ./cleaner.sh --scan
  )"; then
    assert_contains "${output}" "Ubuntu de prueba (debian)" \
      "El escaneo detecta la familia Debian"
    assert_contains "${output}" "(2 paquete(s))" \
      "El escaneo cuenta los paquetes huérfanos de APT"
    assert_contains "${output}" "Total a liberar: ${total_expected}" \
      "El escaneo calcula el total de Debian en formato legible"
  else
    fail "El escaneo de Debian terminó con error"
  fi

  rm -rf "${tmp}"
}

test_scan_fedora() {
  local tmp osr cache journal fakebin output
  local total_expected="2.00 MB"

  tmp="$(mktemp -d)"
  osr="${tmp}/os-release"
  cache="${tmp}/dnf"
  journal="${tmp}/journal"
  fakebin="${tmp}/bin"

  mkdir -p "${cache}" "${journal}" "${fakebin}"

  cat > "${osr}" << 'EOF'
ID=fedora
ID_LIKE="rhel centos"
PRETTY_NAME="Fedora de prueba"
EOF

  truncate -s 1048576 "${cache}/paquete.rpm"

  write_fake_command "${fakebin}" "dnf" "printf 'paquete-tres 1048576\\n'"

  if output="$(
    LINUXCLEANER_OS_RELEASE="${osr}" \
      LINUXCLEANER_DNF_CACHE_DIRS="${cache}" \
      LINUXCLEANER_JOURNAL_DIRS="${journal}" \
      PATH="${fakebin}:${PATH}" \
      bash ./cleaner.sh --scan
  )"; then
    assert_contains "${output}" "Fedora de prueba (fedora)" \
      "El escaneo detecta la familia Fedora"
    assert_contains "${output}" "(1 paquete(s))" \
      "El escaneo cuenta los paquetes huérfanos de DNF"
    assert_contains "${output}" "Total a liberar: ${total_expected}" \
      "El escaneo calcula el total de Fedora en formato legible"
  else
    fail "El escaneo de Fedora terminó con error"
  fi

  rm -rf "${tmp}"
}

test_scan_arch() {
  local tmp osr cache journal fakebin output
  local total_expected="2.00 MB"

  tmp="$(mktemp -d)"
  osr="${tmp}/os-release"
  cache="${tmp}/pacman"
  journal="${tmp}/journal"
  fakebin="${tmp}/bin"

  mkdir -p "${cache}" "${journal}" "${fakebin}"

  cat > "${osr}" << 'EOF'
ID=arch
PRETTY_NAME="Arch Linux de prueba"
EOF

  truncate -s 1048576 "${cache}/paquete.pkg.tar.zst"

  # shellcheck disable=SC2016 # El cuerpo simulado conserva sus expansiones.
  write_fake_command "${fakebin}" "pacman" '
case "${1:-}" in
  -Qtdq) printf "paquete-huerfano\n" ;;
  -Qi) printf "Name            : paquete-huerfano\nInstalled Size  : 1.00 MiB\n" ;;
  *) exit 0 ;;
esac'

  if output="$(
    LINUXCLEANER_OS_RELEASE="${osr}" \
      LINUXCLEANER_PACMAN_CACHE_DIR="${cache}" \
      LINUXCLEANER_JOURNAL_DIRS="${journal}" \
      PATH="${fakebin}:${PATH}" \
      bash ./cleaner.sh --scan
  )"; then
    assert_contains "${output}" "Arch Linux de prueba (arch)" \
      "El escaneo detecta la familia Arch"
    assert_contains "${output}" "(1 paquete(s))" \
      "El escaneo cuenta los paquetes huérfanos de pacman"
    assert_contains "${output}" "Total a liberar: ${total_expected}" \
      "El escaneo calcula el total de Arch en formato legible"
  else
    fail "El escaneo de Arch terminó con error"
  fi

  rm -rf "${tmp}"
}

test_scan_unsupported() {
  local tmp osr fakebin output status bash_bin

  tmp="$(mktemp -d)"
  osr="${tmp}/os-release"
  fakebin="${tmp}/bin"
  bash_bin="$(command -v bash)"

  mkdir -p "${fakebin}"
  ln -s "$(command -v readlink)" "${fakebin}/readlink"

  cat > "${osr}" << 'EOF'
ID=gentoo
PRETTY_NAME="Gentoo de prueba"
EOF

  if output="$(
    PATH="${fakebin}" \
      LINUXCLEANER_OS_RELEASE="${osr}" \
      "${bash_bin}" ./cleaner.sh --scan 2>&1
  )"; then
    fail "Una distribución no soportada debe devolver un código de error"
  else
    status=$?
    if ((status == 1)); then
      pass "Una distribución no soportada devuelve el código 1"
    else
      fail "Código de salida inesperado para una distribución no soportada: ${status}"
    fi
    assert_contains "${output}" "Distribución no soportada" \
      "El escaneo informa de una distribución no soportada"
  fi

  rm -rf "${tmp}"
}

test_pacman_cache_command() {
  local script

  script="$(cat cleaner.sh)"

  assert_contains "${script}" 'run_logged_yes "pacman -Scc" pacman -Scc' \
    "La limpieza de la caché de pacman confirma la pregunta"

  if [[ ${script} == *"pacman -Scc --noconfirm"* ]]; then
    fail "La limpieza de pacman no debe usar --noconfirm (responde 'No' por defecto)"
  else
    pass "La limpieza de pacman no usa --noconfirm"
  fi
}

test_pacman_cache_accepts_partial_unlink_failure() {
  local tmp script rc

  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/cache" "${tmp}/bin"
  printf 'paquete' > "${tmp}/cache/paquete.pkg.tar.zst"
  mkdir "${tmp}/cache/download-abc"

  cat > "${tmp}/bin/pacman" << 'EOF'
#!/usr/bin/env bash
# Emula pacman -Scc en un sistema real: borra los paquetes, pero devuelve 1
# porque unlink() no puede borrar los directorios download-XXXX.
find "${PACMAN_CACHE_DIR}" -maxdepth 1 -type f -delete
exit 1
EOF
  chmod +x "${tmp}/bin/pacman"

  {
    printf 'log_line() { :; }\n'
    printf 'LOG_FILE=%q\n' "${tmp}/linuxcleaner.log"
    printf 'PACMAN_CACHE_DIR=%q\n' "${tmp}/cache"
    printf 'export PACMAN_CACHE_DIR\n'
    sed -n '/^sum_paths_bytes()/,/^}/p' cleaner.sh
    sed -n '/^run_logged_yes()/,/^}/p' cleaner.sh
    sed -n '/^cleanup_pacman_cache()/,/^}/p' cleaner.sh
    printf 'cleanup_pacman_cache\n'
  } > "${tmp}/prueba.sh"

  set +e
  PATH="${tmp}/bin:${PATH}" bash "${tmp}/prueba.sh" > /dev/null 2>&1
  rc=$?
  set -e

  if ((rc == 0)); then
    pass "La caché vaciada se acepta aunque pacman falle al borrar directorios"
  else
    fail "La caché vaciada se trata como error (código ${rc})"
  fi

  # Si pacman falla y no borra nada, el error debe propagarse.
  printf 'paquete' > "${tmp}/cache/paquete.pkg.tar.zst"
  cat > "${tmp}/bin/pacman" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${tmp}/bin/pacman"

  set +e
  PATH="${tmp}/bin:${PATH}" bash "${tmp}/prueba.sh" > /dev/null 2>&1
  rc=$?
  set -e

  if ((rc != 0)); then
    pass "Un fallo real de pacman sin liberar espacio se propaga"
  else
    fail "Un fallo real de pacman se oculta como éxito"
  fi

  rm -rf "${tmp}"
}

test_privileged_mode_requires_root() {
  local output

  if ((EUID == 0)); then
    skip "El modo privilegiado se omite al ejecutar las pruebas como root"
    return 0
  fi

  if output="$(bash ./cleaner.sh --privileged-clean 2>&1)"; then
    fail "El modo privilegiado no debe ejecutarse como usuario normal"
  else
    assert_contains "${output}" "solo puede ejecutarse como root" \
      "El modo privilegiado rechaza a usuarios sin privilegios"
  fi
}

test_installer_dry_run() {
  local target output

  target="$(mktemp -d)"
  output="$(bash ./install.sh --dry-run --destdir "${target}")" \
    || fail "El instalador falla en modo --dry-run"

  assert_contains "${output}" "[dry-run]" "El instalador anuncia el modo de prueba"
  assert_contains "${output}" "Instalación completada" "El instalador simula la instalación"

  if [[ -z $(find "${target}" -mindepth 1 -print -quit) ]]; then
    pass "El modo --dry-run no escribe en el destino"
  else
    fail "El modo --dry-run escribió en ${target}"
  fi

  rm -rf "${target}"
}

test_installer_destdir() {
  local target output binary rule desktop icon

  target="$(mktemp -d)"
  binary="${target}/usr/local/bin/linuxcleaner"
  rule="${target}/etc/polkit-1/rules.d/50-linuxcleaner.rules"
  desktop="${target}/usr/share/applications/linuxcleaner.desktop"
  icon="${target}/usr/share/icons/hicolor/scalable/apps/linuxcleaner.svg"

  output="$(bash ./install.sh --destdir "${target}")" \
    || fail "El instalador falla al preparar una instalación temporal"

  assert_contains "${output}" "Instalación completada" \
    "El instalador completa una instalación temporal"
  assert_file_exists "${binary}" "El instalador copia el ejecutable"
  assert_file_exists "${rule}" "El instalador copia la regla de PolicyKit"
  assert_file_exists "${desktop}" "El instalador copia la entrada del lanzador"
  assert_file_exists "${icon}" "El instalador copia el icono"
  assert_file_mode "${binary}" "755" "El ejecutable tiene permisos 755"
  assert_file_mode "${rule}" "644" "La regla tiene permisos 644"
  assert_file_mode "${desktop}" "644" "La entrada del lanzador tiene permisos 644"
  assert_file_mode "${icon}" "644" "El icono tiene permisos 644"
  assert_same_file "cleaner.sh" "${binary}" "El ejecutable instalado es idéntico al fuente"
  assert_same_file "polkit/50-linuxcleaner.rules" "${rule}" \
    "La regla instalada es idéntica a la fuente"
  assert_same_file "desktop/linuxcleaner.desktop" "${desktop}" \
    "La entrada del lanzador instalada es idéntica a la fuente"
  assert_same_file "desktop/linuxcleaner.svg" "${icon}" \
    "El icono instalado es idéntico al fuente"

  output="$(bash "${binary}" --version)"
  assert_contains "${output}" "linuxcleaner 1.0.0" \
    "El ejecutable instalado se puede ejecutar"

  bash ./install.sh --uninstall --destdir "${target}" > /dev/null \
    || fail "El instalador falla al desinstalar de un destino temporal"

  assert_not_exists "${binary}" "La desinstalación elimina el ejecutable"
  assert_not_exists "${rule}" "La desinstalación elimina la regla"
  assert_not_exists "${desktop}" "La desinstalación elimina la entrada del lanzador"
  assert_not_exists "${icon}" "La desinstalación elimina el icono"

  rm -rf "${target}"
}

test_rule_content() {
  local rule

  rule="$(cat polkit/50-linuxcleaner.rules)"

  assert_contains "${rule}" "org.freedesktop.policykit.exec" \
    "La regla filtra por la acción de pkexec"
  assert_contains "${rule}" "/usr/local/bin/linuxcleaner" \
    "La regla restringe la ruta del programa"
  assert_contains "${rule}" "--privileged-clean" \
    "La regla restringe la línea de comandos"
  assert_contains "${rule}" "wheel" "La regla reconoce el grupo wheel"
  assert_contains "${rule}" "sudo" "La regla reconoce el grupo sudo"
  assert_contains "${rule}" "admin" "La regla reconoce el grupo admin"
}

test_rule_logic() {
  local output

  if ! command -v node > /dev/null 2>&1; then
    skip "Node.js no está disponible; se omite la lógica de la regla"
    return 0
  fi

  if output="$(node tests/rule-logic.mjs 2>&1)"; then
    assert_contains "${output}" "OK" "La regla aplica las restricciones esperadas"
  else
    fail "La lógica de la regla no pasa las comprobaciones: ${output}"
  fi
}

test_rule_validator() {
  local output

  if ! command -v node > /dev/null 2>&1; then
    skip "Node.js no está disponible; se omite la validación de reglas"
    return 0
  fi

  output="$(node scripts/validate-rules.mjs polkit/50-linuxcleaner.rules)" \
    || fail "El validador rechaza la regla de LinuxCleaner"

  assert_contains "${output}" "OK" "El validador acepta la regla de LinuxCleaner"
}

test_rule_validator_rejects_invalid() {
  local bad output modern

  if ! command -v node > /dev/null 2>&1; then
    skip "Node.js no está disponible; se omite la prueba de regla inválida"
    return 0
  fi

  bad="$(mktemp)"
  printf 'polkit.addRule(function (action, subject) {\n' > "${bad}"

  if output="$(node scripts/validate-rules.mjs "${bad}" 2>&1)"; then
    fail "El validador acepta una regla con sintaxis inválida"
  else
    assert_contains "${output}" "FALLO" "El validador rechaza una regla inválida"
  fi

  rm -f "${bad}"

  # polkit usa duktape, que no admite 'let': el validador debe rechazarlo
  # aunque Node.js sí lo acepte.
  modern="$(mktemp)"
  cat > "${modern}" << 'EOF'
polkit.addRule(function (action, subject) {
    let index = 0;
    return index;
});
EOF

  if output="$(node scripts/validate-rules.mjs "${modern}" 2>&1)"; then
    fail "El validador acepta 'let', que duktape no admite"
  else
    assert_contains "${output}" "duktape" "El validador rechaza sintaxis no compatible con duktape"
  fi

  rm -f "${modern}"
}

main() {
  test_structure
  test_desktop_entry
  test_help_and_version
  test_unknown_option
  test_scan_debian
  test_scan_fedora
  test_scan_arch
  test_scan_unsupported
  test_pacman_cache_command
  test_pacman_cache_accepts_partial_unlink_failure
  test_privileged_mode_requires_root
  test_installer_dry_run
  test_installer_destdir
  test_rule_content
  test_rule_logic
  test_rule_validator
  test_rule_validator_rejects_invalid

  printf '\n%d prueba(s) correcta(s), %d fallida(s), %d omitida(s).\n' \
    "${PASSED}" "${FAILED}" "${SKIPPED}"

  if ((FAILED > 0)); then
    exit 1
  fi
}

main "$@"
