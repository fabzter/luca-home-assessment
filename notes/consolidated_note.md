- [Presentación Natural del Diagrama Arquitectónico Principal](#presentación-natural-del-diagrama-arquitectónico-principal)
  - [Punto de Entrada: API Gateway](#punto-de-entrada-api-gateway)
  - [Caja de Seguridad Externa](#caja-de-seguridad-externa)
  - [Los Tres Paths Separados](#los-tres-paths-separados)
    - [Path 1: Interactivo](#path-1-interactivo)
    - [Path 2: Alta Velocidad](#path-2-alta-velocidad)
    - [Path 3: Gobierno](#path-3-gobierno)
  - [Capa de Datos](#capa-de-datos)
  - [Pipeline de Datos y Storage](#pipeline-de-datos-y-storage)
  - [TTL y Lifecycle Automático](#ttl-y-lifecycle-automático)
  - [Monitoring y Observabilidad](#monitoring-y-observabilidad)
  - [El Flujo Completo](#el-flujo-completo)
- [Escenario 3: Sync Trimestral con Gobierno - Explicación Conversacional](#escenario-3-sync-trimestral-con-gobierno---explicación-conversacional)
  - [El Contexto del Problema](#el-contexto-del-problema)
  - [El Trigger - EventBridge Scheduled](#el-trigger---eventbridge-scheduled)
  - [Step Functions Standard - La Orquestación](#step-functions-standard---la-orquestación)
  - [QueryPending - El Estado Inicial](#querypending---el-estado-inicial)
  - [PrepBatch - Preparación de Lotes](#prepbatch---preparación-de-lotes)
  - [SendBatch - El Corazón del Sistema](#sendbatch---el-corazón-del-sistema)
  - [Los Estados de Retry - Exponential Backoff](#los-estados-de-retry---exponential-backoff)
  - [WaitRate - Rate Limiting Explícito](#waitrate---rate-limiting-explícito)
  - [MarkSynced - Actualizando Estado](#marksynced---actualizando-estado)
  - [ClientError - Manejo de Errores Permanentes](#clienterror---manejo-de-errores-permanentes)
  - [DLQ - Dead Letter Queue](#dlq---dead-letter-queue)
  - [Reconcile - Verificación Final](#reconcile---verificación-final)
  - [Monitoreo y Visibilidad](#monitoreo-y-visibilidad)
  - [Configuración de Resilencia](#configuración-de-resilencia)
- [Simulacro de Entrevista Técnica - Arquitectura Luca](#simulacro-de-entrevista-técnica---arquitectura-luca)
  - [Ronda 1: Decisiones Arquitectónicas Fundamentales](#ronda-1-decisiones-arquitectónicas-fundamentales)
  - [Ronda 2: Seguridad y Multi-Tenancy](#ronda-2-seguridad-y-multi-tenancy)
  - [Ronda 3: Escalabilidad y Performance](#ronda-3-escalabilidad-y-performance)
  - [Ronda 4: Operaciones y Monitoring](#ronda-4-operaciones-y-monitoring)
  - [Ronda 5: Edge Cases y Failure Scenarios](#ronda-5-edge-cases-y-failure-scenarios)
  - [Evaluación Final](#evaluación-final)


# Presentación Natural del Diagrama Arquitectónico Principal

Bueno, te presento la arquitectura de componentes principal. Esto es lo que diseñé para resolver el problema de Luca - básicamente necesitábamos manejar tres tipos de tráfico completamente diferentes con un solo sistema, pero manteniendo isolation estricto entre escuelas.

## Punto de Entrada: API Gateway

Aquí en el inicio tenemos nuestra entrada principal, API Gateway, que va a servirnos para todos los casos del assignment. ¿Por qué empezamos ahí? Porque necesitamos un punto único de entrada que nos permita hacer tres cosas críticas: autenticación centralizada, throttling por escuela, y routing inteligente según el tipo de request.

Lo configuré para que valide automáticamente los JWTs que vienen de Cognito y extraiga el `school_id` para pasárselo downstream. También maneja rate limiting específico por tenant - si una escuela se vuelve loca enviando requests, no afecta a las demás.

## Caja de Seguridad Externa

En la caja que dice "Seguridad Externa" tenemos WAF, Cognito y IAM Roles, que están agrupados ahí porque funcionan como una unidad integrada de defense-in-depth. Primero entra en juego **WAF** - es nuestra primera línea contra ataques de injection o patrones maliciosos, especialmente importante porque manejamos PII de menores.

Después viene **Cognito**, que genera los JWTs con el `custom:school_id` claim. Y finalmente **IAM Roles**, que es donde está la magia del multi-tenancy - configuré políticas dinámicas que usan `PrincipalTag` para que sea físicamente imposible acceder a datos de otra escuela, incluso si hay bugs en el código.

## Los Tres Paths Separados

dividí todo en tres paths completamente independientes porque cada uno tiene requisitos totalmente diferentes:

### Path 1: Interactivo 

Este es para cuando los profesores registran notas durante clase. Fíjate que va directo de API Gateway a **App Runner**. ¿Por qué App Runner y no Lambda? Porque necesito garantizar p95 menor a 120ms, y App Runner me da contenedores siempre warm con connection pooling a DynamoDB. Los profesores no pueden esperar 2 segundos para que arranque una Lambda fría - se les acaba la clase.

App Runner también me permite cachear las reglas de calificación en memoria, entonces la segunda consulta de matemáticas ya no va a DynamoDB por la configuración.

### Path 2: Alta Velocidad

Acá es donde se pone divertido. Cuando 5mil estudiantes salen al recreo y todos abren la app simultáneamente, necesito un patrón anti-stampede. Fíjate que API Gateway va directo a **SQS** - no pasa por Lambda intermedia porque eso sería pagar cómputo solo para reenviar mensajes.

SQS actúa como buffer que absorbe los 5k requests por segundo y los convierte en un flujo controlado. El **Event Source Mapping** es clave aquí - configuro `BatchSize: 50` y `MaximumBatchingWindowInSeconds: 5`, entonces Lambda recibe arrays de hasta 50 mensajes por invocación. La Lambda procesa **todo el batch completo en una sola ejecución** - no mensaje por mensaje.

**Idempotencia:** Cada mensaje SQS incluye un `MessageId` único, y mi Lambda usa ese ID como idempotency key en DynamoDB con `ConditionExpression`. Si procesa el mismo mensaje dos veces (por retry), DynamoDB rechaza la segunda escritura automáticamente. El batch completo se procesa, pero los duplicados se ignoran sin fallar la operación.

En lugar de 5,000 escrituras individuales a DynamoDB, termino con 200 batch writes - es 25 veces más eficiente.

### Path 3: Gobierno

Este path es para la sincronización trimestral con la API gubernamental, que es notoriamente inestable. Uso **EventBridge** como trigger programado y **Step Functions** para la orquestación porque necesito retry declarativo, backoff exponencial, y audit trail completo.

La **Dead Letter Queue** captura los batches que fallan definitivamente para análisis manual. Step Functions me da visibilidad visual del progreso - los stakeholders pueden ver exactamente en qué paso está la sincronización sin leer logs técnicos.

## Capa de Datos

En el centro tengo **DynamoDB Single Table On-Demand**. Single table porque los patrones de acceso son predecibles - no necesito JOINs complejos, solo "dame las evaluaciones de este estudiante" o "dame el perfil de comportamiento". On-Demand porque el tráfico escolar es súper spiky - de cero a 5k RPS en el recreo.

Las **DynamoDB Streams** capturan automáticamente todos los cambios y alimentan el pipeline de analytics sin impactar la performance operacional.

## Pipeline de Datos y Storage

Acá tengo un pipeline completamente serverless: **DynamoDB Streams** → **EventBridge Pipes** → **Kinesis Firehose** → **S3 Data Lake**. 

EventBridge Pipes filtra solo los eventos INSERT/MODIFY y los transforma automáticamente. Firehose los agrupa, los comprime en formato Parquet, y los deposita en S3 particionado por año/mes/escuela. Todo esto sin escribir una sola línea de código ETL.

**S3 Data Lake** usa particionado inteligente para que Athena pueda hacer partition pruning - si consultas datos de una escuela específica, solo lee esa carpeta.

## TTL y Lifecycle Automático

DynamoDB tiene TTL configurado para 30 días, entonces los datos viejos se mueven automáticamente del storage hot al cold. Los eventos siguen siendo capturados por Streams antes de ser eliminados, así que no perdemos nada para analytics histórico.

## Monitoring y Observabilidad

**CloudWatch Logs** vienen automáticamente de todos nuestros servicios. App Runner envía logs a `/aws/apprunner/luca-platform/application`, Lambda a `/aws/lambda/grade-processor`, Step Functions a `/aws/stepfunctions/government-sync`. API Gateway tiene logging habilitado y va a su propio log group. Cada log entry incluye el `correlation_id` que generamos en el API Gateway.

**Métricas Custom** las publico desde el código de aplicación usando `boto3.client('cloudwatch').put_metric_data()`. En Lambda, envío métricas como `GradeProcessingLatency` con dimensiones `school_id` y `operation_type`. En App Runner, trackeo `InteractiveRequestCount` por escuela. Estas métricas viven en CloudWatch namespace `Luca/Platform`.

**Dashboards** están configurados en CloudWatch Dashboard llamado "Luca-Production-Overview". Tiene widgets que muestran latencia p95 por escuela usando las custom metrics, error rate desde los logs automáticos, y throughput separado por tenant. También incluyo widgets de DynamoDB (ConsumedReadCapacityUnits por GSI) y SQS (ApproximateNumberOfMessages).

**X-Ray** se habilita automáticamente en App Runner con la variable de entorno `_X_AMZN_TRACE_ID`. En Lambda, uso el decorator `@xray_recorder.capture('lambda_handler')`. API Gateway tiene X-Ray tracing enabled por defecto. Cada request lleva el trace ID que conecta: API Gateway → App Runner → DynamoDB → Streams automáticamente.

**CloudTrail** captura automáticamente todas las API calls de AWS - está habilitado a nivel de cuenta con data events para DynamoDB y management events para Step Functions/IAM. Los logs van a S3 bucket `luca-cloudtrail-logs` y también se indexan en CloudWatch Insights para queries rápidas.

**SNS Alerts** vienen de CloudWatch Alarms configurados específicamente: `Luca-P95-Latency-Alert` (threshold 120ms por escuela), `Luca-StepFunction-Failure-Alert` (3 fallas consecutivas). Los alarms publican a SNS topic `luca-ops-alerts` que tiene subscriptions a Slack webhook y emails del equipo, pagerduty.

Todos estos componentes comparten el mismo `correlation_id` - desde el log inicial en CloudWatch hasta el trace en X-Ray y el audit event en CloudTrail. Puedo seguir un request problemático end-to-end sin cambiar de herramienta.

## El Flujo Completo

Cuando un profesor registra una nota, el request viene authenticado, pasa por el path interactivo, se escribe a DynamoDB, se captura en Streams, se procesa por el pipeline, y termina en el data lake. Todo mientras mantengo isolation perfecto entre tenants y cumpliendo SLAs de latencia.

---

# Escenario 3: Sync Trimestral con Gobierno - Explicación Conversacional
---

## El Contexto del Problema

Bueno, acá viene uno de los desafíos más complicados del sistema. Cada trimestre tengo que sincronizar todas las notas de todas las escuelas con la API del gobierno, y esta API es notoriamente inestable. Se cae, tiene timeouts, rate limits estrictos, y encima tengo 48 horas máximo para completar la sincronización o hay problemas de compliance.

## El Trigger - EventBridge Scheduled

Todo empieza con **EventBridge** configurado como trigger trimestral. ¿Por qué EventBridge y no CloudWatch Events? Porque EventBridge me da más flexibilidad para debugging - puedo ver exactamente cuándo se disparó, con qué payload, y si hubo algún problema en el triggering.

La regla está configurada con `schedule(0 2 1 */3 *)` - se ejecuta el primer día de cada trimestre a las 2 AM. Elegí 2 AM porque es cuando la API gubernamental tiene menos carga y mejor response time.

## Step Functions Standard - La Orquestación

Uso **Step Functions Standard Workflow**,con Standard, cada transición de estado se persiste automáticamente. Si algo falla a las 36 horas de ejecución, puedo retomar exactamente desde donde se quedó.

El workflow tiene **timeout configurado en 47 horas** - me da 1 hora de margen antes del deadline de compliance de 48h. Si no termina en 47 horas, Step Functions lo mata automáticamente y dispara una alarma crítica.

## QueryPending - El Estado Inicial

El primer estado **QueryPending** es una Lambda que consulta DynamoDB para encontrar todas las notas pendientes de sincronización. Usa un GSI con `sync_status = 'pending'` para eficiencia.

Esta Lambda tiene **timeout de 15 minutos** porque puede estar procesando datos de 50 escuelas. Si hay muchas notas (final de año escolar), puede tomar tiempo hacer el query completo. El estado está configurado con `Retry` automático - si falla por throttling de DynamoDB, reintenta 3 veces con exponential backoff.

## PrepBatch - Preparación de Lotes

**PrepBatch** agrupa las notas en batches de 100 registros máximo. ¿Por qué 100? Porque la API gubernamental tiene límite de payload de 1MB, y cada nota promedia 8KB con todos los metadatos requeridos.

Cada batch recibe un **UUID único** que uso como idempotency key. Si envío el mismo batch dos veces, el gobierno lo acepta pero no duplica los datos - esto es crítico para reintentos.

Este estado también tiene configurado `HeartbeatTimeout: 300` segundos. Si PrepBatch no reporta progreso en 5 minutos, Step Functions lo considera colgado y lo mata para reintentar.

## SendBatch - El Corazón del Sistema

Aquí es donde está la complejidad real. **SendBatch** es una Lambda que hace el HTTP POST a la API gubernamental, pero está rodeada de un sistema completo de manejo de errores.

La Lambda tiene configurados **3 tipos de timeout**:
- **Function timeout: 900 segundos** (15 minutos) - para casos donde la API tarda mucho en responder
- **HTTP client timeout: 120 segundos** - si no hay respuesta del servidor en 2 minutos, considera timeout
- **Step Functions task timeout: 1200 segundos** - timeout a nivel de estado, incluye tiempo de retry

## Los Estados de Retry - Exponential Backoff

Cuando SendBatch falla con HTTP 503 o timeout, entra en el sistema de retry con exponential backoff:

**Retry5s**: Espera 5 segundos y reintenta. Esto maneja "blips" temporales de red o sobrecarga momentánea de la API. El estado usa `Wait` de Step Functions, que no consume recursos durante la espera.

**Retry15s**: Si falla otra vez, espera 15 segundos. Aquí estoy asumiendo que puede ser sobrecarga del servidor gubernamental - le doy más tiempo para recuperarse.

**Retry45s**: Último intento con wait de 45 segundos. Esto maneja casos como maintenance windows no anunciados o problemas serios del lado del gobierno.

**Importante**: Cada estado de retry tiene configurado `MaxAttempts: 1` - no quiero retry automático adicional en cada estado, porque ya estoy manejando la lógica de retry explícitamente.

## WaitRate - Rate Limiting Explícito

Cuando SendBatch recibe HTTP 200 OK, pasa a **WaitRate**, que implementa rate limiting de 2 requests por segundo usando `Wait` con `Seconds: 0.5`.

¿Por qué no uso Lambda con sleep? Porque Step Functions `Wait` no consume compute time - es gratis. Mi Lambda termina inmediatamente y Step Functions maneja la pausa automáticamente.

## MarkSynced - Actualizando Estado

**MarkSynced** actualiza DynamoDB para marcar el batch como sincronizado exitosamente. Usa `ConditionExpression` para asegurar que solo actualiza registros que todavía están en estado 'pending' - evita race conditions si hay múltiples ejecuciones.

## ClientError - Manejo de Errores Permanentes

Cuando SendBatch recibe HTTP 4XX (error del cliente), va directo a **ClientError** que logea el error pero continúa con el siguiente batch. Estos son errores permanentes - reintentar no va a ayudar.

ClientError escribe a CloudWatch Logs con structured logging - incluye el batch UUID, school_id, y error details para troubleshooting posterior.

## DLQ - Dead Letter Queue

Después de 3 intentos fallidos (5s → 15s → 45s), el batch va a **DLQ**. Este estado escribe el batch problemático a una SQS Dead Letter Queue para análisis manual posterior.

DLQ también dispara **SNS Alert** inmediatamente - el equipo de ops recibe notificación en Slack con el batch UUID y puede investigar el problema sin esperar al final del proceso.

## Reconcile - Verificación Final

Cuando todos los batches están procesados, **Reconcile** hace la verificación final. Consulta la API gubernamental para confirmar que recibieron todos los registros que enviamos.

Si encuentra discrepancias, crea un reporte detallado y lo envía al equipo de compliance. Si todo está correcto, marca la sincronización trimestral como completa.

## Monitoreo y Visibilidad

Durante toda la ejecución, puedo ver el progreso en tiempo real en **AWS Step Functions Console**:
- **Graph view** muestra visualmente en qué estado está cada ejecución
- **Execution History** me da timeline exacto con timestamps
- **CloudWatch Logs** de cada Lambda incluyen correlation IDs

Si algo falla, no necesito debugging complejo - la consola me muestra exactamente qué batch falló, en qué estado, y por qué. Para auditorías de compliance, tengo trazabilidad completa desde el trigger inicial hasta cada batch individual.

## Configuración de Resilencia

Todo el workflow está configurado para ser **resilient by design**:
- **Checkpointing automático**: Step Functions persiste estado después de cada transición
- **Idempotencia garantizada**: Cada batch tiene UUID único
- **Timeout escalonados**: Desde 120s HTTP hasta 47h workflow completo
- **Retry inteligente**: Exponential backoff específico para patrones de falla de APIs gubernamentales
- **Fallback manual**: DLQ + SNS para intervención humana cuando es necesario

La belleza de Step Functions es que toda esta lógica compleja está declarada en JSON - no hay código custom para manejar estados, timeouts, o retries. AWS maneja la infraestructura, yo solo defino el workflow.

---

# Simulacro de Entrevista Técnica - Arquitectura Luca

*Rol: Entrevistador Senior - Jesús Hergueta (CTO Luca)*

---

## Ronda 1: Decisiones Arquitectónicas Fundamentales

**ENTREVISTADOR:** "Veo que dividiste el sistema en tres paths separados. ¿Por qué no usar un solo path con routing interno? Esto añade complejidad operacional significativa."

**CANDIDATO:** Excelente pregunta. Probé un enfoque monolítico inicialmente, pero los patrones de carga son fundamentalmente incompatibles. Path 1 necesita p95 <120ms con warm containers - si uso Lambda, los cold starts de 2-3 segundos matan la experiencia del profesor durante clase. Path 2 maneja 5k RPS spiky - necesito buffering que App Runner no puede proveer eficientemente. Path 3 requiere workflows de 48 horas con retry declarativo - imposible con Lambda timeout máximo de 15 minutos. Cada path está optimizado para su patrón específico.

**ENTREVISTADOR:** "Interesante. Pero esto significa tres pipelines de deployment, tres sets de métricas, tres puntos de falla. ¿Cómo justificas esa complejidad operacional?"

**CANDIDATO:** Tienes razón sobre la complejidad, pero es controlled complexity. Los tres paths comparten la misma capa de datos (DynamoDB), mismo sistema de seguridad (IAM + multi-tenancy), y mismo pipeline de observabilidad. El deployment sí se triplica, pero cada path es independiente - si Path 2 tiene un bug, no afecta a los profesores en Path 1. Además, puedo escalar y optimizar cada uno independientemente según sus métricas específicas.

**ENTREVISTADOR:** "Hablemos de costos. App Runner + DynamoDB on-demand + Step Functions. ¿Hiciste projecciones? Esto puede ser 3-4x más caro que una solución Lambda monolítica."

**CANDIDATO:** Hice el análisis completo. App Runner cuesta ~$50/mes por contenedor, pero elimino 100% de cold starts. DynamoDB on-demand vs provisioned me ahorra ~40% porque el tráfico escolar es súper spiky - de 0 a 5k RPS en recreos. Step Functions sí es caro ($25 por millón de state transitions), pero solo corre trimestralmente. El costo total es ~$800/mes vs $400 con Lambda puro, pero la diferencia en SLA compliance vale 10x eso en penalidades gubernamentales.

---

## Ronda 2: Seguridad y Multi-Tenancy

**ENTREVISTADOR:** "Dices que usas IAM LeadingKeys para multi-tenancy. ¿Qué pasa si hay un bug en el JWT parsing? ¿O si Cognito está down?"

**CANDIDATO:** Defense-in-depth exactamente para eso. Primer layer: WAF bloquea inyecciones antes de llegar a Cognito. Segundo layer: Cognito valida JWT signature - si está corrupto, rechaza automáticamente. Tercer layer: IAM policy usa `${aws:PrincipalTag/school_id}` del token validado - es físicamente imposible acceder a datos de otra escuela incluso con bugs de aplicación. Si Cognito está down, todo el sistema se degrada gracefully - prefiero downtime total que data leak.

**ENTREVISTADOR:** "Pero IAM policies tienen límites. ¿Qué pasa cuando tengas 500 escuelas? ¿Y el performance impact de esa policy evaluation en cada request?"

**CANDIDATO:** Excelente punto. IAM policy size limit es 2KB, pero mi policy usa wildcard pattern - una sola condición `LeadingKeys: ["TENANT#${aws:PrincipalTag/school_id}#*"]` funciona para infinitas escuelas. Performance impact es <5ms según mis benchmarks - IAM evaluation es local en cada servicio AWS. Alternativa sería application-layer filtering, pero eso requiere confiar 100% en mi código - prefiero defense-in-depth a nivel de infraestructura.

**ENTREVISTADOR:** "Hablemos de PII. Tienes datos de menores distribuidos en DynamoDB, S3, CloudWatch logs. ¿Cómo garantizas compliance con protección de datos?"

**CANDIDATO:** Encryption everywhere. DynamoDB tiene KMS encryption at-rest con customer managed keys por escuela. S3 Data Lake usa SSE-KMS con rotation automática. CloudWatch logs tienen encryption enabled y retention 30 días. Crítico: jamás logueo PII directamente - uso hashed IDs y correlation IDs. X-Ray traces no capturan payload, solo metadata. CloudTrail está en bucket separado con MFA delete y legal hold.

---

## Ronda 3: Escalabilidad y Performance

**ENTREVISTADOR:** "DynamoDB single table. Bold choice. ¿Qué pasa cuando una escuela grande genera hot partitions? ¿Tu GSI puede manejar queries cross-tenant eficientemente?"

**CANDIDATO:** Diseñé el partition key específicamente para eso: `TENANT#{school_id}#{entity_type}#{id}`. Cada escuela está 100% aislada en partitions separadas - imposible hot partition cross-tenant. Para queries cross-tenant (reportes gubernamentales), uso el GSI con `sync_status` como PK - distribuye load uniformemente. Peor caso: una escuela mega grande puede causar hot partition interna, pero DynamoDB on-demand auto-split maneja eso transparentemente.

**ENTREVISTADOR:** "Okay, pero ¿qué pasa cuando necesites agregar un nuevo access pattern? Single table significa schema rigidity."

**CANDIDATO:** Tienes razón, es el trade-off principal. Pero analicé los access patterns exhaustivamente - son muy predecibles en educación: "get student grades", "get class roster", "sync by date range". Si necesito nuevo pattern, puedo agregar GSI (hasta 20 permitidos) o usar Sparse Index pattern. Alternativa sería RDS PostgreSQL, pero perdería el auto-scaling y multi-tenant isolation que necesito.

**ENTREVISTADOR:** "SQS + Lambda para high volume. ¿Por qué no Kinesis Data Streams? ¿Y cómo manejas exactly-once delivery?"

**CANDIDATO:** Kinesis requiere pre-sharding y capacity planning - no funciona para tráfico escolar impredecible. SQS auto-escala infinitamente y absorbe cualquier spike. Exactly-once: cada mensaje incluye `MessageId` único, mi Lambda usa eso como idempotency key en DynamoDB con `ConditionExpression`. Si procesa el mismo mensaje dos veces (retry), DynamoDB rechaza automáticamente la segunda escritura. El batch completo se procesa, duplicados se ignoran sin fallar.

---

## Ronda 4: Operaciones y Monitoring

**ENTREVISTADOR:** "Veo CloudWatch + X-Ray + CloudTrail. ¿Cómo troubleshooteas un request que falla cross-service? ¿Y qué pasa si tienes 1000 requests fallando simultáneamente?"

**CANDIDATO:** Correlation ID es clave. Generado en API Gateway, propagado automáticamente: CloudWatch logs lo incluyen, X-Ray lo usa como trace ID, CloudTrail lo captura en eventos. Para un request específico, busco el correlation ID y veo toda la cadena: logs estructurados → trace timing → audit events. Para 1000 fallas simultáneas, CloudWatch Insights me da queries agregadas por error pattern, X-Ray service map muestra dónde está el bottleneck visualmente.

**ENTREVISTADOR:** "¿Y si hay un data corruption en DynamoDB? ¿Tu pipeline de S3 te ayuda a recovery?"

**CANDIDATO:** DynamoDB Streams captura every change con exact timestamp - antes de TTL deletion. Si detecto corruption, puedo replay desde S3 Data Lake hasta el punto exacto de falla. EventBridge Pipes mantiene ordering y incluye change metadata. También tengo DynamoDB Point-in-Time Recovery habilitado (35 días). Worst case: combino PITR para structure + S3 replay para data = recovery completo.

---

## Ronda 5: Edge Cases y Failure Scenarios

**ENTREVISTADOR:** "Scenario: Es lunes 8 AM, inicio de clases. API Gateway está down. ¿Qué pasa con los tres paths?"

**CANDIDATO:** Total outage, pero degraded gracefully. Path 1 (profesores): App Runner sigue vivo pero inaccessible - pierden entrada de notas durante downtime. Path 2 (estudiantes): SQS buffer mantiene mensajes hasta 14 días, procesamiento resume automáticamente cuando API Gateway regresa. Path 3 (gobierno): Step Functions continúa ejecución, solo se afectan nuevas executions. CloudWatch alarma + SNS alert inmediato. Recovery: API Gateway multi-AZ, pero si falla completamente, necesito Route 53 failover a región secundaria.

**ENTREVISTADOR:** "¿Y si hay un AWS region outage completo durante sync gubernamental crítico?"

**CANDIDATO:** Nightmare scenario, pero planificado. Step Functions execution history se replica automáticamente cross-region. Tengo S3 cross-region replication para checkpoints. En región backup: despiego state machine idéntico, cargo último checkpoint desde S3, resume desde punto exacto de falla. Pérdida máxima: ~5 minutos de progreso. Compliance deadline se mantiene porque tengo 47 horas de buffer built-in.

**ENTREVISTADOR:** "Última pregunta hard: Un DBA junior borra accidentalmente toda la tabla DynamoDB production. Game over?"

**CANDIDATO:** Respiración profunda... pero no game over. Primer layer: Point-in-Time Recovery hasta 35 días - restauro tabla completa a timestamp exacto antes del delete. Segundo layer: S3 Data Lake tiene every change via Streams - puedo rebuild desde raw events si PITR falla. Tercer layer: DynamoDB tiene deletion protection enabled - requiere explicit disable + confirmation. Cuarto layer: IAM policies restringen delete operations a roles específicos con MFA required. Recovery time: ~2 horas para PITR complete.

---

## Evaluación Final

**ENTREVISTADOR:** "Arquitectura sólida. Me impresiona el nivel de detail en resilience planning. Dos concerns: costo operacional y complexity overhead. ¿Cómo convencerías a finance team que esto vale la inversión?"

**CANDIDATO:** ROI directo: compliance penalties por data breach o missed deadlines pueden ser $100K+. Esta arquitectura elimina esos riesgos completamente. SLA compliance mejora customer retention - una escuela perdida cuesta $50K annual revenue. Operational complexity sí existe, pero cada componente tiene clear ownership y monitoring. Comparado con managing custom retry logic, database sharding, y manual failover procedures - esta complejidad es managed por AWS, no por nuestro equipo.

**ENTREVISTADOR:** "Bien defendido. ¿Qué cambiarías en v2 del sistema?"

**CANDIDATO:** Tres optimizaciones: 1) EventBridge custom bus para mejor event routing entre paths, 2) DynamoDB Global Tables para multi-region activo, 3) API Gateway caching layer para repeated queries. Pero honest assessment: esta arquitectura funciona para los próximos 2-3 años sin major changes. Es boring technology que escala, y eso es exactamente lo que necesita una startup en growth phase.

---

*Resultado: Arquitectura técnicamente sólida con justificación business clara. Candidato demuestra deep understanding de trade-offs y failure scenarios.*

