# Seguridad de los datos — hoja de respuestas para Google Play

Respuestas para el formulario **Política y programas → Contenido de la app →
Seguridad de los datos** en Play Console.

Auditado contra el código el **2026-09-02**. Si se agrega o quita un SDK, o
cambian los campos que se guardan del usuario, **hay que volver a revisar este
documento y el formulario**: declarar de menos es motivo de suspensión.

---

## Antes de empezar: las tres URLs

Las tres están vivas y verificadas:

```
Política de privacidad   https://chabad-admin.web.app/privacy
Términos                 https://chabad-admin.web.app/terms
Borrado de cuenta        https://chabad-admin.web.app/delete-account
```

⚠️ Cuando el sitio institucional esté completo conviene moverlas a
`jabadencampus.com`. Google exige que la política de privacidad sea accesible
**sin iniciar sesión** y que no dé 404 nunca — si se cae, la app se baja.

---

## Preguntas generales

| Pregunta | Respuesta |
|---|---|
| ¿La app recopila o comparte datos del usuario? | **Sí** |
| ¿Los datos están cifrados en tránsito? | **Sí** — todo va por HTTPS/TLS: Firebase, Cloud Functions y Stripe |
| ¿El usuario puede pedir que se borren sus datos? | **Sí** — hay borrado de cuenta dentro de la app (`deleteAccount`) y una URL pública |
| ¿La app está dirigida a niños? | **No** |
| ¿Hubo una revisión de seguridad independiente? | **No** |

---

## Tipos de datos a declarar

Para cada uno: **recopilado sí**, **compartido no**, salvo donde se aclare.
"Compartido" en el vocabulario de Google significa transferir a un tercero
*independiente* — un proveedor que procesa por cuenta tuya (Firebase, Stripe)
**no cuenta como compartir**.

### Información personal

| Dato | Recopilado | Obligatorio | Propósito | Dónde |
|---|---|---|---|---|
| Nombre | Sí | Sí | Funciones de la app, gestión de la cuenta | `users/{uid}.displayName`, viene de Google Sign-In |
| Correo electrónico | Sí | Sí | Funciones de la app, gestión de la cuenta, comunicaciones | `users/{uid}.email` |
| Teléfono | Sí | **No** | Funciones de la app | `users/{uid}.phoneNumber`, lo carga el usuario |
| Dirección postal | Sí | **No** | Funciones de la app | `users/{uid}.mailingAddress`, para recibos |
| IDs de usuario | Sí | Sí | Funciones de la app, gestión de la cuenta, estadísticas | `uid` de Firebase Auth |

### Fotos

| Dato | Recopilado | Obligatorio | Propósito |
|---|---|---|---|
| Fotos | Sí | **No** | Funciones de la app — foto de perfil opcional vía `image_picker` → Firebase Storage |

### Información financiera

| Dato | Recopilado | Obligatorio | Propósito |
|---|---|---|---|
| Historial de compras | Sí | Sí | Funciones de la app — el historial de donaciones del usuario |

⚠️ **"Información de pago" (datos de tarjeta): este es el punto delicado.**

La app **nunca ve ni almacena** el número de tarjeta. Se ingresa en la hoja de
pago del SDK de Stripe, que lo tokeniza contra sus servidores; el backend solo
maneja identificadores (`pm_...`, `acct_...`) y los últimos cuatro dígitos.

Google no exige declarar datos recopilados por un procesador de pagos al que el
desarrollador no tiene acceso. **Pero la hoja de Stripe se muestra dentro de la
app**, no en un navegador externo, así que la lectura no es del todo unívoca.

**Recomendación: declarar "Información de pago" como recopilada, no
compartida, con propósito "Funciones de la app"**, y aclarar en la política de
privacidad que la procesa Stripe y que la app no la almacena. Declarar de más
acá no tiene costo; declarar de menos, sí.

### Actividad en la app

| Dato | Recopilado | Obligatorio | Propósito |
|---|---|---|---|
| Interacciones con la app | Sí | **No** | Estadísticas — eventos de Firebase Analytics |

Eventos que se registran: `purchase`, `pushka_empty`, `donation_initiated`,
`donation_failed`, `donation_canceled`. Los parámetros son monto, moneda,
`tenant_id`, medio de pago y destino de la donación. **No viajan datos
personales** en los parámetros.

### Información y rendimiento de la app

| Dato | Recopilado | Obligatorio | Propósito |
|---|---|---|---|
| Registros de fallos | Sí | **No** | Estadísticas — Firebase Crashlytics |
| Diagnósticos | Sí | **No** | Estadísticas — Crashlytics + Analytics |

### Identificadores del dispositivo

| Dato | Recopilado | Obligatorio | Propósito |
|---|---|---|---|
| ID del dispositivo | Sí | **No** | Funciones de la app (token FCM para notificaciones), estadísticas |

---

## Lo que NO hay que declarar

Verificado en el manifest y en el código: la app **no** accede a ubicación,
contactos, calendario, SMS, llamadas, micrófono ni actividad física.

Permisos declarados en el manifest, y por qué ninguno agrega un tipo de dato:

```
INTERNET                 red
POST_NOTIFICATIONS       notificaciones
READ_MEDIA_IMAGES        foto de perfil — ya declarado como "Fotos"
READ_EXTERNAL_STORAGE    idem, compatibilidad con Android viejo
RECEIVE_BOOT_COMPLETED   reprogramar recordatorios al reiniciar
SCHEDULE_EXACT_ALARM     recordatorios a la hora exacta
USE_BIOMETRIC            desbloqueo local; el dato biométrico NUNCA sale
USE_FINGERPRINT          idem
```

La biometría **no se declara**: `local_auth` delega en el sistema operativo y
la app solo recibe un booleano. Nunca accede a la huella ni al rostro.

---

## Otras declaraciones de "Contenido de la app"

| Sección | Respuesta |
|---|---|
| Anuncios | **No contiene anuncios** |
| Funciones financieras | **Ninguna** — ver el razonamiento investigado en la memoria del proyecto |
| App de noticias | No |
| App gubernamental | No |
| COVID-19 | No |
| Público objetivo | Mayores de 18 — requiere tarjeta |

### ⚠️ Acceso a la app — el que hace rebotar la primera revisión

Pushka exige **iniciar sesión y además un código de invitación**. Si no se le
dan credenciales al revisor, abre la app, choca contra el login y rechaza por
"no pudimos revisar la funcionalidad".

Hay que declarar que **todas las funciones están restringidas** y entregar las
credenciales de la cuenta de prueba.

**La cuenta ya está creada** (2026-09-02) en la app de producción:

```
Usuario        play-review@jabadencampus.com
Contraseña     está en la memoria del proyecto, no en el repositorio
Instrucciones  Iniciar sesión con correo y contraseña (NO con Google).
               Cuando la app pida el código de invitación, ingresar JYM-770.
```

⚠️ **Que sea con correo y contraseña, no con Google Sign-In.** La app acepta
los dos, pero si el revisor entra con una cuenta de Google desde los centros de
datos de Google, salta la verificación de seguridad de la propia Google y queda
trabado — y termina reportando que la app no funciona.

⚠️ **No borrar esa cuenta**: Google la usa en cada revisión, también en las
actualizaciones futuras.
