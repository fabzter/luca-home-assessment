# ADR-004: IAM Multi-Tenant Enforcement

---

## Contexto y Problema

El sistema maneja datos PII de menores (estudiantes) distribuidos entre múltiples tenants (escuelas). Un bug en la lógica de aplicación que olvide filtrar por `tenant_id` podría exponer datos cross-tenant, lo cual es inaceptable por compliance (GDPR, COPPA equivalentes).

Necesitamos garantizar aislamiento incluso ante errores de implementación.

## Decisión

**Enforcement multi-tenant a nivel IAM usando `dynamodb:LeadingKeys`:**

Cuando un usuario se autentica, recibe un JWT con claim `school_id`. App Runner/Lambda asumen un rol IAM dinámico con política que restringe acceso solo a items cuyo partition key comience con el tenant del usuario:

```json
{
  "Effect": "Allow",
  "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"],
  "Resource": "arn:aws:dynamodb:*:table/luca-platform",
  "Condition": {
    "ForAllValues:StringLike": {
      "dynamodb:LeadingKeys": ["TENANT#${aws:PrincipalTag/school_id}#*"]
    }
  }
}
```

## Alternativas Consideradas

### Alternativa A: Filtrado solo a nivel aplicación
**Descripción:** WHERE clause en queries: `tenant_id = ${user.tenant_id}`

**Pros:**
- Implementación simple
- No requiere configuración IAM compleja
- Familiar para developers
- Flexibilidad total en código

**Contras:**
- **Riesgo crítico:** Un error humano (olvidar WHERE) expone todos los datos
- Testing incompleto puede no detectar el bug
- Code review humano es falible
- Auditoría post-mortem difícil (logs no muestran intento de acceso cross-tenant bloqueado)

**Escenarios de falla:**
```javascript
// Bug: olvidó filtrar por tenant
const grades = await db.query('SELECT * FROM grades WHERE student_id = ?', [studentId]);
// Retorna grades de TODOS los tenants para ese student_id
```

**Por qué se descartó:** Inaceptable para datos de menores. El riesgo de compliance no justifica la simplicidad.

---

### Alternativa B: Database per Tenant
**Descripción:** Una base de datos DynamoDB por tenant (o schema en RDS).

**Pros:**
- Aislamiento físico total
- Imposible acceder datos cross-tenant
- Backups/restore granular por tenant
- Escalamiento independiente por tenant

**Contras:**
- **Costo:** Cada tabla DynamoDB tiene costo base (~$1.25/mes mínimo)
  - 100 tenants = $125/mes solo en overhead
- **Complejidad operativa:** 
  - Desplegar nuevas features en 100 tablas
  - Monitoreo: 100x alarmas, 100x métricas
  - Migrations: ejecutar en cada tenant secuencialmente
- **Routing complejo:** Código debe mapear user → tenant → tabla específica
- **Límites de servicio:** DynamoDB tiene límite de 2,500 tablas por región (escala limitada)

**Por qué se descartó:** Over-engineering para 10-50 tenants iniciales; costo operativo prohibitivo.

---

### Alternativa C: Query Interceptor Middleware
**Descripción:** Middleware que intercepta todas las queries y agrega automáticamente filtro tenant.

**Pros:**
- Centraliza lógica de multi-tenancy
- Reduce código repetitivo
- Menor riesgo de olvido (centralizado)

**Contras:**
- **Complejidad:** Requiere ORM/query builder personalizado
- **Performance:** Overhead en cada query (parsing + injection)
- **Debuggability:** Stack traces más profundos
- **False sense of security:** Si el middleware tiene bug, afecta TODO
- **Edge cases:** Queries raw/custom pueden bypassear middleware

**Por qué se descartó:** Complejidad adicional sin garantía de seguridad. Sigue siendo enforcement a nivel aplicación.

---

### Alternativa D: Application-Level IAM Roles (sin LeadingKeys)
**Descripción:** Un rol IAM por tenant, pero sin condición `LeadingKeys`.

**Pros:**
- Separación de permisos por tenant
- Auditoría más granular (CloudTrail por rol)

**Contras:**
- **No previene bugs:** El rol tiene acceso a TODA la tabla
- **Gestión compleja:** 100 tenants = 100 roles + 100 policies
- **AssumeRole overhead:** Cada request necesita STS call
- **No resuelve el problema:** Bug en código aún puede leer cross-tenant

**Por qué se descartó:** Complejidad sin beneficio de seguridad.

---

## Comparación de Alternativas


| Criterio            | LeadingKeys | App-Level Filter | DB per Tenant | Query Interceptor | IAM Roles sin Condition |
|---------------------|-------------|------------------|---------------|-------------------|-------------------------|
| Previene bug humano | Sí (Aceptable) | No | Sí (Aceptable) | Parcial (Condicional) | No |
| Costo (100 tenants) | ~$15 | ~$15 | ~$140 | ~$15 | ~$20 |
| Complejidad Ops     | Media (Condicional) | Baja (Aceptable) | Muy Alta (No) | Alta (No) | Alta (No) |
| Auditabilidad       | CloudTrail (Aceptable) | Logs de app (Condicional) | Granular (Aceptable) | Logs de app (Condicional) | CloudTrail (Aceptable) |
| Performance         | Sin overhead (Aceptable) | Sin overhead (Aceptable) | Sin overhead (Aceptable) | Parsing extra (No) | STS extra (Condicional) |
| Compliance          | Infra-level (Aceptable) | App-level (No) | Aislamiento físico (Aceptable) | App-level (Condicional) | App-level (No) |

## Justificación

**IAM LeadingKeys es la mejor opción porque:**

1. **Defense in Depth:**
   - Primera línea: Código filtra correctamente
   - Segunda línea (failsafe): IAM rechaza query si código falla

2. **Compliance Auditable:**
   ```
   Auditor: "¿Cómo garantizan que un bug no expone datos cross-tenant?"
   Nosotros: "AWS IAM rechaza la request a nivel infraestructura antes de llegar a DynamoDB."
   ```

3. **Costo Razonable:**
   - No aumenta costo de DynamoDB
   - Solo complejidad adicional en autenticación (AssumeRoleWithWebIdentity)

4. **Observable:**
   - CloudTrail registra `AccessDenied` si hay intento cross-tenant
   - Podemos crear alarmas proactivas

5. **Escalable:**
   - De 10 a 1000 tenants sin cambio en arquitectura
   - Un solo policy template con variable `${aws:PrincipalTag/school_id}`

## Implementación

### Flow de Autenticación:

1. Usuario hace login → recibe JWT de Cognito con claim `custom:school_id`
2. API Gateway valida JWT
3. App Runner/Lambda llama STS AssumeRoleWithWebIdentity:
   3. App Runner/Lambda obtiene credenciales temporales con:
   ```text
   STS.AssumeRoleWithWebIdentity(role="TenantAccessRole", tag=school_id)
   → credentials temporales para DynamoDB
   ```
4. DynamoDB client usa estas credentials temporales
5. Cualquier query a keys fuera de `TENANT#school_123#*` retorna `AccessDenied`

### Data Model Requirement:

**Todas las partition keys DEBEN comenzar con `TENANT#id#`:**

```
Correcto:
PK: TENANT#school_123#STUDENT#student_456

Incorrecto (no filtra):
PK: STUDENT#student_456
tenant_id: school_123
```

## Consecuencias

### Positivas
- **Seguridad garantizada:** Imposible acceso cross-tenant incluso con bug
- **Compliance:** Auditable a nivel infraestructura
- **Observability:** CloudTrail logs muestran intentos bloqueados
- **Escalabilidad:** Soporta miles de tenants sin cambio arquitectónico

### Negativas
- **Complejidad de autenticación:** Requiere AssumeRole en cada request
- **Latency:** +20-30ms por STS call (mitigable con credential caching)
- **Data model rigidez:** PK design forzado por requirement de LeadingKeys
- **Testing:** Difícil testear localmente (requiere mock de IAM policies)

### Mitigaciones
- **Credential caching:** Cachear credentials por 15 min reduce STS calls 99%
- **Local testing:** Usar IAM Policy Simulator o LocalStack
- **Documentation:** ADR + diagrams clarifican el pattern para nuevo equipo
- **Code templates:** Scaffolding genera código con pattern correcto
