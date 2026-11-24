#!/usr/bin/env bash
# Paso 12: monitoreo con CloudWatch - dashboard, 4 alarmas, SNS y retencion de logs.
# Uso: ALARM_EMAIL=tu@correo.cl ./scripts/12-monitoring.sh     (el correo es opcional)
source "$(dirname "$0")/lib.sh"
DASH=freshbox-ep3
TOPIC_NAME=freshbox-alertas

log "Datos de los recursos"
LB_DIM=$(aws elbv2 describe-load-balancers --names freshbox-eks-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's|.*:loadbalancer/||')
API_ID=${API_ID:-$(aws apigateway get-rest-apis --query "items[?name=='freshbox-api'].id | [0]" --output text)}
API_NAME=$(aws apigateway get-rest-api --rest-api-id "$API_ID" --query name --output text)
ok "ALB $LB_DIM | API $API_NAME ($API_ID)"
export REGION CLUSTER_NAME NAMESPACE LB_DIM API_NAME RDS_ID

log "Dashboard $DASH"
mkdir -p "$ROOT_DIR/app"
python3 - > "$ROOT_DIR/app/dashboard.json" <<'PY'
import json, os
R=os.environ['REGION']; C=os.environ['CLUSTER_NAME']; NS=os.environ['NAMESPACE']
LB=os.environ['LB_DIM']; API=os.environ['API_NAME']; DB=os.environ['RDS_ID']
SVCS=['get-products','create-product','update-product','delete-product']
FUN=['freshbox-cart','freshbox-create-order','freshbox-process-order']
def w(x,y,wd,title,metrics,stat='Average',period=60,h=6):
    return {'type':'metric','x':x,'y':y,'width':wd,'height':h,'properties':{'title':title,'region':R,'view':'timeSeries','stat':stat,'period':period,'metrics':metrics}}
ci=lambda m,s:['ContainerInsights',m,'ClusterName',C,'Namespace',NS,'Service',s]
fn=lambda m,f,st='Sum':['AWS/Lambda',m,'FunctionName',f,{'stat':st}]
ws=[{'type':'text','x':0,'y':0,'width':24,'height':1,'properties':{'markdown':'# FreshBox SpA - Arquitectura hibrida EKS + serverless (EP3)'}}]
ws.append(w(0,1,8,'EKS - replicas por servicio (HPA)',[ci('service_number_of_running_pods',s)+[{'stat':'Maximum'}] for s in SVCS]))
ws.append(w(8,1,8,'EKS - CPU por servicio (%)',[ci('pod_cpu_utilization',s) for s in SVCS]))
ws.append(w(16,1,8,'EKS - CPU y memoria de nodos (%)',[['ContainerInsights','node_cpu_utilization','ClusterName',C],['ContainerInsights','node_memory_utilization','ClusterName',C]]))
ws.append(w(0,7,8,'API Gateway - solicitudes y errores',[['AWS/ApiGateway','Count','ApiName',API,'Stage','prod',{'stat':'Sum'}],['AWS/ApiGateway','4XXError','ApiName',API,'Stage','prod',{'stat':'Sum'}],['AWS/ApiGateway','5XXError','ApiName',API,'Stage','prod',{'stat':'Sum'}]],'Sum'))
ws.append(w(8,7,8,'API Gateway - latencia (ms)',[['AWS/ApiGateway','Latency','ApiName',API,'Stage','prod',{'stat':'Average'}],['AWS/ApiGateway','Latency','ApiName',API,'Stage','prod',{'stat':'p95'}]]))
ws.append(w(16,7,8,'ALB - solicitudes y errores de destino',[['AWS/ApplicationELB','RequestCount','LoadBalancer',LB,{'stat':'Sum'}],['AWS/ApplicationELB','HTTPCode_Target_5XX_Count','LoadBalancer',LB,{'stat':'Sum'}]],'Sum'))
ws.append(w(0,13,6,'Lambda - invocaciones',[fn('Invocations',f) for f in FUN],'Sum'))
ws.append(w(6,13,6,'Lambda - errores y limitaciones',[fn('Errors',f) for f in FUN]+[fn('Throttles',f) for f in FUN],'Sum'))
ws.append(w(12,13,6,'Lambda - duracion promedio (ms)',[fn('Duration',f,'Average') for f in FUN]))
ws.append(w(18,13,6,'Lambda - ejecuciones simultaneas',[fn('ConcurrentExecutions',f,'Maximum') for f in FUN]))
ws.append(w(0,19,8,'SQS - mensajes visibles (cola y DLQ)',[['AWS/SQS','ApproximateNumberOfMessagesVisible','QueueName','freshbox-ordenes',{'stat':'Maximum'}],['AWS/SQS','ApproximateNumberOfMessagesVisible','QueueName','freshbox-ordenes-dlq',{'stat':'Maximum'}]]))
ws.append(w(8,19,8,'RDS - CPU (%) y conexiones',[['AWS/RDS','CPUUtilization','DBInstanceIdentifier',DB],['AWS/RDS','DatabaseConnections','DBInstanceIdentifier',DB]]))
ws.append(w(16,19,8,'DynamoDB - capacidad consumida (carrito)',[['AWS/DynamoDB','ConsumedReadCapacityUnits','TableName','carrito-freshbox',{'stat':'Sum'}],['AWS/DynamoDB','ConsumedWriteCapacityUnits','TableName','carrito-freshbox',{'stat':'Sum'}]],'Sum'))
print(json.dumps({'widgets':ws}))
PY
aws cloudwatch put-dashboard --dashboard-name "$DASH" --dashboard-body "file://$ROOT_DIR/app/dashboard.json" >/dev/null
ok "https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards/dashboard/${DASH}"

log "SNS para las alarmas"
TOPIC_ARN=$(aws sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)
save_state TOPIC_ARN "$TOPIC_ARN"
if [ -n "${ALARM_EMAIL:-}" ]; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALARM_EMAIL" >/dev/null
  ok "Suscripcion enviada a $ALARM_EMAIL (confirma el correo que te llega de AWS)"
else
  warn "Sin ALARM_EMAIL: las alarmas existen pero no envian correo"
fi
ACT=(--alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN")

log "Alarmas"
aws cloudwatch put-metric-alarm --alarm-name freshbox-dlq-no-vacia \
  --alarm-description "Hay ordenes que fallaron 3 veces y quedaron en la DLQ" \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible --dimensions Name=QueueName,Value=freshbox-ordenes-dlq \
  --statistic Maximum --period 60 --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching "${ACT[@]}"
ok "freshbox-dlq-no-vacia"

cat > "$ROOT_DIR/app/alarma-lambda.json" <<JSON
[
 {"Id":"total","Expression":"SUM(METRICS())","Label":"Errores Lambda (total)","ReturnData":true},
 {"Id":"m1","MetricStat":{"Metric":{"Namespace":"AWS/Lambda","MetricName":"Errors","Dimensions":[{"Name":"FunctionName","Value":"freshbox-cart"}]},"Period":60,"Stat":"Sum"},"ReturnData":false},
 {"Id":"m2","MetricStat":{"Metric":{"Namespace":"AWS/Lambda","MetricName":"Errors","Dimensions":[{"Name":"FunctionName","Value":"freshbox-create-order"}]},"Period":60,"Stat":"Sum"},"ReturnData":false},
 {"Id":"m3","MetricStat":{"Metric":{"Namespace":"AWS/Lambda","MetricName":"Errors","Dimensions":[{"Name":"FunctionName","Value":"freshbox-process-order"}]},"Period":60,"Stat":"Sum"},"ReturnData":false}
]
JSON
aws cloudwatch put-metric-alarm --alarm-name freshbox-lambda-errores \
  --alarm-description "Errores en alguna de las 3 funciones Lambda" \
  --metrics "file://$ROOT_DIR/app/alarma-lambda.json" --evaluation-periods 1 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching "${ACT[@]}"
ok "freshbox-lambda-errores"

aws cloudwatch put-metric-alarm --alarm-name freshbox-apigw-5xx \
  --alarm-description "Errores 5XX en el stage prod de API Gateway" \
  --namespace AWS/ApiGateway --metric-name 5XXError --dimensions Name=ApiName,Value="$API_NAME" Name=Stage,Value=prod \
  --statistic Sum --period 60 --evaluation-periods 1 --threshold 3 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching "${ACT[@]}"
ok "freshbox-apigw-5xx"

aws cloudwatch put-metric-alarm --alarm-name freshbox-hpa-get-products-al-maximo \
  --alarm-description "get-products llego al maximo del HPA (3 replicas): evaluar subir el limite" \
  --namespace ContainerInsights --metric-name service_number_of_running_pods \
  --dimensions Name=ClusterName,Value="$CLUSTER_NAME" Name=Namespace,Value="$NAMESPACE" Name=Service,Value=get-products \
  --statistic Maximum --period 60 --evaluation-periods 1 --threshold 3 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching "${ACT[@]}"
ok "freshbox-hpa-get-products-al-maximo"

log "Retencion de logs a 14 dias (los grupos nuevos nunca expiran por defecto)"
for g in /aws/lambda/freshbox-cart /aws/lambda/freshbox-create-order /aws/lambda/freshbox-process-order \
         $(aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/${CLUSTER_NAME}" --query 'logGroups[].logGroupName' --output text); do
  aws logs put-retention-policy --log-group-name "$g" --retention-in-days 14 >/dev/null 2>&1 && ok "$g" || warn "sin grupo $g"
done

log "Estado de las alarmas"
aws cloudwatch describe-alarms --alarm-name-prefix freshbox- --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
