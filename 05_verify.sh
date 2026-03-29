#!/bin/bash
# ============================================================
# 05_verify.sh - Verificación completa de la migración
# Compara origen (local) vs destino (RDS)
# Uso: bash 05_verify.sh
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ──────────────────────────────────────────
# CONFIGURACIÓN
# ──────────────────────────────────────────
[ -f ".rds_config" ] && source .rds_config

DB_HOST="${DB_HOST:-localhost}"
DB_PORT_SRC="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-nombre_de_tu_base_de_datos}"
DB_USER="${DB_USER:-postgres}"
RDS_ENDPOINT="${RDS_ENDPOINT:-}"
RDS_PORT="${RDS_PORT:-5432}"
RDS_MASTER_USER="${RDS_MASTER_USER:-adminuser}"

[ -z "$RDS_ENDPOINT" ] && fail "RDS_ENDPOINT no definido."

REPORT_FILE="./backups/migration_report_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p ./backups

# ──────────────────────────────────────────
# FUNCIONES DE CONSULTA
# ──────────────────────────────────────────
query_src() { psql -h "$DB_HOST" -p "$DB_PORT_SRC" -U "$DB_USER" -d "$DB_NAME" -t -c "$1" 2>/dev/null | xargs; }
query_dst() { psql -h "$RDS_ENDPOINT" -p "$RDS_PORT" -U "$RDS_MASTER_USER" -d "$DB_NAME" -t -c "$1" 2>/dev/null | xargs; }

check() {
  local name="$1"
  local src="$2"
  local dst="$3"
  if [ "$src" = "$dst" ]; then
    echo -e "  ${GREEN}✓${NC} $name: $src"
  else
    echo -e "  ${RED}✗${NC} $name — LOCAL: $src | RDS: $dst"
    ERRORS=$((ERRORS + 1))
  fi
}

ERRORS=0

# ──────────────────────────────────────────
# INICIO DEL REPORTE
# ──────────────────────────────────────────
{
echo "======================================"
echo "REPORTE DE VERIFICACIÓN DE MIGRACIÓN"
echo "Fecha: $(date)"
echo "Origen: $DB_HOST:$DB_PORT_SRC/$DB_NAME"
echo "Destino: $RDS_ENDPOINT:$RDS_PORT/$DB_NAME"
echo "======================================"
} | tee "$REPORT_FILE"

# ──────────────────────────────────────────
# 1. VERIFICAR CONEXIONES
# ──────────────────────────────────────────
section "1. CONEXIONES" | tee -a "$REPORT_FILE"

psql -h "$DB_HOST" -p "$DB_PORT_SRC" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" > /dev/null \
  && echo -e "  ${GREEN}✓${NC} Conexión LOCAL OK" | tee -a "$REPORT_FILE" \
  || { echo -e "  ${RED}✗${NC} Conexión LOCAL FALLÓ" | tee -a "$REPORT_FILE"; ERRORS=$((ERRORS+1)); }

psql -h "$RDS_ENDPOINT" -p "$RDS_PORT" -U "$RDS_MASTER_USER" -d "$DB_NAME" -c "SELECT 1" > /dev/null \
  && echo -e "  ${GREEN}✓${NC} Conexión RDS OK" | tee -a "$REPORT_FILE" \
  || { echo -e "  ${RED}✗${NC} Conexión RDS FALLÓ" | tee -a "$REPORT_FILE"; ERRORS=$((ERRORS+1)); fail "No se puede conectar a RDS"; }

# ──────────────────────────────────────────
# 2. TAMAÑO DE LA BASE DE DATOS
# ──────────────────────────────────────────
section "2. TAMAÑO DE LA BASE DE DATOS" | tee -a "$REPORT_FILE"

SRC_SIZE=$(query_src "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));")
DST_SIZE=$(query_dst "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));")
echo "  LOCAL: $SRC_SIZE  |  RDS: $DST_SIZE" | tee -a "$REPORT_FILE"

# ──────────────────────────────────────────
# 3. CONTEO DE TABLAS
# ──────────────────────────────────────────
section "3. NÚMERO DE TABLAS" | tee -a "$REPORT_FILE"

SRC_TABLES=$(query_src "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")
DST_TABLES=$(query_dst "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")
check "Número de tablas" "$SRC_TABLES" "$DST_TABLES" | tee -a "$REPORT_FILE"

# ──────────────────────────────────────────
# 4. CONTEO DE FILAS POR TABLA
# ──────────────────────────────────────────
section "4. CONTEO DE FILAS POR TABLA" | tee -a "$REPORT_FILE"

TABLES=$(query_src "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;")

printf "%-35s %-15s %-15s %-10s\n" "TABLA" "LOCAL" "RDS" "ESTADO" | tee -a "$REPORT_FILE"
printf "%-35s %-15s %-15s %-10s\n" "-----" "-----" "---" "------" | tee -a "$REPORT_FILE"

for TABLE in $TABLES; do
  SRC_COUNT=$(query_src "SELECT COUNT(*) FROM \"$TABLE\";")
  DST_COUNT=$(query_dst "SELECT COUNT(*) FROM \"$TABLE\";" 2>/dev/null || echo "ERROR")
  
  if [ "$SRC_COUNT" = "$DST_COUNT" ]; then
    STATUS="${GREEN}✓ OK${NC}"
  else
    STATUS="${RED}✗ DIFF${NC}"
    ERRORS=$((ERRORS + 1))
  fi
  
  printf "%-35s %-15s %-15s " "$TABLE" "$SRC_COUNT" "$DST_COUNT" | tee -a "$REPORT_FILE"
  echo -e "$STATUS" | tee -a "$REPORT_FILE"
done

# ──────────────────────────────────────────
# 5. ÍNDICES
# ──────────────────────────────────────────
section "5. ÍNDICES" | tee -a "$REPORT_FILE"

SRC_IDX=$(query_src "SELECT COUNT(*) FROM pg_indexes WHERE schemaname='public';")
DST_IDX=$(query_dst "SELECT COUNT(*) FROM pg_indexes WHERE schemaname='public';")
check "Número de índices" "$SRC_IDX" "$DST_IDX" | tee -a "$REPORT_FILE"

# ──────────────────────────────────────────
# 6. SECUENCIAS
# ──────────────────────────────────────────
section "6. SECUENCIAS" | tee -a "$REPORT_FILE"

SRC_SEQ=$(query_src "SELECT COUNT(*) FROM information_schema.sequences WHERE sequence_schema='public';")
DST_SEQ=$(query_dst "SELECT COUNT(*) FROM information_schema.sequences WHERE sequence_schema='public';")
check "Número de secuencias" "$SRC_SEQ" "$DST_SEQ" | tee -a "$REPORT_FILE"

# ──────────────────────────────────────────
# 7. EXTENSIONES
# ──────────────────────────────────────────
section "7. EXTENSIONES" | tee -a "$REPORT_FILE"

echo "  LOCAL:" | tee -a "$REPORT_FILE"
psql -h "$DB_HOST" -p "$DB_PORT_SRC" -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;" | tee -a "$REPORT_FILE"

echo "  RDS:" | tee -a "$REPORT_FILE"
psql -h "$RDS_ENDPOINT" -p "$RDS_PORT" -U "$RDS_MASTER_USER" -d "$DB_NAME" \
  -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;" | tee -a "$REPORT_FILE"

# ──────────────────────────────────────────
# 8. RESUMEN FINAL
# ──────────────────────────────────────────
section "RESUMEN FINAL" | tee -a "$REPORT_FILE"

if [ "$ERRORS" -eq 0 ]; then
  echo -e "  ${GREEN}✅ MIGRACIÓN VERIFICADA — Sin errores detectados${NC}" | tee -a "$REPORT_FILE"
else
  echo -e "  ${RED}❌ MIGRACIÓN CON ERRORES — $ERRORS diferencias encontradas${NC}" | tee -a "$REPORT_FILE"
fi

echo ""
echo "  📄 Reporte guardado en: $REPORT_FILE"
echo ""

exit $ERRORS
