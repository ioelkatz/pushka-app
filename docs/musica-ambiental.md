# Música ambiental — desactivada el 2026-09-02

La app tenía en Configuración un toggle de **música ambiental**: un nigún en
loop que sonaba de fondo y bajaba de volumen cuando sonaba un efecto (la
moneda, el billete). Se retiró antes de publicar en Google Play.

## Por qué

El audio era un MP3 bajado de YouTube. La melodía de un nigún es tradicional
y de dominio público, pero **esa grabación puntual tiene derechos de quien la
grabó**, y distribuirla desde la app es infracción.

Lo que lo volvía desproporcionado no era el riesgo en abstracto: la cuenta de
Google Play está a nombre de **Jym Inc**, la organización del Rab, recién
creada y sin historial. Un reclamo de derechos no termina en "sacá el audio",
termina en una advertencia contra la cuenta de desarrollador. Del otro lado de
la balanza había un toggle apagado por defecto en una app cuyo propósito es
echar una moneda en la pushka.

## Dónde quedó el archivo

```
C:\dev\_pushka_archivo\audio-ambiental\nigunim.mp3
```

56 MB, MP3 a 64 kbps, casi dos horas. **A propósito fuera del repo**: meter un
archivo con derechos ajenos en git lo deja en el historial para siempre,
aunque después se borre el archivo.

El original vivía en Firebase Storage, en
`gs://pushka-app-ioel.firebasestorage.app/ambient/nigunim.mp3`, y era de
lectura pública.

## Qué se tocó en el código

Nada se borró de verdad: la maquinaria sigue entera y desactivada en un solo
punto, para que volver a encenderla sea trivial.

| Archivo | Cambio |
|---|---|
| `lib/features/feedback/feedback_service.dart` | `_ambientUrl` quedó en `''` y `startAmbient()` retorna de inmediato si está vacío. `updatePreferences()` ignora el parámetro `ambient` y fuerza el apagado. |
| `lib/features/settings/presentation/settings_screen.dart` | Se retiró el toggle de la UI. El campo `ambientEnabled` y su lectura del perfil siguen ahí. |

**Por qué se cortó en el servicio y no solo escondiendo el toggle**: quien ya
tenía `ambientEnabled: true` guardado en su perfil de Firestore lo sigue
arrastrando, y `app.dart` llama a `startAmbient()` al abrir la app leyendo ese
valor. Esconder el toggle habría dejado sonando el audio a los que ya lo
tenían activado.

El resto —el player, el fundido de volumen, `stopAmbient()`, las llamadas de
ducking desde cada efecto— quedó intacto. Con `ambientEnabled` siempre en
`false`, `_fadeAmbientTo()` retorna en la primera línea y no hace nada.

## Cómo volver a habilitarla

1. **Conseguir una grabación que se pueda usar.** Un nigún grabado por alguien
   de la comunidad es la mejor opción: es original, no cuesta nada y encaja
   mucho mejor con la app que un MP3 bajado de YouTube. Si no, sirve
   cualquier grabación con licencia que permita distribución (CC0, dominio
   público comprobado, o una licencia comprada).
2. Subirla a Firebase Storage y hacerla de lectura pública.
3. Poner la URL en `_ambientUrl`.
4. Devolver el toggle a `settings_screen.dart` — está en el historial de git,
   en el commit que retiró la función.
5. Considerar recomprimir: 56 MB a 64 kbps es mucho para un loop de fondo.
   Un fragmento de 2-3 minutos en loop suena igual y no le come los datos al
   usuario.

Las cadenas de traducción (`tr.ambientMusic`, `tr.ambientMusicSub`) siguen en
`s.dart` en los cuatro idiomas. No hace falta volver a traducir nada.
