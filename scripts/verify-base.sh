#!/usr/bin/env bash
# Verifica la base (equivalente al verify.sh del EP2). Termina en TODO OK o con errores.
source "$(dirname "$0")/lib.sh"
set +e; ERR=0
chk() { local d="$1"; shift; if eval "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; ERR=$((ERR+1)); fi; }

log "Red y Security Groups"
chk "VPC $VPC_CIDR"                    '[ "$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query Vpcs[0].CidrBlock --output text)" = "$VPC_CIDR" ]'
chk "6 subredes"                       '[ "$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --query "length(Subnets)" --output text)" = 6 ]'
chk "NAT Gateway available"            '[ "$(aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_ID --query NatGateways[0].State --output text)" = available ]'
chk "SG-RDS 3306 solo desde EKS+Lambda" '[ "$(aws ec2 describe-security-groups --group-ids $SG_RDS --query "SecurityGroups[0].IpPermissions[?FromPort==\`3306\`].UserIdGroupPairs[].GroupId" --output text | tr "\t" "\n" | sort | tr "\n" " ")" = "$(printf "%s\n%s\n" $SG_EKS $SG_LAMBDA | sort | tr "\n" " ")" ]'
log "EKS"
chk "cluster ACTIVE"                   '[ "$(aws eks describe-cluster --name $CLUSTER_NAME --query cluster.status --output text)" = ACTIVE ]'
chk "nodos Ready >= 2"                 '[ "$(kubectl get nodes --no-headers | grep -c " Ready")" -ge 2 ]'
chk "nodos en 2 AZ"                    '[ "$(kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{\"\n\"}{end}" | sort -u | wc -l)" = 2 ]'
chk "nodos arm64 (Graviton)"           '[ "$(kubectl get nodes -o jsonpath="{.items[*].status.nodeInfo.architecture}" | tr " " "\n" | sort -u)" = arm64 ]'
chk "volumenes EBS de nodos cifrados"  '[ -z "$(aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=$(aws ec2 describe-instances --filters Name=tag:eks:cluster-name,Values=$CLUSTER_NAME Name=instance-state-name,Values=running --query "Reservations[].Instances[].InstanceId" --output text | tr "\t" ",") --query "Volumes[?Encrypted==\`false\`].VolumeId" --output text)" ]'
chk "add-on metrics-server ACTIVE"     '[ "$(aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name metrics-server --query addon.status --output text)" = ACTIVE ]'
chk "add-on CloudWatch Observability"  '[ "$(aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name amazon-cloudwatch-observability --query addon.status --output text)" = ACTIVE ]'
chk "AWS LB Controller disponible"     'kubectl -n kube-system get deploy aws-load-balancer-controller -o jsonpath="{.status.availableReplicas}" | grep -q 1'
chk "Cluster Autoscaler corriendo"     'kubectl -n kube-system get deploy | grep -q cluster-autoscaler'
chk "kubectl top nodes (metrics-server)" 'kubectl top nodes'
log "RDS"
RQ() { aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --query "DBInstances[0].$1" --output text; }
chk "clase $RDS_CLASS"                 '[ "$(RQ DBInstanceClass)" = "$RDS_CLASS" ]'
chk "Multi-AZ"                         '[ "$(RQ MultiAZ)" = True ]'
chk "cifrada"                          '[ "$(RQ StorageEncrypted)" = True ]'
chk "sin acceso publico"               '[ "$(RQ PubliclyAccessible)" = False ]'
chk "backups 7 dias"                   '[ "$(RQ BackupRetentionPeriod)" = 7 ]'
chk "estado available"                 '[ "$(RQ DBInstanceStatus)" = available ]'
chk "Job db-init completado"           'kubectl -n $NAMESPACE get job db-init -o jsonpath="{.status.succeeded}" | grep -q 1'
echo; [ $ERR -eq 0 ] && { printf '\033[1;32mTODO OK\033[0m\n'; } || { printf '\033[1;31m%s verificaciones fallaron\033[0m\n' "$ERR"; exit 1; }
