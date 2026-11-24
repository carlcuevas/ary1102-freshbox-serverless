#!/usr/bin/env bash
# Paso 5: espera RDS, guarda el endpoint y carga productos + ordenes + usuario de app mediante un Job en el cluster
source "$(dirname "$0")/lib.sh"
log "Esperando RDS disponible (Multi-AZ puede tardar hasta ~20 min en total)"
aws rds wait db-instance-available --db-instance-identifier "$RDS_ID"
save_state RDS_ENDPOINT "$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].Endpoint.Address' --output text)"
ok "Endpoint: $RDS_ENDPOINT"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create secret generic db-bootstrap \
  --from-literal=DB_HOST="$RDS_ENDPOINT" --from-literal=DB_NAME="$DB_NAME" \
  --from-literal=ADMIN_USER="$DB_ADMIN_USER" --from-literal=ADMIN_PASS="$DB_ADMIN_PASS" \
  --from-literal=APP_USER="$APP_DB_USER" --from-literal=APP_PASS="$APP_DB_PASS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create configmap db-sql --from-file="$ROOT_DIR/sql/" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" delete job db-init --ignore-not-found >/dev/null
RENDER_VARS='${NAMESPACE}' render "$ROOT_DIR/k8s/00-db-init-job.yaml" | kubectl apply -f -
kubectl -n "$NAMESPACE" wait --for=condition=complete job/db-init --timeout=300s || { kubectl -n "$NAMESPACE" logs job/db-init --tail=50; die "El Job db-init fallo"; }
kubectl -n "$NAMESPACE" logs job/db-init
log "Base de datos lista (productos + ordenes + usuario $APP_DB_USER)"
