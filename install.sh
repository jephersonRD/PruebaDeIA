#!/usr/bin/env bash
# =============================================================================
#  Instalador de opencode para Termux
#  Build nativo bionic (aarch64) publicado por Hope2333/opencode-termux.
#
#  Uso:
#    bash install.sh              # instala o actualiza
#    bash install.sh --dry-run    # muestra versión, URL y SHA-256
#    bash install.sh --force      # reinstala la misma versión
#    bash install.sh --help
#
#  Repo: https://github.com/jephersonRD/PruebaDeIA
# =============================================================================
set -euo pipefail

OC_REPO="Hope2333/opencode-termux"
OC_LATEST="https://api.github.com/repos/${OC_REPO}/releases/latest"
OC_LIST="https://api.github.com/repos/${OC_REPO}/releases?per_page=10"
OC_FALLBACK="https://github.com/${OC_REPO}/releases/download/Push261005/opencode_2.0.22_aarch64.deb"
OC_MIN_MB=400

DRY_RUN=false
FORCE=false

if [[ -t 1 ]]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'
  Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; D=""; R=""; G=""; Y=""; C=""; N=""
fi

info() { printf '  %s→%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '\n  %s✘ %s%s\n\n' "$R" "$*" "$N" >&2; exit 1; }

usage() {
  cat <<'EOF'
Instalador de opencode para Termux (build nativo bionic, aarch64).

Uso:
  bash install.sh [opciones]

Opciones:
  -n, --dry-run   Muestra versión, URL y SHA-256 sin instalar
  -f, --force     Reinstala aunque ya esté la misma versión
  -h, --help      Muestra esta ayuda

Variables:
  GITHUB_TOKEN    Token opcional para evitar el límite de la API de GitHub

El script descarga el .deb desde Hope2333/opencode-termux y lo instala con apt.
No modifica la configuración de opencode ni instala nada más.
EOF
}

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=true ;;
    -f|--force) FORCE=true ;;
    *) die "Opción desconocida: $1 (usa --help)" ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
#  Comprobaciones del entorno
# -----------------------------------------------------------------------------
[[ -n "${PREFIX:-}" && "$PREFIX" == *com.termux* ]] \
  || die "Este script debe ejecutarse dentro de Termux."
command -v pkg >/dev/null 2>&1 \
  || die "No se encontró 'pkg'. ¿Estás en Termux?"

arch="$(uname -m)"
[[ "$arch" == "aarch64" || "$arch" == "arm64" ]] \
  || die "opencode solo tiene build nativo para aarch64/arm64 (detectado: $arch)."

if ! command -v curl >/dev/null 2>&1; then
  info "Instalando curl..."
  pkg install -y curl >/dev/null 2>&1 || die "No se pudo instalar curl."
fi

api_headers=(-H "Accept: application/vnd.github+json")
[[ -n "${GITHUB_TOKEN:-}" ]] && api_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

OC_VERSION=""
OC_URL=""

# Elige el .deb aarch64 más nuevo dentro de un JSON de la API de GitHub.
pick_deb() {  # <json>
  local json="$1" names deb url
  names=$(printf '%s' "$json" \
    | grep -oE 'opencode_[0-9]+\.[0-9]+\.[0-9]+_aarch64\.deb' \
    | sort -uV || true)
  deb=$(printf '%s\n' "$names" | sed '/^$/d' | tail -n1 || true)
  [[ -n "$deb" ]] || return 1

  url=$(printf '%s' "$json" \
    | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"(https:[^"]+)"/\1/' \
    | grep -F "/${deb}" | head -n1 || true)
  [[ -n "$url" ]] || return 1

  OC_VERSION="${deb#opencode_}"
  OC_VERSION="${OC_VERSION%_aarch64.deb}"
  OC_URL="$url"
}

resolve_deb() {
  local json
  json=$(curl -fsSL -m 30 "${api_headers[@]}" "$OC_LATEST" 2>/dev/null || true)
  pick_deb "$json" && return 0

  json=$(curl -fsSL -m 30 "${api_headers[@]}" "$OC_LIST" 2>/dev/null || true)
  pick_deb "$json" && return 0

  # Último recurso: URL fija de una versión conocida.
  OC_VERSION="${OC_FALLBACK##*/opencode_}"
  OC_VERSION="${OC_VERSION%_aarch64.deb}"
  OC_URL="$OC_FALLBACK"
}

# semver_gt A B → verdadero si A > B (comparación numérica por segmentos)
semver_gt() {
  local a="${1#v}" b="${2#v}"
  local -a A B
  IFS='.' read -r -a A <<< "$a"
  IFS='.' read -r -a B <<< "$b"
  local i x y
  for i in 0 1 2; do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    x="${x:-0}"; y="${y:-0}"
    (( 10#$x > 10#$y )) && return 0
    (( 10#$x < 10#$y )) && return 1
  done
  return 1
}

# -----------------------------------------------------------------------------
#  Versión instalada y resolución de la última disponible
# -----------------------------------------------------------------------------
current=""
if command -v opencode >/dev/null 2>&1; then
  current=$(opencode --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
fi

info "Buscando la última versión de opencode..."
resolve_deb
[[ -n "$OC_URL" ]] || die "No se pudo resolver el .deb de opencode."

if [[ -n "$current" ]]; then
  info "Instalada: v$current · Disponible: v$OC_VERSION"
else
  info "Disponible: v$OC_VERSION"
fi

free_mb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || true)
free_mb=${free_mb:-0}
[[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=0

sums_url="${OC_URL%/*}/SHA256SUMS.txt"

# -----------------------------------------------------------------------------
#  Modo simulación: no descarga el .deb
# -----------------------------------------------------------------------------
if $DRY_RUN; then
  expected=""
  expected=$(curl -fsSL -m 30 "$sums_url" 2>/dev/null \
    | awk -v n="${OC_URL##*/}" '{f=$2; sub(/^\*/,"",f); if (f==n) {print $1; exit}}' || true)

  printf '\n%s  opencode — simulación%s\n' "$B" "$N"
  printf '  Versión instalada : %s\n' "${current:-ninguna}"
  printf '  Versión disponible: %s\n' "$OC_VERSION"
  printf '  Descarga          : %s\n' "$OC_URL"
  printf '  Espacio libre     : %s MB\n' "$free_mb"
  printf '  SHA-256 esperado  : %s\n\n' "${expected:-no disponible}"
  exit 0
fi

# -----------------------------------------------------------------------------
#  Nada que hacer si ya está igual o más nuevo
# -----------------------------------------------------------------------------
if [[ -n "$current" ]] && ! $FORCE && ! semver_gt "$OC_VERSION" "$current"; then
  ok "opencode ya está instalado (v$current). Usa --force para reinstalarlo."
  exit 0
fi

if (( free_mb > 0 && free_mb < OC_MIN_MB )); then
  warn "Solo quedan ${free_mb} MB libres; se recomiendan ~${OC_MIN_MB} MB."
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/opencode.deb"

# -----------------------------------------------------------------------------
#  Descarga + verificación SHA-256
# -----------------------------------------------------------------------------
info "Descargando opencode v$OC_VERSION..."
curl_opts=(-fL --retry 3 --connect-timeout 15)
if [[ -t 2 ]]; then
  curl_opts+=(--progress-bar)
else
  curl_opts+=(-sS)
fi
curl "${curl_opts[@]}" -o "$deb" "$OC_URL" \
  || die "No se pudo descargar el .deb."

if curl -fsSL -m 30 "$sums_url" -o "$tmp/SHA256SUMS.txt" 2>/dev/null; then
  expected=$(awk -v n="${OC_URL##*/}" \
    '{f=$2; sub(/^\*/,"",f); if (f==n) {print $1; exit}}' "$tmp/SHA256SUMS.txt")
  if [[ -n "$expected" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual=$(sha256sum "$deb" | awk '{print $1}')
      [[ "$actual" == "$expected" ]] \
        || die "El SHA-256 no coincide. Se aborta por seguridad."
      ok "SHA-256 verificado."
    else
      warn "sha256sum no está disponible; se omite la verificación."
    fi
  else
    warn "No se encontró el checksum de ${OC_URL##*/}; se continúa sin verificar."
  fi
else
  warn "No se pudo descargar SHA256SUMS.txt; se continúa sin verificar."
fi

# -----------------------------------------------------------------------------
#  Instalación
# -----------------------------------------------------------------------------
info "Instalando opencode..."
if command -v apt >/dev/null 2>&1; then
  if ! DEBIAN_FRONTEND=noninteractive apt install -y "$deb"; then
    warn "apt falló; intentando con dpkg..."
    dpkg -i "$deb" || true
    DEBIAN_FRONTEND=noninteractive apt install -f -y \
      || die "No se pudo instalar opencode."
  fi
else
  pkg install -y "$deb" || die "No se pudo instalar opencode."
fi

new=""
if command -v opencode >/dev/null 2>&1; then
  new=$(opencode --version 2>/dev/null | head -n1 || true)
fi
[[ -n "$new" ]] || die "La instalación terminó pero 'opencode' no responde."

ok "opencode instalado: $new"
printf '\n  %sPrimeros pasos%s\n' "$B" "$N"
printf '    opencode             # abre la TUI\n'
printf '    opencode models      # modelos disponibles\n'
printf '    opencode auth login  # API key de otro proveedor\n'
printf '\n  Documentación: https://github.com/jephersonRD/PruebaDeIA\n\n'
