# Auditoría Round 4 — Fase 9: Tests

Fecha: 2026-05-11

---

## Estado actual de la cobertura

### Flutter app (`pushka_app/test/`, `integration_test/`)

✅ **Suite existente moderada**:
- `test/widget_test.dart` — smoke test base
- `integration_test/app_test.dart` — e2e flow
- `integration_test/app_navigation_test.dart` — navegación
- `test/services/biometric_service_test.dart` — biometría
- `test/services/transaction_repository_test.dart`
- `test/services/transaction_repository_fake_test.dart` — con FakeFirebaseFirestore probably
- `test/services/user_repository_fake_test.dart`
- `test/unit/cloud_functions_logic_test.dart` — lógica esperada de CFs
- `test/unit/race_condition_test.dart`
- `test/unit/currency_logic_test.dart` — formato monedas
- `test/unit/reminder_test.dart`
- `test/unit/stripe_config_test.dart`
- `test/unit/transaction_test.dart`
- `test/unit/payment_logic_test.dart`
- `test/unit/input_validation_test.dart`
- `test/unit/format_utils_test.dart`
- `test/unit/firestore_rules_test.dart` — solo documenta intent, NO ejecuta contra emulator
- `test/unit/security_audit_test.dart`

**Cobertura cualitativa**: razonable para lógica pura. **Faltan**:
- Widget tests de pantallas críticas (login, donate, settings)
- Tests con golden files para regresión visual
- Tests de RTL (Hebrew)

### Cloud Functions (`pushka_app/functions/test/`)

❌ **CERO tests propios**. La carpeta no existe; el grep solo encontró tests dentro de `node_modules/`.

### Admin web (`pushka_admin/`)

❌ **CERO tests propios**. Las únicas referencias son de `node_modules/zod`.

### Firestore Rules (emulator)

❌ Tests no ejecutados — el `firestore_rules_test.dart` solo documenta intent en Dart, sin usar `@firebase/rules-unit-testing`.

---

## Plan de tests propuesto (cientos/miles de casos)

### Fase 9.1 — Cloud Functions (server-side, Jest)

**Setup**:
1. Crear `functions/test/` con `jest.config.js`
2. Mock Firestore con `firebase-functions-test` + `firebase-admin` con `initializeApp()` en modo online-only para emulator
3. Mock Stripe con `stripe-mock` o stubs manuales

**Tests sugeridos** (uno por CF, con happy + edge cases):

| CF | Casos mínimos |
|---|---|
| `createPaymentIntent` | happy path; auth fail; AppCheck fail; rate limit; tenant suspended; tenant Connect not active; amount < min; amount > max; invalid currency; pushka_empty lock race; correlationId reused |
| `createSetupIntent` | happy; cross-currency get-or-create; race condition on customer create |
| `createDonationSubscription` | happy; cancel; recurring metadata correcto |
| `bootstrapSuperAdmin` | email correcto; email incorrecto; idempotencia |
| `setAdminClaim` | super_admin assigns super; super_admin assigns tenant_admin; tenant_admin assigns collab; tenant_admin can't assign super; revoke super (= BUG-035); pending invitation; revoke pending |
| `claimPendingTenantAdmin` | pending exists; pending doesn't exist; expired pending |
| `joinTenant` | first tenant; second tenant; already member; tenant suspended; tenant trial OK |
| `switchTenant` | valid; non-member denied |
| `leaveTenant` | last tenant; not-last tenant; not member |
| `createTenant` | full; minimal; duplicate slug; invalid commissionRate; super_admin only |
| `updateTenant` | super edits all; tenant_admin edits branding only; tenant_admin can't edit commissionRate; slug change atomic; adminEmail change resolves uid |
| `deleteTenant` | full sweep; tenants with 0/1/many users; legacy single-tenantId sweep |
| `stripeWebhook` | each event type (succeeded, failed, refunded, dispute opened/closed/won/lost/funds, account.updated, application_fee.*, invoice.*); signature invalid; idempotency duplicate; tenantId missing in metadata; drift detection |
| `stripeBillingWebhook` | invoice.payment_succeeded; invoice.payment_failed (30d grace, emails) |
| `handleStripeConnectOAuth` | success; denied error; expired state; unknown state |
| `createStripeConnectLink` | super for any; tenant_admin own; tenant_admin other tenant denied |
| `createTenantSubscription` | first time; idempotent retry |
| `cancelTenantSubscription` | success; no sub |
| `checkGracePeriods` | reminder days 30/20/10/5; suspension when expired; dedup same day |
| `deleteAccount` | full sweep; Stripe failure non-blocking; recent auth required |
| `exportUserData` | full export |
| `backfillTenantSlugs` | new tenant; existing lock conflict |

**Total estimado de tests CF**: ~200-300 tests.

### Fase 9.2 — Firestore Rules (emulator)

**Setup**: `npm install @firebase/rules-unit-testing` + crear `functions/test/rules/`. Iniciar emulator con `firebase emulators:start --only firestore`.

**Estrategia**: por cada colección y cada operación, probar 6 actores:
- super_admin (claims `{role: 'super_admin', admin: true}`)
- tenant_admin propio (mismo tenantId)
- tenant_admin de otro tenant
- tenant_collaborator propio
- usuario donante
- anónimo (no auth)

Por cada actor: probar `read`, `create`, `update`, `delete`. Esto genera 6 actores × 4 ops × ~10 colecciones = **240 tests base**, más combinaciones con `affectedKeys` checks (StripeFields, isBlocked, tenantId, tenantIds, etc.) → estimado **400-500 tests** completos.

### Fase 9.3 — Flutter widget + integration

**Agregar**:
- `test/widgets/donation_flow_test.dart` — abrir donate sheet, ingresar monto, validar
- `test/widgets/login_test.dart` — Google + Email flows
- `test/widgets/settings_test.dart` — toggles, currency change
- `test/widgets/tenant_switch_test.dart` — account switcher
- `test/widgets/legal_test.dart` — privacy + terms
- Goldens para `pushka_3d_widget`, `building_770_widget`, key states

**Estimado**: +50 widget tests, +5 e2e flows.

### Fase 9.4 — Admin web (React + Vitest)

**Setup**: `npm install -D vitest @testing-library/react @testing-library/user-event jsdom`.

**Tests sugeridos**:
- `AuthContext`: bootstrapSuperAdmin side-door, claimPendingTenantAdmin, session expiry
- `TenantsPage`: list, search, backfill slugs button
- `TenantDetailPage`: edit branding, edit financial fields, delete confirm modal (ELIMINAR/DELETE/SUPPRIMER)
- `TenantCreatePage`: validation, success
- `MyOrganizationPage`: branding editor (only for tenant_admin), team section
- `AdminsPage`: list, add, revoke
- `BrandingEditor`: hex validation, donation reasons add/remove
- `TeamSection`: member management, first admin protection
- `useUsers`, `useAdminStats`, `useFailedPayments` hooks

**Estimado**: +80 unit tests, +20 integration tests con MSW para mock CFs.

### Fase 9.5 — Stripe webhook fixtures

Capturar payloads reales de cada evento (en test mode) y guardarlos en `functions/test/fixtures/stripe/`. Firmarlos con `whsec_test` y pasarlos al handler como POST body. Verificar resultados Firestore.

**Estimado**: 15 archivos fixture × 2-3 test cases cada uno = ~40 tests.

---

## Total estimado de la suite

| Categoría | # tests aprox |
|---|---|
| Cloud Functions unit | 250 |
| Firestore Rules emulator | 450 |
| Flutter widgets | 50 |
| Flutter integration | 5 |
| Admin web unit | 80 |
| Admin web integration | 20 |
| Stripe webhook fixtures | 40 |
| **TOTAL** | **~895 tests** |

Cumplir el "miles de tests" requeriría exhaustividad en cada combinación (cross-product). Para Pushka, **~900 tests bien escritos cubren mejor que 10000 tests redundantes**.

---

## Implementación recomendada (priorización)

**Por valor agregado**:

1. **Firestore Rules tests** (450) — protege contra regresiones de seguridad. ALTA prioridad pre-launch. ~1 semana de dev.
2. **Cloud Functions unit tests** (250) — protege contra regresiones de lógica de pago. ALTA prioridad. ~1 semana.
3. **Stripe webhook fixtures** (40) — alta confianza en el flujo de dinero. MEDIA. ~2 días.
4. **Admin web unit** (80) — protege UI critical (auth, tenant CRUD). MEDIA. ~3 días.
5. **Flutter widget tests** (50) — visual regressions. BAJA (manual QA cubre). ~3 días.

**Total estimado dev**: 3 semanas full-time.

---

## Esqueleto creado: 1 archivo de ejemplo

He creado un archivo skeleton en `functions/test/createPaymentIntent.test.js` (siguiente sección).

NO ejecuté tests — pide a Ioel que corra `cd functions && npm test` cuando estés listo.

---

## Bug en cobertura existente

#### BUG-070 — `firestore_rules_test.dart` documenta intent pero no ejecuta rules
- **Archivo**: [test/unit/firestore_rules_test.dart](test/unit/firestore_rules_test.dart)
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: el archivo verifica que listas de campos coincidan entre Flutter code y firestore rules, pero no usa emulator + `@firebase/rules-unit-testing`. Una rule mal redactada (ej. `allow read: if true;`) no se detecta.
- **Fix propuesto**: migrar a tests con emulator (Fase 9.2 propuesta).

---

## Tabla resumen Fase 9

| ID | Severidad | Título | Bloquea launch? |
|---|---|---|---|
| BUG-070 | 🟡 MEDIUM | Tests de rules no usan emulator | No (pero protección débil) |

**Resumen**: tests presentes en Flutter (parcial), AUSENTES en CFs y admin. Plan de 900 tests propuesto, ~3 semanas de dev.

---

Continúo a **Fase 10 — Síntesis y plan**.
