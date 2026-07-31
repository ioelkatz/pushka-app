import 'package:flutter/material.dart';

class S {
  S(this.locale);
  final Locale locale;

  static S of(BuildContext context) => Localizations.of<S>(context, S)!;

  static const LocalizationsDelegate<S> delegate = _SDelegate();

  static const List<Locale> supportedLocales = [
    Locale('es'),
    Locale('en'),
    Locale('fr'),
    Locale('he'),
  ];

  String get _lang => locale.languageCode;

  String _t(String es, [String? en, String? fr, String? he]) {
    return switch (_lang) {
      'en' => en ?? es,
      'fr' => fr ?? es,
      'he' => he ?? es,
      _ => es,
    };
  }

  // ---------------------------------------------------------------------------
  // COMMON
  // ---------------------------------------------------------------------------

  String get cancel => _t('Cancelar', 'Cancel', 'Annuler', 'ביטול');
  String get retry => _t('Reintentar', 'Retry', 'Réessayer', 'נסה שוב');
  String get save => _t('Guardar', 'Save', 'Enregistrer', 'שמור');
  String get delete => _t('Eliminar', 'Delete', 'Supprimer', 'מחק');
  String get understood => _t('Entendido', 'Understood', 'Compris', 'הבנתי');
  String get close => _t('Cerrar', 'Close', 'Fermer', 'סגור');
  String get add => _t('Agregar', 'Add', 'Ajouter', 'הוסף');
  String get accept => _t('Aceptar', 'Accept', 'Accepter', 'אישור');
  String get confirm => _t('Confirmar', 'Confirm', 'Confirmer', 'אישור');
  String get or_ => _t('o', 'or', 'ou', 'או');
  String get enterValidAmount => _t('Ingresa un monto válido', 'Enter a valid amount', 'Entrez un montant valide', 'הכנס סכום תקין');
  String get signInToContinue => _t('Inicia sesión para continuar', 'Sign in to continue', 'Connectez-vous pour continuer', 'התחבר כדי להמשיך');
  String get error => _t('Error', 'Error', 'Erreur', 'שגיאה');
  String get loading => _t('Cargando...', 'Loading...', 'Chargement...', 'טוען...');
  String get fieldRequired => _t('Campo requerido', 'Field required', 'Champ requis', 'שדה חובה');
  String get invalidEmail => _t('Correo inválido', 'Invalid email', 'E-mail invalide', 'כתובת דוא"ל לא תקינה');
  String get invalidPhone => _t('Número inválido', 'Invalid number', 'Numéro invalide', 'מספר לא תקין');

  // ---------------------------------------------------------------------------
  // APP DRAWER
  // ---------------------------------------------------------------------------

  String hello(String name) => _t('Hola $name', 'Hello $name', 'Bonjour $name', 'שלום $name');
  String get myPushka => _t('Mi Pushka', 'My Pushka', 'Ma Pushka', 'הפושקה שלי');
  String get wallet => _t('Billetera', 'Wallet', 'Portefeuille', 'ארנק');
  String get cardNicknameTitle => _t('Apodo de la tarjeta', 'Card nickname', 'Surnom de la carte', 'כינוי לכרטיס');
  String get cardNicknameHint => _t(
    'Opcional — un nombre para diferenciar tus tarjetas (ej: BBVA, Empresa).',
    'Optional — a name to tell your cards apart (e.g. BBVA, Work).',
    "Facultatif — un nom pour distinguer vos cartes (ex. BBVA, Travail).",
    'אופציונלי — שם להבחין בין הכרטיסים שלך (לדוגמה: BBVA, עבודה).',
  );
  String get cardNicknamePlaceholder => _t('BBVA', 'BBVA', 'BBVA', 'BBVA');
  String get cardNicknameAddAction => _t('Agregar apodo', 'Add nickname', 'Ajouter un surnom', 'הוסף כינוי');
  String get cardNicknameEditAction => _t('Editar apodo', 'Edit nickname', 'Modifier le surnom', 'ערוך כינוי');
  String get skip => _t('Omitir', 'Skip', 'Ignorer', 'דלג');

  String get deleteCardLinkedAutoEmptyTitle => _t(
    'Eliminar tarjeta',
    'Delete card',
    'Supprimer la carte',
    'מחק כרטיס',
  );
  String get deleteCardLinkedAutoEmptyBody => _t(
    '¿Seguro que quieres eliminar esta tarjeta? Esta tarjeta tiene el vaciado automático activado.',
    'Are you sure you want to delete this card? This card has auto-empty enabled.',
    'Voulez-vous vraiment supprimer cette carte ? Cette carte a le vidage automatique activé.',
    'האם אתה בטוח שברצונך למחוק כרטיס זה? הכרטיס הזה מוגדר לריקון אוטומטי.',
  );
  /// Used when deleting the auto-empty pinned card AND another saved card
  /// is available — that card auto-pins to the auto-empty after deletion,
  /// so the donor knows exactly which card future ticks will charge.
  String deleteCardLinkedAutoEmptySwitchBody(String brandLastFour) => _t(
    'El vaciado automático va a pasar a usar tu $brandLastFour a partir del próximo cobro. ¿Quieres continuar?',
    'Auto-empty will switch to your $brandLastFour from the next charge. Continue?',
    'Le vidage automatique passera à votre $brandLastFour à partir du prochain prélèvement. Continuer ?',
    'הריקון האוטומטי יעבור להשתמש ב-$brandLastFour שלך מהחיוב הבא. להמשיך?',
  );
  /// Used when deleting the auto-empty pinned card AND it's the only card
  /// left — auto-empty gets fully disabled (frequency switched to manual)
  /// since there's nothing left to charge from. The donor must reconfigure
  /// after adding a new card.
  String get deleteCardLinkedAutoEmptyDisableBody => _t(
    'El vaciado automático se va a desactivar. ¿Quieres continuar?',
    'Auto-empty will be disabled. Continue?',
    'Le vidage automatique sera désactivé. Continuer ?',
    'הריקון האוטומטי יושבת. להמשיך?',
  );

  String get cardAlreadySaved => _t(
    'Esa tarjeta ya estaba registrada.',
    'That card was already saved.',
    'Cette carte était déjà enregistrée.',
    'הכרטיס כבר היה רשום.',
  );

  String get defaultCardSubtitle => _t(
    'Tarjeta predeterminada · toca para administrar',
    'Default card · tap to manage',
    'Carte par défaut · appuyez pour gérer',
    'כרטיס ברירת מחדל · הקש לניהול',
  );
  String get addCardSubtitle => _t(
    'Tocá para agregar una tarjeta',
    'Tap to add a card',
    'Appuyez pour ajouter une carte',
    'הקש להוספת כרטיס',
  );
  String get walletAutoEmptyActiveTitle => _t(
    'Vaciado automático',
    'Auto-empty',
    'Vidage automatique',
    'ריקון אוטומטי',
  );
  String get walletAutoEmptyInactiveTitle => _t(
    'Activar vaciado automático',
    'Enable auto-empty',
    'Activer le vidage automatique',
    'הפעלת ריקון אוטומטי',
  );
  String get walletAutoEmptyInactiveSubtitle => _t(
    'Programa vaciados recurrentes con una tarjeta guardada.',
    'Schedule recurring empties with a saved card.',
    'Planifiez des vidages récurrents avec une carte enregistrée.',
    'תזמן ריקון חוזר עם כרטיס שמור.',
  );
  String get walletLastDonationTitle => _t(
    'Última donación',
    'Last donation',
    'Dernier don',
    'התרומה האחרונה',
  );
  String get today => _t('Hoy', 'Today', 'Aujourd\'hui', 'היום');
  String get yesterday => _t('Ayer', 'Yesterday', 'Hier', 'אתמול');
  String get tomorrow => _t('Mañana', 'Tomorrow', 'Demain', 'מחר');
  String daysAgo(int n) => _t('Hace $n días', '$n days ago', 'Il y a $n jours', 'לפני $n ימים');

  String get walletSavedCardsSubtitle => _t(
    'Tus tarjetas guardadas para donar y vaciar pushka.',
    'Your saved cards for donating and emptying pushka.',
    "Vos cartes enregistrées pour faire des dons et vider la pushka.",
    'הכרטיסים השמורים שלך לתרומות וריקון פושקה.',
  );
  String get reminders => _t('Recordatorios', 'Reminders', 'Rappels', 'תזכורות');
  String get history => _t('Historial', 'History', 'Historique', 'היסטוריה');
  String get settings => _t('Configuración', 'Settings', 'Paramètres', 'הגדרות');
  String get prayersAndSegulot => _t('Segulot y Rezos', 'Prayers & Blessings', 'Prières et Bénédictions', 'סגולות ותפילות');
  String get support => _t('Soporte', 'Support', 'Assistance', 'תמיכה');
  String get about => _t('Acerca de', 'About', 'À propos', 'אודות');
  String version(String v) => _t('Versión $v', 'Version $v', 'Version $v', 'גרסה $v');
  String get sponsoredBy => _t('Patrocinado por', 'Sponsored by', 'Parrainé par', 'בחסות');
  String get sponsorLine1 => _t('Rabino Menachem Mendel Meer', 'Rabbi Menachem Mendel Meer', 'Rabbin Menachem Mendel Meer', 'הרב מנחם מנדל מיר');
  String get sponsorLine2 => _t('', '', '', '');
  String get defaultUser => _t('Usuario', 'User', 'Utilisateur', 'משתמש');
  String get noEmail => _t('Sin correo', 'No email', 'Sans e-mail', 'ללא דוא"ל');

  // ---------------------------------------------------------------------------
  // PUSHKA SCREEN
  // ---------------------------------------------------------------------------

  String get fillIt => _t('¡Llénala!', 'Fill it up!', 'Remplissez-la !', 'מלא אותה!');
  String get streakDays => _t('Racha de Días', 'Day Streak', 'Série de jours', 'רצף ימים');
  String get otherAmount => _t('OTRO', 'OTHER', 'AUTRE', 'אחר');
  String get donateNowBtn => _t('DONAR AHORA', 'DONATE NOW', 'FAIRE UN DON', 'תרום עכשיו');
  String get emptyPushkaBtn => _t('VACIAR PUSHKA', 'EMPTY PUSHKA', 'VIDER LA PUSHKA', 'רוקן פושקה');
  String get changePushkaGoal => _t('CAMBIAR META DE PUSHKA', 'CHANGE PUSHKA GOAL', "CHANGER L'OBJECTIF", 'שנה יעד פושקה');
  String get addToPushka => _t('AGREGAR A PUSHKA', 'ADD TO PUSHKA', 'AJOUTER À LA PUSHKA', 'הוסף לפושקה');
  String get chooseAmount => _t('Elige un monto', 'Choose an amount', 'Choisissez un montant', 'בחר סכום');
  String get tapToEdit => _t('Toca para editar el monto', 'Tap to edit amount', 'Appuyez pour modifier', 'לחץ לעריכת הסכום');
  String addedToPushka(String amount) => _t('$amount agregado a tu Pushka', '$amount added to your Pushka', '$amount ajouté à votre Pushka', '$amount נוסף לפושקה שלך');
  String get otherAmountTitle => _t('Otro monto', 'Other amount', 'Autre montant', 'סכום אחר');
  String get amountHint => _t('Ej: 12.50', 'E.g.: 12.50', 'Ex : 12,50', 'לדוגמה: 12.50');
  String get pushkaFull => _t('Tu Pushka está llena', 'Your Pushka is full', 'Votre Pushka est pleine', 'הפושקה שלך מלאה');
  String get donationGoalReached => _t('¡Alcanzaste tu Meta de Donación!', 'You reached your Donation Goal!', 'Vous avez atteint votre objectif !', 'הגעת ליעד התרומה שלך!');
  String get donateNowTitle => _t('Donación segura', 'Secure donation', 'Don sécurisé', 'תרומה מאובטחת');
  String get donateOnce => _t('Donar una vez', 'One time', 'Une fois', 'פעם אחת');
  String get donateMonthly => _t('Mensual', 'Monthly', 'Mensuel', 'חודשי');
  String get donateMonthlyBtn => _t('Donar mensualmente', 'Donate monthly', 'Faire un don mensuel', 'תרום חודשי');
  String get dedicateDonation => _t('Dedica esta donación', 'Dedicate this donation', 'Dédier ce don', 'הקדש תרומה זו');
  String get walletGooglePayBody => _t(
        'Usá tu cuenta de Google Pay para pagar. Confirmás el pago en el momento de vaciar tu Pushka.',
        'Use your Google Pay account to pay. You confirm the payment when you empty your Pushka.',
        'Utilisez votre compte Google Pay pour payer. Vous confirmez le paiement au moment de vider votre Pushka.',
        'השתמש בחשבון Google Pay שלך לתשלום. אתה מאשר את התשלום בעת ריקון הפושקה.',
      );
  String get walletApplePayBody => _t(
        'Usá tu cuenta de Apple Pay para pagar. Confirmás el pago en el momento de vaciar tu Pushka.',
        'Use your Apple Pay account to pay. You confirm the payment when you empty your Pushka.',
        'Utilisez votre compte Apple Pay pour payer. Vous confirmez le paiement au moment de vider votre Pushka.',
        'השתמש בחשבון Apple Pay שלך לתשלום. אתה מאשר את התשלום בעת ריקון הפושקה.',
      );
  String get emptyOnce => _t('Una vez', 'One time', 'Une fois', 'פעם אחת');
  String get emptyAuto => _t('Automático', 'Automatic', 'Automatique', 'אוטומטי');
  String get emptyFrequencyLabel => _t('Frecuencia', 'Frequency', 'Fréquence', 'תדירות');
  String get emptyAutoBtn => _t('Activar vaciado automático', 'Enable auto-empty', 'Activer le vidage automatique', 'הפעל ריקון אוטומטי');
  String get amount => _t('Monto', 'Amount', 'Montant', 'סכום');
  String get optionalMessage => _t('Mensaje personal (opcional)', 'Personal message (optional)', 'Message personnel (optionnel)', 'הודעה אישית (אופציונלי)');
  String get writeMessage => _t('Escribe un mensaje...', 'Write a message...', 'Écrivez un message...', 'כתוב הודעה...');
  String get instantDonationNote => _t(
    'Donación instantánea. No reduce ni afecta el balance de tu Pushka.',
    'Instant donation. It does not reduce or affect your Pushka balance.',
    'Don instantané. Ne réduit ni n\'affecte le solde de votre Pushka.',
    'תרומה מיידית. אינה מפחיתה את יתרת הפושקה שלך.',
  );
  String get stripeNotConfigured => _t('Stripe no está configurado', 'Stripe is not configured', "Stripe n'est pas configuré", 'Stripe אינו מוגדר');
  String get biometricReasonEmpty => _t('Confirma tu identidad para vaciar la Pushka', 'Confirm your identity to empty the Pushka', 'Confirmez votre identité pour vider la Pushka', 'אמת את זהותך כדי לרוקן את הפושקה');
  String get authRequired => _t('Autenticación requerida para vaciar la Pushka', 'Authentication required to empty the Pushka', 'Authentification requise pour vider la Pushka', 'נדרש אימות לריקון הפושקה');
  String get pushkaEmptied => _t('Pushka vaciada. El pago fue procesado.', 'Pushka emptied. Payment was processed.', 'Pushka vidée. Le paiement a été traité.', 'הפושקה רוקנה. התשלום עובד.');
  String get couldNotEmpty => _t('No se pudo vaciar la Pushka', 'Could not empty the Pushka', 'Impossible de vider la Pushka', 'לא ניתן לרוקן את הפושקה');
  String get biometricReasonDonate => _t('Confirma tu identidad para procesar la donación', 'Confirm your identity to process the donation', 'Confirmez votre identité pour traiter le don', 'אמת את זהותך לעיבוד התרומה');
  String get authRequiredDonate => _t('Autenticación requerida para donar', 'Authentication required to donate', 'Authentification requise pour faire un don', 'נדרש אימות לתרומה');
  String get instantDonation => _t('Donación instantánea', 'Instant donation', 'Don instantané', 'תרומה מיידית');
  String donationProcessed(String amount) => _t('Donación de $amount procesada exitosamente', 'Donation of $amount processed successfully', 'Don de $amount traité avec succès', 'תרומה של $amount עובדה בהצלחה');
  String get donationWithCard => _t('Donación con tarjeta', 'Card donation', 'Don par carte', 'תרומה בכרטיס');
  String paymentProcessedRemaining(String amount) => _t('Pago procesado. Quedaron $amount en la Pushka.', 'Payment processed. $amount remaining in the Pushka.', 'Paiement traité. $amount restant dans la Pushka.', 'התשלום עובד. נותרו $amount בפושקה.');
  String get paymentProcessedHistory => _t('Pago procesado. Se reflejará en el historial pronto.', 'Payment processed. It will appear in your history soon.', "Paiement traité. Il apparaîtra bientôt dans l'historique.", 'התשלום עובד. יופיע בהיסטוריה בקרוב.');
  String get minAmountTitle => _t('Monto mínimo', 'Minimum amount', 'Montant minimum', 'סכום מינימום');
  String minAmountBody(String code, String symbol, String min) => _t(
    'Para procesar pagos en $code, el monto mínimo es de $symbol$min.',
    'To process payments in $code, the minimum amount is $symbol$min.',
    'Pour traiter les paiements en $code, le montant minimum est de $symbol$min.',
    'לעיבוד תשלומים ב-$code, הסכום המינימלי הוא $symbol$min.',
  );
  String get minAmountHint => _t(
    'Puedes aumentar el monto o cambiar la moneda en Configuración.',
    'You can increase the amount or change the currency in Settings.',
    'Vous pouvez augmenter le montant ou changer la devise dans les Paramètres.',
    'תוכל להגדיל את הסכום או לשנות את המטבע בהגדרות.',
  );
  String get errorSessionInvalid => _t(
    'Tu sesión no es válida. Cierra sesión e inicia de nuevo.',
    'Your session is invalid. Log out and sign in again.',
    "Votre session n'est pas valide. Déconnectez-vous et reconnectez-vous.",
    'הסשן שלך אינו תקין. התנתק והתחבר מחדש.',
  );
  String get errorSecurityCheck => _t(
    'Verificación de seguridad fallida. Intenta de nuevo.',
    'Security check failed. Try again.',
    'Vérification de sécurité échouée. Réessayez.',
    'בדיקת אבטחה נכשלה. נסה שוב.',
  );
  String get errorAccessDenied => _t(
    'Acceso denegado por seguridad. Intenta de nuevo.',
    'Access denied for security. Try again.',
    'Accès refusé pour des raisons de sécurité. Réessayez.',
    'הגישה נדחתה מטעמי אבטחה. נסה שוב.',
  );
  String get errorPaymentServer => _t(
    'Error del servidor de pagos. Verifica tu conexión e intenta de nuevo.',
    'Payment server error. Check your connection and try again.',
    'Erreur du serveur de paiement. Vérifiez votre connexion et réessayez.',
    'שגיאת שרת תשלומים. בדוק את החיבור ונסה שוב.',
  );
  String get errorServerUnavailable => _t(
    "El servidor de pagos no está disponible. Intenta más tarde.",
    "Payment server unavailable. Try later.",
    "Le serveur de paiement n'est pas disponible. Réessayez plus tard.",
    'שרת התשלומים אינו זמין. נסה מאוחר יותר.',
  );
  String get couldNotStartPayment => _t("No se pudo iniciar el pago", "Could not start payment", "Impossible de lancer le paiement", 'לא ניתן להתחיל את התשלום');
  String get paymentCanceled => _t('Pago cancelado', 'Payment canceled', 'Paiement annulé', 'התשלום בוטל');
  String paymentFailed(String msg) => _t('No se pudo completar el pago: $msg', 'Could not complete payment: $msg', 'Impossible de compléter le paiement : $msg', 'לא ניתן להשלים את התשלום: $msg');
  String get couldNotCompleteDonation => _t("No se pudo completar la donación", "Could not complete the donation", "Impossible de compléter le don", 'לא ניתן להשלים את התרומה');
  // Donation-failure dialog (replaces the auto-dismiss SnackBar UX so the
  // donor sees a persistent alert with clear next-steps: Retry, Contact rab,
  // or Close).
  String get donationFailedTitle => _t(
    'El pago no se pudo procesar',
    "Payment couldn't be processed",
    "Le paiement n'a pas pu être traité",
    'לא ניתן היה לעבד את התשלום',
  );
  String donationFailedBody(String reason) => _t(
    'Detalle: $reason\n\nPuedes intentar con otra tarjeta o contactar al rab para ayuda.',
    'Details: $reason\n\nYou can try with another card or contact the rabbi for help.',
    "Détails : $reason\n\nVous pouvez essayer avec une autre carte ou contacter le rabbin pour de l'aide.",
    'פרטים: $reason\n\nניתן לנסות בכרטיס אחר או ליצור קשר עם הרב לעזרה.',
  );
  String get donationRetryBtn => _t('Reintentar', 'Retry', 'Réessayer', 'נסה שוב');
  String get donationContactRabBtn => _t('Contactar al rab', 'Contact rabbi', 'Contacter le rabbin', 'צור קשר עם הרב');
  String get donationCloseBtn => _t('Cerrar', 'Close', 'Fermer', 'סגור');
  String get donationEmailSubject => _t(
    'Ayuda con donación',
    'Donation help',
    'Aide pour un don',
    'עזרה בתרומה',
  );
  String donationEmailBody(String reason) => _t(
    'Hola,\n\nTuve un problema al procesar mi donación en la app.\n\nDetalle del error: $reason\n\nGracias.',
    'Hello,\n\nI had an issue processing my donation in the app.\n\nError detail: $reason\n\nThank you.',
    "Bonjour,\n\nJ'ai eu un problème pour traiter mon don dans l'application.\n\nDétail de l'erreur : $reason\n\nMerci.",
    'שלום,\n\nהיתה לי בעיה בעיבוד תרומה באפליקציה.\n\nפירוט השגיאה: $reason\n\nתודה.',
  );
  String get partialDonationTitle => _t('Donación parcial', 'Partial donation', 'Don partiel', 'תרומה חלקית');
  String availableInPushka(String amount) => _t('Disponible en Pushka: $amount', 'Available in Pushka: $amount', 'Disponible dans la Pushka : $amount', 'זמין בפושקה: $amount');
  String get quickSelect => _t('Selecciona rápido', 'Quick select', 'Sélection rapide', 'בחירה מהירה');
  String get amountToDonate => _t('Monto a donar ahora', 'Amount to donate now', 'Montant à donner maintenant', 'סכום לתרומה עכשיו');
  String get donate => _t('Donar', 'Donate', 'Donner', 'תרום');
  String get cannotExceedBalance => _t('No puede ser mayor al saldo de tu Pushka', 'Cannot exceed your Pushka balance', 'Ne peut pas dépasser le solde de votre Pushka', 'לא יכול לעלות על יתרת הפושקה שלך');
  String get tzedakahSettings => _t('Configuración de Tzedaká', 'Tzedakah Settings', 'Configuration de Tsédaka', 'הגדרות צדקה');
  String get donationReasonTitle => _t('Designación', 'Designation', 'Désignation', 'ייעוד');
  String get donationReasonSubtitle => _t('Opcional — elige a qué destino va tu donación.', 'Optional — choose where your donation goes.', 'Optionnel — choisissez la destination de votre don.', 'אופציונלי — בחרו לאן הולכת התרומה.');
  String get donationReasonNone => _t('Sin designación', 'No designation', 'Sans désignation', 'ללא ייעוד');
  String get donationReasonWhereNeeded => _t('Donde se necesite más', 'Where most needed', 'Là où c\'est le plus nécessaire', 'במקום שהכי נחוץ');
  String get donationReasonFamilies => _t('Familias necesitadas', 'Families in need', 'Familles dans le besoin', 'משפחות נזקקות');
  String get donationReasonTorah => _t('Estudio de Torá', 'Torah study', 'Étude de la Torah', 'לימוד תורה');
  String get donationReasonHolidays => _t('Festividades', 'Holidays', 'Fêtes', 'חגים');
  String get donationMessageLabel => _t('Mensaje (opcional)', 'Message (optional)', 'Message (optionnel)', 'הודעה (אופציונלי)');
  String get donationMessageHint => _t('Dejá un mensaje, oración o dedicatoria', 'Leave a message, prayer or dedication', 'Laissez un message, une prière ou une dédicace', 'השאר הודעה, תפילה או הקדשה');
  List<String> get defaultDonationReasons => [
        donationReasonWhereNeeded,
        donationReasonFamilies,
        donationReasonTorah,
        donationReasonHolidays,
      ];
  String get pushkaGoalLabel => _t('META DE PUSHKA', 'PUSHKA GOAL', 'OBJECTIF DE PUSHKA', 'יעד פושקה');
  String get correctAmountLabel => _t('MONTO ACUMULADO', 'ACCUMULATED AMOUNT', 'MONTANT ACCUMULÉ', 'סכום שנצבר');
  String get correctAmountHint => _t('¿Pusiste de más? Corregí el monto acumulado.', 'Added too much? Correct the accumulated amount.', 'Trop ajouté ? Corrigez le montant accumulé.', 'הוספת יותר מדי? תקן את הסכום שנצבר.');
  String get correctAmountDialogTitle => _t('Corregir monto acumulado', 'Correct accumulated amount', 'Corriger le montant accumulé', 'תקן סכום שנצבר');
  String get correctAmountUpdated => _t('Monto corregido', 'Amount corrected', 'Montant corrigé', 'הסכום תוקן');
  String get presetAmountsLabel => _t('MONTOS PREDEFINIDOS', 'PRESET AMOUNTS', 'MONTANTS PRÉDÉFINIS', 'סכומים קבועים מראש');
  String get editQuickAmountHint => _t('Edita los montos que aparecen como botones rápidos', 'Edit the amounts that appear as quick buttons', 'Modifiez les montants des boutons rapides', 'ערוך את הסכומים המופיעים כלחצנים מהירים');
  String get allAmountsMustBePositive => _t('Todos los montos deben ser mayores a 0', 'All amounts must be greater than 0', 'Tous les montants doivent être supérieurs à 0', 'כל הסכומים חייבים להיות גדולים מ-0');
  String get settingsApplied => _t('Configuración aplicada', 'Settings applied', 'Paramètres appliqués', 'הגדרות הוחלו');
  String get customGoal => _t('Meta personalizada', 'Custom goal', 'Objectif personnalisé', 'יעד מותאם אישית');
  String get customGoalHint => _t('Ej: 4500', 'E.g.: 4500', 'Ex : 4500', 'לדוגמה: 4500');
  String get offlineMessage => _t('Sin conexión — algunos datos pueden estar desactualizados', 'Offline — some data may be out of date', 'Hors ligne — certaines données peuvent être obsolètes', 'לא מקוון — חלק מהנתונים עשויים להיות לא מעודכנים');
  String get offlineDonationBlocked => _t('Necesitas conexión a internet para procesar el pago. Verifica tu WiFi o datos.', 'You need an internet connection to process the payment. Check your WiFi or mobile data.', 'Vous avez besoin d\'une connexion internet pour traiter le paiement. Vérifiez votre WiFi ou vos données mobiles.', 'נדרש חיבור לאינטרנט לעיבוד התשלום. בדוק את ה-WiFi או הנתונים שלך.');
  String get offlineDialogTitle => _t('Sin conexión', 'Offline', 'Hors ligne', 'לא מקוון');
  String get commonUnderstood => _t('Entendido', 'Got it', 'Compris', 'הבנתי');
  String get offlineSaved => _t(
    'Sin conexión estable. Guardamos localmente y se sincronizará al reconectar.',
    'No stable connection. Saved locally, will sync on reconnect.',
    'Pas de connexion stable. Enregistré localement, synchronisation à la reconnexion.',
    'אין חיבור יציב. נשמר מקומית, יסונכרן עם חיבור מחדש.',
  );
  String get firestoreUnavailable => _t(
    'No hay conexión con Firestore. Revisa internet y vuelve a intentar.',
    'No Firestore connection. Check internet and try again.',
    'Pas de connexion à Firestore. Vérifiez internet et réessayez.',
    'אין חיבור ל-Firestore. בדוק אינטרנט ונסה שוב.',
  );
  String get couldNotSync => _t(
    'No se pudo sincronizar la configuración. Intenta nuevamente.',
    'Could not sync settings. Try again.',
    'Impossible de synchroniser les paramètres. Réessayez.',
    'לא ניתן לסנכרן הגדרות. נסה שוב.',
  );
  String get dropdownOther => _t('OTRO', 'OTHER', 'AUTRE', 'אחר');

  String get pushkaEmptyCardDesc => _t('Pushka vaciada - pago con tarjeta', 'Pushka emptied - card payment', 'Pushka vidée - paiement par carte', 'פושקה רוקנה - תשלום בכרטיס');

  // ---------------------------------------------------------------------------
  // HOLIDAY NAMES
  // ---------------------------------------------------------------------------

  String get holidayPesaj => _t('Pésaj', 'Pesach', "Pessa'h", 'פסח');
  String get holidayPesajDesc => _t(
    'Celebramos la salida de Egipto. Dona tzedaká para una seuda de Pésaj',
    'We celebrate the Exodus from Egypt. Donate tzedakah for a Pesach seuda',
    "Nous célébrons la sortie d'Égypte. Faites un don de tsédaka pour une seoudah de Pessah",
    'אנו חוגגים את יציאת מצרים. תרמו צדקה לסעודת פסח',
  );
  String get holidayShavuot => _t('Shavuot', 'Shavuot', 'Chavouot', 'שבועות');
  String get holidayShavuotDesc => _t(
    'Celebramos la entrega de la Torá. Dona tzedaká en honor a esta festividad',
    'We celebrate the giving of the Torah. Donate tzedakah in honor of this holiday',
    "Nous célébrons le don de la Torah. Faites un don de tsédaka en l'honneur de cette fête",
    'אנו חוגגים את מתן התורה. תרמו צדקה לכבוד החג',
  );
  String get holidayRoshHashana => _t('Rosh Hashaná', 'Rosh Hashanah', 'Roch Hachana', 'ראש השנה');
  String get holidayRoshHashanaBanner => _t('R. Hashaná', 'R. Hashanah', 'R. Hachana', 'ראש השנה');
  String get holidayRoshHashanaDesc => _t(
    'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
    'Jewish New Year. Start the year with tzedakah and good deeds',
    "Nouvel An juif. Commencez l'année avec la tsédaka et de bonnes actions",
    'ראש השנה היהודי. התחל את השנה עם צדקה ומעשים טובים',
  );
  String get holidayYomKippur => _t('Yom Kipur', 'Yom Kippur', 'Yom Kippour', 'יום כיפור');
  String get holidayYomKippurDesc => _t(
    "Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur",
    "Day of Atonement. Tzedakah is a special merit before Yom Kippur",
    "Jour de l'Expiation. La tsédaka est un mérite spécial avant Yom Kippour",
    'יום הכיפורים. צדקה היא זכות מיוחדת לפני יום כיפור',
  );
  String get holidaySucot => _t('Sucot', 'Sukkot', 'Souccot', 'סוכות');
  String get holidaySucotDesc => _t(
    'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
    'Festival of Booths. Share joy with those most in need',
    'Fête des Cabanes. Partagez la joie avec ceux qui en ont le plus besoin',
    'חג הסוכות. שתף שמחה עם הנזקקים ביותר',
  );
  String get holidayJanuca => _t('Janucá', 'Hanukkah', "'Hanouka", 'חנוכה');
  String get holidayJanucaDesc => _t(
    'En Janucá, cada llama nos recuerda que incluso la luz más pequeña puede vencer la oscuridad… esparce luz con tu donación de tzedaká',
    'On Hanukkah, each flame reminds us that even the smallest light can overcome darkness… spread light with your tzedakah donation',
    "À 'Hanouka, chaque flamme nous rappelle que même la plus petite lumière peut vaincre les ténèbres… diffusez la lumière avec votre don de tsédaka",
    'בחנוכה, כל להבה מזכירה לנו שאפילו האור הקטן ביותר יכול לנצח את החושך… הפיצו אור עם תרומת הצדקה שלכם',
  );
  String get holidayPurim => _t('Purim', 'Purim', 'Pourim', 'פורים');
  String get holidayPurimDesc => _t(
    "Matanot la'Evionim: regalos a los necesitados, una mitzvá central de Purim",
    "Matanot la'Evionim: gifts to the needy, a central mitzvah of Purim",
    "Matanot la'Evionim : cadeaux aux nécessiteux, une mitsva centrale de Pourim",
    "מתנות לאביונים: מתנות לנזקקים, מצווה מרכזית של פורים",
  );

  // ---------------------------------------------------------------------------
  // WALLET SCREEN
  // ---------------------------------------------------------------------------

  String get addFunds => _t('Agregar fondos', 'Add funds', 'Ajouter des fonds', 'הוסף כספים');
  String get enterAmount => _t('Ingresa monto', 'Enter amount', 'Entrez le montant', 'הכנס סכום');
  String get addToBalance => _t('Agregar al saldo', 'Add to balance', 'Ajouter au solde', 'הוסף ליתרה');
  String fundsAdded(String amount) => _t('Fondos agregados: $amount', 'Funds added: $amount', 'Fonds ajoutés : $amount', 'כספים נוספו: $amount');
  String get setFundsSubtitle => _t(
    'Aparta fondos ahora para vaciar tu Pushka después',
    'Set aside funds now to empty your Pushka later',
    'Mettez des fonds de côté maintenant pour vider votre Pushka plus tard',
    'הפרש כספים עכשיו לריקון הפושקה מאוחר יותר',
  );
  String get learnMore => _t('Aprender más', 'Learn more', 'En savoir plus', 'למידע נוסף');
  String get balanceLabel => _t('SALDO', 'BALANCE', 'SOLDE', 'יתרה');
  String get addFundsBtn => _t('+ Agregar fondos', '+ Add funds', '+ Ajouter des fonds', '+ הוסף כספים');
  String get sendRequest => _t('Enviar / Solicitar entre billeteras', 'Send / Request between wallets', 'Envoyer / Demander entre portefeuilles', 'שלח / בקש בין ארנקים');
  String get sendRequestSub => _t('Empodera a familia y amigos con tzedaká', 'Empower family and friends with tzedakah', 'Responsabilisez famille et amis avec la tsédaka', 'העצם משפחה וחברים עם צדקה');
  String get manageAutoRefill => _t('Administrar recarga automática', 'Manage auto refill', 'Gérer la recharge automatique', 'נהל טעינה אוטומטית');
  String get transactionHistory => _t('Historial de transacciones', 'Transaction history', 'Historique des transactions', 'היסטוריית עסקאות');
  String autoRefillActive(String amount, String freq) => _t('ACTIVA - $amount $freq', 'ACTIVE - $amount $freq', 'ACTIF - $amount $freq', 'פעיל - $amount $freq');
  String get autoRefillInactive => _t('RECARGA AUTOMÁTICA INACTIVA', 'AUTO REFILL INACTIVE', 'RECHARGE AUTOMATIQUE INACTIVE', 'טעינה אוטומטית לא פעילה');
  String nextRun(String date) => _t('Próxima: $date', 'Next: $date', 'Prochaine : $date', 'הבא: $date');
  String get weekly => _t('semanal', 'weekly', 'hebdomadaire', 'שבועי');
  String get monthly => _t('mensual', 'monthly', 'mensuel', 'חודשי');
  String minAmountCurrency(String currency, String amount) => _t(
    'Monto mínimo para $currency es $amount',
    'Minimum amount for $currency is $amount',
    'Montant minimum pour $currency est $amount',
    'סכום מינימום עבור $currency הוא $amount',
  );
  String get paymentCouldNotProcess => _t(
    'No se pudo procesar el pago. Intenta nuevamente.',
    'Could not process payment. Try again.',
    'Impossible de traiter le paiement. Réessayez.',
    'לא ניתן לעבד את התשלום. נסה שוב.',
  );

  // ---------------------------------------------------------------------------
  // SETTINGS SCREEN
  // ---------------------------------------------------------------------------

  String get general => _t('GENERAL', 'GENERAL', 'GÉNÉRAL', 'כללי');
  String get appearance => _t('APARIENCIA', 'APPEARANCE', 'APPARENCE', 'מראה');
  String get pushkaGoalSetting => _t('META DE PUSHKA', 'PUSHKA GOAL', 'OBJECTIF DE PUSHKA', 'יעד פושקה');
  String get presetAmount => _t('MONTO PREESTABLECIDO', 'PRESET AMOUNT', 'MONTANT PRÉDÉFINI', 'סכום קבוע מראש');
  String get emptyPushkaSetting => _t('VACIAR PUSHKA', 'EMPTY PUSHKA', 'VIDER LA PUSHKA', 'רוקן פושקה');
  String get manualEmpty => _t('Vaciar Manualmente', 'Manual Empty', 'Vidage manuel', 'ריקון ידני');
  String get currency => _t('MONEDA', 'CURRENCY', 'DEVISE', 'מטבע');
  String get language => _t('IDIOMA', 'LANGUAGE', 'LANGUE', 'שפה');
  String get langSpanish => 'Español';
  String get langEnglish => 'English';
  String get langFrench => 'Français';
  String get langHebrew => 'עברית';
  String get sound => _t('SONIDO', 'SOUND', 'SON', 'צליל');
  String get confettiSound => _t('SONIDO DE CONFETI', 'CONFETTI SOUND', 'SON DE CONFETTIS', 'צליל קונפטי');
  String get vibration => _t('VIBRACIÓN', 'VIBRATION', 'VIBRATION', 'רטט');
  String get ambientMusic => _t('MÚSICA AMBIENTAL', 'AMBIENT MUSIC', 'MUSIQUE AMBIANTE', 'מוזיקת רקע');
  String get ambientMusicSub => _t('Nigunim jasídicos de fondo', 'Hasidic nigunim in the background', 'Nigunim hassidiques en fond', 'ניגונים חסידיים ברקע');
  String get partialPayments => _t('PAGOS PARCIALES', 'PARTIAL PAYMENTS', 'PAIEMENTS PARTIELS', 'תשלומים חלקיים');
  String get biometricAuth => _t('AUTENTICACIÓN BIOMÉTRICA', 'BIOMETRIC AUTHENTICATION', 'AUTHENTIFICATION BIOMÉTRIQUE', 'אימות ביומטרי');
  String get biometricActivated => _t('Autenticación biométrica activada', 'Biometric authentication activated', 'Authentification biométrique activée', 'אימות ביומטרי הופעל');
  String get fingerprint => _t('Huella digital', 'Fingerprint', 'Empreinte digitale', 'טביעת אצבע');
  String get faceRecognition => _t('Reconocimiento facial', 'Face recognition', 'Reconnaissance faciale', 'זיהוי פנים');
  String get pinPattern => _t('PIN / Patrón', 'PIN / Pattern', 'PIN / Schéma', 'PIN / דפוס');
  String get myPushkaSection => _t('MI PUSHKA', 'MY PUSHKA', 'MA PUSHKA', 'הפושקה שלי');
  String get addPushkaBtn => _t('+ Agregar Pushka', '+ Add Pushka', '+ Ajouter Pushka', '+ הוסף פושקה');
  String get signInToSeePushkas => _t('Inicia sesión para ver tus Pushkas', 'Sign in to see your Pushkas', 'Connectez-vous pour voir vos Pushkas', 'התחבר כדי לראות את הפושקות שלך');
  String get errorLoadingPushkas => _t('No se pudieron cargar las Pushkas', 'Could not load Pushkas', 'Impossible de charger les Pushkas', 'לא ניתן לטעון את הפושקות');
  String get defaultPushkaName => _t('Pushka Jabad en Campus', 'Chabad on Campus Pushka', 'Pushka Habad sur le Campus', 'פושקה חב"ד בקמפוס');
  String get profileSection => _t('PERFIL', 'PROFILE', 'PROFIL', 'פרופיל');
  String get nameLabel => _t('NOMBRE', 'NAME', 'NOM', 'שם');
  String get emailLabel => _t('CORREO ELECTRÓNICO', 'EMAIL', 'E-MAIL', 'דוא"ל');
  String get billingEmail => _t('CORREO DE FACTURACIÓN', 'BILLING EMAIL', 'E-MAIL DE FACTURATION', 'דוא"ל לחיוב');
  String get phoneLabel => _t('NÚMERO DE TELÉFONO', 'PHONE NUMBER', 'NUMÉRO DE TÉLÉPHONE', 'מספר טלפון');
  String get mailingAddress => _t('DIRECCIÓN POSTAL', 'MAILING ADDRESS', 'ADRESSE POSTALE', 'כתובת למשלוח');
  String get manageAccount => _t('ADMINISTRAR CUENTA', 'MANAGE ACCOUNT', 'GÉRER LE COMPTE', 'נהל חשבון');
  String get deleteAccountQuestion => _t('¿Eliminar cuenta?', 'Delete account?', 'Supprimer le compte ?', 'מחק חשבון?');
  String get exportMyData => _t('Exportar mis datos', 'Export my data', 'Exporter mes données', 'ייצוא הנתונים שלי');
  String get exportInProgress => _t('Generando exportación...', 'Generating export...', "Génération de l'export...", 'מייצר ייצוא...');
  String get exportSubject => _t(
    'Adjunto mi exportación de datos de Pushka.',
    'My Pushka data export attached.',
    "Mon export de données Pushka ci-joint.",
    'מצורף ייצוא הנתונים שלי מפושקה.',
  );
  String get exportFailed => _t(
    'No se pudo generar la exportación. Intenta de nuevo.',
    'Could not generate export. Please try again.',
    "Impossible de générer l'export. Veuillez réessayer.",
    'לא ניתן ליצור ייצוא. נסה שוב.',
  );
  String get exportRateLimited => _t(
    'Llegaste al límite diario de exportaciones. Probá de nuevo mañana.',
    'You hit the daily export limit. Try again tomorrow.',
    "Vous avez atteint la limite quotidienne d'exports. Réessayez demain.",
    'הגעת למגבלת הייצוא היומית. נסה שוב מחר.',
  );
  String get logout => _t('Cerrar sesión', 'Log out', 'Déconnexion', 'התנתק');
  String get principalBadge => _t('Principal', 'Primary', 'Principal', 'ראשי');
  String get pushkaIconHebrew => 'צדקה';
  String get searchCountry => _t('Buscar país', 'Search country', 'Rechercher un pays', 'חפש מדינה');
  String get nameOrCode => _t('Nombre o código', 'Name or code', 'Nom ou code', 'שם או קוד');
  String get phoneHint => _t('Número de teléfono', 'Phone number', 'Numéro de téléphone', 'מספר טלפון');
  String enterField(String field) => _t('Ingresa $field', 'Enter $field', 'Entrez $field', 'הכנס $field');
  String get deleteAccountTitle => _t('Eliminar Cuenta', 'Delete Account', 'Supprimer le compte', 'מחק חשבון');
  String get deleteAccountBody => _t(
    '¿Está seguro de que desea eliminar su cuenta? Esta acción no se puede deshacer.',
    'Are you sure you want to delete your account? This action cannot be undone.',
    'Êtes-vous sûr de vouloir supprimer votre compte ? Cette action est irréversible.',
    'האם אתה בטוח שברצונך למחוק את החשבון? פעולה זו אינה ניתנת לביטול.',
  );
  String get accountDeleted => _t('Cuenta eliminada', 'Account deleted', 'Compte supprimé', 'החשבון נמחק');
  String get couldNotDeleteAccount => _t('No se pudo eliminar la cuenta', 'Could not delete account', 'Impossible de supprimer le compte', 'לא ניתן למחוק את החשבון');
  String get requiresRecentLogin => _t('Por seguridad, debes volver a iniciar sesión antes de eliminar tu cuenta.', 'For security, please sign in again before deleting your account.', 'Pour votre sécurité, reconnectez-vous avant de supprimer votre compte.', 'מטעמי אבטחה, התחבר שוב לפני מחיקת החשבון.');
  String get deleteConfirmWord => _t('ELIMINAR', 'DELETE', 'SUPPRIMER', 'מחק');
  String deleteTypeInstruction(String word) => _t('Escribe $word para confirmar', 'Type $word to confirm', 'Écrivez $word pour confirmer', 'כתוב $word לאישור');
  String get verifyIdentityTitle => _t('Verificar identidad', 'Verify identity', 'Vérifier l\'identité', 'אמת זהות');
  String get verifyIdentityBody => _t('Para mayor seguridad, confirma tu identidad antes de eliminar tu cuenta.', 'For security, confirm your identity before deleting your account.', 'Pour votre sécurité, confirmez votre identité avant de supprimer votre compte.', 'לאבטחתך, אמת את זהותך לפני מחיקת החשבון.');
  String get reAuthFailed => _t('No se pudo verificar la identidad', 'Could not verify identity', 'Impossible de vérifier l\'identité', 'לא ניתן לאמת זהות');
  String get verifyAndDelete => _t('Verificar y eliminar', 'Verify and delete', 'Vérifier et supprimer', 'אמת ומחק');
  String get continueLabel => _t('Continuar', 'Continue', 'Continuer', 'המשך');
  String get logoutTitle => _t('Cerrar Sesión', 'Log Out', 'Déconnexion', 'התנתקות');
  String get logoutConfirm => _t(
    '¿Está seguro de que desea cerrar sesión?',
    'Are you sure you want to log out?',
    'Êtes-vous sûr de vouloir vous déconnecter ?',
    'האם אתה בטוח שברצונך להתנתק?',
  );
  String get sessionClosed => _t('Sesión cerrada', 'Session closed', 'Session fermée', 'הסשן נסגר');
  String get pushkaGoalDialog => _t('Meta de Pushka', 'Pushka Goal', 'Objectif de Pushka', 'יעד פושקה');
  String get exampleGoalHint => _t('Ej: 3600.00', 'E.g.: 3600.00', 'Ex : 3600,00', 'לדוגמה: 3600.00');
  String get emptyPushkaFirst => _t('Vacía tu Pushka primero', 'Empty your Pushka first', "Videz d'abord votre Pushka", 'רוקן את הפושקה קודם');
  String get currencyChangeBody => _t(
    'Para cambiar de moneda, primero debes vaciar o donar el saldo actual de tu Pushka.',
    'To change currency, first empty or donate your current Pushka balance.',
    "Pour changer de devise, videz d'abord ou donnez le solde actuel de votre Pushka.",
    'כדי לשנות מטבע, עליך קודם לרוקן או לתרום את יתרת הפושקה הנוכחית.',
  );
  String get selectCurrency => _t('Seleccionar Moneda', 'Select Currency', 'Sélectionner la devise', 'בחר מטבע');
  String get changeCurrencyTitle => _t('Cambiar moneda', 'Change currency', 'Changer de devise', 'שנה מטבע');
  String get currencyChangeConfirmBody => _t(
    'El saldo actual de tu Pushka se reiniciará a \$0 al cambiar de moneda.',
    'Your current Pushka balance will be reset to \$0 when changing currency.',
    'Le solde actuel de votre Pushka sera réinitialisé à \$0 lors du changement de devise.',
    'יתרת הפושקה הנוכחית שלך תאופס ל-\$0 בעת שינוי המטבע.',
  );
  String get noBiometric => _t(
    'Tu dispositivo no soporta autenticación biométrica',
    'Your device does not support biometric authentication',
    "Votre appareil ne prend pas en charge l'authentification biométrique",
    'המכשיר שלך אינו תומך באימות ביומטרי',
  );
  String get configureDeviceSecurity => _t(
    'Configura un PIN, huella digital o reconocimiento facial en los ajustes de tu dispositivo primero',
    'Set up a PIN, fingerprint or face recognition in your device settings first',
    'Configurez un PIN, empreinte digitale ou reconnaissance faciale dans les paramètres de votre appareil',
    'הגדר PIN, טביעת אצבע או זיהוי פנים בהגדרות המכשיר תחילה',
  );
  String get authCouldNotComplete => _t(
    'No se pudo completar la autenticación',
    'Could not complete authentication',
    "Impossible de compléter l'authentification",
    'לא ניתן להשלים את האימות',
  );
  String get biometricReasonEnable => _t(
    'Confirma tu identidad para activar la autenticación biométrica',
    'Confirm your identity to enable biometric authentication',
    "Confirmez votre identité pour activer l'authentification biométrique",
    'אמת את זהותך להפעלת האימות הביומטרי',
  );
  String get scanQrCode => _t('Escanear código QR', 'Scan QR code', 'Scanner le code QR', 'סרוק קוד QR');
  String get enterPushkaId => _t('Ingresar ID Pushka', 'Enter Pushka ID', "Entrer l'ID Pushka", 'הכנס מזהה פושקה');
  String get pushkaIdHint => _t('Ingresa ID Pushka', 'Enter Pushka ID', "Entrez l'ID Pushka", 'הכנס מזהה פושקה');
  String get invalidPushkaId => _t('Ingresa un ID de Pushka válido', 'Enter a valid Pushka ID', 'Entrez un ID Pushka valide', 'הכנס מזהה פושקה תקין');
  String get pushkaAdded => _t('Pushka agregada', 'Pushka added', 'Pushka ajoutée', 'פושקה נוספה');
  String get addNewPushka => _t('Agregar nueva Pushka', 'Add new Pushka', 'Ajouter une nouvelle Pushka', 'הוסף פושקה חדשה');
  String get enterValidId => _t('Ingresa un ID válido', 'Enter a valid ID', 'Entrez un ID valide', 'הכנס מזהה תקין');

  // ---------------------------------------------------------------------------
  // REMINDERS SCREEN
  // ---------------------------------------------------------------------------

  String get noReminders => _t('No hay recordatorios', 'No reminders', 'Aucun rappel', 'אין תזכורות');
  String get tapToAddReminder => _t('Toca el botón para agregar uno', 'Tap the button to add one', "Appuyez sur le bouton pour en ajouter", 'לחץ על הכפתור להוספה');
  String get errorLoadingReminders => _t('Error cargando recordatorios', 'Error loading reminders', 'Erreur de chargement des rappels', 'שגיאה בטעינת תזכורות');
  String get addReminder => _t('+ AGREGAR RECORDATORIO', '+ ADD REMINDER', '+ AJOUTER UN RAPPEL', '+ הוסף תזכורת');
  String get deleteReminderTitle => _t('Eliminar recordatorio', 'Delete reminder', 'Supprimer le rappel', 'מחק תזכורת');
  String deleteReminderConfirm(String title) => _t('¿Eliminar "$title"?', 'Delete "$title"?', 'Supprimer "$title" ?', 'למחוק "$title"?');
  String get reminderAdded => _t('Recordatorio agregado', 'Reminder added', 'Rappel ajouté', 'תזכורת נוספה');
  String get reminderUpdated => _t('Recordatorio actualizado', 'Reminder updated', 'Rappel mis à jour', 'תזכורת עודכנה');
  String get signInToSaveReminders => _t('Inicia sesión para guardar recordatorios', 'Sign in to save reminders', 'Connectez-vous pour enregistrer les rappels', 'התחבר כדי לשמור תזכורות');
  String get couldNotSaveReminder => _t("No se pudo guardar el recordatorio", "Could not save reminder", "Impossible d'enregistrer le rappel", 'לא ניתן לשמור את התזכורת');
  String get couldNotUpdateReminder => _t("No se pudo actualizar el recordatorio", "Could not update reminder", "Impossible de mettre à jour le rappel", 'לא ניתן לעדכן את התזכורת');
  String get signInToModify => _t('Inicia sesión para modificar recordatorios', 'Sign in to modify reminders', 'Connectez-vous pour modifier les rappels', 'התחבר כדי לשנות תזכורות');
  String get signInToDelete => _t('Inicia sesión para eliminar recordatorios', 'Sign in to delete reminders', 'Connectez-vous pour supprimer les rappels', 'התחבר כדי למחוק תזכורות');
  String get couldNotDelete => _t('No se pudo eliminar el recordatorio', 'Could not delete reminder', 'Impossible de supprimer le rappel', 'לא ניתן למחוק את התזכורת');
  String reminderLimitReached(int max) => _t(
        'Límite de $max recordatorios alcanzado',
        'Limit of $max reminders reached',
        'Limite de $max rappels atteint',
        'הגעת למגבלה של $max תזכורות',
      );
  String get repeatDaily => _t('Diario', 'Daily', 'Quotidien', 'יומי');
  String get repeatWeekdays => _t('Días de semana', 'Weekdays', 'Jours ouvrables', 'ימי חול');
  String get repeatFridayHoliday => _t('Viernes y festivos', 'Friday & Holidays', 'Vendredi et fêtes', 'שישי וחגים');
  String get repeatChooseDate => _t('Elegir una fecha', 'Choose a date', 'Choisir une date', 'בחר תאריך');
  String get repeatCustom => _t('Personalizado', 'Custom', 'Personnalisé', 'מותאם אישית');
  String get editReminder => _t('Editar Recordatorio', 'Edit Reminder', 'Modifier le rappel', 'ערוך תזכורת');
  String get newReminder => _t('Nuevo Recordatorio', 'New Reminder', 'Nouveau rappel', 'תזכורת חדשה');
  String get labelSection => _t('ETIQUETA', 'LABEL', 'ÉTIQUETTE', 'תווית');
  String get reminderTitleHint => _t('Título del recordatorio', 'Reminder title', 'Titre du rappel', 'כותרת התזכורת');
  String get timeSection => _t('HORA', 'TIME', 'HEURE', 'שעה');
  String get repeatSection => _t('REPETIR', 'REPEAT', 'RÉPÉTER', 'חזור');
  String get dateSection => _t('FECHA', 'DATE', 'DATE', 'תאריך');
  String get daysSection => _t('DÍAS', 'DAYS', 'JOURS', 'ימים');
  String get includeHolidays => _t('Incluir festivos', 'Include holidays', 'Inclure les jours fériés', 'כלול חגים');
  String get secondTimeSection => _t('SEGUNDO HORARIO', 'SECOND TIME', 'DEUXIÈME HEURE', 'שעה שנייה');
  String get addSecondTime => _t('Agregar segundo horario', 'Add second time', 'Ajouter une deuxième heure', 'הוסף שעה שנייה');
  String get secondTimeLabel => _t('Segunda hora', 'Second time', 'Deuxième heure', 'שעה שנייה');
  String get advanceNoticeSection => _t('AVISO PREVIO', 'ADVANCE NOTICE', 'PRÉAVIS', 'התראה מוקדמת');
  String get atExactTime => _t('A la hora exacta', 'At exact time', 'À l\'heure exacte', 'בשעה המדויקת');
  String get minutesBefore30 => _t('30 minutos antes', '30 minutes before', '30 minutes avant', '30 דקות לפני');
  String get minutesBefore60 => _t('1 hora antes', '1 hour before', '1 heure avant', 'שעה לפני');
  String get minutesBefore90 => _t('1h 30min antes', '1.5 hours before', '1h 30min avant', 'שעה וחצי לפני');
  String get minutesBefore120 => _t('2 horas antes', '2 hours before', '2 heures avant', 'שעתיים לפני');
  String get presetsFromMain => _t('Editables con ⚙ en la pantalla principal', 'Editable with ⚙ on main screen', 'Modifiable avec ⚙ sur l\'écran principal', 'ניתן לעריכה עם ⚙ במסך הראשי');
  String get cancelBtn => _t('CANCELAR', 'CANCEL', 'ANNULER', 'ביטול');
  String get saveBtn => _t('GUARDAR', 'SAVE', 'ENREGISTRER', 'שמור');
  String get selectDate => _t('Seleccionar fecha', 'Select date', 'Sélectionner une date', 'בחר תאריך');
  String get dayL => _t('L', 'M', 'L', 'ב');
  String get dayM => _t('M', 'T', 'M', 'ג');
  String get dayX => _t('X', 'W', 'Me', 'ד');
  String get dayJ => _t('J', 'T', 'J', 'ה');
  String get dayV => _t('V', 'F', 'V', 'ו');
  String get dayS => _t('S', 'S', 'S', 'ש');
  String get dayD => _t('D', 'S', 'D', 'א');
  String get selectDateRequired => _t('Selecciona una fecha', 'Select a date', 'Sélectionnez une date', 'בחר תאריך');
  String get selectDayOrHoliday => _t('Selecciona al menos un día o festivos', 'Select at least one day or holidays', 'Sélectionnez au moins un jour ou les jours fériés', 'בחר לפחות יום אחד או חגים');
  String get enterTitle => _t('Ingresa un título', 'Enter a title', 'Entrez un titre', 'הכנס כותרת');
  String get titleTooShort => _t('Título muy corto', 'Title too short', 'Titre trop court', 'הכותרת קצרה מדי');

  // ---------------------------------------------------------------------------
  // HISTORY SCREEN
  // ---------------------------------------------------------------------------

  String get filterAll => _t('Todos', 'All', 'Tous', 'הכל');
  String get filterTzedaka => _t('Mi Tzedaka', 'My Tzedakah', 'Ma Tsédaka', 'הצדקה שלי');
  String get filterPushkaEmpty => _t('Pushka Vacía', 'Pushka Empty', 'Pushka vidée', 'פושקה ריקה');
  String get noTransactions => _t('No hay transacciones', 'No transactions', 'Aucune transaction', 'אין עסקאות');
  String get noTransactionsSubtitle => _t('Tus donaciones aparecerán aquí', 'Your donations will appear here', 'Vos dons apparaîtront ici', 'התרומות שלך יופיעו כאן');
  String get noContactsSubtitle => _t('Agregá tu primer contacto con el botón +', 'Add your first contact with the + button', 'Ajoutez votre premier contact avec le bouton +', 'הוסף את הקשר הראשון שלך עם כפתור +');
  String get errorLoadingHistory => _t("Error cargando historial", "Error loading history", "Erreur de chargement de l'historique", 'שגיאה בטעינת ההיסטוריה');
  String get pending => _t('Pendiente', 'Pending', 'En attente', 'ממתין');
  String get historyDate => _t('Fecha', 'Date', 'Date', 'תאריך');
  String get historyDescription => _t('Descripción', 'Description', 'Description', 'תיאור');
  String get historyMethod => _t('Método', 'Method', 'Méthode', 'שיטה');
  String get historyStatus => _t('Estado', 'Status', 'Statut', 'סטטוס');
  String showingLastN(int n) => _t(
        'Mostrando las últimas $n transacciones',
        'Showing last $n transactions',
        'Affichage des $n dernières transactions',
        'מציג $n עסקאות אחרונות',
      );
  String get loadMore => _t('Cargar más', 'Load more', 'Charger plus', 'טען עוד');
  String get deviceClockSkewError => _t(
        'La hora de tu dispositivo parece incorrecta. Ajusta la fecha y hora e intenta de nuevo.',
        "Your device's date/time looks wrong. Fix it and try again.",
        "L'heure de votre appareil semble incorrecte. Corrigez-la et réessayez.",
        'תאריך/שעה של המכשיר שגויים. תקן ונסה שוב.',
      );

  // ---------------------------------------------------------------------------
  // TRANSACTION DOMAIN
  // ---------------------------------------------------------------------------

  String get typeTzedaka => _t('Mi Tzedaka', 'My Tzedakah', 'Ma Tsédaka', 'הצדקה שלי');
  String get typePushkaEmpty => _t('Pushka Vacía', 'Pushka Empty', 'Pushka vidée', 'פושקה ריקה');
  String get methodCard => _t('Tarjeta', 'Card', 'Carte', 'כרטיס');
  String get methodCheck => _t('Cheque', 'Check', 'Chèque', "צ'ק");
  String get methodTransfer => _t('Transferencia', 'Transfer', 'Virement', 'העברה');
  String get methodDaf => _t('DAF', 'DAF', 'DAF', 'DAF');
  String get methodAuto => _t('Automático', 'Automatic', 'Automatique', 'אוטומטי');
  String get statusCompleted => _t('Completado', 'Completed', 'Terminé', 'הושלם');
  String get statusPending => _t('Pendiente', 'Pending', 'En attente', 'ממתין');
  String get statusConfirmed => _t('Confirmado', 'Confirmed', 'Confirmé', 'אושר');

  // ---------------------------------------------------------------------------
  // REMINDER DOMAIN
  // ---------------------------------------------------------------------------

  String get dayMonShort => _t('Lun', 'Mon', 'Lun', "ב'");
  String get dayTueShort => _t('Mar', 'Tue', 'Mar', "ג'");
  String get dayWedShort => _t('Mié', 'Wed', 'Mer', "ד'");
  String get dayThuShort => _t('Jue', 'Thu', 'Jeu', "ה'");
  String get dayFriShort => _t('Vie', 'Fri', 'Ven', "ו'");
  String get daySatShort => _t('Sáb', 'Sat', 'Sam', 'שב');
  String get daySunShort => _t('Dom', 'Sun', 'Dim', "א'");
  String get weekdaysLabel => _t('Días de Semana', 'Weekdays', 'Jours ouvrables', 'ימי חול');
  String get everyDay => _t('Todos los días', 'Every day', 'Tous les jours', 'כל יום');
  String get holidays => _t('Festivos', 'Holidays', 'Jours fériés', 'חגים');
  String minBefore(String n) => _t('$n min antes', '$n min before', '$n min avant', '$n דקות לפני');

  // ---------------------------------------------------------------------------
  // AUTH – LOGIN SCREEN
  // ---------------------------------------------------------------------------

  String get welcome => _t('Bienvenido', 'Welcome', 'Bienvenue', 'ברוך הבא');
  String get signInSubtitle => _t('Inicia sesión para continuar', 'Sign in to continue', 'Connectez-vous pour continuer', 'התחבר כדי להמשיך');
  String get emailField => _t('Correo electrónico', 'Email', 'E-mail', 'דוא"ל');
  String get passwordField => _t('Contraseña', 'Password', 'Mot de passe', 'סיסמה');
  String get forgotPassword => _t('¿Olvidaste tu contraseña?', 'Forgot your password?', 'Mot de passe oublié ?', 'שכחת סיסמה?');
  String get signIn => _t('Iniciar sesión', 'Sign in', 'Se connecter', 'התחבר');
  String get continueGoogle => _t('Continuar con Google', 'Continue with Google', 'Continuer avec Google', 'המשך עם Google');
  String get continueApple => _t('Continuar con Apple', 'Continue with Apple', 'Continuer avec Apple', 'המשך עם Apple');
  String get noAccount => _t('¿No tienes cuenta?', "Don't have an account?", "Vous n'avez pas de compte ?", 'אין לך חשבון?');
  String get createAccount => _t('Crear cuenta', 'Create account', 'Créer un compte', 'צור חשבון');
  String signInError(String e) => _t('Error al iniciar sesión: $e', 'Sign in error: $e', 'Erreur de connexion : $e', 'שגיאת התחברות: $e');
  String get enterEmailForReset => _t(
    'Ingresa tu correo para recuperar la contraseña',
    'Enter your email to reset your password',
    'Entrez votre e-mail pour réinitialiser votre mot de passe',
    'הכנס את הדוא"ל לאיפוס הסיסמה',
  );
  String get resetEmailSent => _t(
    'Te enviamos un correo para restablecer tu contraseña',
    'We sent you an email to reset your password',
    'Nous vous avons envoyé un e-mail pour réinitialiser votre mot de passe',
    'שלחנו לך דוא"ל לאיפוס הסיסמה',
  );
  String genericError(String e) => _t('Error: $e', 'Error: $e', 'Erreur : $e', 'שגיאה: $e');
  String googleError(String e) => _t('Error con Google: $e', 'Google error: $e', 'Erreur Google : $e', 'שגיאת Google: $e');
  String appleError(String e) => _t('Error con Apple: $e', 'Apple error: $e', 'Erreur Apple : $e', 'שגיאת Apple: $e');
  String get enterYourEmail => _t('Ingresa tu correo', 'Enter your email', 'Entrez votre e-mail', 'הכנס את הדוא"ל שלך');
  String get enterYourPassword => _t('Ingresa tu contraseña', 'Enter your password', 'Entrez votre mot de passe', 'הכנס את הסיסמה שלך');
  String get min6Chars => _t('Mínimo 6 caracteres', 'Minimum 6 characters', '6 caractères minimum', 'מינימום 6 תווים');
  String get emailNotValid => _t('El correo no es válido', 'The email is not valid', "L'e-mail n'est pas valide", 'הדוא"ל אינו תקין');
  String get accountDisabled => _t('Esta cuenta está deshabilitada', 'This account is disabled', 'Ce compte est désactivé', 'חשבון זה מושבת');
  String get noAccountWithEmail => _t('No existe una cuenta con ese correo', 'No account exists with that email', "Aucun compte n'existe avec cet e-mail", 'לא קיים חשבון עם הדוא"ל הזה');
  String get wrongPassword => _t('Contraseña incorrecta', 'Incorrect password', 'Mot de passe incorrect', 'סיסמה שגויה');
  String get tooManyRequests => _t('Demasiados intentos, intenta más tarde', 'Too many attempts, try later', 'Trop de tentatives, réessayez plus tard', 'יותר מדי ניסיונות, נסה מאוחר יותר');
  String get networkError => _t('Error de red, revisa tu conexión', 'Network error, check your connection', 'Erreur réseau, vérifiez votre connexion', 'שגיאת רשת, בדוק את החיבור');
  String signInErrorCode(String code) => _t('Error al iniciar sesión: $code', 'Sign in error: $code', 'Erreur de connexion : $code', 'שגיאת התחברות: $code');
  String get googlePlayError => _t(
    'Error al iniciar con Google. Revisa Servicios de Google Play y vuelve a intentar',
    'Google sign in error. Check Google Play Services and try again',
    'Erreur de connexion Google. Vérifiez les services Google Play et réessayez',
    'שגיאת כניסה עם Google. בדוק את שירותי Google Play ונסה שוב',
  );
  String get signInCanceled => _t('Inicio de sesión cancelado', 'Sign in canceled', 'Connexion annulée', 'ההתחברות בוטלה');
  String get emailDifferentProvider => _t(
    'El correo ya está registrado con otro método',
    'Email already registered with another method',
    'E-mail déjà enregistré avec une autre méthode',
    'הדוא"ל כבר רשום עם שיטה אחרת',
  );

  // ---------------------------------------------------------------------------
  // AUTH – REGISTER SCREEN
  // ---------------------------------------------------------------------------

  String get createAccountTitle => _t('Crear cuenta', 'Create Account', 'Créer un compte', 'צור חשבון');
  String get createYourAccount => _t('Crea tu cuenta', 'Create your account', 'Créez votre compte', 'צור את החשבון שלך');
  String get completeData => _t('Completa tus datos para comenzar', 'Complete your data to get started', 'Complétez vos données pour commencer', 'השלם את הפרטים שלך כדי להתחיל');
  String get fullName => _t('Nombre completo', 'Full name', 'Nom complet', 'שם מלא');
  String createAccountError(String e) => _t('Error al crear cuenta: $e', 'Error creating account: $e', 'Erreur de création de compte : $e', 'שגיאה ביצירת חשבון: $e');
  String get enterYourName => _t('Ingresa tu nombre', 'Enter your name', 'Entrez votre nom', 'הכנס את שמך');
  String get nameTooShort => _t('Nombre demasiado corto', 'Name too short', 'Nom trop court', 'השם קצר מדי');
  String get emailInUse => _t('Ese correo ya está registrado', 'That email is already registered', 'Cet e-mail est déjà enregistré', 'הדוא"ל הזה כבר רשום');
  String get weakPassword => _t('La contraseña es muy débil', 'The password is too weak', 'Le mot de passe est trop faible', 'הסיסמה חלשה מדי');
  String get registrationNotAllowed => _t(
    'Este método de registro no está habilitado',
    'This registration method is not enabled',
    "Cette méthode d'inscription n'est pas activée",
    'שיטת הרישום הזו אינה מופעלת',
  );
  String createAccountErrorCode(String code) => _t('Error al crear cuenta: $code', 'Error creating account: $code', 'Erreur de création de compte : $code', 'שגיאה ביצירת חשבון: $code');
  String verificationEmailSent(String email) => _t(
    'Cuenta creada. Revisa $email para verificar tu correo.',
    'Account created. Check $email to verify your email.',
    'Compte créé. Vérifiez $email pour confirmer votre adresse.',
    'החשבון נוצר. בדוק את $email לאישור כתובת הדוא"ל.',
  );
  String get passwordTooShort => _t('Mínimo 8 caracteres', 'Minimum 8 characters', 'Minimum 8 caractères', 'מינימום 8 תווים');
  String get passwordNeedsNumber => _t('Debe incluir al menos un número', 'Must include at least one number', 'Doit contenir au moins un chiffre', 'חייב לכלול לפחות ספרה אחת');
  String get passwordNeedsUppercase => _t('Debe incluir al menos una mayúscula', 'Must include at least one uppercase letter', 'Doit contenir au moins une majuscule', 'חייב לכלול לפחות אות גדולה אחת');

  // ---------------------------------------------------------------------------
  // SUPPORT SCREEN
  // ---------------------------------------------------------------------------

  String get supportHebrewTitle => 'צדקת רבי מאיר בעל הנס';
  String get colelJabad => _t('Jabad en Campus', 'Chabad on Campus', 'Habad sur le Campus', 'חב"ד בקמפוס');
  String get tagline1788 => _t(
    'Rab Menachem Mendel Meer',
    'Rabbi Menachem Mendel Meer',
    'Rabbin Menachem Mendel Meer',
    'הרב מנחם מנדל מיר',
  );
  String get appVersionSection => _t('VERSIÓN DE LA APP', 'APP VERSION', "VERSION DE L'APP", 'גרסת האפליקציה');
  String get supportSection => _t('SOPORTE', 'SUPPORT', 'ASSISTANCE', 'תמיכה');
  /// BUG-060 fix: brand-parameterised version of the "Learn more" link.
  /// The legacy getter still returns the Jabad-specific copy.
  String learnMoreAbout(String brand) => _t(
        'Conoce más de $brand',
        'Learn more about $brand',
        'En savoir plus sur $brand',
        'גלה עוד על $brand',
      );
  String get learnMoreColel => learnMoreAbout(colelJabad);
  String get developedBy => _t('DESARROLLADO POR', 'DEVELOPED BY', 'DÉVELOPPÉ PAR', 'פותח על ידי');

  // ---------------------------------------------------------------------------
  // ABOUT SCREEN
  // ---------------------------------------------------------------------------

  /// BUG-060 fix: brand-parameterized about-screen labels. Passing the
  /// tenant's `appName` produces tenant-correct headers; falling back to
  /// `colelJabad` preserves the original "Jabad en Campus" experience when
  /// no tenant config is loaded yet.
  String aboutBreadcrumbFor(String brand) => _t(
        'Acerca de | $brand',
        'About | $brand',
        'À propos | $brand',
        'אודות | $brand',
      );
  // Legacy getter — kept for callers that don't yet pass a brand. Equivalent
  // to aboutBreadcrumbFor(colelJabad).
  String get aboutBreadcrumb => aboutBreadcrumbFor(colelJabad);
  String get aboutTitle => colelJabad;
  String get aboutSection => _t('Acerca de', 'About', 'À propos', 'אודות');
  String get aboutP1 => _t(
    'Bienvenido a Jabad en Campus. Esta aplicación fue creada para facilitar la tzedaká en nuestra comunidad, liderada por el Rabino Menachem Mendel Meer.',
    'Welcome to Chabad on Campus. This app was created to facilitate tzedakah in our community, led by Rabbi Menachem Mendel Meer.',
    "Bienvenue à Habad sur le Campus. Cette application a été créée pour faciliter la tsedaka dans notre communauté, dirigée par le Rabbin Menachem Mendel Meer.",
    'ברוכים הבאים לחב"ד בקמפוס. אפליקציה זו נוצרה כדי להקל על הצדקה בקהילתנו, בהנהגת הרב מנחם מענדל מאיר.',
  );
  String get aboutP2 => _t(
    'Nuestra misión es acercar la luz de la Torá y la tzedaká a cada persona, creando una comunidad unida y comprometida con los valores judíos de compasión y generosidad.',
    'Our mission is to bring the light of Torah and tzedakah to every person, building a united community committed to Jewish values of compassion and generosity.',
    "Notre mission est d'apporter la lumière de la Torah et de la tsedaka à chaque personne, en construisant une communauté unie et engagée dans les valeurs juives de compassion et de générosité.",
    'שליחותנו להביא את אור התורה והצדקה לכל אחד, ולבנות קהילה מאוחדת ומחויבת לערכי החמלה והנדיבות היהודיים.',
  );
  String get aboutP3 => _t(
    'Cada donación que realizas a través de esta Pushka contribuye directamente a las actividades de Jabad en Campus y al apoyo de nuestra comunidad.',
    'Every donation you make through this Pushka directly contributes to Chabad on Campus activities and the support of our community.',
    "Chaque don que vous effectuez via cette Pushka contribue directement aux activités de Habad sur le Campus et au soutien de notre communauté.",
    'כל תרומה שאתם תורמים דרך הפושקה הזו תורמת ישירות לפעילויות חב"ד בקמפוס ולתמיכה בקהילתנו.',
  );
  String get privacyPolicy => _t('Política de Privacidad', 'Privacy Policy', 'Politique de confidentialité', 'מדיניות פרטיות');
  String get termsOfService => _t('Términos de Servicio', 'Terms of Service', "Conditions d'utilisation", 'תנאי שימוש');
  String get legalTitle => _t('Privacidad y Términos', 'Privacy & Terms', 'Confidentialité et Conditions', 'פרטיות ותנאים');
  String get legalContactFooter => _t(
        'Para cualquier pregunta sobre estos documentos, escríbenos a support@pushkaapp.com',
        'For any question about these documents, write to support@pushkaapp.com',
        'Pour toute question concernant ces documents, écrivez-nous à support@pushkaapp.com',
        'לשאלות בנוגע למסמכים אלה: support@pushkaapp.com',
      );
  /// BUG-060 fix: copyright line parameterised on tenant brand so each org
  /// shows their own name in the about/legal footer instead of the hardcoded
  /// "Jabad en Campus".
  String copyrightFor(String brand) => _t(
        '© 2026 $brand. Todos los derechos reservados.',
        '© 2026 $brand. All rights reserved.',
        '© 2026 $brand. Tous droits réservés.',
        '© 2026 $brand. כל הזכויות שמורות.',
      );
  String get copyright => copyrightFor(colelJabad);

  // ---------------------------------------------------------------------------
  // AUTO EMPTY SCREEN
  // ---------------------------------------------------------------------------

  String get autoEmpty => _t('Auto Vaciar', 'Auto Empty', 'Vidage automatique', 'ריקון אוטומטי');
  String get autoEmptyLabel => _t('Auto Vaciado', 'Auto Empty', 'Vidage automatique', 'ריקון אוטומטי');
  String get activated => _t('Activado', 'Activated', 'Activé', 'מופעל');
  String get deactivated => _t('Desactivado', 'Deactivated', 'Désactivé', 'מושבת');
  String get autoEmptyInfo => _t(
    'Cuando esté activado, tu Pushka se vaciará automáticamente según la frecuencia que elijas.',
    'When activated, your Pushka will empty automatically based on the frequency you choose.',
    'Lorsqu\'il est activé, votre Pushka se videra automatiquement selon la fréquence choisie.',
    'כשמופעל, הפושקה שלך תתרוקן אוטומטית לפי התדירות שתבחר.',
  );
  String get frequency => _t('Frecuencia', 'Frequency', 'Fréquence', 'תדירות');
  String get freqWeekly => _t('Semanal', 'Weekly', 'Hebdomadaire', 'שבועי');
  String get freqMonthly => _t('Mensual', 'Monthly', 'Mensuel', 'חודשי');
  String get freqErevRosh => _t('Erev Rosh Jódesh', 'Erev Rosh Chodesh', "Veille de Roch 'Hodech", 'ערב ראש חודש');
  String get dayOfWeek => _t('Día de la semana', 'Day of the week', 'Jour de la semaine', 'יום בשבוע');
  String get dayOfMonth => _t('Día del mes', 'Day of the month', 'Jour du mois', 'יום בחודש');
  String get erevRoshNote => _t(
    'Se vaciará automáticamente cada víspera de Rosh Jódesh según el calendario hebreo.',
    'Will empty automatically every Erev Rosh Chodesh according to the Hebrew calendar.',
    "Se videra automatiquement chaque veille de Roch 'Hodech selon le calendrier hébraïque.",
    'יתרוקן אוטומטית בכל ערב ראש חודש לפי הלוח העברי.',
  );
  String nextEmpty(String date) => _t('Próximo vaciado: $date', 'Next empty: $date', 'Prochain vidage : $date', 'ריקון הבא: $date');
  String get notScheduled => _t('No programado', 'Not scheduled', 'Non programmé', 'לא מתוזמן');
  String get pushkaTopOff => _t('Relleno de Pushka', 'Pushka Top Off', 'Remplissage de la Pushka', 'השלמת פושקה');
  String get topOffDescription => _t(
    'El saldo se completará al mínimo antes de vaciar.',
    'The balance will be topped off to the minimum before emptying.',
    'Le solde sera complété au minimum avant le vidage.',
    'היתרה תושלם למינימום לפני הריקון.',
  );
  String get settingsSaved => _t('Configuración guardada', 'Settings saved', 'Paramètres enregistrés', 'הגדרות נשמרו');
  String get saveError => _t('Error al guardar. Intenta nuevamente.', 'Error saving. Try again.', "Erreur d'enregistrement. Réessayez.", 'שגיאה בשמירה. נסה שוב.');
  String get autoEmptyConsentTitle => _t(
    'Autorización',
    'Authorization',
    'Autorisation',
    'אישור',
  );
  String get autoEmptyConsentBody => _t(
    'Al activar el vaciado automático, Pushka vaciará tu alcancía según la frecuencia elegida y el monto acumulado será cobrado a tu tarjeta de pago registrada en ese momento.\n\nEsto constituye una autorización de cobro periódico. Puedes cancelarlo en cualquier momento desde esta misma pantalla.',
    'By activating automatic emptying, Pushka will empty your pushka according to the chosen frequency, and the accumulated amount will be charged to your registered payment card at that time.\n\nThis constitutes authorization for periodic charges. You can cancel at any time from this screen.',
    'En activant le vidage automatique, Pushka videra votre tirelire selon la fréquence choisie et le montant accumulé sera débité de votre carte de paiement enregistrée.\n\nCela constitue une autorisation de prélèvement périodique. Vous pouvez l\'annuler à tout moment depuis cet écran.',
    'בהפעלת הריקון האוטומטי, Pushka תרוקן את הקופה שלך לפי התדירות שנבחרה, והסכום שנצבר יחויב בכרטיס התשלום הרשום שלך באותו רגע.\n\nזהו אישור לחיובים תקופתיים. ניתן לבטל בכל עת מהמסך הזה.',
  );
  String get autoEmptyConsentBullet1 => _t(
    '• El cobro se realiza por el monto exacto acumulado en tu Pushka.',
    '• The charge is for the exact amount accumulated in your Pushka.',
    '• Le débit correspond au montant exact accumulé dans votre Pushka.',
    '• החיוב הוא על הסכום המדויק שנצבר בפושקה שלך.',
  );
  String get autoEmptyConsentBullet3 => _t(
    '• Puedes cancelar o modificar esta configuración en cualquier momento.',
    '• You can cancel or modify this setting at any time.',
    '• Vous pouvez annuler ou modifier ce paramètre à tout moment.',
    '• ניתן לבטל או לשנות הגדרה זו בכל עת.',
  );
  String get autoEmptyConsentAccept => _t(
    'Acepto y Activo',
    'I Accept and Activate',
    'J\'accepte et j\'active',
    'אני מסכים ומפעיל',
  );
  String get autoEmptyConsentCancel => _t('Cancelar', 'Cancel', 'Annuler', 'ביטול');
  String get cardForAutoEmpty => _t('Tarjeta para el cobro automático', 'Card for automatic charge', 'Carte pour le prélèvement automatique', 'כרטיס לחיוב אוטומטי');
  String get dayMonFull => _t('Lunes', 'Monday', 'Lundi', 'שני');
  String get dayTueFull => _t('Martes', 'Tuesday', 'Mardi', 'שלישי');
  String get dayWedFull => _t('Miércoles', 'Wednesday', 'Mercredi', 'רביעי');
  String get dayThuFull => _t('Jueves', 'Thursday', 'Jeudi', 'חמישי');
  String get dayFriFull => _t('Viernes', 'Friday', 'Vendredi', 'שישי');
  String get daySatFull => _t('Sábado', 'Saturday', 'Samedi', 'שבת');
  String get daySunFull => _t('Domingo', 'Sunday', 'Dimanche', 'ראשון');
  String get monthJan => _t('Ene', 'Jan', 'Jan', 'ינו');
  String get monthFeb => _t('Feb', 'Feb', 'Fév', 'פבר');
  String get monthMar => _t('Mar', 'Mar', 'Mar', 'מרץ');
  String get monthApr => _t('Abr', 'Apr', 'Avr', 'אפר');
  String get monthMay => _t('May', 'May', 'Mai', 'מאי');
  String get monthJun => _t('Jun', 'Jun', 'Jun', 'יונ');
  String get monthJul => _t('Jul', 'Jul', 'Juil', 'יול');
  String get monthAug => _t('Ago', 'Aug', 'Aoû', 'אוג');
  String get monthSep => _t('Sep', 'Sep', 'Sep', 'ספט');
  String get monthOct => _t('Oct', 'Oct', 'Oct', 'אוק');
  String get monthNov => _t('Nov', 'Nov', 'Nov', 'נוב');
  String get monthDec => _t('Dic', 'Dec', 'Déc', 'דצמ');

  // ---------------------------------------------------------------------------
  // WALLET AUTO REFILL
  // ---------------------------------------------------------------------------

  String get autoRefillSaved => _t('Recarga automática guardada', 'Auto refill saved', 'Recharge automatique enregistrée', 'טעינה אוטומטית נשמרה');
  String couldNotSaveError(String e) => _t('No se pudo guardar: $e', 'Could not save: $e', "Impossible d'enregistrer : $e", 'לא ניתן לשמור: $e');
  String get frequencyLabel => _t('FRECUENCIA', 'FREQUENCY', 'FRÉQUENCE', 'תדירות');
  String get recurringDay => _t('DÍA RECURRENTE', 'RECURRING DAY', 'JOUR RÉCURRENT', 'יום חוזר');
  String get selectHint => _t('Seleccionar', 'Select', 'Sélectionner', 'בחר');
  String get amountLabel => _t('MONTO', 'AMOUNT', 'MONTANT', 'סכום');
  String get disableAutoRefill => _t('DESACTIVAR RECARGA AUTOMÁTICA', 'DISABLE AUTO REFILL', 'DÉSACTIVER LA RECHARGE AUTOMATIQUE', 'בטל טעינה אוטומטית');
  String get autoRefillDisabled => _t('Recarga automática desactivada', 'Auto refill disabled', 'Recharge automatique désactivée', 'טעינה אוטומטית בוטלה');

  // ---------------------------------------------------------------------------
  // WALLET SEND / REQUEST
  // ---------------------------------------------------------------------------

  String get selectContactBanner => _t(
    'Selecciona un contacto para enviar o solicitar dinero.',
    'Select a contact to send or request money.',
    "Sélectionnez un contact pour envoyer ou demander de l'argent.",
    'בחר קשר לשליחה או בקשת כסף.',
  );
  String get contactAdded => _t('Contacto agregado', 'Contact added', 'Contact ajouté', 'קשר נוסף');
  String get verification => _t('Verificación', 'Verification', 'Vérification', 'אימות');
  String get verificationBody => _t(
    'Para enviar o solicitar tzedaká, primero verifica el contacto:\n• Escanea su ID de billetera (arriba a la derecha en esta pantalla), o\n• Escribe el código de 8 dígitos que te comparta.',
    'To send or request tzedakah, first verify the contact:\n• Scan their wallet ID (top right on this screen), or\n• Enter the 8-digit code they share with you.',
    "Pour envoyer ou demander de la tsédaka, vérifiez d'abord le contact :\n• Scannez leur ID de portefeuille (en haut à droite de cet écran), ou\n• Entrez le code à 8 chiffres qu'ils vous partagent.",
    'כדי לשלוח או לבקש צדקה, אמת קודם את הקשר:\n• סרוק את מזהה הארנק שלו (למעלה מימין במסך זה), או\n• הכנס את הקוד בן 8 הספרות שהוא שיתף איתך.',
  );
  String get addNewContact => _t('+ AGREGAR NUEVO CONTACTO', '+ ADD NEW CONTACT', '+ AJOUTER UN NOUVEAU CONTACT', '+ הוסף קשר חדש');
  String get yourContacts => _t('TUS CONTACTOS', 'YOUR CONTACTS', 'VOS CONTACTS', 'הקשרים שלך');
  String get signInForContacts => _t('Inicia sesión para ver tus contactos', 'Sign in to see your contacts', 'Connectez-vous pour voir vos contacts', 'התחבר כדי לראות את הקשרים שלך');
  String get errorLoadingContacts => _t('Error cargando contactos', 'Error loading contacts', 'Erreur de chargement des contacts', 'שגיאה בטעינת קשרים');
  String get noContacts => _t('Sin contactos', 'No contacts', 'Aucun contact', 'אין קשרים');
  String get defaultContact => _t('Contacto', 'Contact', 'Contact', 'קשר');
  String idPrefix(String id) => _t('ID: $id', 'ID: $id', 'ID : $id', 'מזהה: $id');
  String get send => _t('ENVIAR', 'SEND', 'ENVOYER', 'שלח');
  String get request => _t('SOLICITAR', 'REQUEST', 'DEMANDER', 'בקש');
  String sent(String amount, String id) => _t('Enviado $amount a $id', 'Sent $amount to $id', 'Envoyé $amount à $id', 'נשלח $amount ל-$id');
  String requestSent(String amount) => _t('Solicitud de $amount enviada', 'Request for $amount sent', 'Demande de $amount envoyée', 'בקשה של $amount נשלחה');
  String get insufficientFunds => _t('Fondos insuficientes', 'Insufficient funds', 'Fonds insuffisants', 'יתרה לא מספיקה');
  String get couldNotTransfer => _t('No se pudo completar la transferencia', 'Could not complete the transfer', 'Impossible de compléter le transfert', 'לא ניתן להשלים את ההעברה');
  String get couldNotSendRequest => _t('No se pudo enviar la solicitud', 'Could not send the request', 'Impossible d\'envoyer la demande', 'לא ניתן לשלוח את הבקשה');
  String get couldNotAddContact => _t('No se pudo agregar el contacto', 'Could not add the contact', 'Impossible d\'ajouter le contact', 'לא ניתן להוסיף את הקשר');
  String get cannotAddSelf => _t('No puedes agregar tu propia billetera como contacto', 'You cannot add your own wallet as a contact', 'Vous ne pouvez pas ajouter votre propre portefeuille comme contact', 'אינך יכול להוסיף את הארנק שלך עצמך כקשר');
  String get couldNotConfirmTopUp => _t('No se pudo confirmar la recarga', 'Could not confirm the top-up', 'Impossible de confirmer la recharge', 'לא ניתן לאשר את הטעינה');

  // ---------------------------------------------------------------------------
  // WALLET REQUESTS
  // ---------------------------------------------------------------------------

  String get pendingRequests => _t('Solicitudes pendientes', 'Pending requests', 'Demandes en attente', 'בקשות ממתינות');
  String get noPendingRequests => _t('No tienes solicitudes pendientes', 'No pending requests', 'Aucune demande en attente', 'אין בקשות ממתינות');
  String requestFrom(String walletId) => _t('Solicitud de $walletId', 'Request from $walletId', 'Demande de $walletId', 'בקשה מ-$walletId');
  String requestAmount(String amount) => _t('Monto: $amount', 'Amount: $amount', 'Montant : $amount', 'סכום: $amount');
  String get acceptRequest => _t('Aceptar', 'Accept', 'Accepter', 'אשר');
  String get rejectRequest => _t('Rechazar', 'Reject', 'Rejeter', 'דחה');
  String get requestAccepted => _t('Solicitud aceptada. Fondos enviados.', 'Request accepted. Funds sent.', 'Demande acceptée. Fonds envoyés.', 'הבקשה אושרה. הכספים נשלחו.');
  String get requestRejected => _t('Solicitud rechazada', 'Request rejected', 'Demande rejetée', 'הבקשה נדחתה');
  String get confirmAcceptRequest => _t('Confirmar envío', 'Confirm send', 'Confirmer l\'envoi', 'אשר שליחה');
  String confirmAcceptBody(String amount, String walletId) => _t(
    '¿Enviás $amount de tu billetera a $walletId?',
    'Send $amount from your wallet to $walletId?',
    'Envoyer $amount de votre portefeuille à $walletId ?',
    'שלח $amount מהארנק שלך ל-$walletId?',
  );
  String confirmRejectBody(String amount, String walletId) => _t(
    '¿Rechazás la solicitud de $amount de $walletId?',
    'Reject the request for $amount from $walletId?',
    'Rejeter la demande de $amount de $walletId ?',
    'לדחות את הבקשה של $amount מ-$walletId?',
  );
  String get pendingRequestsBadge => _t('solicitudes', 'requests', 'demandes', 'בקשות');

  // ---------------------------------------------------------------------------
  // PRAYERS SCREEN
  // ---------------------------------------------------------------------------

  String get prayersNote => _t(
    'Nota: Este es un ejemplo. Los textos se mejorarán y perfeccionarán más adelante.',
    'Note: This is an example. Texts will be improved and refined later.',
    'Note : Ceci est un exemple. Les textes seront améliorés et affinés ultérieurement.',
    'הערה: זוהי דוגמה. הטקסטים ישופרו ויעודנו בהמשך.',
  );
  String get prayerTitleEs => _t('DIOS DE (RABINO) MEIR, RESPÓNDEME', 'GOD OF (RABBI) MEIR, ANSWER ME', 'DIEU DE (RABBI) MEIR, RÉPONDS-MOI', 'אלהא דמאיר ענני');
  String get prayerP1 => _t(
    'Se enseñó en nombre del Baal Shem Tov: Una persona que se encuentra en una situación peligrosa que requiere un milagro debe dar 18 monedas grandes, referidas como Gedolim, para velas que se encenderán en una sinagoga.',
    'It was taught in the name of the Baal Shem Tov: A person in a dangerous situation requiring a miracle should give 18 large coins, referred to as Gedolim, for candles to be lit in a synagogue.',
    'Il a été enseigné au nom du Baal Chem Tov : Une personne dans une situation dangereuse nécessitant un miracle doit donner 18 grandes pièces, appelées Guedolim, pour des bougies à allumer dans une synagogue.',
    'נלמד בשם הבעל שם טוב: אדם הנמצא במצב מסוכן הזקוק לנס, יתן 18 מטבעות גדולות הנקראות גדולים, לנרות שיידלקו בבית הכנסת.',
  );
  String get prayerP2 => _t(
    'Debe entonces declarar: "Me comprometo a dar estas 18 monedas por el mérito del alma del Rabino Meir, el maestro de los milagros."',
    'One should then declare: "I commit to give these 18 coins for the merit of the soul of Rabbi Meir, the master of miracles."',
    'On doit alors déclarer : « Je m\'engage à donner ces 18 pièces pour le mérite de l\'âme du Rabbin Meir, le maître des miracles. »',
    'ואז יאמר: "הריני נודר לתת 18 מטבעות אלו לזכות נשמת רבי מאיר בעל הנס."',
  );
  String get prayerP3 => _t(
    'Debe entonces repetir tres veces: "Dios de (Rabino) Meir, (por favor) respóndeme."',
    'One should then repeat three times: "God of (Rabbi) Meir, (please) answer me."',
    'On doit alors répéter trois fois : « Dieu de (Rabbi) Meir, (s\'il vous plaît) réponds-moi. »',
    'ואז יחזור שלוש פעמים: "אלהא דמאיר ענני."',
  );
  String get prayerP4 => _t(
    'Y así sea Tu voluntad, nuestro Dios y Dios de nuestros padres, que así como respondiste a la oración de Tu siervo (Rabino) Meir, realizando milagros y maravillas para él, así también puedas realizar para mí y para todo el pueblo de Tu nación, Israel, que está en necesidad de milagros, tanto revelados como ocultos. Amén, que sea Tu voluntad.',
    'And may it be Your will, our God and God of our fathers, that just as You answered the prayer of Your servant (Rabbi) Meir, performing miracles and wonders for him, so too may You perform for me and for all the people of Your nation, Israel, who are in need of miracles, both revealed and hidden. Amen, may it be Your will.',
    'Et que ce soit Ta volonté, notre Dieu et Dieu de nos pères, que tout comme Tu as répondu à la prière de Ton serviteur (Rabbi) Meir, accomplissant des miracles et des merveilles pour lui, ainsi puisses-Tu accomplir pour moi et pour tout le peuple de Ta nation, Israël, qui a besoin de miracles, tant révélés que cachés. Amen, que ce soit Ta volonté.',
    'ויהי רצון מלפניך ה\' אלוקינו ואלוקי אבותינו, שכשם שעניתה לתפילת עבדך רבי מאיר ועשית לו ניסים ונפלאות, כן תעשה לי ולכל עמך ישראל הצריכים לניסים, נגלים ונסתרים. אמן, יהי רצון.',
  );

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // NAVIGATION TITLES
  // ---------------------------------------------------------------------------

  String get navPushka => _t('Mi Pushka', 'My Pushka', 'Ma Pushka', 'הפושקה שלי');
  String get navReminders => _t('Recordatorios', 'Reminders', 'Rappels', 'תזכורות');
  String get navHistory => _t('Historial', 'History', 'Historique', 'היסטוריה');
  String get navSettings => _t('Configuración', 'Settings', 'Paramètres', 'הגדרות');
  String get navPrayers => _t('Segulot y Rezos', 'Prayers & Blessings', 'Prières et Bénédictions', 'סגולות ותפילות');
  String get navSupport => _t('Soporte', 'Support', 'Assistance', 'תמיכה');

  // ---------------------------------------------------------------------------
  // ACCOUNT SWITCHER
  // ---------------------------------------------------------------------------

  String get myOrganizations => _t('Mis organizaciones', 'My organizations', 'Mes organisations', 'הארגונים שלי');
  String get addOrganization => _t('Agregar organización', 'Add organization', 'Ajouter une organisation', 'הוסף ארגון');
  String get switchOrganization => _t('Cambiar de organización', 'Switch organization', "Changer d'organisation", 'החלף ארגון');

  // ---------------------------------------------------------------------------
  // QR WALLET DIALOG
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // PAYMENT CONFIRMATION
  // ---------------------------------------------------------------------------

  String get confirmPaymentTitle => _t('Confirmar donación', 'Confirm donation', 'Confirmer le don', 'אשר תרומה');
  String confirmPaymentBody(String amount) => _t(
    'Estás a punto de donar $amount. ¿Confirmas esta tzedaká?',
    'You are about to donate $amount. Do you confirm this tzedakah?',
    'Vous êtes sur le point de donner $amount. Confirmez-vous cette tsédaka ?',
    'אתה עומד לתרום $amount. האם אתה מאשר את הצדקה הזו?',
  );
  String get confirmDonate => _t('Sí, donar', 'Yes, donate', 'Oui, donner', 'כן, תרום');

  // ---------------------------------------------------------------------------
  // ONBOARDING
  // ---------------------------------------------------------------------------

  String get onboardingSkip => _t('Omitir', 'Skip', 'Ignorer', 'דלג');
  String get onboardingNext => _t('Siguiente', 'Next', 'Suivant', 'הבא');
  String get onboardingDone => _t('¡Comenzar!', 'Get started!', 'Commencer !', 'בואו נתחיל!');
  String get onboarding1Title => _t('Bienvenido a Pushka', 'Welcome to Pushka', 'Bienvenue sur Pushka', 'ברוכים הבאים לפושקה');
  /// BUG-060 fix: onboarding body is now tenant-aware. Pre-fix the welcome
  /// screen always said "Jabad en Campus Tzedakah app" — any other tenant's
  /// donor would see the wrong org name on their first launch.
  String onboarding1BodyFor(String brand) => _t(
        'La app de Tzedaká de $brand. Acumula donaciones como en una pushka real, y vacíala cuando estés listo.',
        "The $brand Tzedakah app. Accumulate donations like a real pushka, and empty it when you're ready.",
        "L'application Tsédaka de $brand. Accumulez des dons comme dans une vraie pushka, et videz-la quand vous êtes prêt.",
        'אפליקציית הצדקה של $brand. צבור תרומות כמו בפושקה אמיתית, ורוקן אותה כשתהיה מוכן.',
      );
  // Legacy getter — tenants in their first launch with no config loaded still
  // see the original copy.
  String get onboarding1Body => onboarding1BodyFor(colelJabad);
  String get onboarding2Title => _t('Acumula Tzedaká', 'Accumulate Tzedakah', 'Accumulez de la Tsédaka', 'צבור צדקה');
  String get onboarding2Body => _t(
    'Toca los montos predefinidos para ir sumando. Establece una meta y cuando la alcances, ¡celebra tu mitzvá!',
    'Tap the preset amounts to keep adding. Set a goal and when you reach it, celebrate your mitzvah!',
    'Appuyez sur les montants prédéfinis pour continuer à accumuler. Fixez-vous un objectif et quand vous l\'atteignez, célébrez votre mitsva !',
    'לחץ על הסכומים הקבועים מראש כדי להוסיף. קבע יעד וכשתגיע אליו, חגוג את המצווה שלך!',
  );
  String get onboarding3Title => _t('Recordatorios', 'Reminders', 'Rappels', 'תזכורות');
  String get onboarding3Body => _t(
    'Configura recordatorios diarios, semanales o para festividades judías. Nunca olvides tu mitzvá de Tzedaká.',
    'Set up daily, weekly, or Jewish holiday reminders. Never forget your Tzedakah mitzvah.',
    'Configurez des rappels quotidiens, hebdomadaires ou pour les fêtes juives. N\'oubliez jamais votre mitsva de Tsédaka.',
    'הגדר תזכורות יומיות, שבועיות או לחגים יהודיים. לעולם אל תשכח את מצוות הצדקה שלך.',
  );

  // ---------------------------------------------------------------------------
  // HISTORY CHART
  // ---------------------------------------------------------------------------

  String get chartTitle => _t('DONACIONES POR MES', 'MONTHLY DONATIONS', 'DONS MENSUELS', 'תרומות חודשיות');
  String get chartShowGraph => _t('Ver gráfico', 'Show chart', 'Afficher le graphique', 'הצג גרף');
  String get chartHideGraph => _t('Ocultar gráfico', 'Hide chart', 'Masquer le graphique', 'הסתר גרף');
  String get chartNoData => _t('Sin datos aún', 'No data yet', 'Pas encore de données', 'אין נתונים עדיין');

  // ---------------------------------------------------------------------------
  // PROFILE
  // ---------------------------------------------------------------------------

  String get editProfileTitle => _t('Editar perfil', 'Edit profile', 'Modifier le profil', 'ערוך פרופיל');
  String get displayNameLabel => _t('Nombre', 'Name', 'Nom', 'שם');
  String get displayNameHint => _t('Tu nombre completo', 'Your full name', 'Votre nom complet', 'שמך המלא');
  String get profileUpdated => _t('Perfil actualizado', 'Profile updated', 'Profil mis à jour', 'הפרופיל עודכן');
  String get editNameTooltip => _t('Editar nombre', 'Edit name', 'Modifier le nom', 'ערוך שם');
  String get changePhoto => _t('Cambiar foto', 'Change photo', 'Changer la photo', 'שנה תמונה');
  String get uploadingPhoto => _t('Subiendo foto...', 'Uploading photo...', 'Envoi de la photo...', 'מעלה תמונה...');
  String get photoUpdated => _t('Foto actualizada', 'Photo updated', 'Photo mise à jour', 'התמונה עודכנה');
  String get couldNotUploadPhoto => _t('No se pudo subir la foto', 'Could not upload photo', "Impossible de télécharger la photo", 'לא ניתן להעלות את התמונה');
  String imageTooLarge(String size, String max) => _t(
    'Imagen demasiado grande (${size}MB). Máximo permitido: ${max}MB.',
    'Image too large (${size}MB). Maximum allowed: ${max}MB.',
    'Image trop volumineuse ($size Mo). Maximum autorisé : $max Mo.',
    'התמונה גדולה מדי (${size}MB). המקסימום המותר: ${max}MB.',
  );

  // ---------------------------------------------------------------------------
  // SAVED CARDS
  // ---------------------------------------------------------------------------

  String get savedCards => _t('Métodos de pago', 'Payment methods', 'Moyens de paiement', 'אמצעי תשלום');
  String get myCards => _t('Mis tarjetas', 'My cards', 'Mes cartes', 'הכרטיסים שלי');
  String get noCardsYet => _t('Sin tarjetas guardadas', 'No saved cards', 'Aucune carte enregistrée', 'אין כרטיסים שמורים');
  String get noSavedCards => _t(
    'No tienes ninguna tarjeta guardada.\nAgrega una para habilitar el vaciado y la recarga automáticos.',
    'No saved card yet.\nAdd one to enable automatic emptying and refills.',
    "Aucune carte enregistrée.\nAjoutez-en une pour activer le vidage et la recharge automatiques.",
    'אין כרטיס שמור עדיין.\nהוסף אחד כדי להפעיל ריקון וטעינה אוטומטיים.',
  );
  /// Short variant for the Settings preview row — matches the visual weight
  /// of sibling rows like "Vaciar Manualmente". The longer `noSavedCards`
  /// stays for the auto-empty screen banner where context still matters.
  String get noCardsShort => _t(
    'No tienes ninguna tarjeta',
    'You have no cards',
    "Vous n'avez aucune carte",
    'אין לך כרטיסים',
  );
  String get addCard => _t('Agregar tarjeta', 'Add card', 'Ajouter une carte', 'הוסף כרטיס');
  String get cardDefault => _t('Predeterminada', 'Default', 'Par défaut', 'ברירת מחדל');
  String get setAsDefault => _t('Usar como predeterminada', 'Set as default', 'Définir par défaut', 'הגדר כברירת מחדל');
  String get deleteCard => _t('Eliminar tarjeta', 'Delete card', 'Supprimer la carte', 'מחק כרטיס');
  String cardEndingIn(String last4) => _t('Terminada en $last4', 'Ending in $last4', 'Se terminant par $last4', 'מסתיים ב-$last4');
  String cardExpiry(String month, String year) => _t('Vence $month/$year', 'Expires $month/$year', 'Expire $month/$year', 'פג תוקף $month/$year');
  String get cardAdded => _t('Tarjeta agregada correctamente', 'Card added successfully', 'Carte ajoutée avec succès', 'הכרטיס נוסף בהצלחה');
  String get cardDeleted => _t('Tarjeta eliminada', 'Card deleted', 'Carte supprimée', 'הכרטיס נמחק');
  String get cardSetAsDefault => _t('Tarjeta predeterminada actualizada', 'Default card updated', 'Carte par défaut mise à jour', 'כרטיס ברירת המחדל עודכן');
  String get confirmDeleteCard => _t('Eliminar tarjeta', 'Delete card', 'Supprimer la carte', 'מחק כרטיס');
  String get confirmDeleteCardBody => _t(
    '¿Seguro que quieres eliminar esta tarjeta?',
    'Are you sure you want to delete this card?',
    'Voulez-vous vraiment supprimer cette carte ?',
    'האם אתה בטוח שברצונך למחוק כרטיס זה?',
  );
  String get deleteConfirm => _t('Eliminar', 'Delete', 'Supprimer', 'מחק');
  String get loadingCards => _t('Cargando tarjetas...', 'Loading cards...', 'Chargement des cartes...', 'טוען כרטיסים...');
  String get errorLoadingCards => _t('Error al cargar las tarjetas', 'Error loading cards', 'Erreur lors du chargement des cartes', 'שגיאה בטעינת כרטיסים');
  String get webAddCardNotAvailable => _t(
    'Para agregar una tarjeta desde el navegador, haz una donación normal — se guarda automáticamente en tu cuenta.',
    'To add a card from the browser, make a normal donation — it will be saved to your account automatically.',
    'Pour ajouter une carte depuis le navigateur, faites un don normal — elle sera enregistrée automatiquement dans votre compte.',
    'כדי להוסיף כרטיס מהדפדפן, בצע תרומה רגילה — הכרטיס יישמר אוטומטית בחשבונך.',
  );
  String get recurringNotSupportedOnWeb => _t(
    'Las donaciones mensuales por ahora solo funcionan desde la app instalada en Android. Descárgala o haz una donación única desde el navegador.',
    'Monthly donations currently work only from the installed Android app. Install it, or make a one-time donation from the browser.',
    "Les dons mensuels ne fonctionnent actuellement que depuis l'application Android installée. Installez-la, ou faites un don unique depuis le navigateur.",
    'תרומות חודשיות פועלות כרגע רק מהאפליקציה המותקנת ב-Android. התקן אותה, או בצע תרומה חד-פעמית מהדפדפן.',
  );

  String get appleSignInNotAvailableOnWeb => _t(
    'Iniciar sesión con Apple no está disponible en el navegador. Usá Google o email.',
    'Sign in with Apple is not available in the browser. Use Google or email.',
    "La connexion avec Apple n'est pas disponible dans le navigateur. Utilise Google ou email.",
    'התחברות עם Apple לא זמינה בדפדפן. השתמש ב-Google או באימייל.',
  );

  String get pushNotifications => _t(
    'Notificaciones',
    'Notifications',
    'Notifications',
    'התראות',
  );
  String get pushNotificationsSubtitle => _t(
    'Recibe avisos cuando tienes recordatorios, pagos o novedades.',
    'Get notified about reminders, payments and updates.',
    'Reçois des notifications pour les rappels, paiements et nouveautés.',
    'קבל התראות על תזכורות, תשלומים ועדכונים.',
  );
  String get pushPermissionDenied => _t(
    'El navegador bloqueó las notificaciones. Habilitalas desde la configuración del sitio.',
    'The browser blocked notifications. Enable them in the site settings.',
    'Le navigateur a bloqué les notifications. Active-les dans les paramètres du site.',
    'הדפדפן חסם התראות. הפעל אותן בהגדרות האתר.',
  );
  String get pushRequiresInstalledPwa => _t(
    'Para recibir notificaciones en iPhone, primero agrega la app a la pantalla de inicio (Compartir → Agregar a pantalla de inicio) y ábrela desde el ícono.',
    'To receive notifications on iPhone, first add the app to your home screen (Share → Add to Home Screen) and open it from the icon.',
    'Pour recevoir des notifications sur iPhone, ajoute d’abord l’app à ton écran d’accueil (Partager → Sur l’écran d’accueil) et ouvre-la depuis l’icône.',
    'כדי לקבל התראות באייפון, קודם הוסף את האפליקציה למסך הבית (שיתוף ← הוסף למסך הבית) ופתח אותה מהסמל.',
  );
  String get pushEnabled => _t(
    'Notificaciones activadas',
    'Notifications enabled',
    'Notifications activées',
    'ההתראות הופעלו',
  );

  // ---------------------------------------------------------------------------
  // DONATION SUBSCRIPTIONS
  // ---------------------------------------------------------------------------

  String get mySubscriptions => _t(
    'Mis donaciones recurrentes',
    'My recurring donations',
    'Mes dons récurrents',
    'התרומות הקבועות שלי',
  );
  String get noActiveSubscriptions => _t(
    'No tienes donaciones recurrentes activas.',
    "You don't have any active recurring donations.",
    "Vous n'avez aucun don récurrent actif.",
    'אין לך תרומות קבועות פעילות.',
  );
  String get cancelSubscription => _t(
    'Cancelar donación',
    'Cancel donation',
    'Annuler le don',
    'ביטול תרומה',
  );
  String get cancelSubscriptionConfirmTitle => _t(
    'Cancelar donación',
    'Cancel donation',
    'Annuler le don',
    'ביטול תרומה',
  );
  String get cancelSubscriptionConfirmBody => _t(
    'Puedes volver cuando quieras, muchas gracias por aportar.',
    'You can come back whenever you want, thank you for contributing.',
    "Vous pouvez revenir quand vous voulez, merci pour votre contribution.",
    'תוכל לחזור מתי שתרצה, תודה רבה על תרומתך.',
  );
  String get subscriptionCanceled => _t(
    'Donación cancelada',
    'Donation canceled',
    'Don annulé',
    'התרומה בוטלה',
  );
  String get subscriptionCancelFailed => _t(
    'No se pudo cancelar. Intenta de nuevo.',
    "Couldn't cancel. Please try again.",
    "Annulation impossible. Veuillez réessayer.",
    'לא ניתן לבטל. נסה שוב.',
  );
  String nextChargeOn(String date) => _t(
    'Próximo cobro: $date',
    'Next charge: $date',
    'Prochain prélèvement : $date',
    'חיוב הבא: $date',
  );
  String get errorLoadingSubscriptions => _t(
    'Error al cargar las donaciones',
    'Error loading donations',
    'Erreur lors du chargement des dons',
    'שגיאה בטעינת התרומות',
  );

  // ---------------------------------------------------------------------------
  // AUTO REFILL CONSENT
  // ---------------------------------------------------------------------------

  String get tenantJoinFailed => _t(
    'No se pudo unirte a la organización. Intenta de nuevo.',
    "Couldn't join the organization. Please try again.",
    "Impossible de rejoindre l'organisation. Veuillez réessayer.",
    'לא הצלחנו להצטרף לארגון. נסה שוב.',
  );
  String get tenantEnterCode => _t('Ingresar código', 'Enter code', 'Saisir le code', 'הזן קוד');
  String get tenantJoin => _t('Unirme', 'Join', 'Rejoindre', 'הצטרף');
  String get tenantSearch => _t('Buscar', 'Search', 'Rechercher', 'חפש');
  String get tenantCancel => _t('Cancelar', 'Cancel', 'Annuler', 'ביטול');

  // TENANT CODE SCREEN (pre-tenant-join, uses system locale)
  String get tenantCodeTitle => _t(
    'Ingresá el código de invitación',
    'Enter your invite code',
    "Saisissez votre code d'invitation",
    'הזן את קוד ההזמנה',
  );
  String get tenantCodeSubtitle => _t(
    'Tu rab te lo compartió por mensaje.',
    'Your rabbi shared it with you by message.',
    'Votre rabbin vous l\'a partagé par message.',
    'הרב שלך שיתף אותו איתך בהודעה.',
  );
  String get tenantCodeJoinButton => _t('Unirse', 'Join', 'Rejoindre', 'הצטרף');
  String get tenantCodeLostCode => _t(
    '¿Perdiste el código? Contacta a tu rab',
    'Lost the code? Contact your rabbi',
    'Code perdu ? Contactez votre rabbin',
    'אבד לך הקוד? צור קשר עם הרב שלך',
  );
  String get tenantCodeSignOut => _t('Cerrar sesión', 'Sign out', 'Déconnexion', 'התנתק');
  String get tenantCodeMailSubject => _t(
    'Ayuda para unirme a mi organización',
    'Help joining my organization',
    'Aide pour rejoindre mon organisation',
    'עזרה להצטרף לארגון שלי',
  );
  String get tenantCodeMailOpenFailed => _t(
    'No se pudo abrir el mail. Escribí a ioelkatz@gmail.com.',
    'Could not open mail. Write to ioelkatz@gmail.com.',
    'Impossible d\'ouvrir l\'e-mail. Écrivez à ioelkatz@gmail.com.',
    'לא ניתן לפתוח את הדוא"ל. כתוב אל ioelkatz@gmail.com.',
  );
  String get tenantCodeErrorGeneric => _t(
    'Error al unirse. Intenta de nuevo.',
    'Error joining. Please try again.',
    'Erreur lors de l\'adhésion. Veuillez réessayer.',
    'שגיאה בהצטרפות. נסה שוב.',
  );
  String get tenantCodeErrorNotFound => _t(
    'Código no encontrado. Verifica que sea correcto.',
    'Code not found. Please check it.',
    'Code introuvable. Veuillez vérifier.',
    'הקוד לא נמצא. אנא בדוק שהוא נכון.',
  );
  String tenantCodeErrorRateLimitMins(int mins) => _t(
    'Demasiados intentos. Esperá $mins minutos.',
    'Too many attempts. Wait $mins minutes.',
    'Trop de tentatives. Attendez $mins minutes.',
    'יותר מדי ניסיונות. המתן $mins דקות.',
  );
  String get tenantCodeErrorRateLimitOne => _t(
    'Demasiados intentos. Esperá 1 minuto.',
    'Too many attempts. Wait 1 minute.',
    'Trop de tentatives. Attendez 1 minute.',
    'יותר מדי ניסיונות. המתן דקה אחת.',
  );
  String get tenantCodeErrorRateLimitGeneric => _t(
    'Demasiados intentos. Esperá unos minutos.',
    'Too many attempts. Wait a few minutes.',
    'Trop de tentatives. Attendez quelques minutes.',
    'יותר מדי ניסיונות. המתן מספר דקות.',
  );
  String get tenantCodeErrorSessionExpired => _t(
    'Tu sesión expiró. Cierra sesión y vuelve a entrar.',
    'Your session expired. Sign out and back in.',
    'Votre session a expiré. Déconnectez-vous et reconnectez-vous.',
    'הפגישה שלך פגה. התנתק והתחבר מחדש.',
  );
  String get tenantCodeErrorUnavailable => _t(
    'Esta organización no está disponible.',
    'This organization is not available.',
    'Cette organisation n\'est pas disponible.',
    'הארגון הזה אינו זמין.',
  );

  // ---------------------------------------------------------------------------
  // TENANT SUSPENDED SCREEN
  // ---------------------------------------------------------------------------
  String get tenantSuspendedTitle => _t(
    'Servicio no disponible',
    'Service unavailable',
    'Service indisponible',
    'השירות אינו זמין',
  );
  String tenantSlugNotFound(String slug) => _t(
    'El código "$slug" no corresponde a ninguna organización.',
    'The code "$slug" does not match any organization.',
    'Le code « $slug » ne correspond à aucune organisation.',
    'הקוד "$slug" אינו משויך לארגון.',
  );
  String get tenantSlugVerifyError => _t(
    'No se pudo verificar el código. Intenta de nuevo.',
    'Could not verify the code. Please try again.',
    "Impossible de vérifier le code. Veuillez réessayer.",
    'לא ניתן לאמת את הקוד. נסה שוב.',
  );
  String get tenantJoining => _t('Uniéndote...', 'Joining...', 'Adhésion...', 'מצטרף...');
  String get goHome => _t('Ir al inicio', 'Go home', "Aller à l'accueil", 'עבור לדף הבית');

  String get pushkaStyleLabel => _t('Estilo de pantalla principal', 'Main screen style', 'Style de l\'écran principal', 'סגנון המסך הראשי');
  String get pushkaStyleClassic => _t('Pushka', 'Pushka', 'Pushka', 'פושקה');
  String get pushkaStyleBuilding770 => _t('Edificio 770', 'Building 770', 'Bâtiment 770', 'בניין 770');

  String get couldNotOpenLink => _t(
    'No se pudo abrir el enlace.',
    'Could not open the link.',
    "Impossible d'ouvrir le lien.",
    'לא ניתן לפתוח את הקישור.',
  );
  String errorWithMessage(String msg) => _t(
    'Error: $msg',
    'Error: $msg',
    'Erreur : $msg',
    'שגיאה: $msg',
  );

  String get tenantSuspendedBody => _t(
    'El servicio de tu organización está temporalmente suspendido. Contacta al administrador de tu organización para más información.',
    "Your organization's service is temporarily suspended. Please contact your organization administrator for more information.",
    "Le service de votre organisation est temporairement suspendu. Veuillez contacter l'administrateur de votre organisation pour plus d'informations.",
    'שירות הארגון שלך מושעה זמנית. צור קשר עם מנהל הארגון לפרטים נוספים.',
  );

  /// BUG-061 fix: share message now templated on tenant brand + optional
  /// share URL so each tenant's donors share their own org's invitation
  /// link, not always pushkapp.cc/share (which lands on Jabad en Campus).
  /// Callers should pass `brand = tenant.appName ?? tenant.name`, and the
  /// share URL pointing at the tenant's slug (e.g. `https://pushkapp.cc/<slug>`).
  String appShareTextFor(String brand, String shareUrl) => _t(
        'He estado usando esta increíble app Pushka de Tzedaká de $brand. ¡Funciona igual que una pushka real! Con solo un toque puedes "poner una moneda" y cuando estés listo, "vaciarla" para hacer una donación.\n\nMírala aquí: $shareUrl',
        'I\'ve been using this amazing $brand Tzedakah Pushka app. It works just like a real pushka! With one tap you can "drop a coin" and when ready, "empty it" to make a donation.\n\nCheck it out: $shareUrl',
        'J\'utilise cette incroyable app Pushka de Tsédaka de $brand. Elle fonctionne comme une vraie pushka ! D\'un simple clic, vous pouvez "mettre une pièce" et quand vous êtes prêt, "la vider" pour faire un don.\n\nDécouvrez-la ici : $shareUrl',
        'אני משתמש באפליקציית הפושקה המדהימה לצדקה של $brand. היא עובדת בדיוק כמו פושקה אמיתית! בלחיצה אחת אפשר "להכניס מטבע" וכשמוכנים, "לרוקן אותה" לתרומה.\n\nגלה אותה כאן: $shareUrl',
      );
  // Legacy getter for any caller that hasn't migrated to the brand-aware version.
  String get appShareText => appShareTextFor(colelJabad, 'https://pushkapp.cc/share');
}

// -----------------------------------------------------------------------------
// DELEGATE
// -----------------------------------------------------------------------------

class _SDelegate extends LocalizationsDelegate<S> {
  const _SDelegate();

  @override
  bool isSupported(Locale locale) =>
      ['es', 'en', 'fr', 'he'].contains(locale.languageCode);

  @override
  Future<S> load(Locale locale) async => S(locale);

  @override
  bool shouldReload(covariant LocalizationsDelegate<S> old) => false;
}
