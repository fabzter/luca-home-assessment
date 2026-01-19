# ADR-007: Background Job para Consolidación de Notas

---
## Contexto y Problema

El sistema registra evaluaciones individuales (exams, quizzes, homework) a lo largo de un periodo académico. Las notas consolidadas se calculan aplicando reglas específicas del tenant:
- Pesos por tipo de evaluación (exams: 70%, homework: 20%, quiz: 10%)
- Fórmulas custom (promedio, mediana, mejor N de M)
- Redondeo y escala de calificación

Requisitos:
- Evaluaciones se registran en tiempo real (profesores suben notas)
- Consolidación puede tomar segundos (aplicar fórmulas complejas)
- Lectura de perfiles debe ser <120ms p95 (precalculado)
- Consolidación no necesita ser inmediata (eventual consistency aceptable)

## Decisión

**Lambda nightly job (02:00 hrs) triggered por EventBridge Scheduler:**

1. Lambda corre cada noche a las 02:00
2. Query DynamoDB: `consolidated = false`
3. Agrupa por `(tenant, student, subject, period)`
4. Aplica reglas de consolidación del tenant
5. Calcula nota consolidada
6. Escribe a DynamoDB: `GRADE#subject#period`
7. Marca evaluaciones como `consolidated = true`

## Alternativas Consideradas

### Alternativa A: Consolidación On-Write (calcular al registrar evaluación)
**Descripción:** Cuando profesor registra evaluación, Lambda trigger recalcula nota consolidada inmediatamente.

**Pros:**
- Datos siempre actualizados
- No hay delay entre evaluación y grade consolidado
- Lógica simple (trigger directo)

**Contras:**
- **Latencia en escritura:** Profesor espera mientras se recalcula
  - POST /evaluations: 50ms → 300ms (6x más lento)
- **Costo computacional:** Recalcular por cada evaluación es ineficiente
  - Evaluación 1/10 → calcula con 1 evaluación
  - Evaluación 2/10 → recalcula con 2 evaluaciones
  - Evaluación 10/10 → recalcula con 10 evaluaciones
  - Total: 55 cálculos para 10 evaluaciones (vs 1 cálculo batch)
- **Throttling risk:** Múltiples profesores escribiendo simultáneamente
- **Desperdicio:** Consolidación intermedia irrelevante (solo interesa final de periodo)

**Por qué se descartó:** Latencia inaceptable para UX de profesor; costo computacional ineficiente.

---

### Alternativa B: Consolidación On-Read (lazy evaluation)
**Descripción:** Calcular nota consolidada cuando usuario consulta perfil.

**Pros:**
- Zero costo si nadie consulta
- Siempre actualizada (real-time)
- No necesita job scheduler

**Contras:**
- **Latencia de lectura:** GET /profile: 80ms → 250ms
  - Incompatible con p95 < 120ms
- **Cache complexity:** Requiere cache invalidation cuando hay nueva evaluación
- **Cold starts:** Primera lectura después de nueva evaluación es lenta
- **Desperdicio:** Recalcula cada vez que se consulta (sin cache hits)

**Por qué se descartó:** Rompe requisito de latencia p95 < 120ms.

---

### Alternativa C: DynamoDB Streams Trigger
**Descripción:** Lambda triggered por DynamoDB Streams cuando se inserta evaluación.

**Pros:**
- Near real-time consolidation
- Event-driven (no polling)
- Auto-scaling con throughput

**Contras:**
- **Race conditions:** Múltiples evaluaciones simultáneas → múltiples consolidaciones paralelas
  - Requiere optimistic locking complejo
- **Ordenamiento no garantizado:** Streams puede procesar out-of-order
- **Costo:** Lambda invocations por cada INSERT
- **Complejidad:** Lógica de debouncing (esperar X segundos por más evaluaciones)

**Por qué se descartó:** Race conditions difíciles de manejar; complexity no justificada.

---

### Alternativa D: Step Functions Workflow
**Descripción:** Step Functions orquesta consolidación con esperas y batching.

**Pros:**
- Orchestration visual
- Manejo de errores declarativo
- Auditoría built-in

**Contras:**
- **Over-engineering:** Consolidación es operación simple (query → calculate → write)
- **Costo:** $25/1M transitions vs Lambda $0.20/1M invocations
- **Complexity:** ASL para lógica que cabe en 50 líneas de código

**Por qué se descartó:** Complejidad innecesaria para job batch simple.

---

### Alternativa E: Continuous Lambda (cada 5 minutos)
**Descripción:** Lambda corre cada 5 minutos procesando pendientes.

**Pros:**
- Consolidación más frecuente (near real-time)
- Eventual consistency más corta

**Contras:**
- **Desperdicio:** 12 ejecuciones/hora × 24 horas = 288 ejecuciones/día
  - Mayoría procesa zero evaluaciones (fuera de horario escolar)
- **Costo:** 288 × 30 días = 8,640 invocations/mes vs 30 invocations (nightly)
- **No value:** Usuarios no necesitan consolidación cada 5 min

**Por qué se descartó:** Desperdicio de costo sin beneficio para usuarios.

---

## Comparación de Alternativas

| Criterio | Nightly Job | On-Write | On-Read | Streams Trigger | Step Functions | Every 5 min |
|----------|-------------|----------|---------|-----------------|----------------|-------------|
| Criterio            | Nightly Job (Decisión) | On-Write | On-Read | Streams Trigger | Step Fn | Cada 5 min |
|---------------------|------------------------|----------|---------|-----------------|---------|------------|
| Latencia escritura  | <50 ms (Aceptable)     | ~300 ms (No) | <50 ms (Aceptable) | <50 ms (Aceptable) | <50 ms (Aceptable) | <50 ms (Aceptable) |
| Latencia lectura    | <100 ms (Aceptable)    | <100 ms (Aceptable) | ~250 ms (No) | <100 ms (Aceptable) | <100 ms (Aceptable) | <100 ms (Aceptable) |
| Costo mensual       | ~$2 (Aceptable)        | ~$25 (No) | ~$10 (Condicional) | ~$20 (No) | ~$15 (Condicional) | ~$50 (No) |
| Complejidad         | Baja (Aceptable)       | Media (Condicional) | Alta (No) | Alta (No) | Alta (No) | Baja (Aceptable) |
| Frescura de datos   | 24 h máx (Condicional) | Instant (Aceptable) | Instant (Aceptable) | Near-RT (Aceptable) | Configurable (Aceptable) | 5 min (Condicional) |
| Race conditions     | No (Aceptable)         | Posibles (Condicional) | No (Aceptable) | Sí (No) | No (Aceptable) | Posibles (Condicional) |

## Justificación

**Nightly Job es óptimo porque:**

1. **Eventual Consistency Aceptable:**
   - Profesores suben evaluaciones durante el día
   - Estudiantes consultan notas consolidadas (no urgente)
   - Delay de 24h es aceptable para use case

2. **Eficiencia Computacional:**
   - Un cálculo por (student, subject, period) vs múltiples recálculos
   - Batch processing optimiza queries a DynamoDB
   ```javascript
   // Query una vez todas las evaluaciones pendientes
   const evaluations = await db.query({
     IndexName: 'ConsolidatedIndex',
     KeyConditionExpression: 'consolidated = :false'
   });
   // Agrupa en memoria (zero cost)
   const grouped = groupBy(evaluations, e => `${e.tenant}#${e.student}#${e.subject}#${e.period}`);
   ```

3. **Horario Optimizado:**
   - 02:00 hrs: Tráfico mínimo en sistema
   - No compite con operaciones interactivas
   - DynamoDB On-Demand absorbe spike sin throttling

4. **Simplicidad:**
   Un único Lambda nocturno con lógica lineal (query → agrupar → consolidar → guardar) evita orquestación externa y reduce a ~50 líneas de código.

```javascript
   exports.handler = async () => {
     const pendingEvals = await queryPending();
     const grouped = groupByStudentSubjectPeriod(pendingEvals);
     
     for (const [key, evals] of Object.entries(grouped)) {
       const [tenant, student, subject, period] = key.split('#');
       const rules = await getGradingRules(tenant, subject);
       const consolidated = calculateGrade(evals, rules);
       
       await db.transactWrite([
         { Put: { TableName: 'luca', Item: { 
           PK: `TENANT#${tenant}#STUDENT#${student}`,
           SK: `GRADE#${subject}#${period}`,
           consolidated_score: consolidated,
           last_calculated: Date.now()
         }}},
         ...evals.map(e => ({ Update: {
           TableName: 'luca',
           Key: { PK: e.PK, SK: e.SK },
           UpdateExpression: 'SET consolidated = :true',
           ExpressionAttributeValues: { ':true': true }
         }}))
       ]);
     }
   };
```

5. **Cost Efficiency:**
   ```
   Nightly Job:
   - 30 invocations/mes × 2 min avg × 512 MB = $0.04
   - DynamoDB reads: 10K evaluations × $0.00000025 = $0.0025
   Total: ~$0.05/mes
   
   On-Write:
   - 10K evaluations/mes × 100ms × 512 MB = $0.21
   - + recalculation cost cada vez
   Total: ~$2/mes (40x más caro)
   ```

6. **Idempotency:**
   - Flag `consolidated = true` previene reprocesamiento
   - Si job falla mid-execution, next run procesa pendientes

## Implementación

### EventBridge Rule:

Una regla cron de EventBridge (02:00 AM, todos los días) invoca el Lambda de consolidación, pasando un payload `{type:"full-consolidation"}`. No requiere más configuración: simplemente planifica la ejecución nocturna.
```json
{
  "Name": "nightly-grade-consolidation",
  "ScheduleExpression": "cron(0 2 * * ? *)",
  "State": "ENABLED",
  "Targets": [{
    "Arn": "arn:aws:lambda:...:function:consolidate-grades",
    "Input": "{\"type\": \"full-consolidation\"}"
  }]
}
```

### Lambda Function (pseudocódigo)

```javascript
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, QueryCommand, TransactWriteCommand } = require('@aws-sdk/lib-dynamodb');

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));

exports.handler = async (event) => {
  // inicio del job
  
  // 1. Query evaluaciones no consolidadas
  const evaluations = await queryUnconsolidated();
  console.log(`Found ${evaluations.length} pending evaluations`);
  
  // 2. Agrupar por student/subject/period
  const groups = groupEvaluations(evaluations);
  console.log(`Processing ${Object.keys(groups).length} consolidations`);
  
  let processed = 0;
  let failed = 0;
  
  // 3. Consolidar cada grupo
  for (const [key, evals] of Object.entries(groups)) {
    try {
      const [tenant, student, subject, period] = key.split('#');
      const rules = await getGradingRules(tenant, subject);
      const consolidatedScore = applyRules(evals, rules);
      
      await writeConsolidatedGrade({
        tenant, student, subject, period,
        score: consolidatedScore,
        evaluations: evals
      });
      
      processed++;
    } catch (error) {
      console.error(`Failed to consolidate ${key}:`, error);
      failed++;
    }
  }
  
  console.log(`Consolidation complete: ${processed} succeeded, ${failed} failed`);
  
  return {
    statusCode: 200,
    body: { processed, failed }
  };
};
```

### Monitoring:

CloudWatch alarmas vigilan errores y duración del Lambda. Ejemplo (JSON resumido):
```json
{
  "AlarmName": "consolidation-job-failures",
  "MetricName": "Errors",
  "Namespace": "AWS/Lambda",
  "Dimensions": [{
    "Name": "FunctionName",
    "Value": "consolidate-grades"
  }],
  "Threshold": 1,
  "ComparisonOperator": "GreaterThanThreshold"
}
```
Estas alarmas envían notificaciones si el job falla o excede el tiempo esperado, asegurando visibilidad operativa.

## Consecuencias

### Positivas
- **Performance:** Escritura <50ms, lectura <100ms (cumple SLA)
- **Costo:** ~$0.05/mes (40x más barato que on-write)
- **Simplicidad:** 100 líneas de código, zero orchestration
- **Escalabilidad:** Batch processing eficiente
- **Idempotency:** Flag `consolidated` previene duplicados

### Negativas
- **Delay máximo:** 24 horas entre evaluación y consolidación
- **Ventana de procesamiento:** Si job falla, esperamos 24h más, a menos que se configure un trigger manualß
- **No real-time:** Estudiantes no ven nota consolidada inmediatamente, pero esto es aceptable en sistema de notas escolares

### Mitigaciones
- **Manual trigger:** API endpoint para forzar consolidación (caso emergencia)
- **Retry mechanism:** Lambda retry automático en fallos transitorios
- **Monitoring:** CloudWatch alarm si job falla
- **Partial consolidation:** Procesar por batches si volumen crece (evitar timeout)
