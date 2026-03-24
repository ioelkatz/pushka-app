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
  ];

  String get _lang => locale.languageCode;

  String _t(String es, [String? en, String? fr]) {
    return switch (_lang) {
      'en' => en ?? es,
      'fr' => fr ?? es,
      _ => es,
    };
  }

  // ---------------------------------------------------------------------------
  // COMMON
  // ---------------------------------------------------------------------------

  String get cancel => _t('Cancelar', 'Cancel', 'Annuler');
  String get save => _t('Guardar', 'Save', 'Enregistrer');
  String get delete => _t('Eliminar', 'Delete', 'Supprimer');
  String get understood => _t('Entendido', 'Understood', 'Compris');
  String get close => _t('Cerrar', 'Close', 'Fermer');
  String get add => _t('Agregar', 'Add', 'Ajouter');
  String get accept => _t('Aceptar', 'Accept', 'Accepter');
  String get or_ => _t('o', 'or', 'ou');
  String get enterValidAmount => _t('Ingresa un monto válido', 'Enter a valid amount', 'Entrez un montant valide');
  String get signInToContinue => _t('Inicia sesión para continuar', 'Sign in to continue', 'Connectez-vous pour continuer');
  String get error => _t('Error', 'Error', 'Erreur');
  String get loading => _t('Cargando...', 'Loading...', 'Chargement...');
  String get fieldRequired => _t('Campo requerido', 'Field required', 'Champ requis');
  String get invalidEmail => _t('Correo inválido', 'Invalid email', 'E-mail invalide');
  String get invalidPhone => _t('Número inválido', 'Invalid number', 'Numéro invalide');

  // ---------------------------------------------------------------------------
  // APP DRAWER
  // ---------------------------------------------------------------------------

  String hello(String name) => _t('HOLA $name', 'HELLO $name', 'BONJOUR $name');
  String get myPushka => _t('Mi Pushka', 'My Pushka', 'Ma Pushka');
  String get wallet => _t('Billetera', 'Wallet', 'Portefeuille');
  String get reminders => _t('Recordatorios', 'Reminders', 'Rappels');
  String get history => _t('Historial', 'History', 'Historique');
  String get settings => _t('Configuración', 'Settings', 'Paramètres');
  String get prayersAndSegulot => _t('Segulot y Rezos', 'Segulot & Prayers', 'Segoulot et Prières');
  String get support => _t('Soporte', 'Support', 'Assistance');
  String get about => _t('Acerca de', 'About', 'À propos');
  String version(String v) => _t('Versión $v', 'Version $v', 'Version $v');
  String get sponsoredBy => _t('Patrocinado por', 'Sponsored by', 'Parrainé par');
  String get sponsorLine1 => _t('Rabino Dovid (Roberto)', 'Rabbi Dovid (Roberto)', 'Rabbin Dovid (Roberto)');
  String get sponsorLine2 => _t('y Margie Szerer', 'and Margie Szerer', 'et Margie Szerer');
  String get defaultUser => _t('Usuario', 'User', 'Utilisateur');

  // ---------------------------------------------------------------------------
  // PUSHKA SCREEN
  // ---------------------------------------------------------------------------

  String get fillIt => _t('¡Llénala!', 'Fill it up!', 'Remplissez-la !');
  String get streakDays => _t('Racha de Días', 'Day Streak', 'Série de jours');
  String get otherAmount => _t('OTRO', 'OTHER', 'AUTRE');
  String get donateNowBtn => _t('DONAR AHORA', 'DONATE NOW', 'FAIRE UN DON');
  String get emptyPushkaBtn => _t('VACIAR PUSHKA', 'EMPTY PUSHKA', 'VIDER LA PUSHKA');
  String get changePushkaGoal => _t('CAMBIAR META DE PUSHKA', 'CHANGE PUSHKA GOAL', "CHANGER L'OBJECTIF");
  String get addToPushka => _t('AGREGAR A PUSHKA', 'ADD TO PUSHKA', 'AJOUTER À LA PUSHKA');
  String get chooseAmount => _t('Elige un monto', 'Choose an amount', 'Choisissez un montant');
  String get tapToEdit => _t('Toca para editar el monto', 'Tap to edit amount', 'Appuyez pour modifier');
  String addedToPushka(String amount) => _t('$amount agregado a tu Pushka', '$amount added to your Pushka', '$amount ajouté à votre Pushka');
  String get otherAmountTitle => _t('Otro monto', 'Other amount', 'Autre montant');
  String get amountHint => _t('Ej: 12.50', 'E.g.: 12.50', 'Ex : 12,50');
  String get pushkaFull => _t('Tu Pushka está llena', 'Your Pushka is full', 'Votre Pushka est pleine');
  String get donationGoalReached => _t('¡Alcanzaste tu Meta de Donación!', 'You reached your Donation Goal!', 'Vous avez atteint votre objectif !');
  String get donateNowTitle => _t('Donar Ahora', 'Donate Now', 'Faire un don');
  String get amount => _t('Monto', 'Amount', 'Montant');
  String get optionalMessage => _t('Mensaje personal (opcional)', 'Personal message (optional)', 'Message personnel (optionnel)');
  String get writeMessage => _t('Escribe un mensaje...', 'Write a message...', 'Écrivez un message...');
  String get instantDonationNote => _t(
    'Donación instantánea. No reduce ni afecta el balance de tu Pushka.',
    'Instant donation. It does not reduce or affect your Pushka balance.',
    'Don instantané. Ne réduit ni n\'affecte le solde de votre Pushka.',
  );
  String get stripeNotConfigured => _t('Stripe no está configurado', 'Stripe is not configured', "Stripe n'est pas configuré");
  String get biometricReasonEmpty => _t('Confirma tu identidad para vaciar la Pushka', 'Confirm your identity to empty the Pushka', 'Confirmez votre identité pour vider la Pushka');
  String get authRequired => _t('Autenticación requerida para vaciar la Pushka', 'Authentication required to empty the Pushka', 'Authentification requise pour vider la Pushka');
  String get pushkaEmptied => _t('Pushka vaciada. El pago fue procesado.', 'Pushka emptied. Payment was processed.', 'Pushka vidée. Le paiement a été traité.');
  String get couldNotEmpty => _t('No se pudo vaciar la Pushka', 'Could not empty the Pushka', 'Impossible de vider la Pushka');
  String get biometricReasonDonate => _t('Confirma tu identidad para procesar la donación', 'Confirm your identity to process the donation', 'Confirmez votre identité pour traiter le don');
  String get authRequiredDonate => _t('Autenticación requerida para donar', 'Authentication required to donate', 'Authentification requise pour faire un don');
  String get instantDonation => _t('Donación instantánea', 'Instant donation', 'Don instantané');
  String donationProcessed(String amount) => _t('Donación de $amount procesada exitosamente', 'Donation of $amount processed successfully', 'Don de $amount traité avec succès');
  String get donationWithCard => _t('Donación con tarjeta', 'Card donation', 'Don par carte');
  String paymentProcessedRemaining(String amount) => _t('Pago procesado. Quedaron $amount en la Pushka.', 'Payment processed. $amount remaining in the Pushka.', 'Paiement traité. $amount restant dans la Pushka.');
  String get paymentProcessedHistory => _t('Pago procesado. Se reflejará en el historial pronto.', 'Payment processed. It will appear in your history soon.', "Paiement traité. Il apparaîtra bientôt dans l'historique.");
  String donationPending(String amount) => _t(
    'Donación de $amount registrada como pendiente. Completa el pago según las instrucciones.',
    'Donation of $amount registered as pending. Complete payment per instructions.',
    'Don de $amount enregistré comme en attente. Complétez le paiement selon les instructions.',
  );
  String get couldNotRegister => _t("No se pudo registrar la donación", "Could not register the donation", "Impossible d'enregistrer le don");
  String get minAmountTitle => _t('Monto mínimo', 'Minimum amount', 'Montant minimum');
  String minAmountBody(String code, String symbol, String min) => _t(
    'Para procesar pagos en $code, el monto mínimo es de $symbol$min.',
    'To process payments in $code, the minimum amount is $symbol$min.',
    'Pour traiter les paiements en $code, le montant minimum est de $symbol$min.',
  );
  String get minAmountHint => _t(
    'Puedes aumentar el monto o cambiar la moneda en Configuración.',
    'You can increase the amount or change the currency in Settings.',
    'Vous pouvez augmenter le montant ou changer la devise dans les Paramètres.',
  );
  String get errorSessionInvalid => _t(
    'Tu sesión no es válida. Cierra sesión e inicia de nuevo.',
    'Your session is invalid. Log out and sign in again.',
    "Votre session n'est pas valide. Déconnectez-vous et reconnectez-vous.",
  );
  String get errorSecurityCheck => _t(
    'Verificación de seguridad fallida. Intenta de nuevo.',
    'Security check failed. Try again.',
    'Vérification de sécurité échouée. Réessayez.',
  );
  String get errorAccessDenied => _t(
    'Acceso denegado por seguridad. Intenta de nuevo.',
    'Access denied for security. Try again.',
    'Accès refusé pour des raisons de sécurité. Réessayez.',
  );
  String get errorPaymentServer => _t(
    'Error del servidor de pagos. Verifica tu conexión e intenta de nuevo.',
    'Payment server error. Check your connection and try again.',
    'Erreur du serveur de paiement. Vérifiez votre connexion et réessayez.',
  );
  String get errorServerUnavailable => _t(
    "El servidor de pagos no está disponible. Intenta más tarde.",
    "Payment server unavailable. Try later.",
    "Le serveur de paiement n'est pas disponible. Réessayez plus tard.",
  );
  String get couldNotStartPayment => _t("No se pudo iniciar el pago", "Could not start payment", "Impossible de lancer le paiement");
  String get paymentCanceled => _t('Pago cancelado', 'Payment canceled', 'Paiement annulé');
  String paymentFailed(String msg) => _t('No se pudo completar el pago: $msg', 'Could not complete payment: $msg', 'Impossible de compléter le paiement : $msg');
  String get couldNotCompleteDonation => _t("No se pudo completar la donación", "Could not complete the donation", "Impossible de compléter le don");
  String get paymentMethodTitle => _t('Método de pago', 'Payment method', 'Moyen de paiement');
  String get paymentMethodSubtitle => _t('Selecciona cómo deseas realizar tu donación', 'Select how you want to make your donation', 'Sélectionnez comment vous souhaitez faire votre don');
  String get paymentCard => _t('Tarjeta de crédito/débito', 'Credit/debit card', 'Carte de crédit/débit');
  String get paymentCardSub => _t('Pago inmediato vía Stripe', 'Instant payment via Stripe', 'Paiement immédiat via Stripe');
  String get paymentCheck => _t('Cheque', 'Check', 'Chèque');
  String get paymentCheckSub => _t('Envía un cheque por correo', 'Send a check by mail', 'Envoyez un chèque par courrier');
  String get paymentTransfer => _t('Transferencia bancaria', 'Bank transfer', 'Virement bancaire');
  String get paymentTransferSub => _t('Transferencia electrónica', 'Electronic transfer', 'Transfert électronique');
  String get paymentDaf => _t('DAF', 'DAF', 'DAF');
  String get paymentDafSub => _t('Donor Advised Fund', 'Donor Advised Fund', 'Donor Advised Fund');
  String get confirmDonation => _t('Confirmar donación', 'Confirm donation', 'Confirmer le don');
  String get partialDonationTitle => _t('Donación parcial', 'Partial donation', 'Don partiel');
  String availableInPushka(String amount) => _t('Disponible en Pushka: $amount', 'Available in Pushka: $amount', 'Disponible dans la Pushka : $amount');
  String get quickSelect => _t('Selecciona rápido', 'Quick select', 'Sélection rapide');
  String get amountToDonate => _t('Monto a donar ahora', 'Amount to donate now', 'Montant à donner maintenant');
  String get donate => _t('Donar', 'Donate', 'Donner');
  String get cannotExceedBalance => _t('No puede ser mayor al saldo de tu Pushka', 'Cannot exceed your Pushka balance', 'Ne peut pas dépasser le solde de votre Pushka');
  String get tzedakahSettings => _t('Configuración de Tzedaká', 'Tzedakah Settings', 'Configuration de Tsédaka');
  String get pushkaGoalLabel => _t('META DE PUSHKA', 'PUSHKA GOAL', 'OBJECTIF DE PUSHKA');
  String get presetAmountsLabel => _t('MONTOS PREDEFINIDOS', 'PRESET AMOUNTS', 'MONTANTS PRÉDÉFINIS');
  String get editQuickAmountHint => _t('Edita los montos que aparecen como botones rápidos', 'Edit the amounts that appear as quick buttons', 'Modifiez les montants des boutons rapides');
  String get allAmountsMustBePositive => _t('Todos los montos deben ser mayores a 0', 'All amounts must be greater than 0', 'Tous les montants doivent être supérieurs à 0');
  String get settingsApplied => _t('Configuración aplicada', 'Settings applied', 'Paramètres appliqués');
  String get customGoal => _t('Meta personalizada', 'Custom goal', 'Objectif personnalisé');
  String get customGoalHint => _t('Ej: 4500', 'E.g.: 4500', 'Ex : 4500');
  String get offlineSaved => _t(
    'Sin conexión estable. Guardamos localmente y se sincronizará al reconectar.',
    'No stable connection. Saved locally, will sync on reconnect.',
    'Pas de connexion stable. Enregistré localement, synchronisation à la reconnexion.',
  );
  String get firestoreUnavailable => _t(
    'No hay conexión con Firestore. Revisa internet y vuelve a intentar.',
    'No Firestore connection. Check internet and try again.',
    'Pas de connexion à Firestore. Vérifiez internet et réessayez.',
  );
  String get couldNotSync => _t(
    'No se pudo sincronizar la configuración. Intenta nuevamente.',
    'Could not sync settings. Try again.',
    'Impossible de synchroniser les paramètres. Réessayez.',
  );
  String get dropdownOther => _t('OTRO', 'OTHER', 'AUTRE');

  // ---------------------------------------------------------------------------
  // HOLIDAY NAMES
  // ---------------------------------------------------------------------------

  String get holidayMaotJitim => _t("Ma'ot Jitim", "Ma'ot Chitim", "Ma'ot 'Hitim");
  String get holidayMaotJitimDesc => _t(
    'Fondos para los necesitados de Israel para sus necesidades de Pésaj',
    'Funds for the needy of Israel for their Passover needs',
    'Fonds pour les nécessiteux d\'Israël pour leurs besoins de Pessah',
  );
  String get holidayShavuot => _t('Shavuot', 'Shavuot', 'Chavouot');
  String get holidayShavuotDesc => _t(
    'Celebramos la entrega de la Torá. Dona tzedaká en honor a esta festividad',
    'We celebrate the giving of the Torah. Donate tzedakah in honor of this holiday',
    "Nous célébrons le don de la Torah. Faites un don de tsédaka en l'honneur de cette fête",
  );
  String get holidayRoshHashana => _t('Rosh Hashaná', 'Rosh Hashanah', 'Roch Hachana');
  String get holidayRoshHashanaDesc => _t(
    'Año Nuevo judío. Comienza el año con tzedaká y buenas acciones',
    'Jewish New Year. Start the year with tzedakah and good deeds',
    "Nouvel An juif. Commencez l'année avec la tsédaka et de bonnes actions",
  );
  String get holidayYomKippur => _t('Yom Kippur', 'Yom Kippur', 'Yom Kippour');
  String get holidayYomKippurDesc => _t(
    "Día de la Expiación. La tzedaká es un mérito especial antes de Yom Kippur",
    "Day of Atonement. Tzedakah is a special merit before Yom Kippur",
    "Jour de l'Expiation. La tsédaka est un mérite spécial avant Yom Kippour",
  );
  String get holidaySucot => _t('Sucot', 'Sukkot', 'Souccot');
  String get holidaySucotDesc => _t(
    'Fiesta de las Cabañas. Comparte alegría con quienes más lo necesitan',
    'Festival of Booths. Share joy with those most in need',
    'Fête des Cabanes. Partagez la joie avec ceux qui en ont le plus besoin',
  );
  String get holidayJanuca => _t('Janucá', 'Hanukkah', "'Hanouka");
  String get holidayJanucaDesc => _t(
    'Festival de las Luces. Ilumina vidas con tu donación de tzedaká',
    'Festival of Lights. Illuminate lives with your tzedakah donation',
    'Fête des Lumières. Illuminez des vies avec votre don de tsédaka',
  );
  String get holidayPurim => _t('Purim', 'Purim', 'Pourim');
  String get holidayPurimDesc => _t(
    "Matanot la'Evionim: regalos a los necesitados, una mitzvá central de Purim",
    "Matanot la'Evionim: gifts to the needy, a central mitzvah of Purim",
    "Matanot la'Evionim : cadeaux aux nécessiteux, une mitsva centrale de Pourim",
  );

  // ---------------------------------------------------------------------------
  // WALLET SCREEN
  // ---------------------------------------------------------------------------

  String get addFunds => _t('Agregar fondos', 'Add funds', 'Ajouter des fonds');
  String get enterAmount => _t('Ingresa monto', 'Enter amount', 'Entrez le montant');
  String get addToBalance => _t('Agregar al saldo', 'Add to balance', 'Ajouter au solde');
  String fundsAdded(String amount) => _t('Fondos agregados: $amount', 'Funds added: $amount', 'Fonds ajoutés : $amount');
  String walletIdCopied(String id) => _t('ID de billetera copiado: $id', 'Wallet ID copied: $id', 'ID du portefeuille copié : $id');
  String get setFundsSubtitle => _t(
    'Aparta fondos ahora para vaciar tu Pushka después',
    'Set aside funds now to empty your Pushka later',
    'Mettez des fonds de côté maintenant pour vider votre Pushka plus tard',
  );
  String get learnMore => _t('Aprender más', 'Learn more', 'En savoir plus');
  String get yourWalletId => _t('Tu ID de billetera', 'Your wallet ID', 'Votre ID de portefeuille');
  String get balanceLabel => _t('SALDO', 'BALANCE', 'SOLDE');
  String get addFundsBtn => _t('+ Agregar fondos', '+ Add funds', '+ Ajouter des fonds');
  String get sendRequest => _t('Enviar / Solicitar entre billeteras', 'Send / Request between wallets', 'Envoyer / Demander entre portefeuilles');
  String get sendRequestSub => _t('Empodera a familia y amigos con tzedaká', 'Empower family and friends with tzedakah', 'Responsabilisez famille et amis avec la tsédaka');
  String get manageAutoRefill => _t('Administrar recarga automática', 'Manage auto refill', 'Gérer la recharge automatique');
  String get transactionHistory => _t('Historial de transacciones', 'Transaction history', 'Historique des transactions');
  String autoRefillActive(String amount, String freq) => _t('ACTIVA - $amount $freq', 'ACTIVE - $amount $freq', 'ACTIVE - $amount $freq');
  String get autoRefillInactive => _t('RECARGA AUTOMÁTICA INACTIVA', 'AUTO REFILL INACTIVE', 'RECHARGE AUTOMATIQUE INACTIVE');
  String nextRun(String date) => _t('Próxima: $date', 'Next: $date', 'Prochaine : $date');
  String get weekly => _t('semanal', 'weekly', 'hebdomadaire');
  String get monthly => _t('mensual', 'monthly', 'mensuel');
  String minAmountCurrency(String currency, String amount) => _t(
    'Monto mínimo para $currency es $amount',
    'Minimum amount for $currency is $amount',
    'Montant minimum pour $currency est $amount',
  );
  String get paymentCouldNotProcess => _t(
    'No se pudo procesar el pago. Intenta nuevamente.',
    'Could not process payment. Try again.',
    'Impossible de traiter le paiement. Réessayez.',
  );

  // ---------------------------------------------------------------------------
  // SETTINGS SCREEN
  // ---------------------------------------------------------------------------

  String get general => _t('GENERAL', 'GENERAL', 'GÉNÉRAL');
  String get pushkaGoalSetting => _t('META DE PUSHKA', 'PUSHKA GOAL', 'OBJECTIF DE PUSHKA');
  String get presetAmount => _t('MONTO PREESTABLECIDO', 'PRESET AMOUNT', 'MONTANT PRÉDÉFINI');
  String get emptyPushkaSetting => _t('VACIAR PUSHKA', 'EMPTY PUSHKA', 'VIDER LA PUSHKA');
  String get manualEmpty => _t('Vaciar Manualmente', 'Manual Empty', 'Vidage manuel');
  String get currency => _t('MONEDA', 'CURRENCY', 'DEVISE');
  String get language => _t('IDIOMA', 'LANGUAGE', 'LANGUE');
  String get langSpanish => _t('Español', 'Spanish', 'Espagnol');
  String get langEnglish => _t('English', 'English', 'English');
  String get langFrench => _t('Français', 'French', 'Français');
  String get sound => _t('SONIDO', 'SOUND', 'SON');
  String get coinJingle => _t('SONIDO DE MONEDA', 'COIN JINGLE', 'SON DE PIÈCE');
  String get confettiSound => _t('SONIDO DE CONFETI', 'CONFETTI SOUND', 'SON DE CONFETTIS');
  String get vibration => _t('VIBRACIÓN', 'VIBRATION', 'VIBRATION');
  String get partialPayments => _t('PAGOS PARCIALES', 'PARTIAL PAYMENTS', 'PAIEMENTS PARTIELS');
  String get additionalPaymentOptions => _t('OPCIONES DE PAGO ADICIONALES', 'ADDITIONAL PAYMENT OPTIONS', 'OPTIONS DE PAIEMENT SUPPLÉMENTAIRES');
  String get additionalPaymentOptionsSub => _t('Incluyendo cheque, transferencia, DAF', 'Including check, transfer, DAF', 'Y compris chèque, virement, DAF');
  String get biometricAuth => _t('AUTENTICACIÓN BIOMÉTRICA', 'BIOMETRIC AUTHENTICATION', 'AUTHENTIFICATION BIOMÉTRIQUE');
  String get biometricActivated => _t('Autenticación biométrica activada', 'Biometric authentication activated', 'Authentification biométrique activée');
  String get fingerprint => _t('Huella digital', 'Fingerprint', 'Empreinte digitale');
  String get faceRecognition => _t('Reconocimiento facial', 'Face recognition', 'Reconnaissance faciale');
  String get pinPattern => _t('PIN / Patrón', 'PIN / Pattern', 'PIN / Schéma');
  String get myPushkaSection => _t('MI PUSHKA', 'MY PUSHKA', 'MA PUSHKA');
  String get addPushkaBtn => _t('+ Agregar Pushka', '+ Add Pushka', '+ Ajouter Pushka');
  String get signInToSeePushkas => _t('Inicia sesión para ver tus Pushkas', 'Sign in to see your Pushkas', 'Connectez-vous pour voir vos Pushkas');
  String get errorLoadingPushkas => _t('No se pudieron cargar las Pushkas', 'Could not load Pushkas', 'Impossible de charger les Pushkas');
  String get defaultPushkaName => _t('Colel Jabad Pushka', 'Colel Chabad Pushka', "Colel 'Habad Pushka");
  String get profileSection => _t('PERFIL', 'PROFILE', 'PROFIL');
  String get nameLabel => _t('NOMBRE', 'NAME', 'NOM');
  String get emailLabel => _t('CORREO ELECTRÓNICO', 'EMAIL', 'E-MAIL');
  String get billingEmail => _t('CORREO DE FACTURACIÓN', 'BILLING EMAIL', 'E-MAIL DE FACTURATION');
  String get phoneLabel => _t('NÚMERO DE TELÉFONO', 'PHONE NUMBER', 'NUMÉRO DE TÉLÉPHONE');
  String get mailingAddress => _t('DIRECCIÓN POSTAL', 'MAILING ADDRESS', 'ADRESSE POSTALE');
  String get manageAccount => _t('ADMINISTRAR CUENTA', 'MANAGE ACCOUNT', 'GÉRER LE COMPTE');
  String get deleteAccountQuestion => _t('¿Eliminar cuenta?', 'Delete account?', 'Supprimer le compte ?');
  String get logout => _t('Cerrar sesión', 'Log out', 'Déconnexion');
  String get principalBadge => _t('Principal', 'Primary', 'Principal');
  String get pushkaIconHebrew => 'צדקה';
  String get searchCountry => _t('Buscar país', 'Search country', 'Rechercher un pays');
  String get nameOrCode => _t('Nombre o código', 'Name or code', 'Nom ou code');
  String get phoneHint => _t('Número de teléfono', 'Phone number', 'Numéro de téléphone');
  String enterField(String field) => _t('Ingresa $field', 'Enter $field', 'Entrez $field');
  String get deleteAccountTitle => _t('Eliminar Cuenta', 'Delete Account', 'Supprimer le compte');
  String get deleteAccountBody => _t(
    '¿Está seguro de que desea eliminar su cuenta? Esta acción no se puede deshacer.',
    'Are you sure you want to delete your account? This action cannot be undone.',
    'Êtes-vous sûr de vouloir supprimer votre compte ? Cette action est irréversible.',
  );
  String get accountDeleted => _t('Cuenta eliminada', 'Account deleted', 'Compte supprimé');
  String get logoutTitle => _t('Cerrar Sesión', 'Log Out', 'Déconnexion');
  String get logoutConfirm => _t(
    '¿Está seguro de que desea cerrar sesión?',
    'Are you sure you want to log out?',
    'Êtes-vous sûr de vouloir vous déconnecter ?',
  );
  String get sessionClosed => _t('Sesión cerrada', 'Session closed', 'Session fermée');
  String get pushkaGoalDialog => _t('Meta de Pushka', 'Pushka Goal', 'Objectif de Pushka');
  String get exampleGoalHint => _t('Ej: 3600.00', 'E.g.: 3600.00', 'Ex : 3600,00');
  String get emptyPushkaFirst => _t('Vacía tu Pushka primero', 'Empty your Pushka first', "Videz d'abord votre Pushka");
  String get currencyChangeBody => _t(
    'Para cambiar de moneda, primero debes vaciar o donar el saldo actual de tu Pushka.',
    'To change currency, first empty or donate your current Pushka balance.',
    "Pour changer de devise, videz d'abord ou donnez le solde actuel de votre Pushka.",
  );
  String get selectCurrency => _t('Seleccionar Moneda', 'Select Currency', 'Sélectionner la devise');
  String get noBiometric => _t(
    'Tu dispositivo no soporta autenticación biométrica',
    'Your device does not support biometric authentication',
    "Votre appareil ne prend pas en charge l'authentification biométrique",
  );
  String get configureDeviceSecurity => _t(
    'Configura un PIN, huella digital o reconocimiento facial en los ajustes de tu dispositivo primero',
    'Set up a PIN, fingerprint or face recognition in your device settings first',
    'Configurez un PIN, empreinte digitale ou reconnaissance faciale dans les paramètres de votre appareil',
  );
  String get authCouldNotComplete => _t(
    'No se pudo completar la autenticación',
    'Could not complete authentication',
    "Impossible de compléter l'authentification",
  );
  String get biometricReasonEnable => _t(
    'Confirma tu identidad para activar la autenticación biométrica',
    'Confirm your identity to enable biometric authentication',
    "Confirmez votre identité pour activer l'authentification biométrique",
  );
  String get scanQrCode => _t('Escanear código QR', 'Scan QR code', 'Scanner le code QR');
  String get enterPushkaId => _t('Ingresar ID Pushka', 'Enter Pushka ID', "Entrer l'ID Pushka");
  String get pushkaIdHint => _t('Ingresa ID Pushka', 'Enter Pushka ID', "Entrez l'ID Pushka");
  String get invalidPushkaId => _t('Ingresa un ID de Pushka válido', 'Enter a valid Pushka ID', 'Entrez un ID Pushka valide');
  String get pushkaAdded => _t('Pushka agregada', 'Pushka added', 'Pushka ajoutée');
  String get addNewPushka => _t('Agregar nueva Pushka', 'Add new Pushka', 'Ajouter une nouvelle Pushka');
  String get enterValidId => _t('Ingresa un ID válido', 'Enter a valid ID', 'Entrez un ID valide');

  // ---------------------------------------------------------------------------
  // REMINDERS SCREEN
  // ---------------------------------------------------------------------------

  String get noReminders => _t('No hay recordatorios', 'No reminders', 'Aucun rappel');
  String get tapToAddReminder => _t('Toca el botón para agregar uno', 'Tap the button to add one', "Appuyez sur le bouton pour en ajouter");
  String get errorLoadingReminders => _t('Error cargando recordatorios', 'Error loading reminders', 'Erreur de chargement des rappels');
  String get addReminder => _t('+ AGREGAR RECORDATORIO', '+ ADD REMINDER', '+ AJOUTER UN RAPPEL');
  String get deleteReminderTitle => _t('Eliminar recordatorio', 'Delete reminder', 'Supprimer le rappel');
  String deleteReminderConfirm(String title) => _t('¿Eliminar "$title"?', 'Delete "$title"?', 'Supprimer "$title" ?');
  String get reminderAdded => _t('Recordatorio agregado', 'Reminder added', 'Rappel ajouté');
  String get reminderUpdated => _t('Recordatorio actualizado', 'Reminder updated', 'Rappel mis à jour');
  String get signInToSaveReminders => _t('Inicia sesión para guardar recordatorios', 'Sign in to save reminders', 'Connectez-vous pour enregistrer les rappels');
  String get couldNotSaveReminder => _t("No se pudo guardar el recordatorio", "Could not save reminder", "Impossible d'enregistrer le rappel");
  String get couldNotUpdateReminder => _t("No se pudo actualizar el recordatorio", "Could not update reminder", "Impossible de mettre à jour le rappel");
  String get signInToModify => _t('Inicia sesión para modificar recordatorios', 'Sign in to modify reminders', 'Connectez-vous pour modifier les rappels');
  String get signInToDelete => _t('Inicia sesión para eliminar recordatorios', 'Sign in to delete reminders', 'Connectez-vous pour supprimer les rappels');
  String get couldNotUpdateReminder => _t('No se pudo actualizar el recordatorio', 'Could not update reminder', 'Impossible de mettre à jour le rappel');
  String get couldNotDelete => _t('No se pudo eliminar el recordatorio', 'Could not delete reminder', 'Impossible de supprimer le rappel');
  String get repeatDaily => _t('Diario', 'Daily', 'Quotidien');
  String get repeatWeekdays => _t('Días de semana', 'Weekdays', 'Jours ouvrables');
  String get repeatFridayHoliday => _t('Viernes y festivos', 'Friday & Holidays', 'Vendredi et fêtes');
  String get repeatChooseDate => _t('Elegir una fecha', 'Choose a date', 'Choisir une date');
  String get repeatCustom => _t('Personalizado', 'Custom', 'Personnalisé');
  String get editReminder => _t('Editar Recordatorio', 'Edit Reminder', 'Modifier le rappel');
  String get newReminder => _t('Nuevo Recordatorio', 'New Reminder', 'Nouveau rappel');
  String get labelSection => _t('ETIQUETA', 'LABEL', 'ÉTIQUETTE');
  String get reminderTitleHint => _t('Título del recordatorio', 'Reminder title', 'Titre du rappel');
  String get timeSection => _t('HORA', 'TIME', 'HEURE');
  String get repeatSection => _t('REPETIR', 'REPEAT', 'RÉPÉTER');
  String get dateSection => _t('FECHA', 'DATE', 'DATE');
  String get daysSection => _t('DÍAS', 'DAYS', 'JOURS');
  String get includeHolidays => _t('Incluir festivos', 'Include holidays', 'Inclure les jours fériés');
  String get cancelBtn => _t('CANCELAR', 'CANCEL', 'ANNULER');
  String get saveBtn => _t('GUARDAR', 'SAVE', 'ENREGISTRER');
  String get selectDate => _t('Seleccionar fecha', 'Select date', 'Sélectionner une date');
  String get dayL => _t('L', 'M', 'L');
  String get dayM => _t('M', 'T', 'M');
  String get dayX => _t('X', 'W', 'M');
  String get dayJ => _t('J', 'T', 'J');
  String get dayV => _t('V', 'F', 'V');
  String get dayS => _t('S', 'S', 'S');
  String get dayD => _t('D', 'S', 'D');
  String get selectDateRequired => _t('Selecciona una fecha', 'Select a date', 'Sélectionnez une date');
  String get selectDayOrHoliday => _t('Selecciona al menos un día o festivos', 'Select at least one day or holidays', 'Sélectionnez au moins un jour ou les jours fériés');
  String get enterTitle => _t('Ingresa un título', 'Enter a title', 'Entrez un titre');
  String get titleTooShort => _t('Título muy corto', 'Title too short', 'Titre trop court');

  // ---------------------------------------------------------------------------
  // HISTORY SCREEN
  // ---------------------------------------------------------------------------

  String get filterAll => _t('Todos', 'All', 'Tous');
  String get filterTzedaka => _t('Mi Tzedaka', 'My Tzedakah', 'Ma Tsédaka');
  String get filterPushkaEmpty => _t('Pushka Vacía', 'Pushka Empty', 'Pushka vidée');
  String get filterWalletFill => _t('Billetera Rellena', 'Wallet Fill', 'Portefeuille rechargé');
  String get noTransactions => _t('No hay transacciones', 'No transactions', 'Aucune transaction');
  String get errorLoadingHistory => _t("Error cargando historial", "Error loading history", "Erreur de chargement de l'historique");
  String get pending => _t('Pendiente', 'Pending', 'En attente');

  // ---------------------------------------------------------------------------
  // TRANSACTION DOMAIN
  // ---------------------------------------------------------------------------

  String get typeTzedaka => _t('Mi Tzedaka', 'My Tzedakah', 'Ma Tsédaka');
  String get typePushkaEmpty => _t('Pushka Vacía', 'Pushka Empty', 'Pushka vidée');
  String get typeWalletFill => _t('Billetera Rellena', 'Wallet Fill', 'Portefeuille rechargé');
  String get methodCard => _t('Tarjeta', 'Card', 'Carte');
  String get methodCheck => _t('Cheque', 'Check', 'Chèque');
  String get methodTransfer => _t('Transferencia', 'Transfer', 'Virement');
  String get methodDaf => _t('DAF', 'DAF', 'DAF');
  String get statusCompleted => _t('Completado', 'Completed', 'Terminé');
  String get statusPending => _t('Pendiente', 'Pending', 'En attente');
  String get statusConfirmed => _t('Confirmado', 'Confirmed', 'Confirmé');

  // ---------------------------------------------------------------------------
  // REMINDER DOMAIN
  // ---------------------------------------------------------------------------

  String get dayMonShort => _t('Lun', 'Mon', 'Lun');
  String get dayTueShort => _t('Mar', 'Tue', 'Mar');
  String get dayWedShort => _t('Mié', 'Wed', 'Mer');
  String get dayThuShort => _t('Jue', 'Thu', 'Jeu');
  String get dayFriShort => _t('Vie', 'Fri', 'Ven');
  String get daySatShort => _t('Sáb', 'Sat', 'Sam');
  String get daySunShort => _t('Dom', 'Sun', 'Dim');
  String get weekdaysLabel => _t('Días de Semana', 'Weekdays', 'Jours ouvrables');
  String get everyDay => _t('Todos los días', 'Every day', 'Tous les jours');
  String get holidays => _t('Festivos', 'Holidays', 'Jours fériés');
  String minBefore(String n) => _t('$n min antes', '$n min before', '$n min avant');

  // ---------------------------------------------------------------------------
  // AUTH – LOGIN SCREEN
  // ---------------------------------------------------------------------------

  String get welcome => _t('Bienvenido', 'Welcome', 'Bienvenue');
  String get signInSubtitle => _t('Inicia sesión para continuar', 'Sign in to continue', 'Connectez-vous pour continuer');
  String get emailField => _t('Correo electrónico', 'Email', 'E-mail');
  String get passwordField => _t('Contraseña', 'Password', 'Mot de passe');
  String get forgotPassword => _t('¿Olvidaste tu contraseña?', 'Forgot your password?', 'Mot de passe oublié ?');
  String get signIn => _t('Iniciar sesión', 'Sign in', 'Se connecter');
  String get continueGoogle => _t('Continuar con Google', 'Continue with Google', 'Continuer avec Google');
  String get continueApple => _t('Continuar con Apple', 'Continue with Apple', 'Continuer avec Apple');
  String get noAccount => _t('¿No tienes cuenta?', "Don't have an account?", "Vous n'avez pas de compte ?");
  String get createAccount => _t('Crear cuenta', 'Create account', 'Créer un compte');
  String signInError(String e) => _t('Error al iniciar sesión: $e', 'Sign in error: $e', 'Erreur de connexion : $e');
  String get enterEmailForReset => _t(
    'Ingresa tu correo para recuperar la contraseña',
    'Enter your email to reset your password',
    'Entrez votre e-mail pour réinitialiser votre mot de passe',
  );
  String get resetEmailSent => _t(
    'Te enviamos un correo para restablecer tu contraseña',
    'We sent you an email to reset your password',
    'Nous vous avons envoyé un e-mail pour réinitialiser votre mot de passe',
  );
  String genericError(String e) => _t('Error: $e', 'Error: $e', 'Erreur : $e');
  String googleError(String e) => _t('Error con Google: $e', 'Google error: $e', 'Erreur Google : $e');
  String appleError(String e) => _t('Error con Apple: $e', 'Apple error: $e', 'Erreur Apple : $e');
  String get enterYourEmail => _t('Ingresa tu correo', 'Enter your email', 'Entrez votre e-mail');
  String get enterYourPassword => _t('Ingresa tu contraseña', 'Enter your password', 'Entrez votre mot de passe');
  String get min6Chars => _t('Mínimo 6 caracteres', 'Minimum 6 characters', '6 caractères minimum');
  String get emailNotValid => _t('El correo no es válido', 'The email is not valid', "L'e-mail n'est pas valide");
  String get accountDisabled => _t('Esta cuenta está deshabilitada', 'This account is disabled', 'Ce compte est désactivé');
  String get noAccountWithEmail => _t('No existe una cuenta con ese correo', 'No account exists with that email', "Aucun compte n'existe avec cet e-mail");
  String get wrongPassword => _t('Contraseña incorrecta', 'Incorrect password', 'Mot de passe incorrect');
  String get tooManyRequests => _t('Demasiados intentos, intenta más tarde', 'Too many attempts, try later', 'Trop de tentatives, réessayez plus tard');
  String get networkError => _t('Error de red, revisa tu conexión', 'Network error, check your connection', 'Erreur réseau, vérifiez votre connexion');
  String signInErrorCode(String code) => _t('Error al iniciar sesión: $code', 'Sign in error: $code', 'Erreur de connexion : $code');
  String get googlePlayError => _t(
    'Error al iniciar con Google. Revisa Servicios de Google Play y vuelve a intentar',
    'Google sign in error. Check Google Play Services and try again',
    'Erreur de connexion Google. Vérifiez les services Google Play et réessayez',
  );
  String get signInCanceled => _t('Inicio de sesión cancelado', 'Sign in canceled', 'Connexion annulée');
  String get emailDifferentProvider => _t(
    'El correo ya está registrado con otro método',
    'Email already registered with another method',
    'E-mail déjà enregistré avec une autre méthode',
  );

  // ---------------------------------------------------------------------------
  // AUTH – REGISTER SCREEN
  // ---------------------------------------------------------------------------

  String get createAccountTitle => _t('Crear cuenta', 'Create Account', 'Créer un compte');
  String get createYourAccount => _t('Crea tu cuenta', 'Create your account', 'Créez votre compte');
  String get completeData => _t('Completa tus datos para comenzar', 'Complete your data to get started', 'Complétez vos données pour commencer');
  String get fullName => _t('Nombre completo', 'Full name', 'Nom complet');
  String createAccountError(String e) => _t('Error al crear cuenta: $e', 'Error creating account: $e', 'Erreur de création de compte : $e');
  String get enterYourName => _t('Ingresa tu nombre', 'Enter your name', 'Entrez votre nom');
  String get nameTooShort => _t('Nombre demasiado corto', 'Name too short', 'Nom trop court');
  String get emailInUse => _t('Ese correo ya está registrado', 'That email is already registered', 'Cet e-mail est déjà enregistré');
  String get weakPassword => _t('La contraseña es muy débil', 'The password is too weak', 'Le mot de passe est trop faible');
  String get registrationNotAllowed => _t(
    'Este método de registro no está habilitado',
    'This registration method is not enabled',
    "Cette méthode d'inscription n'est pas activée",
  );
  String createAccountErrorCode(String code) => _t('Error al crear cuenta: $code', 'Error creating account: $code', 'Erreur de création de compte : $code');

  // ---------------------------------------------------------------------------
  // SUPPORT SCREEN
  // ---------------------------------------------------------------------------

  String get supportHebrewTitle => 'צדקת רבי מאיר בעל הנס';
  String get colelJabad => _t('Colel Jabad', 'Colel Chabad', "Colel 'Habad");
  String get tagline1788 => _t(
    'Cuidando a los necesitados de Israel desde 1788',
    'Caring for the needy of Israel since 1788',
    "Prendre soin des nécessiteux d'Israël depuis 1788",
  );
  String get appVersionSection => _t('VERSIÓN DE LA APP', 'APP VERSION', "VERSION DE L'APP");
  String get supportSection => _t('SOPORTE', 'SUPPORT', 'ASSISTANCE');
  String get learnMoreColel => _t(
    'Aprende más sobre Colel Jabad y la Pushka de Colel Jabad.',
    'Learn more about Colel Chabad and the Colel Chabad Pushka.',
    "En savoir plus sur Colel 'Habad et la Pushka de Colel 'Habad.",
  );
  String get developedBy => _t('DESARROLLADO POR', 'DEVELOPED BY', 'DÉVELOPPÉ PAR');

  // ---------------------------------------------------------------------------
  // ABOUT SCREEN
  // ---------------------------------------------------------------------------

  String get aboutBreadcrumb => _t('Acerca de | Colel Jabad', 'About | Colel Chabad', "À propos | Colel 'Habad");
  String get aboutTitle => _t('Colel Jabad', 'Colel Chabad', "Colel 'Habad");
  String get aboutSection => _t('Acerca de', 'About', 'À propos');
  String get aboutP1 => _t(
    'Bienvenido a Colel Jabad. Somos la organización benéfica en funcionamiento continuo más antigua de Israel, dedicada a brindar asistencia a quienes la necesitan sin importar su origen.',
    'Welcome to Colel Chabad. We are the oldest continuously operating charity in Israel, dedicated to providing assistance to those in need regardless of their background.',
    "Bienvenue à Colel 'Habad. Nous sommes l'organisme caritatif le plus ancien en activité continue en Israël, dédié à fournir une assistance à ceux qui en ont besoin, quel que soit leur origine.",
  );
  String get aboutP2 => _t(
    'Nuestra misión es alimentar a los hambrientos, apoyar a viudas y huérfanos, y elevar comunidades a través de una variedad de programas arraigados en los valores atemporales de compasión y dignidad.',
    'Our mission is to feed the hungry, support widows and orphans, and uplift communities through a variety of programs rooted in timeless values of compassion and dignity.',
    "Notre mission est de nourrir les affamés, soutenir les veuves et les orphelins, et élever les communautés à travers des programmes enracinés dans les valeurs intemporelles de compassion et de dignité.",
  );
  String get aboutP3 => _t(
    'Desde nuestra fundación en 1788, Colel Jabad ha expandido sus servicios en todo Israel, operando bancos de alimentos, comedores comunitarios, programas de asistencia médica y más.',
    'Since our founding in 1788, Colel Chabad has expanded its services throughout Israel, operating food banks, community kitchens, medical assistance programs and more.',
    "Depuis notre fondation en 1788, Colel 'Habad a étendu ses services à travers tout Israël, opérant des banques alimentaires, des cuisines communautaires, des programmes d'assistance médicale et plus encore.",
  );
  String get privacyPolicy => _t('Política de Privacidad', 'Privacy Policy', 'Politique de confidentialité');
  String get termsOfService => _t('Términos de Servicio', 'Terms of Service', "Conditions d'utilisation");
  String get copyright => _t(
    '© 2026 Colel Jabad. Todos los derechos reservados.',
    '© 2026 Colel Chabad. All rights reserved.',
    "© 2026 Colel 'Habad. Tous droits réservés.",
  );

  // ---------------------------------------------------------------------------
  // AUTO EMPTY SCREEN
  // ---------------------------------------------------------------------------

  String get autoEmpty => _t('Auto Vaciar', 'Auto Empty', 'Vidage automatique');
  String get autoEmptyLabel => _t('Auto Vaciado', 'Auto Empty', 'Vidage automatique');
  String get activated => _t('Activado', 'Activated', 'Activé');
  String get deactivated => _t('Desactivado', 'Deactivated', 'Désactivé');
  String get autoEmptyInfo => _t(
    'Cuando esté activado, tu Pushka se vaciará automáticamente según la frecuencia que elijas.',
    'When activated, your Pushka will empty automatically based on the frequency you choose.',
    'Lorsqu\'il est activé, votre Pushka se videra automatiquement selon la fréquence choisie.',
  );
  String get minBalanceInfo => _t(
    'Si el saldo de tu Pushka es menor a \$5, el vaciado se pospondrá hasta el próximo ciclo.',
    'If your Pushka balance is less than \$5, emptying will be postponed until the next cycle.',
    'Si le solde de votre Pushka est inférieur à 5 \$, le vidage sera reporté au prochain cycle.',
  );
  String get frequency => _t('Frecuencia', 'Frequency', 'Fréquence');
  String get freqWeekly => _t('Semanal', 'Weekly', 'Hebdomadaire');
  String get freqMonthly => _t('Mensual', 'Monthly', 'Mensuel');
  String get freqErevRosh => _t('Erev Rosh Jódesh', 'Erev Rosh Chodesh', "Veille de Roch 'Hodech");
  String get dayOfWeek => _t('Día de la semana', 'Day of the week', 'Jour de la semaine');
  String get dayOfMonth => _t('Día del mes', 'Day of the month', 'Jour du mois');
  String get erevRoshNote => _t(
    'Se vaciará automáticamente cada víspera de Rosh Jódesh según el calendario hebreo.',
    'Will empty automatically every Erev Rosh Chodesh according to the Hebrew calendar.',
    "Se videra automatiquement chaque veille de Roch 'Hodech selon le calendrier hébraïque.",
  );
  String nextEmpty(String date) => _t('Próximo vaciado: $date', 'Next empty: $date', 'Prochain vidage : $date');
  String get notScheduled => _t('No programado', 'Not scheduled', 'Non programmé');
  String get pushkaTopOff => _t('Relleno de Pushka', 'Pushka Top Off', 'Remplissage de la Pushka');
  String get topOffDescription => _t(
    'Si el saldo es muy bajo, lo completaremos al mínimo antes de vaciar.',
    'If the balance is too low, we will top it off to the minimum before emptying.',
    'Si le solde est trop bas, nous le compléterons au minimum avant de vider.',
  );
  String get settingsSaved => _t('Configuración guardada', 'Settings saved', 'Paramètres enregistrés');
  String get saveError => _t('Error al guardar. Intenta nuevamente.', 'Error saving. Try again.', "Erreur d'enregistrement. Réessayez.");
  String get dayMonFull => _t('Lunes', 'Monday', 'Lundi');
  String get dayTueFull => _t('Martes', 'Tuesday', 'Mardi');
  String get dayWedFull => _t('Miércoles', 'Wednesday', 'Mercredi');
  String get dayThuFull => _t('Jueves', 'Thursday', 'Jeudi');
  String get dayFriFull => _t('Viernes', 'Friday', 'Vendredi');
  String get daySatFull => _t('Sábado', 'Saturday', 'Samedi');
  String get daySunFull => _t('Domingo', 'Sunday', 'Dimanche');
  String get daySatFull => _t('Sábado', 'Saturday', 'Samedi');
  String get daySunFull => _t('Domingo', 'Sunday', 'Dimanche');
  String get monthJan => _t('Ene', 'Jan', 'Jan');
  String get monthFeb => _t('Feb', 'Feb', 'Fév');
  String get monthMar => _t('Mar', 'Mar', 'Mar');
  String get monthApr => _t('Abr', 'Apr', 'Avr');
  String get monthMay => _t('May', 'May', 'Mai');
  String get monthJun => _t('Jun', 'Jun', 'Jun');
  String get monthJul => _t('Jul', 'Jul', 'Jui');
  String get monthAug => _t('Ago', 'Aug', 'Aoû');
  String get monthSep => _t('Sep', 'Sep', 'Sep');
  String get monthOct => _t('Oct', 'Oct', 'Oct');
  String get monthNov => _t('Nov', 'Nov', 'Nov');
  String get monthDec => _t('Dic', 'Dec', 'Déc');

  // ---------------------------------------------------------------------------
  // WALLET AUTO REFILL
  // ---------------------------------------------------------------------------

  String get autoRefillSaved => _t('Recarga automática guardada', 'Auto refill saved', 'Recharge automatique enregistrée');
  String couldNotSaveError(String e) => _t('No se pudo guardar: $e', 'Could not save: $e', "Impossible d'enregistrer : $e");
  String get frequencyLabel => _t('FRECUENCIA', 'FREQUENCY', 'FRÉQUENCE');
  String get recurringDay => _t('DÍA RECURRENTE', 'RECURRING DAY', 'JOUR RÉCURRENT');
  String get selectHint => _t('Seleccionar', 'Select', 'Sélectionner');
  String get amountLabel => _t('MONTO', 'AMOUNT', 'MONTANT');
  String get disableAutoRefill => _t('DESACTIVAR RECARGA AUTOMÁTICA', 'DISABLE AUTO REFILL', 'DÉSACTIVER LA RECHARGE AUTOMATIQUE');
  String get autoRefillDisabled => _t('Recarga automática desactivada', 'Auto refill disabled', 'Recharge automatique désactivée');

  // ---------------------------------------------------------------------------
  // WALLET SEND / REQUEST
  // ---------------------------------------------------------------------------

  String get selectContactBanner => _t(
    'Selecciona un contacto para enviar o solicitar dinero.',
    'Select a contact to send or request money.',
    "Sélectionnez un contact pour envoyer ou demander de l'argent.",
  );
  String get invalidWalletId => _t('Ingresa un ID de billetera válido', 'Enter a valid wallet ID', 'Entrez un ID de portefeuille valide');
  String get contactAdded => _t('Contacto agregado', 'Contact added', 'Contact ajouté');
  String get verification => _t('Verificación', 'Verification', 'Vérification');
  String get verificationBody => _t(
    'Para enviar o solicitar tzedaká, primero verifica el contacto:\n• Escanea su ID de billetera (arriba a la derecha en esta pantalla), o\n• Escribe el código de 6 dígitos que te comparta.',
    'To send or request tzedakah, first verify the contact:\n• Scan their wallet ID (top right on this screen), or\n• Enter the 6-digit code they share with you.',
    "Pour envoyer ou demander de la tsédaka, vérifiez d'abord le contact :\n• Scannez leur ID de portefeuille (en haut à droite de cet écran), ou\n• Entrez le code à 6 chiffres qu'ils vous partagent.",
  );
  String get scanWalletId => _t('Escanear ID de billetera', 'Scan wallet ID', "Scanner l'ID du portefeuille");
  String get enterWalletId => _t('Ingresar ID de billetera', 'Enter wallet ID', "Entrer l'ID du portefeuille");
  String get writeWalletId => _t('Escribe ID de billetera', 'Write wallet ID', "Écrivez l'ID du portefeuille");
  String get addNewContact => _t('+ AGREGAR NUEVO CONTACTO', '+ ADD NEW CONTACT', '+ AJOUTER UN NOUVEAU CONTACT');
  String get yourContacts => _t('TUS CONTACTOS', 'YOUR CONTACTS', 'VOS CONTACTS');
  String get signInForContacts => _t('Inicia sesión para ver tus contactos', 'Sign in to see your contacts', 'Connectez-vous pour voir vos contacts');
  String get errorLoadingContacts => _t('Error cargando contactos', 'Error loading contacts', 'Erreur de chargement des contacts');
  String get noContacts => _t('Sin contactos', 'No contacts', 'Aucun contact');
  String get defaultContact => _t('Contacto', 'Contact', 'Contact');
  String idPrefix(String id) => _t('ID: $id', 'ID: $id', 'ID : $id');
  String get send => _t('ENVIAR', 'SEND', 'ENVOYER');
  String get request => _t('SOLICITAR', 'REQUEST', 'DEMANDER');
  String sent(String amount, String id) => _t('Enviado \$$amount a $id', 'Sent \$$amount to $id', 'Envoyé $amount à $id');
  String requestSent(String amount) => _t('Solicitud de \$$amount enviada', 'Request for \$$amount sent', 'Demande de $amount envoyée');

  // ---------------------------------------------------------------------------
  // PRAYERS SCREEN
  // ---------------------------------------------------------------------------

  String get prayersNote => _t(
    'Nota: Este es un ejemplo. Los textos se mejorarán y perfeccionarán más adelante.',
    'Note: This is an example. Texts will be improved and refined later.',
    'Note : Ceci est un exemple. Les textes seront améliorés et affinés ultérieurement.',
  );
  String get prayerTitleEs => _t('DIOS DE (RABINO) MEIR, RESPÓNDEME', 'GOD OF (RABBI) MEIR, ANSWER ME', 'DIEU DE (RABBI) MEIR, RÉPONDS-MOI');
  String get prayerP1 => _t(
    'Se enseñó en nombre del Baal Shem Tov: Una persona que se encuentra en una situación peligrosa que requiere un milagro debe dar 18 monedas grandes, referidas como Gedolim, para velas que se encenderán en una sinagoga.',
    'It was taught in the name of the Baal Shem Tov: A person in a dangerous situation requiring a miracle should give 18 large coins, referred to as Gedolim, for candles to be lit in a synagogue.',
    'Il a été enseigné au nom du Baal Chem Tov : Une personne dans une situation dangereuse nécessitant un miracle doit donner 18 grandes pièces, appelées Guedolim, pour des bougies à allumer dans une synagogue.',
  );
  String get prayerP2 => _t(
    'Debe entonces declarar: "Me comprometo a dar estas 18 monedas por el mérito del alma del Rabino Meir, el maestro de los milagros."',
    'One should then declare: "I commit to give these 18 coins for the merit of the soul of Rabbi Meir, the master of miracles."',
    'On doit alors déclarer : « Je m\'engage à donner ces 18 pièces pour le mérite de l\'âme du Rabbin Meir, le maître des miracles. »',
  );
  String get prayerP3 => _t(
    'Debe entonces repetir tres veces: "Dios de (Rabino) Meir, (por favor) respóndeme."',
    'One should then repeat three times: "God of (Rabbi) Meir, (please) answer me."',
    'On doit alors répéter trois fois : « Dieu de (Rabbi) Meir, (s\'il vous plaît) réponds-moi. »',
  );
  String get prayerP4 => _t(
    'Y así sea Tu voluntad, nuestro Dios y Dios de nuestros padres, que así como respondiste a la oración de Tu siervo (Rabino) Meir, realizando milagros y maravillas para él, así también puedas realizar para mí y para todo el pueblo de Tu nación, Israel, que está en necesidad de milagros, tanto revelados como ocultos. Amén, que sea Tu voluntad.',
    'And may it be Your will, our God and God of our fathers, that just as You answered the prayer of Your servant (Rabbi) Meir, performing miracles and wonders for him, so too may You perform for me and for all the people of Your nation, Israel, who are in need of miracles, both revealed and hidden. Amen, may it be Your will.',
    'Et que ce soit Ta volonté, notre Dieu et Dieu de nos pères, que tout comme Tu as répondu à la prière de Ton serviteur (Rabbi) Meir, accomplissant des miracles et des merveilles pour lui, ainsi puisses-Tu accomplir pour moi et pour tout le peuple de Ta nation, Israël, qui a besoin de miracles, tant révélés que cachés. Amen, que ce soit Ta volonté.',
  );

  // ---------------------------------------------------------------------------
  // PAYMENT INSTRUCTION TEXTS
  // ---------------------------------------------------------------------------

  String checkInstructions(String amount) => _t(
    'Envía un cheque por el monto de $amount a:\n\nNombre: [Nombre de la Organización]\nDirección: [Dirección postal]\nCiudad, Estado, ZIP: [Ciudad, ST 00000]\n\nReferencia: Incluye tu email o ID de usuario en el memo del cheque.\n\nUna vez recibido y procesado, la donación se marcará como confirmada en tu historial.',
    'Send a check for $amount to:\n\nName: [Organization Name]\nAddress: [Mailing Address]\nCity, State, ZIP: [City, ST 00000]\n\nReference: Include your email or user ID in the check memo.\n\nOnce received and processed, the donation will be marked as confirmed in your history.',
    'Envoyez un chèque de $amount à :\n\nNom : [Nom de l\'Organisation]\nAdresse : [Adresse postale]\nVille, État, Code postal : [Ville, XX 00000]\n\nRéférence : Incluez votre e-mail ou ID utilisateur dans le mémo du chèque.\n\nUne fois reçu et traité, le don sera marqué comme confirmé dans votre historique.',
  );

  String transferInstructions(String amount) => _t(
    'Transfiere $amount a la siguiente cuenta:\n\nBanco: [Nombre del Banco]\nNúmero de cuenta: [XXXX-XXXX-XXXX]\nRouting / ABA: [XXXXXXXXX]\nBeneficiario: [Nombre de la Organización]\n\nReferencia: Usa tu email como referencia de la transferencia.\n\nEl pago se confirmará automáticamente en 2-3 días hábiles.',
    'Transfer $amount to the following account:\n\nBank: [Bank Name]\nAccount number: [XXXX-XXXX-XXXX]\nRouting / ABA: [XXXXXXXXX]\nBeneficiary: [Organization Name]\n\nReference: Use your email as transfer reference.\n\nPayment will be confirmed automatically in 2-3 business days.',
    'Transférez $amount vers le compte suivant :\n\nBanque : [Nom de la Banque]\nNuméro de compte : [XXXX-XXXX-XXXX]\nRouting / ABA : [XXXXXXXXX]\nBénéficiaire : [Nom de l\'Organisation]\n\nRéférence : Utilisez votre e-mail comme référence de virement.\n\nLe paiement sera confirmé automatiquement sous 2 à 3 jours ouvrables.',
  );

  String dafInstructions(String amount) => _t(
    'Realiza una donación de $amount desde tu DAF a:\n\nOrganización: [Nombre Legal de la Organización]\nEIN: [XX-XXXXXXX]\nDirección: [Dirección de la Organización]\n\nIndica tu email en el campo de notas del grant.\n\nProveedores comunes: Fidelity Charitable, Schwab Charitable, DAF Direct.\n\nUna vez procesado el grant, la donación se confirmará en tu historial.',
    'Make a donation of $amount from your DAF to:\n\nOrganization: [Legal Organization Name]\nEIN: [XX-XXXXXXX]\nAddress: [Organization Address]\n\nInclude your email in the grant notes field.\n\nCommon providers: Fidelity Charitable, Schwab Charitable, DAF Direct.\n\nOnce the grant is processed, the donation will be confirmed in your history.',
    'Faites un don de $amount depuis votre DAF à :\n\nOrganisation : [Nom Légal de l\'Organisation]\nEIN : [XX-XXXXXXX]\nAdresse : [Adresse de l\'Organisation]\n\nIndiquez votre e-mail dans le champ notes de la subvention.\n\nFournisseurs courants : Fidelity Charitable, Schwab Charitable, DAF Direct.\n\nUne fois la subvention traitée, le don sera confirmé dans votre historique.',
  );

  String get checkTitle => _t('Pago con Cheque', 'Check Payment', 'Paiement par chèque');
  String get transferTitle => _t('Transferencia Bancaria', 'Bank Transfer', 'Virement bancaire');
  String get dafTitle => _t('Donor Advised Fund (DAF)', 'Donor Advised Fund (DAF)', 'Donor Advised Fund (DAF)');
}

// -----------------------------------------------------------------------------
// DELEGATE
// -----------------------------------------------------------------------------

class _SDelegate extends LocalizationsDelegate<S> {
  const _SDelegate();

  @override
  bool isSupported(Locale locale) =>
      ['es', 'en', 'fr'].contains(locale.languageCode);

  @override
  Future<S> load(Locale locale) async => S(locale);

  @override
  bool shouldReload(covariant LocalizationsDelegate<S> old) => false;
}
