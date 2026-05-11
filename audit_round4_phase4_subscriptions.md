# Auditoría Round 4 — Fase 4: Suscripción mensual SaaS

Fecha: 2026-05-11

---

## Flujo actual (estado de las cosas)

```
[super_admin crea tenant]
        ↓
createTenant CF — setea paymentStatus="trial", stripeSubscriptionId=null, planPrice=99
        ↓
   [GAP CRÍTICO]
        ↓
createTenantSubscription CF existe pero NUNCA SE LLAMA
        ↓
   tenant queda en "trial" indefinidamente
        ↓
   Pushka NO factura nada al rab
```

Hay TODA la infraestructura para billing SaaS (`createTenantSubscription`, `cancelTenantSubscription`, `stripeBillingWebhook` con succeeded/failed handlers, `checkGracePeriods` cron diario con reminders, dunning emails) — pero **el primer paso de la cadena no se dispara**.

---

## CFs revisadas

### `createTenantSubscription` ([functions/index.js:6944](functions/index.js#L6944))
- Super_admin only (fresh claims) ✓
- Rate limit 5/h ✓
- Idempotency keys con `tenantId` + `planPrice` ✓
- Crea Stripe customer + price + subscription ✓
- Setea `paymentStatus: "pending_payment"` (subscription incomplete hasta primer pago)
- Returns `clientSecret` para que el rab confirme con SetupIntent ✓
- **Pero**: no se llama desde ningún UI

### `cancelTenantSubscription` ([functions/index.js:7044](functions/index.js#L7044))
- Super_admin only ✓
- `cancel_at_period_end: true` ✓ (mantiene acceso hasta fin del ciclo)
- Setea `paymentStatus: "canceling"`
- ❌ **No envía email** ni al admin del tenant ni al super_admin

### `deleteTenant` ([functions/index.js:7106](functions/index.js#L7106))
- Super_admin only + rate limit + audit log ✓
- Cancela Stripe sub + borra customer ✓
- Borra slug lock ✓
- Paginated user sweep (tenantIds, tenantState, legacy tenantId) ✓
- ❌ **No revoca claims** de los users que tenían `role=tenant_admin/collaborator` apuntando al tenant. Quedan con claims huérfanos hasta el próximo `getTenantConfig` (que sí los limpia — orphan healing).

### `stripeBillingWebhook` ([functions/index.js:7286](functions/index.js#L7286))
- Signature validation ✓
- Idempotency vía `_stripeWebhookEvents` ✓
- `invoice.payment_succeeded`: marca `status: "active"`, `paymentStatus: "current"`, clears grace ✓
- `invoice.payment_failed`: 30 días grace + emails al admin + super_admin + activityLog ✓
- ❌ **No maneja `customer.subscription.deleted/updated`** — pero esto se maneja en `stripeWebhook` (línea 2827) con routing por separado. OK arquitectónicamente pero confuso.
- ❌ **No maneja `invoice.upcoming`** — no se avisa al admin un cobro próximo (Stripe lo manda ~3 días antes si está subscrito al evento).

### `checkGracePeriods` ([functions/index.js:7453](functions/index.js#L7453))
- Diario, busca `paymentStatus == "grace_period"` ✓
- Si `daysLeft <= 0` → `paymentStatus: "suspended"` + email + activityLog ✓
- Reminders en días 30, 20, 10, 5 ✓
- Deduplicación por día (`lastReminderEmailSentAt`) ✓

---

## Bugs encontrados

### BUG-026 — `createTenantSubscription` orfana (= BUG-016 escalado)
- **Severidad**: 🔴 **CRITICAL**
- **Descripción**: ya documentado en Fase 2 BUG-016. Lo refuerzo: este es **el bloqueante #1 del modelo de negocio SaaS**. Sin esta CF llamada, Pushka no factura mensualidad a ningún tenant.
- **Fix obligatorio**:
  1. Agregar botón "Activar suscripción mensual" en `TenantDetailPage` (super_admin only)
  2. Botón llama `createTenantSubscription({ tenantId })` → recibe `clientSecret`
  3. Si hay `clientSecret`, abrir flujo de SetupIntent en admin web para que el rab confirme método de pago (o enviarle link por email)
  4. **Alternativa más simple**: encadenar `createTenant` → `createTenantSubscription` automáticamente al crear el tenant, y mostrar el `clientSecret` en `TenantCreatePage` como "Próximo paso: completá pago".
- **Validación post-fix**: crear un tenant nuevo en dev, verificar que `stripeSubscriptionId` queda set, confirmar primer pago de $1 USD con tarjeta test.

### BUG-027 — Cambiar `planPrice` post-creación no actualiza el Stripe Subscription (= BUG-017)
- **Severidad**: 🟠 **HIGH**
- **Descripción**: ya documentado en Fase 2 BUG-017.
- **Fix propuesto** (en detalle):
  ```js
  // Dentro de updateTenant, después de aplicar patch a Firestore:
  if (isSuper && "planPrice" in updates && tenantData.stripeSubscriptionId) {
    const stripe = require("stripe")(stripeSecret.value());
    // Crear nuevo Price object
    const newPrice = await stripe.prices.create({
      currency: "usd",
      unit_amount: Math.round(patch.planPrice * 100),
      recurring: { interval: "month" },
      product_data: { name: `Pushka SaaS — ${tenantData.name}` },
    }, { idempotencyKey: `tenant_price_${tenantId}_${Math.round(patch.planPrice * 100)}` });
    
    // Actualizar la subscription al nuevo price
    const sub = await stripe.subscriptions.retrieve(tenantData.stripeSubscriptionId);
    await stripe.subscriptions.update(tenantData.stripeSubscriptionId, {
      items: [{ id: sub.items.data[0].id, price: newPrice.id }],
      proration_behavior: "create_prorations", // o "none" según preferencia
    });
  }
  ```
  Decisión a confirmar: **proration o no?** Por defecto Stripe prorratea (cobra/credita la diferencia inmediatamente).

### BUG-028 — `subscriptionMonthlyAmount` campo fantasma (= BUG-015)
- Ya documentado. Decidir si eliminar o documentar.

### BUG-029 — `cancelTenantSubscription` no envía email de confirmación
- **Severidad**: 🟢 **LOW**
- **Descripción**: cuando super_admin cancela, el admin del tenant NO recibe email avisando. Solo se entera al fin del período cuando el servicio se suspenda.
- **Fix propuesto**: enviar email al `adminEmail` del tenant + activityLog. Útil para registro y para que el rab pueda objetar/renovar.

### BUG-030 — `deleteTenant` no revoca claims de tenant_admin/collaborator
- **Severidad**: 🟡 **MEDIUM**
- **Archivo**: [functions/index.js:7106](functions/index.js#L7106)
- **Descripción**: cuando se borra un tenant:
  - Sweep `users.tenantIds` para quitar el tenantId — ✓
  - Borra `tenantState/{tenantId}` — ✓
  - **NO toca `admin.auth().customClaims`** — usuarios que eran tenant_admin/tenant_collaborator de este tenant quedan con claim `role` y `tenantId` apuntando a un tenant que ya no existe
- **Impacto**: hasta el próximo `getTenantConfig` (que tiene orphan healing → limpia claims), el usuario puede seguir intentando llamar CFs con el claim viejo. Las CFs validan claims pero el tenantId apunta a void → 404 errors silenciosos.
- **Fix propuesto**: durante el sweep, si `userData.tenantId === tenantId` Y el user tenía claim `role: tenant_admin/collaborator` con ese `tenantId`, llamar `admin.auth().setCustomUserClaims(uid, { ...keepOthers })` removiendo `role` y `tenantId`. Encadenar al batch que ya itera.

### BUG-031 — `createTenant` setea `paymentStatus: "trial"` pero `status: "active"` (inconsistencia)
- **Archivo**: [functions/index.js:5753-5785](functions/index.js#L5753)
- **Severidad**: 🟢 **LOW**
- **Descripción**: status del tenant queda en `"active"` mientras `paymentStatus` está en `"trial"`. El flag `status` controla si los donantes pueden usar la app (createPaymentIntent chequea `status === "suspended"`). Combinado con BUG-026, esto significa: tenants en trial pueden recibir donaciones reales aunque Pushka no esté cobrándoles aún. Aceptable como design pero conflictivo si el modelo es "free trial sin cobrar comisión".
- **Fix propuesto**: clarificar el semantic. Si "trial" implica algún beneficio (sin comisión, etc.), implementarlo. Si trial es solo administrativo, eliminar el estado y arrancar como `current` o `pending_payment`.

### BUG-032 — `checkGracePeriods` ejecuta cada 24h, ventana de hasta 25h sin chequeo
- **Severidad**: 🟢 **LOW**
- **Descripción**: el cron es `every 24 hours`. Si el cron se ejecuta a las 10:00 día N y al día siguiente N+1 a las 10:50, hubo una ventana donde un tenant que entró en grace exactamente a las 10:30 del día N-30 quedó 25h por encima del límite antes de ser suspendido.
- **Fix propuesto**: cambiar a `every 6 hours` o `every 12 hours`. Menor latencia, costo despreciable (lectura de pocos docs).

### BUG-033 — Webhook de invoice cuenta toda en USD, pero algunos campos como `amount_paid` deberían ser dividido por divisor de moneda
- **Archivo**: [functions/index.js:7351](functions/index.js#L7351)
- **Severidad**: 🟢 **LOW**
- **Descripción**: `const amountPaid = (invoice.amount_paid ?? 0) / 100;` asume USD (divisor 100). Si Pushka factura SaaS solo en USD (BUG-025) esto está bien. Documentar.

### BUG-034 — No hay UI de "billing portal" para que tenant_admin gestione su pago
- **Severidad**: 🟠 **HIGH**
- **Descripción**: el rab no tiene forma de:
  - Cambiar su método de pago si la tarjeta vence
  - Ver historial de facturas
  - Descargar recibos
  
  Stripe ofrece `billing_portal.sessions.create` para esto — abre un portal hosteado donde el customer hace self-service. Actualmente la única vía es que el super_admin (Ioel) intervenga manualmente desde Stripe Dashboard.
- **Fix propuesto**: agregar CF `createBillingPortalSession({ tenantId })` que retorna un URL. Botón en `MyOrganizationPage` para tenant_admin → "Gestionar suscripción y método de pago". Bloqueante para escalar más allá de 1 tenant.

---

## Tabla resumen Fase 4

| ID | Severidad | Título | Bloquea launch? |
|---|---|---|---|
| BUG-026 | 🔴 CRITICAL | createTenantSubscription no se llama | **Sí** (modelo SaaS no factura) |
| BUG-027 | 🟠 HIGH | Cambio planPrice no se aplica a Stripe sub | **Sí** (cambios fantasma) |
| BUG-028 | 🟠 HIGH | subscriptionMonthlyAmount campo fantasma | No |
| BUG-029 | 🟢 LOW | cancelTenantSubscription sin email | No |
| BUG-030 | 🟡 MEDIUM | deleteTenant no revoca claims | No (orphan healing lo cubre eventualmente) |
| BUG-031 | 🟢 LOW | status/paymentStatus inconsistente en trial | No |
| BUG-032 | 🟢 LOW | checkGracePeriods cada 24h | No |
| BUG-033 | 🟢 LOW | invoice amount asume USD | No |
| BUG-034 | 🟠 HIGH | Sin billing portal para tenant_admin | **Sí** (operación insostenible a escala) |

**Resumen**: 1 CRITICAL, 3 HIGH, 1 MEDIUM, 4 LOW.

---

## Recomendación operacional inmediata (pre-launch Jabad en Campus)

**Para arrancar a facturar Jabad en Campus YA sin esperar la implementación completa de BUG-026:**

1. Crear el tenant via admin (como ya está)
2. Super_admin (Ioel) llama `createTenantSubscription({ tenantId })` manualmente desde Cloud Shell:
   ```bash
   curl -X POST https://us-central1-pushka-app-ioel.cloudfunctions.net/createTenantSubscription \
     -H "Authorization: Bearer $(firebase auth:print-access-token)" \
     -H "Content-Type: application/json" \
     -d '{"data":{"tenantId":"<TENANT_ID>"}}'
   ```
3. Recibe `clientSecret` en la respuesta — pasarlo al rab manualmente para que confirme método de pago via Stripe Elements (custom form)

**Pero**: implementar BUG-026 fix correctamente es 1-2 horas de trabajo. Recomiendo no usar el workaround salvo emergencia.

---

Continúo a **Fase 5 — Seguridad**.
