# ADR-010: Observability Stack - CloudWatch + X-Ray

---

## Contexto y Problema

El sistema tiene arquitectura distribuida:
- API Gateway → App Runner/Lambda
- SQS → Lambda → DynamoDB
- Step Functions → API externo
- DynamoDB Streams → EventBridge Pipes → Firehose → S3

Necesitamos:
- **Trazabilidad:** Seguir una request a través de todos los componentes
- **Debugging:** Identificar dónde falló una transacción
- **Performance analysis:** Detectar bottlenecks de latencia
- **Alerting:** Notificaciones proactivas de errores
- **Cost tracking:** Attribution por tenant

## Decisión

**CloudWatch + X-Ray como observability stack:**

1. **CloudWatch Logs:** Logs estructurados (JSON) con correlation IDs
2. **CloudWatch Metrics:** Métricas custom por tenant + built-in metrics
3. **CloudWatch Alarms:** Alertas en errores, latencia, throttling
4. **X-Ray:** Distributed tracing end-to-end
5. **CloudWatch Dashboards:** Visualización unificada

**Logging Standard (ejemplo ficticio):**
```json
{
  "timestamp": "2024-01-18T10:30:00Z",
  "level": "INFO",
  "correlation_id": "abc-123-def",
  "trace_id": "1-5f3a1234-56789abcdef",
  "tenant_id": "school_123",
  "service": "grade-calculator",
  "event": "grade_calculated",
  "student_id": "student_456",
  "duration_ms": 45,
  "metadata": {...}
}
```

## Alternativas Consideradas

### Alternativa A: ELK Stack (Elasticsearch + Logstash + Kibana)
**Descripción:** Self-hosted logging y analytics platform.

**Pros:**
- Full-text search potente
- Visualizaciones ricas (Kibana)
- Flexibilidad total en queries
- Log aggregation avanzada

**Contras:**
- **Costo:** 3 nodos OpenSearch × t3.medium × 730 hrs × $0.076 = $166/mes
  - vs CloudWatch Logs: ~$15/mes (10 GB)
- **Ops overhead:** Gestionar cluster, sharding, replicas, upgrades
- **Complejidad:** Logstash pipelines, index templates, retention policies
- **Scaling:** Manual tuning de nodes y storage
- **Vendor lock-in diferente:** Specific a Elastic

**Por qué se descartó:** Complejidad operativa no justificada; costo 10x mayor.

---

### Alternativa B: Datadog
**Descripción:** SaaS observability platform.

**Pros:**
- UX excelente
- APM integrado
- Dashboards potentes
- Alerting sofisticado
- Multi-cloud

**Contras:**
- **Costo:** $15/host/mes + $0.10/GB logs ingested
  - 10 servicios + 50 GB logs = $155/mes
  - vs CloudWatch: ~$20/mes
- **Vendor lock-in:** Migrar dashboards/alerts es costoso
- **Latency:** Logs tardan segundos en aparecer (vs milliseconds CloudWatch)
- **Compliance:** Datos salen de AWS (potential issue para PII)

**Por qué se descartó:** Costo 8x mayor; vendor lock-in; latencia adicional.

---

### Alternativa C: Grafana + Prometheus + Loki
**Descripción:** Open-source observability stack.

**Pros:**
- Costo de software: $0 (open source)
- Flexibilidad total
- Community plugins
- Beautiful dashboards

**Contras:**
- **Infra cost:** EC2 instances para Prometheus + Loki + Grafana = ~$100/mes
- **Ops burden:** Mantener 3 servicios, backups, upgrades, HA
- **Integration complexity:** Conectar con servicios AWS (exporters custom)
- **Scaling:** Manual horizontal scaling de Loki
- **Expertise required:** Team necesita saber operar stack

**Por qué se descartó:** Overhead operativo masivo; team focus debería estar en producto, no en infra de observability.

---

### Alternativa D: CloudWatch Logs Insights únicamente (sin X-Ray)
**Descripción:** Solo CloudWatch para logs y métricas, sin distributed tracing.

**Pros:**
- Más simple
- Costo menor (~$5/mes ahorro)
- Menos integración

**Contras:**
- **No distributed tracing:** Imposible seguir request a través de servicios
- **Debugging difícil:** "Request falló" → ¿dónde? ¿API Gateway? ¿Lambda? ¿DynamoDB?
- **Performance analysis limitado:** No visualización de latency breakdown
- **Correlation manual:** Buscar correlation_id en múltiples log groups

**Por qué se descartó:** X-Ray resuelve problemas críticos de debugging distribuido; $10/mes adicional justificado.

---

### Alternativa E: AWS CloudTrail únicamente
**Descripción:** CloudTrail para auditoría de API calls.

**Pros:**
- Compliance built-in
- Auditoría completa
- Retention largo plazo

**Contras:**
- **No application logs:** CloudTrail solo captura AWS API calls
- **No custom metrics:** Solo metadata de requests
- **Query lento:** CloudTrail Insights toma minutos
- **Costo alto:** $2/100K events

**Por qué se descartó:** CloudTrail es complementario, no reemplazo de app observability.

---

## Comparación de Alternativas

| Criterio            | CloudWatch + X-Ray (Decisión) | ELK Stack | Datadog | Grafana Stack | Logs Only | CloudTrail |
|---------------------|------------------------------|-----------|---------|---------------|-----------|-----------|
| Costo mensual       | $20 (Aceptable)              | $166 (No) | $155 (No) | $100 (No) | $15 (Aceptable) | $30 (Condicional) |
| Complejidad Ops     | Muy baja (Aceptable)          | Alta (No) | Baja (Aceptable) | Muy alta (No) | Muy baja (Aceptable) | Baja (Aceptable) |
| Distributed tracing | X-Ray (Aceptable)             | No (No) | APM (Aceptable) | Tempo (Condicional) | No (No) | No (No) |
| Latencia consulta   | <1 s (Aceptable)              | 1-5 s (Condicional) | 2-5 s (Condicional) | 1-3 s (Condicional) | <1 s (Aceptable) | Minutos (No) |
| Integración AWS     | Nativa (Aceptable)            | Manual (Condicional) | Buena (Aceptable) | Exporters (Condicional) | Nativa (Aceptable) | Nativa (Aceptable) |
| Alerting            | Nativo (Aceptable)            | Rico (Aceptable) | Potente (Aceptable) | Flexible (Aceptable) | Nativo (Aceptable) | Limitado (Condicional) |

## Justificación

**CloudWatch + X-Ray es óptimo porque:**

1. **Native AWS Integration:**
   - Zero config para Lambda, API Gateway, DynamoDB logs
   - Automatic metrics (invocations, errors, duration)
   - IAM permissions ya configuradas

2. **X-Ray Distributed Tracing:**
   ```javascript
   // App Runner: Automatic X-Ray integration
   const AWSXRay = require('aws-xray-sdk-core');
   const AWS = AWSXRay.captureAWS(require('aws-sdk'));
   
   app.get('/profile/:id', async (req, res) => {
     const segment = AWSXRay.getSegment();
     const subsegment = segment.addNewSubsegment('calculate-grade');
     
     try {
       const rules = await getRules(req.params.id);  // Traced
       const grade = calculateGrade(rules);  // Traced
       subsegment.close();
       res.json({ grade });
     } catch (error) {
       subsegment.addError(error);
       subsegment.close();
       throw error;
     }
   });
   ```
   
   X-Ray trace muestra:
   ```
   API Gateway (10ms)
    └─ App Runner (45ms)
        ├─ DynamoDB Query (8ms)
        ├─ Calculate (35ms)
        └─ DynamoDB PutItem (2ms)
   ```

3. **Structured Logging Pattern:**
Cada servicio emite logs JSON con campos estandarizados (timestamp, level, trace_id, correlation_id, tenant_id, event, metadata). Puede implementarse con `console.log`, *pino* o *winston*; lo importante es la consistencia para que CloudWatch Insights filtre fácilmente por tenant o trace.

    ```javascript
   const logger ={
     info: (event, metadata = {}) => {
       console.log(JSON.stringify({
         timestamp: new Date().toISOString(),
         level: 'INFO',
         correlation_id: req.headers['x-correlation-id'],
         trace_id: process.env._X_AMZN_TRACE_ID,
         tenant_id: req.user.school_id,
         event,
         ...metadata
       }));
     }
   };
   
   logger.info('grade_calculated', {
     student_id: 'student_456',
     subject: 'matematicas',
     score: 84.5,
     duration_ms: 45
   });
   ```
     
4. **CloudWatch Insights Queries:**
   ```
   # Find all errors for tenant
   fields @timestamp, event, student_id, @message
   | filter tenant_id = "school_123"
   | filter level = "ERROR"
   | sort @timestamp desc
   | limit 100
```

Estos ejemplos muestran cómo los analistas podrían filtrar errores y monitorizar latencia en minutos sin mover datos fuera de AWS. Se ejecutan desde líneas de Insights dentro de CloudWatch, integrándose con dashboards y alarmas.
   
   # P95 latency por endpoint
   ```
   fields @timestamp, event, duration_ms
   | filter event = "grade_calculated"
   | stats pct(duration_ms, 95) by bin(5m)
   ```

5. **Cost Breakdown:**
   ```
   CloudWatch Logs:
   - 50 GB ingested × $0.50/GB = $25
   - 10 GB stored × $0.03/GB = $0.30
   
   CloudWatch Metrics:
   - 100 custom metrics × $0.30 = $30
   
   X-Ray:
   - 1M traces × $5/1M = $5
   - 1M traces scanned × $0.50/1M = $0.50
   
   Alarms:
   - 20 alarms × $0.10 = $2
   
   Total: ~$63/mes
   
   vs Datadog: ~$155/mes (2.5x más caro)
   vs ELK: ~$166/mes + ops time
   ```
6. **Alerting Strategy:**
   ```javascript
   // CloudWatch Alarm: High error rate
   {
     "AlarmName": "grade-calc-high-errors",
     "MetricName": "Errors",
     "Namespace": "AWS/Lambda",
     "Statistic": "Sum",
     "Period": 300,
     "EvaluationPeriods": 2,
     "Threshold": 10,
     "ComparisonOperator": "GreaterThanThreshold",
     "AlarmActions": ["arn:aws:sns:...:ops-alerts"]
   }
   ```

## Implementación

### Lambda Logging

```javascript
console.log(JSON.stringify({ level:'INFO', event:'start', trace_id, tenant_id }));
```

Se recomienda usar una librería JSON logger ligera; los campos deben seguir el esquema estándar para unificar consultas. El código anterior refleja el camino mínimo: imprimir JSON a stdout para que CloudWatch lo indexe.

```javascript
const { createLogger, format, transports } = require('winston');

const logger = createLogger({
  format: format.combine(
    format.timestamp(),
    format.json()
  ),
  defaultMeta: {
    service: process.env.SERVICE_NAME,
    environment: process.env.STAGE
  },
  transports: [
    new transports.Console()  // Lambda logs to stdout
  ]
});

exports.handler = async (event, context) => {
  const correlationId = event.headers['x-correlation-id'] || context.awsRequestId;
  
  logger.info('Processing request', {
    correlation_id: correlationId,
    trace_id: process.env._X_AMZN_TRACE_ID,
    tenant_id: event.requestContext.authorizer.claims['custom:school_id']
  });
  
  try {
    const result = await processEvent(event);
    logger.info('Request completed', { correlation_id: correlationId, duration_ms: 45 });
    return result;
  } catch (error) {
    , {
      correlation_id: correlationId,
      error: error.message,
      stack: error.stack
    });
    throw error;
};
```

### X-Ray Subsegments

```javascript
const seg = AWSXRay.getSegment();
const sub = seg.addNewSubsegment('external-call');
// … lógica …
sub.close();
```
Con unas pocas líneas se añaden anotaciones y metadatos que luego son filtrables en la consola X-Ray para análisis profundo.

```javascript
const AWSXRay = require('aws-xray-sdk-core');

async function calculateGrade(studentId, period) {
  const segment = AWSXRay.getSegment();
  
  // Subsegment for external call
  const subsegment = segment.addNewSubsegment('get-grading-rules');
  subsegment.addAnnotation('student_id', studentId);
  subsegment.addAnnotation('period', period);
  
  try {
    const rules = await db.get({...});
    subsegment.addMetadata('rules_count', rules.length);
    subsegment.close();
    return applyRules(rules);
  } catch (error) {
    subsegment.addError(error);
    subsegment.close();
    throw error;
  }
}
```

### CloudWatch Dashboards 

Se crean widgets de métricas (Invocations, Errors, Duration) y consultas de Logs Insights para mostrar errores recientes. Dashboards se versionan como JSON en IaC y permiten a operaciones revisar salud y tendencias en tiempo real sin salir de AWS.

```json
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          ["AWS/Lambda", "Invocations", {"stat": "Sum"}],
          [".", "Errors", {"stat": "Sum"}],
          [".", "Duration", {"stat": "Average"}]
        ],
        "period": 300,
        "stat": "Sum",
        "region": "us-east-1",
        "title": "Lambda Health"
      }
    },
    {
      "type": "log",
      "properties": {
        "query": "fields @timestamp, level, event, duration_ms | filter level = \"ERROR\" | sort @timestamp desc | limit 20",
        "region": "us-east-1",
        "title": "Recent Errors"
      }
    }
  ]
}
```

## Consecuencias

### Positivas
- **Zero ops overhead:** Managed services, no clusters
- **Native integration:** Automatic logs from Lambda, API Gateway
- **Cost-effective:** 3-8x más barato que alternativas
- **Familiar tooling:** Team ya conoce AWS console
- **Fast iteration:** Query results en <1 segundo

### Negativas
- **Query language:** CloudWatch Insights syntax menos potente que SQL
- **Retention cost:** Logs >30 días pueden ser costosos
- **Vendor lock-in:** CloudWatch-specific queries no portables
- **UI limitations:** Dashboards menos ricos que Grafana/Datadog

### Mitigaciones
- **Log aggregation:** Archive logs a S3 después 30 días ($0.023/GB)
- **Query optimization:** Filtrar por correlation_id reduce scan cost
- **Dashboard templates:** IaC (CloudFormation) para reproducibilidad
- **Training:** Documentar query patterns comunes para team
