#!/usr/bin/env bash
# Paso 6: construye las 4 imagenes (linux/arm64, Node 20) y las sube a ECR con escaneo al subir
source "$(dirname "$0")/lib.sh"
need_state ACCOUNT_ID
have docker || die "Docker no disponible en CloudShell"
docker info >/dev/null 2>&1 || die "El demonio de Docker no responde (reabre CloudShell)"
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"; save_state ECR_URI "$ECR_URI"
aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_URI" >/dev/null 2>&1 || die "Login a ECR fallo"
ok "Login ECR"
log "Emulacion arm64 (CloudShell es x86)"
docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 || warn "No pude instalar binfmt; si el build falla con 'exec format error' avisame"
for svc in get-products create-product update-product delete-product; do
  log "freshbox-$svc"
  aws ecr describe-repositories --repository-names "freshbox-$svc" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "freshbox-$svc" --image-scanning-configuration scanOnPush=true --encryption-configuration encryptionType=AES256 >/dev/null
  docker build --platform linux/arm64 -t "$ECR_URI/freshbox-$svc:latest" "$ROOT_DIR/app/microservicios/$svc" 2>&1 | tail -2
  docker push "$ECR_URI/freshbox-$svc:latest" 2>&1 | tail -1
  ok "$svc publicado"
done
log "Imagenes listas"; aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
