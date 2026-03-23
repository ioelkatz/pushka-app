import 'package:flutter/material.dart';
import '../../../app/theme/app_tokens.dart';

class PrayersScreen extends StatelessWidget {
  const PrayersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nota de ejemplo
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: AppTokens.cardSilver,
              border: Border.all(color: AppTokens.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: AppTokens.skyBlue, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Nota: Este es un ejemplo. Los textos se mejorarán y perfeccionarán más adelante.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTokens.mutedText,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Título en Hebreo
          const Text(
            'אלקא דמאיר ענני',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.5,
            ),
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.right,
          ),
          const SizedBox(height: 20),

          // Texto en Hebreo
          const Text(
            '''מסופר בשם הבעל שם טוב: מי שנמצא במצב מסוכן וצריך נס, יתן י"ח מטבעות גדולים לנרות להדלקה בבית הכנסת, ויאמר: "אני מתחייב י"ח מטבעות גדולים לנרות לעילוי נשמת רבי מאיר בעל הנס", ואז יאמר ג' פעמים: "אלקא דמאיר ענני".''',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.right,
          ),
          const SizedBox(height: 16),
          const Text(
            '''ובכן יהי רצון מלפניך ה' או"א כשם ששמעת את תפלת עבדך מאיר ועשית לו ניסים ונפלאות כן תעשה עמדי ועם כל ישראל עמך הצריכים לניסים נסתרים ונגלים אכי"ר.''',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.right,
          ),
          const SizedBox(height: 32),

          // Título en Español
          const Text(
            'DIOS DE (RABINO) MEIR, RESPÓNDEME',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),

          // Texto en Español
          const Text(
            'Se enseñó en nombre del Baal Shem Tov: Una persona que se encuentra en una situación peligrosa que requiere un milagro debe dar 18 monedas grandes, referidas como Gedolim, para velas que se encenderán en una sinagoga.',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Debe entonces declarar: "Me comprometo a dar estas 18 monedas por el mérito del alma del Rabino Meir, el maestro de los milagros."',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Debe entonces repetir tres veces: "Dios de (Rabino) Meir, (por favor) respóndeme."',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Y así sea Tu voluntad, nuestro Dios y Dios de nuestros padres, que así como respondiste a la oración de Tu siervo (Rabino) Meir, realizando milagros y maravillas para él, así también puedas realizar para mí y para todo el pueblo de Tu nación, Israel, que está en necesidad de milagros, tanto revelados como ocultos. Amén, que sea Tu voluntad.',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
