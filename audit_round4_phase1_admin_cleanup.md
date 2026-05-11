# Auditoría Round 4 — Fase 1: Limpieza del admin web

Fecha: 2026-05-11

---

## 1. Clasificación de páginas

| Página | Acceso | Status | Notas |
|---|---|---|---|
| `LoginPage` | público | **USED** | core auth |
| `DashboardPage` | RequireAdmin | **USED** | `useAdminStats` + `useRecentTransactions` (scope por tenant) |
| `CRMPage` | RequireAdmin | **USED** | listado de usuarios con `useUsers` |
| `TransactionsPage` | RequireAdmin | **USED** | `useRecentTransactions` |
| `OverviewPage` | RequireAdmin | **USED** | KPIs + failed payments + super dashboard |
| `UserHistoryPage` | RequireAdmin | **USED** | per-user transactions |
| `ActivityPage` | super_admin only | **USED** | feed `_activityLog` + resolver |
| `AdminsPage` | super_admin only | **USED** | gestiona super_admins (NO tenant_admins — esos se manejan desde `MyOrganizationPage` / `TenantDetailPage`) |
| `SettingsPage` | RequireAdmin | **THIN** | solo theme toggle + idioma admin (NO escribe nada a Firestore). OK como utility |
| `TenantsPage` | super_admin only | **USED** | listTenants + backfillTenantSlugs |
| `TenantCreatePage` | super_admin only | **USED** | createTenant |
| `TenantDetailPage` | super_admin only | **USED** | updateTenant (4 grupos) + cancelTenantSubscription + deleteTenant + Stripe Connect link |
| `MyOrganizationPage` | tenant_admin/collab | **USED** | BrandingEditor + TeamSection |
| `FinanzasPage` | super_admin only | **USED** | LTV/revenue por tenant + edit commissionRate |

**Resultado**: ninguna página entera está obsoleta. Todas tienen propósito vigente.

---

## 2. Campos de BrandingEditor: write-only vs used

`BrandingEditor` (component) llama `updateTenant` con 16 campos. La Flutter app construye `TenantConfig` a partir de `tenants/{id}` (vía CF `getTenantConfig`).

| Campo | Admin escribe | Flutter lee/muestra | Status | Dónde se usa en Flutter |
|---|---|---|---|---|
| `appName` | ✅ | ✅ | **USED** | drawer, payment merchantName (4 lugares), join_via_link |
| `welcomeText` | ✅ | ❌ | **WRITE_ONLY** ⚠️ | solo aparece en `tenant_config.dart` (deserializa pero nunca renderiza) |
| `primaryColor` | ✅ | ✅ | **USED** | `tenant_theme_provider`, theme |
| `secondaryColor` | ✅ | ✅ | **USED** | `tenant_theme_provider` |
| `logoUrl` | ✅ | ✅ | **USED** | drawer, account switcher, join_via_link |
| `showPoweredBy` | ✅ | ❌ | **WRITE_ONLY** ⚠️ | no se renderiza "Powered by Pushka" en ningún footer |
| `defaultLanguage` | ✅ | ❌ | **WRITE_ONLY** ⚠️ | no se aplica al user al joinar tenant |
| `defaultCurrency` | ✅ | ✅ | **USED** | `settings_screen` (currency picker hint) |
| `defaultCountry` | ✅ | ✅ | **USED** | `settings_screen` |
| `contactEmail` | ✅ | ❌ | **WRITE_ONLY** ⚠️ | `support_screen` hardcodea `jymmexico@gmail.com`; `legal_content` hardcodea `support@pushkaapp.com` |
| `contactPhone` | ✅ | ❌ | **WRITE_ONLY** ⚠️ | sin UI que lo muestre |
| `privacyPolicyUrl` | ✅ | ❌ | **WRITE_ONLY** ⚠️ | la app tiene `legal_content.dart` con texto in-app en 4 idiomas; nunca abre URL externa del tenant |
| `termsUrl` | ✅ | ❌ | **WRITE_ONLY** ⚠️ | igual |
| `city` | ✅ | ⚠️ parcial | **DEAD-WEIGHT** | `tenant_summary.dart` lo deserializa pero ninguna pantalla lo renderiza |
| `country` | ✅ | ⚠️ parcial | **DEAD-WEIGHT** | idem |
| `donationReasons` | ✅ | ✅ | **USED** | `donation_subscriptions_screen`, `auto_empty_screen` |

**Resumen**: de 16 campos editables, **8 son WRITE_ONLY** (welcomeText, showPoweredBy, defaultLanguage, contactEmail, contactPhone, privacyPolicyUrl, termsUrl) + **2 DEAD-WEIGHT** (city/country). Solo 7 campos efectivamente impactan la app.

---

## 3. Bugs encontrados

### BUG-001 — `support_screen.dart` hardcodea email y branding (CRITICAL)
- **Archivo**: [lib/features/support/presentation/support_screen.dart:99](lib/features/support/presentation/support_screen.dart#L99)
- **Severidad**: 🔴 **CRITICAL**
- **Descripción**: el screen de "Soporte" muestra `jymmexico@gmail.com` hardcoded y el título es `tr.colelJabad` ("Colel Chabad") + tagline `tr.tagline1788`. Cualquier otro tenant que use la app va a ver el email del rab de Jabad en Campus México y branding "Colel Chabad" — totalmente no multi-tenant.
- **Reproducción**: instalar la app → unirse a un tenant distinto a Jabad en Campus → Settings → Soporte → ver email/branding del rab equivocado.
- **Impacto**: viola el modelo multi-tenant. Si un donante de tenant X tiene problema, le pide soporte al rab de tenant Y. Bloquea launch a múltiples tenants.
- **Fix propuesto**: leer `contactEmail` y `contactPhone` desde `tenantConfigProvider`, fallback a `support@pushkaapp.com` solo si el tenant no tiene email configurado. Reemplazar título hardcoded por `appName` o `name` del tenant. Reemplazar foto hardcoded (`mendy_meer.png`) por logo del tenant.

### BUG-002 — `legal_content.dart` hardcodea email de soporte (HIGH)
- **Archivo**: [lib/features/legal/data/legal_content.dart:42](lib/features/legal/data/legal_content.dart#L42)
- **Severidad**: 🟠 **HIGH**
- **Descripción**: `const String _contactEmail = 'support@pushkaapp.com';` aparece en 20+ ubicaciones del texto legal en 4 idiomas. No se usa `contactEmail` del tenant. Además los textos legales son únicos por idioma pero genéricos a "Pushka" — no hay versión por tenant.
- **Impacto**: si el tenant tiene su propia política de privacidad o términos en `privacyPolicyUrl`/`termsUrl`, la app los ignora completamente y muestra los términos de Pushka. Posibles problemas legales/compliance para tenants con regulaciones locales.
- **Fix propuesto**:
  1. Si `tenant.privacyPolicyUrl` está set → mostrar pantalla con `WebView` o link externo al URL del tenant. Si no → mostrar `legal_content.dart` como fallback.
  2. Idem para `termsUrl`.
  3. Reemplazar `_contactEmail` por `tenant.contactEmail ?? 'support@pushkaapp.com'`.

### BUG-003 — Sidebar muestra menu de tenant_admin a tenant_collaborator (MEDIUM)
- **Archivo**: [src/components/layout/Sidebar.tsx:76](../../pushka_admin/src/components/layout/Sidebar.tsx#L76)
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: `const nav = [...(isSuperAdmin ? NAV_BASE_SUPER : NAV_BASE_TENANT), ...(isSuperAdmin ? NAV_SUPER_ADMIN : NAV_TENANT_ADMIN)]` — el ternario solo distingue super vs no-super. Un `tenant_collaborator` ve EXACTAMENTE el mismo menú que `tenant_admin`, incluido `/my-org`.
- **Impacto**: el colaborador puede entrar a `/my-org` y ver `BrandingEditor` (aunque el editor se gatea por `isTenantAdmin` adentro → no escribe) y `TeamSection` (donde `canManageMembers` también se gatea). UX confusa, el colaborador ve secciones que no puede usar.
- **Fix propuesto**: agregar `NAV_TENANT_COLLABORATOR` que excluya `/my-org`, o usar `role` directamente para dividir tres ramas.

### BUG-004 — `welcomeText`, `showPoweredBy`, `defaultLanguage` se escriben pero no se aplican (MEDIUM)
- **Archivos**: `BrandingEditor.tsx` los expone como editables; `tenant_config.dart` los deserializa; **ningún archivo de presentation los renderiza/aplica**.
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: el admin puede editar `welcomeText` ("Mensaje de bienvenida") y `showPoweredBy` y `defaultLanguage` y guardar — pero la app no lo refleja porque ningún widget consume estos valores.
- **Impacto**:
  - `welcomeText`: UX rota — el tenant cree que está personalizando el splash/onboarding pero el cambio no aparece nunca.
  - `showPoweredBy`: viola white-label intent — si un tenant paga por quitarlo, no se quita.
  - `defaultLanguage`: el tenant ajusta default ES → FR pero el user nuevo arranca en español de todas formas (probablemente toma del locale del device).
- **Fix propuesto** (Fase 2 — sync):
  1. Renderizar `welcomeText` en el splash o en una banner del home.
  2. Implementar footer "Powered by Pushka" controlado por `showPoweredBy`.
  3. Al joinar tenant: si el user no tiene `language` explícito, setearlo a `tenant.defaultLanguage`.

### BUG-005 — `contactPhone`, `city`, `country` escritos sin uso (LOW)
- **Severidad**: 🟢 **LOW**
- **Descripción**: campos del editor que ni `support_screen` ni ningún otro renderiza.
- **Fix propuesto**: o agregarlos a `support_screen` rediseñado en BUG-001, o removerlos del `BrandingEditor`.

### BUG-006 — Duplicated `updateTenant` write paths (LOW)
- **Archivos**: `FinanzasPage.tsx:354` escribe `{ commissionRate }`, `TenantDetailPage.tsx:213` también escribe `commissionRate` (entre otros).
- **Severidad**: 🟢 **LOW**
- **Descripción**: dos UIs editan el mismo campo. No es un bug funcional pero potencial race si un super_admin tiene FinanzasPage en una tab y TenantDetailPage en otra.
- **Fix propuesto**: aceptable como está (super_admin único agente humano). Documentar.

---

## 4. CFs no llamadas por admin web (posibles huérfanas o user-only)

| CF | Origen esperado | Estado |
|---|---|---|
| `sendTestNotification` | Flutter (Settings) | OK user-side |
| `createPaymentIntent` | Flutter (donación) | OK user-side |
| `releaseManualPushkaEmptyLock` | Flutter | OK |
| `createDonationSubscription`, `listDonationSubscriptions`, `cancelDonationSubscription` | Flutter | OK |
| `createSetupIntent`, `listSavedCards`, `setPaymentMethodNickname`, `deletePaymentMethod`, `setDefaultPaymentMethod` | Flutter | OK |
| `deleteAccount`, `exportUserData` | Flutter (Settings) | OK |
| `joinTenant`, `switchTenant`, `leaveTenant` | Flutter | OK |
| `getTenantBySlug`, `listDiscoverableTenants`, `getTenantConfig` | Flutter | OK |
| `backfillDonationReasonsChabad` | one-off CLI | OK |
| `createTenantSubscription` | ❓ no se llama desde admin ni Flutter visible | ⚠️ verificar en Fase 4 si se llama server-side desde `createTenant` |

---

## 5. Resumen ejecutivo Fase 1

- Páginas: **14 usadas, 0 obsoletas**. SettingsPage es delgada pero útil.
- BrandingEditor: **8 campos write-only + 2 dead-weight = 10/16 campos sin efecto en la app**. Esto representa más de la mitad del editor sin impacto real.
- **2 hardcodes críticos** en Flutter (`support_screen` y `legal_content`) que violan el modelo multi-tenant.
- **1 bug de UX** en Sidebar (tenant_collaborator ve menú de admin).

**Bugs**: 1 CRITICAL, 1 HIGH, 2 MEDIUM, 2 LOW.

**Decisión recomendada para Ioel** (no implementar todavía):
- **Antes de invitar al primer rab**: arreglar BUG-001 y BUG-002 (sí o sí — el rab le pasaría la app a un donante de Jabad en Campus y vería el email de Jabad en Campus, lo cual está ok para ESE tenant, pero los textos legales y el branding hardcoded sí rompen).
- Esperar antes de implementar BUG-004 hasta validar si efectivamente vamos a usar esas funciones de white-label.
- BUG-003 y BUG-005 son nice-to-have.

---

Continúo a **Fase 2 — Sync admin ↔ app**.
