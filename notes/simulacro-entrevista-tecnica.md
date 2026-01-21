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
