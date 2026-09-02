# Capturas para Google Play

`play/` tiene las versiones listas para subir. Las de la raíz son los
originales sin recortar del Galaxy S25 (1080×2340).

## Por qué están recortadas a 1080×2160

Google rechaza cualquier captura cuyo lado mayor supere el **doble** del
menor. Un screenshot nativo del S25 es 1080×2340 → relación 2,17, así que
las cuatro habrían sido rechazadas tal cual salieron del teléfono.

El recorte quita 130 px arriba y 50 abajo (`crop=1080:2160:0:130`), que en
todas las pantallas es margen vacío. También se les saca el canal alfa: Play
exige PNG de 24 bits sin transparencia.

Para regenerar desde un original nuevo:

    ffmpeg -y -i entrada.png -vf "crop=1080:2160:0:130" -pix_fmt rgb24 salida.png

## Qué muestra cada una

| Archivo | Pantalla |
|---|---|
| `01-pushka.png` | Mi Pushka con monto acumulado y racha — modo oscuro |
| `01-pushka-claro.png` | La misma en modo claro, para elegir cuál va |
| `02-segulot.png` | Segulot y Rezos |
| `03-recordatorios.png` | Recordatorios con tres frecuencias distintas |
| `04-donacion.png` | Hoja de donación: única/automática, designación, dedicatoria |

Sacadas con la cuenta de revisión de Play (`play-review@jabadencampus.com`),
no con una cuenta real: así ningún dato personal termina en la ficha pública.
Los montos y recordatorios son estado real de esa cuenta, generado tocando la
app; no hay nada montado.

Play pide mínimo 2 y acepta hasta 8.
