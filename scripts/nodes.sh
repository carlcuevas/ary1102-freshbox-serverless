#!/usr/bin/env bash
# Ahorro de presupuesto del lab: ./nodes.sh pause  (nodos a 0)  |  ./nodes.sh resume  (vuelve a min/desired de config.env)
source "$(dirname "$0")/lib.sh"
case "${1:-}" in
  pause)  aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --scaling-config minSize=0,maxSize=$NODE_MAX,desiredSize=0 >/dev/null; ok "nodos -> 0 (siguen cobrando: plano de control EKS, NAT, ALB y RDS)";;
  resume) aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" --scaling-config minSize=$NODE_MIN,maxSize=$NODE_MAX,desiredSize=$NODE_DESIRED >/dev/null; ok "nodos -> $NODE_DESIRED (espera ~3 min: kubectl get nodes)";;
  *) echo "uso: $0 pause|resume"; exit 1;;
esac
