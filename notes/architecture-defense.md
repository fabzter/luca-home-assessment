# Guía de Defensa Arquitectónica - Preparación 30 min

Documento de referencia rápida para responder en español durante la entrevista.

## Preguntas Esperadas y Respuestas

### 1. "¿Por qué no usar Lambda para todo? Sería más simple."

**Intención de la pregunta:** Menos componentes = menos complejidad.

**Respuesta:**
- **Costo:** Concurrency provisionada para p95 <120ms suma ~USD $200/mes solo en cold starts.
- **App Runner vs Lambda:** USD $17/mes vs USD $77/mes (~41% ahorro).
- **Pool de conexiones:** App Runner mantiene conexiones abiertas; Lambda las crea en cada invocación.
- **Ejemplo claro:** En el pico de 11am, los cold starts añadirían 500-2000ms; App Runner elimina ese impacto en clase.

### 2. "DynamoDB es overkill. ¿Por qué no PostgreSQL?"

**Intención:** Familiaridad con relacional.

**Respuesta:**
- **Performance:** Aurora Serverless v2 tiene cold starts de 30-45s; DynamoDB responde <5ms.
- **Escalado:** Aurora requiere planificar ACUs; DynamoDB On-Demand escala 0→5,000 RPS al instante.
- **Costo:** Aurora mínimo USD $44/mes + I/O; DynamoDB ~USD $15/mes.
- **Multi-tenant:** `dynamodb:LeadingKeys` no es posible en RDS.
- **Patrones de acceso:** Consultas predecibles (evaluaciones, perfiles) sin JOINs complejos.

### 3. "Step Functions es complejo para simples llamadas HTTP."

**Intención:** Preferencia por lógica de reintentos en código.

**Respuesta:**
- **Auditoría visual:** Stakeholders ven el estado sin leer código.
- **Reintentos declarativos:** 15 líneas vs >100 de código + pruebas.
- **Estado durable:** Pausas de horas/días sin costo de cómputo.
- **Costo:** ~USD $10/año vs miles en depuración de sincronizaciones fallidas.
- **Compliance:** Historial de ejecuciones listo para auditoría gubernamental.

### 4. "Las políticas IAM multi-tenant son sobre-ingeniería."

**Intención:** Confiar solo en filtros de aplicación.

**Respuesta:**
- **Defensa en profundidad:** Manejamos PII de menores; no basta con lógica de app.
- **Escenario real:** Un bug sin `WHERE tenant_id` se bloquea a nivel infraestructura.
- **Auditabilidad:** Se puede demostrar aislamiento sin leer código de aplicación.
- **Trade-off:** Sí, añade complejidad en auth, pero evita brechas catastróficas.

### 5. "Hot/Cold storage complica. ¿Por qué no solo DynamoDB?"

**Intención:** Un solo datastore parece más simple.

**Respuesta:**
- **Costo:** 500GB en DynamoDB ~USD $125/mes vs Hot+Cold ~USD $13.77/mes (90% ahorro).
- **Patrón de uso:** 95% de consultas son últimos 30 días; no pagamos premium por históricos.
- **Analytics:** S3+Athena permite SQL analítico; DynamoDB no es eficiente para cohortes.
- **Ciclo de vida automático:** TTL + Streams + Pipes mueven datos sin operación manual.

## Puntos Clave por Componente

### API Gateway
- **¿Por qué no ALB?** Trae throttling, validación JWT y SQS directo sin configurar auto-scaling.
- **Costo:** USD $3.50/1M requests vs ALB USD $16/mes base + targets.

### App Runner
- **¿Por qué no ECS/Fargate?** Auto-scaling sencillo sin alarms; despliegue simplificado.
- **¿Por qué no Lambda?** Pool de conexiones, caché en memoria, sin cold starts.

### SQS
- **¿Por qué no Kinesis?** USD $110/mes fijo vs USD $0.40/mes variable.
- **¿Por qué no EventBridge?** USD $10/mes vs USD $0.40/mes (25x más caro).
- **¿Por qué Standard y no FIFO?** Necesitamos >3,000 TPS y el orden no importa.

### DynamoDB
- **¿Por qué On-Demand y no Provisioned?** Tráfico escolar es espinoso; sin planificación de capacidad.
- **¿Por qué Single Table?** Patrones predecibles, sin cruces complejos, menor operación.

## Defensa de Costos (lleva números)

### Desglose mensual
```
App Runner (11h/día activo):     $17
Lambda (200K invocaciones):      $0.37
DynamoDB (10M lect/escrit):      $15
SQS (10M mensajes):              $0.40
Step Functions (40 ejecuciones): $0.10
S3 + Athena:                     $5
CloudWatch/X-Ray:                $10
──────────────────────────────
Total:                          ~$48/mes
```

### Alternativas
- **Full Lambda + Provisioned:** ~$77/mes (60% más)
- **Aurora + ECS:** ~$120/mes (150% más)
- **Solo DynamoDB (sin S3):** ~$140/mes (200% más)

## Deep Dives Técnicos

### Flujo de Seguridad Multi-tenant
1. Login → Cognito JWT con `custom:school_id`
2. API Gateway valida JWT
3. App Runner llama `AssumeRoleWithWebIdentity`
4. Obtiene credenciales temporales con `PrincipalTag/school_id`
5. Cliente DynamoDB usa esas credenciales
6. IAM restringe a llaves `TENANT#school_123#*`

### Flujo SQS → Lambda → DynamoDB
1. 5,000 msgs/seg llegan a SQS
2. Event Source Mapping agrupa en 50
3. Lambda procesa batch en 2-3s
4. `BatchWriteItem` (25 ítems/llamada) a DynamoDB
5. Resultado: 5,000 escrituras individuales → 200 batch writes

### Resiliencia Sync Gobierno
- **Backoff exponencial:** 5s → 15s → 45s
- **Rate limiting:** 2s entre batches
- **Circuit breaker:** 4xx fallan inmediato
- **Patrón DLQ:** Batches fallidos a tabla de análisis
- **Reconciliación:** Lambda diaria compara nuestros registros vs API gobierno

## Estrategia de Observabilidad

### Propagación de Correlation ID
```javascript
// Cada componente agrega contexto de traza
{
  "correlation_id": "req-123-abc",
  "trace_id": "1-5f123-456def", 
  "tenant_id": "school_123",
  "service": "grade-calculator"
}
```

### Estrategia de Alertas (sin fatiga)
- **Usuario:** p95 latencia >120ms, error rate >1%
- **Sistema:** DLQ depth >10, fallos Step Functions
- **Negocio:** Mismatches en reconciliación diaria

## Preguntas de Seguimiento

**P: ¿Cómo manejas 10x de tráfico?**
R: DynamoDB On-Demand autoescala; SQS es ilimitado; Lambda aumenta concurrencia; App Runner escala horizontal; límite: API Gateway 10K RPS → múltiples regiones.

**P: ¿Y recuperación ante desastres?**
R: DynamoDB Global Tables; S3 replicación cruzada; Lambda/Step Functions via IaC; RTO ~15 min, RPO ~5 min.

**P: ¿Cómo pruebas el sistema distribuido?**
R: Unit tests por Lambda; integración con LocalStack; contract tests entre servicios; cargas en staging; chaos engineering (fallos aleatorios).

**P: ¿Mayor riesgo arquitectónico?**
R: Hot partitions en DynamoDB si un tenant concentra carga; mitigación: monitoreo + diseño de PK permite resharding; S3 como válvula para volúmenes grandes.

## Mensajes de Confianza

Recuerda:
- ✅ Todos son servicios administrados AWS (probados a escala)
- ✅ Atendemos 3 patrones de carga con la mejor opción
- ✅ Costos 60-90% menores que alternativas ingenuas
- ✅ Cumplimos latencia, throughput y compliance
- ✅ Cada decisión tiene alternativas evaluadas

## Posicionamiento Personal

**Eres el socio senior:** Ofreces criterio arquitectónico, no pides el puesto. Pensaste implicaciones de negocio y técnicas.

**Tono:** Seguro pero humilde. "Consideré X, Y, Z. Elegí Y por A/B/C y revisaría si cambia el contexto."
