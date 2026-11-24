#!/usr/bin/env bash
# Paso 1: VPC /22, 6 subredes /26 (2 publicas, 2 privadas app, 2 privadas datos), IGW, NAT, rutas y Security Groups
source "$(dirname "$0")/lib.sh"
mapfile -t AZS < <(aws ec2 describe-availability-zones --filters Name=state,Values=available Name=zone-type,Values=availability-zone --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' '\n' | sort | head -2)
AZ_A=${AZS[0]}; AZ_B=${AZS[1]}; log "AZ: $AZ_A / $AZ_B"

log "VPC"
if [ -z "${VPC_ID:-}" ]; then
  save_state VPC_ID "$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "$(tags vpc freshbox-vpc)" --query Vpc.VpcId --output text)"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
fi; ok "$VPC_ID"

mk_subnet() { # VAR nombre cidr az tagKey tagVal
  [ -n "${!1:-}" ] && { ok "$2 ya existe"; return; }
  local id; id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$3" --availability-zone "$4" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT},{Key=$5,Value=$6},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared}]" \
    --query Subnet.SubnetId --output text)
  save_state "$1" "$id"; ok "$2 $id"
}
log "Subredes"
mk_subnet PUB_A  freshbox-pub-a  10.0.0.0/26   "$AZ_A" kubernetes.io/role/elb 1
mk_subnet PUB_B  freshbox-pub-b  10.0.0.64/26  "$AZ_B" kubernetes.io/role/elb 1
mk_subnet APP_A  freshbox-app-a  10.0.0.128/26 "$AZ_A" kubernetes.io/role/internal-elb 1
mk_subnet APP_B  freshbox-app-b  10.0.0.192/26 "$AZ_B" kubernetes.io/role/internal-elb 1
mk_subnet DATA_A freshbox-data-a 10.0.1.0/26   "$AZ_A" Tier data
mk_subnet DATA_B freshbox-data-b 10.0.1.64/26  "$AZ_B" Tier data
save_state AZ_A "$AZ_A"; save_state AZ_B "$AZ_B"

log "Internet Gateway"
if [ -z "${IGW_ID:-}" ]; then
  save_state IGW_ID "$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway freshbox-igw)" --query InternetGateway.InternetGatewayId --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi; ok "$IGW_ID"

log "NAT Gateway (unico, en pub-a)"
if [ -z "${NAT_ID:-}" ]; then
  save_state EIP_ALLOC "$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tags elastic-ip freshbox-nat-eip)" --query AllocationId --output text)"
  save_state NAT_ID "$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_ALLOC" --tag-specifications "$(tags natgateway freshbox-nat)" --query NatGateway.NatGatewayId --output text)"
fi
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"; ok "$NAT_ID disponible"

log "Tablas de ruta"
if [ -z "${RT_PUB:-}" ]; then
  save_state RT_PUB "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tags route-table freshbox-rt-public)" --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  for s in "$PUB_A" "$PUB_B"; do aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$s" >/dev/null; done
fi
if [ -z "${RT_APP:-}" ]; then
  save_state RT_APP "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tags route-table freshbox-rt-app)" --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route --route-table-id "$RT_APP" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
  for s in "$APP_A" "$APP_B"; do aws ec2 associate-route-table --route-table-id "$RT_APP" --subnet-id "$s" >/dev/null; done
fi
if [ -z "${RT_DATA:-}" ]; then
  save_state RT_DATA "$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tags route-table freshbox-rt-data)" --query RouteTable.RouteTableId --output text)"
  for s in "$DATA_A" "$DATA_B"; do aws ec2 associate-route-table --route-table-id "$RT_DATA" --subnet-id "$s" >/dev/null; done
fi
ok "public=$RT_PUB app=$RT_APP data=$RT_DATA (datos sin ruta a Internet)"

log "Security Groups"
mk_sg() { # VAR nombre descripcion
  [ -n "${!1:-}" ] && { ok "$2 ya existe"; return; }
  save_state "$1" "$(aws ec2 create-security-group --group-name "$2" --description "$3" --vpc-id "$VPC_ID" --tag-specifications "$(tags security-group "$2")" --query GroupId --output text)"
  ok "$2 ${!1}"
}
mk_sg SG_ALB    freshbox-sg-alb    "ALB publico"
mk_sg SG_EKS    freshbox-sg-eks    "Nodos EKS (capa app)"
mk_sg SG_LAMBDA freshbox-sg-lambda "Funciones Lambda en VPC"
mk_sg SG_RDS    freshbox-sg-rds    "RDS MySQL (capa datos)"

allow "$SG_ALB" "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]"
allow "$SG_ALB" "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]"
# Nodos/pods: trafico interno del cluster + puertos de los 4 microservicios solo desde el ALB
allow "$SG_EKS" "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$SG_EKS}]"
allow "$SG_EKS" "IpProtocol=tcp,FromPort=3001,ToPort=3004,UserIdGroupPairs=[{GroupId=$SG_ALB}]"
# RDS: 3306 solo desde EKS y Lambda
allow "$SG_RDS" "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$SG_EKS}]"
allow "$SG_RDS" "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$SG_LAMBDA}]"
ok "Reglas: ALB 80/443 <- Internet | EKS 3001-3004 <- ALB | RDS 3306 <- EKS y Lambda"
log "Red lista"
