# Rediseño JYM — pendientes

Rama: `rediseno/paleta-jym`. Nada de esto está en `dev` ni en producción.
Play sigue sirviendo 1.0.15 con la paleta vieja.

## Hecho

- **Paleta.** Los tres colores de la identidad (rosado `#F82D4A`, gris
  `#D3D3D3`, verde `#05806E`) viven solo en `lib/app/theme/app_tokens.dart`.
  `test/unit/paleta_jym_test.dart` los bloquea y falla si alguien vuelve a
  escribir uno de esos hex a mano en `lib/`.
- **Lata nueva.** `assets/images/pushka_can.png`, 1249×978, apaisada: trae
  los chevrones del logo abriéndose a los costados. `Pushka3DWidget` deriva
  su alto de la proporción del archivo en vez de recibir un alto fijo, y la
  animación de la moneda apunta a `slotFromTop`.
  `test/unit/pushka_asset_test.dart` ata las medidas del PNG a las
  constantes.

## Pendiente: el 770 con estilo nuevo

**Qué es.** El usuario puede elegir entre dos pushkas en Configuración →
apariencia: la lata (`PushkaStyle.classic`) y el edificio de 770 Eastern
Parkway (`PushkaStyle.building770`). El edificio está **dibujado a mano** en
`lib/features/pushka/presentation/building_770_painter.dart` con un
`CustomPainter` y ~24 colores escritos en el propio painter.

**Qué falta.** Rehacerlo en el estilo nuevo, a juego con la lata. Dos caminos
y conviene decidir cuál antes de tocar nada:

1. **Imagen, como la lata.** El cliente dibuja un 770 con los mismos
   chevrones y se reemplaza el painter por un PNG. Es lo más consistente y
   borra 24 colores sueltos de un saque. Pierde el llenado progresivo, que
   hoy el painter pinta según `fillFraction` — aunque la lata ya lo perdió y
   el progreso se lee en la barra de arriba, así que no sería una asimetría
   nueva.
2. **Seguir pintándolo, con la paleta nueva.** Se mantiene el llenado, pero
   hay que elegir a mano cómo caen rosado / gris / verde sobre ladrillo,
   techo, puertas y ventanas. Más trabajo y más chance de que quede
   desparejo contra la lata, que es una foto.

**Ojo con esto al hacerlo.** El 770 hoy recibe un `SizedBox(height:
imageHeight)` con alto fijo — ver el callsite en `pushka_screen.dart`. La
lata dejó de usarlo. Si el 770 pasa a ser una imagen, va a necesitar el mismo
tratamiento de proporción, o va a quedar con franja muerta arriba y abajo.

**Material de referencia:** `docs/770_wireframe.html` y
`docs/770_wireframe.svg`.

## Decisiones abiertas de color

- **La racha.** El prototipo del cliente la muestra en rosado fijo. Hoy la
  app cicla siete colores, uno por día de la semana
  (`_streakColors` en `pushka_screen.dart`). Pasar a rosado fijo simplifica,
  pero saca una función que ya existe.
- **Los avisos ámbar.** Siguen en ámbar. Son advertencias, no marca, así que
  defendible; pero si el cliente quiere todo dentro de la paleta, hay que
  elegir con qué se reemplazan.
- **Barrido de colores sueltos restantes:** `splash_screen.dart` (15),
  `jewish_confetti.dart` (14), y ~25 repartidos entre settings, historial,
  billetera y tarjetas. Ninguno es de marca, por eso el test no los marca.

## Cómo mirar un cambio sin compilar el APK

```
flutter test tool/capturas/pushka_capturas_test.dart
```

Deja PNG de cinco pantallas distintas en `tool/capturas/salida/`
(gitignorada) y escribe en consola la medida de la lata en cada una.

⚠️ **Sin resolver: la primera captura sale en segundos y cada una de las
siguientes tarda 10 minutos clavados.** Diez minutos exactos huele a un
timeout, no a render — los procesos quedan con el CPU en cero, esperando. Ya
se descartó `precacheImage` (era un cuelgue real y se reemplazó por escuchar
el `ImageStream` a mano, que arregló la primera captura pero no las demás).
Mientras no se resuelva, conviene correr el arnés con una sola pantalla en
`telefonos` o dejarlo en segundo plano. Dos corridas a la vez se trancan
entre sí por el lock del build: antes de arrancar otra, verificar que no haya
un `flutter_tester` vivo.

Aun así vale la pena: una captura tarda menos que los 6-7 minutos de un build
de release, y no hay que instalar nada en el celular para mirar un cambio.
