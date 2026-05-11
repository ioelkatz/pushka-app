# Auditoría Round 4 — Fase 6: Persistencia y datos

Fecha: 2026-05-11

---

## 1. Foto de perfil

### Path y persistencia
- **Storage path**: `profile_photos/{uid}.jpg`
- **Upload**: `UserRepository.uploadProfilePhoto` ([lib/features/users/data/user_repository.dart:129](lib/features/users/data/user_repository.dart#L129))
- **URL guardado**: `users/{uid}.photoURL` (download URL firmado, token-based)
- **Limpieza en deleteAccount**: ✓ borra el blob de Storage

### Bugs

#### BUG-045 — No hay compresión/resize antes de subir foto
- **Archivo**: [lib/features/users/data/user_repository.dart:129-145](lib/features/users/data/user_repository.dart#L129)
- **Severidad**: 🟠 **HIGH**
- **Descripción**: `uploadProfilePhoto` recibe `Uint8List bytes` y los sube tal cual. No hay:
  - Validación de tamaño (Storage rule rechaza > 5MB → falla genérica al user)
  - Resize a dimensiones razonables (200x200 sería suficiente para avatar)
  - Compression JPEG con quality < 100
- **Impacto**: cámara de Samsung S25 default 12MP → JPEG de 4-8MB. La mayoría de uploads fallarán por la rule de 5MB → user ve "permission-denied" sin entender por qué.
- **Fix propuesto**: usar `flutter_image_compress` o `image` package. Comprimir a max 1024x1024, quality 80. Validar tamaño post-compress < 5MB antes del put.
  ```dart
  // Pseudo:
  final compressed = await FlutterImageCompress.compressWithList(
    bytes, minWidth: 512, minHeight: 512, quality: 80,
  );
  if (compressed.length > 5 * 1024 * 1024) {
    throw ImageTooLargeException();
  }
  ```

#### BUG-046 — No hay manejo de error visible en uploadProfilePhoto
- **Severidad**: 🟡 **MEDIUM**
- **Descripción**: si la subida falla (red caída, Storage rule rechaza, etc.), la excepción burbujea al UI sin mensaje localizado. El user ve un Snackbar de error genérico.
- **Fix propuesto**: capturar `FirebaseException` y mostrar mensajes traducidos según el `code` (`storage/canceled`, `storage/quota-exceeded`, etc.).

### Race conditions
- Si el user sube una foto y al instante cierra la app, el upload se cancela. El `users/{uid}.photoURL` queda apuntando al URL anterior o vacío. **No es bug — comportamiento esperado**.
- Si dos uploads concurrentes del mismo user → Storage permite overwrite (mismo path `{uid}.jpg`), segundo gana. OK.

---

## 2. Settings del usuario

### Persistencia

Todos los campos viven en `users/{uid}` (root):
- `language`, `currencyCountry`, `currencyCode`
- `soundEnabled`, `vibrationEnabled`, `ambientEnabled`, `coinJingleEnabled`
- `partialPaymentsEnabled`, `additionalPaymentOptionsEnabled`
- `biometricAuthenticationEnabled`
- `presetAmount`, `presetAmounts`, `pushkaGoal` (también espejados en tenantState — ver más abajo)
- `autoEmpty*` fields (legacy single-tenant)
- `streakCount`, `lastStreakDate` (también en tenantState)
- `stripeCustomerId` (server-managed, client read-only)
- `reminderCount`, `onboardingCompleted`

✓ **Firestore rules** validan tipos y rangos para cada campo (ver firestore.rules:199-300+).
✓ **Stripe fields** son write-protected en update (`hasNoStripeFieldsWritten`).
✓ **tenantId/tenantIds** son write-protected (solo CFs los manejan).

### Sync entre `users/{uid}` y `tenantState/{tenantId}`

Algunos campos están **duplicados** entre el doc raíz y el subdoc tenantState:
- `pushkaAmount`, `pushkaGoal`, `presetAmount`, `presetAmounts`
- `streakCount`, `lastStreakDate`
- `autoEmptyFrequency`, `autoEmptyWeekday`, `autoEmptyDayOfMonth`, `autoEmptyTopOff*`
- `autoEmptyNextRunAt`

Esto fue por la transición legacy → multi-tenant. La **lazy migration** en `getTenantConfig` ([functions/index.js:6416](functions/index.js#L6416)) copia los campos del user doc al tenantState si no existe.

#### BUG-047 — Campos legacy en `users/{uid}` no se purgan tras la migración
- **Severidad**: 🟢 **LOW**
- **Descripción**: la lazy migration crea el tenantState pero NO elimina los campos legacy del user doc. Los campos quedan duplicados — uno autoritativo (`tenantState`) y otro huérfano (`users/{uid}`).
- **Impacto**:
  - Conceptualmente confuso, dev pierde tiempo debugging "cuál es el campo bueno"
  - Si Flutter app por error escribe al campo viejo, se pierde sync silenciosamente
- **Fix propuesto**: en la lazy migration, después de crear el tenantState, hacer `userRef.update({ pushkaAmount: FieldValue.delete(), ... })` para los campos migrados. Ya hace `autoEmptyNextRunAt: null` (líneas 6458-6463) pero solo ese.

---

## 3. Historial de transacciones

### Persistencia
- `users/{uid}/transactions/{txId}` donde `txId = paymentIntentId` (o `refund_{chargeId}`, `dispute_{disputeId}`, `inv_{invoiceId}`)
- Escrito por `stripeWebhook` (uno solo proceso server-side, idempotente)
- Lectura desde Flutter: `transaction_repository.dart` + `transactions_provider.dart`
- Lectura desde admin: `getRecentTransactions` CF + `users/{uid}/transactions` query directa en `useUsers`

### Campos por tx
- `type`: 'tzedaka' | 'pushkaEmpty' | 'refund' | 'chargeback'
- `amount`, `currencyCode`, `tenantId`
- `description`, `paymentMethod`, `status`
- `correlationId` (16 hex chars) para tracing
- `donorMessage` (sanitizado, max 240 chars) — opcional
- `donationReason` (max 80 chars) — opcional
- `createdAt`

### Backfill pendiente — `tenantId` en transacciones legacy

#### BUG-048 — Transacciones pre-multi-tenant carecen de `tenantId`
- **Severidad**: 🟡 **MEDIUM**
- **Estado**: ya documentado en `CLAUDE.md` y memoria `audit_session_2026_04_15`. **Pendiente de ejecución en prod**.
- **Impacto**: queries multi-tenant tipo `.where('tenantId', '==', X)` silenciosamente excluyen estas filas → admin del tenant no ve transacciones históricas de antes del cutover.
- **Mitigación parcial actual**: firestore.rules tiene fallback `'tenantId' in resource.data ? ... : get(...users/{uid}.tenantId)` — pero esto solo aplica a rules, no a queries client-side.
- **Fix propuesto**: ejecutar one-off CF de backfill en prod. **NO BLOQUEANTE para invitar a Jabad en Campus** porque ese tenant es nuevo (no tiene transacciones pre-cutover).

---

## 4. Donaciones recurrentes

### Persistencia
- Stripe Subscription con metadata `{ uid, tenantId, purpose: 'donation_recurring', donationReason?, donorMessage? }`
- Lectura: `listDonationSubscriptions` CF lista subs del customer Stripe
- Cada invoice exitoso genera tx con `subscriptionId` en `users/{uid}/transactions/inv_{invoiceId}`

### Cleanup
- `cleanupIncompleteDonationSubscriptions` cron borra subs en `incomplete_expired` después de 7 días ✓

### Bug
#### BUG-049 — Si user borra cuenta con subs activas, las subs se cancelan (deleteAccount lo hace) — pero el tenant pierde el ingreso recurrente
- **Severidad**: 🟢 **LOW** — comportamiento esperado
- **Descripción**: deleteAccount cancela todas las subs Stripe del user. Eso está bien — pero el tenant_admin no recibe notificación del corte. Podría querer saber para conectar con el donante.
- **Fix propuesto**: opcional — escribir `_activityLog` cuando deleteAccount cancela subs.

---

## 5. Cambio de tenant

### Flujos
- `joinTenant` ([functions/index.js:5436](functions/index.js#L5436)): agrega al `tenantIds[]`, setea active si es el primero
- `switchTenant` ([functions/index.js:5554](functions/index.js#L5554)): cambia `tenantId` activo, valida membership
- `leaveTenant` ([functions/index.js:5589](functions/index.js#L5589)): remueve de `tenantIds`, fallback a otro tenant si era el activo

### Qué se preserva al cambiar de tenant
- `pushkaAmount`, `streak`, `presets` del tenant viejo → quedan en `tenantState/{tenantOldId}` (no se borran)
- `transactions` históricas → se mantienen (con `tenantId` para filtrado)
- Stripe customer → un solo customer multi-tenant (compartido)
- Saved cards → compartidas entre tenants (Stripe customer único)

### Bugs

#### BUG-050 — `leaveTenant` no elimina el `tenantState/{tenantId}` del usuario
- **Severidad**: 🟢 **LOW**
- **Descripción**: leaveTenant solo actualiza el array `tenantIds` y cambia `tenantId` activo, no borra el `tenantState/{tenantOldId}` doc. Si el user re-joinea más tarde, conserva su pushka anterior.
- **Comportamiento**: probablemente intencional (preservar progreso). Documentar como design decision.

---

## 6. Eliminación de tenant — cleanup

`deleteTenant` ya cubierto en Fase 4. Resumen:
- ✅ Cancela Stripe sub
- ✅ Borra Stripe customer
- ✅ Borra slug lock
- ✅ Paginated user sweep (tenantIds, tenantState)
- ✅ Hard delete tenant doc
- ✅ Audit log
- ❌ NO revoca claims (BUG-030)
- ❌ NO borra transacciones históricas (intencional — retención legal)

---

## 7. Backups Firestore

### Estado actual

**No hay configuración explícita** de backups programados en el repo. Buscando en `firebase.json` y `firestore.indexes.json` no hay schedules de export.

#### BUG-051 — Sin backups programados en producción
- **Severidad**: 🟠 **HIGH**
- **Descripción**: Pushka producción no tiene exports automatizados de Firestore. Un bug catastrófico (CF que borra mal por error, migración fallida) podría perder datos sin recuperación posible. Firestore tiene PITR (point-in-time recovery) limitado a 7 días por defecto, no es un backup real.
- **Fix propuesto**:
  1. Activar **Firestore Scheduled Exports** vía Cloud Scheduler:
     ```bash
     gcloud firestore export gs://pushka-app-ioel-backups
     ```
     Schedule diario, retención 30 días.
  2. Crear el bucket GCS `pushka-app-ioel-backups` con object lifecycle (auto-delete > 30 días).
  3. Verificar permisos: el Cloud Scheduler SA necesita `roles/datastore.importExportAdmin`.
  4. **Costo**: $0.18/GB por export. Pushka actual estimado < 1GB → < $5/mes.
- **Alternativa más simple**: usar Firebase CLI script en GitHub Action diaria que ejecute `gcloud firestore export`.

---

## 8. Persistencia local (Flutter Hive cache)

`TenantConfig.toMap()` ([lib/features/tenant/domain/tenant_config.dart:66](lib/features/tenant/domain/tenant_config.dart#L66)) es round-trippable para Hive cache. Permite que la app abra con branding del último tenant antes del network call. ✓

No encontré evidencia de cache para `transactions` ni `tenantState`. El user que abre la app offline ve loaders hasta network.

#### BUG-052 — No hay offline-first para transactions/pushka
- **Severidad**: 🟢 **LOW** — feature request más que bug
- **Descripción**: Firestore tiene built-in offline persistence pero solo para listeners. Si la app inicializa esos listeners siempre, OK. Si reabre desde cold start sin red → spinner.
- **Decisión**: posponer salvo que un tenant lo pida.

---

## Tabla resumen Fase 6

| ID | Severidad | Título | Bloquea launch? |
|---|---|---|---|
| BUG-045 | 🟠 HIGH | Sin compresión de foto perfil → uploads fallan | **Sí** (UX rota) |
| BUG-046 | 🟡 MEDIUM | Sin manejo de error upload | No |
| BUG-047 | 🟢 LOW | Campos legacy duplicados sin purgar | No |
| BUG-048 | 🟡 MEDIUM | Backfill tenantId en transacciones legacy pendiente | No (Jabad nuevo) |
| BUG-049 | 🟢 LOW | deleteAccount no notifica al tenant_admin | No |
| BUG-050 | 🟢 LOW | leaveTenant deja tenantState huérfano (intencional) | No |
| BUG-051 | 🟠 HIGH | Sin backups Firestore en producción | **Sí** (riesgo operacional) |
| BUG-052 | 🟢 LOW | Sin cache offline-first transactions | No |

**Resumen**: 0 CRITICAL, 2 HIGH, 2 MEDIUM, 4 LOW.

---

Continúo a **Fase 7 — Performance**.
