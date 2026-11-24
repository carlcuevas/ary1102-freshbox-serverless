#!/usr/bin/env bash
# Paso 3: cluster EKS + Managed Node Group t4g.small (Graviton) con EBS cifrado. Usa LabRole.
source "$(dirname "$0")/lib.sh"
need_state APP_A APP_B PUB_A PUB_B SG_EKS LAB_ROLE_ARN

log "Cluster $CLUSTER_NAME (k8s $K8S_VERSION)"
if ! aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  aws eks create-cluster --name "$CLUSTER_NAME" --kubernetes-version "$K8S_VERSION" --role-arn "$LAB_ROLE_ARN" \
    --resources-vpc-config "subnetIds=$APP_A,$APP_B,$PUB_A,$PUB_B,securityGroupIds=$SG_EKS,endpointPublicAccess=true,endpointPrivateAccess=true" \
    --tags Project="$PROJECT" >/dev/null
fi
log "Esperando cluster ACTIVE (~10 min)"
aws eks wait cluster-active --name "$CLUSTER_NAME"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
save_state CLUSTER_SG "$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)"
ok "Cluster activo, kubeconfig listo, cluster SG $CLUSTER_SG"

log "Launch template (EBS gp3 cifrado, IMDSv2 con hop limit 2 para los controllers, SG-EKS + SG del cluster)"
if ! aws ec2 describe-launch-templates --launch-template-names freshbox-ng-lt >/dev/null 2>&1; then
  LT_DATA=$(jq -nc --arg a "$SG_EKS" --arg b "$CLUSTER_SG" '{
    BlockDeviceMappings:[{DeviceName:"/dev/xvda",Ebs:{VolumeSize:20,VolumeType:"gp3",Encrypted:true,DeleteOnTermination:true}}],
    MetadataOptions:{HttpEndpoint:"enabled",HttpTokens:"required",HttpPutResponseHopLimit:2},
    SecurityGroupIds:[$a,$b]}')
  aws ec2 create-launch-template --launch-template-name freshbox-ng-lt --launch-template-data "$LT_DATA" >/dev/null
fi
ok "freshbox-ng-lt"

log "Node group $NODEGROUP ($NODE_TYPE x $NODE_MIN-$NODE_MAX, subredes app)"
if ! aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" >/dev/null 2>&1; then
  aws eks create-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP" \
    --scaling-config "minSize=$NODE_MIN,maxSize=$NODE_MAX,desiredSize=$NODE_DESIRED" \
    --subnets "$APP_A" "$APP_B" --node-role "$LAB_ROLE_ARN" \
    --ami-type AL2023_ARM_64_STANDARD --instance-types "$NODE_TYPE" --capacity-type ON_DEMAND \
    --launch-template name=freshbox-ng-lt,version=1 \
    --tags "k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/${CLUSTER_NAME}=owned,Project=${PROJECT}" >/dev/null
fi
log "Esperando nodos (~5 min)"
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP"
kubectl get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
