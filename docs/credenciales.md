# Dónde vive cada credencial

Inventario de todo lo secreto del proyecto: dónde está guardado, quién lo lee
y cómo se rota. Este archivo **no contiene ningún valor** y por eso puede
estar en el repo.

Se escribió el 2026-10-23, después de que una rotación de la clave de Stripe
dejara los pagos caídos un rato por no tener este inventario a mano. La
lección está al final.

---

## Secretos del backend — Firebase Secret Manager

Los declara `functions/index.js` con `defineSecret`. Viven en Google Secret
Manager, encriptados, y las Cloud Functions los leen en ejecución. **Nunca
están en el repo ni en la app.**

| Secreto | Para qué | Proyecto prod | Proyecto dev |
|---|---|---|---|
| `STRIPE_SECRET_KEY` | Cobrar, tarjetas guardadas, suscripciones | `sk_live_…` | `sk_test_…` |
| `STRIPE_WEBHOOK_SECRET` | Verificar la firma del webhook de pagos | sí | sí |
| `STRIPE_BILLING_WEBHOOK_SECRET` | Firma del webhook de facturación del SaaS | sí | sí |
| `STRIPE_CONNECT_CLIENT_ID` | OAuth de Stripe Connect | sí | sí |
| `BREVO_API_KEY` | Todo el correo transaccional | sí | verificar |

Cada proyecto de Firebase tiene su propio juego. Rotar el de prod no toca dev
y al revés.

```
firebase functions:secrets:set <NOMBRE> --project <pushka-app-ioel|pushka-app-ioel-test>
```

Usá `scripts/set-secret.ps1` en vez del comando pelado. Hay motivos, están
abajo.

---

## Valores de compilación — dart-define

No son secretos: viajan dentro del APK y cualquiera puede extraerlos. Están
acá para que se sepa de dónde salen.

| Variable | Qué es |
|---|---|
| `ENV` | `dev` o `prod`. Elige proyecto de Firebase y modo de Stripe. |
| `STRIPE_PUBLISHABLE_KEY` | Clave **pública** de Stripe (`pk_live_` / `pk_test_`). No sirve para cobrar. |
| `APP_CHECK_PROVIDER` | `debug` solo para el APK de sideload. Ver la nota en `CLAUDE.md`. |
| `RECAPTCHA_SITE_KEY` | Clave de sitio de reCAPTCHA, también pública. |
| `STRIPE_MERCHANT_ID` | Merchant ID de Apple Pay. Vacío hasta que exista la cuenta de Apple. |

Los valores de prod salen de `production.env`; los de dev, de `dev.env`.
Los dos están en `.gitignore`.

---

## Archivos locales — nunca se commitean

| Archivo | Recuperable |
|---|---|
| `android/app/pushka-release-key.jks` | **NO.** Sin esto no se puede volver a publicar en Play. |
| `android/key.properties` | **NO.** Las contraseñas del keystore. |
| `production.env` / `dev.env` | Sí, con las claves de Stripe a mano |
| `android/app/src/{prod,dev}/google-services.json` | Sí, con `firebase apps:sdkconfig` |
| `lib/firebase_options_{prod,dev}.dart` | Sí, con `flutterfire configure` |

Los dos primeros son los únicos irrecuperables del proyecto entero. Están
respaldados aparte desde el 2026-09-22.

---

## Lo que NO tiene credenciales de Stripe

Vale la pena dejarlo escrito, porque lo contrario se dio por cierto y costó
tiempo:

- **`pushka_admin`** (panel de administración) — solo usa `VITE_ENV`. Todo lo
  sensible lo hace a través de las Cloud Functions.
- **La web de jabadencampus.com en Vercel** — tiene Supabase y la contraseña
  del panel, pero **no** tiene `STRIPE_SECRET_KEY`. El código de
  `src/lib/stripe.ts` está preparado para una restricted key de solo lectura
  y devuelve `null` si no está, así que el panel de finanzas muestra
  "conectá Stripe". Nunca se enchufó.

**Entonces: la clave secreta de Stripe vive en un solo lugar, Firebase.**

---

## Cómo rotar la clave de Stripe

Las dos claves conviven hasta el final, así que nada se corta en ningún
momento y siempre hay vuelta atrás.

1. **Stripe → Developers → API keys → Standard keys → Create secret key.**
   Opción "Powering an integration you built". Nombre con fecha,
   `pushka-backend-<mes><año>`. **No revoques la vieja todavía.**

2. **Cargar la nueva**, sin cerrar el cartel de Stripe:

   ```powershell
   .\scripts\set-secret.ps1 -Nombre STRIPE_SECRET_KEY -Proyecto pushka-app-ioel -Prefijo sk_live_
   ```

   El script espera a que copies el valor, así que el orden no importa.
   Decile que sí al redeploy que ofrece el CLI.

3. **Verificar que producción esté en pie**:

   ```
   curl https://us-central1-pushka-app-ioel.cloudfunctions.net/health
   ```

   Tiene que dar `"stripe":"ok"` y HTTP 200. Si da `degraded`, la clave
   no quedó bien: volvé al paso 2, no sigas.

4. **Una donación real de un dólar desde la app**, y que llegue el
   comprobante. El endpoint de salud solo prueba leer el saldo; la donación
   prueba el camino completo sobre la cuenta conectada del Rab.

5. **Recién ahí, revocar la vieja** en Stripe.

---

## Qué pasó el 2026-10-23

Dos cosas, las dos sobre cómo entra el valor, ninguna sobre Stripe.

**El valor pegado no era el valor.** Se usó `Read-Host` para pedir la clave.
Ese prompt no pasa por el motor de teclado de PowerShell, así que **Ctrl+V no
pega**: inserta un carácter de control literal. Firebase guardó ese carácter
como si fuera la clave, redesplegó 26 funciones con él, y los pagos de
producción quedaron rechazados por Stripe hasta que se detectó.

Lo que faltó no fue cuidado, fue **una verificación antes de aplicar**. Por
eso `scripts/set-secret.ps1` chequea prefijo, largo y espacios, y aborta sin
tocar Firebase si algo no da.

**La clave quedó en dos historiales.** Un intento fallido con `printf` —que
no existe en PowerShell— dejó la clave escrita en la línea de comando, y de
ahí pasó al archivo de historial de PSReadLine, en texto plano. Esa clave hubo
que descartarla y crear otra.

Regla que sale de esto: **el valor de un secreto nunca se escribe como
argumento de un comando**. Ni en una terminal, ni en un chat, ni en un
archivo temporal que después uno se olvida de borrar.

---

## Lo que queda pendiente

- **Dos claves restringidas** en lugar de una completa: una de solo lectura
  para el panel de finanzas de la web, y una con permisos acotados para la
  app. El backend no usa reembolsos, transferencias, retiros ni creación de
  cuentas, así que recortarlos no le quita nada. Probar primero en modo test.
- **App Check**, hoy apagado en las 51 funciones de cara al usuario. Se
  prende de a una y probando en dev. Ver `reference_appcheck_apagado`.
- **Un detector de secretos** que rechace un commit con una clave adentro.
