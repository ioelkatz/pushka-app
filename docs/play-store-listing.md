# Ficha de Google Play — Jabad en Campus

Estado: **borrador listo para que lo apruebe el Rab.**
Última revisión: 2026-09-02.

La misión que define este texto está en la memoria del proyecto
(`project_mision_jabad_en_campus`). Tres reglas fijas, decididas por Ioel:

1. **"Jabad en Campus" va presente y notorio**, no como pie de página.
2. **No se menciona deducción de impuestos** ni ningún beneficio fiscal.
3. **No se sugiere que otras organizaciones vayan a usar la app.**

---

## Nombre de la app (máx. 30) — 26 caracteres

```
Jabad en Campus — Pushka
```

> Decisión pendiente del Rab. El nombre pone la marca primero porque en la
> lista de resultados de Play se ve el nombre solo, sin la descripción.
> Alternativas: `Pushka — Jabad en Campus`, `Jabad en Campus CDMX`.

## Descripción corta (máx. 80) — 72 caracteres

```
La pushka de Jabad en Campus: tzedaká diaria de los jóvenes de la CDMX
```

## Descripción completa (máx. 4000) — 1794 caracteres

> **Lo importante del formato:** Play muestra solo las **tres primeras
> líneas** antes del botón "Más información". Casi nadie lo toca. Por eso el
> primer párrafo tiene que llevar la marca y la misión completas — y las
> lleva: "Jabad en Campus" aparece en el carácter 3.

```
En Jabad en Campus trabajamos todos los días con jóvenes judíos de Ciudad de México que crecieron lejos de sus raíces. Los invitamos a un Shabat, a un asado, a ponerse tefilín por primera vez.

Chicos y chicas que se acercan sin apuro y sin que nadie los juzgue, encuentran una comunidad y vuelven a conectarse con lo suyo y con Hashem.

Todo eso se sostiene con tzedaká. Esta app es la pushka de Jabad en Campus: la alcancía de siempre, ahora en tu teléfono.

CÓMO FUNCIONA

Tocas un monto y lo vas guardando en tu pushka, como quien deja una moneda antes de salir. Cuando quieres, la vacías y lo que juntaste se dona a Jabad en Campus.

Si prefieres no estar pendiente, puedes programar el vaciado automático: cada semana, cada mes o en Erev Rosh Jodesh.

QUÉ VAS A ENCONTRAR

• Tu pushka personal, con montos predefinidos para dar en un toque
• Una meta de donación y una racha de días consecutivos dando
• Vaciado automático: semanal, mensual o en Erev Rosh Jodesh
• Recordatorios para sostener el hábito
• Historial completo de tus donaciones
• Segulot y rezos
• Avisos de las festividades del calendario judío
• Disponible en español, inglés, francés y hebreo

En la tzedaká lo que cuenta es la constancia, no el monto.

POR QUÉ TE PIDE UN CÓDIGO

Porque esta no es una app abierta a cualquiera. Es de Jabad en Campus y es para la gente de Jabad en Campus. El código te lo da el Rab.

SOBRE LOS PAGOS

Las donaciones se procesan con Stripe. La app nunca almacena los datos de tu tarjeta.

Cada vez que vacías tu pushka estás sosteniendo eso: un Shabat que se arma, una mesa que se llena, un joven que se pone tefilín por primera vez. No es una app de finanzas: es una forma concreta de sostener lo que Jabad en Campus hace en Ciudad de México.
```

### Por qué está redactada así

- **Abre con la gente, no con la app.** Los primeros 190 caracteres son los
  chicos y las actividades. La app recién aparece en el tercer párrafo, como
  lo que es: el medio, no el fin.
- **"Cada vez que vacías tu pushka estás sosteniendo eso"**, y no *"hay un
  Shabat que se arma"*. La segunda forma promete una relación uno a uno entre
  cada donación y un evento concreto, que no es cierta y que Play puede leer
  como afirmación engañosa.
- **La pantalla del código está explicada.** Es lo primero que ve el revisor
  de Google al abrir la app, y una app que pide un código sin decir por qué
  es un motivo clásico de rechazo. La sección "POR QUÉ TE PIDE UN CÓDIGO"
  existe para eso tanto como para el usuario.
- **Sin promesas de resultado espiritual ni presión.** "En la tzedaká lo que
  cuenta es la constancia, no el monto" invita sin culpar.

---

## Datos del formulario

| Campo | Valor |
|---|---|
| Categoría | Estilo de vida |
| Etiquetas | Donaciones, Comunidad, Religión |
| Tipo | App (no juego) |
| Precio | **Gratis** — las donaciones son pagos a un tercero por Stripe, no compras dentro de la app, así que no hay Google Play Billing de por medio |
| Clasificación | Todos |
| Email de contacto | jymmexico@gmail.com |
| Política de privacidad | https://pushka-landing.web.app/privacidad/ |
| Borrado de cuenta | https://pushka-landing.web.app/delete-account/ |
| Público objetivo | 18+ |
| Anuncios | No contiene |

## Recursos gráficos

| Recurso | Archivo | Estado |
|---|---|---|
| Ícono 512×512 | `docs/store-assets/play-icon-512.png` | listo, sin canal alfa |
| Gráfico destacado 1024×500 | `docs/store-assets/play-feature-graphic-1024x500.png` | listo |
| Capturas de teléfono (mín. 2, máx. 8) | `docs/store-assets/screenshots/` | ver abajo |

### Capturas

Play pide un mínimo de 2; conviene mandar 4. En orden:

1. **Pushka principal** con saldo acumulado — es la pantalla que define la app
2. **Vaciar la pushka** con los montos predefinidos
3. **Historial** de donaciones
4. **Segulot y rezos**

Requisitos: PNG o JPEG, entre 320 px y 3840 px de lado, relación entre 16:9 y
9:16. Un screenshot nativo del S25 (1080×2340) cumple todo.

## Antes de enviar

- [ ] El Rab aprueba el nombre y el texto
- [ ] Cuenta de prueba para el revisor cargada en "Acceso a la app"
      (`googleplay.review@jabadencampus.com` / código de invitación JYM-770)
- [ ] Formulario de Data Safety completo — respuestas en
      `docs/play-store-data-safety.md`
- [ ] Build de tienda: `flutter build appbundle --flavor prod` **sin**
      `APP_CHECK_PROVIDER=debug` (ver la advertencia en `CLAUDE.md`)
