#!/usr/bin/env bash
# Paso 8: DynamoDB (carrito, TTL), SQS + DLQ y VPC Endpoint Gateway para DynamoDB
source "$(dirname "$0")/lib.sh"
need_state VPC_ID RT_APP
TABLE=carrito-freshbox
log "DynamoDB $TABLE (on-demand, TTL en expiresAt)"
if ! aws dynamodb describe-table --table-name $TABLE >/dev/null 2>&1; then
  aws dynamodb create-table --table-name $TABLE --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=userId,AttributeType=S AttributeName=productId,AttributeType=S \
    --key-schema AttributeName=userId,KeyType=HASH AttributeName=productId,KeyType=RANGE \
    --tags Key=Project,Value=$PROJECT >/dev/null
fi
aws dynamodb wait table-exists --table-name $TABLE
aws dynamodb update-time-to-live --table-name $TABLE --time-to-live-specification Enabled=true,AttributeName=expiresAt >/dev/null 2>&1 || true
ok "TTL: $(aws dynamodb describe-time-to-live --table-name $TABLE --query TimeToLiveDescription.TimeToLiveStatus --output text)"

log "SQS: cola de ordenes + DLQ (3 intentos)"
DLQ_URL=$(aws sqs create-queue --queue-name freshbox-ordenes-dlq --attributes SqsManagedSseEnabled=true,MessageRetentionPeriod=1209600 --query QueueUrl --output text)
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)
cat > "$ROOT_DIR/state.queue.json" <<JSON
{"VisibilityTimeout":"180","SqsManagedSseEnabled":"true","MessageRetentionPeriod":"345600","RedrivePolicy":"{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"}
JSON
SQS_URL=$(aws sqs create-queue --queue-name freshbox-ordenes --attributes "file://$ROOT_DIR/state.queue.json" --query QueueUrl --output text)
rm -f "$ROOT_DIR/state.queue.json"
save_state SQS_URL "$SQS_URL"; save_state DLQ_URL "$DLQ_URL"
save_state SQS_ARN "$(aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
ok "$SQS_URL"

log "VPC Endpoint Gateway para DynamoDB (rutas de la capa de aplicacion)"
EP=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.$REGION.dynamodb --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' --output text)
if [ -z "$EP" ]; then
  EP=$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --vpc-endpoint-type Gateway --service-name com.amazonaws.$REGION.dynamodb --route-table-ids "$RT_APP" \
    --tag-specifications "$(tags vpc-endpoint freshbox-dynamodb-endpoint)" --query VpcEndpoint.VpcEndpointId --output text)
fi
save_state VPCE_ID "$EP"; ok "$EP"
