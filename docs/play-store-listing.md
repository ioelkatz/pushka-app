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

## Descripción completa — 2884 de 4000 caracteres

> Play muestra solo las **tres primeras líneas** antes del botón "Más
> información". El primer párrafo mide 223 caracteres: Play va a cortarlo cerca del final y
> mostrar "Más información".
> La palabra "pushka" ya no aparece ahí — Ioel prefirió cerrar el párrafo en la
> misión — pero sí está en la descripción corta, que Play muestra siempre
> arriba de todo.

```
En Jabad en Campus trabajamos con jóvenes judíos de Ciudad de México que crecieron un poco lejos de sus raíces. Los invitamos a un Shabat, a un asado, a ponerse tefilín, a conocer gente, a volver a conectar con su judaísmo.

Cada Shabat hay jalá en la mesa, ensaladas, risas e historias fascinantes. Siempre terminan faltando sillas. Vienes una vez y te quedas por siempre. Muchos llegan porque un amigo los invitó, sin saber muy bien qué esperar, pero a las doce de la noche siguen ahí, pasando un momento increíble.

La pushka es la alcancía de tzedaká que está en tantas casas judías. En ella puedes poner una moneda antes de salir, el viernes antes de que empiece Shabat, cuando nace un hijo, alguien se recupera de una operación o simplemente tienes ganas de dar.

La aplicación funciona de manera sencilla: seleccionas el monto que prefieras y el importe se acumula en la pushka. En ese momento no se realiza ningún cargo. Cuando tú lo decidas, puedes vaciarla y se hará un único cargo por el total acumulado, que será donado a Jabad en Campus.

Y si prefieres no estar pendiente, puedes programar que se vacíe sola cada semana, cada mes o en Erev Rosh Jodesh, cuando muchos ya tienen la costumbre de dar. En ese caso sí se hace un cobro automático a la tarjeta que elijas: te avisamos cada vez que pasa y puedes cambiarlo o apagarlo cuando quieras desde Ajustes. O, si prefieres, te mandamos solamente un recordatorio y la vacías tú.

La app también cuenta los días seguidos que llevas dando. Puedes ponerte una meta mensual, ver cuánto llevas y cuánto te falta, y consultar todo en tu historial. Cada donación queda registrada y recibes su comprobante por correo. El Rab lo dice así: en la tzedaká importa la constancia, no el monto.

Adentro hay también tefilot y segulot para leer, y avisos cuando se acerca una festividad. Puedes dar en pesos, dólares, shékels u otras monedas, y pedir huella o reconocimiento facial antes de donar o de vaciar la pushka. Está en español, inglés, francés y hebreo, para que cada quien pueda usarla en el idioma en que reza.

¿Por qué la app te pide un código?

Porque esta es la pushka de una comunidad, no una app de donaciones abierta al público. El código de invitación es JYM-770. Las donaciones van directamente a Jabad en Campus, y siempre sabrás a dónde va tu dinero.

Los pagos los procesa Stripe. Tu tarjeta se guarda directamente en la pantalla de Stripe dentro de la app, y puedes borrarla o incluso eliminar tu cuenta entera cuando quieras.

Jabad en Campus es una organización judía sin fines de lucro. Las donaciones son voluntarias y no desbloquean funciones ni contenido dentro de la app. Lo que juntamos entre todos ayuda a sostener el trabajo en Ciudad de México: Shabatot, viajes, asados y eventos; todo para que un judío más conecte con su esencia, con su neshamá.
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
| Política de privacidad | https://pushka-app-ioel.web.app/privacy/ |
| Borrado de cuenta | https://pushka-app-ioel.web.app/delete-account/ |
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
