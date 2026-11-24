#!/usr/bin/env bash
# FreshBox EP3 - punto de entrada unico.
#   ./up.sh            Despliega TODO desde cero (scripts 00 a 12) y termina con verify.sh. Reanuda donde quedo si se corta.
#   ./up.sh resume     Despierta un laboratorio ya desplegado (nodos, trigger SQS, targets del ALB) y verifica. ~5 min.
#   ./up.sh verify     Solo corre las 35 comprobaciones.
#   ./up.sh pause      Baja los nodos a 0 para ahorrar presupuesto.
#   ./up.sh status     Muestra nodos, pods, HPA y trigger SQS.
# Variables opcionales: ALARM_EMAIL=correo@dominio.cl  FORCE=1 (repite pasos ya hechos)  DRY_RUN=1 (solo lista los pasos)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
export PATH="$HOME/bin:$PATH"
mkdir -p logs
c() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
okm() { printf '  \033[1;32m[ok]\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m[xx]\033[0m %s\n' "$*"; }

STEPS=(00-preflight 01-network 02-rds 03-eks 04-addons 05-db-init 06-images 07-eks-apps 08-data 09-lambdas 10-apigw 11-frontend 12-monitoring)

cfg() { # carga config.env y state.env
  set -a; source config.env; [ -f state.env ] && source state.env; set +a
  export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
}

full() {
  local t0=$SECONDS
  c "Despliegue completo: ${#STEPS[@]} pasos (aprox. 45-60 min la primera vez)"
  for s in "${STEPS[@]}"; do
    if [ "${DRY_RUN:-0}" = 1 ]; then echo "  - scripts/$s.sh"; continue; fi
    if [ -f "logs/.ok-$s" ] && [ "${FORCE:-0}" != 1 ]; then okm "$s ya estaba listo (FORCE=1 para repetir)"; continue; fi
    c "Paso $s"
    local t1=$SECONDS
    if bash "scripts/$s.sh" 2>&1 | tee "logs/${s%%-*}.log"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
      touch "logs/.ok-$s"; okm "$s listo en $((SECONDS - t1)) s"
    else
      bad "Fallo $s. Revisa logs/${s%%-*}.log y vuelve a correr ./up.sh (continua desde este paso)."; exit 1
    fi
  done
  [ "${DRY_RUN:-0}" = 1 ] && exit 0
  verify
  cfg; c "Listo en $(( (SECONDS - t0) / 60 )) min. Sitio: ${SITE_URL:-ver logs/11.log}"
}

verify() { c "Verificacion end-to-end"; bash scripts/verify.sh 2>&1 | tee logs/verify.log; }

resume() {
  cfg
  c "Despertando el laboratorio"
  aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 || { bad "Sin credenciales AWS: inicia el lab (Start Lab) y abre CloudShell."; exit 1; }
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null && okm "kubeconfig"
  bash scripts/nodes.sh resume
  c "Esperando nodos Ready (hasta 10 min)"
  for i in $(seq 1 60); do
    n=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
    [ "${n:-0}" -ge "${NODE_DESIRED:-2}" ] && break; sleep 10
  done
  kubectl get nodes --no-headers 2>/dev/null | sed 's/^/    /'
  c "Habilitando el trigger SQS -> Process-Order"
  UUID=$(aws lambda list-event-source-mappings --function-name freshbox-process-order --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null)
  if [ -n "$UUID" ] && [ "$UUID" != None ]; then aws lambda update-event-source-mapping --uuid "$UUID" --enabled >/dev/null && okm "trigger habilitado"; else bad "No encontre el trigger (corre ./up.sh para crearlo)"; fi
  c "Esperando pods y targets del ALB (puede tardar ~2 min)"
  for i in 1 2 3 4; do
    if bash scripts/verify.sh > logs/verify.log 2>&1; then okm "TODO OK"; tail -n 4 logs/verify.log; return 0; fi
    echo "    aun no esta todo sano (intento $i/4); espero 60 s..."; sleep 60
  done
  bad "Quedaron comprobaciones fallidas:"; grep -a "xx" logs/verify.log | sed 's/^/    /'; exit 1
}

status() {
  cfg
  kubectl get nodes 2>&1 | sed 's/^/  /'; kubectl -n "$NAMESPACE" get pods,hpa 2>&1 | sed 's/^/  /'
  aws lambda list-event-source-mappings --function-name freshbox-process-order --query 'EventSourceMappings[0].State' --output text 2>&1 | sed 's/^/  trigger SQS: /'
}

case "${1:-full}" in
  full|up) full ;;
  resume)  resume ;;
  verify)  cfg; verify ;;
  pause)   cfg; bash scripts/nodes.sh pause ;;
  status)  status ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
