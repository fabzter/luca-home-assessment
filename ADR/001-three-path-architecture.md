# ADR-001: Separación en Tres Paths de Ejecución

---

## Contexto y Problema

El sistema debe manejar tres tipos de operaciones con perfiles radicalmente diferentes:
1. **Interactivas:** Consultas y escrituras síncronas (profesores/estudiantes) - p95 < 120ms
2. **Alta velocidad:** Ingesta masiva de eventos (~5,000 RPS en picos)
3. **Integración externa:** Sincronización trimestral con API gubernamental inestable

Usar una arquitectura monolítica forzaría a optimizar para el caso promedio, sacrificando eficiencia en los extremos.

## Decisión

Separar el sistema en **tres paths de ejecución independientes** basados en perfiles de tráfico:

- **Path 1 (Interactivo):** App Runner + API Gateway
- **Path 2 (Alta Velocidad):** API Gateway → SQS → Lambda (batch processing)
- **Path 3 (Sincronización):** EventBridge Scheduler → Step Functions

## Alternativas Consideradas

### Alternativa A: Arquitectura Monolítica con Lambda
**Descripción:** Una sola Lambda manejando todos los casos con routing interno.

**Pros:**
- Menor número de componentes
- Despliegue unificado
- Simplicidad operativa inicial

**Contras:**
- Cold starts afectan operaciones interactivas (incompatible con p95 < 120ms)
- Provisioned concurrency costoso (~$200/mes) para garantizar latencia
- Mezcla concerns con distintos perfiles de escalamiento
- Timeouts de Lambda (15 min) inadecuados para sincronización larga

**Por qué se descartó:** No cumple requisitos de latencia sin costo prohibitivo.

---

### Alternativa B: Microservicios en ECS/Fargate
**Descripción:** Contenedores independientes en ECS para cada dominio.

**Pros:**
- Aislamiento completo entre dominios
- Sin cold starts
- Flexibilidad total en runtime

**Contras:**
- Overhead operativo: ALB, target groups, service discovery, auto-scaling policies
- Costos fijos: mínimo 2 tareas x 3 servicios = 6 contenedores corriendo 24/7
- Complejidad en deployment pipelines
- Over-engineering para el volumen esperado

**Por qué se descartó:** Complejidad operativa no justificada para la escala actual.

---

### Alternativa C: Full Serverless (Lambda everywhere)
**Descripción:** Lambdas individuales para cada operación con SQS/EventBridge como coordinación.

**Pros:**
- Costo óptimo (pago por uso)
- Auto-scaling sin configuración
- Sin gestión de infraestructura

**Contras:**
- Cold starts constantes en path interactivo
- Conexiones a DynamoDB efímeras (sin connection pooling efectivo)
- Complejidad en orquestación (cadenas de Lambdas)
- Debugging distribuido más complejo

**Por qué se descartó:** Trade-off latencia vs costo no aceptable para path interactivo.

---

## Comparación de Alternativas

| Criterio | Path Separation | Monolito Lambda | ECS/Fargate | Full Serverless |
|----------|----------------|-----------------|-------------|-----------------|
| **Latencia p95** | <120 ms (Aceptable) | >200 ms (No) | <100 ms (Aceptable) | >150 ms (No) |
| **Costo mensual** | ~$150 | ~$350 | ~$450 | ~$120 |
| **Complejidad Ops** | Baja | Muy Baja | Alta | Media |
| **Escalabilidad** | Independiente (Aceptable) | Acoplada (No) | Independiente (Aceptable) | Infinita (Aceptable) |
| **Developer DX** | Clara separación (Aceptable) | Acoplada (No) | Aislamiento (Aceptable) | Debugging difícil (Moderado) |
## Justificación

La separación en tres paths logra el mejor balance entre:
1. **Performance:** App Runner elimina cold starts sin provisioned concurrency
2. **Costo:** Lambda batch processing optimiza ingesta masiva
3. **Resiliencia:** Step Functions maneja complejidad de integración externa
4. **Simplicidad:** Cada path usa la primitiva AWS óptima para su perfil

## Consecuencias

### Positivas
- Cada path puede optimizarse independientemente
- Fallas en un path no afectan a otros
- Escalamiento horizontal automático
- Costo proporcional al uso real

### Negativas
- Mayor número de componentes en diagrama de arquitectura
- Necesidad de observabilidad distribuida (correlation IDs)
- Duplicación de lógica común (autenticación, logging)

### Mitigaciones
- Shared libraries para código común
- CloudWatch + X-Ray para trazabilidad end-to-end
- IaC (Terraform/CDK) para gestión unificada
