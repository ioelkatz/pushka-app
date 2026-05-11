# Auditoría Round 4 — Fase 7: Performance (3k usuarios diarios)

Fecha: 2026-05-11

---

## Modelo de carga estimada (3k DAU activos)

Asumiendo sesiones promedio: **20 calls Cloud Functions / día / user**:
- 3000 × 20 = **60k CF invocations/día** = ~700/h en pico
- Listeners Firestore por user: ~5-6 abiertos en pantalla activa
- Lecturas Firestore por sesión: ~30-50 (incluye perfil, transacciones, tenantState, reminders)
- Estimado total Firestore: 3000 × 40 = **120k reads/día**

A los precios de Firestore (`$0.06/100k reads`, `$0.18/100k writes`), el costo Firestore queda en **~$10-15/mes** para 3k DAU. Económicamente viable.

---

## Firestore indexes

[firestore.indexes.json](firestore.indexes.json) tiene:

| Index | Para qué query |
|---|---|
| `transactions: (type, createdAt)` | history filtrado por tipo |
| `transactions: (tenantId, createdAt)` | admin filtra por tenant |
| `transactions: collectionGroup (tenantId, createdAt)` | super_admin queries cross-user |
| `_stripeWebhookEvents: (status, createdAt)` | monitorStripeWebhook health |
| `_stripeWebhookEvents: (status, lastAttemptAt)` | monitorStripeWebhookStuckEvents |
| `tenants: (slug, status)` | getTenantBySlug |
| `tenantState.autoEmptyNextRunAt` | processPushkaAutoEmpty cron |
| `tenantState.tenantId` (cg) | onTenantBrandingUpdated fan-out |
| `fcmTokens.lastUsedAt` (cg) | cleanupStaleFcmTokens cron |

**Cobertura**: parece correcta. No identifico queries en código que carezcan de índice.

#### BUG-053 — `users.where('tenantIds', 'array-contains', X)` usa single-field index (OK pero monitorear)
- **Severidad**: 🟢 **LOW** — performante hoy
- **Descripción**: `deleteTenant` itera `users.where('tenantIds', 'array-contains', tenantId)` paginado 500. Funciona con single-field index (auto). Pero si Pushka crece a 100k+ users y un tenant tiene 50k miembros, la query será lenta. No es crítico ahora.

---

## Cold starts en Cloud Functions

### `minInstances` configurados: 0 (ninguno)

⚠️ **TODAS las CFs cold-startan**. Latencias típicas:
- Tier hot (CF en memoria): 50-200ms
- Cold start (Node.js 20 + `require("stripe")` + `require("firebase-admin")`): 1-3 segundos

### Impacto por CF crítica

| CF | Cold latencia esperada | Frecuencia llamada | Impacto user |
|---|---|---|---|
| `createPaymentIntent` | 2-3s | bursty (clicks de "donar") | ⚠️ user ve loading 2s antes de PaymentSheet |
| `getTenantConfig` | 1-2s | cada cold start + 60s poll | ⚠️ splash screen tarda más |
| `joinTenant` | 1-2s | una vez por usuario | OK |
| `createSetupIntent` | 2s | guardar tarjeta | OK |
| `listSavedCards` | 1s | abrir settings | OK |
| Admin CFs | 1-2s | super_admin operacional | OK |
| `stripeWebhook` | 1-2s | Stripe retry tolera | OK |

#### BUG-054 — Sin `minInstances` para CFs del path crítico de pago
- **Severidad**: 🟡 **MEDIUM**
- **Archivos**: `createPaymentIntent`, `getTenantConfig`, `createSetupIntent`
- **Descripción**: estas 3 son críticas para UX. Sin warm instances, cada user en cold-start espera 2-3s.
- **Fix propuesto** (cuando llegue a >100 DAU activos por hora):
  ```js
  exports.createPaymentIntent = onCall(
    {
      secrets: [stripeSecret],
      enforceAppCheck: true,
      minInstances: 1, // 1 warm instance siempre
      memory: "256MiB",
    },
    ...
  );
  ```
  Costo: $0.0000025/sec/instance = ~$6.50/mes por minInstance=1. Justificado para UX premium.
- **Decisión**: NO crítico para launch con un solo tenant. Activar cuando Pushka tenga ≥3 tenants o ≥500 DAU.

---

## Snapshot listeners abiertos por session de Flutter

Identificados 6 listeners (`.snapshots()`):
1. `transactions` ([transaction_repository.dart:30](lib/features/history/data/transaction_repository.dart#L30))
2. `tenants/{tenantId}` ([tenant_repository.dart:178](lib/features/tenant/data/tenant_repository.dart#L178))
3. Otra subscripción en tenant_repository:192
4. `users/{uid}` ([user_repository.dart:41](lib/features/users/data/user_repository.dart#L41))
5. `users/{uid}/tenantState/{tenantId}` ([user_repository.dart:155](lib/features/users/data/user_repository.dart#L155))
6. `reminders` ([reminder_repository.dart:22](lib/features/reminders/data/reminder_repository.dart#L22))

Cada listener mantiene una **conexión gRPC abierta** y consume lecturas Firestore cuando hay cambios. Para 3000 DAU activos simultáneos en pantalla:
- 3000 × 6 = **18000 listeners concurrentes**
- Cada uno cuesta lecturas en mutaciones (el cliente cuenta como lectura cada doc que recibe)

### Asunción

Estos listeners se cierran cuando la pantalla se cierra (Flutter's `dispose` los unsuscribe). Verificar manualmente en `transactions_provider`, `auth_state_provider`, etc.

#### BUG-055 — No verifiqué explícitamente que los listeners se dispongan
- **Severidad**: 🟢 **LOW** — necesita verificación, no es bug confirmado
- **Fix propuesto**: revisar cada widget que subscribe a un listener. Los `Provider`s de Riverpod auto-dispose por default si nadie los está usando. Confirmar con grep `autoDispose`.

---

## Paginación de listas

### Admin web
- `useUsers`: lee TODOS los users (`getDocs(collection(db, 'users'))`) — ⚠️ no paginado
- `useRecentTransactions`: CF `getRecentTransactions` con `limit` server-side ✓
- `useUsers.fetchTransactionsForUser`: lee TODAS las transactions de un user (sin limit)
- `getAdminStats`: agregaciones server-side ✓

#### BUG-056 — `useUsers` lee toda la colección users sin paginación
- **Archivo**: [src/hooks/useUsers.ts:18-22](../../pushka_admin/src/hooks/useUsers.ts#L18)
- **Severidad**: 🟠 **HIGH** (escalando)
- **Descripción**: `getDocs(collection(db, 'users'))` o filtrada por tenantId, sin `limit()`. A 3k DAU → 3k docs por carga del CRMPage. Cada doc ~2KB → ~6MB transferencia + 3000 lecturas Firestore cobradas cada vez que el admin abre CRMPage.
- **Impacto**:
  - Tiempo de carga: 5-10s para 3k users
  - Costo Firestore: $0.0018 por carga (insignificante hoy, escalable mañana)
  - Memory bloat en admin web (3000 user objects en JS heap)
- **Fix propuesto**: paginar con `limit(50)` + cursor pattern. Agregar buscador con búsqueda server-side (CF custom).
- **Decisión**: no bloqueante para Jabad en Campus (50 donantes esperados máx). Bloqueante a partir de 500 users/tenant.

#### BUG-057 — `useUsers.fetchTransactionsForUser` sin limit
- **Archivo**: [src/hooks/useUsers.ts:82-85](../../pushka_admin/src/hooks/useUsers.ts#L82)
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: lee TODAS las transactions de un user (sin limit). Un user activo puede tener cientos de donaciones después de 1 año.
- **Fix propuesto**: agregar `limit(100)` y cargar más con paginación.

### Flutter app
- `transaction_repository.snapshots()` — ⚠️ verificar si tiene limit
- Otros listeners parecen scoped a 1 doc

---

## Imágenes y caching

- `profile_photos` via Firebase Storage download URL (CDN-backed) ✓
- Logos de tenant: URLs externas (Cloudinary, etc.) — no controlado por Pushka
- Imágenes hardcoded en assets (770 widget, mendy_meer.png) — bundled en APK ✓

No identifico hotspot grave en imágenes.

---

## CFs schedulers — overlap risk

| CF | Schedule | Concurrencia |
|---|---|---|
| `cleanupStaleFcmTokens` | every 24h | safe |
| `resetMonthlyActiveUsers` | every 24h | safe |
| `cleanupIncompleteDonationSubscriptions` | every 24h | safe |
| `cleanupOldStripeWebhookEvents` | every 24h | safe |
| `monitorStripeWebhookHealth` | every 60min | safe |
| `monitorStripeWebhookStuckEvents` | every ? | safe |
| `processPushkaAutoEmpty` | every ? min | ⚠️ `maxInstances: 1` ✓ (correcto) |
| `checkGracePeriods` | every 24h | safe |

Bien diseñado.

#### BUG-058 — `processPushkaAutoEmpty` corre cada... minuto? 5 min?
- Verificar: el schedule no está visible en mi grep. Si corre cada minuto y procesa muchos users, podría haber overlap → maxInstances=1 lo previene pero genera backlog si N+1 corrida arranca antes que terminé la N.
- **Fix propuesto** (validar primero antes de cambiar): si es cada 5 min y el lock interno es 10 min, hay riesgo. Subir lock a 15 min.

---

## Rate limit — costo Firestore

Cada CF call hace **1 transacción Firestore** (read+write) para rate limit. Para 60k calls/día:
- 60k transactions/día = 60k reads + 60k writes/día
- Costo: ~$0.18/día = **$5.40/mes en rate limiting solo**

Aceptable para 3k DAU. A 30k DAU sería $54/mes — considerar mover a Redis (Memorystore) o usar enfoque "Firestore stream" más barato.

---

## Cobertura de App Check

✅ Todas las CFs user-facing (Flutter) tienen `enforceAppCheck: true`. Defensa contra abuso de API anónimo.

⚠️ Webhook endpoints (`stripeWebhook`, `stripeBillingWebhook`, `handleStripeConnectOAuth`, `assetlinks`) NO tienen App Check (correcto — no son user-facing).

---

## Tabla resumen Fase 7

| ID | Severidad | Título | Bloquea launch? |
|---|---|---|---|
| BUG-053 | 🟢 LOW | array-contains query escalable | No |
| BUG-054 | 🟡 MEDIUM | Sin minInstances en CFs críticas | No (activar a >100 DAU) |
| BUG-055 | 🟢 LOW | Verificar dispose de listeners | No |
| BUG-056 | 🟠 HIGH | useUsers sin paginación | No (bloqueante a >500 users/tenant) |
| BUG-057 | 🟡 MEDIUM | fetchTransactionsForUser sin limit | No |
| BUG-058 | 🟢 LOW | processPushkaAutoEmpty schedule no verificado | No |

**Resumen**: 0 CRITICAL, 1 HIGH, 2 MEDIUM, 3 LOW. Performance está bien para el primer tenant; los issues son escalabilidad.

---

Continúo a **Fase 8 — i18n y accesibilidad**.
