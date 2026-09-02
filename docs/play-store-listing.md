# Ficha de Google Play — Jabad en Campus

Estado: **texto final, listo para que lo apruebe el Rab.** Última revisión:
2026-09-02.

La misión que define este texto está en la memoria del proyecto
(`project_mision_jabad_en_campus`). Reglas fijas decididas por Ioel:

1. **"Jabad en Campus" presente y notorio**, no como pie de página.
2. **Nada de deducción de impuestos** ni beneficio fiscal.
3. **Nada que sugiera que otras organizaciones vayan a usar la app.**
4. **Nada de encabezados en mayúscula ni listas de viñetas.** El texto tiene
   que sonar a persona, no a hoja de especificaciones. Esta regla se agregó el
   2026-09-02 y es la que más cuesta respetar: cada revisión de cumplimiento
   tiende a devolver el texto a formato formulario.
5. **Español de México.** No "chicos" sino *chavos*; no "se viene" sino *se
   acerca*; no "nafta" sino *gasolina*; "apuro" en México es aprieto, no prisa.
   Cero voseo. **Excepción decidida por Ioel: "asado", no "carne asada"** —
   se lo propuse y prefirió su palabra.

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

## Descripción completa — 2963 de 4000 caracteres

> Play muestra solo las **tres primeras líneas** antes del botón "Más
> información". El primer párrafo mide 189 caracteres, así que entra entero.
> La palabra "pushka" ya no aparece ahí — Ioel prefirió cerrar el párrafo en la
> misión — pero sí está en la descripción corta, que Play muestra siempre
> arriba de todo.

```
En Jabad en Campus trabajamos con jóvenes judíos de Ciudad de México que crecieron lejos de sus raíces. Los invitamos a un Shabat, a un asado, a ponerse tefilín, a conectar con su judaísmo.

Un viernes cualquiera hay jalá en la mesa, ensaladas, dos que discuten de futbol y alguien acomodando sillas de más. Siempre faltan sillas. Nadie pregunta hace cuánto no pisan una sinagoga. Hay chavos que vienen una vez y ya; otros llegaron porque un amigo les insistió, todavía no saben bien a qué, y a las once de la noche siguen ahí.

Una pushka es la alcancía de tzedaká que hay en toda casa judía. Se echa una moneda antes de salir, y el viernes antes de que entre Shabat. También cuando nace un sobrino o alguien sale bien de una operación.

La de la app funciona igual que la de la cocina. Tocas uno de los montos que ya están puestos, o los cambias por los tuyos, y se va juntando ahí adentro. No se te cobra nada en ese momento. El día que tú decides, vacías la pushka y se hace un solo cargo por el total, que se dona a Jabad en Campus.

Si prefieres no estar pendiente, puedes programar que se vacíe sola cada semana, cada mes o en Erev Rosh Jodesh, que es cuando muchos ya tienen la costumbre de dar. Ahí sí hay un cobro automático a la tarjeta que elijas: te llega el aviso cada vez que pasa, y puedes cambiarlo o apagarlo cuando quieras desde Ajustes. O te mandamos nada más un recordatorio y la vacías tú.

La app cuenta los días seguidos que llevas dando, y puedes ponerte una meta al mes y ver cuánto te falta. Todo lo que diste queda en el historial, con comprobante por correo de cada donación. El Rab lo dice así: en la tzedaká cuenta la constancia, no el monto.

Adentro hay también tefilot y segulot para leer, y un aviso cuando se acerca una festividad, por si el calendario hebreo te toma desprevenido. Puedes dar en pesos, dólares, shékels u otras monedas, y pedir huella o reconocimiento facial antes de donar o de vaciar. Está en español, inglés, francés y hebreo, para que cada quien la use en el idioma en que reza.

Por qué la app te pide un código

Porque es la pushka de una comunidad, no una app de donaciones abierta al público: lo que entra acá va a Jabad en Campus y a nadie más, y quien da tiene derecho a saber exactamente a dónde va. El código de invitación te lo da el Rab, y es gratis, igual que la app. Si llegaste hasta aquí y no lo tienes, escríbele y te lo pasa.

Los pagos los procesa Stripe. Tu tarjeta se escribe en la pantalla de Stripe y queda de su lado: en la app solo se ven la marca y los últimos cuatro dígitos, y puedes borrarla, o borrar tu cuenta entera, cuando quieras.

Jabad en Campus es una organización judía sin fines de lucro. Las donaciones son voluntarias y no desbloquean funciones ni contenido dentro de la app. Lo que se junta entre todos ayuda a sostener el trabajo en Ciudad de México: los Shabatot, las comidas del viernes, ir a buscar a quien no tiene cómo llegar. Y las sillas, que siempre faltan.
```

---

# Qué se resolvió en este texto

Una revisión adversarial del 2026-09-02 (un crítico de naturalidad y otro
haciendo de revisor de Google) encontró dos motivos de rechazo probables. Los
dos están resueltos arriba.

## 1. Faltaba "sin fines de lucro" y "donaciones voluntarias" — resuelto

Era el más grave. La app cobra **por fuera de Google Play Billing** vía Stripe,
y lo único que lo permite es la excepción de la política de pagos para
donaciones a organizaciones sin fines de lucro. Sin esas palabras en la ficha,
el revisor ve que se mueve dinero dentro de la app, no encuentra la excepción, y
clasifica el cobro como venta de contenido digital eludiendo Play Billing.

Peor todavía si sospecha que el dinero desbloquea algo (metas, rachas, segulot,
historial). Por eso el último párrafo dice explícitamente que las donaciones
**no desbloquean funciones ni contenido**.

"Sin fines de lucro" es la categoría de la organización, no una afirmación
fiscal: no promete deducción y no viola la regla 2.

## 2. El auto-vaciado era un cargo recurrente no divulgado — resuelto

Decía "deja que se vacíe sola" sin mencionar nunca que hay un cobro automático
a una tarjeta guardada. Play exige que los cargos recurrentes se declaren de
forma clara y visible; esconderlos detrás de una metáfora entra en "cobros no
divulgados". Y aparte del rechazo, es el disparador clásico de "me cobraron sin
avisar" y de contracargos contra la cuenta de Stripe del Rab.

Ahora dice que hay cobro automático, a qué tarjeta, que llega aviso cada vez y
que se apaga desde Ajustes.

### Y salió un bug real de acá

Al ir a verificar que el aviso existiera de verdad antes de prometerlo en la
ficha, apareció que **el vaciado automático no mandaba comprobante por correo**:
`receipt_email` estaba puesto en el pago manual (`createPaymentIntent`) pero
nunca en `processPushkaAutoEmpty`. O sea que el cobro off-session —el que el
usuario no está mirando— aparecía solo en el resumen de la tarjeta. Exactamente
el escenario que termina en contracargo.

Arreglado y desplegado en prod y dev el 2026-09-02.

## 3. "Nunca guarda los datos de tu tarjeta" chocaba con el Data Safety — resuelto

Verificado en el código: para el donante las tarjetas **viven en Stripe**, se
listan en vivo y no se persiste nada en Firestore; solo se muestran marca y
últimos cuatro dígitos. Pero `docs/play-store-data-safety.md` recomienda
declarar "Información de pago" como recopilada, porque la hoja de Stripe se
muestra dentro de la app. Un "nunca" absoluto contra esa declaración es rechazo
por *data safety mismatch*.

La redacción actual es precisa y no más débil: la tarjeta se escribe en la
pantalla de Stripe y queda de su lado.

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

- [ ] El Rab aprueba el nombre, el texto y las dos afirmaciones marcadas arriba
- [ ] **Play Console → Contenido de la app → Acceso a la app**: cargar mail,
      contraseña **y el código de invitación JYM-770** de
      `play-review@jabadencampus.com`. Sin el código el revisor se estrella
      contra la pantalla de invitación y rechaza sin leer la descripción.
- [ ] Data Safety completo — `docs/play-store-data-safety.md`. Declarar
      "Información de pago" como recopilada, para que no choque con la ficha.
- [ ] Elegir cuál captura principal va, la oscura o la clara
- [ ] Build de tienda: `flutter build appbundle --flavor prod` **sin**
      `APP_CHECK_PROVIDER=debug` (ver la advertencia en `CLAUDE.md`)
