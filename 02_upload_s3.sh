#!/bin/bash
# ============================================================
# 02_upload_s3.sh - Subida del dump a S3
# Uso: bash 02_upload_s3.sh <archivo_dump>
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ──────────────────────────────────────────
# CONFIGURACIÓN
# ──────────────────────────────────────────
S3_BUCKET="${S3_BUCKET:-mi-bucket-migracion-postgres}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
DUMP_FILE="${1:-}"  # Puedes pasar el archivo como argumento

# Si no se pasa argumento, usa el más reciente
if [ -z "$DUMP_FILE" ]; then
  DUMP_FILE=$(ls -t "$BACKUP_DIR"/*.dump 2>/dev/null | head -1)
  [ -z "$DUMP_FILE" ] && fail "No se encontró ningún .dump en $BACKUP_DIR"
  warn "Usando dump más reciente: $DUMP_FILE"
fi

[ -f "$DUMP_FILE" ] || fail "Archivo no encontrado: $DUMP_FILE"

# ──────────────────────────────────────────
# VERIFICAR AWS CLI
# ──────────────────────────────────────────
command -v aws >/dev/null || fail "AWS CLI no instalado."
aws sts get-caller-identity > /dev/null || fail "AWS CLI no configurado. Ejecuta: aws configure"

# ──────────────────────────────────────────
# CREAR BUCKET SI NO EXISTE
# ──────────────────────────────────────────
log "Verificando bucket S3: s3://$S3_BUCKET"
if ! aws s3 ls "s3://$S3_BUCKET" 2>/dev/null; then
  log "Creando bucket: s3://$S3_BUCKET"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3 mb "s3://$S3_BUCKET"
  else
    aws s3 mb "s3://$S3_BUCKET" --region "$AWS_REGION"
  fi
  
  # Bloquear acceso público al bucket
  aws s3api put-public-access-block \
    --bucket "$S3_BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  
  log "Bucket creado y acceso público bloqueado ✓"
fi

# ──────────────────────────────────────────
# SUBIR ARCHIVOS
# ──────────────────────────────────────────
FILENAME=$(basename "$DUMP_FILE")
S3_PATH="s3://$S3_BUCKET/dumps/$FILENAME"

log "Subiendo $DUMP_FILE → $S3_PATH"
aws s3 cp "$DUMP_FILE" "$S3_PATH" \
  --storage-class STANDARD_IA \
  --no-progress

log "Dump subido ✓"

# Subir también schema si existe
SCHEMA_FILE=$(ls -t "$BACKUP_DIR"/*_schema_*.sql 2>/dev/null | head -1 || true)
if [ -n "$SCHEMA_FILE" ]; then
  log "Subiendo schema: $SCHEMA_FILE"
  aws s3 cp "$SCHEMA_FILE" "s3://$S3_BUCKET/dumps/$(basename $SCHEMA_FILE)"
fi

# ──────────────────────────────────────────
# VERIFICAR
# ──────────────────────────────────────────
log "Contenido del bucket:"
aws s3 ls "s3://$S3_BUCKET/dumps/" --human-readable

echo ""
echo "======================================"
log "UPLOAD COMPLETADO"
echo "======================================"
echo "  🪣 Bucket: s3://$S3_BUCKET/dumps/"
echo "  📦 Archivo: $FILENAME"
echo ""

# Guardar referencia del archivo en S3 para scripts siguientes
echo "$S3_PATH" > "$BACKUP_DIR/.last_s3_path"
log "Ruta S3 guardada en $BACKUP_DIR/.last_s3_path"
echo ""
echo "Próximo paso: bash scripts/03_create_rds.sh"
