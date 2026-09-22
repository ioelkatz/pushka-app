# Mensaje de lanzamiento por WhatsApp — Jabad en Campus

Mensaje listo para copiar y mandar a los donantes de Jabad en Campus.

> ⚠️ **Este documento se reescribió el 2026-09-22 para el lanzamiento en Google
> Play.** La versión anterior era de la época del sideload y tenía dos errores
> que habrían roto el lanzamiento: el código de invitación estaba **al revés**
> (`770JYM` en vez de `JYM-770`, que es el único que funciona) y el enlace
> apuntaba a la página de descarga del APK, que hay que dar de baja.

---

## ⚠️ Lo primero, porque afecta a TODOS los que ya tienen la app

Quien haya instalado la app por el enlace viejo —el APK que se bajaba de
`pushka-landing.web.app/instalar`— **tiene que desinstalarla antes de instalar
la de Play**.

No es un capricho: Android bloquea la instalación cuando las firmas no
coinciden, y la app de Play la firma Google con una clave distinta de la que
usábamos para el APK. Si no desinstalan primero, la instalación falla con un
error que no explica nada.

**No se pierde nada**: la cuenta, el historial de donaciones y el saldo de la
pushka viven en el servidor. Solo hay que volver a iniciar sesión.

Por eso el mensaje de abajo lo dice explícitamente. **No lo saques.**

---

## Antes de mandar nada

1. **Dar de baja la página del APK.** Si queda arriba, la gente sigue
   instalando la versión vieja y el problema se repite indefinidamente.

2. **Usar una LISTA DE DIFUSIÓN, no un grupo.** Cada persona lo recibe en su
   chat privado. En un grupo todos se ven entre todos, y quién dona tzedaká no
   es algo que se comparta.
   - Android: WhatsApp → menú (⋮) → "Nueva difusión".
   - iPhone: WhatsApp → arriba a la derecha → "Listas de difusión".
   - Solo lo reciben los contactos que tengan al Rab agendado en su celular.

3. **Probar con dos o tres personas primero.** Que confirmen que pudieron
   instalar, entrar con el código y donar. Recién después, el envío grande.

4. **Elegir un horario tranquilo.** Evitar el viernes a la tarde.

---

## El mensaje

> B"H
>
> ¡Hola! Ya está la pushka de Jabad en Campus en Google Play. Es la alcancía de
> tzedaká, en tu teléfono: juntas durante la semana y la vacías cuando tú
> quieras.
>
> Descárgala aquí:
> https://play.google.com/store/apps/details?id=com.pushka.app
>
> Al abrirla te va a pedir un código. Es: *JYM-770*
>
> Si ya tenías la app instalada de antes, **desinstálala primero** y luego
> instala esta. No pierdes nada: tu cuenta y tu historial quedan guardados.
>
> Cualquier duda me escribes.
>
> Que sea con brajá,
> Rab Mendy

---

## Para iPhone

La app todavía **no está en App Store**. A quien tenga iPhone, mandarle esto:

> Por ahora en iPhone se usa desde el navegador, funciona igual:
> https://app.jabadencampus.com
>
> Ábrelo en Safari, toca el botón de compartir (el cuadrito con la flecha) y
> elige "Agregar a pantalla de inicio". Te queda como una app más.
>
> El código es el mismo: *JYM-770*

---

## Respuestas listas para las preguntas de siempre

### "¿Es seguro?"

> Sí. Los pagos los procesa Stripe, la misma plataforma que usan miles de apps.
> Tu tarjeta se escribe en la pantalla de Stripe y queda de su lado; en la app
> solo se ven la marca y los últimos cuatro dígitos, y la puedes borrar cuando
> quieras.

### "No me deja instalar / me da error"

> Es porque tienes la versión vieja instalada. Desinstálala manteniendo el dedo
> sobre el ícono → "Desinstalar", y después instala la de Google Play. Tu cuenta
> y tu historial no se pierden.

### "¿En cuánto llega la donación?"

> Al instante. Cuando confirmas el pago queda registrado y llega a Jabad en
> Campus, y te llega un comprobante por correo.

### "¿Cuánto tengo que donar?"

> Lo que quieras y cuando quieras. La idea es la costumbre, no el monto — puede
> ser desde cinco pesos. En la tzedaká cuenta la constancia.

### "¿Se puede desinstalar?"

> Claro, como cualquier app. Y si quieres borrar tu cuenta entera, está dentro
> de Ajustes.

---

## Nota técnica — para el Rab y para Ioel, no para donantes

- **El código es `JYM-770`**, y se teclea **J Y M 7 7 0**. El guion es un
  separador visual, no se escribe. Estuvo publicado al revés (`770JYM`) durante
  meses y con esa forma la app responde "código no encontrado".
- El código **también está publicado en la ficha de Google Play**, decisión
  tomada el 2026-09-02: quien llegue por su cuenta puede entrar sin pedirlo.
- El enlace de Play es
  `https://play.google.com/store/apps/details?id=com.pushka.app`. Solo funciona
  una vez que la app esté publicada en producción — en prueba interna no abre
  para quien no sea verificador.
- `app.jabadencampus.com` es la PWA, y **se queda arriba hasta que la app esté
  aprobada en App Store**. Es lo único que tienen los iPhone hasta entonces.
