# ADR-002: Computación Híbrida - App Runner + Lambda

---

## Contexto y Problema

El path interactivo requiere:
- p95 < 120ms para consultas de perfil
- Conexiones persistentes a DynamoDB para connection pooling
- Reglas de consolidación cargadas en memoria

Lambda puro tiene cold starts de 500-2000ms que rompen el SLA. Provisioned concurrency cuesta ~$200/mes para mantener 2 instancias calientes 24/7.

## Decisión

**Path Interactivo:** AWS App Runner con contenedor Node.js  
**Path Ingesta:** AWS Lambda con batch processing (SQS)  
**Path Consolidación:** AWS Lambda (nightly job)

## Alternativas Consideradas

### Alternativa A: Full Lambda con Provisioned Concurrency
**Descripción:** Lambda para todo, provisioned concurrency en path interactivo.

**Pros:**
- Arquitectura homogénea (un solo paradigma)
- Auto-scaling incluido
- Despliegue unificado

**Contras:**
- **Costo:** $0.015/GB-hora provisioned = ~$216/mes para 2GB x 2 instancias
- Desperdicio durante horas no escolares (18:00-07:00, fines de semana)
- Complejidad en configuración de concurrency óptima

**Análisis de costos:**
```
Provisioned: 2 instancias x 2GB x 730hrs x $0.0000097 = $28.37/mes
Compute: 2 instancias x 2GB x 730hrs x $0.00001667 = $48.73/mes
Requests: 100K requests x $0.20/1M = $0.02/mes
TOTAL: ~$77/mes (solo compute)
```

**Por qué se descartó:** Desperdicio de recursos fuera de horario escolar.

---

### Alternativa B: Full ECS/Fargate
**Descripción:** Todos los workloads en contenedores ECS.

**Pros:**
- Sin cold starts
- Control total sobre runtime
- Connection pooling óptimo

**Contras:**
- **Costo fijo:** 2 tareas x 0.5 vCPU x $0.04048/hr = ~$59/mes mínimo
- Overhead operativo: ALB ($16/mes), target groups, health checks
- Auto-scaling requiere configuración manual (CloudWatch alarms + scaling policies)
- Batch processing ineficiente (contenedores corriendo idle esperando mensajes)

**Por qué se descartó:** Over-engineering para workloads batch/nightly.

---

### Alternativa C: Full Serverless (Lambda everywhere)
**Descripción:** Lambda para todo sin provisioned concurrency.

**Pros:**
- Costo óptimo (verdadero pay-per-use)
- Zero gestión de infraestructura
- Auto-scaling infinito

**Contras:**
- **Latencia:** Cold starts 500-2000ms en path interactivo
- Conexiones efímeras a DynamoDB (overhead en cada invocación)
- Imposible cumplir p95 < 120ms sin provisioned concurrency
- Reglas de consolidación re-cargadas en cada request

**Por qué se descartó:** Incompatible con requisitos de latencia.

---

### Alternativa D: App Runner everywhere
**Descripción:** Contenedores App Runner para todos los paths.

**Pros:**
- Sin cold starts en ningún path
- Arquitectura homogénea
- Simplicidad conceptual

**Contras:**
- **Desperdicio:** Batch processor corriendo 24/7 esperando mensajes SQS
- Nightly job mantiene contenedor activo 23 horas/día sin hacer nada
- Costo mínimo de ~$30/mes por servicio = $90/mes total
- Auto-scaling ineficiente para workloads esporádicos

**Por qué se descartó:** Ineficiente para workloads batch/scheduled.

---

## Comparación de Alternativas


| Criterio             | Híbrido (Decisión)          | Lambda Provisioned     | ECS/Fargate            | Full Serverless        | App Runner Todo        |
|----------------------|------------------------------|------------------------|------------------------|------------------------|------------------------|
| Latencia p95         | <120 ms (Aceptable)          | <100 ms (Aceptable)    | <80 ms (Aceptable)     | >200 ms (No)           | <100 ms (Aceptable)    |
| Costo mensual        | ~$45                         | ~$77                   | ~$85                   | ~$20                   | ~$90                   |
| Cold starts          | Solo interactivo (Aceptable) | No (Aceptable)         | No (Aceptable)         | Sí (No)                | No (Aceptable)         |
| Complejidad Ops      | Media                        | Baja                   | Alta                   | Baja                   | Media                  |
| Eficiencia batch     | Alta (Aceptable)             | Media (Condicional)    | Baja (No)              | Alta (Aceptable)       | Muy baja (No)          |

## Justificación

**App Runner para Path Interactivo:**
- Escala a cero fuera de horario (18:00-07:00 = 13hrs/día = ahorro 54%)
- Mantiene 1 instancia caliente durante horas escolares (07:00-18:00)
- Connection pooling a DynamoDB reduce latencia en 20-30ms
- Config cache en memoria (grading rules) evita round-trip a DB

**Cálculo de costo App Runner:**
```
Instancia activa (11 hrs/día x 22 días):
0.5 vCPU x 242 hrs/mes x $0.064 = $15.49
1GB RAM x 242 hrs/mes x $0.007 = $1.69
Requests: 50K x $0.001/1000 = $0.05
TOTAL: ~$17/mes
```

**Lambda para Batch Processing:**
- Solo corre cuando hay mensajes en SQS
- Batch de 50 mensajes optimiza costo
- 1M invocaciones/mes = $0.20

**Lambda para Nightly Job:**
- Corre 30 min/día = 15 hrs/mes
- Costo despreciable: ~$2/mes

**Total híbrido: ~$45/mes vs $77 Lambda Provisioned (ahorro 41%)**

## Consecuencias

### Positivas
- **Latencia:** Cumple p95 < 120ms sin provisioned concurrency
- **Costo:** Optimizado por tipo de workload
- **Simplicidad:** Usa la primitiva AWS correcta para cada caso
- **Escalabilidad:** Auto-scaling independiente por path

### Negativas
- Dos paradigmas de deployment (contenedores vs funciones)
- Logging/monitoring debe unificar ambos modelos
- Shared code requiere estrategia (layers para Lambda, npm packages para App Runner)

### Mitigaciones
- IaC unificado (CDK/Terraform) abstrae diferencias
- Structured logging con formato común (JSON + correlation IDs)
- Shared business logic en npm packages privados
- X-Ray para trazabilidad cross-service
