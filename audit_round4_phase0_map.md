# Auditoría Round 4 — Fase 0: Mapeo del sistema

Fecha: 2026-05-11
Branch: `dev`

Este documento es el mapa de referencia que usan las fases siguientes. Sin bugs todavía; solo descripción de qué existe.

---

## 1. Admin web — páginas y rutas

Repo: [c:/dev/pushka_admin/src/](../../pushka_admin/src/)

### Rutas (desde `App.tsx`)

| Path | Componente | Acceso (router) |
|---|---|---|
| `/login` | LoginPage | público |
| `/` (index) | DashboardPage | RequireAdmin (cualquier rol con acceso) |
| `/crm` | CRMPage | RequireAdmin |
| `/transactions` | TransactionsPage | RequireAdmin |
| `/overview` | OverviewPage | RequireAdmin |
| `/users/:uid/history` | UserHistoryPage | RequireAdmin |
| `/activity` | ActivityPage | RequireAdmin |
| `/admins` | AdminsPage | RequireAdmin |
| `/settings` | SettingsPage | RequireAdmin |
| `/tenants` | TenantsPage | RequireAdmin |
| `/tenants/new` | TenantCreatePage | RequireAdmin |
| `/tenants/:tenantId` | TenantDetailPage | RequireAdmin |
| `/my-org` | MyOrganizationPage | RequireAdmin |
| `/finanzas` | FinanzasPage | RequireAdmin |
| `*` | Navigate to `/` | — |

⚠️ **Nota**: `RequireAdmin` solo verifica que hay claim de acceso — el filtrado por rol específico (super_admin vs tenant_admin) sucede DENTRO de cada página o en el `Sidebar`. Esto significa que un tenant_admin podría intentar navegar manualmente a `/tenants` (super_admin-only) y ver lo que la página decida mostrar. Validar en Fase 5.

### Nav links visibles por rol (desde `Sidebar.tsx`)

| Rol | Rutas visibles en el menú |
|---|---|
| super_admin | `/`, `/crm`, `/overview`, `/activity`, `/finanzas`, `/tenants`, `/admins`, `/settings` |
| tenant_admin | `/`, `/crm`, `/transactions`, `/overview`, `/my-org`, `/settings` |
| tenant_collaborator | **idéntico a tenant_admin** ← potencial bug (Sidebar solo distingue super vs no-super) |

### Componentes compartidos

| Path | Propósito |
|---|---|
| `components/layout/AppLayout.tsx` | shell con Sidebar + TopBar + Outlet |
| `components/layout/Sidebar.tsx` | nav lateral desktop |
| `components/layout/MobileNav.tsx` | nav móvil |
| `components/layout/BottomNav.tsx` | nav inferior móvil |
| `components/layout/TopBar.tsx` | barra superior |
| `components/layout/RequireAdmin.tsx` | guard de auth/role |
| `components/ui/ConfirmModal.tsx` | modal de confirmación reutilizable |
| `components/ui/StatCard.tsx` | tarjeta de KPI |
| `components/tenant/BrandingEditor.tsx` | editor de branding (color, logo, nombre) |
| `components/tenant/TeamSection.tsx` | gestión de equipo de un tenant |
| `components/crm/UserDrawer.tsx` | drawer lateral con detalle de usuario CRM |
| `contexts/AuthContext.tsx` | provider de auth + claims + side-doors super_admin |
| `contexts/ThemeContext.tsx` | dark/light mode |
| `contexts/LanguageContext.tsx` | i18n (ES/EN/FR/HE) |

---

## 2. Flutter app — pantallas/features

Repo: [c:/dev/pushka_app/lib/features/](lib/features/)

### Features y archivos clave (no exhaustivo — solo presentation)

| Feature | Pantalla principal | Otros archivos clave |
|---|---|---|
| **splash** | `splash_screen.dart` | — |
| **onboarding** | `onboarding_screen.dart` | — |
| **auth** | `login_screen.dart`, `register_screen.dart` | `auth_controller.dart`, `auth_state_provider.dart`, `biometric_service.dart` |
| **shell** | `app_shell.dart` (bottom nav), `app_drawer.dart` | — |
| **pushka** | `pushka_screen.dart` | `pushka_3d_widget.dart`, `pushka_3d_painter.dart`, `building_770_widget.dart`, `building_770_painter.dart`, `bill_fall_animation.dart`, `jewish_confetti.dart` |
| **wallet** | `wallet_screen.dart` | — |
| **history** | `history_screen.dart` | `transaction_repository.dart`, `donation_chart.dart`, `transactions_provider.dart`, `transaction.dart` (domain) |
| **payments** | `donation_subscriptions_screen.dart` | `stripe_service.dart`, `donation_reason_picker.dart` |
| **settings** | `settings_screen.dart` | `saved_cards_screen.dart`, `auto_empty_screen.dart`, `auto_empty_action_row.dart`, `card_brand_box.dart` |
| **reminders** | `reminders_screen.dart` | `reminder_repository.dart`, `reminders_provider.dart`, `reminder.dart` |
| **prayers** | `prayers_screen.dart` | — |
| **tenant** | `account_switcher_sheet.dart`, `join_via_link_screen.dart`, `tenant_code_screen.dart`, `tenant_suspended_screen.dart` | `tenant_repository.dart`, `tenant_theme_provider.dart`, `tenant_config.dart` (domain), `tenant_summary.dart` (domain) |
| **users** | — | `user_repository.dart`, `user_profile_provider.dart` (incluye upload Storage de foto perfil) |
| **legal** | `legal_screen.dart` | `legal_content.dart` (textos in-app de privacidad y términos) |
| **about** | `about_screen.dart` | — |
| **support** | `support_screen.dart` | — |
| **deep_links** | — | `deep_link_service.dart` |
| **notifications** | — | `notification_service.dart` (FCM + tokens) |
| **analytics** | — | `analytics_service.dart` |
| **feedback** | — | `feedback_service.dart` |

---

## 3. Cloud Functions exportadas

Archivo: [functions/index.js](functions/index.js)

### Callables (`onCall`) — 38 funciones

| Función | Línea | Propósito breve |
|---|---|---|
| `sendTestNotification` | 536 | enviar push de prueba a sí mismo |
| `createPaymentIntent` | 564 | crear PI Stripe (donación) |
| `releaseManualPushkaEmptyLock` | 1145 | liberar lock de "vaciar pushka" manual |
| `createDonationSubscription` | 1203 | suscripción de donación recurrente (Stripe) |
| `listDonationSubscriptions` | 1608 | listar suscripciones de donación del usuario |
| `cancelDonationSubscription` | 1674 | cancelar suscripción de donación |
| `createSetupIntent` | 1729 | guardar método de pago (Stripe SetupIntent) |
| `listSavedCards` | 1835 | listar métodos guardados |
| `setPaymentMethodNickname` | 1975 | renombrar tarjeta guardada |
| `deletePaymentMethod` | 2015 | borrar PM guardado |
| `setDefaultPaymentMethod` | 2168 | marcar PM por defecto |
| `bootstrapSuperAdmin` | 4232 | side-door super_admin (idempotente) |
| `claimPendingTenantAdmin` | 4284 | aplicar invitación pendiente al sign-in |
| `setAdminClaim` | 4397 | super_admin asigna role/claims a un usuario |
| `listAdmins` | 4589 | listar admins (scope tenant si tenant_admin) |
| `getAdminStats` | 4678 | KPIs del dashboard |
| `getRecentTransactions` | 4900 | transacciones recientes |
| `getFailedPayments` | 5007 | pagos fallidos (de webhook events) |
| `setUserBlocked` | 5085 | block/unblock usuario |
| `deleteAccount` | 5173 | borrar cuenta del usuario callee |
| `exportUserData` | 5348 | GDPR export |
| `joinTenant` | 5436 | usuario se une a tenant por slug/code |
| `switchTenant` | 5554 | usuario alterna entre tenants en los que está |
| `leaveTenant` | 5589 | usuario abandona tenant |
| `createTenant` | 5693 | super_admin crea tenant |
| `backfillTenantSlugs` | 5955 | one-off, escribe `_tenantSlugs` para tenants legacy |
| `backfillDonationReasonsChabad` | 6047 | one-off, default reasons Colel Chabad |
| `getTenantBranding` | 6082 | branding de un tenant (público con AppCheck) |
| `updateTenant` | 6123 | super_admin edita tenant (incluye slug move, adminEmail reassign) |
| `getTenantBySlug` | 6294 | lookup tenant por slug |
| `listDiscoverableTenants` | 6345 | tenants visibles en el "explorar" |
| `getTenantConfig` | 6393 | config + escritura `tenantState` denormalizado |
| `listTenants` | 6539 | super_admin lista todos (incluye orphan sweep) |
| `getSuperAdminDashboard` | 6621 | dashboard super_admin |
| `createStripeConnectLink` | 6689 | onboarding Stripe Connect del tenant |
| `createTenantSubscription` | 6944 | crear sub mensual SaaS del tenant |
| `cancelTenantSubscription` | 7044 | cancelar sub SaaS |
| `deleteTenant` | 7106 | super_admin elimina tenant (Stripe + Firestore sweep) |
| `resolveActivityItem` | 7575 | super_admin marca activity item como resuelto |

### HTTP Endpoints (`onRequest`) — 4 funciones

| Función | Línea | Propósito |
|---|---|---|
| `stripeWebhook` | 2223 | webhook donaciones + Connect |
| `handleStripeConnectOAuth` | 6749 | callback OAuth Stripe Connect del tenant |
| `stripeBillingWebhook` | 7286 | webhook suscripciones SaaS |
| `assetlinks` | 7544 | `.well-known/assetlinks.json` para App Links Android |

### Firestore Triggers — 2 funciones

| Función | Línea | Trigger | Propósito |
|---|---|---|---|
| `onTransactionCreated` | 3005 | `onDocumentCreated('users/{uid}/transactions/{tid}')` | actualiza `_monthlyActive`, sync streak |
| `onTenantBrandingUpdated` | 3307 | `onDocumentUpdated('tenants/{tenantId}')` | fan-out branding a `tenantState` de miembros |

### Schedulers (`onSchedule`) — 8 cron jobs

| Función | Línea | Propósito |
|---|---|---|
| `cleanupStaleFcmTokens` | 3123 | borrar tokens FCM viejos |
| `resetMonthlyActiveUsers` | 3156 | resetear contador MAU por tenant |
| `cleanupIncompleteDonationSubscriptions` | 3218 | borrar subs Stripe que quedaron `incomplete` |
| `cleanupOldStripeWebhookEvents` | 3267 | TTL de `_stripeWebhookEvents` |
| `monitorStripeWebhookHealth` | 3363 | alerta si webhook no recibió eventos en N horas |
| `monitorStripeWebhookStuckEvents` | 3389 | alerta si hay eventos en estado pending viejo |
| `processPushkaAutoEmpty` | 4030 | cron que ejecuta donaciones automáticas |
| `checkGracePeriods` | 7453 | revisa tenants en `past_due` y aplica suspensión |

**Total: 52 funciones exportadas**.

---

## 4. Colecciones Firestore

### Top-level

| Colección | Propósito | Acceso (resumen rules) |
|---|---|---|
| `tenants/{tenantId}` | organizaciones | read: admin o miembro propio; write: server-only |
| `tenants/{tenantId}/team/{uid}` | equipo del tenant | sin match → default-deny (server-only via CFs) |
| `users/{uid}` | perfil del usuario donante | read: owner/admin/tenant-member; create/update: owner con validUserDoc; delete: false |
| `users/{uid}/tenantState/{tenantStateId}` | pushka por tenant, streak, autoEmpty | read/create/update: owner; delete: false |
| `users/{uid}/transactions/{txId}` | historial de donaciones | read: owner/admin/tenant-member; create: owner; update/delete: false |
| `users/{uid}/reminders/{rid}` | recordatorios push | read/CRUD: owner |
| `users/{uid}/fcmTokens/{tokenId}` | tokens FCM | read/CRUD: owner |
| `users/{uid}/paymentEvents/{eventId}` | log de eventos Stripe por usuario | read: owner; write: server-only |
| `adminData/{uid}` | estado moderación por usuario | read: owner/admin; write: admin (super_admin) |
| `adminConfig/{document}` | config admin | read/write: admin |
| `_activityLog/{docId}` | feed de actividad super_admin | read/write: admin |
| `_rateLimits/**` | rate limiting por uid+action | server-only |
| `_exchangeRates/**` | cache FX | server-only |
| `_tenantSlugs/{slug}` | lock único de slug → tenantId | server-only |
| `_stripeWebhookEvents/**` | idempotencia webhook | server-only |
| `_monthlyActive/**` | MAU por tenant | server-only |
| `_backfillRuns/**` | sentinel de backfills one-off | server-only |
| `_appConfig/**` | config singleton (e.g., `stripe`) | server-only |
| `_pendingTenantAdmins/{email}` | invitaciones tenant_admin sin Auth aún | server-only |

---

## 5. Storage paths

Archivo: [storage.rules](storage.rules)

| Path | Reglas |
|---|---|
| `/profile_photos/{fileName}` | read: cualquier auth; write: solo si `fileName == auth.uid + '.jpg'`, < 5MB, content-type image/* |
| Cualquier otro path | default-deny |

⚠️ **Observaciones**:
- Las fotos de perfil tienen download URLs firmadas (token-based) — la regla de read es laxa pero el URL público es lo que se comparte.
- **No hay reglas para logos de tenant** — ¿se almacenan en Storage o en URLs externas? El campo `tenants.logoUrl` puede ser URL externa (Cloudinary, etc.). Validar en Fase 2.

---

## 6. Mapa de roles → permisos (Firestore Rules)

Helpers definidos en `firestore.rules`:
- `isSignedIn()` — auth presente
- `isOwner(uid)` — auth.uid == uid
- `isAdmin()` — `claims.admin == true` || `claims.role == 'super_admin'`
- `isSuperAdmin()` — `claims.role == 'super_admin'`
- `isTenantAdmin()` — `claims.role == 'tenant_admin'`
- `isTenantCollaborator()` — `claims.role == 'tenant_collaborator'`
- `isTenantMember()` — tenant_admin OR tenant_collaborator
- `callerTenantId()` — `claims.tenantId`

### Resumen por colección

| Colección | super_admin | tenant_admin/collab (propio) | tenant_admin/collab (otro) | usuario donante | anónimo |
|---|---|---|---|---|---|
| `tenants/{id}` | R | R (solo el propio) | ❌ | ❌ | ❌ |
| `tenants/{id}/team/{uid}` | server-only (CF) | server-only (CF) | server-only | server-only | ❌ |
| `users/{uid}` (otro user del mismo tenant) | R | R (si user.tenantIds incluye el tenant del caller) | ❌ | ❌ | ❌ |
| `users/{uid}` (propio) | RW | RW | n/a | RW | n/a |
| `users/{uid}/tenantState/{tsId}` | ❌ (no match para admin) | ❌ | ❌ | RW (propio) | ❌ |
| `users/{uid}/transactions/{tid}` | R | R (si tenant del caller) | ❌ | RW (propio create) | ❌ |
| `users/{uid}/reminders` | ❌ | ❌ | ❌ | RW (propio) | ❌ |
| `users/{uid}/fcmTokens` | ❌ | ❌ | ❌ | RW (propio) | ❌ |
| `users/{uid}/paymentEvents` | ❌ | ❌ | ❌ | R (propio) | ❌ |
| `adminData/{uid}` | RW | ❌ (cross-tenant moderation leak fixed) | ❌ | R (propio) | ❌ |
| `adminConfig` | RW | ❌ | ❌ | ❌ | ❌ |
| `_activityLog` | RW | ❌ | ❌ | ❌ | ❌ |
| `_rateLimits` y otras `_*` (excepto `_activityLog`) | server-only | server-only | server-only | server-only | ❌ |

⚠️ **Observación A**: `tenantState`, `reminders`, `fcmTokens`, `paymentEvents` no tienen branch para `isAdmin()`. Esto significa que un super_admin **no puede leer** estos datos vía Firestore directo — debe ir vía CFs. Por diseño parece correcto (datos personales del usuario), pero validar en Fase 5 que las CFs de admin (e.g., `getRecentTransactions`, `UserHistoryPage`) usan Admin SDK y no client-side.

⚠️ **Observación B**: `tenant_admin` puede leer otros `users` del mismo tenant pero **no** puede leer sus `tenantState`/subcollections. Esto significa que el CRM web (`/crm`) tampoco puede leer pushkaAmount/streak directo — debe ir vía CF. Validar en Fase 1/2.

---

## 7. Dependencias entre módulos / flujos

### Flujo "super_admin cambia branding de Tenant A"
1. Admin web → `updateTenant({ tenantId, primaryColor: '#abc' })` (CF)
2. CF valida claims + escribe `tenants/{tenantId}` via Admin SDK
3. `onTenantBrandingUpdated` trigger se dispara
4. Trigger lee miembros del tenant (`users.where(tenantIds array-contains tenantId)` — o similar)
5. Para cada miembro, escribe los campos denormalizados en `users/{uid}/tenantState/{tenantId}`: `tenantName`, `tenantAppName`, `tenantLogoUrl`, `tenantPrimaryColor`
6. Flutter app del usuario tiene listener en `tenantState/{currentTenantId}` → recibe cambio → `tenant_theme_provider` actualiza Material theme

### Flujo "donación exitosa"
1. Flutter → `createPaymentIntent({ amount, currency, tenantId, reason })` → CF crea PI Stripe con `transfer_data.destination` (Connect del tenant) + `application_fee_amount` (comisión plataforma)
2. Flutter llama `confirmPayment` (Stripe SDK) → user paga
3. Stripe → `stripeWebhook` HTTP → CF valida firma → idempotencia vía `_stripeWebhookEvents/{eventId}`
4. CF escribe `users/{uid}/transactions/{paymentIntentId}` con `tenantId`, `amount`, `fee`, etc.
5. Trigger `onTransactionCreated` se dispara → MAU + sync pushkaAmount en `tenantState`
6. Flutter `transactions_provider` (snapshot listener) recibe la nueva transacción → UI se actualiza

### Flujo "tenant_admin invita colaborador que no tiene cuenta"
1. Admin web → `setAdminClaim({ email, role: 'tenant_admin' })` (CF)
2. CF: si Auth user existe, asigna claim + entrada en `tenants/{tid}/team/{uid}`
3. CF: si NO existe Auth user, escribe `_pendingTenantAdmins/{normalizedEmail}` con `{ tenantId, role }`
4. Cuando el invitado eventualmente hace login: `AuthContext.ensureClaimsAfterAuth` llama `claimPendingTenantAdmin` (CF)
5. CF busca `_pendingTenantAdmins/{auth.email}` → aplica claim + escribe team subcollection → borra pending doc

### Flujo "suscripción SaaS del tenant"
1. Admin web → `createTenantSubscription({ tenantId, priceId })` (CF) cuando se crea el tenant
2. CF crea Stripe customer + subscription para el tenant_admin
3. Stripe Billing → `stripeBillingWebhook` HTTP → CF actualiza `tenants/{tid}.subscriptionStatus`
4. `checkGracePeriods` cron diario revisa tenants en `past_due` → si grace expirado, marca `suspended`
5. Cuando el tenant está suspendido, Flutter app muestra `tenant_suspended_screen.dart`

---

## 8. Resumen de superficie de ataque/test

| Superficie | # endpoints/objetos | Notas |
|---|---|---|
| Callable CFs | 38 | cada una debe validar `auth`, `claims`, `data`, AppCheck |
| HTTP CFs | 4 | webhooks deben validar firma; assetlinks es público |
| Triggers Firestore | 2 | escriben con Admin SDK (bypass rules), deben ser idempotentes |
| Schedulers | 8 | sin auth callable; deben verificar invariantes |
| Colecciones Firestore | 19 (incluyendo subcollections) | con rules específicas |
| Storage paths | 1 + default-deny | profile_photos |
| Admin web routes | 14 | filtrado por rol mezclado en Router/Sidebar/páginas |
| Flutter screens | ~25 | algunas dependientes de tenant context |
| Idiomas | 4 (ES/EN/FR/HE) | HE es RTL |

---

## Próximo paso

Esperando luz verde de Ioel para arrancar **Fase 1 — Limpieza admin web**.
