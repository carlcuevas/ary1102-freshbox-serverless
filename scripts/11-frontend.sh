#!/usr/bin/env bash
# Paso 11: publica el frontend estatico en S3 (Static Website Hosting) con la URL del API inyectada
source "$(dirname "$0")/lib.sh"
need_state API_URL ACCOUNT_ID
BUCKET="freshbox-frontend-$ACCOUNT_ID"; save_state BUCKET "$BUCKET"
OUT="$ROOT_DIR/build/frontend"; rm -rf "$OUT"; mkdir -p "$OUT"; cp -r "$ROOT_DIR/app/frontend/." "$OUT/"
sed -i "s|__API_URL__|$API_URL|" "$OUT/js/app.js"; grep -q "$API_URL" "$OUT/js/app.js" || die "No se inyecto API_URL"
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || aws s3api create-bucket --bucket "$BUCKET" >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false 2>/dev/null || warn "No pude abrir el acceso publico del bucket"
aws s3api put-bucket-website --bucket "$BUCKET" --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}'
cat > "$ROOT_DIR/build/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"PublicRead","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::$BUCKET/*"}]}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$ROOT_DIR/build/policy.json" || warn "Politica publica rechazada (revisa Block Public Access de la cuenta)"
aws s3 sync "$OUT" "s3://$BUCKET" --delete --cache-control no-cache >/dev/null
save_state SITE_URL "http://$BUCKET.s3-website-$REGION.amazonaws.com"
ok "$SITE_URL"; echo "  GET sitio -> $(curl -s -o /dev/null -w '%{http_code}' "$SITE_URL")"
