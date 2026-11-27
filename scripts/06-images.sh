#!/usr/bin/env bash
# Paso 6: construye las 4 imagenes (linux/arm64, Node 20) y las sube a ECR con escaneo al subir
source "$(dirname "$0")/lib.sh"
need_state ACCOUNT_ID
have docker || die "Docker no disponible en CloudShell"
docker info >/dev/null 2>&1 || die "El demonio de Docker no responde (reabre CloudShell)"
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"; save_state ECR_URI "$ECR_URI"
aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_URI" >/dev/null 2>&1 || die "Login a ECR fallo"
ok "Login ECR"
have npm || die "npm no disponible (se usa para instalar las dependencias antes de construir)"
# Imagen base: espejo oficial en ECR Public (sin limite de pulls de Docker Hub); si no responde, Docker Hub
BASE=public.ecr.aws/docker/library/node:20-alpine
docker pull --platform linux/arm64 "$BASE" >/dev/null 2>&1 || { warn "ECR Public no respondio; uso Docker Hub"; BASE=node:20-alpine; }
ok "Imagen base $BASE"
STAGE="$ROOT_DIR/build/img"; rm -rf "$STAGE"; mkdir -p "$STAGE"
for svc in get-products create-product update-product delete-product; do
  log "freshbox-$svc"
  aws ecr describe-repositories --repository-names "freshbox-$svc" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "freshbox-$svc" --image-scanning-configuration scanOnPush=true --encryption-configuration encryptionType=AES256 >/dev/null
  # Dependencias de JavaScript puro: se instalan aqui y el Dockerfile solo las copia (no ejecuta nada arm64 durante el build)
  cp -r "$ROOT_DIR/app/microservicios/$svc" "$STAGE/$svc"
  (cd "$STAGE/$svc" && npm ci --omit=dev --no-audit --no-fund >/dev/null 2>&1) || die "npm ci de $svc fallo"
  docker build --platform linux/arm64 --build-arg BASE="$BASE" -t "$ECR_URI/freshbox-$svc:latest" "$STAGE/$svc" >"$STAGE/$svc.build.log" 2>&1 || { tail -15 "$STAGE/$svc.build.log"; die "docker build de $svc fallo"; }
  docker push "$ECR_URI/freshbox-$svc:latest" >"$STAGE/$svc.push.log" 2>&1 || { tail -15 "$STAGE/$svc.push.log"; die "docker push de $svc fallo"; }
  ok "$svc publicado"
done
log "Imagenes listas"; aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
