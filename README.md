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

## 3. Arquitectura del Sistema

```mermaid
flowchart TB
    %% External Actors
    Student["Estudiante"]
    Teacher["Profesor"]
    GovSystem["Sistema Gobierno"]

    %% === PUBLIC EDGE LAYER ===
    subgraph EdgeLayer ["Public Edge & Security"]
        WAF["AWS WAF"]
        APIG["API Gateway<br/>(HTTP API + JWT)"]
    end

    %% === COMPUTE & INGESTION LAYER ===
    subgraph Path1 ["Path 1: Interactivo"]
        AppRunner["AWS App Runner<br/>(Contenedor Node.js)"]
    end

    subgraph Path2 ["Path 2: Alta Velocidad"]
        SQS["Amazon SQS"]
        Lambda["AWS Lambda<br/>(Batch Processor)"]
    end

    subgraph Path3 ["Path 3: Sincronización"]
        Scheduler["EventBridge Scheduler"]
        StepFunctions["AWS Step Functions"]
    end

    %% === PERSISTENCE LAYER ===
    subgraph PersistenceLayer ["Persistence"]
        DynamoDB[("DynamoDB<br/>Single Table<br/>⚠️ Multi-Tenant: IAM Isolation")]
    end

    %% === DATA PIPELINE ===
    subgraph DataPipeline ["Data Pipeline"]
        direction LR
        Streams["DynamoDB<br/>Streams"] --> Pipes["EventBridge<br/>Pipes"]
        Pipes --> Firehose["Kinesis<br/>Firehose"]
        Firehose --> S3["S3<br/>Data Lake"]
    end

    %% === OBSERVABILITY ===
    subgraph ObsLayer ["Observability"]
        direction LR
        CloudWatch["CloudWatch"]
        XRay["X-Ray"]
    end

    %% === TRAFFIC FLOWS ===
    
    %% Entry
    Student & Teacher --> WAF
    WAF --> APIG

    %% Path 1: Interactive
    APIG -->|"/grades, /profile"| AppRunner
    AppRunner --> DynamoDB

    %% Path 2: High Volume
    APIG -->|"/behavior"| SQS
    SQS -->|"Batch: 50"| Lambda
    Lambda --> DynamoDB

    %% Path 3: Government Sync
    Scheduler -->|"Every 48hrs"| StepFunctions
    StepFunctions --> DynamoDB
    StepFunctions <-->|"HTTP Retry"| GovSystem

    %% Data Pipeline Connection
    DynamoDB -.-> Streams

    %% Observability (simplified - single connection per layer)
    EdgeLayer -.-> ObsLayer
    Path1 -.-> ObsLayer
    Path2 -.-> ObsLayer
    Path3 -.-> ObsLayer

    %% Styling
    classDef edge fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px
    classDef compute fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    classDef data fill:#fff3e0,stroke:#ef6c00,stroke-width:2px
    classDef pipeline fill:#fce4ec,stroke:#880e4f,stroke-width:2px
    classDef obs fill:#f3e5f5,stroke:#7b1fa2,stroke-width:1px
    classDef external fill:#eceff1,stroke:#37474f,stroke-width:2px

    class WAF,APIG,EdgeLayer edge
    class AppRunner,Lambda,SQS,Scheduler,StepFunctions,Path1,Path2,Path3 compute
    class DynamoDB,PersistenceLayer data
    class Streams,Pipes,Firehose,S3,DataPipeline pipeline
    class CloudWatch,XRay,ObsLayer obs
    class Student,Teacher,GovSystem external
```

### Estrategia de Separación de Dominios

Separé el sistema en **tres paths de ejecución** basándome en sus perfiles de tráfico y requerimientos de latencia:

**Path 1 (Interactivo):** Operaciones síncronas como consulta de perfiles y cálculo de notas. Usé contenedores persistentes (App Runner) en lugar de funciones efímeras para mantener conexiones activas a la base de datos y reglas de negocio cargadas en memoria. Esto elimina cold starts y garantiza latencias estables bajo el target de p95 < 120ms.

**Path 2 (Alta Velocidad):** Ingesta masiva de eventos de comportamiento estudiantil (~5,000 RPS en picos). API Gateway escribe directamente a SQS sin lambda intermedia, reduciendo costo y latencia. Lambda workers procesan en lotes de 50 mensajes, optimizando escrituras a DynamoDB mediante `BatchWriteItem`. La cola actúa como buffer anti-stampede protegiendo el resto del sistema.

**Path 3 (Sincronización):** Integración con el sistema del gobierno usando Step Functions para manejar la naturaleza inestable del API externo. La máquina de estados coordina reintentos con backoff exponencial, esperas largas sin consumir recursos, y mantiene auditoría completa del proceso de sincronización.

**Multi-Tenancy:** El aislamiento entre escuelas se garantiza a nivel IAM usando `dynamodb:LeadingKeys` en las políticas de acceso. Esto previene que un tenant acceda datos de otro incluso si existe un bug en la lógica de aplicación—crítico para compliance con datos de menores.

**Observabilidad:** CloudWatch centraliza logs estructurados (JSON) con correlation IDs que permiten seguir una transacción completa a través de todos los componentes. X-Ray provee trazabilidad distribuida para análisis de latencia y debugging.

**Data Pipeline:** DynamoDB Streams captura todos los cambios en la base de datos. EventBridge Pipes filtra y transforma los eventos antes de enviarlos a Kinesis Firehose, que los archiva en S3 en formato Parquet para auditoría y análisis posterior—sin escribir código ETL custom.