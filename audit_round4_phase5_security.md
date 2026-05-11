# Auditoría Round 4 — Fase 5: Seguridad

Fecha: 2026-05-11

---

## Resumen ejecutivo

La superficie está bien defendida en general. Hay **1 bug crítico** (case-sensitivity en revocación de super_admin) y varios issues de medianos a bajos. Los pillars de defensa son sólidos:

- **Firestore rules**: granulares por colección, con `affectedKeys()` diffs para impedir escrituras en campos sensibles
- **Cloud Functions**: `enforceAppCheck` en todas las CFs user-facing; auth + role checks server-side en TODAS
- **Rate limiting**: 33 CFs con `enforceRateLimit` (windows variando entre 10/10min y 100/h según sensibilidad)
- **Stripe**: signature validation + idempotency keys + drift detection
- **Custom claims**: `setCustomUserClaims` reemplaza (no merge) — uso correcto con preservación explícita
- **Storage**: 1 sola ruta abierta (profile_photos), validación de owner + tamaño + content-type

---

## CFs con `enforceAppCheck: false` (revisión)

Encontradas 18 CFs sin AppCheck. **Todas son admin-web-only** (admin web React no usa AppCheck) y validan claims server-side:

| CF | Validación de claims | Riesgo |
|---|---|---|
| `bootstrapSuperAdmin` | email === SUPER_ADMIN_EMAIL | ✅ ok (sólo ese email pasa) |
| `claimPendingTenantAdmin` | lookup en `_pendingTenantAdmins/{email}` | ✅ ok |
| `setAdminClaim` | callerIsSuper || callerIsTenantAdmin (fresh) | ⚠️ ver BUG-035 |
| `listAdmins` | callerIsSuperAdmin/TenantAdmin | ✅ |
| `getAdminStats` | callerIsAdmin | ✅ |
| `getRecentTransactions` | callerIsAdmin | ✅ |
| `getFailedPayments` | callerIsAdmin | ✅ |
| `setUserBlocked` | callerIsAdmin | ✅ |
| `createTenant` | callerIsSuperAdminFresh | ✅ |
| `backfillTenantSlugs` | callerIsSuperAdminFresh | ✅ |
| `getTenantBranding` | tenant_admin del propio o super | ✅ |
| `updateTenant` | super_admin (all fields) o tenant_admin (branding only) | ✅ |
| `listTenants` | callerIsSuperAdmin | ✅ |
| `getSuperAdminDashboard` | callerIsSuperAdmin | ✅ |
| `createStripeConnectLink` | super o tenant_admin | ✅ |
| `cancelTenantSubscription` | callerIsSuperAdminFresh | ✅ |
| `deleteTenant` | callerIsSuperAdminFresh | ✅ |
| `resolveActivityItem` | callerIsAdmin | ✅ |

**Conclusión**: la falta de AppCheck en estas CFs no es un problema — la auth y los claims las cubren.

---

## Bugs encontrados

### BUG-035 — `setAdminClaim` permite revocar super_admin via uppercase email (CRITICAL)
- **Archivo**: [functions/index.js:4470](functions/index.js#L4470)
- **Severidad**: 🔴 **CRITICAL**
- **Descripción**: la línea
  ```js
  if (revoke && targetEmail === SUPER_ADMIN_EMAIL) {
    throw new HttpsError("permission-denied", "No se pueden revocar los permisos del super administrador.");
  }
  ```
  hace una comparación **case-sensitive** entre el `targetEmail` raw (no normalizado) y `SUPER_ADMIN_EMAIL` constante (`'ioelkatz@gmail.com'`). Si un atacante pasa `"IOELKATZ@GMAIL.COM"`, esta guard falla y la función continúa.
- **Vector de ataque**:
  1. Atacante necesita ser tenant_admin de cualquier tenant (rol válido) AND first admin de ese tenant (passes `isFirstAdmin` check)
  2. Llama `setAdminClaim({ targetEmail: "IOELKATZ@GMAIL.COM", revoke: true })`
  3. Línea 4470 bypass (case-sensitive). Línea 4474 bypass (super_admin no tiene tenantId claim). Línea 4505 bypass (super_admin tiene Auth account).
  4. Línea 4526: `setCustomUserClaims(super_admin_uid, {})` — **wipea las claims**
  5. Línea 4569: `revokeRefreshTokens` — super_admin queda sin token válido
  6. Resultado: super_admin DOS para la próxima hora hasta que `bootstrapSuperAdmin` re-aplique en re-login.
- **Mitigación parcial actual**: el `AuthContext.ensureClaimsAfterAuth` del admin web llama `bootstrapSuperAdmin` automáticamente cuando detecta `ioelkatz@gmail.com` sin claim `super_admin`. Así que el daño es temporal (hasta el próximo login).
- **Fix obligatorio**:
  ```js
  // Cambiar línea 4470 de:
  if (revoke && targetEmail === SUPER_ADMIN_EMAIL) {
  
  // A:
  if (revoke && normalizedEmail === SUPER_ADMIN_EMAIL.toLowerCase()) {
  ```
  (`normalizedEmail` ya es `String(targetEmail).toLowerCase().trim()` en línea 4436)

### BUG-036 — `setAdminClaim` logea email completo del target (LOW)
- **Archivo**: [functions/index.js:4574-4580](functions/index.js#L4574)
- **Severidad**: 🟢 **LOW**
- **Descripción**: el `console.info` final loguea `callerEmail` y `targetEmail` en plain text. Cloud Logging puede ser indexado por Google y por humanos con acceso al proyecto. Es PII.
- **Comparación**: la función `_redactEmail` ya existe (línea 6895) — se usa en `sendEmail` y `checkGracePeriods`. Aplicarla acá.
- **Fix propuesto**: reemplazar por `_redactEmail(callerRecord.email)` y `_redactEmail(targetEmail)` (cuando el log no sea de auditoría — pero acá es operacional, mejor redactar).

### BUG-037 — `tenantState` no tiene branch para super_admin/tenant_admin (gap funcional, no de seguridad)
- **Archivo**: [firestore.rules:574-579](firestore.rules#L574)
- **Severidad**: 🟡 **MEDIUM** — funcional, no de seguridad
- **Descripción**: ya cubierto en Fase 0. Las rules de `tenantState` solo permiten al owner. Significa que el CRM del admin no puede leer client-side el `pushkaAmount` ni el `streak` de un usuario — todo debe ir vía CF.
- **Validación**: `UserHistoryPage` (admin) y `useUsers` hook leen `users/{uid}` y `transactions` — NO leen tenantState. ✓
- **Conclusión**: no es bug. Si en el futuro el CRM quisiera mostrar streak/pushka del donante, hay que crear una CF nueva.

### BUG-038 — `bootstrapSuperAdmin` puede crear DoS si SUPER_ADMIN_EMAIL no está en Auth todavía
- **Archivo**: [functions/index.js:4232](functions/index.js#L4232)
- **Severidad**: 🟢 **LOW**
- **Descripción**: si la cuenta `ioelkatz@gmail.com` no existe en Auth aún (proyecto fresco recién creado), `bootstrapSuperAdmin` falla con error. Pero como `AuthContext.ensureClaimsAfterAuth` lo llama silenciosamente (try/catch), no rompe el flujo. Aceptable.

### BUG-039 — Storage rules de `profile_photos` permiten read a CUALQUIER usuario autenticado
- **Archivo**: [storage.rules:13](storage.rules#L13)
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: `allow read: if request.auth != null;` — significa que cualquier user logueado puede listar y descargar TODAS las fotos de perfil de TODOS los users del sistema. Esto es por diseño según el comentario:
  > Reads scoped to authenticated users. Note: Flutter clients fetch photos via the `getDownloadURL()` token URL which bypasses these rules entirely.
- **Riesgo real**:
  - Usuario malicioso enumera Storage → descarga fotos de otros donantes (potencial doxing)
  - El comentario dice que en producción se usa URL con token, pero las rules NO previenen el listado/download directo via Storage SDK
- **Fix propuesto** (recomendado pre-launch escalado):
  ```
  allow read: if request.auth != null
              && fileName == request.auth.uid + '.jpg';
  ```
  Pierde la feature de "leaderboard con avatares" — si esa feature aplica, mantener read abierto (current behavior) y aceptar el riesgo. Decisión de producto.

### BUG-040 — `_pendingTenantAdmins` no expira (potential staleness)
- **Severidad**: 🟢 **LOW**
- **Descripción**: las invitaciones queued via `setAdminClaim` (para emails sin Auth account) viven en `_pendingTenantAdmins/{email}` **indefinidamente**. Si un super_admin invita un email y luego se arrepiente sin revocar explícitamente, el documento queda. Si esa persona EVENTUALMENTE crea cuenta con ese email, automáticamente recibe el claim.
- **Riesgo**: una invitación olvidada de hace 6 meses para una expariente podría reactivarse si esa persona crea cuenta nuevamente.
- **Fix propuesto**: TTL de 30 días vía `cleanupOldPendingInvitations` cron, o agregar `expiresAt` en el doc y validarlo en `claimPendingTenantAdmin`.

### BUG-041 — `joinTenant` permite unirse a tenants en grace_period
- **Archivo**: [functions/index.js:5450](functions/index.js#L5450)
- **Severidad**: 🟢 **LOW**
- **Descripción**: `if (!["active", "trial", "grace_period"].includes(tenantData.status))` — permite unirse aunque el tenant esté en grace_period (no pagó). Funcional mente OK (el tenant está casi suspendido, mejor no acumular más donantes) pero puede confundir al donante que se une y al rato ve "servicio suspendido".
- **Fix propuesto** (debatible): excluir `grace_period`. O dejar.

### BUG-042 — Validación de email en `sendEmail` es defensiva pero después de tocar Stripe
- **Severidad**: 🟢 **LOW**
- **Descripción**: ok, lo encontré pero releyendo es OK. Falsa alarma.

### BUG-043 — `_tenantSlugs` collection rule deny-all bloquea lectura para validar slug en cliente
- **Archivo**: [firestore.rules:496](firestore.rules#L496)
- **Severidad**: 🟢 **LOW**
- **Descripción**: rule es deny-all client. Eso es correcto desde seguridad. El cliente que quiere validar un slug debe llamar `getTenantBySlug` CF. Está bien diseñado.

### BUG-044 — Multiple console.info en CFs registran emails sin redact
- **Severidad**: 🟢 **LOW**
- **Descripción**: además de BUG-036, hay otros logs como `console.info("backfillTenantSlugs", { ... })` y `console.info("createTenant: completed", { name, slug })` que aunque no logean emails, sí logean nombres/slugs de tenants. Para Pushka esto es OK (tenants públicos), pero si se ampliara a usuarios privados, revisar.

---

## Stripe Connect — chequeos extra de seguridad

✅ **Signature validation** en ambos webhooks
✅ **Idempotency** via `_stripeWebhookEvents/{eventId}`
✅ **OAuth state token** con TTL de 24h, CSRF-safe
✅ **Connect transfer_data** ata cada PI a un specific account ID
✅ **Drift detection** entre PI metadata y current tenant.connectAccountId

⚠️ **Faltante** — ya en Fase 3 BUG-019: el OAuth callback marca `active` sin verificar `charges_enabled` de Stripe. Ataque concebible pero baja probabilidad.

---

## Stripe Customer / Payment Method security

Revisando rápidamente `createSetupIntent` ([functions/index.js:1729](functions/index.js#L1729)) y `listSavedCards` ([functions/index.js:1835](functions/index.js#L1835)) — todos enforcan `auth.uid` y leen `users/{uid}.stripeCustomerId`. Rate limit ok. Fields write-protected en rules. ✓

---

## Tabla resumen Fase 5

| ID | Severidad | Título | Bloquea launch? |
|---|---|---|---|
| BUG-035 | 🔴 CRITICAL | setAdminClaim revoca super_admin via uppercase | **Sí** (DoS al super_admin) |
| BUG-036 | 🟢 LOW | Email plain en logs de setAdminClaim | No |
| BUG-037 | 🟡 MEDIUM | tenantState sin branch admin (no es bug, validar) | No |
| BUG-038 | 🟢 LOW | bootstrapSuperAdmin si email no existe en Auth | No |
| BUG-039 | 🟡 MEDIUM | Storage profile_photos read abierto | No (decisión de producto) |
| BUG-040 | 🟢 LOW | _pendingTenantAdmins sin TTL | No |
| BUG-041 | 🟢 LOW | joinTenant en grace_period | No |
| BUG-043 | 🟢 LOW | Falsa alarma | No |
| BUG-044 | 🟢 LOW | Logs con nombres de tenant | No |

**Resumen**: 1 CRITICAL, 2 MEDIUM, 5 LOW. La seguridad es sólida, BUG-035 es el único accionable hoy.

---

Continúo a **Fase 6 — Persistencia**.
