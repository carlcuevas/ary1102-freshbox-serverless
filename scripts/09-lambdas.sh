#!/usr/bin/env bash
# Paso 9: empaqueta y despliega las 3 Lambdas (nodejs20.x, arm64) y conecta la cola SQS a Process-Order
source "$(dirname "$0")/lib.sh"
need_state LAB_ROLE_ARN SQS_URL SQS_ARN RDS_ENDPOINT APP_A APP_B SG_LAMBDA
have npm || die "npm no disponible"
BUILD="$ROOT_DIR/build"; rm -rf "$BUILD"; mkdir -p "$BUILD"
zipdir() { python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f); z.write(p, os.path.relpath(p, src))
PY
}
log "Empaquetando (Cart y Create-Order usan el SDK v3 incluido en el runtime; Process-Order lleva mysql2)"
cp -r "$ROOT_DIR/app/lambda/cart" "$BUILD/cart"; cp -r "$ROOT_DIR/app/lambda/create-order" "$BUILD/create-order"; cp -r "$ROOT_DIR/app/lambda/process-order" "$BUILD/process-order"
(cd "$BUILD/process-order" && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1) || die "npm install de process-order fallo"
for f in cart create-order process-order; do zipdir "$BUILD/$f" "$BUILD/$f.zip"; ok "$f.zip ($(du -h "$BUILD/$f.zip" | cut -f1))"; done

deploy() { # nombre zip timeout env-json [args extra]
  local name=$1 zip=$2 to=$3 envj=$4; shift 4
  if aws lambda get-function --function-name "$name" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$name" --zip-file "fileb://$zip" >/dev/null
    aws lambda wait function-updated --function-name "$name"
    aws lambda update-function-configuration --function-name "$name" --timeout "$to" --environment "$envj" "$@" >/dev/null
    aws lambda wait function-updated --function-name "$name"
  else
    aws lambda create-function --function-name "$name" --runtime nodejs20.x --architectures arm64 --handler index.handler \
      --role "$LAB_ROLE_ARN" --zip-file "fileb://$zip" --timeout "$to" --memory-size 256 --environment "$envj" \
      --tags Project=$PROJECT "$@" >/dev/null
    aws lambda wait function-active-v2 --function-name "$name"
  fi
  aws logs create-log-group --log-group-name "/aws/lambda/$name" >/dev/null 2>&1 || true
  aws logs put-retention-policy --log-group-name "/aws/lambda/$name" --retention-in-days 14 >/dev/null 2>&1 || true
  ok "$name"
}
log "Funciones"
deploy freshbox-cart "$BUILD/cart.zip" 10 "$(jq -nc '{Variables:{TABLE_NAME:"carrito-freshbox"}}')"
deploy freshbox-create-order "$BUILD/create-order.zip" 10 "$(jq -nc --arg q "$SQS_URL" '{Variables:{TABLE_NAME:"carrito-freshbox",QUEUE_URL:$q}}')"
deploy freshbox-process-order "$BUILD/process-order.zip" 30 \
  "$(jq -nc --arg h "$RDS_ENDPOINT" --arg u "$APP_DB_USER" --arg p "$APP_DB_PASS" --arg d "$DB_NAME" '{Variables:{TABLE_NAME:"carrito-freshbox",DB_HOST:$h,DB_USER:$u,DB_PASS:$p,DB_NAME:$d,DB_PORT:"3306"}}')" \
  --vpc-config "SubnetIds=$APP_A,$APP_B,SecurityGroupIds=$SG_LAMBDA"
save_state CART_ARN "$(aws lambda get-function --function-name freshbox-cart --query Configuration.FunctionArn --output text)"
save_state ORDER_ARN "$(aws lambda get-function --function-name freshbox-create-order --query Configuration.FunctionArn --output text)"

log "Trigger SQS -> Process-Order (lote 5, fallos parciales, concurrencia maxima 5 para cuidar las conexiones a MySQL)"
UUID=$(aws lambda list-event-source-mappings --function-name freshbox-process-order --query 'EventSourceMappings[0].UUID' --output text)
if [ "$UUID" = None ] || [ -z "$UUID" ]; then
  aws lambda create-event-source-mapping --function-name freshbox-process-order --event-source-arn "$SQS_ARN" \
    --batch-size 5 --maximum-batching-window-in-seconds 0 --function-response-types ReportBatchItemFailures \
    --scaling-config MaximumConcurrency=5 >/dev/null
fi
ok "Trigger SQS configurado"
