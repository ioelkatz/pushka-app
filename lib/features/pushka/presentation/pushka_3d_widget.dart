import 'package:flutter/material.dart';

/// Static PNG pushka. Ioel pidió reemplazar la pushka 3D pintada (cilindro
/// custom-painter + animación de líquido + labels de meta/monto flotantes)
/// por una imagen única — el progreso ya se ve en la barra de arriba, así
/// que duplicarlo flotando sobre la pushka era ruido visual.
///
/// La signature se mantiene (fillPercentage / goal / amount / currencySymbol)
/// para no romper el callsite en pushka_screen ni la GlobalKey
/// `Pushka3DWidgetState`. Los parámetros se ignoran — la imagen es estática.
class Pushka3DWidget extends StatefulWidget {
  final double fillPercentage;
  final double goal;
  final double amount;
  final String currencySymbol;

  const Pushka3DWidget({
    super.key,
    required this.fillPercentage,
    required this.goal,
    required this.amount,
    required this.currencySymbol,
  });

  @override
  State<Pushka3DWidget> createState() => Pushka3DWidgetState();
}

class Pushka3DWidgetState extends State<Pushka3DWidget> {
  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      // +10 px de offset vertical para nudge la pushka hacia abajo dentro
      // de su SizedBox — Ioel pidió que quede levemente más abajo para
      // mejor balance visual con el resto del contenido. NO afecta el
      // cálculo de la ranura en _launchFallingAnimation (ese usa el
      // RenderBox del widget completo, no la imagen interna).
      offset: const Offset(0, 10),
      child: Center(
        // 80% del SizedBox que da pushka_screen — Ioel quiso bajar el tamaño
        // visual sin tocar el layout del screen (que ya clampa la altura entre
        // 220 y 440 según el espacio disponible).
        child: FractionallySizedBox(
          widthFactor: 0.80,
          heightFactor: 0.80,
          child: Image.asset(
            'assets/images/pushka_can.webp',
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}
