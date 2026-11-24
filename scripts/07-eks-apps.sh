#!/usr/bin/env bash
# Paso 7: 4 Deployments + Services + HPA y un Ingress (ALB) que despacha por metodo HTTP. Sin pod frontend.
source "$(dirname "$0")/lib.sh"
need_state ECR_URI RDS_ENDPOINT PUB_A PUB_B SG_ALB
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create configmap app-config --from-literal=DB_HOST="$RDS_ENDPOINT" --from-literal=DB_NAME="$DB_NAME" --from-literal=DB_PORT=3306 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create secret generic app-db --from-literal=DB_USER="$APP_DB_USER" --from-literal=DB_PASS="$APP_DB_PASS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "ConfigMap app-config y Secret app-db (usuario sin DROP)"
for p in get-products:3001 create-product:3002 update-product:3003 delete-product:3004; do
  SVC=${p%%:*} PORT=${p##*:} RENDER_VARS='${SVC} ${PORT} ${NAMESPACE} ${ECR_URI}' render "$ROOT_DIR/k8s/10-service.tpl.yaml" | kubectl apply -f - >/dev/null
  ok "$p"
done
RENDER_VARS='${NAMESPACE} ${PUB_A} ${PUB_B} ${SG_ALB}' render "$ROOT_DIR/k8s/20-ingress.yaml" | kubectl apply -f - >/dev/null
for s in get-products create-product update-product delete-product; do kubectl -n "$NAMESPACE" rollout status deploy/$s --timeout=240s; done
log "Esperando el ALB (2-4 min)"
for i in $(seq 1 40); do
  H=$(kubectl -n "$NAMESPACE" get ingress freshbox-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$H" ] && break; sleep 10
done
[ -n "${H:-}" ] || { kubectl -n "$NAMESPACE" describe ingress freshbox-ingress | tail -15; die "El ALB no aparecio (revisa los eventos del Ingress)"; }
save_state ALB_DNS "$H"; ok "ALB $ALB_DNS"
log "Esperando targets healthy"
for i in $(seq 1 30); do
  LB=$(aws elbv2 describe-load-balancers --names freshbox-eks-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
  BAD=0; N=0
  if [ -n "$LB" ] && [ "$LB" != None ]; then
    for tg in $(aws elbv2 describe-target-groups --load-balancer-arn "$LB" --query 'TargetGroups[].TargetGroupArn' --output text); do
      N=$((N+1)); BAD=$((BAD + $(aws elbv2 describe-target-health --target-group-arn "$tg" --query "length(TargetHealthDescriptions[?TargetHealth.State!='healthy'])" --output text)))
    done
  fi
  [ "$N" -ge 4 ] && [ "$BAD" -eq 0 ] && break; sleep 10
done
echo "  target groups: $N, no healthy: $BAD"
for m in GET; do echo "  $m /api/products -> $(curl -s -o /dev/null -w '%{http_code}' "http://$ALB_DNS/api/products")"; done
echo "  POST sin cuerpo (debe llegar a create-product: 400) -> $(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "http://$ALB_DNS/api/products")"
kubectl -n "$NAMESPACE" get pods,hpa
