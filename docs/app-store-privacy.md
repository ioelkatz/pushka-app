# Privacidad de la app — hoja de respuestas para App Store Connect

Equivalente de [play-store-data-safety.md](play-store-data-safety.md) para el
cuestionario de Apple. Las categorías **no son las mismas** que las de Google,
así que esto no es una traducción: es un mapeo.

Se completa en App Store Connect → tu app → **App Privacy**.

---

## Lo primero, porque decide todo lo demás: ¿la app "rastrea"?

**No.** Y conviene entender por qué, porque la palabra engaña.

Para Apple, *tracking* tiene un significado estrecho y concreto: cruzar los
datos del usuario con datos de **terceros** para publicidad dirigida, o
venderlos a un corredor de datos. No significa "recolectar datos" ni "usar
analítica".

Pushka no hace nada de eso. No hay red publicitaria, no se comparte nada con
terceros independientes, y **el identificador de publicidad (IDFA) no se
recolecta**: no está `google_mobile_ads` en el proyecto, y Firebase Analytics
dejó de tomar el IDFA por su cuenta hace varias versiones mayores.

Entonces, en TODAS las categorías de abajo: **"Used to Track You" = No.**

> ⚠️ **Consecuencia práctica que conviene mirar**: si nada se usa para
> rastrear, el prompt de App Tracking Transparency **no es obligatorio**. Hoy
> la app lo muestra al arrancar (`app_initializer.dart`), con un comentario
> que dice que Apple rechaza apps con SDKs tipo IDFA sin preguntar — premisa
> que ya no se sostiene. Es una pregunta incómoda apenas abrís una app de
> tzedaká, y cuesta conversión.
>
> **Antes de sacarlo hay que confirmar una sola cosa sobre el binario real:
> que `AdSupport.framework` no esté enlazado.** Eso se ve recién cuando haya
> un build de iOS. Si no está, el prompt sale sin costo alguno.
>
> Ojo con lo que se pierde: hoy ese prompt también sirve de consentimiento
> para Analytics y Crashlytics — si el usuario dice que no, se apagan los dos.
> Si se saca el prompt, hay que decidir si ese consentimiento se pide de otra
> forma o se deja de pedir.

---

## Resumen de las respuestas

Para cada dato: **recolectado sí**, **vinculado al usuario sí**, **usado para
rastrear no**, salvo donde se aclare.

"Vinculado" es literal: todo cuelga del `uid` de Firebase Auth, así que la
respuesta honesta es que sí en casi todo.

### Contact Info

| Dato de Apple | Recolectado | Propósito | Dónde vive |
|---|---|---|---|
| Name | Sí | App Functionality | `users/{uid}.displayName` |
| Email Address | Sí | App Functionality | `users/{uid}.email` |
| Phone Number | Sí | App Functionality | `users/{uid}.phoneNumber`, opcional |
| Physical Address | Sí | App Functionality | `users/{uid}.mailingAddress`, opcional |

### Financial Info

| Dato de Apple | Recolectado | Propósito |
|---|---|---|
| Payment Info | Sí | App Functionality |

Mismo razonamiento que en la ficha de Google: la app **nunca ve ni guarda** el
número de tarjeta —se ingresa en la hoja del SDK de Stripe, que lo tokeniza
contra sus servidores, y el backend solo maneja identificadores y los últimos
cuatro dígitos— pero esa hoja se muestra **dentro** de la app, no en un
navegador externo. Declarar de más no tiene costo; declarar de menos, sí.

### Purchases

| Dato de Apple | Recolectado | Propósito |
|---|---|---|
| Purchase History | Sí | App Functionality |

Es el historial de donaciones. Apple llama "purchases" a esto aunque no haya
compra: no hay categoría mejor.

### User Content

| Dato de Apple | Recolectado | Propósito |
|---|---|---|
| Photos or Videos | Sí | App Functionality |
| Other User Content | Sí | App Functionality |

La foto de perfil es opcional. "Other User Content" son los textos libres:
dedicatorias de donaciones, etiquetas de recordatorios, apodos de tarjetas.

### Identifiers

| Dato de Apple | Recolectado | Propósito |
|---|---|---|
| User ID | Sí | App Functionality, Analytics |
| Device ID | Sí | App Functionality |

El Device ID es el token de APNs/FCM, que sin él no hay notificaciones.

### Usage Data

| Dato de Apple | Recolectado | Propósito |
|---|---|---|
| Product Interaction | Sí | Analytics |

Eventos de Firebase Analytics. **No** marcar "Advertising Data": no hay
publicidad en la app.

### Diagnostics

| Dato de Apple | Recolectado | Propósito |
|---|---|---|
| Crash Data | Sí | Analytics |
| Performance Data | Sí | Analytics |

Firebase Crashlytics.

---

## Lo que NO hay que declarar

Verificado en el `Info.plist` y en el código: la app **no** accede a
ubicación, contactos, calendario, salud, navegación ni búsquedas.

Las claves de permisos que sí están y por qué ninguna agrega un tipo de dato:

```
NSFaceIDUsageDescription        desbloqueo local
NSPhotoLibraryUsageDescription  foto de perfil — ya declarado como Photos
NSCameraUsageDescription        idem, si la toma en el momento
NSMicrophoneUsageDescription    lo arrastra image_picker, no se usa
NSUserTrackingUsageDescription  ver la nota del principio
```

**La biometría no se declara.** `local_auth` delega en el sistema operativo y
la app solo recibe un booleano: nunca toca la huella ni el rostro. Face ID no
es un dato recolectado.

---

## Dos cosas que hay que tener listas además del cuestionario

**La URL de la política de privacidad.** Es obligatoria y tiene que abrir sin
login: `https://pushka-app-ioel.web.app/privacy/`

**La respuesta sobre el borrado de cuenta.** Apple exige que toda app con
registro permita borrar la cuenta *desde adentro*. Está hecho
(Configuración → Eliminar cuenta, más la URL pública
`/delete-account/`), pero aparece como pregunta aparte y conviene no
improvisarla.

---

## Coherencia con Google

Las dos fichas tienen que contar la misma historia. Si Apple dice que no se
recolecta algo que en Play sí figura, es una señal de alarma para los dos
revisores —y además una de las dos estaría mal. Ante cualquier cambio futuro
en los SDKs, actualizar **las dos**.
