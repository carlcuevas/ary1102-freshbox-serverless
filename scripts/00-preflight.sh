#!/usr/bin/env bash
# Paso 0: verifica herramientas y cuenta. Instala kubectl/helm en ~/bin si faltan.
source "$(dirname "$0")/lib.sh"
mkdir -p "$HOME/bin"
ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; *) die "Arquitectura $ARCH no soportada";; esac

log "Herramientas"
for t in aws jq openssl curl; do have $t && ok "$t" || die "Falta $t"; done
if ! have envsubst; then warn "Falta envsubst: sudo dnf install -y gettext (o apt install gettext-base)"; die "envsubst requerido"; fi
ok envsubst
if ! have kubectl; then
  log "Instalando kubectl en ~/bin"
  V=$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_VERSION}.txt")
  curl -fsSL -o "$HOME/bin/kubectl" "https://dl.k8s.io/release/${V}/bin/linux/${A}/kubectl"; chmod +x "$HOME/bin/kubectl"
fi
ok "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"
if ! have helm; then
  log "Instalando helm en ~/bin"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | USE_SUDO=false HELM_INSTALL_DIR="$HOME/bin" bash
fi
ok "helm $(helm version --short)"
have docker && ok "docker (necesario desde el paso de imagenes)" || warn "docker no encontrado (se usa en el paso de imagenes EP3)"

log "Cuenta AWS"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || die "Sin credenciales: abre el Learner Lab y renueva las credenciales"
save_state ACCOUNT_ID "$ACCOUNT_ID"; ok "Cuenta $ACCOUNT_ID, region $REGION"
LAB_ROLE_ARN=$(aws iam get-role --role-name LabRole --query Role.Arn --output text) || die "No existe/no se puede leer LabRole"
save_state LAB_ROLE_ARN "$LAB_ROLE_ARN"; ok "LabRole: $LAB_ROLE_ARN"
N=$(aws ec2 describe-availability-zones --filters Name=state,Values=available --query 'length(AvailabilityZones)' --output text)
[ "$N" -ge 2 ] && ok "$N zonas de disponibilidad" || die "Se requieren 2 AZ"
log "Preflight OK"
