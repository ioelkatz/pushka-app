# Ficha de Google Play — borrador para aprobar con el Rab

Textos propuestos y material gráfico necesario. **Todo esto se puede cambiar
después de publicar**, así que no bloquea subir el binario.

---

## Nombre de la app — máx. 30 caracteres

Tres opciones, de más a menos recomendada:

```
Pushka — Jabad en Campus          24    ← recomendada
Pushka                             6
Pushka Tzedaká                    14
```

La primera gana porque un donante que busca "Jabad en Campus" la encuentra, y
quien ya conoce la app la reconoce por "Pushka". Sola, "Pushka" es demasiado
genérica y no compite bien en búsquedas.

## Descripción corta — máx. 80 caracteres

```
Tu alcancía de tzedaká digital. Doná cuando quieras, desde el celular.
```
69 caracteres. Es lo primero que se lee bajo el título; tiene que decir qué es
en una línea.

Alternativa más directa:
```
Acumulá tzedaká en tu pushka digital y doná a Jabad en Campus.
```

## Descripción larga — máx. 4000 caracteres

```
Pushka es la alcancía de tzedaká de Jabad en Campus, ahora en tu celular.

La mitzvá de dar tzedaká acompaña el día a día. Esta app te permite
mantener ese hábito con la misma sencillez de echar una moneda en la
alcancía, estés donde estés.

CÓMO FUNCIONA

Tocá los montos predefinidos para ir acumulando en tu pushka. Cuando
quieras, vaciás la alcancía y el monto acumulado se dona a la
organización. También podés programar el vaciado automático: semanal,
mensual o en Erev Rosh Jodesh.

QUÉ VAS A ENCONTRAR

• Tu pushka personal, para acumular de a poco
• Metas de donación y racha de días consecutivos
• Vaciado automático con la frecuencia que elijas
• Recordatorios para no perder el hábito
• Historial completo de tus donaciones
• Segulot y rezos
• Avisos de las festividades del calendario judío
• Disponible en español, inglés, francés y hebreo

DONACIONES SEGURAS

Los pagos se procesan con Stripe, líder mundial en pagos en línea. La app
nunca almacena los datos de tu tarjeta.

Jabad en Campus opera bajo JYM Inc, organización sin fines de lucro
reconocida por el IRS bajo la sección 501(c)(3). Tus donaciones son
deducibles de impuestos en Estados Unidos.

PARA EMPEZAR

Necesitás el código de invitación que comparte tu Rab. Si no lo tenés,
escribinos y te ayudamos.
```

⚠️ **Revisar con el Rab antes de publicar.** Dos puntos concretos:

1. La frase sobre deducción de impuestos es una afirmación fiscal. Es cierta
   —la carta del IRS dice `Contribution Deductibility: Yes`— pero que la
   apruebe él.
2. Confirmar si quiere mencionar "Jabad en Campus" o prefiere una redacción
   más general, pensando en que la app es multi-organización.

---

## Material gráfico

| Qué | Medidas | Formato | Estado |
|---|---|---|---|
| Ícono | 512 × 512 | PNG 32-bit, sin transparencia | Se puede reusar `assets/images/app_icon.png` (el 770) |
| Gráfico destacado | 1024 × 500 | PNG o JPG, sin transparencia | **Falta** |
| Capturas de teléfono | mín. 320 px, máx. 3840 px de lado | PNG o JPG | **Faltan** — mínimo 2, idealmente 4-8 |

El gráfico destacado es el banner que se ve arriba de la ficha. Se puede armar
con el 770 sobre el degradé de la app y el nombre.

### Capturas sugeridas, en este orden

1. La pushka con monto acumulado — es la pantalla que define la app
2. Los montos predefinidos, mostrando el gesto de acumular
3. El historial de donaciones
4. La configuración de vaciado automático
5. Segulot y rezos

Sacarlas del S25 con la app en producción y datos realistas: montos redondos,
no de prueba, y nada de "Test" ni cuentas de desarrollo a la vista.

---

## Otros campos de la ficha

```
Categoría              Estilo de vida       ← NO "Finanzas"
Etiquetas              donaciones, comunidad, religión
Correo de contacto     apps@jabadencampus.com
Sitio web              https://jabadencampus.com
Política de privacidad https://chabad-admin.web.app/privacy
```

**"Estilo de vida" y no "Finanzas" a propósito**: la categoría Finanzas activa
políticas y revisiones más estrictas que no corresponden, porque la app no
ofrece un servicio financiero — recibe donaciones para una entidad exenta.

---

## Traducciones

La ficha se puede publicar en varios idiomas. La app ya soporta español,
inglés, francés y hebreo. Conviene al menos español (principal) e inglés.

Cuando el Rab apruebe los textos en español, se traducen.
