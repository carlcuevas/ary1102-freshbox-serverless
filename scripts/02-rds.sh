#!/usr/bin/env bash
# Paso 2: inicia RDS MySQL Multi-AZ cifrado (tarda ~15-20 min; NO espera: sigue con el paso 3 en paralelo)
source "$(dirname "$0")/lib.sh"
need_state DATA_A DATA_B SG_RDS

[ -n "${DB_ADMIN_PASS:-}" ] || { save_secret DB_ADMIN_PASS "$(gen_pass)"; save_secret APP_DB_PASS "$(gen_pass)"; log "Credenciales generadas en .secrets.env (no se versiona)"; }

aws rds describe-db-subnet-groups --db-subnet-group-name freshbox-db-subnets >/dev/null 2>&1 || \
  aws rds create-db-subnet-group --db-subnet-group-name freshbox-db-subnets --db-subnet-group-description "FreshBox datos" --subnet-ids "$DATA_A" "$DATA_B" >/dev/null
ok "DB subnet group"

if aws rds describe-db-instances --db-instance-identifier "$RDS_ID" >/dev/null 2>&1; then
  ok "$RDS_ID ya existe"; exit 0
fi
EV=$(aws rds describe-db-engine-versions --engine mysql --query "DBEngineVersions[?starts_with(EngineVersion,'8.0')].EngineVersion" --output text | tr '\t' '\n' | sort -V | tail -1)
log "Creando $RDS_ID (MySQL $EV, $RDS_CLASS, Multi-AZ, gp3 20GB cifrado, backups 7 dias)"
aws rds create-db-instance --db-instance-identifier "$RDS_ID" --db-instance-class "$RDS_CLASS" \
  --engine mysql --engine-version "$EV" --db-name "$DB_NAME" \
  --master-username "$DB_ADMIN_USER" --master-user-password "$DB_ADMIN_PASS" \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted --multi-az --no-publicly-accessible \
  --db-subnet-group-name freshbox-db-subnets --vpc-security-group-ids "$SG_RDS" \
  --backup-retention-period 7 --copy-tags-to-snapshot --tags Key=Project,Value="$PROJECT" >/dev/null
ok "Creacion iniciada. Continua con 03-eks.sh"
