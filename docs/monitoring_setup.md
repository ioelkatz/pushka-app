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

---

## 6. Cold start de Cloud Functions (latencia 5-10s al primer click)

### Por qué pasa

Cloud Functions v2 escala a CERO cuando no hay tráfico. La primera llamada
después de un período de inactividad sufre **cold start**: el sistema arranca
un container Node.js, carga firebase-admin (~10MB) + firebase-functions +
secrets manager, y recién entonces ejecuta tu código. Eso son 3-5 segundos
fijos antes de tocar Stripe.

En **dev** (testing solo) esto se nota mucho porque las funciones casi nunca
se invocan → siempre cold. En **prod** con 50+ donaciones/día el container
queda warm casi todo el tiempo y el lag desaparece naturalmente.

### Cuándo configurar `minInstances`

Pagar para tener instances "always-on" (`minInstances: 1`) es la solución
oficial. Costo aproximado **us-central1**:

| Función | Memoria | CPU | Costo/mes con minInstances:1 |
|---------|---------|-----|------------------------------|
| createPaymentIntent | 256MB | 1 vCPU | ~$72 |
| createSetupIntent | 256MB | 1 vCPU | ~$72 |
| createDonationSubscription | 256MB | 1 vCPU | ~$72 |
| listSavedCards | 256MB | 1 vCPU | ~$72 |
| **Total 4 funciones** | | | **~$288/mes** |

### Recomendación por etapa

- **HOY (dev + rollout 50-100 users)**: NO configurar `minInstances`. El
  costo no se justifica con tráfico tan bajo y el lag solo te afecta a vos
  testeando. Tus primeros 50-100 usuarios reales mantendrán las CFs warm
  por su propio uso.

- **Cuando tengas 200+ donaciones/mes**: configurar `minInstances: 1` SOLO
  en `createPaymentIntent` (la más crítica para conversión). Con commission
  del 3% sobre $200/donación promedio = $6 por donación → 12 donaciones cubren
  el costo mensual de esa instance.

- **Cuando tengas 1000+ donaciones/mes**: agregar a las 4 funciones críticas.

### Cómo configurar (cuando llegue el momento)

En `functions/index.js`, en el `onCall` config:

```js
exports.createPaymentIntent = onCall(
  {
    secrets: [stripeSecret],
    enforceAppCheck: true,
    minInstances: 1, // ← agregar esta línea (solo en prod)
  },
  async (request) => { ... }
);
```

Y deployar **solo a prod**:
```
firebase deploy --only functions:createPaymentIntent --project pushka-app-ioel
```

NO agregarlo en `pushka-app-ioel-test` (dev) — gastarías sin necesidad.

### Mientras tanto (dev)

El spinner en el botón "Agregar tarjeta" ya muestra al user que algo está
pasando. Si querés un mensaje más claro, decímelo y agrego un overlay tipo
"Cargando Stripe..." que se muestra cuando la latencia supera 2 segundos.
