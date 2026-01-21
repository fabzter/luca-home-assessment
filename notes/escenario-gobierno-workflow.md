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

*Este workflow garantiza que cumplimos el deadline de 48h de compliance mientras manejamos gracefully la inestabilidad de la API gubernamental, con visibilidad completa para troubleshooting y auditorías.*
