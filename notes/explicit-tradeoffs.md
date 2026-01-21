# Análisis Explícito de Trade-offs

Documento que consolida decisiones, alternativas, costos y justificaciones de los ADRs en un solo lugar para la defensa en entrevista. Enfocado en cumplimiento y operación para datos educativos (PII de menores).

---

## 1. Patrón Arquitectónico: Tres Paths vs Monolito

### ✅ Decisión: Separación en Tres Ps
- **Path 1:** App Runner (interactivo)  
- **Path 2:** SQS + Lambda (alto volumen)ath
- **Path 3:** Step Functions (sincronización gobierno)

### Alternativas Rechazadas

**❌ Lambda Monolítico**
- **Motivo:** Cold starts rompen p95 <120ms
- **Costo:** Requeriría ~USD $200/mes en concurrency provisionada
- **Técnico:** Timeout 15min insuficiente para sync gubernamental

**❌ ECS/Fargate Completo**  
- **Motivo:** Over-engineering para escala actual
- **Costo:** ~USD $450/mes (6 contenedores 24/7) vs ~$150/mes híbrido
- **Ops:** ALB complejo, políticas de auto-escalado manuales

**❌ Serverless Total (Lambda en todo)**
- **Motivo:** Latencia incompatible (<120ms p95)  
- **Performance:** Cold starts 500-2000ms
- **Arquitectura:** Requeriría cadenas Lambda complejas

### Trade-off Aceptado
Más componentes a monitorear vs desempeño optimizado por tipo de carga.

---

## 2. Cómputo: Híbrido App Runner + Lambda

### ✅ Decisión: Modelo Híbrido
- **Interactivo:** App Runner (contenedores warm)
- **Batch:** Lambda (event-driven)
- **Programado:** Lambda (jobs nocturnos)

### Alternativas Rechazadas

**❌ Lambda con Concurrency Provisionada**
- **Costo:** ~$77/mes vs ~$45/mes híbrido (41% ahorro)
- **Desperdicio:** Capacidad provisionada fuera de horario escolar
- **Técnico:** Sigue teniendo overhead de conexión a DynamoDB

**❌ Todo en App Runner**
- **Motivo:** Ineficiente para batch/scheduler
- **Costo:** ~$90/mes (3 servicios always-on) vs ~$45/mes híbrido
- **Desperdicio:** Contenedores esperando SQS 24/7

**❌ ECS/Fargate Completo**
- **Costo:** Mínimo ~$85/mes (contenedores always-on)
- **Ops:** ALB (+USD $16/mes) + scaling manual
- **Over-engineering:** Demasiado para cargas escolares espinosas

### Trade-off Aceptado
Dos modelos de despliegue (contenedores + funciones) vs optimización de costo y latencia.

---

## 3. Base de Datos: DynamoDB Single Table vs Alternativas

### ✅ Decisión: DynamoDB On-Demand Single Table
- **Diseño:** Entidades en una tabla con keys compuestas
- **Escalado:** Sin planeación de capacidad; escala instantáneo
- **Costo:** ~USD $15/mes estimado

### Alternativas Rechazadas

**❌ PostgreSQL (Aurora Serverless v2)**
- **Motivo:** Latencia y escalado incompatibles
- **Latencia:** +10-15ms vs DynamoDB <5ms
- **Escalado:** 30-45s en picos
- **Costo:** ~USD $60/mes mínimo vs $15/mes
- **Cold starts:** 30s tras 5 min inactivo

**❌ DynamoDB Multi-Tabla**  
- **Costo:** ~$25/mes (4 tablas) vs $15/mes single table
- **Ops:** 4x backups/streams/alarmas
- **Cross-table:** Transacciones limitadas y caras

**❌ MongoDB Atlas**
- **Costo:** ~$80/mes (5-10x DynamoDB)
- **Latencia:** +20-30ms (salir de AWS)
- **Integración:** IAM complejo fuera de AWS

**❌ DynamoDB Provisioned Capacity**
- **Planeación:** Cálculo manual RCU/WCU
- **Riesgo:** Throttling si el tráfico supera lo provisionado
- **Patrón:** Tráfico escolar es impredecible

### Trade-off Aceptado
Sin JOINs + flexibilidad de esquema vs garantías relacionales.

---

## 4. Seguridad: IAM LeadingKeys vs Filtros en App

### ✅ Decisión: Enforcement Multi-tenant en IAM
- **Método:** Condición `dynamodb:LeadingKeys` fuerza prefijo de tenant
- **Garantía:** Seguridad a nivel infraestructura; imposible de puentear

### Alternativas Rechazadas

**❌ Solo Filtrado en Aplicación**
- **Motivo:** Riesgo humano inaceptable con PII de menores
- **Riesgo:** Un olvido de WHERE expone todos los tenants
- **Compliance:** Sin defensa en profundidad

**❌ Base de Datos por Tenant**
- **Costo:** ~$125/mes overhead (100 tenants × ~$1.25)
- **Ops:** 100x tablas/backups/migraciones/monitoreo
- **Límites AWS:** 2,500 tablas/región

**❌ Middleware Interceptor**
- **Motivo:** Sigue en capa app; punto único de falla
- **Performance:** Overhead de parseo en cada request
- **Complejidad:** ORM custom difícil de depurar

### Trade-off Aceptado
Complejidad en auth (+20-30ms STS) vs aislamiento garantizado.

---

## 5. Integración Gobierno: Step Functions vs Lógica Custom

### ✅ Decisión: Step Functions Standard Workflow
- **Capacidades:** Workflows visuales, retry declarativo, audit trail
- **Duración:** Hasta 1 año de ejecución
- **Costo:** ~$10/año volumen esperado

### Alternativas Rechazadas

**❌ Lambda con Retry Custom**
- **Motivo:** Reinventar backoff/DLQ que ya da Step Functions
- **Complejidad:** 100+ líneas a mantener
- **Timeout:** 15min → requeriría chaining para esperas largas
- **Debug:** Solo logs; sin vista visual

**❌ Cadena SQS + Lambda**
- **Límite:** Visibility 12h insuficiente para SLA 48h
- **Coordinación:** Sin estado de workflow
- **Auditoría:** Sin vista central de progreso

**❌ EventBridge + Lambda + estado en DynamoDB**
- **Motivo:** Duplica Step Functions en código
- **Mantenimiento:** Dashboard custom para ver estado
- **Ineficiencia:** Lambda cobra mientras espera backoff

**❌ Step Functions Express**
- **Motivo:** Límite 5 minutos; sin historial
- **Costo:** Barato pero inútil para sync larga

### Trade-off Aceptado
Lock-in AWS vs resiliencia probada.

---

## 6. Pipeline de Datos: EventBridge Pipes vs Código Custom

### ✅ Decisión: EventBridge Pipes + Kinesis Firehose
- **Arquitectura:** DynamoDB Streams → Pipes → Firehose → S3
- **Código:** Cero ETL custom
- **Costo:** ~$2/mes volumen esperado

### Alternativas Rechazadas

**❌ Lambda Procesando Streams**
- **Complejidad:** 150+ líneas para filtrar/transformar/batchear
- **Costo:** ~$8/mes (4x) por invocaciones
- **Mantenimiento:** Manejo de errores/DLQ/monitoreo en código

**❌ Kinesis Data Streams + Lambda**
- **Costo:** ~$19/mes mínimo (shards) vs $2/mes Pipes
- **Over-engineering:** Streams ya ordena; agrega servicio innecesario
- **Complejidad:** Capacidad de shards a planificar

**❌ Lambda Directo a S3**
- **Límite:** 10GB Lambda; buffering en memoria
- **Durabilidad:** Si falla Lambda se pierde el batch
- **Formato:** Escribir Parquet en Lambda es costoso

**❌ Glue ETL Jobs**
- **Latencia:** Snapshots diarios vs casi real time
- **Costo:** ~$30/mes vs $2/mes streaming
- **Ineficiencia:** Export completos vs cambios incrementales

### Trade-off Aceptado
Tooling AWS específico vs simplicidad operativa.

---

## 7. Jobs en Background: Lambda Nocturna vs Tiempo Real

### ✅ Decisión: Consolidación Nocturna (Lambda)
- **Horario:** 02:00 via EventBridge Scheduler
- **Eficiencia:** Batch reduce cómputo
- **Consistencia:** Eventual es aceptable para notas

### Alternativas Rechazadas

**❌ Consolidar en Escritura (Tiempo real)**
- **Latencia:** 300ms vs 50ms (6x más lento)
- **Cómputo:** 55 cálculos por 10 evaluaciones vs 1 batch
- **UX:** Retraso en clase es inaceptable

**❌ Consolidar en Lectura (Lazy)**
- **Latencia:** 250ms vs <120ms requerido  
- **Cache:** Invalidation compleja
- **Cold start:** Primera lectura tras cambios es lenta

**❌ Trigger DynamoDB Streams**
- **Pro:** Cerca de tiempo real
- **Contra:** Ineficiente vs batch nocturno; más componentes a operar

### Trade-off Aceptado
Freshness eventual vs eficiencia y buena UX.

---

## 8. Ingesta Alto Volumen: SQS vs Procesamiento Directo

### ✅ Decisión: API Gateway → SQS → Lambda Batch
- **Patrón:** Anti-stampede absorbe 5k→100 RPS estable
- **Costo:** ~$0.40/MM vs ~$2.00/MM directo a Lambda
- **Escala:** Maneja picos sin throttling

### Alternativas Rechazadas

**❌ Lambda Directo**
- **Concurrencia:** 5k RPS supera límite por defecto
- **Costo:** 5x más caro
- **Carga:** 5,000 writes individuales vs batch

**❌ Kinesis Data Streams**
- **Costo:** ~$110/mes fijo (shards) vs ~$5/mes SQS
- **Sobre-provisión:** Shards 24/7 para tráfico espinoso
- **Complejidad:** Plan de shards

**❌ EventBridge**
- **Costo:** ~$40/mes vs $0.40/mes
- **Over-engineering:** No se necesita routing avanzado
- **Latencia:** Más saltos de red

### Trade-off Aceptado
Consistencia eventual (cola) vs absorción de tráfico y costo bajo.

---

## 9. Almacenamiento: Hot/Cold vs Único Store

### ✅ Decisión: Estrategia Hot/Cold
- **Hot (DynamoDB):** Últimos 30 días para consultas interactivas
- **Cold (S3 Parquet):** Históricos para analytics
- **Ahorro:** ~$1,332/año vs todo en DynamoDB

### Alternativas Rechazadas

**❌ Todo DynamoDB (sin TTL)**
- **Costo:** ~$1,500/año vs ~$168/año híbrido (9x)
- **Performance:** Ineficiente para analytics masivo
- **Desperdicio:** 95% consultas son data reciente

**❌ Todo S3 (sin Hot)**
- **Latencia:** Consultas 2-5s vs <100ms requerido
- **Costo query:** $0.50 por 100GB escaneados
- **UX:** Profesores esperando segundos por perfiles

**❌ Mixto SQL + NoSQL**
- **Complejidad:** Múltiples stores a operar
- **Consistencia:** Sincronización cruzada difícil
- **Ops:** Backups/monitoreo/escala duplicados

### Trade-off Aceptado
Complejidad (dos stores) vs ahorro masivo y desempeño correcto.

---

## 10. Observabilidad: CloudWatch vs Herramientas Externas

### ✅ Decisión: CloudWatch + X-Ray (Stack Nativo)
- **Integración:** Nativa en AWS
- **Costo:** ~$15/mes vs $200+/mes externos
- **Simplicidad:** Métricas integradas, sin infra adicional

### Alternativas Rechazadas

**❌ ELK Self-Hosted**
- **Costo:** ~$166/mes (3 nodos) vs $15/mes
- **Ops:** Gestión de clúster, sharding, upgrades
- **Complejidad:** Pipelines, retención, índices

**❌ Datadog**
- **Costo:** $200+/mes (hosts + logs)
- **Lock-in:** Otra dependencia externa
- **Over-engineering:** No se requieren features avanzadas

**❌ Grafana + Prometheus**
- **Self-managed:** Infra propia
- **Costo:** Instancias EC2 + operación
- **Integración AWS:** Exporters y config extra

### Trade-off Aceptado
Lock-in ecosistema AWS vs simplicidad y costo.

---

## Resumen: Por Qué Esta Arquitectura

**Decisiones guiadas por costo:**
- Compute híbrido ahorra ~$77→$45/mes (41%)
- Hot/Cold ahorra ~$1,332/año (90%)  
- SQS vs Lambda directo ahorra ~$1.60/MM eventos

**Decisiones guiadas por latencia:**
- App Runner elimina cold starts en path interactivo
- DynamoDB vs PostgreSQL ahorra 10-15ms por query
- Notas precalculadas vs on-demand ahorra ~200ms por perfil

**Decisiones guiadas por fiabilidad:**
- Step Functions ofrece retry y visibilidad probadas
- IAM LeadingKeys evita fugas por error humano
- SQS como buffer evita fallos por picos

**Decisiones guiadas por simplicidad:**
- EventBridge Pipes elimina 150+ líneas de ETL custom
- Servicios gestionados reducen operación
- Single table simplifica monitoreo

**Costo total de la arquitectura: ~USD $45/mes vs ~$400+/mes alternativas.**

Tema consistente: **Elegir tecnología aburrida que funcione, optimizada para patrones educativos (picos, costo sensible, cumplimiento crítico).**
