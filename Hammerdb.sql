--Desde centos vamos a creauna base de datos nueva el programa Hammerdb
create database tienda_tpcc;

----descarga del programa como usuario con privilegios 
sudo dnf install wget tar -y
wget https://github.com/TPC-Council/HammerDB/releases/download/v5.0/HammerDB-5.0-Prod-Lin-RHEL8.tar.gz
tar -xzvf HammerDB-5.0-Prod-Lin-RHEL8.tar.gz
cd HammerDB-5.0/
./hammerdbcli


------Configurar y construir el esquema
// 1. Le decimos que el motor es PostgreSQL
dbset db pg

// 2. Configuramos la conexión
diset connection pg_host localhost
diset connection pg_port 5432

// 3. Le pasamos las credenciales y la base de datos que creamos
diset tpcc pg_user postgres
diset tpcc pg_pass TU_CONTRASEÑA_AQUI
diset tpcc pg_dbase tienda_tpcc

// 4. Configuramos el tamaño de la prueba (10 almacenes es un buen tamaño inicial)
diset tpcc pg_count_ware 10
diset tpcc pg_num_vu 4

// 5. ¡Iniciamos la construcción!
buildschema
