/// Lógica de la racha de días, aislada de la UI para poder testearla.
///
/// La racha cuenta **días consecutivos en los que el usuario agregó tzedaká a
/// su pushka**. No cuenta donaciones efectivas: agregar a la pushka ya es el
/// acto de dar, y vaciarla es solo cuándo se mueve el dinero.
library;

/// Días en los que NO dar no corta la racha.
///
/// Solo Shabat. En Shabat no se maneja dinero, así que es esperable que no
/// haya actividad y no debe penalizarse.
///
/// La versión anterior también salteaba el **domingo**, que es un día común y
/// laborable. Con esa lógica alguien podía dar el viernes, no hacer nada el
/// domingo y volver el lunes conservando la racha: se perdía un día entero
/// sin consecuencia.
bool isStreakExemptDay(DateTime day) => day.weekday == DateTime.saturday;

/// Normaliza a medianoche para comparar por día y no por instante.
DateTime _atMidnight(DateTime d) => DateTime(d.year, d.month, d.day);

/// El día anterior a [day] que sí cuenta para la racha.
DateTime previousStreakDay(DateTime day) {
  var d = _atMidnight(day).subtract(const Duration(days: 1));
  while (isStreakExemptDay(d)) {
    d = d.subtract(const Duration(days: 1));
  }
  return d;
}

/// La racha **vigente hoy**, dada la guardada y el último día con actividad.
///
/// Devuelve 0 si se cortó. Esto es lo que hay que MOSTRAR: el valor guardado
/// en Firestore es el de la última vez que hubo actividad y no caduca solo,
/// así que pintarlo tal cual hacía que alguien que dejó de dar hace semanas
/// siguiera viendo su racha vieja intacta.
int currentStreak({
  required int stored,
  required DateTime? lastActivity,
  required DateTime today,
}) {
  if (stored <= 0 || lastActivity == null) return 0;

  final last = _atMidnight(lastActivity);
  final t = _atMidnight(today);

  // Reloj del dispositivo atrasado respecto de la última escritura: no es
  // culpa del usuario, no se castiga.
  if (last.isAfter(t)) return stored;

  if (last == t) return stored;
  if (last == previousStreakDay(t)) return stored;

  return 0;
}

/// La racha **después de registrar actividad hoy**.
///
/// Se apoya en [currentStreak] para no heredar una racha ya cortada: si el
/// usuario volvió después de faltar, arranca de nuevo en 1.
int streakAfterActivity({
  required int stored,
  required DateTime? lastActivity,
  required DateTime today,
}) {
  final t = _atMidnight(today);
  final last = lastActivity == null ? null : _atMidnight(lastActivity);

  final vigente = currentStreak(
    stored: stored,
    lastActivity: lastActivity,
    today: today,
  );

  // Ya se contó hoy: la racha no avanza dos veces en el mismo día.
  if (last == t) return vigente > 0 ? vigente : 1;

  return vigente + 1;
}
