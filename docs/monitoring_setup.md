# Monitoring setup — pre-rollout checklist

Cinco minutos de configuración **antes de invitar al primer donante real**.
Todo esto se hace en Firebase Console / GCP Console / Stripe Dashboard.
NO requiere código.

## 1. Cloud Logging Alert — errores críticos en CFs

Hoy `console.error` en CFs llega a Cloud Logging pero **nadie lo está mirando**.
Si Stripe se cae un sábado, te enterás cuando un donante reclama.

### Pasos

1. Abrir [Google Cloud Console → Logs Explorer](https://console.cloud.google.com/logs)
   con el proyecto `pushka-app-ioel-test` (luego repetir para `pushka-app-ioel`).
2. Pegar este filtro en la barra de búsqueda:
   ```
   resource.type="cloud_function"
   severity>=ERROR
   (
     jsonPayload.message=~"Stripe API error"
     OR jsonPayload.message=~"stripe_charge_failed"
     OR jsonPayload.message=~"webhook"
     OR jsonPayload.message=~"lock_tx_failed"
     OR jsonPayload.message=~"monitorStripe"
     OR jsonPayload.message=~"connectAccountId DRIFT"
     OR textPayload=~"Stripe API error"
   )
   ```
3. Click "Create alert" (icono de campana arriba a la derecha).
4. Configuración:
   - **Notification channel**: agregar tu email (Notification channels → Email).
   - **Alert name**: `Pushka — CF critical error`
   - **Documentation** (mensaje en el email):
     ```
     Critical error en Cloud Function. Revisar Logs Explorer:
     https://console.cloud.google.com/logs/query?project=PROJECT_ID
     ```
   - **Threshold**: 1 occurrence en 5 min (cualquier error crítico te avisa).
5. Save.

### Repetir para `pushka-app-ioel` (prod)

Cambiar el proyecto y volver a configurar el mismo filtro.

---

## 2. Firestore quota alerts

Si llegamos al 80% del plan Spark gratuito, queremos saber antes de saturar.

1. [GCP Console → APIs & Services → Quotas](https://console.cloud.google.com/iam-admin/quotas)
2. Filtrar por "Firestore".
3. Para cada quota relevante (read/write per day):
   - Click → Create alert at 80% usage.

---

## 3. Stripe Dashboard alerts

### Webhook delivery failures

1. [Stripe Dashboard → Developers → Webhooks](https://dashboard.stripe.com/webhooks)
2. Click en el endpoint `stripeWebhook`.
3. Settings → "Notify on failure" → tu email.

### Disputes / Fraud / Failed payments

1. [Stripe Dashboard → Settings → Notifications](https://dashboard.stripe.com/settings/team)
2. Activar email para:
   - Disputes opened
   - Disputes lost
   - High-risk payments flagged
   - Subscription payment failures

---

## 4. Crashlytics (cliente)

Ya está configurado. Verificar que las alertas estén activas:

1. [Firebase Console → Crashlytics](https://console.firebase.google.com)
2. Settings (engranaje arriba a la derecha) → **Alerts**.
3. Habilitar:
   - **Velocity alerts** (crash spike): on
   - **New issue alert**: on para `payment:*` (los logueamos con ese prefijo)
4. Email destino: tu inbox.

---

## 5. Verificación post-setup (smoke test)

Disparar un error a propósito para confirmar que las alertas llegan:

1. Stripe dashboard → Webhooks → click "Send test event" con un evento que no esté
   suscrito → debería llegarte el email "delivery failed".
2. Crashlytics → en Flutter, llamar `FirebaseCrashlytics.instance.recordError(...)`
   con un error de prueba en algún botón temporal → ver que aparece en consola
   en ~2 min.

Si NO llegan los emails: revisar que el filtro de spam no los esté bloqueando
y que el Notification channel quedó verificado.

---

## Costo estimado

- Cloud Logging alerts: **gratis** dentro del free tier.
- Firestore quota alerts: **gratis**.
- Stripe alerts: **gratis** (incluido).
- Crashlytics alerts: **gratis**.

Total: $0/mes. Hacelo HOY.
