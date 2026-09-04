# Audit de producto — 2026-09-04

16 confirmados, 42 refutados.

## 1. [CRITICO] La donación recurrente muere en silencio: ni push, ni correo, ni una marca en la pantalla

**Dimension**: sesion-y-confianza — **functions/index.js:4564**

**Evidencia**: El handler de `invoice.payment_failed` (functions/index.js:4564-4602) hace exactamente dos cosas: `writeUserPaymentEvent(uid, ...)` con `kind: "donation_recurring_failed"` y `finalizeWebhookEvent`. No hay `sendToUser` ni `sendEmail` en toda la rama. El comentario de functions/index.js:4873 afirma «The webhook for invoice.payment_failed already notifies the user» — no lo hace. Y la colección donde escribe no la lee nadie: `grep -rn "paymentEvents" lib --include=*.dart` no devuelve un solo resultado. Del lado de la app, `_buildSubTile` (lib/features/payments/presentation/donation_subscriptions_screen.dart:873-968) recibe `sub['status']` desde la CF pero nunca lo usa: una suscripción en `past_due` se dibuja idéntica a una sana, con «Próximo cobro el <fecha>». Cuando Stripe termina el dunning y la pasa a `canceled`/`unpaid`, `listDonationSubscriptions` la filtra con `ACTIVE_STATUSES` y la fila simplemente desaparece de «Mis donaciones». Los propios Términos que la app muestra prometen lo contrario (lib/features/legal/data/legal_content.dart:264: «Si tu medio de pago falla en un cobro recurrente, te notificaremos...»).

**Consecuencia**: Un donante arma una donación mensual, se le vence la tarjeta a los ocho meses y nunca se entera. La app le sigue mostrando la donación como activa con su próxima fecha, después la fila desaparece sin explicación, y él sigue creyendo que da tzedaká todos los meses. La organización pierde el ingreso recurrente sin señal alguna. Es el peor caso de esta auditoría: dinero que el usuario cree que fluye y no fluye, en los cuatro canales callados a la vez.

**Fix propuesto**: En el handler de `invoice.payment_failed`: enviar push (`sendToUser`) Y correo (`sendEmail` al `billingEmail || email`) con enlace a Tarjetas guardadas — el correo es imprescindible porque el push depende de un permiso que muchos no dan. En la app, renderizar `sub['status']` en `_buildSubTile`: badge rojo «Cobro fallido — actualizá tu tarjeta» cuando es `past_due`, y no filtrar del listado las canceladas por falta de pago sin antes mostrar por qué se cancelaron.

---

## 2. [ALTO] El donante nuevo en la PWA queda atrapado en /join/jym770 sin poder salir ni cerrar sesión

**Dimension**: ciclo-de-cuenta — **lib/app/router.dart:195**

**Evidencia**: El redirect global manda a `/join/$hostSlug` a todo usuario logueado sin tenant cuando el hostname está mapeado:

```dart
// router.dart:188-199
if (_cachedHasTenant == false) {
  final hostSlug = tenantSlugFromHostname();
  if (hostSlug != null && !loc.startsWith('/join/')) {
    return '/join/$hostSlug';
  }
  return '/tenant-setup';
}
```

`hostname_tenant_map.dart:23` mapea `app.jabadencampus.com` → `jym770`, que es el host productivo (mismo dominio que usa el redirect de `firebase.json`). Es decir: en producción `hostSlug` NUNCA es null.

Y las dos únicas salidas de `JoinViaLinkScreen` van a `/`:

```dart
// join_via_link_screen.dart:141-142  (estado _Error)
onPressed: () => context.go('/'),
child: Text(tr.goHome),
// join_via_link_screen.dart:196-197  (estado _Preview)
onPressed: () => context.go('/'),
child: Text(tr.cancel),
```

`context.go('/')` vuelve a entrar al redirect, que ve `_cachedHasTenant == false` y devuelve `/join/jym770` otra vez. La pantalla no tiene botón de cerrar sesión (comparar con `tenant_code_screen.dart:204` y `tenant_suspended_screen.dart:56`, que sí lo tienen).

**Consecuencia**: Todo donante que abre app.jabadencampus.com, se registra o entra con Google, y después quiere retroceder — porque eligió la cuenta de Google equivocada, porque `validateSlug` falló por red/cold start de la CF y ve el estado de error, o simplemente porque quiere pensarlo — no tiene salida. "Cancelar" e "Ir al inicio" rebotan a la misma pantalla, y no hay forma de cerrar sesión para entrar con otra cuenta. La única salida real es borrar los datos del sitio del navegador o desinstalar la PWA, cosa que un donante no va a hacer ni sabe hacer. Es exactamente el callejón sin salida en el primer minuto de la relación con la app, en el canal de distribución principal.

**Fix propuesto**: Agregar a `JoinViaLinkScreen` un botón "Usar otra cuenta / Cerrar sesión" que llame a `ref.read(authControllerProvider).signOut()` (no `FirebaseAuth.instance.signOut()` directo, ver hallazgo del token FCM) — el `refreshListenable` del router lo lleva a `/login`. Y cambiar el destino de "Cancelar"/"Ir al inicio" a `/tenant-setup` en vez de `/`, para que caiga en la pantalla que sí tiene escotilla de salida en vez de rebotar contra el redirect.

---

## 3. [ALTO] La donación mensual que dejó de cobrarse se sigue mostrando como sana, y el aviso que el backend escribe no lo lee nadie

**Dimension**: errores-y-salida — **lib/features/payments/presentation/donation_subscriptions_screen.dart:945**

**Evidencia**: `listDonationSubscriptions` devuelve `status` por suscripción y acepta explícitamente `past_due` como activa (`functions/index.js:2448` y 2497). El cliente descarta ese campo: `_buildSubTile` (línea 873) lee id, currency, amount, interval, `currentPeriodEnd` y `cancelAtPeriodEnd` — `grep -n "status" donation_subscriptions_screen.dart` solo devuelve la línea 749, que es un literal `'status': 'active'` del tile optimista. La línea 945 pinta `tr.nextChargeOn(_formatDate(periodEnd))` sin condicionar por estado. Del lado del servidor, `invoice.payment_failed` (functions/index.js:4564-4593) solo hace `writeUserPaymentEvent(uid, ..., kind: 'donation_recurring_failed')`: escribe `users/{uid}/paymentEvents/{id}`, no manda FCM ni correo. Y ese subárbol NO lo lee ninguna línea de Flutter — `grep -rn "paymentEvents" lib` no devuelve nada, aunque `firestore.rules:776` ya le da `allow read: if isOwner(uid)`. El comentario en functions/index.js:4872 afirma "The webhook for invoice.payment_failed already notifies the user", lo cual es falso: no notifica por ningún canal.

**Consecuencia**: A un donante se le vence la tarjeta. Stripe reintenta, falla, la suscripción pasa a past_due. En la app sigue viendo su donación mensual listada con "Próximo cobro: <fecha>". No recibe push, no recibe mail, no ve un banner. Después de los reintentos Stripe la cancela y la suscripción simplemente desaparece de la lista. Estuvo meses creyendo que daba tzedaká todos los meses y no dio nada — que es exactamente el mismo daño que el correo mal tipeado: el usuario no se entera nunca.

**Fix propuesto**: Dos cosas. (1) En `_buildSubTile`, cuando `sub['status'] == 'past_due'`, reemplazar la línea de "próximo cobro" por una fila de advertencia con acción directa a Tarjetas guardadas. (2) Leer `users/{uid}/paymentEvents` (limit 10, orderBy createdAt desc) con un StreamProvider y mostrar los `kind: donation_recurring_failed` y `payment_failed` no vistos como banner en Mi Pushka; alternativamente, agregar un `sendToUser()` en el handler de invoice.payment_failed, igual que ya hace el vaciado automático.

---

## 4. [ALTO] Los mensajes de tarjeta rechazada están escritos a mano en español en una app de cuatro idiomas

**Dimension**: errores-y-salida — **lib/features/pushka/presentation/pushka_screen.dart:2873**

**Evidencia**: `_translateStripeDeclineReason` (líneas 2864-2909) devuelve literales de Dart, no claves de `S`: 'Fondos insuficientes en la tarjeta.', 'La tarjeta expiró. Probá con otra.', 'Código CVC incorrecto.', 'La tarjeta fue rechazada por el banco. Probá con otra.', etc. `S.supportedLocales` (lib/core/l10n/s.dart:11-16) declara es, en, fr y he. Este es el camino del error de pago MÁS común: `_donationErrorMessage` lo invoca en el `case 'internal'` (línea 2812), que es por donde el backend reenvía todos los declines de Stripe. El agujero es más ancho: en `failed-precondition` y `permission-denied` (líneas 2799-2805) el mensaje que se muestra es `_sanitizeUserFacingError(error.message)`, o sea el string crudo de la Cloud Function — y las 233 `HttpsError(...)` de functions/index.js están todas en español rioplatense ("Debes iniciar sesión.", "No tenés organización activa.", "El monto excede el límite permitido.", "Tu cuenta está temporalmente suspendida. Contactá a soporte."). Los tres puntos de fallo de pago (`emptyPushka` línea 481, `_donateNow` línea 913, `_processCardPayment` línea 1024) pasan por acá.

**Consecuencia**: Un donante que usa la app en inglés, francés o hebreo pone su tarjeta, se la rechazan, y lo único que recibe es una frase en español dentro de un diálogo por lo demás traducido — en hebreo además metida en un layout RTL. No sabe si el problema es la tarjeta, el monto, su cuenta o la app; no sabe si tiene que probar otra tarjeta o llamar al banco. En una app de donaciones eso se traduce en el donante que abandona y no vuelve.

**Fix propuesto**: Mover las diez frases de `_translateStripeDeclineReason` a `S` con las cuatro traducciones (el helper `_t(es, en, fr, he)` de s.dart ya está para esto) y devolver códigos, no texto. Para los mensajes que vienen del backend, que las CFs devuelvan un código estable en `details` (ej. `{code: 'amount_exceeds_limit'}`) y que el cliente lo traduzca, dejando el `message` en español solo como fallback de log.

---

## 5. [ALTO] El vaciado automático puede llevar meses fallando y la app lo muestra perfectamente sano

**Dimension**: sesion-y-confianza — **lib/features/settings/presentation/auto_empty_action_row.dart:33**

**Evidencia**: En el fallo, functions/index.js:5641-5652 escribe `autoEmptyConsecutiveFailures` (increment), `autoEmptyLastFailureAt` y `autoEmptyLastFailureCode`, y corre `autoEmptyNextRunAt` +24h. Esos tres campos se escriben y nunca se leen: `grep -rn "autoEmptyConsecutiveFailures|autoEmptyLastFailure" functions/index.js lib` devuelve solo las líneas de escritura (5647-5649, 5694-5696, 5718). El único aviso es un push (functions/index.js:5672). La fila que resume el plan, `AutoEmptyActionRow` (lib/features/settings/presentation/auto_empty_action_row.dart:25-39), muestra únicamente frecuencia + `autoEmptyNextRunAt` — que en el fallo se reescribe cada 24h, así que siempre exhibe una fecha próxima y creíble. Y activar el vaciado automático nunca pide ni verifica permiso de notificaciones: `grep -n "notification|permission" lib/features/settings/presentation/auto_empty_screen.dart` no devuelve nada, mientras que la pantalla de recordatorios sí lo gestiona con todo detalle (lib/features/reminders/presentation/reminders_screen.dart:780-798).

**Consecuencia**: El donante configura un cobro automático mensual y no da permiso de notificaciones (o lo revoca después). La tarjeta se vence. Desde ahí: cero avisos, ningún correo de fallo, y la pantalla de Cartera sigue diciendo «Mensual · 12 de octubre». Sigue metiendo monedas en su pushka virtual creyendo que se vacía sola, y no llega un peso a la organización. Los Términos (legal_content.dart, sección 6) prometen «la app te notificará».

**Fix propuesto**: Sumar correo al push en la rama de fallo (5654-5680) — un canal que no dependa de un permiso opcional. Leer `autoEmptyConsecutiveFailures`/`autoEmptyLastFailureCode` en `AutoEmptyActionRow` y pintar la fila en rojo con el motivo. Al activar el vaciado automático, pedir permiso de notificaciones con el mismo flujo de tres estados de la pantalla de recordatorios, y si lo deniegan, decir explícitamente que los avisos llegarán solo por correo.

---

## 6. [ALTO] Un correo mal escrito al registrarse deja la cuenta muerta y sin forma de arreglarla desde la app

**Dimension**: sesion-y-confianza — **lib/features/settings/presentation/settings_screen.dart:492**

**Evidencia**: El registro pide nombre, correo y contraseña sin campo de confirmación de correo (lib/features/auth/presentation/register_screen.dart, 236 líneas, campos en 65-80). En Ajustes, el correo se dibuja con `_buildProfileField(tr.emailLabel, userEmail)` — el helper de solo lectura, a diferencia de `_buildEditableField` que sí usan correo de facturación, teléfono y dirección (settings_screen.dart:492 vs 494-535). En toda la carpeta lib no existe `updateEmail` ni `verifyBeforeUpdateEmail` (`grep -rn` sin resultados). El guard nuevo `requireVerifiedEmailForPayments` (functions/index.js, commit 437a50f) rechaza el pago y reenvía el enlace a `user.email` — la dirección equivocada — con el mensaje «Te enviamos un enlace a <email>...». La app tampoco lee `emailVerified` en ninguna parte, así que no hay pantalla que explique el estado.

**Consecuencia**: Quien tipea «gmial.com» crea una cuenta que no puede donar nunca: el enlace de verificación viaja siempre al buzón inexistente, el mensaje de error le promete un correo que jamás va a llegar, y no hay ningún lugar en la app donde corregir la dirección. La única salida es borrar la cuenta y registrarse de nuevo, y nada se lo dice. Es el mismo typo del ejemplo, pero ahora con la consecuencia agravada: antes se perdía los comprobantes, ahora queda trabado.

**Fix propuesto**: Tres cosas, en orden de costo: (1) campo «confirmá tu correo» en el registro, que ataja la mayoría de los casos; (2) hacer el correo editable en Ajustes vía `verifyBeforeUpdateEmail` (Firebase solo lo aplica tras clic en el nuevo buzón, así que es seguro); (3) que el mensaje de rechazo del pago ofrezca «¿No es tu correo? Cambialo acá» en vez de solo reenviar.

---

## 7. [MEDIO] Cerrar sesión desde la pantalla del código de invitación deja el token de notificaciones vivo hasta 90 días

**Dimension**: ciclo-de-cuenta — **lib/features/tenant/presentation/tenant_code_screen.dart:206**

**Evidencia**: ```dart
// tenant_code_screen.dart:203-208
// Escape hatch: user firmado pero sin código válido puede salir y volver.
Future<void> _signOut() async {
  try {
    await FirebaseAuth.instance.signOut();   // <- salta el AuthController
  } catch (_) {}
}
```

Se saltea todo lo que `AuthController.signOut()` hace a propósito (`auth_controller.dart:132-172`), empezando por lo que su propio comentario marca como CRÍTICO:

```dart
// auth_controller.dart:134-137
// CRITICAL: revoke this device's FCM token from Firestore *before*
// FirebaseAuth.signOut(). After signOut() the auth context is gone and
// Firestore rules reject the delete (`isOwner(uid)` fails), leaving a
// stale token doc that keeps pushing to this device for the prev user.
```

Tampoco corre `HiveCache.instance.clearUser(uid)` ni `invalidateTenantCache()` (auth_controller.dart:166-171).

El doc huérfano sobrevive hasta la limpieza programada, que barre a los 90 días:
```js
// functions/index.js:4790
const staleBefore = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 90 * 24 * 60 * 60 * 1000));
```

Y lo que se sigue empujando a ese dispositivo lleva montos:
```js
// functions/index.js:4674  onTransactionCreated
tzedaka: `¡Gracias por tu donación! ${fmt(amount)}`,
pushkaEmpty: `Tu Pushka fue vaciada. Donación: ${fmt(amount)}`,
```

**Consecuencia**: Esa pantalla es justo la salida que usa quien se equivocó de cuenta o de código. Después de tocarla, el teléfono sigue registrado como dispositivo del usuario anterior: si otra persona entra con su cuenta en ese mismo teléfono — el caso normal en una casa de Jabad, un celular compartido, un dispositivo prestado — le van a seguir llegando notificaciones ajenas con montos de donación ("Tu Pushka fue vaciada. Donación: $500") y recordatorios que no son suyos, durante hasta tres meses. La app promete que cerrar sesión te desconecta; en este camino no lo cumple.

**Fix propuesto**: Cambiar `tenant_code_screen.dart:206` por `await ref.read(authControllerProvider).signOut()`, igual que hace `tenant_suspended_screen.dart:56`. Es una línea y el widget ya es `ConsumerStatefulWidget`, así que tiene `ref` a mano.

---

## 8. [MEDIO] Los consentimientos de cobro sobreviven al borrado de cuenta y quedan fuera de la exportación

**Dimension**: datos-del-donante — **functions/index.js:7389**

**Evidencia**: `deleteAccount` barre exactamente seis subcolecciones: `["transactions", "reminders", "fcmTokens", "tenantState", "paymentEvents", "savedCards"]` (functions/index.js:7389-7392). `exportUserData` enumera las mismas seis (línea 7715-7717). `users/{uid}/consents` no está en ninguna de las dos listas, y existe: la crea `recordAutoEmptyConsent` (functions/index.js:8032) y guarda `uid`, `tenantId`, el texto aceptado, y la IP del donante puesta por el servidor (`ip: trustedCallerIp(request)`, línea 8049). La regla de Firestore la reconoce (firestore.rules:786-789). Como el doc padre `users/{uid}` sí se borra (línea 7620), el resultado son subcolecciones huérfanas invisibles en la consola.

**Consecuencia**: Después de un borrado que la política describe como "borrar tus datos personales identificables" (legal_content.dart:172), queda en Firestore, indefinidamente, la dirección IP del donante junto con su uid. Y por el otro lado: el donante nunca puede ver ni llevarse la autorización de cobro recurrente que firmó, que es el único documento que le sirve si un día discute un cargo.

**Fix propuesto**: Agregar `"consents"` a las dos listas. Lo mismo con `_emailVerifications/{uid}`: si el donante nunca confirmó el código, el doc con su correo en claro (functions/index.js:13123) no se borra ni por confirmación, ni por vencimiento, ni por `deleteAccount`.

---

## 9. [MEDIO] Los Términos afirman una aceptación que la pantalla de registro nunca pide ni muestra

**Dimension**: datos-del-donante — **lib/features/legal/data/legal_content.dart:233**

**Evidencia**: Términos §1: «Al registrarte, instalar o utilizar Pushka, confirmás que leíste, entendiste y aceptás estos Términos de Servicio y la Política de Privacidad» (legal_content.dart:233). En `lib/features/auth/presentation/register_screen.dart` (236 líneas) no aparece la palabra terms, privacidad, legal ni acepta: `grep -n -i "terms|privac|legal|acepta|accept"` sobre ese archivo no devuelve nada. El único acceso a los documentos es `about_screen.dart:75` (Acerca de → Política de privacidad), que está detrás del login y de la selección de organización, y `legal_screen.dart:74` depende de `tenantConfigProvider`, o sea que ni siquiera renderiza bien antes de unirse a un tenant.

**Consecuencia**: La app declara por escrito que el donante leyó y aceptó dos documentos que en ese momento no tuvo forma de ver. Si un día hay que sostener la comisión de plataforma del 3% (Términos §4.4) o el consentimiento de tratamiento de datos, la evidencia de aceptación no existe.

**Fix propuesto**: Poner debajo del botón de registro la línea «Al crear tu cuenta aceptás los Términos y la Política de Privacidad», con los dos enlaces abriendo `LegalScreen` sin requerir tenant (pasar `tenantContactEmail: null` cuando no hay tenant todavía).

---

## 10. [MEDIO] El consentimiento del vaciado automático se toma una sola vez y después queda mintiendo

**Dimension**: datos-del-donante — **lib/features/settings/presentation/auto_empty_screen.dart:458**

**Evidencia**: `final needsConsent = _frequency != 'manual' && _savedFrequency == 'manual';` (auto_empty_screen.dart:458-460): el diálogo y el registro solo se disparan al pasar de manual a automático. Cambiar después el monto del top-off de 50 a 500, o pasar de semanal a mensual, guarda sin volver a pedir nada (`_saveConfig`, línea 1079) y sin actualizar el registro, que sigue guardando el `topOffAmount` viejo (functions/index.js:8038). Aparte, `autoEmptyConsentAt` / `autoEmptyConsentId` (functions/index.js:8065-8066) se escriben y nunca se leen: `grep -n "autoEmptyConsentAt"` da solo esas dos líneas de escritura, así que el cron de cobro no verifica que exista consentimiento antes de cobrar, y los donantes que configuraron el auto-vaciado antes del 2026-08-28 siguen con horario activo y sin registro.

**Consecuencia**: El registro existe para exhibirlo en una disputa de Stripe. Si dice que el donante autorizó 50 y el cargo fue de 500, no solo no defiende: acredita lo contrario. Y la garantía que el propio comentario del código enuncia —«si hay horario activo, hay consentimiento registrado» (functions/index.js:7984-7985)— hoy la sostiene únicamente el cliente.

**Fix propuesto**: Volver a pedir consentimiento cuando cambie el monto del top-off o la frecuencia sobre un horario ya activo (comparar contra los valores guardados, no solo contra `manual`). Y que `processPushkaAutoEmpty` exija `autoEmptyConsentAt` presente antes de cobrar, saltando y avisando a los que no lo tengan.

---

## 11. [MEDIO] El correo de contacto para ejercer derechos apunta a un dominio que el proyecto no controla

**Dimension**: datos-del-donante — **lib/features/legal/data/legal_content.dart:47**

**Evidencia**: `const String _contactEmail = 'support@pushkaapp.com';` (legal_content.dart:47) es el canal para ejercer TODOS los derechos (§9, línea 183), para pedir la copia exportable (§8, línea 173), para reclamos de menores (§11, línea 197), para reembolsos dentro de los 60 días (Términos §7, línea 278) y el contacto general (§14, línea 219). In-app se reemplaza por `tenantConfig?.contactEmail` cuando el tenant lo tiene configurado (legal_screen.dart:74), pero las páginas públicas no tienen ese override y lo llevan escrito a mano: `public/privacy/index.html:88` y :94-96, más `public/delete-account/index.html`. `nslookup` de pushkaapp.com da 198.49.23.145 (parking de Squarespace) con MX de Google Workspace; el dominio no aparece en ninguna config del proyecto (Firebase usa pushka-app-ioel.web.app, SendGrid está pendiente de autenticar jabadencampus.com) y `pushkapp.cc`, el dominio que sí se había planeado, nunca se compró.

**Consecuencia**: Un donante que quiere que le borren los datos, que reclama un cargo dentro de los 60 días o que pide su exportación escribe a un buzón de un tercero, o a ninguno. Nadie del proyecto se entera del pedido y el plazo legal de 30 días que la propia política promete corre igual.

**Fix propuesto**: Verificar quién es el titular de pushkaapp.com. Si no es del proyecto, reemplazar el literal por una dirección real de jabadencampus.com en `legal_content.dart:47` y en los cuatro `public/privacy/*` y `public/terms/*`, y probar que el buzón recibe.

---

## 12. [MEDIO] El único enlace legal de la página pública de borrado de cuenta está roto

**Dimension**: datos-del-donante — **public/delete-account/index.html:214**

**Evidencia**: `<a href="/privacy/es.html" data-i18n="privacyLink">Política de privacidad</a>` (public/delete-account/index.html:214). En `public/privacy/` los archivos son `index.html`, `en.html`, `fr.html`, `he.html` — no existe `es.html`. Con `cleanUrls: true` y `trailingSlash: false` en el target `assetlinks` de `firebase.json`, `/privacy/es.html` redirige a `/privacy/es` y termina en 404. Esta página es la URL de borrado de cuenta declarada en la ficha de Play (`docs/play-store-listing.md:143`).

**Consecuencia**: El donante que llegó a la página para borrar su cuenta y antes quiere leer qué se conserva y qué no, cae en un 404. Es el único enlace legal de esa página, y es la página que un revisor de Google abre para verificar el requisito de borrado de cuenta.

**Fix propuesto**: Cambiar el href a `/privacy` (o `/privacy/index.html`), y revisar de paso los enlaces cruzados de `public/privacy/*.html` y `public/terms/*.html`.

---

## 13. [MEDIO] Los interruptores de Ajustes mienten: el guardado falla en silencio y el usuario ve confirmación

**Dimension**: errores-y-salida — **lib/features/settings/presentation/settings_screen.dart:1820**

**Evidencia**: `_updateSettingsSilent` es literalmente "fire-and-forget": `.catchError((Object e) => debugPrint('toggle updateSettings error: $e'))` (línea 1820). Lo mismo en la meta de la pushka (línea 143), los presets (línea 1194) y el idioma (línea 1328). El patrón es siempre igual: primero `setState()` local, después la escritura, y el error solo va a `debugPrint`, que en un build release no existe. El caso peor es la biometría (líneas 437-447): tras el prompt, hace `setState(() => biometricAuthenticationEnabled = value)`, dispara `_updateSettingsSilent(...)` sin esperarla y muestra `SnackBar(tr.biometricActivated)` — "biometría activada" — pase lo que pase con Firestore. Y ese flag es el que gatea el pago: `pushka_screen.dart:2936`, `auto_empty_screen.dart:1025`, `donation_subscriptions_screen.dart:299` leen `biometricAuthenticationEnabled` del perfil, no del estado local. Que esto falle no es teórico: las reglas de `users/{uid}` usan un `hasOnly()` con ~45 campos (firestore.rules:260-315) y el comentario de las líneas 305-312 documenta el incidente real — cuando el servidor empezó a denormalizar `transactionCount`/`lastDonationAt`, TODA escritura del cliente pasó a dar PERMISSION_DENIED apenas el usuario donaba una vez. Nadie se enteró justamente por este catchError. La memoria del proyecto registra el mismo tipo de bug otras dos veces (moneda/presets/meta, auto-vaciado). La propia app ya tiene el patrón correcto en otro lado: `pushka_screen.dart:3474-3484` distingue timeout, `unavailable` y error genérico y avisa con `_showError`.

**Consecuencia**: El donante prende la biometría, lee "biometría activada", y sus donaciones nunca piden huella — ni ese día ni nunca. Igual con la meta, los presets y el idioma: quedan puestos hasta que cierra la app y vuelven al valor viejo, sin ninguna explicación. Y si vuelve a aparecer un desajuste de reglas como el de `transactionCount`, la app entera deja de guardar preferencias y el equipo se entera por un ticket de soporte, no por un error.

**Fix propuesto**: Hacer `_updateSettingsSilent` asíncrono con manejo real: si la escritura falla, revertir el `setState` al valor anterior y mostrar un SnackBar con acción "Reintentar" (el mismo `_showError` que ya usa `_syncTzedakahSettings`). En el caso de la biometría, mostrar `tr.biometricActivated` SOLO después de que la escritura resuelva OK. Aplicar lo mismo a las líneas 143, 1194 y 1328.

---

## 14. [MEDIO] El spinner del express checkout puede quedarse trabado para siempre con la app inutilizable

**Dimension**: errores-y-salida — **lib/features/payments/stripe_service.dart:371**

**Evidencia**: En el camino de express checkout se abre un diálogo modal con `barrierDismissible: false` y `useRootNavigator: true` (líneas 378-386), cuyo contenido es `_ExpressProgressDialog` (línea 1032): un `PopScope(canPop: false)` con un `CircularProgressIndicator` pelado, sin una sola línea de texto. La única forma de cerrarlo es `closeProgress()` (línea 371), que hace `if (sheetContext.mounted) { Navigator.of(sheetContext, rootNavigator: true).pop(); }`. Si `sheetContext` (el context de PushkaScreen) se desmontó mientras `Stripe.instance.confirmPayment` estaba en vuelo, el `pop()` no se ejecuta nunca y el diálogo queda vivo en el navigator raíz. Eso es alcanzable: `router.go(route)` se dispara desde afuera de la UI por notificación (`app/router.dart:301-310`, `NotificationService.instance.onNavigate`) y por deep link, y PushkaScreen vive dentro de un `ShellRoute` cuyo child se reemplaza al navegar, así que se dispone. Ninguna de las tres salidas de `confirmPayment` (éxito línea 397, `StripeException` línea 405, catch genérico 428) usa un `finally` ni una referencia de navigator capturada antes del await; las tres dependen del mismo guard de `mounted`. Tampoco hay `.timeout()` sobre `confirmPayment`.

**Consecuencia**: El donante toca "Confirmar", le entra una notificación (un recordatorio de la propia app, por ejemplo), la toca, vuelve a la app y se encuentra con una rueda girando sin texto, sin botón, con el botón Atrás anulado y sin saber si le cobraron. La única salida es matar la app desde el administrador de tareas. Es el peor momento posible para dejar a alguien sin salida: justo cuando acaba de autorizar un cargo.

**Fix propuesto**: Capturar `final rootNav = Navigator.of(sheetContext, rootNavigator: true);` ANTES del `showDialog` y cerrar con `rootNav.pop()` desde un bloque `finally`, sin depender de `sheetContext.mounted`. Agregar texto al diálogo ("Procesando tu donación, no cierres la app") y un `.timeout()` sobre `confirmPayment` que resuelva en un error manejable en lugar de esperar indefinidamente.

---

## 15. [MEDIO] La biometría promete abrir la app y no abre nada; y se apaga sin biometría

**Dimension**: sesion-y-confianza — **lib/features/settings/presentation/settings_screen.dart:435**

**Evidencia**: La Política de Privacidad que la app muestra dice, textual (lib/features/legal/data/legal_content.dart:120): «la autenticación biométrica **para abrir la app** se procesa exclusivamente en tu dispositivo». No existe ningún bloqueo al abrir: `lib/app/router.dart` no tiene ruta ni redirect de lock, y `BiometricService` solo se llama en donar/vaciar/suscribir (pushka_screen.dart:405, 823, 1051; donation_subscriptions_screen.dart:701; auto_empty_screen.dart:464). Peor: el toggle solo autentica al ENCENDER (settings_screen.dart:435-441 — `if (value) { final success = await _authenticateWithBiometrics(); ... }`); apagarlo no pide nada. Además `_biometricEnabled()` lee un booleano del perfil (pushka_screen.dart:2926-2936) — es una decisión 100% del cliente, ninguna CF de pago la conoce.

**Consecuencia**: Alguien con el teléfono desbloqueado en la mano (robo con la pantalla abierta, un chico, un compañero de cuarto) entra a Ajustes, apaga el candado en dos toques y vacía la pushka o dona con la tarjeta guardada. La protección que el usuario cree haber activado —y que la política le dice que le pide huella al abrir la app— no le cubre ninguno de los dos escenarios que imagina: ni abrir la app, ni impedir que se la desactiven.

**Fix propuesto**: Elegir una de las dos y hacerla verdad. Lo honesto es implementar el bloqueo al abrir (gate biométrico en el shell tras `resumed`, con re-prompt por timeout) y exigir biometría también para APAGAR el toggle. Si no se implementa el bloqueo de apertura, corregir el texto de legal_content.dart:120 y renombrar el toggle a algo que describa lo que hace de verdad («Pedir huella para donar y vaciar»).

---

## 16. [MEDIO] Nadie ve los Términos ni la Privacidad antes de crear la cuenta, aunque los Términos digan que al registrarse los aceptó

**Dimension**: sesion-y-confianza — **lib/features/auth/presentation/register_screen.dart:48**

**Evidencia**: `grep -n "terms|Terms|privacy|Privacy|legal|Legal|acept" lib/features/auth/presentation/*.dart` no devuelve una sola línea: ni el login ni el registro mencionan o enlazan los documentos legales. La pantalla de registro (register_screen.dart:41-111) es título, subtítulo, tres campos y un botón. Los Términos, sin embargo, afirman en su sección 1 (lib/features/legal/data/legal_content.dart, «Al registrarte, instalar o utilizar Pushka, confirmás que leíste, entendiste y aceptás estos Términos de Servicio y la Política de Privacidad»). El único acceso es Ajustes → Acerca de → los dos enlaces de about_screen.dart:73-83, ya con sesión iniciada. Tampoco se guarda constancia de aceptación (ninguna escritura de `termsAcceptedAt` en user_repository.dart:87).

**Consecuencia**: El donante entrega nombre, correo y después una tarjeta sin haber tenido delante —ni siquiera como enlace— qué se hace con sus datos, quién cobra, cuál es la política de reembolsos ni que hay comisión. Es justo el punto donde una app de dinero se gana o se pierde la confianza, y la cláusula de aceptación que la propia app distribuye no se sostiene: no hubo nada que leer.

**Fix propuesto**: Debajo del botón «Crear cuenta», una línea con los dos documentos enlazados a `LegalScreen` («Al crear tu cuenta aceptás los Términos y la Política de Privacidad»). Y guardar `termsAcceptedAt` + la fecha de revisión del documento en el doc de usuario, para poder pedir re-aceptación cuando cambien de verdad.

---

