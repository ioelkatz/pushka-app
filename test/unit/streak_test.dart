import 'package:flutter_test/flutter_test.dart';
import 'package:pushka_app/features/pushka/domain/streak.dart';

void main() {
  // Fechas ancla, para que los tests no dependan de "hoy".
  final lunes = DateTime(2026, 9, 7);
  final martes = DateTime(2026, 9, 8);
  final viernes = DateTime(2026, 9, 11);
  final sabado = DateTime(2026, 9, 12);
  final domingo = DateTime(2026, 9, 13);

  group('isStreakExemptDay', () {
    test('solo Shabat exime', () {
      expect(isStreakExemptDay(sabado), isTrue);
      expect(isStreakExemptDay(domingo), isFalse, reason: 'el domingo es día común');
      expect(isStreakExemptDay(lunes), isFalse);
      expect(isStreakExemptDay(viernes), isFalse);
    });
  });

  group('previousStreakDay', () {
    test('un día común, el anterior es el día calendario anterior', () {
      expect(previousStreakDay(martes), lunes);
    });

    test('el día previo al domingo saltea Shabat y cae en viernes', () {
      expect(previousStreakDay(domingo), viernes);
    });

    test('el día previo al lunes es el domingo, NO el viernes', () {
      // Esta es la regresión: antes se salteaba también el domingo, así que
      // se podía faltar un día entero sin cortar la racha.
      expect(previousStreakDay(DateTime(2026, 9, 14)), domingo);
    });
  });

  group('currentStreak — lo que se muestra', () {
    test('sin actividad previa es 0', () {
      expect(
        currentStreak(stored: 0, lastActivity: null, today: lunes),
        0,
      );
    });

    test('una racha guardada sin fecha no se muestra', () {
      expect(currentStreak(stored: 7, lastActivity: null, today: lunes), 0);
    });

    test('si la última actividad fue hoy, se mantiene', () {
      expect(currentStreak(stored: 5, lastActivity: lunes, today: lunes), 5);
    });

    test('si fue ayer, sigue viva', () {
      expect(currentStreak(stored: 5, lastActivity: lunes, today: martes), 5);
    });

    test('el viernes sostiene la racha del domingo, salteando Shabat', () {
      expect(currentStreak(stored: 3, lastActivity: viernes, today: domingo), 3);
    });

    test('CADUCA cuando pasaron días sin actividad', () {
      // El bug: la racha guardada se pintaba tal cual y nunca se cortaba
      // sola, así que alguien que dejó de dar hace semanas seguía viendo su
      // número viejo.
      expect(
        currentStreak(stored: 12, lastActivity: lunes, today: DateTime(2026, 9, 20)),
        0,
      );
    });

    test('faltar el domingo CORTA la racha', () {
      // Con la lógica anterior esto devolvía 4: se salteaba el domingo.
      expect(
        currentStreak(stored: 4, lastActivity: viernes, today: DateTime(2026, 9, 14)),
        0,
      );
    });

    test('un reloj adelantado no castiga al usuario', () {
      expect(
        currentStreak(stored: 6, lastActivity: DateTime(2026, 9, 20), today: lunes),
        6,
      );
    });
  });

  group('streakAfterActivity — lo que se guarda', () {
    test('primera actividad de la vida arranca en 1', () {
      expect(
        streakAfterActivity(stored: 0, lastActivity: null, today: lunes),
        1,
      );
    });

    test('dar dos días seguidos suma', () {
      expect(
        streakAfterActivity(stored: 1, lastActivity: lunes, today: martes),
        2,
      );
    });

    test('volver después de faltar reinicia en 1', () {
      expect(
        streakAfterActivity(
          stored: 12,
          lastActivity: lunes,
          today: DateTime(2026, 9, 20),
        ),
        1,
      );
    });

    test('dar de nuevo el mismo día no avanza', () {
      expect(
        streakAfterActivity(stored: 5, lastActivity: lunes, today: lunes),
        5,
      );
    });

    test('viernes y después domingo suma, salteando Shabat', () {
      expect(
        streakAfterActivity(stored: 3, lastActivity: viernes, today: domingo),
        4,
      );
    });

    test('dato inconsistente (fecha sin contador) no inventa una racha', () {
      // stored=0 con fecha de ayer es estado corrupto; lo correcto es contar
      // hoy y nada más, no asumir que ayer también contaba.
      expect(
        streakAfterActivity(stored: 0, lastActivity: lunes, today: martes),
        1,
      );
    });
  });
}
