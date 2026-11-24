#!/usr/bin/env bash
# Verificacion integral EP3 (infraestructura + flujo end-to-end). Termina en TODO OK o con errores.
source "$(dirname "$0")/lib.sh"
set +e; ERR=0
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; ERR=$((ERR+1)); fi; }
code() { curl -s -o /tmp/vb.json -w '%{http_code}' "$@"; }
J='-H Content-Type:application/json'

log "Contenedores (EKS)"
for s in get-products create-product update-product delete-product; do
  t "deployment $s disponible" test "$(kubectl -n $NAMESPACE get deploy $s -o jsonpath='{.status.availableReplicas}')" -ge 1
  t "hpa $s-hpa" kubectl -n $NAMESPACE get hpa $s-hpa
done
t "sin pod frontend (el sitio vive en S3)" test -z "$(kubectl -n $NAMESPACE get deploy -o name | grep frontend)"
LB=$(aws elbv2 describe-load-balancers --names freshbox-eks-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
BAD=0; for tg in $(aws elbv2 describe-target-groups --load-balancer-arn "$LB" --query 'TargetGroups[].TargetGroupArn' --output text); do BAD=$((BAD+$(aws elbv2 describe-target-health --target-group-arn $tg --query "length(TargetHealthDescriptions[?TargetHealth.State!='healthy'])" --output text))); done
t "targets del ALB healthy" test "$BAD" = 0

log "Serverless"
t "DynamoDB TTL habilitado" test "$(aws dynamodb describe-time-to-live --table-name carrito-freshbox --query TimeToLiveDescription.TimeToLiveStatus --output text)" = ENABLED
t "VPC Endpoint DynamoDB disponible" test "$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $VPCE_ID --query 'VpcEndpoints[0].State' --output text)" = available
t "SQS + DLQ" test "$(aws sqs get-queue-attributes --queue-url $SQS_URL --attribute-names RedrivePolicy --query Attributes.RedrivePolicy --output text)" != None
for f in freshbox-cart freshbox-create-order freshbox-process-order; do
  t "$f Active ($(aws lambda get-function-configuration --function-name $f --query Runtime --output text))" test "$(aws lambda get-function-configuration --function-name $f --query State --output text)" = Active
done
t "Process-Order dentro de la VPC (subredes app)" test "$(aws lambda get-function-configuration --function-name freshbox-process-order --query VpcConfig.VpcId --output text)" = "$VPC_ID"
t "trigger SQS habilitado" test "$(aws lambda list-event-source-mappings --function-name freshbox-process-order --query 'EventSourceMappings[0].State' --output text)" = Enabled
t "API Gateway stage prod" aws apigateway get-stage --rest-api-id $API_ID --stage-name prod
t "S3 sitio estatico responde 200" test "$(code $SITE_URL)" = 200

log "CRUD de productos (API GW -> ALB -> EKS -> MySQL)"
t "GET /api/products = 200" test "$(code $API_URL/api/products)" = 200
t "POST /api/products = 201" test "$(code -X POST $J -d '{"nombre":"Verify tmp","descripcion":"x","precio":1000,"stock":5,"categoria":"Test"}' $API_URL/api/products)" = 201
PID=$(jq -r .id /tmp/vb.json)
t "PUT /api/products/$PID = 200" test "$(code -X PUT $J -d '{"nombre":"Verify tmp 2","descripcion":"x","precio":1200,"stock":4,"categoria":"Test"}' $API_URL/api/products/$PID)" = 200
t "DELETE /api/products/$PID = 200" test "$(code -X DELETE $API_URL/api/products/$PID)" = 200
t "DELETE repetido = 404" test "$(code -X DELETE $API_URL/api/products/$PID)" = 404

log "Carrito y ordenes (Lambda -> DynamoDB -> SQS -> Lambda -> MySQL)"
U="verify-$RANDOM"
t "carrito: dato invalido = 400" test "$(code -X POST $J -d '{"userId":"'$U'"}' $API_URL/api/cart)" = 400
t "orden con carrito vacio = 400" test "$(code -X POST $J -d '{"userId":"'$U'"}' $API_URL/api/orders)" = 400
for i in 1 2; do code -X POST $J -d '{"userId":"'$U'","productId":"1","nombre":"Manzana","precio":3490,"cantidad":1}' $API_URL/api/cart >/dev/null; done
code -X POST $J -d '{"userId":"'$U'","productId":"2","nombre":"Lechuga","precio":1990,"cantidad":1}' $API_URL/api/cart >/dev/null
t "carrito acumula cantidades y calcula total (8970)" test "$(code "$API_URL/api/cart?userId=$U")" = 200 -a "$(jq -r .total /tmp/vb.json)" = 8970
t "DELETE /api/cart/2 = 200" test "$(code -X DELETE "$API_URL/api/cart/2?userId=$U")" = 200
t "POST /api/orders = 200 (recibido)" test "$(code -X POST $J -d '{"userId":"'$U'"}' $API_URL/api/orders)" = 200
OID=$(jq -r .orderId /tmp/vb.json); echo "  orden: $OID total=$(jq -r .total /tmp/vb.json)"
EST=pendiente; for i in $(seq 1 20); do sleep 2; code $API_URL/api/orders/$OID >/dev/null; EST=$(jq -r .estado /tmp/vb.json); [ "$EST" = procesado ] && break; done
t "orden procesada de forma asincrona (estado=$EST)" test "$EST" = procesado
t "mensaje al cliente 'Su pedido fue procesado'" test "$(jq -r .mensaje /tmp/vb.json)" = "Su pedido fue procesado"
t "carrito vaciado tras procesar" test "$(code "$API_URL/api/cart?userId=$U")" = 200 -a "$(jq -r .cantidadItems /tmp/vb.json)" = 0
N=$(kubectl -n $NAMESPACE run mysqlq-$RANDOM --rm -i --restart=Never --quiet --image=mysql:8.0 --env="MYSQL_PWD=$APP_DB_PASS" --command -- mysql -h $RDS_ENDPOINT -u $APP_DB_USER -N -e "SELECT COUNT(*) FROM freshbox.ordenes WHERE order_id='$OID' AND estado='procesado'" 2>/dev/null | tail -1)
t "orden registrada en RDS MySQL (1 fila)" test "$N" = 1
t "DLQ vacia" test "$(aws sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text)" = 0
echo; [ $ERR -eq 0 ] && printf '\033[1;32mTODO OK\033[0m\n' || { printf '\033[1;31m%s verificaciones fallaron\033[0m\n' "$ERR"; exit 1; }
