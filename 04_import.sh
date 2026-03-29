#!/bin/bash
# ============================================================
# 04_import.sh - Importar dump a RDS PostgreSQL
# Uso: bash 04_import.sh [archivo_dump]
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ──────────────────────────────────────────
# CARGAR CONFIG DE RDS (generada por 03_create_rds.sh)
# ──────────────────────────────────────────
[ -f ".rds_config" ] && source .rds_config || {
  warn "No se encontró .rds_config. Usando variables de entorno."
  RDS_ENDPOINT="${RDS_ENDPOINT:-}"
  RDS_PORT="${RDS_PORT:-5432}"
  RDS_MASTER_USER="${RDS_MASTER_USER:-adminuser}"
  DB_NAME="${DB_NAME:-nombre_de_tu_base_de_datos}"
}

[ -z "$RDS_ENDPOINT" ] && fail "RDS_ENDPOINT no definido. Ejecuta primero 03_create_rds.sh"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
DUMP_FILE="${1:-}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

# ──────────────────────────────────────────
# SELECCIONAR DUMP
# ──────────────────────────────────────────
if [ -z "$DUMP_FILE" ]; then
  DUMP_FILE=$(ls -t "$BACKUP_DIR"/*.dump 2>/dev/null | head -1)
  [ -z "$DUMP_FILE" ] && fail "No se encontró .dump en $BACKUP_DIR. Pasa el archivo como argumento."
  warn "Usando dump más reciente: $DUMP_FILE"
fi

[ -f "$DUMP_FILE" ] || fail "Archivo no encontrado: $DUMP_FILE"

# ──────────────────────────────────────────
# VERIFICAR CONEXIÓN A RDS
# ──────────────────────────────────────────
log "Verificando conexión a RDS: $RDS_ENDPOINT"
psql -h "$RDS_ENDPOINT" -p "$RDS_PORT" -U "$RDS_MASTER_USER" -d "$DB_NAME" \
  -c "SELECT version();" > /dev/null \
  || fail "No se puede conectar a RDS. Verifica endpoint, credenciales y Security Group."
log "Conexión a RDS OK ✓"

# ──────────────────────────────────────────
# SNAPSHOT ANTES DE IMPORTAR (buena práctica)
# ──────────────────────────────────────────
if [ -n "${RDS_IDENTIFIER:-}" ]; then
  SNAP_ID="${RDS_IDENTIFIER}-pre-import-$(date +%Y%m%d%H%M%S)"
  log "Creando snapshot pre-import: $SNAP_ID"
  aws rds create-db-snapshot \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --db-snapshot-identifier "$SNAP_ID" \
    --region "${AWS_REGION:-eu-west-1}" > /dev/null
  log "Snapshot iniciado (se completa en background): $SNAP_ID"
fi

# ──────────────────────────────────────────
# IMPORTAR CON pg_restore
# ──────────────────────────────────────────
log "Iniciando restauración desde: $DUMP_FILE"
log "Usando $PARALLEL_JOBS workers paralelos"

START_TIME=$(date +%s)

pg_restore \
  -h "$RDS_ENDPOINT" \
  -p "$RDS_PORT" \
  -U "$RDS_MASTER_USER" \
  -d "$DB_NAME" \
  -F c \
  -j "$PARALLEL_JOBS" \
  -v \
  --no-owner \
  --no-acl \
  "$DUMP_FILE" 2>&1 | tee /tmp/restore_log.txt || {
    warn "pg_restore terminó con advertencias (puede ser normal). Revisa /tmp/restore_log.txt"
  }

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
log "Restauración completada en ${ELAPSED}s ✓"

# ──────────────────────────────────────────
# VERIFICACIÓN BÁSICA
# ──────────────────────────────────────────
log "Verificando datos importados..."

psql -h "$RDS_ENDPOINT" -p "$RDS_PORT" -U "$RDS_MASTER_USER" -d "$DB_NAME" << 'EOSQL'
\echo '--- Tablas y conteo de filas ---'
SELECT schemaname, tablename, n_live_tup AS filas
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 30;

\echo ''
\echo '--- Tamaño de la base de datos ---'
SELECT pg_size_pretty(pg_database_size(current_database())) AS tamaño_total;

\echo ''
\echo '--- Número de objetos por tipo ---'
SELECT object_type, count
FROM (
  SELECT 'tablas'     AS object_type, COUNT(*) AS count FROM information_schema.tables    WHERE table_schema = 'public'
  UNION ALL
  SELECT 'índices',                   COUNT(*)            FROM pg_indexes                 WHERE schemaname = 'public'
  UNION ALL
  SELECT 'secuencias',                COUNT(*)            FROM information_schema.sequences WHERE sequence_schema = 'public'
  UNION ALL
  SELECT 'funciones',                 COUNT(*)            FROM information_schema.routines  WHERE routine_schema = 'public'
) t;
EOSQL

echo ""
echo "======================================"
log "IMPORT COMPLETADO"
echo "======================================"
echo "  🗄️  RDS Endpoint: $RDS_ENDPOINT"
echo "  ⏱️  Tiempo total: ${ELAPSED}s"
echo "  📋 Log completo: /tmp/restore_log.txt"
echo ""
echo "Próximo paso: bash scripts/05_verify.sh"
