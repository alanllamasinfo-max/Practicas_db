# 🐘 Guía de Migración PostgreSQL → AWS RDS

Guía completa para exportar una base de datos PostgreSQL local y migrarla a Amazon RDS usando AWS Database Migration Service (DMS).

---

## 📋 Índice

1. [Requisitos previos](#-requisitos-previos)
2. [Fase 1: Export de la base de datos local](#-fase-1-export-de-la-base-de-datos-local)
3. [Fase 2: Crear instancia RDS en AWS](#-fase-2-crear-instancia-rds-en-aws)
4. [Fase 3: Configurar AWS DMS](#-fase-3-configurar-aws-dms)
5. [Fase 4: Importar el dump a RDS](#-fase-4-importar-el-dump-a-rds)
6. [Fase 5: Verificación y pruebas](#-fase-5-verificación-y-pruebas)
7. [Troubleshooting](#-troubleshooting)
8. [Checklist final](#-checklist-final)

---

## ✅ Requisitos previos

### Local
- PostgreSQL instalado (`pg_dump`, `psql`, `pg_restore`)
- AWS CLI instalado y configurado (`aws configure`)
- Acceso a la base de datos origen (usuario con permisos de lectura total)

### AWS
- Cuenta AWS activa
- IAM user/role con permisos sobre: RDS, DMS, S3, VPC, IAM
- Una VPC configurada (o usar la default)

### Verificar versiones

```bash
# Versión local de PostgreSQL
psql --version
pg_dump --version

# AWS CLI
aws --version
aws sts get-caller-identity  # Verificar credenciales
```

---

## 📦 Fase 1: Export de la base de datos local

### 1.1 Variables de entorno (ajusta a tu entorno)

```bash
# Configura estas variables antes de ejecutar cualquier comando
export DB_HOST="localhost"
export DB_PORT="5432"
export DB_NAME="nombre_de_tu_base_de_datos"
export DB_USER="tu_usuario"
export BACKUP_DIR="./backups"
export TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR
```

### 1.2 Export completo con pg_dump (formato custom — recomendado)

```bash
# Formato custom: comprimido, permite restauración paralela y selectiva
pg_dump \
  -h $DB_HOST \
  -p $DB_PORT \
  -U $DB_USER \
  -d $DB_NAME \
  -F c \
  -b \
  -v \
  -f "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump"
```

> **Flags:**
> - `-F c` → formato custom (binario comprimido)
> - `-b` → incluye blobs/large objects
> - `-v` → verbose (muestra progreso)

### 1.3 Export en formato SQL plano (alternativa)

```bash
# Útil si necesitas inspeccionar el dump manualmente
pg_dump \
  -h $DB_HOST \
  -p $DB_PORT \
  -U $DB_USER \
  -d $DB_NAME \
  -F p \
  --no-owner \
  --no-acl \
  -v \
  -f "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql"

# Comprimir el SQL
gzip "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql"
```

### 1.4 Export de schema únicamente (sin datos)

```bash
pg_dump \
  -h $DB_HOST \
  -p $DB_PORT \
  -U $DB_USER \
  -d $DB_NAME \
  -F p \
  --schema-only \
  -f "$BACKUP_DIR/${DB_NAME}_schema_${TIMESTAMP}.sql"
```

### 1.5 Verificar integridad del dump

```bash
# Listar contenido del dump (formato custom)
pg_restore --list "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump" | head -50

# Ver tamaño del archivo
ls -lh "$BACKUP_DIR/"
```

### 1.6 Subir el dump a S3 (para acceso desde AWS)

```bash
export S3_BUCKET="tu-bucket-migracion"
export AWS_REGION="eu-west-1"  # Cambia a tu región

# Crear bucket si no existe
aws s3 mb s3://$S3_BUCKET --region $AWS_REGION

# Subir el dump
aws s3 cp "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump" \
  s3://$S3_BUCKET/dumps/ \
  --storage-class STANDARD_IA

# Verificar subida
aws s3 ls s3://$S3_BUCKET/dumps/
```

---

## 🏗️ Fase 2: Crear instancia RDS en AWS

### 2.1 Crear subnet group para RDS

```bash
# Obtener IDs de subnets de tu VPC (o usar la default)
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXX" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone]' \
  --output table

# Crear DB Subnet Group
aws rds create-db-subnet-group \
  --db-subnet-group-name "migracion-subnet-group" \
  --db-subnet-group-description "Subnet group para migración PostgreSQL" \
  --subnet-ids subnet-XXXXXX subnet-YYYYYY
```

### 2.2 Crear Security Group para RDS

```bash
export VPC_ID="vpc-XXXXXXXX"  # Tu VPC ID

# Crear security group
SG_ID=$(aws ec2 create-security-group \
  --group-name "rds-postgres-sg" \
  --description "SG para RDS PostgreSQL" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

echo "Security Group ID: $SG_ID"

# Permitir acceso PostgreSQL (puerto 5432) desde tu IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 5432 \
  --cidr "$MY_IP/32"
```

### 2.3 Crear instancia RDS PostgreSQL

```bash
aws rds create-db-instance \
  --db-instance-identifier "mi-postgres-rds" \
  --db-instance-class db.t3.medium \
  --engine postgres \
  --engine-version "15.4" \
  --master-username adminuser \
  --master-user-password "CambiaEstaPassword123!" \
  --allocated-storage 20 \
  --max-allocated-storage 100 \
  --db-name $DB_NAME \
  --db-subnet-group-name "migracion-subnet-group" \
  --vpc-security-group-ids $SG_ID \
  --backup-retention-period 7 \
  --multi-az false \
  --no-publicly-accessible \
  --storage-type gp3 \
  --region $AWS_REGION
```

> ⚠️ Para producción, considera `--multi-az` y ajusta `--db-instance-class`.

### 2.4 Esperar a que RDS esté disponible

```bash
echo "Esperando que la instancia RDS esté disponible..."
aws rds wait db-instance-available \
  --db-instance-identifier "mi-postgres-rds"

# Obtener el endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "mi-postgres-rds" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "RDS Endpoint: $RDS_ENDPOINT"
```

---

## 🔄 Fase 3: Configurar AWS DMS

> DMS es útil para migraciones con mínimo downtime (replicación continua). Para un import simple desde dump, ve directamente a la Fase 4.

### 3.1 Crear Replication Instance

```bash
aws dms create-replication-instance \
  --replication-instance-identifier "mi-replication-instance" \
  --replication-instance-class dms.t3.medium \
  --allocated-storage 50 \
  --no-publicly-accessible \
  --replication-subnet-group-identifier "migracion-subnet-group" \
  --vpc-security-group-ids $SG_ID
```

### 3.2 Crear Source Endpoint (PostgreSQL local)

```bash
# Si tu BD local es accesible desde AWS (VPN o IP pública):
aws dms create-endpoint \
  --endpoint-identifier "source-postgres-local" \
  --endpoint-type source \
  --engine-name postgres \
  --server-name "TU_IP_PUBLICA_O_HOSTNAME" \
  --port 5432 \
  --database-name $DB_NAME \
  --username $DB_USER \
  --password "tu_password"
```

> ⚠️ Para conectar DMS a una BD local necesitas: IP pública + puerto abierto, o AWS Direct Connect / VPN.

### 3.3 Crear Target Endpoint (RDS)

```bash
aws dms create-endpoint \
  --endpoint-identifier "target-rds-postgres" \
  --endpoint-type target \
  --engine-name postgres \
  --server-name $RDS_ENDPOINT \
  --port 5432 \
  --database-name $DB_NAME \
  --username adminuser \
  --password "CambiaEstaPassword123!"
```

### 3.4 Crear y ejecutar Replication Task

```bash
# Obtener ARNs de los endpoints y la instancia de replicación
SOURCE_ARN=$(aws dms describe-endpoints \
  --filters Name=endpoint-id,Values=source-postgres-local \
  --query 'Endpoints[0].EndpointArn' --output text)

TARGET_ARN=$(aws dms describe-endpoints \
  --filters Name=endpoint-id,Values=target-rds-postgres \
  --query 'Endpoints[0].EndpointArn' --output text)

REPL_ARN=$(aws dms describe-replication-instances \
  --filters Name=replication-instance-id,Values=mi-replication-instance \
  --query 'ReplicationInstances[0].ReplicationInstanceArn' --output text)

# Crear la tarea de migración
aws dms create-replication-task \
  --replication-task-identifier "tarea-migracion-postgres" \
  --source-endpoint-arn $SOURCE_ARN \
  --target-endpoint-arn $TARGET_ARN \
  --replication-instance-arn $REPL_ARN \
  --migration-type full-load \
  --table-mappings '{"rules":[{"rule-type":"selection","rule-id":"1","rule-name":"1","object-locator":{"schema-name":"%","table-name":"%"},"rule-action":"include"}]}'

# Iniciar la tarea
TASK_ARN=$(aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=tarea-migracion-postgres \
  --query 'ReplicationTasks[0].ReplicationTaskArn' --output text)

aws dms start-replication-task \
  --replication-task-arn $TASK_ARN \
  --start-replication-task-type start-replication
```

---

## 📥 Fase 4: Importar el dump a RDS

> Este es el método más directo para importar el export de la Fase 1.

### 4.1 Importar con pg_restore (formato custom)

```bash
pg_restore \
  -h $RDS_ENDPOINT \
  -p 5432 \
  -U adminuser \
  -d $DB_NAME \
  -F c \
  -v \
  --no-owner \
  --no-acl \
  "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.dump"
```

### 4.2 Importar SQL plano (alternativa)

```bash
# Si usaste el export SQL
psql \
  -h $RDS_ENDPOINT \
  -p 5432 \
  -U adminuser \
  -d $DB_NAME \
  -f "$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql"
```

### 4.3 Importar desde S3 (si subiste el dump)

```bash
# Descargar primero desde S3
aws s3 cp \
  s3://$S3_BUCKET/dumps/${DB_NAME}_${TIMESTAMP}.dump \
  ./restore.dump

# Luego restaurar
pg_restore \
  -h $RDS_ENDPOINT \
  -p 5432 \
  -U adminuser \
  -d $DB_NAME \
  -F c \
  -j 4 \
  -v \
  --no-owner \
  --no-acl \
  ./restore.dump
```

> `-j 4` usa 4 workers paralelos para restauración más rápida.

---

## 🧪 Fase 5: Verificación y pruebas

### 5.1 Conectar a RDS y verificar

```bash
psql -h $RDS_ENDPOINT -p 5432 -U adminuser -d $DB_NAME
```

```sql
-- Listar todas las tablas
\dt

-- Contar filas por tabla
SELECT schemaname, tablename, n_live_tup AS filas
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;

-- Verificar tamaño de la base de datos
SELECT pg_size_pretty(pg_database_size(current_database()));

-- Verificar extensiones
SELECT * FROM pg_extension;
```

### 5.2 Comparar conteo de filas (origen vs destino)

```bash
# Script de verificación
cat << 'EOF' > verify_migration.sh
#!/bin/bash

echo "=== CONTEO EN ORIGEN (LOCAL) ==="
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME \
  -c "SELECT tablename, n_live_tup FROM pg_stat_user_tables ORDER BY tablename;"

echo ""
echo "=== CONTEO EN DESTINO (RDS) ==="
psql -h $RDS_ENDPOINT -p 5432 -U adminuser -d $DB_NAME \
  -c "SELECT tablename, n_live_tup FROM pg_stat_user_tables ORDER BY tablename;"
EOF

chmod +x verify_migration.sh
./verify_migration.sh
```

### 5.3 Verificar sequences, índices y constraints

```sql
-- Verificar sequences
SELECT sequence_name, last_value FROM information_schema.sequences;

-- Verificar índices
SELECT indexname, tablename FROM pg_indexes WHERE schemaname = 'public';

-- Verificar foreign keys
SELECT conname, conrelid::regclass AS tabla
FROM pg_constraint WHERE contype = 'f';
```

---

## 🔧 Troubleshooting

### Error: "connection refused" al conectar a RDS

- Verifica que el Security Group permite el puerto 5432 desde tu IP
- Confirma que `--publicly-accessible` está habilitado si conectas desde fuera de VPC
- Revisa que el RDS esté en estado `available`

```bash
aws rds describe-db-instances \
  --db-instance-identifier "mi-postgres-rds" \
  --query 'DBInstances[0].DBInstanceStatus'
```

### Error: "role does not exist" durante pg_restore

```bash
# Usar --no-owner y --no-acl en pg_restore (ya incluido arriba)
# O crear el rol manualmente:
psql -h $RDS_ENDPOINT -U adminuser -d $DB_NAME \
  -c "CREATE ROLE nombre_rol;"
```

### Error de versión de PostgreSQL

```bash
# La versión del cliente debe ser >= versión del servidor
# Instalar versión específica de PostgreSQL client:
# Ubuntu/Debian:
sudo apt-get install postgresql-client-15

# macOS:
brew install postgresql@15
```

### Dump muy lento o timeout

```bash
# Aumentar timeout de la conexión
export PGCONNECT_TIMEOUT=300

# Para dumps grandes, usar pg_dump con compresión paralela
pg_dump -j 4 -F d -f backup_dir/ ...  # Formato directory (soporta -j)
```

### Verificar logs de DMS

```bash
aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=tarea-migracion-postgres \
  --query 'ReplicationTasks[0].{Status:Status,StopReason:StopReason}'
```

---

## ✅ Checklist final

### Pre-migración
- [ ] Backup completo realizado y verificado
- [ ] Dump subido a S3
- [ ] Instancia RDS creada y `available`
- [ ] Security Groups configurados
- [ ] Conectividad a RDS verificada

### Durante migración
- [ ] pg_restore completado sin errores críticos
- [ ] Conteo de filas comparado (origen vs destino)
- [ ] Sequences verificados y correctos
- [ ] Índices y constraints verificados

### Post-migración
- [ ] Aplicación apunta al nuevo endpoint RDS
- [ ] Pruebas funcionales de la aplicación
- [ ] Monitorización activada (CloudWatch)
- [ ] Snapshot de RDS antes de go-live
- [ ] Plan de rollback documentado

---

## 📁 Estructura de archivos del proyecto

```
migracion-postgres-aws/
├── README.md                    # Esta guía
├── scripts/
│   ├── 01_export.sh             # Export de BD local
│   ├── 02_upload_s3.sh          # Subida a S3
│   ├── 03_create_rds.sh         # Creación de RDS
│   ├── 04_import.sh             # Import a RDS
│   └── 05_verify.sh             # Verificación
├── backups/                     # Dumps locales (no subir a git)
└── .gitignore
```

### .gitignore recomendado

```
backups/
*.dump
*.sql
.env
*.log
```

---

## 🔐 Seguridad

- **Nunca** subas passwords a Git. Usa variables de entorno o AWS Secrets Manager.
- Elimina el S3 bucket o aplica lifecycle rules después de la migración.
- Revoca el acceso público a RDS una vez completada la migración.
- Activa encryption at rest en RDS (`--storage-encrypted`).

```bash
# Usar AWS Secrets Manager para passwords
aws secretsmanager create-secret \
  --name "rds/postgres/adminuser" \
  --secret-string '{"password":"CambiaEstaPassword123!"}'
```

---

## 📚 Referencias

- [AWS RDS PostgreSQL Docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html)
- [AWS DMS User Guide](https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html)
- [pg_dump Documentation](https://www.postgresql.org/docs/current/app-pgdump.html)
- [pg_restore Documentation](https://www.postgresql.org/docs/current/app-pgrestore.html)
