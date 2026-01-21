# Escenario estudiante:
Integration Proxy: El API Gateway escribe directo a SQS. No usamos una Lambda para recibir el request ("Lambda Proxy") porque sería pagar cómputo solo para pasar un mensaje. Esto reduce el costo de ingesta en un ~40% y la latencia a <30ms.

Batching: La Lambda Worker procesa lotes de 50 mensajes. En lugar de hacer 5,000 escrituras por segundo a DynamoDB, hacemos 100 BatchWriteItem. Esto reduce drásticamente los Write Capacity Units (WCU) consumidos.

# Escenario profesor:
Por qué App Runner: A diferencia de Lambda, el contenedor mantiene la conexión a la base de datos abierta (TCP Keep-Alive) y las reglas de negocio en memoria RAM. Evitamos el costo de inicialización (Cold Start) en cada request interactivo.

Concurrency: App Runner maneja múltiples requests concurrentes por instancia, lo que es más eficiente para tráfico I/O bound que el modelo "una Lambda por request".