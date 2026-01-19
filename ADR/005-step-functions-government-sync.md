# ADR-005: Step Functions para Sincronización con Gobierno

---

## Contexto y Problema

Cada 3 meses, el sistema debe sincronizar notas consolidadas con un API del gobierno que:
- Está fuera de nuestro control
- Es inestable (timeouts, 503 frecuentes)
- Tiene rate limits estrictos
- Procesa batches (max 100 registros por request)
- Puede tomar horas completar la sincronización completa

Necesitamos orquestación robusta con:
- Reintentos con backoff exponencial
- Rate limiting para respetar límites del API
- Auditoría completa del proceso
- Manejo de fallas parciales (algunos batches fallan, otros no)
- Reconciliación para detectar discrepancias

## Decisión

**AWS Step Functions Standard Workflow** para orquestar la sincronización:

1. Query DynamoDB para obtener grades pendientes
2. Crear batches de 100 registros
3. Por cada batch:
   - Enviar HTTP POST al API gobierno
   - Si 5xx/timeout → retry con backoff (máx 3 intentos)
   - Si 4xx → fallar inmediatamente (error de datos)
   - Si éxito → marcar batch como sincronizado
   - Si fallo definitivo → escribir a DLQ
4. Wait 2 segundos entre batches (rate limiting)
5. Lambda diario de reconciliación compara con API gobierno

## Alternativas Consideradas

### Alternativa A: Lambda con Custom Retry Logic
**Descripción:** Lambda que implementa retry, batching, y state tracking en código.

**Pros:**
- Todo en código (familiar para developers)
- Sin costo adicional de Step Functions
- Debugging con logs normales
- Flexibilidad total

**Contras:**
- **Complejidad:** Implementar exponential backoff, circuit breaker, DLQ es error-prone
- **State management:** Requiere DynamoDB table para tracking (sync_batch_id, retry_count, status)
- **Timeout límite:** Lambda max 15 minutos, sincronización puede tomar horas
  - Solución: Chain de Lambdas coordinadas por SQS (aumenta complejidad)
- **No auditable visualmente:** Estado solo visible en logs/DB
- **Testing:** Difícil probar todos los edge cases (timeouts, retries parciales)

**Ejemplo de complejidad:**
```javascript
async function syncWithRetry(batch, retryCount = 0) {
  try {
    await http.post(GOV_API, batch);
    await db.update({ batch_id, status: 'synced' });
  } catch (error) {
    if (error.statusCode >= 500 && retryCount < 3) {
      const backoff = Math.pow(2, retryCount) * 5000; // 5s, 10s, 20s
      await sleep(backoff);
      return syncWithRetry(batch, retryCount + 1);
    } else {
      await dlq.send(batch, error);
    }
  }
}
// Falta: rate limiting, circuit breaker, observability, reconciliation
```

**Por qué se descartó:** Reinventar primitivas que Step Functions provee gratuitamente.

---

### Alternativa B: SQS + Lambda Chain
**Descripción:** SQS FIFO queue con Lambdas procesando batches secuencialmente.

**Pros:**
- Escalamiento automático
- Built-in retry con DLQ
- Backoff configurable en SQS
- Costo bajo

**Contras:**
- **No esperas largas:** SQS visibility timeout máximo 12 horas
  - Problema: Si el API gobierno tiene downtime de 24hrs, perdemos estado
- **No auditoría de workflow:** No hay visualización del estado completo
- **Coordinación compleja:** Requiere Lambda adicional para iniciar proceso
- **Rate limiting manual:** Lambda debe implementar throttling
- **Sin rollback:** Si falla a mitad, no hay forma fácil de reintentar desde donde quedó

**Por qué se descartó:** SQS es excelente para eventos independientes, no para workflows secuenciales con estado.

---

### Alternativa C: EventBridge Scheduler + Lambda + DynamoDB State
**Descripción:** Scheduler ejecuta Lambda periódicamente, state en DynamoDB.

**Pros:**
- Scheduler ya disponible para otros jobs
- DynamoDB state es queryable
- Lambda familiar

**Contras:**
- **Duplica lógica de Step Functions:** State machine en código + DB
- **No retry declarativo:** Implementar en código
- **No visualización:** Requiere dashboard custom para ver estado
- **Esperas largas ineficientes:** Lambda corriendo idle esperando backoff

**Por qué se descartó:** Peor de ambos mundos (complejidad de Lambda + state management).

---

### Alternativa D: Step Functions Express Workflow
**Descripción:** Express en lugar de Standard.

**Pros:**
- **Costo:** $1.00/1M requests vs $25/1M transitions (96% más barato)
- **Performance:** Alta throughput

**Contras:**
- **Duración máxima:** 5 minutos (Standard: 1 año)
  - Problema: Sincronización completa puede tomar horas
- **No auditable:** Sin execution history persistente
- **No inspección:** No puedes ver estado de workflow in-flight

**Por qué se descartó:** Límite de 5 minutos incompatible con proceso que puede tomar horas.

---

## Comparación de Alternativas

| Criterio                | Step Fn Std (Decisión) | Lambda Custom | SQS Chain | EventBridge+Lambda | SF Express |
|-------------------------|------------------------|---------------|-----------|--------------------|------------|
| Duración máxima         | 1 año (Aceptable)      | 15 min (No)   | 12 h (Condicional) | 15 min (No) | 5 min (No) |
| Retry declarativo       | Sí (Aceptable)         | Manual (No)   | Retry SQS (Condicional) | Manual (No) | Sí (Aceptable) |
| Auditoría visual        | Console UI (Aceptable) | Logs (No)     | Logs (No) | Logs (No) | Sin history (No) |
| Costo anual (40K batches)| ~$10 (Aceptable)       | ~$2 (Aceptable)| ~$1 (Aceptable) | ~$2 (Aceptable) | ~$0.5 (Aceptable) |
| Esperas largas          | Sin costo (Aceptable)  | Lambda idle (No) | Visibility timeout (No) | Lambda idle (No) | Máx 5 min (Condicional) |
| Complejidad Ops         | Baja (Aceptable)       | Alta (No)     | Media (Condicional) | Alta (No)   | Baja (Aceptable) |

## Justificación

**Step Functions Standard es óptimo porque:**

1. **Retry Declarativo:**
   Retry policy (pseudocódigo):
```text
on Timeout or 503:
  attempts: 3
  backoff: 5s → 15s → 45s
```
   15 líneas de JSON vs 100+ líneas de código con tests.

2. **Esperas sin Costo:**
   ```json
   {
     "Type": "Wait",
     "Seconds": 2
   }
   ```
   Workflow pausado, zero compute consumido.

3. **Auditoría Built-in:**
   - Console muestra cada estado del workflow
   - Execution history persistente
   - CloudWatch Events para alertas

4. **Error Handling Visual:**
   ```
   SendToGov → [Success] → MarkSynced
              ↓ [Error]
              WaitRetry → [Retry < 3] → SendToGov
              ↓ [Max retries]
              WriteToDLQ
   ```
   Cualquier developer entiende el flujo sin leer código.

5. **Reconciliación Simple:**
   Lambda diario:
   ```javascript
   const executions = await stepfunctions.listExecutions({ 
     stateMachineArn, 
     statusFilter: 'SUCCEEDED' 
   });
   const syncedBatches = executions.map(e => e.output.batch_id);
   const govBatches = await govAPI.listSynced();
   const missing = difference(syncedBatches, govBatches);
   if (missing.length > 0) sendAlert(missing);
   ```

6. **Costo Justificado:**
   - 10,000 batches/trimestre × 4 trimestres = 40K batches/año
   - 40K × 10 transitions avg × $0.000025 = **$10/año**
   - vs costo de debugging sync failures en producción: **$$$**

## Implementación

### State Machine (simplificado):

```json
{
  "StartAt": "QueryPendingGrades",
  "States": {
    "QueryPendingGrades": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:...:QueryLambda",
      "Next": "CheckEmpty"
    },
    "CheckEmpty": {
      "Type": "Choice",
      "Choices": [{
        "Variable": "$.grades.length",
        "NumericGreaterThan": 0,
        "Next": "PrepBatch"
      }],
      "Default": "Success"
    },
    "PrepBatch": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:...:PrepBatchLambda",
      "Next": "SendToGov"
    },
    "SendToGov": {
      "Type": "Task",
      "Resource": "arn:aws:states:::http:invoke",
      "Parameters": {
        "ApiEndpoint": "https://api.gobierno.cl/sync",
        "Method": "POST",
        "RequestBody.$": "$.batch"
      },
      "Retry": [{
        "ErrorEquals": ["States.Timeout", "States.TaskFailed"],
        "IntervalSeconds": 5,
        "MaxAttempts": 3,
        "BackoffRate": 3
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "WriteToDLQ"
      }],
      "Next": "MarkSynced"
    },
    "MarkSynced": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:...:MarkSyncedLambda",
      "Next": "WaitRateLimit"
    },
    "WaitRateLimit": {
      "Type": "Wait",
      "Seconds": 2,
      "Next": "QueryPendingGrades"
    },
    "WriteToDLQ": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:...:DLQLambda",
      "Next": "QueryPendingGrades"
    },
    "Success": {
      "Type": "Succeed"
    }
  }
}
```

## Consecuencias

### Positivas
- **Robustez:** Manejo de errores probado y battle-tested por AWS
- **Auditoría:** Execution history completa sin código adicional
- **Debugging:** Console UI muestra exactamente dónde falló
- **Maintenance:** Cambiar retry policy es editar JSON, no código
- **Compliance:** Logs de CloudTrail muestran cada transición

### Negativas
- **Vendor lock-in:** Difícil migrar fuera de AWS
- **Learning curve:** Developers deben aprender ASL (Amazon States Language)
- **Debugging local:** Requiere Step Functions Local o mocks
- **Costo por transición:** Puede ser costoso si workflow tiene muchos estados

### Mitigaciones
- **Testing:** Step Functions Local para integration tests
- **Monitoring:** CloudWatch alarmas en estado FAILED
- **Costo:** Optimizar workflow (combinar estados donde posible)
