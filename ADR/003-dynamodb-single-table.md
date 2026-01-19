# ADR-003: DynamoDB Single Table Design

---

## Contexto y Problema

El sistema requiere:
- Almacenar evaluaciones, grades consolidados, configs por tenant, eventos de comportamiento
- Queries predecibles: "dame todas las notas de este estudiante en este periodo"
- Escalamiento automático durante picos (5,000 RPS)
- Aislamiento multi-tenant a nivel infraestructura
- p95 < 120ms en reads
- Sin capacity planning manual

## Decisión

**DynamoDB On-Demand con diseño Single Table:**
- Una tabla para todos los dominios (evaluations, grades, configs, behavior events)
- Partition key compuesta: `TENANT#school_id#ENTITY#entity_id`
- Sort key: `TYPE#timestamp` o `ATTRIBUTE#value`

```
PK: TENANT#school_123#STUDENT#student_456
SK: EVAL#matematicas#Q1_2024#exam_001

PK: TENANT#school_123#STUDENT#student_456
SK: GRADE#matematicas#Q1_2024

PK: TENANT#school_123#CONFIG
SK: PERIODS
```

## Alternativas Consideradas

### Alternativa A: RDS PostgreSQL (Aurora Serverless v2)
**Descripción:** Base de datos relacional con tablas normalizadas.

**Pros:**
- Modelo relacional familiar para developers
- JOINs nativos
- Transacciones ACID multi-tabla
- SQL queries ad-hoc para analytics
- Foreign keys garantizan integridad referencial

**Contras:**
- **Capacity planning:** Necesita definir ACU min/max (costos fijos)
- **Escalamiento lento:** Toma 30-45 segundos escalar ACUs durante pico
- **Cold starts:** Aurora Serverless v2 pausa después de 5 min inactividad, warm-up ~30s
- **Costo:** Mínimo 0.5 ACU x 730 hrs x $0.12 = ~$44/mes base + I/O
- **Multi-tenancy:** Requiere RLS (Row Level Security) complejo
- **Latencia:** ~10-15ms adicional vs DynamoDB para single-item reads

**Por qué se descartó:** Modelo de datos no requiere JOINs complejos; latencia adicional incompatible con p95 < 120ms.

---

### Alternativa B: DynamoDB Multi-Table
**Descripción:** Una tabla por dominio (Evaluations, Grades, Configs, Events).

**Pros:**
- Separación clara de dominios
- Schemas independientes
- Backups/restore granular por tabla
- Permisos IAM específicos por tabla

**Contras:**
- **Costo:** 4 tablas x $1.25/mes base + RCU/WCU = overhead
- **Transacciones cross-table:** Limitadas, caras ($0.00012 por write vs $0.00065 transactional)
- **Global Secondary Indexes:** Duplicados en cada tabla
- **Joins:** Múltiples requests para queries cross-entity
- **Complejidad operativa:** 4x alarmas, 4x backups, 4x DynamoDB Streams

**Por qué se descartó:** Queries típicos no cruzan dominios; overhead operativo innecesario.

---

### Alternativa C: MongoDB Atlas (Serverless)
**Descripción:** Base de datos document-oriented managed.

**Pros:**
- Modelo document-oriented natural para datos semi-estructurados
- Flexible schema
- Agregaciones potentes
- Multi-tenant con database per tenant

**Contras:**
- **Vendor lock-in diferente:** Migración a otra solución más compleja
- **Costo:** $0.10/1M reads + $1.00/1M writes (5-10x más caro que DynamoDB)
- **Latencia:** ~20-30ms adicional por estar fuera de AWS (network hops)
- **Escalamiento:** Auto-scaling menos granular que DynamoDB
- **IAM Integration:** Requiere gestión de credenciales fuera de AWS IAM

**Por qué se descartó:** Costo significativamente mayor; integración con AWS IAM más compleja.

---

### Alternativa D: DynamoDB Provisioned Capacity
**Descripción:** DynamoDB con RCU/WCU fijos.

**Pros:**
- **Costo predecible:** $0.00013/WCU-hour, más barato que On-Demand en tráfico constante
- Mismo modelo de datos que On-Demand

**Contras:**
- **Capacity planning:** Requiere calcular RCU/WCU necesarios
- **Auto-scaling complejo:** CloudWatch alarms + scaling policies + cooldown periods
- **Throttling riesgo:** Si el tráfico excede capacity provisioned
- **Desperdicio:** Capacity subutilizada fuera de picos
- **Costo en picos:** Escalamiento reactivo puede ser más lento que la demanda

**Cálculo de costos:**
```
Provisioned (tráfico moderado):
- 50 WCU x 730 hrs x $0.00013 = $4.75/mes
- 100 RCU x 730 hrs x $0.000013 = $0.95/mes
Total: ~$6/mes + storage

On-Demand (mismo tráfico):
- 5M writes x $0.00000125 = $6.25/mes
- 10M reads x $0.00000025 = $2.50/mes
Total: ~$9/mes + storage

PERO en picos (20M writes):
Provisioned: throttling + emergency scaling
On-Demand: absorbe sin configuración
```

**Por qué se descartó:** Tráfico educativo es spiky (8am-4pm), provisioned sería over o under. Capacity planning impredicible para patrones escolares.

---

## Comparación de Alternativas


| Criterio              | Single Table | Aurora Serverless | Multi-Table | MongoDB Atlas | DDB Provisioned |
|-----------------------|--------------|-------------------|-------------|---------------|-----------------|
| Read latency p95      | <5 ms (Aceptable) | 10-15 ms (Condicional) | <5 ms (Aceptable) | 20-30 ms (No) | <5 ms (Aceptable) |
| Costo mensual         | ~$15          | ~$60              | ~$25        | ~$80          | ~$6-30 (Variable) |
| Auto-scaling          | Instant (Aceptable) | 30-45 s (Condicional) | Instant (Aceptable) | Lenta (Condicional) | Manual (No) |
| Multi-tenant IAM      | LeadingKeys (Aceptable) | RLS complejo (Condicional) | LeadingKeys (Aceptable) | App-level (No) | LeadingKeys (Aceptable) |
| Complejidad Ops       | Baja (Aceptable) | Media (Condicional) | Media-Alta (Condicional) | Media (Condicional) | Alta (No) |
| JOINs                 | App-level (Condicional) | Nativo (Aceptable) | App-level (Condicional) | Potente (Aceptable) | App-level (Condicional) |


## Justificación

**Single Table Design es óptimo porque:**

1. **Access Patterns predecibles:**
   - "Dame evaluaciones de student_X en periodo_Y" → Query con PK+SK prefix
   - "Dame config de tenant_X" → GetItem directo
   - No necesitamos queries ad-hoc cross-entity

2. **Multi-tenancy enforcement:**
   **Enforcement IAM:**
```text
Condition:
  ForAllValues:StringLike:
    dynamodb:LeadingKeys: "TENANT#<tenant_id>#*"
```
AWS rechaza cualquier query que no empiece con el tenant correcto, incluso con bug en código.

1. **Performance:**
   - Single-digit millisecond latency
   - Consistent performance durante picos
   - No cold starts (vs Aurora)

2. **Costo On-Demand:**
   - Zero capacity planning
   - Absorbe picos sin throttling
   - Escala a cero automáticamente fuera de horario

3. **Operational simplicity:**
   - Una tabla = un backup policy, un stream, un set de alarmas
   - DynamoDB Streams captura todos los cambios para data lake

## Consecuencias

### Positivas
- **Latencia garantizada:** <5ms p95 para single-item reads
- **Zero throttling:** On-Demand absorbe picos sin configuración
- **Multi-tenant seguro:** IAM enforcement a nivel infraestructura
- **Simplicidad operativa:** Una tabla, un set de alarmas
- **Costo proporcional:** Pago solo por uso real

### Negativas
- **Sin transacciones ACID multi-item:** Cada write es atómico solo dentro de un item
- **Sin JOINs:** Queries complejos requieren múltiples requests o denormalización
- **Esquema implícito:** No hay validación de schema en base de datos
- **Learning curve:** Single table design requiere modelado cuidadoso

### Mitigaciones
- **Optimistic locking:** Campo `version` previene race conditions
- **Denormalización estratégica:** Duplicar datos cuando sea necesario para evitar JOINs
- **Validation en aplicación:** Schemas Joi/Zod validan datos antes de escribir
- **Documentación:** ADR documenta access patterns y diseño de keys
- **Transacciones limitadas:** DynamoDB TransactWriteItems para casos críticos (max 25 items)
- **Data Lake en S3:** Para analytics complejos, usar Athena sobre Parquet
