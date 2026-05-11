# Auditoría Round 4 — Fixes que requieren acción externa (no codeable)

Fecha: 2026-05-11

Estos bugs **NO se pueden resolver desde el repo solamente** — requieren cambios en consolas externas (Google Cloud, Firebase, Stripe) o decisiones de producto. Cada uno tiene los pasos exactos.

---

## BUG-051 — Activar Firestore Scheduled Exports en producción (HIGH)

**Estado**: pendiente acción operacional.

**Por qué**: Firestore no tiene snapshot diario nativo. Sin esto, un bug catastrófico (CF que borra mal, migración fallida) puede perder datos sin recuperación posible. PITR (point-in-time recovery) solo cubre 7 días por defecto y no es un backup real.

**Pasos (correr en Cloud Shell del proyecto `pushka-app-ioel`):**

```bash
# 1. Crear bucket con lifecycle (auto-delete > 30 días)
gsutil mb -p pushka-app-ioel -l us-central1 gs://pushka-app-ioel-backups
gsutil lifecycle set <(cat <<EOF
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30}
    }
  ]
}
EOF
) gs://pushka-app-ioel-backups

# 2. Darle al Cloud Scheduler service account permisos de import/export
PROJECT_NUMBER=$(gcloud projects describe pushka-app-ioel --format='value(projectNumber)')
gcloud projects add-iam-policy-binding pushka-app-ioel \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/datastore.importExportAdmin"
gsutil iam ch serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com:objectAdmin gs://pushka-app-ioel-backups

# 3. Crear el job de Cloud Scheduler que dispara el export diario a las 03:00 UTC
gcloud scheduler jobs create http daily-firestore-export \
  --schedule="0 3 * * *" \
  --time-zone="Etc/UTC" \
  --location=us-central1 \
  --uri="https://firestore.googleapis.com/v1/projects/pushka-app-ioel/databases/(default):exportDocuments" \
  --http-method=POST \
  --oauth-service-account-email="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --message-body='{"outputUriPrefix":"gs://pushka-app-ioel-backups"}'

# 4. Test manual (dispara ahora)
gcloud scheduler jobs run daily-firestore-export --location=us-central1

# 5. Verificar que apareció el dump
gsutil ls gs://pushka-app-ioel-backups/
```

**Repetir lo mismo en `pushka-app-ioel-test`** (con bucket `gs://pushka-app-ioel-test-backups`).

**Costo estimado**: $0.18/GB export + $0.020/GB/mes storage. Pushka actual <1GB → < $5/mes.

---

## BUG-048 — Ejecutar `backfillTransactionTenantId` en prod

**Estado**: CF deployada (Round 4 Batch 7). Falta ejecutar manualmente.

**Por qué**: transacciones pre-multi-tenant no tienen el campo `tenantId`. Las queries del admin `where('tenantId', '==', X)` las excluyen → reportes históricos incompletos.

**Pasos**:

1. Asegurate de estar logueado como super_admin en el admin web (https://pushka-admin.web.app)
2. Abrí DevTools → Console (F12)
3. Pegá:
   ```js
   const fn = firebase.functions().httpsCallable('backfillTransactionTenantId');
   const res = await fn({});
   console.log(res.data);
   ```
4. Verificá el resultado: `{ scanned, stamped, alreadyHadTenantId, skippedNoUserTenant, remaining }`
5. Si `remaining > 0`, **volvé a correr** hasta que `remaining === 0`
6. Si `skippedNoUserTenant > 0`, esos users no tienen tenantId — revisalos manualmente

Alternativa (si DevTools no funciona): correr desde la app Flutter en `flavor prod` con el rol super_admin.

---

## BUG-019 follow-up — Re-verificar Connect del primer tenant (Jabad en Campus)

Una vez que el rab complete Stripe Connect onboarding:

1. Verificá en Firestore `tenants/{jabadId}.stripeConnectStatus === 'active'`
2. Si está `'restricted'`, el rab tiene KYC pendiente. Mirá `account.charges_enabled` y `payouts_enabled` en https://dashboard.stripe.com → Connected accounts → {accountId} → Requirements

---

## BUG-026 follow-up — Probar suscripción real del tenant

Una vez que el primer tenant esté creado vía `createTenant`:

1. Verificá que `tenants/{tenantId}.stripeSubscriptionId` está set (no null)
2. El response de createTenant debería incluir `subscription.hostedInvoiceUrl` — mandalo por email al rab para que confirme el método de pago
3. Cuando el rab pague la primera factura, el webhook `invoice.payment_succeeded` cambia `paymentStatus` a `current`

---

## BUG-051 follow-up — También considerar:

- **Backups de Firebase Storage** (logos, profile photos): si los necesitamos recuperar después de un borrado accidental, lifecycle a "Coldline" en lugar de delete, o cross-bucket replication.
- **Backups de Authentication**: `firebase auth:export users.json --project pushka-app-ioel` cron mensual.

---

## BUG-059 — Hebrew en admin web (MEDIUM, postpone)

**Estado**: no resuelto. Requiere traducción manual de ~300 strings al hebreo + agregar 'he' al `Lang` type en `pushka_admin/src/lib/translations.ts`.

**Decisión**: postponer hasta que tengamos un tenant israelí real que lo pida.

---

## BUG-068 — Contraste primaryColor default (LOW, decisión de producto)

`#e8a87c` (terracota) sobre blanco no pasa WCAG AA contrast ratio. Posibles fixes:
- Cambiar default a un color más oscuro
- Restringir el rango aceptable de primaryColor en el editor (rechazar colores con contrast < 4.5:1)
- O dejar como está y aceptar el riesgo

**Decisión**: postponer hasta que algún usuario reporte problemas de visibilidad.

---

## BUG-069 — Verificar RTL en runtime (MEDIUM, requiere device en Hebrew)

Pasos:
1. En el dispositivo, cambiar idioma del sistema a Hebrew
2. Abrir la app
3. Recorrer todas las pantallas y verificar:
   - Texto fluye derecha → izquierda
   - Iconos direccionales (flechas back) se voltean
   - Paddings asimétricos respetan RTL (`EdgeInsetsDirectional` vs `EdgeInsets`)
   - Animaciones con `Transform.translate(Offset(x, 0))` se voltean

Reportar visualmente cualquier glitch.

---

## BUG-070 — Suite de tests con emulator (MEDIUM, 2-3 semanas dev)

**Estado**: skeleton creado en `functions/test/createPaymentIntent.test.js`. Plan completo en `audit_round4_phase9_tests.md`.

**Pasos para empezar**:
```bash
cd functions
npm install --save-dev jest @firebase/rules-unit-testing firebase-functions-test
```

Agregar `"test": "jest"` a `package.json` scripts. Iniciar con los tests de `setAdminClaim` para cubrir el regression de BUG-035.

---

## Resumen de fixes aplicados vs pendientes

| Categoría | Aplicado en código | Pendiente externo |
|---|---|---|
| Security | ✅ BUG-035, 036, 040, 022, 023 | — |
| Stripe routing | ✅ BUG-018, 013, 019, 024 | Onboarding Jabad |
| SaaS subscription | ✅ BUG-026, 027, 028, 029, 030, 034 | Pago real primer tenant |
| Multi-tenant content | ✅ BUG-001, 002, 060, 061, 062, 063, 064, 066 | — |
| Sync & triggers | ✅ BUG-007, 010, 047 | — |
| Admin web | ✅ BUG-003, 004 | BUG-059 (Hebrew) |
| Persistencia | ✅ BUG-045, 046, 049, 050 | BUG-048 (backfill), BUG-051 (backups) |
| Performance | ✅ BUG-056, 057, 032 | BUG-054 (minInstances) |
| Misc | ✅ BUG-041 | BUG-068, 069, 070 |

**Total**: ~50 fixes aplicados en código, ~10 pendientes acción externa.

---

## Próximos pasos recomendados

1. **Hoy/mañana**: deploy CFs a dev (`firebase deploy --only functions --project pushka-app-ioel-test`) y probar localmente que el flujo de donación + createTenant funciona end-to-end
2. **Esta semana**: deploy CFs a prod y correr `backfillTransactionTenantId` + activar exports Firestore
3. **Esta semana**: coordinar onboarding Stripe Connect con el rab Jabad en Campus
4. **Próxima semana**: probar pago real $1 USD en flavor prod, subir listing Play Store
