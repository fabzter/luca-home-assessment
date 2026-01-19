# ADR-006: EventBridge Pipes para Data Pipeline

---

## Contexto y Problema

El sistema debe mantener un data lake con historial completo de cambios para:
- **Trazabilidad completa desde source hasta analytics** para auditorías (quién modificó qué y cuándo)
- Análisis de tendencias (comportamiento estudiantil a lo largo del tiempo)  
- Queries analíticos complejos (SQL sobre datos históricos)
- **Data lineage** completa para compliance reviews
- Backup cold storage (retención 3 años compliance)

DynamoDB Streams captura todos los cambios, pero necesitamos:
- Filtrar eventos irrelevantes (solo INSERT/MODIFY, no DELETE de TTL)
- Transformar formato (DynamoDB JSON → Parquet)
- Agrupar en archivos (buffering)
- Escribir a S3 en particiones optimizadas

## Decisión

**EventBridge Pipes conectando DynamoDB Streams → Kinesis Firehose → S3:**

```
DynamoDB Streams
  ↓ (change events)
EventBridge Pipes
  ↓ (filter: eventName IN ['INSERT', 'MODIFY'])
  ↓ (transform: DynamoDB JSON → simplified JSON)
Kinesis Firehose
  ↓ (buffer: 5 MB or 60 seconds)
  ↓ (convert: JSON → Parquet)
S3
  └── year=2024/month=01/school_id=123/data.parquet
```

## Alternativas Consideradas

### Alternativa A: Lambda leyendo DynamoDB Streams
**Descripción:** Lambda triggered por DynamoDB Streams, procesa batch, escribe a Firehose/S3.

**Pros:**
- Flexibilidad total en transformación
- Lógica custom (ej: enriquecer con datos externos)
- Debugging familiar (logs de Lambda)
- Control fino sobre batching

**Contras:**
- **Código custom:** 100+ líneas de código que mantener
- **Error handling manual:** Retries, DLQ, idempotency en código
- **Throttling risk:** Lambda puede quedarse atrás si stream tiene spike
- **Costo adicional:** Lambda invocations + duration
- **Testing:** Requiere integration tests con mocks de Streams

**Complejidad típica:**
```javascript
exports.handler = async (event) => {
  const records = event.Records
    .filter(r => ['INSERT', 'MODIFY'].includes(r.eventName))
    .map(r => transformDynamoDBToJSON(r.dynamodb.NewImage));
  
  // Chunking para Firehose (max 500 records/batch)
  const chunks = chunkArray(records, 500);
  
  for (const chunk of chunks) {
    await firehose.putRecordBatch({
      DeliveryStreamName: 'luca-data-stream',
      Records: chunk.map(r => ({ Data: JSON.stringify(r) }))
    });
  }
  
  // Faltan: retries, DLQ, monitoring, error handling
};
```

**Por qué se descartó:** Reinventa primitivas que EventBridge Pipes provee sin código.

---

### Alternativa B: Kinesis Data Streams + Lambda
**Descripción:** DynamoDB Streams → Kinesis Data Streams → Lambda → S3.

**Pros:**
- Kinesis Data Streams tiene mejor throughput que Firehose
- Múltiples consumers posibles
- Replay capability (retención 7 días)

**Contras:**
- **Costo:** Kinesis Data Streams ~$0.015/shard-hour = $11/mes mínimo (1 shard)
- **Capacity planning:** Necesita calcular shards necesarios
- **Complejidad adicional:** Un servicio más en la cadena
- **Overhead:** DynamoDB Streams ya provee ordering y low-latency
- **Lambda aún necesaria:** Transformación y escritura a S3

**Por qué se descartó:** Over-engineering para throughput que DynamoDB Streams ya maneja.

---

### Alternativa C: Lambda escribiendo directamente a S3
**Descripción:** Lambda lee Streams, agrupa en memoria, escribe Parquet a S3.

**Pros:**
- Control total sobre formato de archivo
- Partitioning custom
- Compresión optimizada

**Contras:**
- **Memory limits:** Lambda tiene max 10 GB, difícil buffering grande
- **Complejidad:** Implementar Parquet writer en Lambda (librerías pesadas)
- **Cold starts:** Parquet libs aumentan init time
- **Orchestration:** Necesita lógica para decidir cuándo "cerrar" archivo
- **Durability:** Si Lambda falla mid-batch, datos en memoria se pierden

**Por qué se descartó:** Firehose maneja buffering y conversión a Parquet nativamente.

---

### Alternativa D: Glue ETL Job
**Descripción:** DynamoDB export to S3 (daily) + Glue ETL convierte a Parquet.

**Pros:**
- Procesamiento batch eficiente
- Glue optimizado para transformaciones grandes
- Formato Parquet optimizado

**Contras:**
- **Latency:** Exports son snapshot diarios, no near real-time
- **Costo:** Export ~$0.10/GB + Glue DPU ~$0.44/DPU-hour
- **Complejidad:** Requiere scheduler + Glue jobs + S3 staging
- **No incremental:** Cada export es full table (desperdicio)

**Por qué se descartó:** Necesitamos near real-time para auditoría, no batch diario.

---

## Comparación de Alternativas

| Criterio              | EventBridge Pipes (Decisión) | Lambda Streams | Kinesis + Lambda | Lambda → S3 | Glue ETL |
|-----------------------|------------------------------|----------------|------------------|-------------|----------|
| Código custom         | Zero (Aceptable)             | ~150 líneas (No) | ~200 líneas (No) | ~300 líneas (No) | SQL/Python (Condicional) |
| Latencia              | <2 min (Aceptable)           | <1 min (Aceptable) | <1 min (Aceptable) | <1 min (Aceptable) | 24 h (No) |
| Costo mensual         | ~$5 (Aceptable)              | ~$8 (Aceptable) | ~$19 (No)        | ~$10 (Aceptable) | ~$30 (No) |
| Complejidad Ops       | Baja (Aceptable)             | Media (Condicional) | Alta (No) | Alta (No)  | Media (Condicional) |
| Conversión Parquet    | Firehose nativo (Aceptable)  | Firehose nativo (Condicional) | Custom (No) | Custom (No) | Nativo (Aceptable) |
| Buffering             | Firehose (Aceptable)         | Manual (Condicional) | Manual (Condicional) | Memory-bound (No) | Batch (Aceptable) |

## Justificación

**EventBridge Pipes + Firehose es óptimo porque:**

1. **Zero Code Pipeline:**
   - Filtro: Configuración JSON (no código)
   - Transformación: Built-in transformers
   - Buffering: Firehose config (size/time)
   - Parquet: Firehose schema conversion

2. **Managed Scaling:**
   - Pipes escala automáticamente con Streams throughput
   - Firehose escala sin shards ni capacity planning
   - Sin throttling risk

3. **Built-in Reliability:**
   - Pipes tiene retry automático
   - Firehose tiene S3 backup bucket para fallas
   - DLQ automático para transformaciones que fallan

4. **Costo Optimizado:**
   ```
   EventBridge Pipes: ~200K events/mes × $0.0000004 = $0.08
   Kinesis Firehose: 200K records × $0.029/10K = $0.58
   S3 Storage: 50 GB × $0.023 = $1.15
   Total: ~$2/mes
   
   vs Lambda approach: ~$8/mes
   ```

5. **Observability:**
   - CloudWatch metrics automáticas (records processed, failed, latency)
   - CloudWatch Logs para cada stage
   - No logging boilerplate en código

6. **Parquet Optimization:**
   Firehose convierte JSON → Parquet automáticamente:
   - Define schema una vez
   - Compresión Snappy
   - Partitioning por fecha automático

## Configuración

### EventBridge Pipe:

```json
{
  "Name": "dynamodb-to-datalake",
  "Source": "arn:aws:dynamodb:...:table/luca-platform/stream/...",
  "Target": "arn:aws:firehose:...:deliverystream/luca-data-stream",
  "SourceParameters": {
    "DynamoDBStreamParameters": {
      "StartingPosition": "LATEST",
      "BatchSize": 100,
      "MaximumBatchingWindowInSeconds": 10
    },
    "FilterCriteria": {
      "Filters": [{
        "Pattern": "{\"eventName\": [\"INSERT\", \"MODIFY\"]}"
      }]
    }
  },
  "Enrichment": "arn:aws:lambda:...:function:transform-dynamodb-record",
  "TargetParameters": {
    "FirehoseParameters": {
      "DeliveryStreamName": "luca-data-stream"
    }
  }
}
```

### Firehose Configuration:

```json
{
  "DeliveryStreamName": "luca-data-stream",
  "ExtendedS3DestinationConfiguration": {
    "BucketARN": "arn:aws:s3:::luca-data-lake",
    "Prefix": "events/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/",
    "BufferingHints": {
      "SizeInMBs": 128,
      "IntervalInSeconds": 300
    },
    "CompressionFormat": "UNCOMPRESSED",
    "DataFormatConversionConfiguration": {
      "SchemaConfiguration": {
        "DatabaseName": "luca_analytics",
        "TableName": "events"
      },
      "InputFormatConfiguration": {
        "Deserializer": { "OpenXJsonSerDe": {} }
      },
      "OutputFormatConfiguration": {
        "Serializer": {
          "ParquetSerDe": {
            "Compression": "SNAPPY"
          }
        }
      }
    }
  }
}
```

### Transform Lambda (si necesario):

Esta función normaliza el payload para Firehose. Ejemplo mínimo:

```javascript
exports.handler = async (event) => event.records.map(r => normalize(r));
```

## Consecuencias

### Positivas
- **Mantenimiento zero:** No código de infra que mantener
- **Escalabilidad:** Auto-scaling sin configuración
- **Costo óptimo:** Pay-per-use sin overhead
- **Parquet nativo:** Queries SQL eficientes en Athena
- **Partitioning automático:** S3 paths optimizados para queries

### Negativas
- **Transformación limitada:** Pipes transformer tiene restricciones
  - Si necesitas lógica compleja, requiere Lambda en Enrichment step
- **Debugging:** Menos control que código custom
- **Schema changes:** Cambiar schema Parquet requiere Glue update
- **Vendor lock-in:** Específico de AWS

### Mitigaciones
- **Lambda enrichment:** Para transformaciones complejas (pero mantener simple)
- **Schema versioning:** Glue schema registry para backward compatibility
- **Monitoring:** CloudWatch alarms en Firehose delivery errors
- **Testing:** LocalStack o mocks para integration tests
