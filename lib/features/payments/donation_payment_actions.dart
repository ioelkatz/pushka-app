import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../../app/theme/app_tokens.dart';
import '../../config/stripe_config.dart';
import '../../core/l10n/s.dart';

/// Los botones de pago de una donacion, con Apple Pay primero cuando se puede.
///
/// ---------------------------------------------------------------------
/// Por que existe este widget
/// ---------------------------------------------------------------------
/// La guideline 3.2.1(vi) de Apple dice, textual: *"Approved nonprofits may
/// fundraise directly within their own apps ... and offer Apple Pay support."*
/// Y la guia de marca de Apple Pay es igual de tajante en la otra direccion:
/// *"Don't create custom Apple Pay button designs or try to replicate the
/// Apple-provided ones."* O sea: el boton lo dibuja el sistema o no existe.
/// Por eso aca no hay ni un color ni un texto nuestro — `PlatformPayButton`
/// pinta el boton nativo real.
///
/// El widget compone los DOS botones en vez de exponer solo el de Apple Pay,
/// y eso es a proposito: quien lo usa no tiene que preguntarse si Apple Pay
/// esta disponible para decidir si dibuja el separador. Cuando no esta, lo
/// que queda es [botonAlternativo] solo, a ancho completo — exactamente la
/// pantalla que hay hoy en produccion. El cambio es invisible hasta que Apple
/// Pay realmente funcione.
///
/// ---------------------------------------------------------------------
/// Cuando NO se muestra
/// ---------------------------------------------------------------------
/// Hacen falta las tres:
///
/// 1. Que sea iOS. En Android este mismo widget de Stripe dibujaria un boton
///    de Google Pay, y la app de Play esta viva: no se toca en este cambio.
/// 2. Que `STRIPE_MERCHANT_ID` este cargado. Sin el Apple Pay Payment
///    Processing Certificate en la cuenta conectada el boton apareceria y el
///    cobro fallaria, que es peor que no mostrarlo.
/// 3. Que el dispositivo lo soporte y tenga una tarjeta cargada
///    (`isPlatformPaySupported`).
///
/// ⚠️ La deteccion de plataforma usa `defaultTargetPlatform`, NO
/// `dart:io Platform`. En este proyecto ya hubo un crash de la PWA por tocar
/// `Platform` en codigo compartido: `dart:io` no existe en web.
class DonationPaymentActions extends StatefulWidget {
  /// Se dispara cuando la persona toca el boton nativo de Apple Pay.
  /// Quien lo recibe tiene que llamar a `StripeService.pay(useApplePay: true)`.
  final VoidCallback onApplePay;

  /// El boton que ya existia: abre la hoja de Stripe con todos los medios de
  /// pago. Cuando Apple Pay esta disponible pasa a ser la segunda opcion.
  final Widget botonAlternativo;

  /// Alto de los dos botones. Por defecto 50, que es el de los botones de la
  /// pantalla principal. El minimo que admite Apple para el boton de donar es
  /// 30pt de alto y 140pt de ancho; 50 a ancho completo pasa holgado.
  final double alto;

  const DonationPaymentActions({
    super.key,
    required this.onApplePay,
    required this.botonAlternativo,
    this.alto = 50,
  });

  @override
  State<DonationPaymentActions> createState() => _DonationPaymentActionsState();
}

class _DonationPaymentActionsState extends State<DonationPaymentActions> {
  /// null mientras se consulta. Importa: hasta saberlo se muestra solo el
  /// boton de siempre, nunca un hueco ni un spinner. La consulta tarda
  /// milisegundos, pero si tardara, lo que se ve es la pantalla de hoy.
  bool? _disponible;

  @override
  void initState() {
    super.initState();
    _consultarDisponibilidad();
  }

  bool get _puedeHaberApplePay =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      StripeConfig.merchantIdentifier.isNotEmpty;

  Future<void> _consultarDisponibilidad() async {
    if (!_puedeHaberApplePay) {
      if (mounted) setState(() => _disponible = false);
      return;
    }
    bool soportado = false;
    try {
      soportado = await Stripe.instance.isPlatformPaySupported();
    } catch (e) {
      // Un fallo del canal nativo no puede tumbar la pantalla de donar. Si no
      // se pudo averiguar, se asume que no hay Apple Pay y queda el boton de
      // siempre, que funciona igual.
      debugPrint('DonationPaymentActions: isPlatformPaySupported fallo: $e');
      soportado = false;
    }
    if (mounted) setState(() => _disponible = soportado);
  }

  @override
  Widget build(BuildContext context) {
    final anchoCompleto = SizedBox(
      width: double.infinity,
      height: widget.alto,
      child: widget.botonAlternativo,
    );

    if (_disponible != true) return anchoCompleto;

    final esOscuro = Theme.of(context).brightness == Brightness.dark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          height: widget.alto,
          child: PlatformPayButton(
            // El tipo que Apple reserva para organizaciones sin fines de
            // lucro aprobadas. Dibuja "Donate with  Pay".
            type: PlatformButtonType.donate,
            // El estilo sale de NUESTRO tema, no de `automatic`. La app tiene
            // su propio interruptor de apariencia: con `automatic` el boton
            // seguiria al del telefono y podria salir negro sobre fondo
            // oscuro, o blanco sobre fondo claro.
            appearance: esOscuro
                ? PlatformButtonStyle.white
                : PlatformButtonStyle.black,
            borderRadius: AppTokens.radiusMd.round(),
            constraints: BoxConstraints.tightFor(height: widget.alto),
            onPressed: widget.onApplePay,
          ),
        ),
        const SizedBox(height: AppTokens.spaceMd),
        const _SeparadorO(),
        const SizedBox(height: AppTokens.spaceMd),
        anchoCompleto,
      ],
    );
  }
}

/// Una linea con "o" en el medio, para que se lea que son dos caminos para lo
/// mismo y no dos acciones distintas.
class _SeparadorO extends StatelessWidget {
  const _SeparadorO();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).brightness == Brightness.dark
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : AppTokens.mutedText;
    final linea = Expanded(
      child: Divider(color: color.withValues(alpha: 0.3), height: 1),
    );
    return Row(
      children: [
        linea,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMd),
          child: Text(
            S.of(context).orSeparator,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
        linea,
      ],
    );
  }
}
