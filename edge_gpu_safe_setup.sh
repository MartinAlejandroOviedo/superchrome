#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/edge-gpu-setup"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
BIN_DIR="$HOME/.local/bin"
LAST_RUN_FILE="$STATE_DIR/last_run"

DRY_RUN=0
DO_REVERT=0
INSTALL_DEPS=0
ASSUME_YES=0
FORCE_PLATFORM="auto"
FORCE_BROWSER="auto"

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERR ] %s\n' "$*" >&2; }

usage() {
  cat <<EOF
Uso:
  $SCRIPT_NAME [opciones]

Opciones:
  --dry-run        Muestra qué cambiaría, sin escribir archivos.
  --revert         Revierte la última ejecución aplicada por este script.
  --install-deps   Intenta instalar utilidades de diagnóstico (mesa-utils / vainfo según distro).
  --x11            Fuerza launcher del navegador en X11 (útil para evitar warnings Wayland+Vulkan).
  --wayland        Fuerza launcher del navegador en Wayland.
  --browser        auto|edge|chrome|chromium (default: auto)
  -y, --yes        No pide confirmación interactiva.
  -h, --help       Muestra esta ayuda.

Qué hace (modo apply):
  1) Detecta distro y sesión (Wayland/X11).
  2) Crea un wrapper seguro en ~/.local/bin para Edge/Chrome/Chromium con flags GPU.
  3) Crea un lanzador nuevo en ~/.local/share/applications (no toca /usr/share).
  4) Guarda backup y metadata para poder revertir.
EOF
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY ]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

confirm() {
  local msg="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$msg [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" || "${ans,,}" == "s" || "${ans,,}" == "si" ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_path_in_home() {
  [[ "$1" == "$HOME/"* ]]
}

detect_distro() {
  local id="unknown" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"
    like="${ID_LIKE:-}"
  fi

  DISTRO_ID="$id"
  DISTRO_LIKE="$like"

  case "$id:$like" in
    ubuntu:*|debian:*|linuxmint:*|pop:*|zorin:*|elementary:*|*":debian"*) DISTRO_FAMILY="debian" ;;
    fedora:*|rhel:*|centos:*|rocky:*|almalinux:*|ol:*|*":rhel"*|*":fedora"*) DISTRO_FAMILY="rhel" ;;
    arch:*|manjaro:*|endeavouros:*|garuda:*|*":arch"*) DISTRO_FAMILY="arch" ;;
    opensuse*:*|sles:*|*":suse"*) DISTRO_FAMILY="suse" ;;
    alpine:*|*":alpine"*) DISTRO_FAMILY="alpine" ;;
    *) DISTRO_FAMILY="unknown" ;;
  esac
}

detect_session() {
  local st="${XDG_SESSION_TYPE:-}"
  if [[ -z "$st" ]]; then
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
      st="wayland"
    else
      st="x11"
    fi
  fi
  SESSION_TYPE="${st,,}"
}

find_browser_binary() {
  local candidates=()
  local c

  case "$FORCE_BROWSER" in
    edge)
      candidates=(microsoft-edge-stable microsoft-edge-beta microsoft-edge-dev microsoft-edge)
      ;;
    chrome)
      candidates=(google-chrome-stable google-chrome-beta google-chrome-unstable google-chrome)
      ;;
    chromium)
      candidates=(chromium chromium-browser)
      ;;
    auto)
      candidates=(
        microsoft-edge-stable microsoft-edge-beta microsoft-edge-dev microsoft-edge
        google-chrome-stable google-chrome-beta google-chrome-unstable google-chrome
        chromium chromium-browser
      )
      ;;
    *)
      err "Valor inválido para --browser: $FORCE_BROWSER"
      exit 1
      ;;
  esac

  BROWSER_BIN=""
  BROWSER_CHANNEL=""
  for c in "${candidates[@]}"; do
    if require_cmd "$c"; then
      BROWSER_BIN="$(command -v "$c")"
      BROWSER_CHANNEL="$c"
      break
    fi
  done

  if [[ -z "$BROWSER_BIN" ]]; then
    err "No encontré un navegador compatible en PATH."
    err "Probé: ${candidates[*]}"
    exit 1
  fi
}

icon_for_channel() {
  case "$BROWSER_CHANNEL" in
    microsoft-edge-stable) echo "microsoft-edge" ;;
    microsoft-edge-beta) echo "microsoft-edge-beta" ;;
    microsoft-edge-dev) echo "microsoft-edge-dev" ;;
    google-chrome-stable|google-chrome-beta|google-chrome-unstable|google-chrome) echo "google-chrome" ;;
    chromium|chromium-browser) echo "chromium-browser" ;;
    *) echo "web-browser" ;;
  esac
}

configure_browser_metadata() {
  case "$BROWSER_CHANNEL" in
    microsoft-edge-stable|microsoft-edge-beta|microsoft-edge-dev|microsoft-edge)
      BROWSER_FAMILY="edge"
      WRAPPER_NAME="microsoft-edge-gpu"
      DESKTOP_NAME="microsoft-edge-gpu.desktop"
      APP_LABEL="Microsoft Edge (GPU)"
      APP_COMMENT="Microsoft Edge con aceleración por hardware"
      APP_WMCLASS="Microsoft-edge"
      BROWSER_CONFIG_ROOT="$HOME/.config/microsoft-edge"
      ;;
    google-chrome-stable|google-chrome-beta|google-chrome-unstable|google-chrome)
      BROWSER_FAMILY="chrome"
      WRAPPER_NAME="google-chrome-gpu"
      DESKTOP_NAME="google-chrome-gpu.desktop"
      APP_LABEL="Google Chrome (GPU)"
      APP_COMMENT="Google Chrome con aceleración por hardware"
      APP_WMCLASS="Google-chrome"
      BROWSER_CONFIG_ROOT="$HOME/.config/google-chrome"
      ;;
    chromium|chromium-browser)
      BROWSER_FAMILY="chromium"
      WRAPPER_NAME="chromium-gpu"
      DESKTOP_NAME="chromium-gpu.desktop"
      APP_LABEL="Chromium (GPU)"
      APP_COMMENT="Chromium con aceleración por hardware"
      APP_WMCLASS="Chromium"
      BROWSER_CONFIG_ROOT="$HOME/.config/chromium"
      ;;
    *)
      err "Canal de navegador no soportado: $BROWSER_CHANNEL"
      exit 1
      ;;
  esac

  BROWSER_ICON="$(icon_for_channel)"
}

set_gpu_flags() {
  local ozone_hint

  case "$FORCE_PLATFORM" in
    x11) ozone_hint="x11" ;;
    wayland) ozone_hint="wayland" ;;
    *) ozone_hint="auto" ;;
  esac

  BROWSER_FLAGS=(
    "--ignore-gpu-blocklist"
    "--enable-gpu-rasterization"
    "--enable-zero-copy"
    "--ozone-platform-hint=$ozone_hint"
    "--enable-features=VaapiVideoDecoder,VaapiVideoEncoder"
    "--disable-features=Vulkan"
    "--disable-vulkan"
    "--use-vulkan=none"
  )
}

backup_and_remove_path() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    return 0
  fi

  backup_and_record "$path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY ] Limpiar cache/estado GPU: %s\n' "$path"
  else
    rm -rf "$path"
  fi
}

reset_browser_gpu_runtime_state() {
  local root="$BROWSER_CONFIG_ROOT"
  local profile

  if [[ ! -d "$root" ]]; then
    return 0
  fi

  for profile in "$root"/Default "$root"/Profile*; do
    [[ -d "$profile" ]] || continue

    backup_and_remove_path "$profile/GPUCache"
    backup_and_remove_path "$profile/GrShaderCache"
    backup_and_remove_path "$profile/DawnCache"
    backup_and_remove_path "$profile/ShaderCache"
    backup_and_remove_path "$profile/DawnGraphiteCache"
    backup_and_remove_path "$profile/DawnWebGPUCache"
  done

  backup_and_remove_path "$root/ShaderCache"
  backup_and_remove_path "$root/GraphiteDawnCache"
}

pkg_install_hint() {
  case "$DISTRO_FAMILY" in
    debian)
      echo "sudo apt update && sudo apt install -y mesa-utils vainfo"
      ;;
    rhel)
      echo "sudo dnf install -y mesa-demos libva-utils"
      ;;
    arch)
      echo "sudo pacman -S --needed mesa-demos libva-utils"
      ;;
    suse)
      echo "sudo zypper install -y Mesa-demo-x libva-utils"
      ;;
    alpine)
      echo "sudo apk add mesa-demos libva-utils"
      ;;
    *)
      echo "Instala manualmente: mesa-utils/mesa-demos y vainfo/libva-utils"
      ;;
  esac
}

install_deps() {
  local cmd
  cmd="$(pkg_install_hint)"
  log "Comando sugerido para utilidades de diagnóstico: $cmd"

  if ! confirm "¿Quieres intentar instalar ahora esas utilidades?"; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY ] %s\n' "$cmd"
    return 0
  fi

  if ! require_cmd sudo; then
    warn "No existe sudo. Ejecuta manualmente: $cmd"
    return 0
  fi

  case "$DISTRO_FAMILY" in
    debian)
      run sudo apt update
      run sudo apt install -y mesa-utils vainfo
      ;;
    rhel)
      run sudo dnf install -y mesa-demos libva-utils
      ;;
    arch)
      run sudo pacman -S --needed mesa-demos libva-utils
      ;;
    suse)
      run sudo zypper install -y Mesa-demo-x libva-utils
      ;;
    alpine)
      run sudo apk add mesa-demos libva-utils
      ;;
    *)
      warn "No tengo instalador automático para esta distro. Ejecuta manualmente: $cmd"
      ;;
  esac
}

new_run_dir() {
  RUN_ID="$(date +%Y%m%d-%H%M%S)"
  RUN_DIR="$STATE_DIR/runs/$RUN_ID"
  MANIFEST="$RUN_DIR/manifest.tsv"

  run mkdir -p "$RUN_DIR" "$APP_DIR" "$BIN_DIR"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    : > "$MANIFEST"
  fi
}

backup_and_record() {
  local target="$1"
  local name backup had_original

  name="$(echo "$target" | sed 's#/#__#g')"
  backup="$RUN_DIR/$name.bak"

  if [[ -e "$target" ]]; then
    had_original=1
    run cp -a "$target" "$backup"
  else
    had_original=0
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' "$target" "$had_original" "$backup" >> "$MANIFEST"
  fi
}

write_wrapper() {
  WRAPPER_PATH="$BIN_DIR/$WRAPPER_NAME"
  backup_and_record "$WRAPPER_PATH"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY ] Escribir wrapper: %s\n' "$WRAPPER_PATH"
    return 0
  fi

  cat > "$WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FLAGS=(
EOF
  local flag
  for flag in "${BROWSER_FLAGS[@]}"; do
    printf '  %q\n' "$flag" >> "$WRAPPER_PATH"
  done
  cat >> "$WRAPPER_PATH" <<EOF
)
exec "$BROWSER_BIN" "\${FLAGS[@]}" "\$@"
EOF
  chmod +x "$WRAPPER_PATH"
}

write_desktop_entry() {
  DESKTOP_PATH="$APP_DIR/$DESKTOP_NAME"
  backup_and_record "$DESKTOP_PATH"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY ] Escribir desktop launcher: %s\n' "$DESKTOP_PATH"
    return 0
  fi

  cat > "$DESKTOP_PATH" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$APP_LABEL
Comment=$APP_COMMENT
Exec=$WRAPPER_PATH %U
Terminal=false
Icon=$BROWSER_ICON
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
StartupWMClass=$APP_WMCLASS
EOF

  if require_cmd update-desktop-database; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[DRY ] update-desktop-database %s\n' "$APP_DIR"
    else
      update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
  fi
}

write_desktop_override() {
  local source_path="$1"
  local target_name="$2"
  local target_path="$APP_DIR/$target_name"

  if [[ ! -f "$source_path" ]]; then
    return 0
  fi

  backup_and_record "$target_path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY ] Crear override limpio: %s (desde %s)\n' "$target_path" "$source_path"
    return 0
  fi

  awk -v wrapper="$WRAPPER_PATH" '
    /^Exec=/ {
      has_inprivate = index($0, "--inprivate") > 0
      has_u = index($0, "%U") > 0

      line = "Exec=" wrapper
      if (has_inprivate) line = line " --inprivate"
      if (has_u) line = line " %U"

      print line
      next
    }
    { print }
  ' "$source_path" > "$target_path"
}

write_standard_browser_overrides() {
  case "$BROWSER_FAMILY" in
    edge)
      write_desktop_override "/usr/share/applications/microsoft-edge.desktop" "microsoft-edge.desktop"
      write_desktop_override "/usr/share/applications/com.microsoft.Edge.desktop" "com.microsoft.Edge.desktop"
      ;;
    chrome)
      write_desktop_override "/usr/share/applications/google-chrome.desktop" "google-chrome.desktop"
      write_desktop_override "/usr/share/applications/com.google.Chrome.desktop" "com.google.Chrome.desktop"
      ;;
    chromium)
      write_desktop_override "/usr/share/applications/chromium.desktop" "chromium.desktop"
      write_desktop_override "/usr/share/applications/org.chromium.Chromium.desktop" "org.chromium.Chromium.desktop"
      ;;
  esac

  if require_cmd update-desktop-database; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[DRY ] update-desktop-database %s\n' "$APP_DIR"
    else
      update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
  fi
}

save_last_run() {
  if [[ "$DRY_RUN" -eq 0 ]]; then
    run mkdir -p "$STATE_DIR"
    printf '%s\n' "$RUN_DIR" > "$LAST_RUN_FILE"
  fi
}

show_next_steps() {
  echo
  log "Listo. Se creó un lanzador nuevo sin tocar archivos del sistema."
  log "Abre desde menú: '$APP_LABEL'"
  log "También se crearon overrides seguros del launcher estándar en ~/.local/share/applications."
  log "Verifica en chrome://gpu (aplica a Edge/Chrome/Chromium)"
  echo
  log "Diagnóstico opcional:"
  echo "  - glxinfo -B | grep -E 'OpenGL vendor|OpenGL renderer'"
  echo "  - vainfo"
  echo
  log "Para revertir la última ejecución:"
  echo "  $SCRIPT_NAME --revert"
}

revert_last_run() {
  if [[ ! -f "$LAST_RUN_FILE" ]]; then
    err "No hay historial de ejecuciones para revertir en $LAST_RUN_FILE"
    exit 1
  fi

  local run_dir manifest
  run_dir="$(cat "$LAST_RUN_FILE")"
  manifest="$run_dir/manifest.tsv"

  if [[ ! -f "$manifest" ]]; then
    err "No encuentro manifest para revertir: $manifest"
    exit 1
  fi

  log "Revirtiendo última ejecución: $run_dir"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    cp "$manifest" "$run_dir/manifest.revert.input.tsv"
  fi

  while IFS=$'\t' read -r target had_original backup; do
    if ! is_path_in_home "$target"; then
      warn "Ruta fuera de HOME en manifest, omito por seguridad: $target"
      continue
    fi

    if [[ "$had_original" == "1" ]]; then
      if [[ -e "$backup" ]]; then
        run cp -a "$backup" "$target"
        log "Restaurado: $target"
      else
        warn "Falta backup para $target, omito."
      fi
    else
      if [[ -e "$target" ]]; then
        run rm -rf -- "$target"
        log "Eliminado recurso creado por script: $target"
      fi
    fi
  done < "$manifest"

  log "Reversión terminada."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --revert)
        DO_REVERT=1
        shift
        ;;
      --install-deps)
        INSTALL_DEPS=1
        shift
        ;;
      --x11)
        FORCE_PLATFORM="x11"
        shift
        ;;
      --wayland)
        FORCE_PLATFORM="wayland"
        shift
        ;;
      --browser)
        if [[ $# -lt 2 ]]; then
          err "--browser requiere un valor: auto|edge|chrome|chromium"
          exit 1
        fi
        FORCE_BROWSER="${2,,}"
        shift 2
        ;;
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Opción desconocida: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  detect_distro
  detect_session

  log "Distro detectada: id=$DISTRO_ID like=${DISTRO_LIKE:-n/a} family=$DISTRO_FAMILY"
  log "Sesión detectada: $SESSION_TYPE"

  if [[ "$DO_REVERT" -eq 1 ]]; then
    revert_last_run
    exit 0
  fi

  find_browser_binary
  configure_browser_metadata
  set_gpu_flags

  log "Navegador detectado: $BROWSER_CHANNEL ($BROWSER_FAMILY)"
  log "Binario: $BROWSER_BIN"
  log "Flags GPU: ${BROWSER_FLAGS[*]}"

  if [[ "$INSTALL_DEPS" -eq 1 ]]; then
    install_deps
  else
    log "Tip: usa --install-deps para instalar utilidades de diagnóstico."
  fi

  if ! confirm "¿Aplicar cambios seguros en tu HOME (~/.local)?"; then
    log "Cancelado por usuario."
    exit 0
  fi

  new_run_dir
  reset_browser_gpu_runtime_state
  write_wrapper
  write_desktop_entry
  write_standard_browser_overrides
  save_last_run
  show_next_steps
}

main "$@"
