#!/bin/bash
# ============================================================
# 01_export.sh - Export completo de PostgreSQL local
# Uso: bash 01_export.sh
# ============================================================

set -euo pipefail

# ──────────────────────────────────────────
# CONFIGURACIÓN — edita estas variables
# ──────────────────────────────────────────
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-nombre_de_tu_base_de_datos}"
DB_USER="${DB_USER:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ──────────────────────────────────────────
# COLORES
# ──────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ──────────────────────────────────────────
# VERIFICACIONES
# ──────────────────────────────────────────
log "Verificando dependencias..."
command -v pg_dump  >/dev/null || fail "pg_dump no encontrado. Instala postgresql-client."
command -v psql     >/dev/null || fail "psql no encontrado."

log "Creando directorio de backups: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# ──────────────────────────────────────────
# VERIFICAR CONEXIÓN
# ──────────────────────────────────────────
log "Verificando conexión a $DB_HOST:$DB_PORT/$DB_NAME..."
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT version();" > /dev/null \
  || fail "No se puede conectar a la base de datos. Verifica las credenciales."
log "Conexión OK ✓"

# ──────────────────────────────────────────
# INFORMACIÓN PREVIA AL DUMP
# ──────────────────────────────────────────
log "Información de la base de datos:"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT schemaname, tablename, n_live_tup AS filas
   FROM pg_stat_user_tables
   ORDER BY n_live_tup DESC
   LIMIT 20;"

DB_SIZE=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c \
  "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" | xargs)
log "Tamaño actual de la BD: $DB_SIZE"

# ──────────────────────────────────────────
# DUMP FORMATO CUSTOM (recomendado)
# ──────────────────────────────────────────
DUMP_FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump"
log "Iniciando dump formato custom → $DUMP_FILE"

pg_dump \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -F c \
  -b \
  -v \
  -f "$DUMP_FILE"

log "Dump custom completado ✓"

# ──────────────────────────────────────────
# DUMP FORMATO SQL PLANO (como backup extra)
# ──────────────────────────────────────────
SQL_FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql"
log "Generando dump SQL plano → ${SQL_FILE}.gz"

pg_dump \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -F p \
  --no-owner \
  --no-acl \
  -f "$SQL_FILE"

gzip "$SQL_FILE"
log "Dump SQL comprimido ✓"

# ──────────────────────────────────────────
# DUMP SOLO SCHEMA
# ──────────────────────────────────────────
SCHEMA_FILE="$BACKUP_DIR/${DB_NAME}_schema_${TIMESTAMP}.sql"
log "Generando dump de schema → $SCHEMA_FILE"

pg_dump \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -F p \
  --schema-only \
  --no-owner \
  --no-acl \
  -f "$SCHEMA_FILE"

log "Dump de schema completado ✓"

# ──────────────────────────────────────────
# VERIFICAR INTEGRIDAD
# ──────────────────────────────────────────
log "Verificando integridad del dump..."
OBJECT_COUNT=$(pg_restore --list "$DUMP_FILE" | wc -l)
log "Objetos en el dump: $OBJECT_COUNT"
pg_restore --list "$DUMP_FILE" | head -20

# ──────────────────────────────────────────
# RESUMEN
# ──────────────────────────────────────────
echo ""
echo "======================================"
log "EXPORT COMPLETADO"
echo "======================================"
echo ""
ls -lh "$BACKUP_DIR/"
echo ""
echo "Archivos generados:"
echo "  📦 Dump custom:  $DUMP_FILE"
echo "  📄 Dump SQL:     ${SQL_FILE}.gz"
echo "  🏗️  Schema:       $SCHEMA_FILE"
echo ""
echo "Próximo paso: bash scripts/02_upload_s3.sh"
