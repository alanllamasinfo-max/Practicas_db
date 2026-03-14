🚀 DB Performance Testing: HammerDB + PostgreSQL Analysis
Este repositorio contiene una guía práctica y scripts para realizar pruebas de estrés (Benchmarking) sobre PostgreSQL 17 utilizando HammerDB, además de la configuración necesaria para auditar y detectar cuellos de botella en el motor mediante pg_stat_statements.

📋 Contenido del Proyecto
Configuración del Entorno: Instalación de HammerDB en RHEL/CentOS.

Preparación de la DB: Configuración del motor PostgreSQL para auditoría.

Ejecución de Stress Test: Comandos CLI para simular carga TPC-C.

Análisis de Resultados: Queries para detectar las consultas más lentas y el uso de caché.

🛠️ 1. Instalación y Configuración de HammerDB
Ejecuta estos comandos en tu servidor (RHEL/CentOS) para descargar y preparar la herramienta de benchmarking:

🏗️ 2. Construcción del Esquema (Build Schema)
Dentro de hammerdbcli, configura la conexión y crea la base de datos de prueba:


📊 3. Monitoreo de Rendimiento (PostgreSQL)
Para analizar qué sucede durante el estrés, habilitamos la extensión pg_stat_statements. Esto nos permite ver el tiempo de ejecución real y el Cache Hit Ratio.


Query de Detección de Cuellos de Botella
Esta consulta filtra el ruido de herramientas externas (DBeaver/pgAdmin) y se enfoca en las tablas de la simulación:

⚡ 4. Ejecución de la Simulación
Una vez construido el esquema y configurado el monitoreo, lanza la carga de usuarios:

