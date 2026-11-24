#!/usr/bin/env bash
# Paso 10: API Gateway REST (importado desde OpenAPI generado): productos -> ALB, carrito/ordenes -> Lambda. CORS y stage prod.
source "$(dirname "$0")/lib.sh"
need_state ALB_DNS CART_ARN ORDER_ARN ACCOUNT_ID
mkdir -p "$ROOT_DIR/build"; OAS="$ROOT_DIR/build/openapi.json"
python3 - > "$OAS" <<'PY'
import json, os
R = os.environ['REGION']; ALB = os.environ['ALB_DNS']
uri = lambda arn: f"arn:aws:apigateway:{R}:lambda:path/2015-03-31/functions/{arn}/invocations"
CORS = {"Access-Control-Allow-Origin": "'*'", "Access-Control-Allow-Headers": "'Content-Type'", "Access-Control-Allow-Methods": "'GET,POST,PUT,DELETE,OPTIONS'"}
def options():
    return {"responses": {"200": {"description": "CORS", "headers": {k: {"schema": {"type": "string"}} for k in CORS}}},
            "x-amazon-apigateway-integration": {"type": "mock", "requestTemplates": {"application/json": "{\"statusCode\": 200}"}, "passthroughBehavior": "when_no_match",
              "responses": {"default": {"statusCode": "200", "responseParameters": {f"method.response.header.{k}": v for k, v in CORS.items()}}}}}
def params(pp): return [{"name": n, "in": "path", "required": True, "schema": {"type": "string"}} for n in pp]
def http(method, path, pp=()):
    i = {"type": "http_proxy", "httpMethod": method, "uri": f"http://{ALB}{path}", "passthroughBehavior": "when_no_match", "timeoutInMillis": 10000}
    if pp: i["requestParameters"] = {f"integration.request.path.{n}": f"method.request.path.{n}" for n in pp}
    op = {"responses": {"200": {"description": "ok"}}, "x-amazon-apigateway-integration": i}
    if pp: op["parameters"] = params(pp)
    return op
def lam(arn, pp=()):
    op = {"responses": {"200": {"description": "ok"}}, "x-amazon-apigateway-integration": {"type": "aws_proxy", "httpMethod": "POST", "uri": uri(arn), "passthroughBehavior": "when_no_match"}}
    if pp: op["parameters"] = params(pp)
    return op
C, O = os.environ['CART_ARN'], os.environ['ORDER_ARN']
paths = {
  "/api/products": {"get": http("GET", "/api/products"), "post": http("POST", "/api/products"), "options": options()},
  "/api/products/{id}": {"get": http("GET", "/api/products/{id}", ["id"]), "put": http("PUT", "/api/products/{id}", ["id"]), "delete": http("DELETE", "/api/products/{id}", ["id"]), "options": options()},
  "/api/cart": {"get": lam(C), "post": lam(C), "options": options()},
  "/api/cart/{productId}": {"delete": lam(C, ["productId"]), "options": options()},
  "/api/orders": {"post": lam(O), "options": options()},
  "/api/orders/{orderId}": {"get": lam(O, ["orderId"]), "options": options()},
}
print(json.dumps({"openapi": "3.0.1", "info": {"title": "freshbox-api", "version": "1.0"}, "paths": paths}))
PY
jq -e '.paths|length==6' "$OAS" >/dev/null || die "OpenAPI invalido"
log "Importando API"
if [ -z "${API_ID:-}" ]; then
  save_state API_ID "$(aws apigateway import-rest-api --body "fileb://$OAS" --parameters endpointConfigurationTypes=REGIONAL --query id --output text)"
else
  aws apigateway put-rest-api --rest-api-id "$API_ID" --mode overwrite --body "fileb://$OAS" >/dev/null
fi
ok "API $API_ID"
for t in DEFAULT_4XX DEFAULT_5XX; do
  aws apigateway put-gateway-response --rest-api-id "$API_ID" --response-type $t \
    --response-parameters file://$ROOT_DIR/app/gwresp.json >/dev/null
done
log "Permisos API Gateway -> Lambda"
for fn in freshbox-cart freshbox-create-order; do
  aws lambda remove-permission --function-name $fn --statement-id apigw-invoke >/dev/null 2>&1 || true
  aws lambda add-permission --function-name $fn --statement-id apigw-invoke --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*/*" >/dev/null
  ok "$fn"
done
log "Deploy stage prod"
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name prod >/dev/null
aws apigateway update-stage --rest-api-id "$API_ID" --stage-name prod --patch-operations \
  op=replace,path=/*/*/throttling/rateLimit,value=50 op=replace,path=/*/*/throttling/burstLimit,value=100 op=replace,path=/*/*/metrics/enabled,value=true >/dev/null 2>&1 || warn "No pude fijar throttling/metricas del stage (no es critico)"
save_state API_URL "https://$API_ID.execute-api.$REGION.amazonaws.com/prod"
ok "$API_URL"
echo "  GET /api/products -> $(curl -s -o /dev/null -w '%{http_code}' "$API_URL/api/products")"
echo "  GET /api/cart?userId=test123 -> $(curl -s -o /dev/null -w '%{http_code}' "$API_URL/api/cart?userId=test123")"
