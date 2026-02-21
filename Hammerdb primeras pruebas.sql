# 1. Cargamos el script de simulación de tienda (TPC-C)
loadscript

# 2. Le decimos que queremos simular 50 usuarios concurrentes, si este comando da error
# lanazamo vudestroy para que libere los usuarios que tiene en memoria
vuset vu 100

# 3. (Opcional) Mostramos el log en pantalla para ver qué pasa
vuset logtotemp 1

# 4. ¡Iniciamos el ataque!
vurun

# 5 Al finalizar la prueba si, no vaciamos las conexiones estas se mantendran ocupadas 
vudestroy
