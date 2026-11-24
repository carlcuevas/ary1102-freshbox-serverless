#!/usr/bin/env bash
# Pruebas de rendimiento (IE4.3.2): HPA de get-products, concurrencia de Lambda y cold start vs warm
source "$(dirname "$0")/lib.sh"
need_state API_URL
log "1) Carga sobre get-products (6 generadores x 240 s) y seguimiento del HPA"
kubectl -n $NAMESPACE delete pod load-gen --ignore-not-found >/dev/null
kubectl -n $NAMESPACE run load-gen --image=busybox:1.36 --restart=Never -- /bin/sh -c 'for i in 1 2 3 4 5 6; do (while true; do wget -q -O- http://get-products:3001/api/products >/dev/null; done) & done; sleep 240'
for i in $(seq 1 9); do sleep 30; echo "--- t=$((i*30))s"; kubectl -n $NAMESPACE get hpa get-products-hpa --no-headers; done
kubectl -n $NAMESPACE delete pod load-gen --ignore-not-found >/dev/null
kubectl -n $NAMESPACE get pods -l app=get-products

log "2) Cold start de Lambda Cart (se fuerza un entorno nuevo cambiando una variable)"
ENVJ=$(aws lambda get-function-configuration --function-name freshbox-cart --query Environment --output json | jq -c '{Variables: (.Variables + {COLD: (now|tostring)})}')
aws lambda update-function-configuration --function-name freshbox-cart --environment "$ENVJ" >/dev/null; aws lambda wait function-updated --function-name freshbox-cart
for n in 1 2 3; do echo "  llamada $n: $(curl -s -o /dev/null -w '%{time_total}s' "$API_URL/api/cart?userId=loadtest1")"; done

log "3) Concurrencia: 60 solicitudes con 30 en paralelo a /api/cart"
seq 60 | xargs -P30 -I{} curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "$API_URL/api/cart?userId=loadtest1" | sort | uniq -c | sort -rn | head -5
sleep 20
log "Evidencia en CloudWatch Logs (Init Duration = cold start)"
aws logs filter-log-events --log-group-name /aws/lambda/freshbox-cart --filter-pattern '"Init Duration"' --max-items 3 --query 'events[].message' --output text | tr -d '\t' | head -6
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name ConcurrentExecutions --dimensions Name=FunctionName,Value=freshbox-cart \
  --start-time "$(date -u -d '-10 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Maximum]' --output text
