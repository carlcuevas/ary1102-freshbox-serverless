#!/usr/bin/env bash
# Paso 4: metrics-server y CloudWatch Observability (add-ons), AWS Load Balancer Controller y Cluster Autoscaler (Helm)
source "$(dirname "$0")/lib.sh"
need_state VPC_ID

addon() {
  aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$1" >/dev/null 2>&1 || \
    aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name "$1" --resolve-conflicts OVERWRITE >/dev/null
  aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name "$1"; ok "add-on $1"
}
log "Add-ons gestionados"
addon metrics-server
addon amazon-cloudwatch-observability

log "AWS Load Balancer Controller (credenciales via rol del nodo = LabRole)"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName="$CLUSTER_NAME" --set region="$REGION" --set vpcId="$VPC_ID" --set replicaCount=1 >/dev/null
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=240s

log "Cluster Autoscaler"
CA_ARGS=()
if [ -n "${CA_IMAGE_TAG:-}" ]; then CA_ARGS+=(--set "image.tag=${CA_IMAGE_TAG}"); fi
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" --set awsRegion="$REGION" "${CA_ARGS[@]}" >/dev/null
kubectl -n kube-system rollout status deploy/cluster-autoscaler-aws-cluster-autoscaler --timeout=240s || warn "Revisa: kubectl -n kube-system get deploy | grep autoscaler"
log "Add-ons listos"
