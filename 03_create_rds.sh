#!/bin/bash
# ============================================================
# 03_create_rds.sh - Crear instancia RDS PostgreSQL en AWS
# Uso: bash 03_create_rds.sh
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ──────────────────────────────────────────
# CONFIGURACIÓN — edita estas variables
# ──────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-west-1}"
DB_NAME="${DB_NAME:-nombre_de_tu_base_de_datos}"
RDS_IDENTIFIER="${RDS_IDENTIFIER:-mi-postgres-rds}"
RDS_MASTER_USER="${RDS_MASTER_USER:-adminuser}"
RDS_MASTER_PASS="${RDS_MASTER_PASS:-CambiaEstaPassword123!}"
RDS_INSTANCE_CLASS="${RDS_INSTANCE_CLASS:-db.t3.medium}"
PG_VERSION="${PG_VERSION:-15}"
SUBNET_GROUP_NAME="migracion-subnet-group"
SG_NAME="rds-postgres-sg"

# ──────────────────────────────────────────
# VERIFICACIONES
# ──────────────────────────────────────────
command -v aws >/dev/null || fail "AWS CLI no instalado."
aws sts get-caller-identity > /dev/null || fail "AWS CLI no configurado."

# ──────────────────────────────────────────
# OBTENER VPC DEFAULT
# ──────────────────────────────────────────
log "Obteniendo VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION")

[ "$VPC_ID" = "None" ] && fail "No hay VPC default. Configura VPC_ID manualmente."
log "VPC: $VPC_ID"

# ──────────────────────────────────────────
# OBTENER SUBNETS
# ──────────────────────────────────────────
log "Obteniendo subnets..."
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].SubnetId' \
  --output text \
  --region "$AWS_REGION")

SUBNET_ARRAY=($SUBNET_IDS)
[ ${#SUBNET_ARRAY[@]} -lt 2 ] && fail "Se necesitan al menos 2 subnets en distintas AZs."
log "Subnets encontradas: ${SUBNET_ARRAY[@]}"

# ──────────────────────────────────────────
# CREAR SUBNET GROUP
# ──────────────────────────────────────────
log "Creando DB Subnet Group..."
if aws rds describe-db-subnet-groups --db-subnet-group-name "$SUBNET_GROUP_NAME" \
   --region "$AWS_REGION" 2>/dev/null; then
  warn "Subnet Group '$SUBNET_GROUP_NAME' ya existe, omitiendo."
else
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$SUBNET_GROUP_NAME" \
    --db-subnet-group-description "Subnet group para migración PostgreSQL" \
    --subnet-ids "${SUBNET_ARRAY[@]}" \
    --region "$AWS_REGION"
  log "Subnet Group creado ✓"
fi

# ──────────────────────────────────────────
# CREAR SECURITY GROUP
# ──────────────────────────────────────────
log "Creando Security Group..."
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "SG para RDS PostgreSQL - Migración" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text \
    --region "$AWS_REGION")
  log "Security Group creado: $SG_ID"

  # Obtener IP pública actual
  MY_IP=$(curl -s https://checkip.amazonaws.com || echo "0.0.0.0")
  log "Tu IP pública: $MY_IP"

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 5432 \
    --cidr "$MY_IP/32" \
    --region "$AWS_REGION"
  log "Regla ingress PostgreSQL añadida para $MY_IP/32 ✓"
else
  warn "Security Group '$SG_NAME' ya existe: $SG_ID"
fi

# ──────────────────────────────────────────
# CREAR INSTANCIA RDS
# ──────────────────────────────────────────
log "Creando instancia RDS: $RDS_IDENTIFIER"

# Verificar si ya existe
RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "notfound")

if [ "$RDS_STATUS" != "notfound" ]; then
  warn "La instancia '$RDS_IDENTIFIER' ya existe (estado: $RDS_STATUS). Omitiendo creación."
else
  aws rds create-db-instance \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --db-instance-class "$RDS_INSTANCE_CLASS" \
    --engine postgres \
    --engine-version "${PG_VERSION}" \
    --master-username "$RDS_MASTER_USER" \
    --master-user-password "$RDS_MASTER_PASS" \
    --allocated-storage 20 \
    --max-allocated-storage 100 \
    --db-name "$DB_NAME" \
    --db-subnet-group-name "$SUBNET_GROUP_NAME" \
    --vpc-security-group-ids "$SG_ID" \
    --backup-retention-period 7 \
    --no-multi-az \
    --publicly-accessible \
    --storage-type gp3 \
    --storage-encrypted \
    --deletion-protection \
    --region "$AWS_REGION"

  log "Instancia RDS creada. Esperando que esté disponible (puede tardar ~10 minutos)..."
  aws rds wait db-instance-available \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --region "$AWS_REGION"
  log "Instancia RDS disponible ✓"
fi

# ──────────────────────────────────────────
# OBTENER ENDPOINT
# ──────────────────────────────────────────
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

RDS_PORT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Port' \
  --output text \
  --region "$AWS_REGION")

# Guardar endpoint para scripts siguientes
echo "RDS_ENDPOINT=$RDS_ENDPOINT" > .rds_config
echo "RDS_PORT=$RDS_PORT" >> .rds_config
echo "RDS_IDENTIFIER=$RDS_IDENTIFIER" >> .rds_config
echo "RDS_MASTER_USER=$RDS_MASTER_USER" >> .rds_config
echo "DB_NAME=$DB_NAME" >> .rds_config
echo "SG_ID=$SG_ID" >> .rds_config

echo ""
echo "======================================"
log "RDS CREADO Y DISPONIBLE"
echo "======================================"
echo "  🗄️  Identifier: $RDS_IDENTIFIER"
echo "  🌐 Endpoint:    $RDS_ENDPOINT"
echo "  🔌 Puerto:      $RDS_PORT"
echo "  👤 Usuario:     $RDS_MASTER_USER"
echo "  📁 Base datos:  $DB_NAME"
echo ""
echo "  Prueba de conexión:"
echo "  psql -h $RDS_ENDPOINT -p $RDS_PORT -U $RDS_MASTER_USER -d $DB_NAME"
echo ""
echo "Próximo paso: bash scripts/04_import.sh"
