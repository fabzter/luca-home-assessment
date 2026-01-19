# ADR-008: SQS para Ingesta de Alto Volumen

---

## Contexto y Problema

El sistema recibe eventos de comportamiento estudiantil (asistencia, participación, actividades completadas) con perfil de tráfico:
- **Picos:** ~5,000 RPS durante clases activas (09:00-12:00)
- **Valle:** <100 RPS durante breaks y fuera de horario
- **Volumen diario:** ~10M eventos
- **Latencia aceptable:** Eventual consistency (no necesita ser síncrono)

Necesitamos:
- Absorber picos sin throttling
- Procesar eficientemente en batch
- Proteger DynamoDB de spikes
- Costo proporcional al uso

## Decisión

**API Gateway → SQS (direct integration) → Lambda (batch processor):**

1. API Gateway expone `/behavior` endpoint
2. Direct integration con SQS (sin Lambda intermedia)
3. SQS actúa como buffer elástico
4. Lambda consume batches de 50 mensajes
5. `BatchWriteItem` a DynamoDB (25 items por call)

## Alternativas Consideradas

### Alternativa A: API Gateway → Lambda → DynamoDB directamente
**Descripción:** Lambda sincrónica procesa cada request individual.

**Pros:**
- Arquitectura simple (menos componentes)
- Latencia mínima (sin queueing)
- Debugging directo (logs en Lambda)

**Contras:**
- **Throttling risk:** Lambda concurrency limit (1000 default)
  - 5,000 RPS → 5,000 Lambdas concurrentes (excede límite)
- **DynamoDB pressure:** 5,000 writes/sec sin batching
- **Costo:** 10M invocations × $0.20/1M = $2.00/mes
  - vs SQS: $0.40/mes
- **Cold starts:** Spikes causan cold starts masivos

**Por qué se descartó:** No escala para 5,000 RPS; excede concurrency limits.

---

### Alternativa B: Kinesis Data Streams
**Descripción:** API Gateway → Lambda → Kinesis → Lambda → DynamoDB.

**Pros:**
- Alta throughput (MB/sec por shard)
- Ordering garantizado por partition key
- Replay capability (retención 7 días)
- Múltiples consumers posibles

**Contras:**
- **Costo fijo:** $0.015/shard-hour × 10 shards × 730 hrs = $110/mes
- **Capacity planning:** Calcular shards necesarios
  - 5,000 RPS × 1 KB avg = 5 MB/sec
  - 1 shard = 1 MB/sec → necesita 5 shards mínimo
- **Complejidad:** Requiere Lambda intermedia para escribir a Kinesis
- **Over-provisioning:** Shards corren 24/7 aunque tráfico sea spiky

**Por qué se descartó:** Costo fijo inaceptable para tráfico spiky; over-engineering.

---

### Alternativa C: EventBridge
**Descripción:** API Gateway → EventBridge → targets (Lambda, DynamoDB).

**Pros:**
- Event routing flexible
- Múltiples targets
- Event replay
- Schema registry

**Contras:**
- **Costo:** $1.00/1M events (5x más caro que SQS)
  - 10M events/mes = $10/mes vs SQS $0.40/mes
- **No batching nativo:** Requiere Lambda para agrupar writes
- **Overkill:** No necesitamos routing complejo (un solo target)

**Por qué se descartó:** 25x más caro que SQS sin beneficios para este use case.

---

### Alternativa D: DynamoDB On-Demand sin Queue
**Descripción:** API Gateway → Lambda → DynamoDB directo, confiando en On-Demand scaling.

**Pros:**
- Arquitectura más simple
- DynamoDB On-Demand escala automáticamente
- Latencia menor (sin queueing)

**Contras:**
- **Throttling temporal:** On-Demand escala reactivamente
  - Puede tardar minutos en escalar de 100 RPS → 5,000 RPS
  - Primeros requests pueden recibir `ProvisionedThroughputExceededException`
- **Burst absorption:** Sin buffer para absorber spikes
- **No batching:** Cada write individual (ineficiente)
- **Lambda concurrency:** Aún necesita 5,000 Lambdas concurrentes

**Por qué se descartó:** On-Demand scaling no es instantáneo; risk de throttling.

---

### Alternativa E: SQS FIFO Queue
**Descripción:** SQS FIFO en lugar de Standard.

**Pros:**
- Ordering garantizado
- Exactly-once processing
- Message deduplication

**Contras:**
- **Throughput limitado:** 300 TPS por FIFO queue (3,000 con batching)
  - Incompatible con 5,000 RPS
- **Costo:** 3x más caro que Standard
- **Ordering innecesario:** Eventos de comportamiento son independientes

**Por qué se descartó:** Throughput insuficiente; features innecesarias.

---

## Comparación de Alternativas

| Criterio              | SQS Std (Decisión) | Lambda Direct | Kinesis | EventBridge | DDB Direct | SQS FIFO |
|-----------------------|--------------------|---------------|---------|-------------|------------|----------|
| Max throughput        | Ilimitado (Aceptable) | 1 000 (No) | 5 MB/s (Aceptable) | Alto (Aceptable) | Gradual (Condicional) | 3 000 TPS (No) |
| Costo mensual         | $0.40 (Aceptable)  | $2.00 (Aceptable) | $110 (No) | $10 (No) | $1.50 (Condicional) | $1.20 (Condicional) |
| Batching              | Nativo (Aceptable) | Manual (No)  | Nativo (Aceptable) | Manual (No) | No (No) | Nativo (Aceptable) |
| Buffer capacity       | Sí (Aceptable)     | No (No)      | Sí (Aceptable) | Limitado (Condicional) | No (No) | Sí (Aceptable) |
| Complejidad Ops       | Baja (Aceptable)   | Baja (Aceptable) | Alta (No) | Media (Condicional) | Baja (Aceptable) | Media (Condicional) |
| Cold-start impact     | Mínimo (Aceptable) | Alto (No)    | Mínimo (Aceptable) | Medio (Condicional) | Alto (No) | Mínimo (Aceptable) |

## Justificación

**SQS Standard es óptimo porque:**

1. **API Gateway Direct Integration:**
   ```json
   // API Gateway Integration Request
   {
     "Action": "SendMessage",
     "MessageBody": "$input.body",
     "QueueUrl": "https://sqs.us-east-1.amazonaws.com/.../behavior-queue"
   }
   ```
   Zero Lambda entre API Gateway y SQS = elimina hop, reduce costo.

2. **Buffer Anti-Stampede:**
   - SQS absorbe spike de 5,000 RPS sin problemas
   - Lambda procesa a ritmo constante controlado
   - DynamoDB no recibe spike directo

3. **Batch Processing Eficiente:**
   ```javascript
   exports.handler = async (event) => {
     // Lambda recibe max 50 mensajes
     const events = event.Records.map(r => JSON.parse(r.body));
     
     // BatchWriteItem acepta max 25 items
     const chunks = chunkArray(events, 25);
     
     for (const chunk of chunks) {
       await db.batchWriteItem({
         RequestItems: {
           'luca-platform': chunk.map(e => ({
             PutRequest: { Item: transformEvent(e) }
           }))
         }
       });
     }
   };
   ```
   50 eventos procesados en 2 `BatchWriteItem` calls vs 50 `PutItem` individuales.

4. **Costo Optimizado:**
   ```
   SQS Standard:
   - 10M requests/mes × $0.40/1M = $0.40
   - Negligible data transfer
   
   Lambda processing:
   - 10M events / 50 batch = 200K invocations
   - 200K × $0.20/1M = $0.04
   - 200K × 2 sec × 512 MB × $0.0000166667 = $0.33
   
   DynamoDB writes:
   - 10M writes × $0.00000125 = $12.50
   
   Total: ~$13/mes
   
   vs Lambda direct: ~$15/mes + throttling risk
   vs Kinesis: ~$123/mes
   ```

5. **Auto-Scaling:**
   - SQS: unlimited queue depth
   - Lambda: escala de 0 a N workers automáticamente
   - DynamoDB On-Demand: absorbe writes graduales

6. **Failure Handling:**
   - SQS visibility timeout: mensaje reintetado si Lambda falla
   - Dead Letter Queue: mensajes que fallan después de 3 intentos
   - CloudWatch alarmas en DLQ depth

## Configuración

### API Gateway Integration

La API pública recibe eventos JSON y, mediante integración **AWS Service**, mapea la solicitud HTTP directamente a la acción `SendMessage` de SQS:

* Método `POST` → Acción `SendMessage`.
* Cuerpo de la petición se convierte en el `MessageBody`.
* Gateway devuelve **202 Accepted** evitando bloqueo al cliente.
* Sin Lambda intermedia → menor latencia y costo.

### SQS Queue Configuration:

```json
{
  "QueueName": "behavior-events-queue",
  "Attributes": {
    "VisibilityTimeout": "300",
    "MessageRetentionPeriod": "345600",
    "ReceiveMessageWaitTimeSeconds": "20",
    "RedrivePolicy": {
      "deadLetterTargetArn": "arn:aws:sqs:...:behavior-events-dlq",
      "maxReceiveCount": "3"
    }
  }
}
```
- **VisibilityTimeout (5 min):** da tiempo a Lambda para procesar lote antes de reentregar.
- **Retention (4 días):** permite reintentos prolongados durante picos o fallas.
- **Long Poll (20 s):** reduce costos de `ReceiveMessage` vacíos.
- **DLQ (maxReceive 3):** mensajes fallidos tras 3 intentos se envían a DLQ para análisis y reprocesamiento.

### Lambda Event Source Mapping:

```json
{
  "FunctionName": "behavior-batch-processor",
  "EventSourceArn": "arn:aws:sqs:...:behavior-events-queue",
  "BatchSize": 50,
  "MaximumBatchingWindowInSeconds": 5,
  "ScalingConfig": {
    "MaximumConcurrency": 100
  }
}
```

### Lambda Function:

```javascript
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, BatchWriteCommand } = require('@aws-sdk/lib-dynamodb');

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));

exports.handler = async (event) => {
  console.log(`Processing ${event.Records.length} events`);
  
  const events = event.Records.map(record => {
    const body = JSON.parse(record.body);
    return {
      PK: `TENANT#${body.school_id}#STUDENT#${body.student_id}`,
      SK: `EVENT#${body.timestamp}`,
      event_type: body.event_type,
      ...body.metadata
    };
  });
  
  // Chunk into max 25 items per BatchWriteItem
  const chunks = [];
  for (let i = 0; i < events.length; i += 25) {
    chunks.push(events.slice(i, i + 25));
  }
  
  for (const chunk of chunks) {
    await db.send(new BatchWriteCommand({
      RequestItems: {
        'luca-platform': chunk.map(item => ({
          PutRequest: { Item: item }
        }))
      }
    }));
  }
  
  return { processed: events.length };
};
```

## Consecuencias

### Positivas
- **Absorbe spikes:** SQS buffer ilimitado
- **Cost-effective:** Pay-per-message, no fixed cost
- **Batch efficiency:** 50:1 (o n:1 :-)) reduction en Lambda invocations
- **DynamoDB protection:** Rate limiting natural
- **Auto-scaling:** Lambda escala con queue depth

### Negativas
- **Eventual consistency:** Delay entre ingesta y disponibilidad (5-10 segundos típico)
- **No ordering:** SQS Standard no garantiza orden
- **Monitoring complexity:** Métricas distribuidas (API GW + SQS + Lambda + DDB)

### Mitigaciones
- **Delay aceptable:** Use case no requiere real-time (eventual consistency OK)
- **Ordering innecesario:** Eventos de comportamiento son independientes y se pueden procesar con timestamps
- **CloudWatch Dashboard:** Unifica métricas de todos los componentes
- **X-Ray tracing:** Correlación end-to-end con correlation IDs
