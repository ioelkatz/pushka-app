# Auditoría Exhaustiva Pre-Launch Pushka — Round 4

> **Cómo usar este prompt:** copialo entero y pegalo en una sesión nueva de Claude Code,
> sin contexto previo. Está diseñado para ser autocontenido.

---

## Contexto del proyecto

**Pushka** es una app SaaS multi-tenant de donaciones tzedaka (caridad judía).
Está al ~95% lista para Play Store y App Store. El próximo paso es invitar al primer
cliente real (rab Jabad en Campus Mexico — `jymmexico@gmail.com`) y abrir donaciones
a usuarios finales.

### Arquitectura
- **Flutter app** (tenant-facing, multi-idioma ES/EN/FR/HE): `c:/dev/pushka_app/`
- **React + Vite admin web** (super_admin + tenant_admin): `c:/dev/pushka_admin/`
- **Hosting admin**: `pushka-admin.web.app` (prod) y `pushka-admin-test.web.app` (dev)
- **Firebase**: Auth (custom claims), Firestore, Storage, Cloud Functions v2, App Check, Crashlytics
- **Stripe Connect**: routea donaciones al Stripe del tenant + comisión de plataforma al Stripe principal de Ioel
- **Stripe Subscriptions**: mensualidad SaaS cobrada al tenant_admin
- **Dos entornos separados**: `pushka-app-ioel` (prod) y `pushka-app-ioel-test` (dev/test)
- **Branding por tenant**: cada tenant puede personalizar `appName`, `logoUrl`, `primaryColor`, etc., y la app del usuario final debe reflejar esos cambios en vivo

### Roles del sistema
- `super_admin` → Ioel (email `ioelkatz@gmail.com`). Gestiona TODOS los tenants
- `tenant_admin` → dueño de la organización (ej. el rab). Gestiona SOLO su tenant
- `tenant_collaborator` → equipo del tenant. Permisos limitados
- Usuario final → donante. Sin rol explícito, scope a su tenant

### Convenciones del repo
- Branch protegido: `dev`. Trabajar en feature branches y abrir PRs squash-merge
- Secrets: `printf '<value>' | firebase functions:secrets:set NAME --data-file -` (NUNCA `echo` — agrega `\n`)
- Build dev: `flutter run --flavor dev --dart-define=ENV=dev --dart-define=STRIPE_PUBLISHABLE_KEY=...`
- Deploy CF prod: `firebase deploy --only functions --project pushka-app-ioel`
- Existe `CLAUDE.md` en raíz con convenciones — leerlo primero

---

## Reglas de oro durante la auditoría

1. **NO commits, NO pushes, NO deploys** sin que Ioel los pida explícitamente.
2. **NO borrar archivos ni código** sin confirmación explícita.
3. **NO modificar `package.json`, `pubspec.yaml`, `firebase.json`, `firestore.rules`** sin confirmación.
4. **NO hacer migraciones de Firestore ni mover datos** sin confirmación.
5. **SÍ leer todo el código que necesites** — la auditoría requiere lectura exhaustiva.
6. Al terminar cada fase, presentar **reporte estructurado** con:
   - Bug ID (BUG-001, BUG-002, …)
   - Severidad: `CRITICAL` (bloquea launch) / `HIGH` (degrada UX) / `MEDIUM` / `LOW`
   - Archivo:línea
   - Descripción + reproducción
   - Impacto
   - Fix propuesto (no implementarlo aún)
7. **Esperar luz verde de Ioel** antes de pasar a la siguiente fase.
8. **NO** asumir nada sobre el estado del código sin verificarlo leyéndolo.
9. **Idioma de los reportes**: español rioplatense.
10. Si encontrás algo que requiere decisión de diseño (no es bug, es trade-off), preguntá en vez de asumir.

---

## Fase 0 — Mapeo del sistema (read-only, sin reporte de bugs)

**Objetivo**: armar mental model completo antes de buscar bugs.

Deliverables:
1. Lista de TODAS las páginas/rutas del admin web (`pushka_admin/src/pages/**`) con una línea de descripción cada una.
2. Lista de TODAS las pantallas Flutter (`pushka_app/lib/features/**`) con una línea cada una.
3. Lista de TODAS las Cloud Functions exportadas en `pushka_app/functions/index.js` con: nombre, tipo (`onCall` / `onRequest` / `onSchedule` / trigger), una línea de propósito.
4. Lista de TODAS las colecciones Firestore que aparecen en el código (grep `.collection(` o `firestore().collection`).
5. Lista de TODOS los buckets/paths Firebase Storage referenciados.
6. Mapa de roles → permisos: para cada rol (super_admin / tenant_admin / tenant_collaborator / usuario), qué CFs puede llamar y qué colecciones Firestore puede tocar (read/write/update/delete).
7. Listar dependencias entre módulos: ej. "cuando se actualiza `tenants/{id}.primaryColor`, ¿qué trigger se dispara y qué actualiza?".

Salida: un único archivo markdown llamado `audit_round4_phase0_map.md` en la raíz del repo.

---

## Fase 1 — Limpieza del admin web (qué se usa y qué no)

**Objetivo**: identificar secciones del admin web que están de más, obsoletas o que duplican funcionalidad. Ioel sospecha que hay personalización que no se aplica nunca a la app.

Tareas:
1. Por cada página del admin web encontrada en Fase 0, verificar:
   - ¿La página existe en el `Router` actual? ¿Hay link al menos desde algún lado del UI?
   - ¿Las acciones que ofrece efectivamente persisten en Firestore?
   - ¿Esos campos se LEEN desde la Flutter app? (grep el nombre del campo en `pushka_app/lib/`)
   - Si el admin web escribe un campo pero la Flutter app no lo lee → **probable basura**.
2. Catalogar cada sección en una de estas categorías:
   - `USED` — funciona end-to-end (admin escribe → app lee → usuario lo ve)
   - `WRITE_ONLY` — admin escribe pero nada lo consume (basura candidata a eliminar)
   - `READ_ONLY` — admin solo muestra info sin acciones
   - `BROKEN` — visible en admin pero rota (campo no escribe, error 500, etc.)
   - `DUPLICATE` — misma función expuesta en 2+ lados del admin
3. Para super_admin vs tenant_admin: confirmar qué páginas ve cada rol. Si tenant_admin ve algo que es solo para super_admin (o viceversa), bug de permisos en frontend.

Reporte: tabla con todas las secciones + categoría + recomendación.

---

## Fase 2 — Sincronización Web Admin ↔ Flutter App

**Objetivo crítico**: validar que cada campo editable en el admin web efectivamente cambia el comportamiento o aspecto de la app del usuario final del tenant correspondiente, sin filtrar a otros tenants.

Para CADA uno de estos grupos de campos, validar el flujo completo (admin → Firestore → app):

### 2.1 Branding (tenant)
- `appName`, `tenantName`, `logoUrl`, `primaryColor`, `secondaryColor`, `accentColor`, fuente, banner de festividades.
- Verificar: ¿hay trigger Firestore (`onTenantBrandingUpdated` o similar) que actualice los `tenantState/{tenantId}` denormalizados? ¿Existe race condition? ¿Funciona offline?
- Probar mentalmente: tenant A cambia primaryColor → solo usuarios de tenant A ven el cambio, NUNCA usuarios de tenant B.

### 2.2 Settings de donaciones
- `donationReasons` (lista de causas), `presets` (montos predefinidos), `meta` (objetivo), `currency`, `paymentMethodsEnabled`, `minDonation`, `maxDonation`, `allowRecurring`, etc.
- Verificar persistencia y lectura desde Flutter. Ya hubo bugs históricos acá (ver `session_2026_05_03` en memoria — 3 bugs de Firestore rules).

### 2.3 Datos personales del tenant
- `adminEmail`, `contactPhone`, `address`, `website`, `taxId`, redes sociales, etc.
- Donde aparecen en la app del usuario (pantalla de soporte, about, footer): ¿están leyendo el dato correcto? ¿Se actualizan al cambiarlos?
- **Caso límite**: si super_admin cambia `adminEmail` de un tenant a un email distinto, ¿el `adminUid` se reasigna? ¿El tenant viejo pierde acceso? Verificar CF `updateTenant`.

### 2.4 Configuración de comisión de plataforma
- `platformFeePercent` o `platformFeeCents` (¿cómo se llama el campo? ¿está por tenant o global?).
- Si super_admin cambia el porcentaje del 5% al 7%: ¿se aplica a próxima donación? ¿O queda cacheado?
- Cobertura de monedas: ARS / USD / ILS / EUR / MXN / CLP / COP — la comisión debe calcularse en la moneda del tenant.

### 2.5 Suscripción mensual del tenant
- `subscriptionPriceMonthly`, `subscriptionStatus`, `subscriptionStripeId`, `subscriptionCurrentPeriodEnd`.
- Si super_admin cambia el precio de $50 → $100 → $150: ¿se aplica al próximo ciclo? ¿Cómo se llama la CF? ¿Proración?

Reporte por cada grupo: ¿hay sync correcto? ¿hay desfases? ¿hay campos que el admin escribe pero la app no lee (basura)? ¿hay campos que la app lee pero el admin no expone (impone valor hardcoded)?

---

## Fase 3 — Flujo de dinero (Stripe Connect)

**Objetivo crítico**: validar que cada peso/dólar donado:
1. Sale de la tarjeta del donante
2. Stripe debita el monto total
3. La comisión de plataforma (`application_fee_amount`) llega a la cuenta Stripe principal de Ioel
4. El resto llega al Stripe Connect del tenant (el rab)
5. Firestore registra la transacción correctamente con `amount`, `fee`, `net`, `currency`, `tenantId`, `userId`

Tareas:
1. Leer `functions/index.js` y mapear el flujo: `createPaymentIntent` (o equivalente) → ¿cómo pasa `application_fee_amount` y `transfer_data.destination`?
2. Validar uso de **idempotency keys** en todas las llamadas a Stripe (NO se debe poder crear 2 PaymentIntents para la misma intención del usuario).
3. Validar el `stripeWebhook` handler: ¿maneja TODOS los eventos relevantes? Lista mínima:
   - `payment_intent.succeeded`
   - `payment_intent.payment_failed`
   - `payment_intent.canceled`
   - `charge.refunded`
   - `charge.dispute.created`
   - `charge.dispute.closed`
   - `charge.dispute.funds_withdrawn`
   - `charge.dispute.funds_reinstated`
   - `account.updated` (cuenta Connect del tenant)
   - `application_fee.created`
   - `application_fee.refunded`
4. Verificar signature validation del webhook (`STRIPE_WEBHOOK_SECRET`).
5. Verificar que dispute notifications llegan al super_admin (no solo al tenant).
6. Verificar refund flow: si el tenant emite refund, ¿la comisión de plataforma también se refundea (application_fee.refunded)?
7. Edge cases:
   - Donación recurrente cuya tarjeta vence
   - Tenant cuya capability `card_payments` se desactiva mientras hay donaciones recurrentes activas
   - Donación con monto que con comisión deja al tenant con menos del mínimo de Stripe
   - Moneda del donante distinta a la del tenant (¿se permite? ¿hay conversión?)

Reporte: cada handler, cada gap encontrado, cada idempotency miss.

---

## Fase 4 — Suscripción mensual SaaS

**Objetivo**: validar el cobro mensual al tenant_admin (separado del Stripe Connect, que es para donaciones).

Tareas:
1. ¿Cómo se crea la suscripción? CF `createTenantSubscription` o similar.
2. ¿Cómo se cambia el precio? Si super_admin sube de $50 → $100, ¿es proración inmediata o se aplica al próximo ciclo?
3. ¿Qué pasa si el cobro mensual falla? ¿Hay grace period? ¿Se suspende el tenant? ¿Los donantes finales pueden seguir donando aunque el tenant esté `past_due`?
4. ¿Hay webhook handler para `customer.subscription.updated` y `customer.subscription.deleted`?
5. ¿Hay `invoice.payment_failed` handler? ¿Qué hace?
6. ¿Hay flujo de cancelación? CF `cancelTenantSubscription` deployada (ver memoria 2026-05-01) — ¿soft cancel o hard delete?
7. ¿Hay billing portal de Stripe para que el tenant_admin gestione su método de pago?
8. Documentar el estado actual del cobro mensual: ¿está activo, dormant, o no se cobra todavía?

Reporte: cómo se cobra HOY, cómo DEBERÍA cobrarse, gaps.

---

## Fase 5 — Seguridad (Firestore rules, CFs, claims)

**Objetivo**: cada operación debe estar correctamente protegida. Atacante objetivo: usuario malicioso con cuenta válida.

Tareas:
1. Leer `firestore.rules` completo. Para CADA colección documentar:
   - Quién puede `read`
   - Quién puede `create`
   - Quién puede `update` (y qué campos puede tocar — usar `affectedKeys()`)
   - Quién puede `delete`
2. Verificar que NO existan rules tipo `allow read, write: if request.auth != null;` sin más check (autenticado ≠ autorizado).
3. Para cada CF `onCall`, verificar:
   - `enforceAppCheck: true` (excepto si hay razón documentada)
   - Validación de `auth` y `claims`
   - Validación de `data` (tipos, longitudes, sanitización)
   - Rate limiting si aplica
4. Verificar boundaries entre tenants:
   - ¿Puede un tenant_admin de Tenant A leer datos de Tenant B? (debe ser NO)
   - ¿Puede un usuario donante ver transacciones de OTRO usuario? (debe ser NO, solo las suyas)
   - ¿Puede un tenant_collaborator hacer cosas reservadas a tenant_admin? (debe ser NO)
5. PII handling: emails, teléfonos, direcciones, IDs fiscales. ¿Se logean en plain text en algún `console.log`? ¿En Crashlytics?
6. Secretos: confirmar que NO hay API keys hardcodeadas en código (grep `pk_live_`, `sk_live_`, `whsec_`, `AIza`).
7. Storage rules (`storage.rules`): mismo análisis. Profile photos, logos, etc.
8. Verificar el flujo de bootstrap super_admin y `claimPendingTenantAdmin` — ¿puede un atacante forzar pending admin de un email que no es suyo?

Reporte por colección y por CF.

---

## Fase 6 — Persistencia y datos del usuario

**Objetivo**: validar que TODO lo del usuario se guarda correctamente y no se pierde.

Casos a validar:
1. **Foto de perfil**: ¿dónde se guarda? (Storage path), ¿se comprime antes? ¿qué pasa si el upload falla a mitad? ¿qué pasa si el usuario sube una foto de 50MB?
2. **Settings del usuario**: idioma, tema, moneda, presets personales.
3. **Pushka actual**: monto acumulado, racha (streak), última donación.
4. **Historial de transacciones**: legacy (pre-multi-tenant) y nuevas. Ver memoria `session_2026_04_15` — quedó pendiente backfill de `tenantId` en transacciones legacy.
5. **Donaciones recurrentes**: estado, próximo cobro, método de pago asociado.
6. **Cuando un usuario cambia de tenant**: ¿qué datos se mantienen? ¿qué se borra? ¿hay flujo de "abandonar tenant"?
7. **Cuando un tenant se elimina** (CF `deleteTenant`): ¿qué pasa con las donaciones históricas de sus usuarios? ¿con los `tenantIds[]` de los usuarios?
8. **Backups**: ¿hay export programado de Firestore? ¿Política de retención?

Reporte: cada caso + estado actual + riesgos.

---

## Fase 7 — Performance para 3000 usuarios activos diarios

**Objetivo**: el sistema debe sostener 3k DAU sin caerse ni pasarse de presupuesto Firebase.

Tareas:
1. Estimar lecturas/escrituras Firestore por sesión de usuario típica (login, ver pushka, donar, ver historial). Multiplicar por 3k.
2. Identificar **queries sin índice compuesto** que puedan caer al `__default__` y ser lentas — `firestore.indexes.json` y mensajes "needs index" en logs.
3. Identificar **listeners en tiempo real (`onSnapshot`)** que se mantienen abiertos en pantallas Flutter. Cada uno cuesta lecturas continuas. ¿Se cierran correctamente al salir de la pantalla?
4. Cold starts de Cloud Functions: ¿qué CFs tienen `minInstances`? Las críticas en pago deberían tener al menos 1 warm.
5. Memoria asignada por CF: ¿hay alguna que necesite más?
6. Tamaño del bundle Flutter (release APK / AAB) — ¿menos de 50MB? ¿se cargan imágenes lazy?
7. Pantalla principal en Flutter: ¿cuántas queries Firestore al abrir? ¿hay batching?
8. Pagination de listas largas (historial, transacciones, tenants en admin) — ¿hay paginación real o se trae todo?
9. Imágenes: ¿se sirven con cache headers correctos? ¿hay CDN delante?
10. App Check: ¿hay rate limiting suficiente para defender de abuso?

Reporte: hotspots ordenados por riesgo.

---

## Fase 8 — Multi-idioma (i18n) y accesibilidad

**Objetivo**: 4 idiomas funcionando completos sin keys faltantes ni strings hardcoded.

Tareas:
1. Listar archivos `.arb` (Flutter) y JSON de traducciones del admin.
2. Diff de keys entre ES / EN / FR / HE — ¿hay keys que existen en uno y no en otros?
3. Grep de strings hardcoded en Flutter (texto entre comillas sin pasar por `AppLocalizations`).
4. Validar formato RTL para hebreo (Hebreo es de derecha a izquierda — verificar que la UI no se rompe).
5. Validar formato de moneda por locale (decimales, separadores).
6. Accesibilidad: `Semantics`, contrastes mínimos, tamaño de fuente escalable.

Reporte: keys faltantes, strings hardcoded, problemas RTL.

---

## Fase 9 — Tests (crear suite robusta)

**Objetivo**: dejar la base de tests para que regresiones futuras no pasen sin detectarse. Ioel pidió "miles de tests" — interpretar como cobertura amplia, no número literal.

Generar (sin ejecutar deploy ni nada destructivo, solo crear archivos):

### 9.1 Unit tests — Cloud Functions
- Cada CF crítica con al menos: happy path, auth fail, validation fail, role-not-allowed, idempotency.
- Mocks de Stripe (NO llamar API real en tests).
- Mocks de Firestore con `@firebase/rules-unit-testing` o similar.

### 9.2 Firestore rules tests
- Suite con `@firebase/rules-unit-testing` que cubra cada colección.
- Por colección: probar todos los actores (super_admin, tenant_admin propio, tenant_admin de otro tenant, tenant_collaborator, usuario, anónimo) contra cada operación (read/create/update/delete).
- Debería resultar en MUCHOS tests (cientos solo de rules).

### 9.3 Flutter widget tests
- Pantallas clave: home, donación, settings, login.
- Goldens si tiene sentido.

### 9.4 Flutter integration tests
- Flujo completo: login → ver tenant → donar (mock Stripe) → ver historial.

### 9.5 Admin web tests
- React Testing Library / Vitest.
- Páginas críticas: TenantsPage, TenantDetailPage, AuthContext flows.

### 9.6 Stripe webhook tests
- Generar payloads de cada evento, firmados con secret de test, y enviar al endpoint local — verificar Firestore queda en estado correcto.

Reporte: estructura propuesta de la suite + qué se creó. No ejecutar `npm test` ni `flutter test` (puede romper, lo corre Ioel).

---

## Fase 10 — Síntesis y plan de acción

Al finalizar las 9 fases anteriores, generar `audit_round4_summary.md` con:

1. **Resumen ejecutivo** (5-10 líneas, qué tan listo está para launch en escala 1-10).
2. **Tabla consolidada de bugs** ordenada por severidad.
3. **Bloqueantes de launch** (CRITICAL) — lista numerada.
4. **Recomendaciones de limpieza** (basura del admin web identificada en Fase 1).
5. **Recomendaciones de performance** (top 5 hotspots).
6. **Plan de remediación sugerido** — qué fixear primero, en qué orden, con tiempo estimado.

---

## Output esperado al terminar todo

En la raíz del repo `pushka_app/`:
- `audit_round4_phase0_map.md`
- `audit_round4_phase1_admin_cleanup.md`
- `audit_round4_phase2_sync.md`
- `audit_round4_phase3_stripe_connect.md`
- `audit_round4_phase4_subscriptions.md`
- `audit_round4_phase5_security.md`
- `audit_round4_phase6_persistence.md`
- `audit_round4_phase7_performance.md`
- `audit_round4_phase8_i18n.md`
- `audit_round4_phase9_tests.md` (+ archivos de tests creados en `functions/test/`, `test/`, `pushka_admin/src/__tests__/`)
- `audit_round4_summary.md`

---

## Recordatorio final

- Ioel está en Windows 11, PowerShell por defecto, sin WSL.
- Usar Markdown linkable (`[file.ts](path/file.ts)`) en los reportes.
- Reportar progreso al final de cada fase y **esperar luz verde** antes de seguir.
- Si en cualquier fase encontrás un `CRITICAL` que bloquea launch, decirlo en ese momento — no esperes al summary final.

**Comenzá por Fase 0**.
