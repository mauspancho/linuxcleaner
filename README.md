# LinuxCleaner

Utilidad de mantenimiento para Linux escrita en Bash, sin Python, con interfaz gráfica Zenity y
elevación de privilegios mediante `pkexec` y PolicyKit.

LinuxCleaner analiza primero el sistema, calcula el espacio que se puede liberar y solo ejecuta la
limpieza después de una confirmación explícita. La ventana de progreso muestra el avance real del
proceso privilegiado.

## Características

- Detección automática de la distribución mediante `/etc/os-release`.
- Cálculo previo del espacio recuperable, mostrado en B, KB, MB, GB o TB.
- Escaneo inicial con barra de progreso.
- Diálogo de confirmación con el resumen exacto antes de limpiar.
- Limpieza ejecutada como root mediante `pkexec`.
- Progreso y mensajes enviados por una tubería a `zenity --progress`.
- Diálogo final de éxito con el espacio calculado.
- Registro de la limpieza en `/var/log/linuxcleaner.log`.
- Sin contraseñas en texto plano ni uso de `sudo -S`.

## Distribuciones soportadas

| Familia       | Distribuciones de ejemplo                     | Limpieza                                                                  |
| ------------- | --------------------------------------------- | ------------------------------------------------------------------------- |
| Debian/Ubuntu | Debian, Ubuntu, Linux Mint, Pop!\_OS, Kali    | `apt-get autoremove --purge`, `apt-get clean`, `journalctl --vacuum-time` |
| Fedora/RHEL   | Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux | `dnf autoremove`, `dnf clean all`, `journalctl --vacuum-time`             |
| Arch Linux    | Arch, Manjaro, EndeavourOS, Garuda            | `pacman -Rns` de huérfanos, `pacman -Scc`, `journalctl --vacuum-time`     |

La caché de logs se recorta a los últimos 7 días. Si `journalctl` no está disponible, esa categoría
se omite. El cálculo de la caché de logs puede ser conservador cuando el usuario sin privilegios no
puede leer todos los archivos del journal; el proceso privilegiado vuelve a analizar antes de
limpiar.

## Qué se analiza y qué se elimina

LinuxCleaner solo actúa sobre cachés de paquetes, paquetes huérfanos y registros antiguos del
sistema. **No borra documentos, archivos personales ni configuraciones de usuario.**

### Rutas que se escanean

| Categoría          | Debian/Ubuntu                          | Fedora/RHEL                                              | Arch Linux                             |
| ------------------ | -------------------------------------- | -------------------------------------------------------- | -------------------------------------- |
| Caché de paquetes  | `/var/cache/apt/archives`              | `/var/cache/dnf`, `/var/cache/yum`, `/var/cache/libdnf5` | `/var/cache/pacman/pkg`                |
| Paquetes huérfanos | `apt-get -s autoremove --purge`        | `dnf repoquery --unneeded --installed`                   | `pacman -Qtdq`                         |
| Registros antiguos | `/var/log/journal`, `/run/log/journal` | `/var/log/journal`, `/run/log/journal`                   | `/var/log/journal`, `/run/log/journal` |

El tamaño de la caché se calcula sumando los archivos de esas carpetas. El de los paquetes huérfanos
se obtiene del tamaño instalado que informa cada gestor. El de los registros suma los archivos
`*.journal~` con más de 7 días de antigüedad.

### Rutas y datos que se eliminan

| Familia       | Acción                          | Qué se borra exactamente                                                                                                                                        |
| ------------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Debian/Ubuntu | `apt-get autoremove --purge -y` | Paquetes instalados automáticamente que ya no son necesarios y sus archivos de configuración. No elimina paquetes instalados manualmente.                       |
| Debian/Ubuntu | `apt-get clean`                 | Todos los paquetes `.deb` descargados en `/var/cache/apt/archives`, incluida la subcarpeta `partial/`.                                                          |
| Fedora/RHEL   | `dnf -y autoremove`             | Paquetes huérfanos: los instalados como dependencia que ya no necesita ningún paquete instalado.                                                                |
| Fedora/RHEL   | `dnf clean all`                 | Metadatos y paquetes descargados en `/var/cache/dnf`, `/var/cache/yum` y `/var/cache/libdnf5`.                                                                  |
| Arch Linux    | `pacman -Rns --noconfirm`       | Paquetes huérfanos (`pacman -Qtdq`), sus dependencias no usadas, archivos de configuración y archivos sobrantes. No elimina paquetes requeridos explícitamente. |
| Arch Linux    | `pacman -Scc`                   | Todos los paquetes y firmas de `/var/cache/pacman/pkg`. Pueden quedar directorios vacíos `download-*` de descargas parciales.                                   |
| Todas         | `journalctl --vacuum-time=7d`   | Entradas archivadas del journal con más de 7 días en `/var/log/journal` y `/run/log/journal`.                                                                   |

### Qué no se toca

- Archivos personales: `/home`, escritorio, documentos, descargas, etc.
- Configuraciones del sistema y del usuario en `/etc` y `~/.config`.
- Bases de datos de paquetes: `/var/lib/dpkg`, `/var/lib/rpm` y `/var/lib/pacman/local`, necesarias
  para conocer qué paquetes están instalados.
- Paquetes instalados manualmente que no sean huérfanos.
- Registros del journal con menos de 7 días.

## Requisitos

- Bash 4.4 o posterior.
- `zenity` para la interfaz gráfica.
- `pkexec` y PolicyKit para la elevación de privilegios.
- `systemd` con `journalctl` (opcional, para la caché de logs).
- Gestor de paquetes de la distribución: `apt-get`/`dpkg-query`, `dnf` o `pacman`.

En Debian/Ubuntu instala las dependencias gráficas con:

```bash
sudo apt install zenity policykit-1  # en versiones recientes: zenity pkexec
```

En Fedora/RHEL:

```bash
sudo dnf install zenity polkit
```

En Arch Linux:

```bash
sudo pacman -S zenity polkit
```

## Instalación

Desde la raíz del proyecto:

```bash
sudo ./install.sh
```

El instalador:

1. Valida la sintaxis del ejecutable y la regla de PolicyKit.
2. Copia `cleaner.sh` a `/usr/local/bin/linuxcleaner` con permisos `0755`.
3. Copia `polkit/50-linuxcleaner.rules` a `/etc/polkit-1/rules.d/50-linuxcleaner.rules` con permisos
   `0644`.
4. Instala la entrada del lanzador en `/usr/share/applications/linuxcleaner.desktop` y el icono en
   `/usr/share/icons/hicolor/scalable/apps/linuxcleaner.svg`, ambos con permisos `0644`.
5. Aplica propietario `root:root` a todos los archivos.
6. Guarda una copia de seguridad si ya existían.
7. Actualiza las cachés de aplicaciones e iconos del escritorio, si las herramientas están
   disponibles.
8. Recarga el servicio de PolicyKit.

Gracias a la entrada `.desktop` estándar, LinuxCleaner aparece en el lanzador de aplicaciones de
cualquier entorno de escritorio (GNOME, KDE Plasma, XFCE, Cinnamon, MATE, LXQt, etc.) sin
configuración adicional.

Puedes revisar lo que hará antes de modificar el sistema:

```bash
./install.sh --dry-run
```

Para preparar una instalación en un directorio temporal (pruebas o empaquetado):

```bash
./install.sh --destdir /tmp/linuxcleaner-prueba
```

Tras instalar, inicia la aplicación desde el lanzador de tu escritorio (busca **LinuxCleaner**) o
desde una terminal:

```bash
linuxcleaner
```

También puedes lanzar la interfaz desde el repositorio con `./cleaner.sh`. En ambos casos la
limpieza privilegiada se ejecuta siempre desde `/usr/local/bin/linuxcleaner`, que es la ruta
autorizada por la regla de PolicyKit.

También puedes analizar el sistema sin abrir la interfaz gráfica:

```bash
linuxcleaner --scan
```

## Uso

1. Abre `linuxcleaner` desde una terminal.
2. Espera a que termine el análisis inicial.
3. Revisa el resumen: distribución, caché de paquetes, paquetes huérfanos, caché de logs y total a
   liberar.
4. Pulsa **Limpiar** para continuar o **Cancelar** para no hacer cambios.
5. Si PolicyKit lo requiere, autoriza la operación.
6. Observa el progreso y el mensaje final.

Opciones de línea de comandos:

| Opción               | Descripción                                                      |
| -------------------- | ---------------------------------------------------------------- |
| `--scan`             | Analiza el sistema y muestra el resumen en la terminal.          |
| `--privileged-clean` | Modo interno usado por `pkexec`. No debe ejecutarse manualmente. |
| `-h`, `--help`       | Muestra la ayuda.                                                |
| `-V`, `--version`    | Muestra la versión.                                              |

## Seguridad

- La interfaz y el análisis inicial se ejecutan como el usuario normal.
- Solo el proceso de limpieza se ejecuta como root, a través de `pkexec`.
- No se usan contraseñas en variables, argumentos ni tuberías.
- La regla `50-linuxcleaner.rules` autoriza automáticamente la acción
  `org.freedesktop.policykit.exec` solo cuando coinciden exactamente:
  - el programa `/usr/local/bin/linuxcleaner`;
  - la línea de comandos `/usr/local/bin/linuxcleaner --privileged-clean`;
  - una sesión local y activa de un usuario de los grupos `wheel`, `sudo` o `admin`.
- Los usuarios que no pertenecen a esos grupos deben autenticarse como administradores.
- Cualquier otra invocación de `pkexec` sigue el flujo normal de autenticación de PolicyKit.
- Antes de borrar, el proceso privilegiado comprueba que se ejecuta desde la ruta instalada, que el
  archivo pertenece a root y que ni el archivo ni su directorio son escribibles por grupo u otros
  usuarios.
- El proceso privilegiado fuerza las rutas de producción y un `PATH` seguro, ignorando las variables
  de entorno usadas en las pruebas.
- Las reglas de PolicyKit se escriben en sintaxis ES5 porque polkit las evalúa con duktape. El
  proyecto lo comprueba con ESLint (`ecmaVersion: 5`) y con el validador de reglas.

El registro se guarda en `/var/log/linuxcleaner.log` con permisos `0640`.

## Solución de problemas

- **PolicyKit pide la contraseña cada vez**: comprueba que polkit pudo cargar la regla:

  ```bash
  journalctl -b | grep linuxcleaner.rules
  ```

  Si aparece un error de compilación, actualiza el proyecto y vuelve a ejecutar `sudo ./install.sh`.
  La regla debe usar sintaxis ES5.

- **La limpieza dice que terminó, pero la caché sigue ocupando lo mismo**: actualiza el proyecto y
  vuelve a instalar. En Arch Linux, `pacman -Scc --noconfirm` no borra nada porque responde "No" a
  la pregunta "remove ALL files from cache? [y/N]"; la versión actual confirma esa pregunta de forma
  explícita.

- **Aparece "No se pudo completar la limpieza" aunque la caché quedó vacía**: en Arch Linux,
  `pacman -Scc` devuelve un código de error si quedan directorios temporales `download-XXXX` de
  descargas parciales, porque no puede borrarlos con `unlink()`. La versión actual comprueba el
  espacio real antes de informar de un fallo, así que ese caso ya no muestra el error. Si el aviso
  persiste, revisa el registro con `sudo tail -n 80 /var/log/linuxcleaner.log`.

- **La aplicación no aparece en el lanzador**: comprueba que la entrada está instalada:

  ```bash
  ls -l /usr/share/applications/linuxcleaner.desktop
  update-desktop-database ~/.local/share/applications 2>/dev/null || true
  ```

  Algunos entornos tardan unos segundos o requieren cerrar y volver a abrir la sesión. También
  puedes ejecutar `linuxcleaner` desde una terminal para comprobar que la aplicación funciona.

- **Se cierra la ventana de progreso pero el proceso sigue vivo**: revisa que no quede un diálogo de
  PolicyKit abierto. Con la regla bien instalada, los usuarios de `wheel`, `sudo` o `admin` no
  necesitan autenticarse.

## Desinstalación

```bash
sudo ./install.sh --uninstall
```

Se eliminan el ejecutable, la regla de PolicyKit, la entrada del lanzador y el icono. El archivo de
registro se conserva para que puedas revisarlo.

## Estructura del proyecto

```text
.
├── cleaner.sh                        # Aplicación principal
├── desktop/
│   ├── linuxcleaner.desktop          # Entrada del lanzador de aplicaciones
│   └── linuxcleaner.svg              # Icono de la aplicación
├── polkit/
│   └── 50-linuxcleaner.rules         # Regla de autorización de PolicyKit
├── install.sh                        # Instalador y desinstalador
├── README.md                         # Esta documentación
├── scripts/                          # Utilidades de validación y formato
├── tests/
│   ├── smoke.sh                      # Pruebas sin interfaz gráfica
│   └── rule-logic.mjs                # Pruebas de la regla de PolicyKit
└── Makefile                          # Tareas de desarrollo
```

## Desarrollo

El proyecto usa ShellCheck, shfmt, Prettier y ESLint. Las herramientas locales se descargan en
`.tools/bin` y las dependencias Node en `node_modules`:

```bash
make setup    # Descarga ShellCheck/shfmt e instala dependencias
make check    # Sintaxis, ShellCheck, shfmt, reglas, Prettier y ESLint
make format   # Aplica formato y correcciones automáticas
make test     # Ejecuta las pruebas de humo
```

Las pruebas no requieren root ni entorno gráfico: usan un `/etc/os-release` falso, directorios
temporales y comandos simulados de APT, DNF y pacman.

## Avisos

- LinuxCleaner se centra en cachés y paquetes del sistema; no elimina datos personales ni cachés de
  navegadores.
- Revisa siempre el resumen antes de confirmar. La purga de paquetes huérfanos puede eliminar
  software que ya no necesitas.
- El espacio mostrado es una estimación calculada antes de la limpieza; el espacio realmente
  liberado puede variar por el estado del sistema de archivos, la compresión o los paquetes que el
  gestor decida conservar.
- No ejecutes `--privileged-clean` a mano. Está pensado para ser invocado únicamente por `pkexec` y
  está protegido por la regla de PolicyKit.
