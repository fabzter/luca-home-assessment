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

*La clave de esta arquitectura es que cada path está optimizado para su patrón específico de carga, pero todos comparten la misma infraestructura de datos y seguridad. Es boring technology que funciona, optimizada para patrones educativos reales.*
