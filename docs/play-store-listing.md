# Ficha de Google Play — Jabad en Campus

Estado: **borrador cálido listo, con tres arreglos de política pendientes de
integrar.** Última revisión: 2026-09-02.

La misión que define este texto está en la memoria del proyecto
(`project_mision_jabad_en_campus`). Reglas fijas decididas por Ioel:

1. **"Jabad en Campus" presente y notorio**, no como pie de página.
2. **Nada de deducción de impuestos** ni beneficio fiscal.
3. **Nada que sugiera que otras organizaciones vayan a usar la app.**
4. **Nada de encabezados en mayúscula ni listas de viñetas.** El texto tiene
   que sonar a persona, no a hoja de especificaciones. Esta regla se agregó el
   2026-09-02 y es la que más cuesta respetar: cada revisión de cumplimiento
   tiende a devolver el texto a formato formulario.
5. **Español de México.** No "asado" sino *carne asada*; no "chicos" sino
   *chavos*; no "se viene" sino *se acerca*; "apuro" en México es aprieto, no
   prisa. Cero voseo.

---

## Nombre de la app (máx. 30) — 24 caracteres

```
Jabad en Campus — Pushka
```

La marca va primero: en los resultados de búsqueda de Play el título se ve
solo, sin descripción, y quien busca a la organización tiene que reconocerla.
Alternativa sin em dash (22 car.): `Pushka Jabad en Campus` — sirve si al
pegar desde WhatsApp el "—" se convierte en dos guiones.

**Pendiente**: que el Rab lo confirme.

## Descripción corta (máx. 80) — 69 caracteres

```
La pushka de Jabad en Campus: la alcancía de siempre, en tu teléfono.
```

## Descripción completa — borrador actual, 2253 de 4000 caracteres

> Play muestra solo las **tres primeras líneas** antes del botón "Más
> información". El primer párrafo mide 246 caracteres, así que entra entero:
> quien no toca nada ya leyó marca, ciudad, misión, tzedaká y la palabra
> pushka.

```
En Jabad en Campus trabajamos con jóvenes judíos de Ciudad de México que crecieron lejos de sus raíces. Los invitamos a un Shabat, a una carne asada, a ponerse tefilín por primera vez. Todo eso se sostiene con tzedaká, y esta app es nuestra pushka.

Un viernes cualquiera hay jalá en la mesa, ensaladas, dos que discuten de futbol y alguien acomodando sillas de más. Siempre faltan sillas. Nadie los apura y nadie los juzga. Hay chavos que vienen una vez y ya; otros llegaron porque un amigo les insistió, todavía no saben bien a qué, y a las once de la noche siguen ahí.

Una pushka es la alcancía de tzedaká que hay en toda casa judía. Se echa una moneda antes de salir, antes de Shabat, cuando pasa algo bueno. Esta es la de Jabad en Campus, ahora en tu teléfono.

Funciona igual que la de la cocina. Tocas uno de los montos que ya están puestos y la moneda se va juntando ahí adentro. Todavía no pasa nada. El día que quieres, la vacías y lo que juntaste se dona a Jabad en Campus.

Y si te conoces y sabes que se te va a pasar, deja que se vacíe sola: cada semana, cada mes o en Erev Rosh Jodesh, que es cuando muchos ya tienen la costumbre de dar. Si te sirve que te lo recordemos, te lo recordamos.

La app lleva la cuenta de los días seguidos que llevas dando. Una meta, si te gusta ponerte metas. Y todo lo que diste queda guardado, por si algún día quieres mirarlo. El Rab lo dice así: en la tzedaká cuenta la constancia, no el monto.

Adentro hay también segulot y rezos, y un aviso cuando se viene una festividad, por si el calendario hebreo te agarra desprevenido (nos pasa a todos). Está en español, inglés, francés y hebreo, para que cada quien la use en el idioma en que reza.

Por qué la app te pide un código

Porque no es una app abierta a cualquiera. Es de Jabad en Campus y es para la gente de Jabad en Campus. El código de invitación te lo da el Rab; sin él no se entra. Si llegaste hasta aquí y no lo tienes, pídeselo.

Los pagos los procesa Stripe. La app nunca guarda los datos de tu tarjeta: si dejas una guardada para no volver a escribirla, queda del lado de Stripe.

Lo que se junta entre todos sostiene la comida del viernes y la gasolina de ir a buscar a alguien que no tiene cómo llegar. Y las sillas, que siempre faltan.
```

---

# ⚠️ NO ENVIAR ASÍ — tres arreglos de política pendientes

Una revisión adversarial del 2026-09-02 (dos críticos: uno de naturalidad,
otro haciendo de revisor de Google) encontró **dos motivos de rechazo
probables** y un tercer riesgo. Ninguno es de estilo. Sobran 1.747 caracteres,
así que todo entra sin sacrificar nada.

## 1. Falta decir "sin fines de lucro" y "donaciones voluntarias" — RECHAZO

El más importante. La app cobra **por fuera de Google Play Billing** (vía
Stripe). Lo único que lo permite es la excepción de la política de pagos para
donaciones a organizaciones sin fines de lucro. El revisor abre la ficha, ve
que se mueve dinero dentro de la app, no encuentra en ningún lado las palabras
"sin fines de lucro" ni "donación voluntaria", y clasifica el cobro como venta
de contenido digital eludiendo Play Billing.

Peor todavía si sospecha que el dinero desbloquea algo (metas, rachas,
segulot, historial): eso es rechazo directo.

Hay que decirlo **en el texto de la ficha**, no solo en el formulario:

> Jabad en Campus es una organización judía sin fines de lucro. Las donaciones
> son voluntarias y no desbloquean funciones ni contenido dentro de la app.

"Sin fines de lucro" no es una afirmación fiscal ni promete deducción — es la
categoría de la organización, que es justo lo que Play necesita ver. No viola
la regla 2.

## 2. El auto-vaciado es un cargo recurrente no divulgado — RECHAZO + disputas

La ficha dice "deja que se vacíe sola" y nunca menciona que eso implica un
**cobro automático a una tarjeta guardada**, ni que se puede desactivar. Play
exige que los cargos recurrentes se declaren de forma clara y visible;
esconderlos detrás de una metáfora entra en "cobros no divulgados".

Y aparte del rechazo: es el disparador clásico de "me cobraron sin avisar" y de
contracargos contra la cuenta de Stripe del Rab.

Hay que decir que hay cobro automático, a qué tarjeta, y que se apaga cuando
uno quiere.

## 3. "La app nunca guarda los datos de tu tarjeta" contradice el Data Safety

En el formulario hay que declarar que la app maneja información de pago: guarda
marca y últimos cuatro dígitos para poder mostrar la tarjeta en pantalla. Play
cruza automáticamente la ficha contra el formulario, y una inconsistencia es
rechazo por *data safety mismatch*.

La formulación correcta no es más débil, es más precisa: la app no guarda el
**número**; la tarjeta vive del lado de Stripe y aquí solo se ven marca y
últimos cuatro dígitos.

**Antes de escribirlo hay que verificar en el código qué se guarda
exactamente.** No copiar esa frase a ciegas.

## Además, dos cosas que no son rechazo pero conviene arreglar

- **"Porque no es una app abierta a cualquiera"** suena a club cerrado y es lo
  contrario de la misión. Mejor: es la pushka de una comunidad, no una app de
  donaciones abierta al público, y el código es gratuito igual que la app.
- **"sostiene la comida del viernes y la gasolina"** afecta el dinero a
  partidas concretas que no se pueden garantizar. La regla es siempre *ayuda a
  sostener*, nunca *financia*.

## Cómo integrarlo — la parte difícil

El crítico de reglas devolvió una versión completa con todo esto adentro
(3.054 caracteres) **pero reintrodujo los encabezados en mayúscula y las
viñetas**, que es exactamente lo que Ioel rechazó. Esa versión quedó guardada
en `docs/play-store-listing-contenido-politica.txt` y sirve como fuente del
**contenido, no del formato**.

El trabajo de mañana es meter el contenido de política dentro de la prosa
cálida, sin volver al formato formulario.

## Arreglos de estilo que quedaron sin aplicar

Del crítico de naturalidad, los tres que más delatan:

- **"Nadie los apura y nadie los juzga"** — paralelismo perfecto y emoción
  declarada en vez de mostrada. Propuesta: *"Nadie pregunta hace cuánto no
  pisan una sinagoga."*
- **"Porque no es una app abierta a cualquiera. Es de Jabad en Campus y es para
  la gente de Jabad en Campus."** — el molde "es de X y es para X" suena a
  eslogan y no explica la razón real.
- **"Y las sillas, que siempre faltan"** como cierre — callback textual puesto
  a redondear; la estructura circular perfecta es sello de prosa generada.

Y dos correcciones de español mexicano: *"se viene una festividad"* → **"se
acerca"**; *"te agarra desprevenido"* → **"te toma desprevenido"**.

## Funciones que se perdieron en la reescritura

Ninguna es motivo de rechazo, pero son las que convencen al que duda: montos
rápidos editables, elección de moneda (pesos, dólares, shékels), biometría
antes de donar o vaciar, y comprobante por correo de cada donación.

---

## Datos del formulario

| Campo | Valor |
|---|---|
| Categoría | Estilo de vida |
| Etiquetas | Donaciones, Comunidad, Religión |
| Tipo | App (no juego) |
| Precio | **Gratis** — las donaciones son pagos a un tercero por Stripe, no compras dentro de la app |
| Clasificación | Todos |
| Email de contacto | jymmexico@gmail.com |
| Política de privacidad | https://pushka-landing.web.app/privacidad/ |
| Borrado de cuenta | https://pushka-landing.web.app/delete-account/ |
| Público objetivo | 18+ |
| Anuncios | No contiene |

## Recursos gráficos

| Recurso | Archivo | Estado |
|---|---|---|
| Ícono 512×512 | `docs/store-assets/play-icon-512.png` | listo, sin alfa |
| Gráfico destacado 1024×500 | `docs/store-assets/play-feature-graphic-1024x500.png` | listo |
| Capturas | `docs/store-assets/screenshots/play/` | listas — ver el README de esa carpeta |

Las capturas están recortadas a 1080×2160 porque **Play rechaza toda imagen
cuyo lado mayor supere el doble del menor**, y el screenshot nativo del S25 es
1080×2340 (2,17). La principal está en dos versiones, oscura y clara, para
elegir.

## Antes de enviar

- [ ] Integrar los tres arreglos de política de arriba
- [ ] Aplicar los arreglos de estilo y las dos correcciones de mexicano
- [ ] El Rab aprueba el nombre y el texto
- [ ] **Play Console → Contenido de la app → Acceso a la app**: cargar mail,
      contraseña **y el código de invitación JYM-770** de
      `play-review@jabadencampus.com`. Sin el código el revisor se estrella
      contra la pantalla de invitación y rechaza sin leer la descripción.
- [ ] Data Safety completo — `docs/play-store-data-safety.md`
- [ ] Build de tienda: `flutter build appbundle --flavor prod` **sin**
      `APP_CHECK_PROVIDER=debug` (ver la advertencia en `CLAUDE.md`)
