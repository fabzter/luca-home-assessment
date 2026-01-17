# Home Assessment: Architecture & Design Strategy

## 1. Principios de Diseño

Mi diseño busca ser pragmático. Estas son mis motivaciones para cada decisión:

* **Simplicidad Operativa:** Priorizo productos gestionados (Managed Services) en lugar de gestionar infraestructura propia. Evito Kubernetes o clusters de Kafka. Busco que los equipos se enfoquen en el producto, no en manejar infraestructura.
* **Serverless, donde haga sentido:** Uso Serverless (Lambda, SQS) para tráfico impredecible y masivo tratando de proteger costos. Uso contenedores en App Runner donde la latencia en *cold start* es crítica, evitando pagar *provisioned concurrency* en Lambda.
* **Developer Experience:** Busco reducir la complejidad mental del equipo (y la mía) separando ciertos dominios y evitando cadenas de Lambdas difíciles de monitorear, entre otros.
* **Resiliencia por diseño:** Siempre desarrollo pensando en que las piezas van a fallar.
* **Compliance y Seguridad:** La protección de datos (PII de menores) y el aislamiento entre escuelas (Multi-tenant) se manejan a nivel infraestructura e IAM. Es inaceptable que un tenant vea datos de otro.
* **Simplicidad:** Trato de no hacer sobre ingeniería, pero dejando margen para iteraciones cercanas.

## 2. Suposiciones (Key Assumptions)

Asumí y llené con mi imaginación educadamente bastantes gaps en la descripción del problema. Estas son algunas de las suposiciones que tomé:

* **Perfil de Tráfico:** Predecible pero explosivo. Se concentra de Lunes a Viernes de 7:00 a 12:00 hrs.
* **Volumen:** Por poner un número para dimensionar, definí "picos altos" como **~5,000 RPS** durante eventos masivos.
* **Latencia:** El requerimiento de **p95 < 120ms** implica que la lectura interactiva (ver perfil, dashboard) y el cálculo de notas deben ser en tiempo real. La ingesta de comportamiento puede ser de consistencia eventual.

## 3. Arquitectura de Contexto

Fronteras del sistema.
```mermaid
flowchart TD
    %% --- External Actors ---
    Student([Estudiante])
    Prof([Profesor])
    GovAPI[("Sistema Gobierno\n(Legacy API)")]

    %% --- Public Edge Layer ---
    subgraph Edge ["Public Edge & Security"]
        WAF["AWS WAF (Firewall)"]
        APIG["API Gateway\n(HTTP API + JWT Authorizer)"]
    end

    %% --- Compute Layer ---
    subgraph Compute ["Compute & Ingestion"]
        direction TB
        %% Síncrono
        AppRunner["App Runner Service\n(Core API / Node.js)"]
        
        %% Asíncrono (Ingesta)
        SQS["SQS Queue\n(Behavior Events)"]
        Worker["Lambda Function\n(Batch Processor)"]
        
        %% Asíncrono (Sync Gobierno)
        Scheduler(("EventBridge\nScheduler"))
        StepF["Step Functions\n(Sync Workflow)"]
    end

    %% --- Data Layer ---
    subgraph Data ["Data & Persistence"]
        DDB[("DynamoDB\n(Single Table)")]
        Stream["DynamoDB Streams"]
    end

    %% --- Observability & Analytics ---
    subgraph Obs ["Observability & Analytics"]
        CW["CloudWatch\n(Logs & Metrics)"]
        XRay["AWS X-Ray\n(Distributed Tracing)"]
        
        %% Data Lake Pipeline
        Pipes["EventBridge Pipes"]
        Firehose["Kinesis Firehose"]
        S3[("S3 Data Lake\n(Parquet / Audit)")]
    end

    %% --- Relaciones (Flows) ---
    
    %% 1. Traffic Entry
    Student & Prof -->|HTTPS| WAF
    WAF --> APIG
    
    %% 2. Synchronous Flow (Profesor/Lectura)
    APIG -->|"Route: /grades, /profile"| AppRunner
    AppRunner <-->|"SDK (Keep-Alive)"| DDB
    AppRunner -.->|"Async Logs"| CW
    
    %% 3. Asynchronous Flow (Estudiante/Ingesta)
    APIG -->|"Integration: SQS"| SQS
    SQS -->|"Trigger (Batch: 50)"| Worker
    Worker -->|BatchWrite| DDB
    Worker -.->|"Logs/Traces"| CW
    
    %% 4. Government Sync Flow
    Scheduler -->|"Cron Trigger"| StepF
    StepF <-->|"Read Data"| DDB
    StepF <-->|"HTTP w/ Retry"| GovAPI
    StepF -.->|"Execution History"| CW

    %% 5. Data Pipeline & Audit
    DDB -.->|"Change Event"| Stream
    Stream -->|Filter| Pipes
    Pipes -->|Buffer| Firehose
    Firehose -->|Archive| S3
    
    %% 6. Tracing
    APIG -.->|"Trace ID"| XRay
    AppRunner & Worker & StepF -.->|"Segment Data"| XRay

    %% Styles
    classDef actor fill:#eceff1,stroke:#37474f,stroke-width:2px;
    classDef edge fill:#e8f5e9,stroke:#2e7d32,stroke-dasharray: 5 5;
    classDef compute fill:#e3f2fd,stroke:#1565c0;
    classDef data fill:#fff3e0,stroke:#ef6c00;
    classDef obs fill:#f3e5f5,stroke:#7b1fa2;

    class Student,Prof,GovAPI actor;
    class WAF,APIG edge;
    class AppRunner,SQS,Worker,Scheduler,StepF compute;
    class DDB,Stream data;
    class CW,XRay,Pipes,Firehose,S3 obs;
```

Descripción de Componentes y Flujos
A. Capa de Seguridad (Edge)
AWS WAF: Implementamos reglas de Rate Limiting por IP aquí para mitigar ataques DDoS antes de que toquen nuestra infraestructura de cómputo.

API Gateway: Gestiona la autenticación (JWT) y enruta el tráfico:

Tráfico interactivo -> App Runner.

Eventos de alta velocidad -> SQS (Integración directa).

B. Capa de Cómputo (Compute)
App Runner (Core Síncrono): Servicio de contenedores para lógica de negocio compleja (Cálculo de Notas). Mantiene conexiones calientes a la BD para latencia mínima.

SQS + Lambda Worker (Periferia Asíncrona):

SQS: Actúa como buffer "Anti-Stampede".

Lambda Worker: Consume mensajes en lotes (ej. 50 eventos) y realiza una sola escritura Batch a la base de datos, optimizando costos y conexiones.

Step Functions: Orquesta la sincronización con el Gobierno, manejando reintentos y esperas sin bloquear recursos.

C. Capa de Datos y Observabilidad
DynamoDB: Fuente de verdad única.

Pipeline de Analytics: Usamos EventBridge Pipes y Firehose para capturar todos los cambios en la BD (Streams) y archivarlos en S3 para auditoría y análisis, sin escribir código ETL manual.

Observabilidad:

CloudWatch: Centraliza logs estructurados (JSON).

X-Ray: Provee trazabilidad distribuida end-to-end usando el Trace-ID inyectado desde el API Gateway.

### El Estudiante (Ingesta Masiva / Anti-Stampede)
**Objetivo:** Absorber picos de ~5,000 RPS sin degradar la base de datos ni el servicio principal.
**Estrategia:** Desacoplamiento total usando el patrón *Queue-Based Load Leveling*.
```mermaid
sequenceDiagram
    autonumber
    actor Student as Estudiante
    participant WAF as AWS WAF
    participant APIG as API Gateway
    participant SQS as SQS Queue
    participant Worker as Lambda Worker
    participant DDB as DynamoDB

    Note over Student, APIG: Pico de Tráfico (e.g., Fin de Clase)
    
    Student->>WAF: POST /behavior (Evento)
    WAF->>APIG: Allow Request
    
    %% Integration Proxy (No Lambda)
    Note right of APIG: Validación JWT +<br/>Integración Directa SQS
    APIG-->>SQS: Enqueue Message
    
    %% Ack Inmediato
    APIG-->>Student: 202 Accepted
    
    %% Procesamiento Asíncrono
    loop Batch Processing
        Worker->>SQS: Poll (Batch Size: 50)
        activate Worker
        SQS-->>Worker: Retorna 50 eventos
        
        Worker->>Worker: Deduplicación & Validación
        
        %% Escritura Eficiente
        Worker->>DDB: BatchWriteItem (50 items)
        DDB-->>Worker: Success
        
        deactivate Worker
    end
```

### El Profesor (Core Interactivo / Baja Latencia)
Garantizar lectura y cálculo de notas en <120ms (p95).
```mermaid
sequenceDiagram
    autonumber
    actor Prof as Profesor
    participant APIG as API Gateway
    participant Core as App Runner (Node.js)
    participant DDB as DynamoDB

    Prof->>APIG: POST /grades (Subir Notas)
    APIG->>Core: Forward Request
    
    activate Core
    %% Memoria Caliente
    Note right of Core: Memory Hit:<br/>Reglas de Calificación<br/>ya cargadas en RAM
    
    Core->>Core: Calcular Promedios
    
    %% Escritura Condicional
    Core->>DDB: PutItem (Condition: Version match)
    DDB-->>Core: Success
    
    Core-->>APIG: 200 OK
    deactivate Core
    
    APIG-->>Prof: Respuesta (<100ms)
    
    %% Logging Asíncrono
    par Async Logging
        Core-)Core: Flush Logs to stdout
        Note right of Core: CloudWatch captura stdout<br/>sin bloquear el request
    end
```

Opté por App Runner (contenedores) en lugar de Lambda para este flujo específico.

Esto nos permite mantener en memoria caché las reglas de negocio y conexiones a base de datos persistentes (Keep-Alive), eliminando los Cold Starts y garantizando la estabilidad de la latencia para la experiencia de usuario crítica.

### Integración Gobierno
Objetivo: Manejar la inestabilidad de sistemas externos con reintentos robustos.

```mermaid
sequenceDiagram
    autonumber
    participant Sched as Scheduler
    participant SF as Step Functions
    participant DDB as DynamoDB
    participant Gov as API Gobierno

    Sched->>SF: Trigger Sync (Cron)
    activate SF
    
    SF->>DDB: Scan (Notas Pendientes)
    DDB-->>SF: Lista de Items
    
    loop Para cada Lote
        SF->>Gov: POST /sync (Datos)
        
        alt Success (200 OK)
            Gov-->>SF: Ack
            SF->>DDB: Update (Synced=true)
        
        else Fallo Temporal (503/Timeout)
            Gov--xSF: Error
            Note right of SF: Espera 5s... 10s... 20s...<br/>(Exponential Backoff)
            SF->>Gov: Retry Request
            
        else Fallo Definitivo (4xx)
            Gov--xSF: Bad Request
            SF->>DDB: Marcar 'SyncFailed'
            SF->>SF: Alertar a Ops (DLQ)
        end
    end
    
    deactivate SF
```

* Usamos Step Functions para manejar visualmente el estado de la transacción.
* Implementamos un patrón de Exponential Backoff (espera incremental) cuando el API del gobierno falla, evitando saturar su sistema y colapsar el nuestro.
* Cada intento y resultado queda auditado automáticamente por el historial de ejecución de la máquina de estados.