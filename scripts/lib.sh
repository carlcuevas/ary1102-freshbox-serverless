#!/usr/bin/env bash
# Utilidades comunes. Uso: source "$(dirname "$0")/lib.sh"
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/bin:$PATH"
# shellcheck disable=SC1091
set -a; source "$ROOT_DIR/config.env"; set +a
STATE_FILE="$ROOT_DIR/state.env"
SECRETS_FILE="$ROOT_DIR/.secrets.env"
touch "$STATE_FILE" "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
# shellcheck disable=SC1090
set -a; source "$STATE_FILE"; source "$SECRETS_FILE"; set +a
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  \033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m[!!]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[xx]\033[0m %s\n' "$*"; }
die()  { fail "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# save_state CLAVE VALOR -> persiste en state.env y exporta
save_state() {
  local k="$1" v="$2"
  sed -i "/^${k}=/d" "$STATE_FILE"
  echo "${k}=\"${v}\"" >> "$STATE_FILE"
  export "${k}=${v}"
}
save_secret() {
  local k="$1" v="$2"
  sed -i "/^${k}=/d" "$SECRETS_FILE"
  echo "${k}=\"${v}\"" >> "$SECRETS_FILE"
  export "${k}=${v}"
}
gen_pass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20; }

# tags TIPO NOMBRE -> --tag-specifications
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT}]"; }

# allow SG "ip-permission" (ignora duplicados al re-ejecutar)
allow() { aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "$2" >/dev/null 2>&1 || true; }

# render ARCHIVO -> sustituye solo las variables indicadas en RENDER_VARS
render() { envsubst "${RENDER_VARS:-\${NAMESPACE}}" < "$1"; }

need_state() { for v in "$@"; do [ -n "${!v:-}" ] || die "Falta $v en state.env (corre antes el script anterior)"; done; }
