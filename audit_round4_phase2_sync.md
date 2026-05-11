# Auditoría Round 4 — Fase 2: Sync Web Admin ↔ Flutter App

Fecha: 2026-05-11

---

## Flujos de sincronización por grupo

### 2.1 Branding (tenant)

**Cadena de sync:**
1. Admin web `BrandingEditor` → CF `updateTenant` ([functions/index.js:6123](functions/index.js#L6123))
2. `updateTenant` valida (super_admin o tenant_admin del mismo tenant) → escribe `tenants/{id}` con `patch`
3. Trigger `onTenantBrandingUpdated` ([functions/index.js:3307](functions/index.js#L3307)) fan-out a `users/{uid}/tenantState/{tenantId}` de cada miembro
4. Flutter app:
   - Polling cada 60s en `getTenantConfig` → recibe todos los `TENANT_MEMBER_FIELDS` (17 campos)
   - `tenant_theme_provider` reactivo (`select((primary, secondary))`) → rebuilds theme cuando cambia color

**Sub-bugs / gaps:**

#### BUG-007 — Trigger sync solo cubre 5 campos, no todos
- **Archivo**: [functions/index.js:3314-3320](functions/index.js#L3314)
- **Severidad**: 🟢 **LOW**
- **Descripción**: el `fieldMap` del trigger solo sincroniza `name`, `appName`, `logoUrl`, `primaryColor`, `contactPhone` (+ `donationReasons` aparte). Cambios a **`secondaryColor`**, `welcomeText`, `showPoweredBy`, `defaultLanguage/Currency/Country`, `contactEmail`, `privacy/termsUrl`, `city`, `country` NO disparan fan-out a tenantState.
- **Impacto**: estos campos se actualizan en la app solamente via el polling de `getTenantConfig` cada 60s — lag de hasta 60 segundos para que el usuario vea el cambio. Funcionalmente correcto, pero no instantáneo como los 5 campos hot.
- **Fix propuesto**: agregar `secondaryColor` al `fieldMap` (es el único que se usa visualmente en theme). Los otros write-only no hace falta sincronizar antes que se resuelva BUG-004 de Fase 1.

#### BUG-008 — Branding `name` no se renderiza pero sí se sincroniza
- **Severidad**: 🟢 **LOW**
- **Descripción**: el trigger sincroniza `name → tenantName` pero `BrandingEditor` no expone `name` (solo `appName`). `name` solo se setea en `createTenant`. Si super_admin lo cambia desde `TenantDetailPage`, sí se propaga. Pero un tenant_admin no puede cambiarlo. Eso es correcto por diseño.

### 2.2 Settings de donaciones

| Campo | Editado por | Persistencia | Lectura Flutter | Estado |
|---|---|---|---|---|
| `donationReasons` | tenant_admin (BrandingEditor) | `tenants/{id}` + tenantState (trigger) | `tenantConfigProvider`, picker en donación + auto-empty | ✅ **OK** |
| `presetAmount`/`presetAmounts` | usuario en Flutter | `tenantState` (per-tenant) | Flutter local | ✅ **OK** |
| `pushkaGoal` | usuario en Flutter | `tenantState` | Flutter local | ✅ **OK** |
| `defaultCurrency` | tenant_admin | `tenants/{id}` | `settings_screen` (sugerencia al user) | ✅ **OK** pero 60s lag |
| `defaultCountry` | tenant_admin | `tenants/{id}` | `settings_screen` | ✅ **OK** pero 60s lag |
| `paymentMethodsEnabled` | ❌ **no expuesto en admin** | n/a | n/a | **GAP** (decisión: necesario o no?) |
| `minDonation` / `maxDonation` | ❌ **no expuesto en admin** | server-side global (`CURRENCY_MINIMUMS`) | createPaymentIntent valida | ✅ por diseño |
| `allowRecurring` | ❌ **no expuesto en admin** | n/a | siempre activo | ✅ por diseño |

#### BUG-009 — No hay control por tenant de "permitir donaciones recurrentes" ni de "métodos de pago habilitados"
- **Severidad**: 🟢 **LOW**
- **Descripción**: actualmente cualquier tenant permite Card, Google Pay, Apple Pay, recurring, etc. — no se puede inhabilitar features a nivel tenant.
- **Impacto**: si un futuro tenant quiere "solo donaciones únicas, sin recurrentes" no hay forma de configurarlo.
- **Fix propuesto**: posponer. No es bloqueante para launch con Jabad en Campus.

### 2.3 Datos personales del tenant

#### BUG-010 — Cambio de `adminEmail` no transfiere claims ni revoca al admin anterior
- **Archivo**: [functions/index.js:6230-6247](functions/index.js#L6230)
- **Severidad**: 🟠 **HIGH**
- **Descripción**: cuando super_admin cambia `adminEmail` en TenantDetailPage:
  - ✅ `updateTenant` actualiza el campo `adminEmail` y resuelve `adminUid` via `getUserByEmail`
  - ❌ **NO aplica claim `tenant_admin` al nuevo email**
  - ❌ **NO revoca claim del admin anterior**
- **Impacto**:
  1. El admin nuevo no tiene acceso al admin web hasta que super_admin manualmente llame `setAdminClaim` aparte
  2. El admin viejo sigue con role=tenant_admin y tenantId=X en sus claims por hasta 1 hora más, sigue pudiendo editar su tenant
  3. Si el flujo se hace fuera de orden, hay ventana donde el tenant tiene 2 admins activos
- **Fix propuesto**: dentro de `updateTenant`, cuando se cambia `adminEmail`:
  1. Si hay `oldEmail`/`oldUid` resoluble, revocar claims (`role`, `tenantId`) — solo si ese user no es admin de otro tenant
  2. Si hay `newUid`, aplicar claims `{role: 'tenant_admin', tenantId}` (preservando `admin: true` si lo tenía)
  3. Escribir/actualizar `tenants/{tid}/team/{oldUid}` y `team/{newUid}`
  4. Si el nuevo email no tiene cuenta Auth, escribir `_pendingTenantAdmins/{normalizedEmail}` para que se aplique al sign-in (igual que el flujo de invitación nueva)

#### BUG-011 — `support_screen.dart` hardcodea email/branding (ya reportado en Fase 1 BUG-001)
Sigue siendo el bloqueante #1 de multi-tenant.

#### BUG-012 — `legal_content.dart` hardcodea email/textos (ya reportado en Fase 1 BUG-002)

### 2.4 Comisión de plataforma

**Cadena:**
1. `createTenant` setea `commissionRate: 0.03` por defecto (3%)
2. `updateTenant` (super_admin only — `superOnlyFields`) valida 0-0.10 (0-10%)
3. En cada donación, `createPaymentIntent` lee `tenants/{id}.commissionRate`
4. `safeTenantCommissionRate` ([functions/index.js:119](functions/index.js#L119)) valida y aplica fallback **0.03 (3%) si inválido**
5. `application_fee_amount = floor(amount * commissionRate)`, clamped a `[1, amount-1]`
6. Stripe procesa: amount total se cobra al donante → commission al platform account → resto al Connect del tenant

**Estado**: ✅ funcional con bugs menores.

#### BUG-013 — `commissionRate = 0` no se honra (siempre cobra al menos 1 cent)
- **Archivo**: [functions/index.js:787-788](functions/index.js#L787)
- **Severidad**: 🟢 **LOW**
- **Descripción**: `safeFee = Math.max(1, Math.min(rawFee, amount - 1))`. Si `commissionRate = 0`, `rawFee = 0`, pero el `Math.max(1, 0) = 1`. Se cobra siempre al menos 1 cent de fee.
- **Impacto**: tenant que NO debería pagar fee de plataforma igual paga 1 cent por donación. Caso edge muy raro.
- **Fix propuesto**: cambiar a `if (rawFee === 0) { /* no app_fee */ } else { safeFee = Math.max(1, ...) }`. O dejar como está si no se planea cobrar 0 nunca.

#### BUG-014 — Tenant sin Connect onboarding completo recibe donaciones al Stripe principal
- **Archivo**: [functions/index.js:685-689](functions/index.js#L685)
- **Severidad**: 🟠 **HIGH**
- **Descripción**: cuando `stripeConnectAccountId === null` Y `connectStatus === "not_connected"` (estado default después de `createTenant`), el código **cae a charge en platform account sin Connect params**. Las donaciones quedan en el Stripe de Ioel, no del tenant.
- **Impacto**: si un rab invita donantes ANTES de completar Stripe Connect onboarding, esa plata queda en la cuenta de Ioel. Tendría que pasársela manualmente por transferencia bancaria — operacionalmente feo y propenso a errores.
- **Fix propuesto recomendado**: cambiar la rama default a "rechazar pago con error amigable":
  ```js
  if (!tenantConnectAccountId) {
    throw new HttpsError("failed-precondition",
      "Tu organización todavía no completó la conexión con el procesador de pagos. " +
      "Avisale al administrador para que lo configure.");
  }
  ```
  Y agregar pantalla en Flutter que detecte `connectStatus !== 'active'` y muestre "donaciones temporalmente deshabilitadas".

### 2.5 Suscripción mensual SaaS

**Hallazgo crítico**: hay **dos campos en el tenant doc** relacionados al precio mensual:
- `planPrice` (default 99 en createTenant)
- `subscriptionMonthlyAmount` (sin default; editable en TenantDetailPage)

Pero **solo `planPrice` es lo que Stripe efectivamente cobra** (createTenantSubscription line 7000: `unit_amount: Math.round(planPrice * 100)`).

#### BUG-015 — `subscriptionMonthlyAmount` es un campo fantasma (no afecta cobro real)
- **Archivos**: 
  - [src/pages/TenantDetailPage.tsx:214](../../pushka_admin/src/pages/TenantDetailPage.tsx#L214) (edita)
  - [functions/index.js:6169](functions/index.js#L6169) (acepta)
  - [src/pages/FinanzasPage.tsx:56](../../pushka_admin/src/pages/FinanzasPage.tsx#L56) (lo usa solo para LTV calc)
  - NO se usa en `createTenantSubscription`
- **Severidad**: 🟠 **HIGH**
- **Descripción**: super_admin puede editar `subscriptionMonthlyAmount` desde `TenantDetailPage` y queda persistido, pero **el cobro real sigue siendo `planPrice`**. Si los dos campos desyncan (super_admin tipea $150 en `subscriptionMonthlyAmount` pero `planPrice` sigue en $99), el dashboard de LTV miente.
- **Impacto**:
  - Reportes financieros incorrectos
  - Si super_admin cree que está cambiando el precio del tenant, pero no, el tenant sigue pagando lo viejo
- **Fix propuesto**:
  1. **Decidir**: ¿son el mismo concepto? Si sí, **eliminar `subscriptionMonthlyAmount`** y usar solo `planPrice`. Si distintos (ej. `planPrice` es lista, `subscriptionMonthlyAmount` es real cobrado con descuentos), documentar y validar coherencia.
  2. Actualizar `TenantDetailPage` para mostrar solo uno o explicar la diferencia.

#### BUG-016 — `createTenantSubscription` CF no se llama desde ningún lado (CRITICAL)
- **Archivo**: [functions/index.js:6944](functions/index.js#L6944)
- **Severidad**: 🔴 **CRITICAL**
- **Descripción**: la CF `createTenantSubscription` existe pero **no se invoca desde admin web, Flutter, ni internamente desde otra CF**. Verificado con grep en ambos repos.
- **Impacto**: cuando `createTenant` corre, deja al tenant con `paymentStatus: "trial"` y `stripeSubscriptionId: null` — **el tenant nunca recibe factura mensual de SaaS**. Pushka no factura su mensualidad a ningún cliente actualmente.
- **Reproducción**: crear un tenant nuevo desde admin → ver `tenants/{id}` en Firestore → `stripeSubscriptionId` queda null para siempre.
- **Fix propuesto**:
  1. **Inmediato**: super_admin invoca manualmente la CF desde la consola (gcloud o admin web con un botón nuevo) para Jabad en Campus cuando empiece a cobrarse mensualidad.
  2. **Largo plazo**: agregar UI en `TenantDetailPage` con botón "Activar suscripción SaaS" que llame esta CF. O encadenar `createTenant` → `createTenantSubscription` automáticamente cuando el rab confirme Stripe Connect.

#### BUG-017 — Cambiar `planPrice` post-creación no actualiza el Stripe Subscription
- **Severidad**: 🟠 **HIGH**
- **Descripción**: si super_admin edita `planPrice` de $99 a $150 desde `TenantDetailPage`, el campo se actualiza en Firestore pero **la suscripción Stripe sigue cobrando el precio viejo**. La forma correcta sería: crear nuevo `Price` object en Stripe y hacer `subscriptions.update` con el nuevo price + proration.
- **Impacto**: cambios de precio en admin no se aplican; el super_admin tendría que hacerlo manualmente desde Stripe Dashboard.
- **Fix propuesto**: cuando `updateTenant` cambia `planPrice` y el tenant tiene `stripeSubscriptionId`, llamar `stripe.subscriptions.update` con proration config. **Pendiente decisión**: ¿proration inmediato o aplicar al siguiente ciclo?

---

## Tabla resumen de bugs Fase 2

| ID | Severidad | Título | Archivo | Bloquea launch? |
|---|---|---|---|---|
| BUG-007 | 🟢 LOW | Trigger sync solo cubre 5 campos | functions/index.js:3314 | No |
| BUG-008 | 🟢 LOW | `name` solo sincroniza una vía | n/a | No |
| BUG-009 | 🟢 LOW | No hay toggle paymentMethods/recurring por tenant | n/a | No |
| BUG-010 | 🟠 HIGH | Cambio adminEmail no transfiere claims | functions/index.js:6230 | **Sí** (operacional) |
| BUG-011 | 🔴 CRITICAL | `support_screen` hardcodea (= BUG-001) | lib/features/support/...:99 | **Sí** |
| BUG-012 | 🟠 HIGH | `legal_content` hardcodea (= BUG-002) | lib/features/legal/...:42 | **Sí** |
| BUG-013 | 🟢 LOW | commissionRate=0 siempre cobra 1 cent | functions/index.js:787 | No |
| BUG-014 | 🟠 HIGH | Tenant sin Connect activo recibe en platform | functions/index.js:685 | **Sí** |
| BUG-015 | 🟠 HIGH | `subscriptionMonthlyAmount` fantasma | TenantDetailPage:214 | No (LTV miente pero no bloquea) |
| BUG-016 | 🔴 CRITICAL | `createTenantSubscription` no se llama nunca | functions/index.js:6944 | **Sí** (Pushka no factura) |
| BUG-017 | 🟠 HIGH | Cambio `planPrice` no actualiza Stripe | functions/index.js:updateTenant | **Sí** (cambios fantasma) |

**Resumen**: 2 CRITICAL, 5 HIGH, 4 LOW. La sincronización tiene **gaps reales en el camino del dinero** (Connect + Subscription).

---

Continúo a **Fase 3 — Stripe Connect**.
