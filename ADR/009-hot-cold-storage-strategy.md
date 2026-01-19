# ADR-009: Estrategia Hot/Cold Storage

---

## Contexto y Problema

El sistema genera dos tipos de queries sobre eventos de comportamiento estudiantil:
1. **Hot queries:** Profesores consultan actividad reciente (últimos 30 días)
   - Latencia requerida: <100ms p95
   - Frecuencia: Alta (miles/día)
   - Patrón: Por estudiante individual
2. **Cold queries:** Analistas consultan tendencias históricas (meses/años)
   - Latencia aceptable: Segundos/minutos
   - Frecuencia: Baja (decenas/día)
   - Patrón: Agregaciones cross-student

Storage costs:
- DynamoDB On-Demand: $0.25/GB-month
- S3 Standard: $0.023/GB-month (11x más barato)
- S3 Glacier: $0.004/GB-month (62x más barato)

Con 500 GB de datos, diferencia anual: $1,500 vs $138 vs $24.

## Decisión

**Estrategia Tiered Storage:**

1. **Hot Storage (DynamoDB):** Últimos 30 días con TTL automático
1. **Hot Storage (DynamoDB):** Últimos 30 días
   - TTL automático elimina eventos >30 días
   - Optimizado para queries por student_id
   - Latencia <10ms

2. **Cold Storage (S3):** Historia completa en Parquet
   - DynamoDB Streams → EventBridge Pipes → Kinesis Firehose → S3
   - Formato Parquet optimizado para analytics
   - Particionado: `year=YYYY/month=MM/school_id=XXX/`
   - Queryable via Athena (SQL)

3. **Archival (Glacier):** Datos >2 años post-graduación
   - S3 Lifecycle Policy automática
   - Compliance/auditoría únicamente

## Alternativas Consideradas

### Alternativa A: Todo en DynamoDB (sin TTL)
**Descripción:** Mantener todos los eventos en DynamoDB indefinidamente.

**Pros:**
- Arquitectura simple (un solo storage)
- Queries uniformes (mismo API)
- Latencia consistente

**Contras:**
- **Costo prohibitivo:** 500 GB × $0.25 = $125/mes
  - vs Hot+Cold: 10 GB × $0.25 + 490 GB × $0.023 = $13.77/mes
  - **Ahorro: $111/mes ($1,332/año)**
- **Performance degradation:** DynamoDB no optimizado para agregaciones grandes
- **Desperdicio:** 95% de queries son sobre datos recientes

**Por qué se descartó:** Costo 10x mayor sin beneficio; mayoría de datos raramente accedidos.

---

### Alternativa B: Todo en S3 (sin hot storage)
**Descripción:** Escribir directamente a S3, queries via Athena.

**Pros:**
- **Costo mínimo:** $0.023/GB
- Arquitectura simple
- Analytics-first

**Contras:**
- **Latencia inaceptable:** Athena queries toman 2-5 segundos
  - Requisito: <100ms para actividad reciente
- **Costo de queries:** Athena cobra por data scanned
  - Query simple 100 GB = $0.50
  - Miles de queries/día = $$$
- **UX pobre:** Profesores esperando 5 segundos por perfil

**Por qué se descartó:** Latencia incompatible con operaciones interactivas.

---

### Alternativa C: DynamoDB + Glacier (sin S3 intermedio)
**Descripción:** DynamoDB export directo a Glacier.

**Pros:**
- Costos mínimos
- Dos tiers simples (hot/archive)

**Contras:**
- **Glacier retrieval:** 3-5 horas para restaurar datos
  - Imposible hacer analytics ad-hoc
- **No queryable:** Glacier no soporta SQL queries
- **Export overhead:** DynamoDB export es snapshot, no incremental

**Por qué se descartó:** Glacier es write-only; no permite analytics.

---

### Alternativa D: RDS con Partitioning
**Descripción:** PostgreSQL con table partitioning (hot/cold tables).

**Pros:**
- SQL nativo para todo
- JOINs potentes
- Transacciones ACID

**Contras:**
- **Costo:** Aurora Serverless v2 mínimo 0.5 ACU × 730 hrs × $0.12 = $44/mes
  - Solo compute, sin incluir storage
- **Capacity planning:** Requiere dimensionar ACUs
- **Partitioning manual:** Crear particiones, mover datos (maintenance overhead)
- **No serverless real:** Warm-up delays

**Por qué se descartó:** Costo fijo alto; complejidad de partitioning; no true serverless.

---

### Alternativa E: ElasticSearch/OpenSearch
**Descripción:** Hot/cold tiers en OpenSearch con Index Lifecycle Management.

**Pros:**
- Full-text search
- Agregaciones potentes
- Hot/cold tiers nativos

**Contras:**
- **Costo:** OpenSearch mínimo 2 nodos × t3.small × 730 hrs × $0.038 = $55/mes
- **Complejidad:** Cluster management, sharding, replicas
- **Over-engineering:** No necesitamos full-text search
- **Latency:** >50ms típico para queries

**Por qué se descartó:** Over-engineering para use case; costo fijo innecesario.

---

## Comparación de Alternativas

| Criterio               | Hot/Cold (Decisión) | Todo DynamoDB | Todo S3 | DDB+Glacier | RDS Partitioning | OpenSearch |
|------------------------|---------------------|--------------|---------|-------------|------------------|-----------|
| Costo mensual          | $14 (Aceptable)     | $125 (No)    | $11 (Aceptable) | $25 (Condicional) | $60 (No) | $70 (No) |
| Latencia consultas hot | <10 ms (Aceptable)  | <10 ms (Aceptable) | 2-5 s (No) | <10 ms (Aceptable) | 20-50 ms (Condicional) | 50-100 ms (Condicional) |
| Latencia consultas cold| 2-10 s (Aceptable)  | Lenta (Condicional) | 2-5 s (Condicional) | 3-5 h (No) | <1 s (Aceptable) | <1 s (Aceptable) |
| Capacidades analytics  | SQL Athena (Aceptable) | Limitadas (No) | SQL (Aceptable) | Ninguna (No) | SQL (Aceptable) | Muy potentes (Aceptable) |
| Complejidad Ops        | Baja (Aceptable)    | Muy baja (Aceptable) | Baja (Aceptable) | Baja (Aceptable) | Alta (No) | Alta (No) |
| Auto-scaling           | Sí (Aceptable)      | Sí (Aceptable) | N/A | Sí (Aceptable) | Manual (Condicional) | Manual (Condicional) |

## Justificación

**Hot/Cold Storage es óptimo porque:**

1. **Access Pattern Optimization:**
   - 90% de queries son sobre últimos 7 días
   - 95% sobre últimos 30 días
   - Analytics histó ricos son <5% del tráfico

2. **Cost Efficiency:**
   ```
   Scenario: 500 GB total data
   
   Hot/Cold Strategy:
   - Hot (30 días): 10 GB × $0.25 = $2.50
   - Cold (historia): 490 GB × $0.023 = $11.27
   Total: $13.77/mes
   
   Todo DynamoDB:
   - 500 GB × $0.25 = $125/mes
   
   Ahorro: $111/mes = 808% ROI
   ```

3. **Performance Tiering:**
   - Profesores: GET /profile → DynamoDB → <10ms
   - Analistas: SELECT AVG(...) → Athena → 3s (aceptable)
   
   Cada storage optimizado para su use case.

4. **Automatic Data Movement:**
   - DynamoDB TTL: Zero código, zero costo
   - Streams → Pipes → Firehose: Zero custom ETL
   - S3 Lifecycle: Glacier transition automática

5. **Query Cost Optimization:**
   - DynamoDB: Pay per read ($0.00000025/read)
   - Athena: Pay per GB scanned ($5/TB)
   
   Athena costoso para queries frecuentes, perfecto para analytics esporádicos.

## Implementación

### DynamoDB TTL Configuration:

```json
{
  "TableName": "luca-platform",
  "TimeToLiveSpecification": {
    "Enabled": true,
    "AttributeName": "ttl"
  }
}
```

```javascript
// Al escribir evento
const event = {
  PK: `TENANT#school_123#STUDENT#student_456`,
  SK: `EVENT#${timestamp}`,
  event_type: 'participation',
  ttl: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000)  // +30 días
};
```

_Este TTL expira automáticamente los eventos "hot" tras 30 días y, a través de DynamoDB Streams, los envía al pipeline que los deposita en S3 sin cron jobs ni mantenimiento adicional._

### S3 Lifecycle Policy

Política de ciclo de vida que traslada datos "cold" a Glacier y los expira, reduciendo costos al mínimo:

```json
{
  "Rules": [{
    "Id": "archive-old-events",
    "Status": "Enabled",
    "Filter": {
      "Prefix": "events/"
    },
    "Transitions": [{
      "Days": 730,
      "StorageClass": "GLACIER"
    }],
    "Expiration": {
      "Days": 2555
    }
  }]
}
```

### Athena in the Workflow

Athena permite consultas SQL ad-hoc sobre el lago de datos Parquet en S3.

- Use case: reportes históricos, tendencias multi-año, exploración de comportamiento.
- Pago por escaneo (≈ $0.005/GB) lo hace ideal para consultas esporádicas.
- Con este diseño, las aplicaciones interactivas permanecen en DynamoDB; los analistas usan Athena cuando la latencia de segundos es aceptable.
- Glue Data Catalog mantiene particiones (school_id, year, month) para minimizar datos escaneados.

### App Runner Query Logic

```javascript
exports.getStudentProfile = async (studentId, schoolId) => {
  const events = await queryRecentEvents(studentId, schoolId); // DynamoDB
  return enrichProfile(events);
};
```
Intento: exponer un endpoint REST con baja latencia (<10 ms p95). Seguridad: IAM role con acceso solo `Query` y `GetItem` sobre partición del tenant. Mecanismo: paginación + `Limit` para prevenir lecturas grandes.
```javascript
  const recentEvents = await db.query({
    TableName: 'luca-platform',
    KeyConditionExpression: 'PK = :pk AND begins_with(SK, :sk)',
    ExpressionAttributeValues: {
      ':pk': `TENANT#${schoolId}#STUDENT#${studentId}`,
      ':sk': 'EVENT#'
    },
    ScanIndexForward: false,  // Más recientes primero
    Limit: 100
  });
  
  return {
    student_id: studentId,
    recent_activity: recentEvents.Items,
    activity_count_30d: recentEvents.Count
  };
```

### Analytics Query (Athena)

Las funciones de capa "analytics" invocan Athena usando plantillas SQL parametrizadas; los resultados se almacenan en S3 y se devuelven al frontend una vez listos. Latencia típica 3-10 s, adecuada para dashboards fuera del camino crítico.

## Consecuencias

### Positivas
- **Costo reducido:** 90% ahorro vs all-DynamoDB
- **Latencia optimizada:** <10ms para queries frecuentes
- **Analytics potente:** SQL sobre Parquet histórico
- **Automatic lifecycle:** Zero maintenance para data movement
- **Compliance:** Glacier para retention largo plazo

### Negativas
- **Complejidad arquitectónica:** Dos sistemas de storage
- **Query duality:** Lógica diferente para hot vs cold
- **Gap temporal:** Eventos en tránsito (DynamoDB → S3) pueden no estar disponibles
- **Athena cost:** Queries ineficientes pueden ser costosos

### Mitigaciones
- **Abstraction layer:** Service layer oculta hot/cold split de consumers
- **Query optimization:** Partitioning S3 por school_id + date reduce scans
- **Monitoring:** CloudWatch alarmas en Athena query costs
- **Best practices:** Documentar query patterns eficientes para analistas
- **Transition buffer:** DynamoDB TTL + Streams garantiza datos llegan a S3 antes de expirar
