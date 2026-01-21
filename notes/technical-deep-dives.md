# Profundizaciones Técnicas - Prep de Entrevista

## 1. DynamoDB Single Table (Diseño)

### Estrategia de Partition Key
```
PK Pattern: TENANT#school_id#ENTITY#entity_id
Ejemplos:
- TENANT#school_123#STUDENT#student_456
- TENANT#school_123#CONFIG
- TENANT#school_123#TEACHER#teacher_789
```

**Por qué funciona:**
- Aislamiento natural por tenant (datos co-localizados).
- Permite enforcement IAM con `dynamodb:LeadingKeys`.
- Patrones de consulta predecibles.
- Distribuye carga y evita hot partitions.

### Estrategia de Sort Key
```
SK Pattern: TYPE#attributes#timestamp
Ejemplos:
- EVAL#matematicas#Q1_2024#exam_001
- GRADE#matematicas#Q1_2024  
- EVENT#2024-01-15T10:30:00Z
- PERIODS
```

**Ejemplos de consulta:**
```javascript
// Evaluaciones de un estudiante en un periodo
PK = "TENANT#school_123#STUDENT#student_456"
SK begins_with "EVAL#matematicas#Q1_2024"

// Nota consolidada
PK = "TENANT#school_123#STUDENT#student_456"  
SK = "GRADE#matematicas#Q1_2024"

// Eventos recientes de comportamiento
PK = "TENANT#school_123#STUDENT#student_456"
SK begins_with "EVENT#"
ScanIndexForward = false, Limit = 50
```

## 2. Implementación de Seguridad Multi-tenant

### Política IAM (detalle)
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "dynamodb:GetItem",
      "dynamodb:PutItem", 
      "dynamodb:Query",
      "dynamodb:UpdateItem"
    ],
    "Resource": "arn:aws:dynamodb:*:*:table/luca-platform",
    "Condition": {
      "ForAllValues:StringLike": {
        "dynamodb:LeadingKeys": ["TENANT#${aws:PrincipalTag/school_id}#*"]
      }
    }
  }]
}
```

### Flujo de Autenticación
1. **Login:** POST /auth/login → Cognito.
2. **JWT:** Incluye claim `custom:school_id`.  
3. **Request API:** Cliente envía JWT en Authorization.
4. **API Gateway:** Valida JWT y extrae claims.
5. **AssumeRole:** App Runner llama STS con el JWT.
   ```javascript
   const params = {
     RoleArn: 'arn:aws:iam::account:role/TenantAccessRole',
     WebIdentityToken: jwtToken,
     RoleSessionName: `session-${schoolId}`,
     PrincipalTags: {
       'school_id': schoolId
     }
   };
   ```
6. **Credenciales temporales:** STS devuelve credenciales acotadas.
7. **Cliente DynamoDB:** Usa esas credenciales; IAM aplica aislamiento.

### Por qué importa
- **Compliance:** PII de menores requiere defensa en profundidad.
- **Auditabilidad:** CloudTrail registra access denied.
- **Riesgo negocio:** Brecha de datos puede cerrar la operación.
- **Seguridad dev:** Evita queries cross-tenant accidentales.

## 3. Diseño de State Machine (Step Functions)

### State Machine de Sync Gubernamental
```json
{
  "Comment": "Government sync with resilience",
  "StartAt": "QueryPendingGrades",
  "States": {
    "QueryPendingGrades": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:::function:QueryPendingGrades",
      "Next": "CheckEmpty",
      "Retry": [{
        "ErrorEquals": ["States.TaskFailed"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2.0
      }]
    },
    "CheckEmpty": {
      "Type": "Choice", 
      "Choices": [{
        "Variable": "$.pendingCount",
        "NumericGreaterThan": 0,
        "Next": "PrepBatch"
      }],
      "Default": "Success"
    },
    "PrepBatch": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:::function:PrepBatch", 
      "Next": "SendToGovernment"
    },
    "SendToGovernment": {
      "Type": "Task",
      "Resource": "arn:aws:states:::http:invoke",
      "Parameters": {
        "ApiEndpoint": "https://api.gob.mx/grades",
        "Method": "POST",
        "RequestBody.$": "$.batch",
        "Headers": {
          "Authorization": "Bearer TOKEN",
          "Idempotency-Key.$": "$.batchId"
        }
      },
      "Retry": [{
        "ErrorEquals": ["States.Http.StatusCode.503", "States.Timeout"],
        "IntervalSeconds": 5,
        "MaxAttempts": 3,
        "BackoffRate": 3.0
      }],
      "Catch": [{
        "ErrorEquals": ["States.Http.StatusCode.4XX"], 
        "Next": "LogClientError"
      }, {
        "ErrorEquals": ["States.ALL"],
        "Next": "WriteToDLQ"
      }],
      "Next": "MarkSynced"
    },
    "MarkSynced": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:::function:MarkSynced",
      "Next": "WaitRateLimit"
    },
    "WaitRateLimit": {
      "Type": "Wait",
      "Seconds": 2,
      "Next": "QueryPendingGrades"
    },
    "WriteToDLQ": {
      "Type": "Task", 
      "Resource": "arn:aws:lambda:::function:WriteToDLQ",
      "Next": "QueryPendingGrades"
    },
    "LogClientError": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:::function:LogClientError", 
      "Next": "QueryPendingGrades"
    },
    "Success": {
      "Type": "Succeed"
    }
  }
}
```

### Rasgos Clave
- **Idempotencia:** `batchId` evita procesar duplicados.
- **Backoff exponencial:** 5s → 15s → 45s para errores transitorios.  
- **Rate limiting:** Espera 2s entre batches.
- **Clasificación de errores:** 4xx fallan rápido; 5xx se reintentan.
- **Patrón DLQ:** Batches fallidos quedan para análisis.
- **Cero cómputo en espera:** Estados Wait no consumen compute.

## 4. Procesamiento SQS + Lambda

### Configuración de Event Source Mapping
```json
{
  "EventSourceArn": "arn:aws:sqs:::behavior-events-queue",
  "FunctionName": "behavior-batch-processor",
  "BatchSize": 50,
  "MaximumBatchingWindowInSeconds": 5,
  "ScalingConfig": {
    "MaximumConcurrency": 100  
  }
}
```

### Lógica de Batch en Lambda
```javascript
exports.handler = async (event) => {
  const events = event.Records.map(record => {
    const body = JSON.parse(record.body);
    return {
      PK: `TENANT#${body.school_id}#STUDENT#${body.student_id}`,
      SK: `EVENT#${body.timestamp}`,
      event_type: body.event_type,
      metadata: body.metadata,
      ttl: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000) // 30 días
    };
  });
  
  // DynamoDB BatchWriteItem acepta máximo 25 items
  const chunks = chunkArray(events, 25);
  
  for (const chunk of chunks) {
    await db.batchWriteItem({
      RequestItems: {
        'luca-platform': chunk.map(item => ({
          PutRequest: { Item: item }
        }))
      }
    });
  }
  
  return { processedCount: events.length };
};
```

### Características de Performance
- **Throughput:** 5,000 RPS → 100 invocaciones (batch 50:1).
- **Latencia:** ~2-5s end-to-end (consistencia eventual).  
- **Costo:** ~$0.37/mes por 200K invocaciones vs ~$2/mes individual.
- **Auto-scaling:** Concurrencia Lambda escala con profundidad de cola.
- **Backpressure:** SQS actúa como buffer infinito.

## 5. Arquitectura Hot/Cold Storage

### Configuración de TTL en DynamoDB
```javascript
// Al escribir eventos, agrega TTL
const event = {
  PK: `TENANT#${schoolId}#STUDENT#${studentId}`,
  SK: `EVENT#${timestamp}`,
  event_type: 'quiz_completed',
  score: 85,
  ttl: Math.floor((Date.now() + 30 * 24 * 60 * 60 * 1000) / 1000) // 30 días
};
```

### Configuración EventBridge Pipes  
```json
{
  "Name": "dynamodb-to-datalake",
  "Source": "arn:aws:dynamodb:::table/luca-platform/stream",
  "Target": "arn:aws:firehose:::deliverystream/luca-events",
  "SourceParameters": {
    "DynamoDBStreamParameters": {
      "StartingPosition": "LATEST",
      "BatchSize": 100
    },
    "FilterCriteria": {
      "Filters": [{
        "Pattern": "{\"eventName\": [\"INSERT\", \"MODIFY\"]}"
      }]
    }
  }
}
```

### Estrategia de Particionado en S3
```
s3://luca-data-lake/
├── events/
│   ├── year=2024/
│   │   ├── month=01/
│   │   │   ├── school_id=123/
│   │   │   │   └── data.parquet
│   │   │   └── school_id=456/
│   │   └── month=02/
│   └── year=2025/
└── grades/
    └── year=2024/
```

### Consultas Athena (ejemplos)
```sql
-- Patrones de comportamiento por escuela
SELECT 
  event_type,
  COUNT(*) as event_count,
  AVG(CAST(metadata.duration_seconds AS DOUBLE)) as avg_duration
FROM events 
WHERE year = '2024' 
  AND month = '01'
  AND school_id = '123'
GROUP BY event_type;

-- Análisis de cohortes
SELECT 
  DATE_TRUNC('week', timestamp) as week,
  COUNT(DISTINCT student_id) as active_students
FROM events
WHERE year = '2024' 
  AND event_type = 'lesson_completed'
GROUP BY DATE_TRUNC('week', timestamp)
ORDER BY week;
```

## 6. Observabilidad

### Patrón de Logging Estructurado
```javascript
const logger = {
  info: (event, metadata = {}) => {
    console.log(JSON.stringify({
      timestamp: new Date().toISOString(),
      level: 'INFO',
      correlation_id: getCorrelationId(),
      trace_id: process.env._X_AMZN_TRACE_ID,
      tenant_id: getTenantId(),
      service: process.env.SERVICE_NAME,
      event,
      ...metadata
    }));
  }
};

// Uso
logger.info('grade_calculated', {
  student_id: 'student_456',
  subject: 'matematicas', 
  score: 84.5,
  duration_ms: 45
});
```

### Instrumentación X-Ray
```javascript
const AWSXRay = require('aws-xray-sdk-core');
const AWS = AWSXRay.captureAWS(require('aws-sdk'));

async function calculateGrade(studentId, period) {
  const segment = AWSXRay.getSegment();
  const subsegment = segment.addNewSubsegment('calculate-grade');
  
  try {
    subsegment.addAnnotation('student_id', studentId);
    subsegment.addAnnotation('period', period);
    
    const evaluations = await getEvaluations(studentId, period);
    const rules = await getGradingRules();
    const grade = applyRules(evaluations, rules);
    
    subsegment.addMetadata('evaluations_count', evaluations.length);
    subsegment.close();
    
    return grade;
  } catch (error) {
    subsegment.addError(error);
    subsegment.close();
    throw error;
  }
}
```

### Consultas CloudWatch Insights
```
# Errores por tenant
fields @timestamp, level, event, @message
| filter tenant_id = "school_123" 
| filter level = "ERROR"
| sort @timestamp desc

# Análisis de performance
fields @timestamp, event, duration_ms
| filter event = "grade_calculated"
| stats avg(duration_ms), pct(duration_ms, 95), pct(duration_ms, 99) by bin(5m)
```

## 7. Optimización de Performance

### Connection Pooling (App Runner)
```javascript
// Cliente DynamoDB singleton con reuse de conexión
const dynamodb = new AWS.DynamoDB.DocumentClient({
  maxRetries: 3,
  retryDelayOptions: {
    base: 300
  },
  httpOptions: {
    agent: new https.Agent({
      keepAlive: true,
      maxSockets: 25,
      maxFreeSockets: 10
    })
  }
});
```

### Config Caching 
```javascript
// Cache de reglas de calificación en memoria
let configCache = new Map();
const CACHE_TTL = 5 * 60 * 1000; // 5 minutos

async function getGradingRules(tenantId, subject) {
  const key = `${tenantId}#${subject}`;
  const cached = configCache.get(key);
  
  if (cached && (Date.now() - cached.timestamp) < CACHE_TTL) {
    return cached.rules;
  }
  
  const rules = await db.get({
    TableName: 'luca-platform',
    Key: {
      PK: `TENANT#${tenantId}#CONFIG`,
      SK: 'GRADING_RULES'  
    }
  }).promise();
  
  configCache.set(key, {
    rules: rules.Item,
    timestamp: Date.now()
  });
  
  return rules.Item;
}
```

### Optimizaciones de Batch
```javascript
// Escrituras batch eficientes en DynamoDB
async function batchWrite(items) {
  const chunks = chunkArray(items, 25); // Límite DynamoDB
  
  const promises = chunks.map(async chunk => {
    let retries = 0;
    const maxRetries = 3;
    
    while (retries < maxRetries) {
      try {
        const result = await db.batchWriteItem({
          RequestItems: {
            'luca-platform': chunk.map(item => ({
              PutRequest: { Item: item }
            }))
          }
        }).promise();
        
        // Manejar items no procesados
        if (result.UnprocessedItems && 
            Object.keys(result.UnprocessedItems).length > 0) {
          await new Promise(resolve => setTimeout(resolve, 2 ** retries * 100));
          retries++;
          continue;
        }
        
        break;
      } catch (error) {
        retries++;
        if (retries >= maxRetries) throw error;
        await new Promise(resolve => setTimeout(resolve, 2 ** retries * 100));
      }
    }
  });
  
  await Promise.all(promises);
}
```
