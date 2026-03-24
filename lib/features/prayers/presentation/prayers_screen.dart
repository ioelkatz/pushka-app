import 'package:flutter/material.dart';
import '../../../core/l10n/s.dart';

class PrayersScreen extends StatelessWidget {
  const PrayersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
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
              color: Colors.orange.shade50,
              border: Border.all(color: Colors.orange.shade200),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.orange.shade700, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr.prayersNote,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade900,
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
          Text(
            tr.prayerTitleEs,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),

          // Texto en Español
          Text(
            tr.prayerP1,
            style: const TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr.prayerP2,
            style: const TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr.prayerP3,
            style: const TextStyle(
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            tr.prayerP4,
            style: const TextStyle(
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
