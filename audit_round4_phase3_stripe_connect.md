# Auditoría Round 4 — Fase 3: Stripe Connect (flujo de dinero)

Fecha: 2026-05-11

---

## Flujo end-to-end de una donación

1. **Flutter**: `StripeService.pay()` → CF `createPaymentIntent({ amount, currency, tenantId, donationReason, correlationId })`
2. **CF `createPaymentIntent`** ([functions/index.js:564](functions/index.js#L564)):
   - Auth + AppCheck + rate limit (10/10min)
   - Block check (`adminData.isBlocked`)
   - Lee `users/{uid}` para `tenantId`
   - Lee `tenants/{tid}` para `commissionRate` y `stripeConnectAccountId/Status`
   - **Lock anti-double-charge** (10 min TTL) en `tenantState._autoEmptyChargeLockAt` para `pushka_empty`
   - Construye PaymentIntent con:
     - `amount` (validated, currency-aware minimum)
     - `application_fee_amount = floor(amount * commissionRate)` clamp `[1, amount-1]`
     - `transfer_data.destination = tenantConnectAccountId` (cuando Connect activo)
     - `metadata` con `uid, purpose, tenantId, connectAccountId, donorMessage, donationReason, correlationId`
   - **Idempotency key**: `pi_{uid}_{correlationId}` (correlationId del cliente o random)
3. **Flutter**: `Stripe.presentPaymentSheet()` → user paga
4. **Stripe webhook** → CF `stripeWebhook` HTTP ([functions/index.js:2223](functions/index.js#L2223)):
   - Valida firma + idempotencia (`_stripeWebhookEvents/{eventId}`)
   - En `payment_intent.succeeded`: escribe `users/{uid}/transactions/{piId}` con `tenantId, amount, fee, currency, paymentMethod, donationReason, correlationId`
   - Llama `incrementTenantRevenue(tenantId, amountUSD)` para revenue counter pre-agregado
   - Detecta **drift** entre `stamped connectAccountId` y `current tenant.stripeConnectAccountId`
5. **Trigger `onTransactionCreated`** ([functions/index.js:3005](functions/index.js#L3005)) → actualiza MAU + streak

---

## Eventos webhook manejados

✅ Cobertura completa. Verificado en [functions/index.js:2277-2975](functions/index.js#L2277):

| Evento | Manejado | Acciones |
|---|---|---|
| `payment_intent.succeeded` | ✅ | escribe tx + actualiza revenue + libera lock pushka_empty + reset pushkaAmount |
| `payment_intent.payment_failed` | ✅ | escribe paymentEvent + libera lock |
| `payment_intent.canceled` | ✅ | escribe paymentEvent |
| `charge.refunded` | ✅ | escribe negating tx + paymentEvent + out-of-order guard |
| `charge.dispute.created` | ✅ | escribe negating tx + paymentEvent |
| `charge.dispute.closed` | ✅ | si `won` borra el negating tx, si `lost` lo mantiene |
| `charge.dispute.funds_withdrawn` | ✅ | paymentEvent journal |
| `charge.dispute.funds_reinstated` | ✅ | paymentEvent journal |
| `account.updated` | ✅ | sincroniza `stripeConnectStatus` + writeActivityLog en transición a active |
| `application_fee.created` | ✅ | log (sin escritura) |
| `application_fee.refunded` | ✅ | log |
| `customer.subscription.deleted/updated` | ✅ | mapea sub.status → tenant.status (active/grace_period/suspended) |
| `invoice.payment_succeeded` (donation_recurring) | ✅ | escribe tx para invoice de subscription de donante |
| `invoice.payment_failed` (donation_recurring) | ✅ | paymentEvent |

**Calidad técnica del webhook**: 🟢 muy buena.
- Signature validation ✓
- Idempotencia ✓
- Out-of-order guard (refund_before_original) ✓
- Drift detection (connectAccountId) ✓
- correlationId threading ✓
- payment_method real (Apple Pay / Google Pay) detectado vía `card.wallet.type` ✓

---

## OAuth Stripe Connect

`createStripeConnectLink` ([functions/index.js:6689](functions/index.js#L6689)) y `handleStripeConnectOAuth` ([functions/index.js:6749](functions/index.js#L6749)):
- CSRF state token de 20 bytes (40 hex chars) con TTL de 24h ✓
- `redirect_uri` dinámico por proyecto (prod vs test) ✓
- Exchange `code → stripe_user_id` vía `stripe.oauth.token` ✓
- Setea `stripeConnectAccountId` + `stripeConnectStatus: 'active'` post-callback ✓

---

## Bugs encontrados

### BUG-018 — Donaciones a tenant sin Connect onboarding caen al Stripe principal (= BUG-014 reformulado)
- **Archivo**: [functions/index.js:685-689](functions/index.js#L685)
- **Severidad**: 🔴 **CRITICAL** (escalado de HIGH a CRITICAL — es bloqueante real para launch)
- **Descripción**: detalle ya en Fase 2 BUG-014. Acá lo escalo porque cuando hablamos de "el flujo del dinero" este es el punto de leakage más serio:
  - Tenant nuevo creado → `stripeConnectAccountId: null`, `stripeConnectStatus: "not_connected"`
  - Si el tenant_admin comparte el slug e invita donantes ANTES de hacer Connect onboarding → las donaciones se cobran a la cuenta Stripe principal de Pushka (Ioel) **con `application_fee_amount` setado pero `transfer_data` ausente**
  - Stripe acepta esto como charge normal en la cuenta principal — el rab nunca recibe nada
- **Fix obligatorio antes de invitar al rab a producción**:
  ```js
  // ANTES (líneas 685-689):
  // If connectAccountId is null AND status is not_connected: tenant never
  // set up Connect — fall through to platform-account charge (the original
  // behavior). This is intentional for tenants still in onboarding.
  
  // DESPUÉS:
  if (!tenantConnectAccountId) {
    throw new HttpsError(
      "failed-precondition",
      "Esta organización todavía no completó la configuración de pagos. " +
      "Avisale al administrador para que active Stripe Connect."
    );
  }
  ```
- Adicional: agregar pantalla en Flutter que detecte el error y muestre mensaje amigable.

### BUG-019 — `stripeConnectStatus="active"` se setea sin verificar `charges_enabled`
- **Archivo**: [functions/index.js:6795-6800](functions/index.js#L6795)
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: `handleStripeConnectOAuth` setea status=active inmediatamente después del OAuth exchange, sin chequear que la cuenta efectivamente puede recibir charges. Stripe OAuth solo confirma que el rab autorizó — la verificación KYC, banco, etc. puede estar pendiente.
- **Impacto**: hay una ventana entre OAuth callback y la primera notification de `account.updated` donde:
  - `createPaymentIntent` cree que el tenant está "active" y enruta donación con transfer_data
  - Stripe rechaza con error tipo "destination account cannot accept charges"
  - El user ve error genérico "no se pudo procesar el pago"
- **Probabilidad**: baja en producción (Stripe usualmente completa verificación antes del OAuth), pero posible en test mode o cuentas con requisitos faltantes.
- **Fix propuesto**:
  ```js
  // Tras el oauth.token exchange, retrievear el account para confirmar status
  const acct = await stripe.accounts.retrieve(stripeConnectAccountId);
  const isReady = acct.charges_enabled && acct.payouts_enabled;
  await tenantDoc.ref.update({
    stripeConnectAccountId,
    stripeConnectStatus: isReady ? "active" : "restricted",
    ...
  });
  ```

### BUG-020 — Idempotency key del PI usa correlationId arbitrario del cliente
- **Archivo**: [functions/index.js:730-777](functions/index.js#L730)
- **Severidad**: 🟢 **LOW**
- **Descripción**: el comentario explica bien por qué se cambió de `(uid + purpose + amount + currency + hour_bucket)` a `(uid + correlationId)`: Stripe rechaza retries con misma key si los params no son idénticos, y `application_fee_amount` puede cambiar entre intentos.
  - El trade-off: si el cliente NO envía correlationId, el server genera uno random → dos intentos rápidos del mismo user obtendrán keys distintas → potencial double-charge si el cliente no tiene `_processing` guard.
- **Estado**: la protección anti-double-tap está delegada al cliente (`_processing` guard). Validar en Fase 9 (tests) que ese guard existe en `StripeService.pay`.

### BUG-021 — `incrementTenantRevenue` se ejecuta dentro del webhook sin await en algunos paths
- **Archivo**: [functions/index.js:2417 y 2919](functions/index.js#L2417)
- **Severidad**: 🟢 **LOW**
- **Descripción**: `if (txTenantId) await incrementTenantRevenue(txTenantId, txSnap.amountUSD);` — sí tiene await. OK, falsa alarma.

### BUG-022 — Drift de Connect: queda solo en log, no se notifica al super_admin
- **Archivo**: [functions/index.js:2360-2367](functions/index.js#L2360)
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: cuando un PaymentIntent fue creado con `connectAccountId=X` pero al momento del webhook el tenant ya tiene `connectAccountId=Y`, se loguea como ERROR pero no se escribe en `_activityLog` ni se manda email al super_admin. El dinero ya fue a la cuenta vieja (X) pero el sistema lo atribuye al tenant — sin alerta, queda enterrado en Cloud Logging.
- **Impacto**: si el rab cambia su Stripe Connect (raro pero posible — ej. cambio de banco, regenerar credenciales), donaciones in-flight quedan misroutadas y nadie se entera hasta auditoría manual.
- **Fix propuesto**: cuando se detecta drift, escribir en `_activityLog` con `severity: 'error'` + `requiresAction: true`. La pantalla `/activity` en admin web ya marca pendientes en el sidebar.

### BUG-023 — `account.updated` no notifica a super_admin cuando un tenant pasa a "restricted"
- **Archivo**: [functions/index.js:2748-2757](functions/index.js#L2748)
- **Severidad**: 🟠 **HIGH**
- **Descripción**: el handler escribe `_activityLog` cuando un tenant pasa a "active" (`stripe_connect_activated`) — pero NO escribe nada cuando pasa de "active" a "restricted" (= el rab perdió la capacidad de cobrar). Esto debería ser ALERT PROMINENT — sin Connect activo, los nuevos PaymentIntents fallarán (gracias a BUG-018 fix).
- **Fix propuesto**: agregar branch:
  ```js
  if (newConnectStatus === "restricted" && prevConnectStatus === "active") {
    await writeActivityLog({
      type: "stripe_connect_restricted",
      tenantId: tenantsSnap.docs[0].id,
      tenantName: tenantDocData.name,
      severity: "error",
      requiresAction: true,
      data: { accountId, charges_enabled: chargesEnabled, payouts_enabled: payoutsEnabled },
    });
    // Optional: send email to super_admin
  }
  ```

### BUG-024 — Refund flow no refundea proporcionalmente la `application_fee`
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: cuando el tenant emite un refund desde Stripe Dashboard, Stripe automáticamente refundea la `application_fee` (`application_fee.refunded` evento). El webhook actual loguea esto pero no escribe un ajuste a `tenants/{id}` revenue. La pantalla de finanzas mostraría revenue inflado.
- **Fix propuesto**: en el handler de `application_fee.refunded`, decrementar `tenants/{tid}` revenue counter en proporción al refundedAmount.

### BUG-025 — Validación de moneda hardcodeada en createTenantSubscription
- **Archivo**: [functions/index.js:6999](functions/index.js#L6999)
- **Severidad**: 🟢 **LOW**
- **Descripción**: `currency: "usd"` hardcodeado para la suscripción SaaS del tenant. Tenants en LATAM/Israel facturados en USD aunque su contabilidad sea en otra moneda. Decisión de negocio aceptable, pero documentar.
- **Fix propuesto**: dejar así si Pushka factura SaaS solo en USD. Documentar.

---

## Tabla resumen de bugs Fase 3

| ID | Severidad | Título | Bloquea launch? |
|---|---|---|---|
| BUG-018 | 🔴 CRITICAL | Donaciones sin Connect activo van al Stripe principal | **Sí** |
| BUG-019 | 🟡 MEDIUM | OAuth marca active sin verificar charges_enabled | No (pero confunde tests) |
| BUG-020 | 🟢 LOW | Idempotency key con correlationId arbitrario | No |
| BUG-022 | 🟡 MEDIUM | Drift Connect no notifica super_admin | No |
| BUG-023 | 🟠 HIGH | account.updated→restricted no alerta | No (pero operacionalmente serio) |
| BUG-024 | 🟡 MEDIUM | Refund no ajusta tenant revenue counter | No (números incorrectos en panel) |
| BUG-025 | 🟢 LOW | SaaS sub hardcoded en USD | No |

**Resumen**: 1 CRITICAL, 1 HIGH, 3 MEDIUM, 2 LOW.

El webhook está **muy bien diseñado** (idempotencia, signature, drift, out-of-order). Los gaps son operacionales/observabilidad.

---

Continúo a **Fase 4 — Suscripción mensual SaaS**.
