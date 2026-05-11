// Privacy Policy + Terms of Service content for in-app rendering.
//
// All text lives here (not in remote URLs) so review of legal language is
// version-controlled alongside code. Last revision date drives the
// "Last updated" line shown in-app and informs users when re-acceptance is
// expected (we don't currently force re-accept on update — see runbooks).
//
// 4 languages: Spanish (canonical), English, French, Hebrew. Translations
// are pragmatic (not certified) — for a production launch in jurisdictions
// requiring sworn translations (FR, HE), have these reviewed by a lawyer.

class LegalSection {
  const LegalSection({required this.title, required this.paragraphs});
  final String title;
  final List<String> paragraphs;
}

class LegalDoc {
  const LegalDoc({
    required this.title,
    required this.lastUpdated,
    required this.intro,
    required this.sections,
  });
  final String title;
  final String lastUpdated;
  final String intro;
  final List<LegalSection> sections;
}

class LegalContent {
  const LegalContent({required this.privacy, required this.terms});
  final LegalDoc privacy;
  final LegalDoc terms;
}

const String _lastUpdatedLabel = 'Última actualización: 7 de mayo de 2026';
const String _lastUpdatedLabelEn = 'Last updated: May 7, 2026';
const String _lastUpdatedLabelFr = 'Dernière mise à jour : 7 mai 2026';
const String _lastUpdatedLabelHe = 'עדכון אחרון: 7 במאי 2026';

// Default contact email — also acts as the substitution sentinel below.
// If `tenantContactEmail` is provided to `legalContentFor`, every occurrence
// of this literal across the legal text gets rewritten to the tenant-specific
// address. Picked a unique-looking string so the replacement can't collide
// with user-generated content.
const String _contactEmail = 'support@pushkaapp.com';

/// Returns the legal content (privacy + terms) for the given language code,
/// optionally rewriting the default Pushka support email to the tenant's
/// own `contactEmail` (BUG-002/012/066 fix, Audit Round 4 Phase 1/8).
///
/// Pre-fix every donor across every tenant saw `support@pushkaapp.com` —
/// not multi-tenant correct. Now each tenant's legal page reflects their
/// own contact channel when configured.
LegalContent legalContentFor(String languageCode, {String? tenantContactEmail}) {
  final base = switch (languageCode) {
    'en' => _legalContentEn,
    'fr' => _legalContentFr,
    'he' => _legalContentHe,
    _    => _legalContentEs,
  };
  final overrideEmail = (tenantContactEmail ?? '').trim();
  if (overrideEmail.isEmpty || overrideEmail == _contactEmail) {
    return base;
  }
  return _rewriteContactEmail(base, overrideEmail);
}

LegalContent _rewriteContactEmail(LegalContent base, String newEmail) {
  return LegalContent(
    privacy: _rewriteDoc(base.privacy, newEmail),
    terms: _rewriteDoc(base.terms, newEmail),
  );
}

LegalDoc _rewriteDoc(LegalDoc doc, String newEmail) {
  return LegalDoc(
    title: doc.title.replaceAll(_contactEmail, newEmail),
    lastUpdated: doc.lastUpdated,
    intro: doc.intro.replaceAll(_contactEmail, newEmail),
    sections: doc.sections
        .map((s) => LegalSection(
              title: s.title.replaceAll(_contactEmail, newEmail),
              paragraphs: s.paragraphs
                  .map((p) => p.replaceAll(_contactEmail, newEmail))
                  .toList(growable: false),
            ))
        .toList(growable: false),
  );
}

// ---------------------------------------------------------------------------
// ESPAÑOL (canónico)
// ---------------------------------------------------------------------------

const _legalContentEs = LegalContent(
  privacy: LegalDoc(
    title: 'Política de Privacidad',
    lastUpdated: _lastUpdatedLabel,
    intro:
        'Esta Política describe cómo Pushka recopila, usa, comparte y protege tu información cuando utilizás la aplicación. Al usar Pushka, aceptás las prácticas descritas aquí. Si no estás de acuerdo, te pedimos que no uses la app.',
    sections: [
      LegalSection(
        title: '1. Quiénes somos',
        paragraphs: [
          'Pushka es una plataforma multi-organización ("multi-tenant") que conecta donantes con organizaciones de beneficencia (cada una, una "Organización" o "Tenant"). Cada Organización opera su propia identidad, marca y destino de fondos dentro de la app.',
          'Pushka no es la organización receptora de tus donaciones. Actuamos como intermediario tecnológico que facilita el pago entre vos (donante) y la Organización que elegiste apoyar.',
        ],
      ),
      LegalSection(
        title: '2. Información que recopilamos',
        paragraphs: [
          '2.1 Datos de cuenta: nombre, dirección de correo electrónico, foto de perfil (opcional), credenciales de inicio de sesión proporcionadas por Firebase Authentication, idioma preferido y país/moneda.',
          '2.2 Datos de pago: NO almacenamos los datos completos de tu tarjeta de crédito o débito. El procesamiento se realiza íntegramente a través de Stripe, Inc. Únicamente conservamos un identificador de cliente de Stripe ("stripeCustomerId"), los últimos 4 dígitos de la tarjeta y la marca (Visa, Mastercard, etc.) para mostrarlos en tu lista de tarjetas guardadas.',
          '2.3 Historial de donaciones: monto, moneda, fecha, organización receptora, designación elegida (si aplica), mensaje opcional del donante y método de pago. Esta información es necesaria para cumplir con obligaciones contables y fiscales tanto nuestras como de las Organizaciones receptoras.',
          '2.4 Datos de uso y dispositivo: tipo de dispositivo, sistema operativo, idioma, identificador único de la app (no del dispositivo), región aproximada inferida del idioma o moneda. NO recopilamos tu ubicación GPS precisa.',
          '2.5 Notificaciones push: tokens de Firebase Cloud Messaging para enviarte recordatorios, confirmaciones de pago y avisos de festividades.',
          '2.6 Datos de soporte: cuando nos contactás por correo, conservamos el contenido del mensaje y tu dirección de correo para responder.',
          '2.7 Información que NO recopilamos: contactos de tu agenda, fotos de tu galería (excepto la que vos subas como foto de perfil), historial de navegación fuera de la app, datos de salud, datos biométricos (la autenticación biométrica para abrir la app se procesa exclusivamente en tu dispositivo y nunca llega a nuestros servidores).',
        ],
      ),
      LegalSection(
        title: '3. Cómo usamos tu información',
        paragraphs: [
          '3.1 Procesamiento de donaciones: para crear cargos en Stripe, transferir fondos a la Organización receptora a través de Stripe Connect, generar comprobantes y mantener el historial.',
          '3.2 Funcionamiento de la app: para operar tu cuenta, mantener tu balance acumulado en tu pushka virtual, gestionar suscripciones recurrentes, programar el vaciado automático y mostrar tu historial.',
          '3.3 Notificaciones: para enviarte recordatorios de festividades, confirmaciones de pago, alertas de cobros fallidos y otras comunicaciones operativas relacionadas con tu cuenta.',
          '3.4 Seguridad y prevención de fraude: para detectar y prevenir actividad sospechosa, proteger contra accesos no autorizados y cumplir con requisitos antifraude de Stripe.',
          '3.5 Mejoras y analítica: para entender cómo se usa la app, identificar errores, optimizar la experiencia. Usamos Firebase Analytics y Crashlytics, que pueden recopilar datos agregados sobre el uso. Podés desactivar la recopilación opcional desde la configuración de tu dispositivo.',
          '3.6 Cumplimiento legal: para cumplir con obligaciones fiscales, contables, antifraude y antilavado aplicables.',
        ],
      ),
      LegalSection(
        title: '4. Stripe y el procesamiento de pagos',
        paragraphs: [
          'Pushka utiliza Stripe, Inc. (con sede en San Francisco, EE.UU.) para procesar todos los pagos. Cuando ingresás los datos de tu tarjeta, estos se transmiten directamente a Stripe a través de su SDK certificado en PCI DSS Nivel 1, sin pasar por nuestros servidores.',
          'Stripe es un controlador independiente de los datos de pago que recolecta. Su uso de tu información se rige por la Política de Privacidad de Stripe, disponible en https://stripe.com/privacy.',
          'Si optás por guardar una tarjeta para futuros cobros, Stripe almacena los datos completos de forma segura y nos devuelve únicamente un token (identificador) que usamos para iniciar nuevos cobros con tu autorización previa.',
        ],
      ),
      LegalSection(
        title: '5. Modelo multi-tenant — qué se comparte con la Organización',
        paragraphs: [
          'Cuando donás a una Organización a través de Pushka, esa Organización recibe acceso a información necesaria para gestionar tu donación: tu nombre o seudónimo, dirección de correo electrónico, monto donado, fecha, designación elegida (si la Organización configuró opciones) y mensaje opcional que vos hayas escrito.',
          'La Organización NO recibe datos completos de tu tarjeta, tu contraseña, tu historial de donaciones a otras organizaciones, ni datos sensibles fuera del contexto de las donaciones que vos le hayas hecho específicamente a ella.',
          'Cada Organización es responsable como controlador independiente de los datos personales que recibe a través de Pushka. Recomendamos consultar la política de privacidad de la Organización a la que estás donando.',
          'Si elegís donar a múltiples Organizaciones desde la misma cuenta, mantenemos los historiales y donaciones recurrentes separados por Organización.',
        ],
      ),
      LegalSection(
        title: '6. Servicios de terceros',
        paragraphs: [
          'Para operar Pushka utilizamos los siguientes proveedores como sub-procesadores de datos:',
          '• Google Firebase (Authentication, Firestore, Cloud Functions, Cloud Messaging, Analytics, Crashlytics, App Check) — Google Ireland Limited / Google LLC.',
          '• Stripe, Inc. — procesamiento de pagos, Stripe Connect.',
          '• SendGrid (cuando aplica) — envío de correos transaccionales.',
          'Estos proveedores procesan datos en nuestro nombre conforme a sus propias políticas de privacidad y acuerdos de protección de datos.',
        ],
      ),
      LegalSection(
        title: '7. Compartir información',
        paragraphs: [
          'No vendemos, alquilamos ni intercambiamos tu información personal con terceros con fines comerciales.',
          'Compartimos información cuando: (a) sea estrictamente necesario para el funcionamiento del servicio (por ejemplo, enviar tus datos de pago a Stripe); (b) sea requerido por una autoridad competente o una orden judicial válida; (c) sea necesario para proteger derechos, propiedad o seguridad de Pushka, sus usuarios o terceros; (d) en caso de fusión, adquisición o venta de activos, en cuyo caso te notificaremos de la transferencia y de cualquier cambio de política aplicable.',
        ],
      ),
      LegalSection(
        title: '8. Retención y eliminación',
        paragraphs: [
          'Conservamos tu información mientras tu cuenta esté activa. Los datos de transacciones se conservan por al menos el período mínimo requerido por leyes contables, fiscales y antilavado aplicables (típicamente 5 a 10 años, según jurisdicción), incluso después de que cierres tu cuenta.',
          'Podés eliminar tu cuenta en cualquier momento desde Configuración → "Eliminar mi cuenta". Al hacerlo: cancelaremos tus suscripciones recurrentes activas, eliminaremos tu cliente en Stripe (lo que desvincula todas las tarjetas guardadas), y borraremos tus datos personales identificables. El historial de transacciones se anonimiza pero se conserva por las razones legales mencionadas arriba.',
          'También podés exportar tus datos en cualquier momento desde Configuración → "Exportar mis datos".',
        ],
      ),
      LegalSection(
        title: '9. Tus derechos',
        paragraphs: [
          'Dependiendo de tu jurisdicción, podés tener los siguientes derechos sobre tus datos personales: acceso, rectificación, eliminación, oposición al procesamiento, portabilidad, limitación del procesamiento y retiro del consentimiento.',
          'Residentes de la Unión Europea / Espacio Económico Europeo (RGPD): tenés derecho a presentar reclamos ante tu autoridad de protección de datos local.',
          'Residentes de California (CCPA/CPRA): tenés derecho a saber qué información recopilamos, eliminarla, corregirla y a no ser discriminado por ejercer estos derechos.',
          'Residentes de Brasil (LGPD), Argentina (Ley 25.326) y otras jurisdicciones latinoamericanas: tenés derechos análogos según tu legislación local.',
          'Para ejercer cualquier derecho, contactanos en $_contactEmail. Responderemos dentro del plazo que exija la ley aplicable (típicamente 30 días).',
        ],
      ),
      LegalSection(
        title: '10. Seguridad',
        paragraphs: [
          'Aplicamos medidas técnicas y organizativas razonables para proteger tu información: cifrado en tránsito (TLS 1.2+), cifrado en reposo (Firebase y Stripe), Firebase App Check para prevenir abuso de API, autenticación obligatoria, separación lógica entre Organizaciones y registros de auditoría.',
          'Ningún sistema es 100% seguro. En caso de un incidente de seguridad que afecte tus datos, te notificaremos sin demora indebida según lo exija la ley aplicable.',
        ],
      ),
      LegalSection(
        title: '11. Menores de edad',
        paragraphs: [
          'Pushka NO está dirigido a menores de 13 años (o 16 años en jurisdicciones del EEE). No recopilamos a sabiendas datos personales de menores. Si descubrimos que recolectamos datos de un menor sin el consentimiento parental requerido, eliminaremos esa información de inmediato.',
          'Si sos padre, madre o tutor y creés que tu hijo nos ha proporcionado información personal, contactanos en $_contactEmail.',
        ],
      ),
      LegalSection(
        title: '12. Transferencias internacionales',
        paragraphs: [
          'Pushka opera con servidores ubicados principalmente en Estados Unidos (Firebase, Stripe). Al usar la app, entendés que tus datos pueden transferirse y procesarse fuera de tu país de residencia, en jurisdicciones que pueden tener leyes de protección de datos diferentes a las tuyas.',
          'Implementamos cláusulas contractuales tipo y otras salvaguardas exigidas por las leyes de protección de datos aplicables para asegurar un nivel adecuado de protección.',
        ],
      ),
      LegalSection(
        title: '13. Cambios en esta política',
        paragraphs: [
          'Podemos actualizar esta política para reflejar cambios en nuestras prácticas, requisitos legales o funcionalidades del servicio. Cuando lo hagamos, actualizaremos la fecha de "Última actualización" arriba. Si los cambios son materiales, te notificaremos a través de la app o por correo electrónico antes de que entren en vigor.',
          'Tu uso continuado de Pushka tras la entrada en vigor de los cambios constituirá tu aceptación de la política revisada.',
        ],
      ),
      LegalSection(
        title: '14. Contacto',
        paragraphs: [
          'Si tenés preguntas, comentarios o reclamos sobre esta Política de Privacidad o sobre cómo manejamos tus datos, escribinos a:',
          'Pushka — Soporte y Privacidad',
          'Correo: $_contactEmail',
        ],
      ),
    ],
  ),
  terms: LegalDoc(
    title: 'Términos de Servicio',
    lastUpdated: _lastUpdatedLabel,
    intro:
        'Estos Términos rigen tu uso de Pushka. Al crear una cuenta o utilizar la aplicación, aceptás estos Términos. Si no estás de acuerdo, te pedimos que no uses la app.',
    sections: [
      LegalSection(
        title: '1. Aceptación de los Términos',
        paragraphs: [
          'Al registrarte, instalar o utilizar Pushka, confirmás que leíste, entendiste y aceptás estos Términos de Servicio y la Política de Privacidad. Si usás Pushka en nombre de una organización, declarás tener autoridad para vincularla a estos Términos.',
        ],
      ),
      LegalSection(
        title: '2. Descripción del servicio',
        paragraphs: [
          'Pushka es una plataforma multi-organización que permite a donantes realizar donaciones únicas o recurrentes a Organizaciones de beneficencia inscritas en la plataforma. Cada Organización configura su identidad, designaciones de destino y datos de cobro mediante Stripe Connect.',
          'Pushka actúa como facilitador tecnológico. NO somos la entidad receptora de los fondos donados — los fondos viajan directamente desde tu medio de pago hasta la cuenta Stripe Connect de la Organización elegida, descontando una comisión de plataforma.',
        ],
      ),
      LegalSection(
        title: '3. Cuenta de usuario',
        paragraphs: [
          'Para usar Pushka necesitás crear una cuenta con un correo electrónico válido. Sos responsable de proporcionar información veraz y mantenerla actualizada.',
          'Edad mínima: debés tener al menos 13 años (16 en jurisdicciones del EEE). Si sos menor de la mayoría de edad legal en tu jurisdicción, necesitás el consentimiento de un padre o tutor para usar la app y para realizar donaciones.',
          'Sos responsable de mantener la seguridad de tus credenciales. Notificanos de inmediato si sospechás un acceso no autorizado a tu cuenta.',
        ],
      ),
      LegalSection(
        title: '4. Cómo funcionan las donaciones',
        paragraphs: [
          '4.1 Donación única ("Donar ahora"): efectuás un cargo único a tu medio de pago. Una vez confirmado, los fondos se envían a la Organización elegida menos la comisión de plataforma.',
          '4.2 Pushka virtual ("Vaciar Pushka"): podés acumular un balance virtual ingresándolo manualmente en la app y, cuando lo decidas, cobrar el total acumulado en una sola transacción. La app ofrece también la opción de "Vaciado automático" que cobra periódicamente el balance acumulado.',
          '4.3 Donación recurrente: podés crear suscripciones semanales o mensuales por un monto fijo. Cada cobro se realiza automáticamente con la tarjeta guardada como predeterminada.',
          '4.4 Comisión de plataforma: Pushka cobra una comisión sobre cada donación procesada. La comisión por defecto es del 3%, pero puede variar por Organización. Esta comisión cubre los costos de infraestructura, procesamiento, soporte y desarrollo.',
        ],
      ),
      LegalSection(
        title: '5. Donaciones recurrentes — cancelación',
        paragraphs: [
          'Podés cancelar cualquier suscripción recurrente en cualquier momento desde la sección "Mis donaciones recurrentes". La cancelación detiene cobros futuros pero no genera reembolsos automáticos por cobros ya realizados.',
          'Si tu medio de pago falla en un cobro recurrente, te notificaremos y mantendremos la suscripción activa pero pausada hasta que actualices la información de pago. Tras múltiples intentos fallidos consecutivos, la suscripción puede cancelarse automáticamente.',
        ],
      ),
      LegalSection(
        title: '6. Vaciado automático',
        paragraphs: [
          'Al activar el "Vaciado automático", autorizás a Pushka a cobrar tu tarjeta guardada predeterminada según la frecuencia y condiciones que configurés (semanal, mensual, en Erev Rosh Jodesh, etc.) por el monto que tengas acumulado en tu pushka virtual al momento del cobro.',
          'Estos cobros son "off-session" — se ejecutan automáticamente sin requerir tu confirmación cada vez. Podés desactivar el vaciado automático en cualquier momento desde Configuración. Los cobros ya realizados no se reembolsan automáticamente al desactivarlo.',
          'Si la tarjeta guardada falla, la app te notificará y reintentará en 24 horas. Si los reintentos fallan, deberás reabilitar manualmente el método de pago.',
        ],
      ),
      LegalSection(
        title: '7. Reembolsos y disputas',
        paragraphs: [
          'Las donaciones son voluntarias y, en general, son finales. Sin embargo, si efectuaste un cargo por error, fraude o si la Organización no recibió los fondos correctamente, contactanos en $_contactEmail dentro de los 60 días.',
          'Pushka coordina con la Organización receptora y con Stripe para procesar reembolsos cuando corresponda. La decisión final sobre un reembolso depende de cada caso y queda a discreción razonable de Pushka y de la Organización.',
          'Tenés derecho a iniciar una disputa de cargo con tu banco o emisor de tarjeta ("chargeback"). En caso de chargeback, los fondos se retiran provisionalmente; te recomendamos contactarnos primero porque resolver el problema a través de nosotros suele ser más rápido y mantiene tu historial limpio.',
        ],
      ),
      LegalSection(
        title: '8. Usos prohibidos',
        paragraphs: [
          'Te comprometés a NO usar Pushka para: (a) actividades ilegales, fraude o lavado de activos; (b) impersonar a otra persona u organización; (c) usar tarjetas que no te pertenecen o sin autorización; (d) intentar comprometer la seguridad o integridad de la app, intentar ingeniería inversa, scraping o ataques de denegación de servicio; (e) eludir las medidas antifraude o los límites de uso; (f) usar la app de cualquier manera que viole leyes aplicables o derechos de terceros.',
          'El incumplimiento puede resultar en suspensión inmediata, cancelación de cuenta y reporte a las autoridades correspondientes.',
        ],
      ),
      LegalSection(
        title: '9. Conducta de las Organizaciones',
        paragraphs: [
          'Cada Organización inscrita en Pushka es responsable independiente del uso que haga de los fondos recibidos, de cumplir con las regulaciones fiscales y de cumplir con sus obligaciones frente a sus donantes.',
          'Pushka no audita ni garantiza el uso final de los fondos por parte de las Organizaciones. Si tenés dudas sobre cómo una Organización usa los fondos, te recomendamos contactar directamente a esa Organización y, si lo considerás necesario, a las autoridades competentes.',
        ],
      ),
      LegalSection(
        title: '10. Propiedad intelectual',
        paragraphs: [
          'La app Pushka, su código, diseño, logotipos y marca son propiedad de Pushka y están protegidos por leyes de propiedad intelectual. No podés copiar, modificar, distribuir, vender ni crear obras derivadas sin nuestro consentimiento previo por escrito.',
          'Los logotipos, nombres y marcas de las Organizaciones son propiedad de cada Organización respectivamente. Pushka muestra esta información con la autorización de cada Organización para identificar el destino de las donaciones.',
        ],
      ),
      LegalSection(
        title: '11. Limitación de responsabilidad',
        paragraphs: [
          'En la máxima medida permitida por la ley aplicable, Pushka se ofrece "tal cual" y "según disponibilidad", sin garantías de ningún tipo, expresas o implícitas.',
          'Pushka no será responsable por: (a) interrupciones del servicio causadas por proveedores externos (Firebase, Stripe, redes de tarjetas); (b) fluctuaciones de tipo de cambio entre la moneda de tu tarjeta y la moneda configurada por la Organización; (c) decisiones tomadas por las Organizaciones receptoras sobre el uso de los fondos; (d) pérdidas indirectas, incidentales o consecuentes.',
          'En ningún caso la responsabilidad agregada de Pushka excederá el monto de comisiones efectivamente cobradas a vos en los 12 meses anteriores al evento que motiva el reclamo.',
          'Algunas jurisdicciones no permiten ciertas exclusiones de garantías o limitaciones de responsabilidad. En ese caso, las limitaciones se aplicarán hasta donde la ley lo permita.',
        ],
      ),
      LegalSection(
        title: '12. Indemnización',
        paragraphs: [
          'Aceptás defender, indemnizar y mantener indemne a Pushka y sus afiliadas frente a cualquier reclamo, demanda, pérdida o gasto (incluidos honorarios legales razonables) que surjan de: (a) tu incumplimiento de estos Términos; (b) tu uso indebido de la app; (c) la violación de derechos de terceros causada por tu uso de Pushka.',
        ],
      ),
      LegalSection(
        title: '13. Suspensión y terminación',
        paragraphs: [
          'Podés terminar tu cuenta en cualquier momento desde Configuración → "Eliminar mi cuenta". Al hacerlo, cancelaremos tus suscripciones activas y procesaremos la eliminación de datos según la sección 8 de la Política de Privacidad.',
          'Podemos suspender o terminar tu cuenta inmediatamente, sin aviso previo, si: (a) violás estos Términos; (b) detectamos actividad fraudulenta; (c) lo exige una autoridad competente. En caso de terminación por parte nuestra, los cargos no reembolsables ya procesados no serán devueltos.',
        ],
      ),
      LegalSection(
        title: '14. Modificaciones de los Términos',
        paragraphs: [
          'Podemos actualizar estos Términos para reflejar cambios en el servicio, requisitos legales o nuestras prácticas. Si los cambios son materiales, te notificaremos a través de la app o por correo electrónico al menos 14 días antes de que entren en vigor.',
          'Tu uso continuado de Pushka después de la fecha de entrada en vigor constituirá tu aceptación de los Términos modificados. Si no aceptás los nuevos Términos, debés dejar de usar la app y, si lo deseás, cerrar tu cuenta.',
        ],
      ),
      LegalSection(
        title: '15. Ley aplicable y jurisdicción',
        paragraphs: [
          'Estos Términos se rigen por las leyes del país donde Pushka tiene su sede operativa principal. Cualquier disputa se resolverá ante los tribunales competentes de esa jurisdicción.',
          'Si sos consumidor en una jurisdicción que requiere protecciones específicas, conservás los derechos imperativos que te otorgue tu legislación local.',
        ],
      ),
      LegalSection(
        title: '16. Disposiciones generales',
        paragraphs: [
          'Si alguna disposición de estos Términos es declarada inválida o inejecutable, el resto de los Términos permanecerá en pleno vigor. Nuestra falta de ejercicio de un derecho no constituye renuncia. No podés ceder tus derechos bajo estos Términos sin nuestro consentimiento previo por escrito.',
        ],
      ),
      LegalSection(
        title: '17. Contacto',
        paragraphs: [
          'Para preguntas, reclamos o ejercicio de derechos:',
          'Pushka — Soporte',
          'Correo: $_contactEmail',
        ],
      ),
    ],
  ),
);

// ---------------------------------------------------------------------------
// ENGLISH
// ---------------------------------------------------------------------------

const _legalContentEn = LegalContent(
  privacy: LegalDoc(
    title: 'Privacy Policy',
    lastUpdated: _lastUpdatedLabelEn,
    intro:
        'This Policy describes how Pushka collects, uses, shares, and protects your information when you use the application. By using Pushka, you accept the practices described here. If you disagree, please do not use the app.',
    sections: [
      LegalSection(
        title: '1. Who we are',
        paragraphs: [
          'Pushka is a multi-organization ("multi-tenant") platform that connects donors with charitable organizations (each, an "Organization" or "Tenant"). Each Organization operates its own identity, branding, and fund destination within the app.',
          'Pushka is not the recipient organization for your donations. We act as a technological intermediary that facilitates payment between you (the donor) and the Organization you choose to support.',
        ],
      ),
      LegalSection(
        title: '2. Information we collect',
        paragraphs: [
          '2.1 Account data: name, email address, profile photo (optional), authentication credentials provided by Firebase Authentication, preferred language, and country/currency.',
          '2.2 Payment data: we DO NOT store your full credit/debit card information. Processing is performed entirely through Stripe, Inc. We only retain a Stripe customer identifier ("stripeCustomerId"), the last 4 digits of the card, and the brand (Visa, Mastercard, etc.) to display in your saved cards list.',
          '2.3 Donation history: amount, currency, date, recipient Organization, chosen designation (if applicable), optional donor message, and payment method. This information is required to comply with accounting and tax obligations both for us and for the recipient Organizations.',
          '2.4 Usage and device data: device type, operating system, language, unique app identifier (not the device), approximate region inferred from language or currency. We DO NOT collect your precise GPS location.',
          '2.5 Push notifications: Firebase Cloud Messaging tokens to send you reminders, payment confirmations, and holiday alerts.',
          '2.6 Support data: when you contact us by email, we retain the message content and your email address to respond.',
          '2.7 Information we DO NOT collect: contacts from your address book, photos from your gallery (except the one you upload as a profile picture), browsing history outside the app, health data, biometric data (biometric authentication to unlock the app is processed exclusively on your device and never reaches our servers).',
        ],
      ),
      LegalSection(
        title: '3. How we use your information',
        paragraphs: [
          '3.1 Donation processing: to create charges in Stripe, transfer funds to the recipient Organization through Stripe Connect, generate receipts, and maintain history.',
          '3.2 App operation: to operate your account, maintain your accumulated balance in your virtual pushka, manage recurring subscriptions, schedule automatic emptying, and display your history.',
          '3.3 Notifications: to send you holiday reminders, payment confirmations, failed charge alerts, and other operational communications related to your account.',
          '3.4 Security and fraud prevention: to detect and prevent suspicious activity, protect against unauthorized access, and comply with Stripe anti-fraud requirements.',
          '3.5 Improvements and analytics: to understand how the app is used, identify errors, optimize the experience. We use Firebase Analytics and Crashlytics, which may collect aggregated usage data. You can disable optional collection from your device settings.',
          '3.6 Legal compliance: to comply with applicable tax, accounting, anti-fraud, and anti-money-laundering obligations.',
        ],
      ),
      LegalSection(
        title: '4. Stripe and payment processing',
        paragraphs: [
          'Pushka uses Stripe, Inc. (headquartered in San Francisco, USA) to process all payments. When you enter your card details, they are transmitted directly to Stripe through their PCI DSS Level 1 certified SDK, without passing through our servers.',
          'Stripe is an independent controller of the payment data it collects. Its use of your information is governed by Stripe\'s Privacy Policy, available at https://stripe.com/privacy.',
          'If you choose to save a card for future charges, Stripe stores the full data securely and returns to us only a token (identifier) that we use to initiate new charges with your prior authorization.',
        ],
      ),
      LegalSection(
        title: '5. Multi-tenant model — what is shared with the Organization',
        paragraphs: [
          'When you donate to an Organization through Pushka, that Organization receives access to information needed to manage your donation: your name or alias, email address, donation amount, date, chosen designation (if the Organization configured options), and optional message you wrote.',
          'The Organization does NOT receive full card data, your password, your donation history to other organizations, or sensitive data outside the context of donations you specifically made to it.',
          'Each Organization is responsible as an independent controller for the personal data it receives through Pushka. We recommend reviewing the privacy policy of the Organization you are donating to.',
          'If you choose to donate to multiple Organizations from the same account, we keep histories and recurring donations separated by Organization.',
        ],
      ),
      LegalSection(
        title: '6. Third-party services',
        paragraphs: [
          'To operate Pushka we use the following providers as data sub-processors:',
          '• Google Firebase (Authentication, Firestore, Cloud Functions, Cloud Messaging, Analytics, Crashlytics, App Check) — Google Ireland Limited / Google LLC.',
          '• Stripe, Inc. — payment processing, Stripe Connect.',
          '• SendGrid (when applicable) — transactional email delivery.',
          'These providers process data on our behalf according to their own privacy policies and data protection agreements.',
        ],
      ),
      LegalSection(
        title: '7. Sharing information',
        paragraphs: [
          'We do not sell, rent, or trade your personal information with third parties for commercial purposes.',
          'We share information when: (a) strictly necessary for service operation (e.g., sending payment data to Stripe); (b) required by a competent authority or valid court order; (c) necessary to protect rights, property, or safety of Pushka, its users, or third parties; (d) in case of merger, acquisition, or asset sale, in which case we will notify you of the transfer and any applicable policy change.',
        ],
      ),
      LegalSection(
        title: '8. Retention and deletion',
        paragraphs: [
          'We retain your information while your account is active. Transaction data is kept for at least the minimum period required by applicable accounting, tax, and anti-money-laundering laws (typically 5 to 10 years, depending on jurisdiction), even after you close your account.',
          'You can delete your account at any time from Settings → "Delete my account". When you do: we will cancel your active recurring subscriptions, delete your customer in Stripe (which unlinks all saved cards), and erase your identifiable personal data. Transaction history is anonymized but retained for the legal reasons mentioned above.',
          'You can also export your data at any time from Settings → "Export my data".',
        ],
      ),
      LegalSection(
        title: '9. Your rights',
        paragraphs: [
          'Depending on your jurisdiction, you may have the following rights over your personal data: access, rectification, deletion, opposition to processing, portability, processing limitation, and consent withdrawal.',
          'European Union / European Economic Area residents (GDPR): you have the right to file complaints with your local data protection authority.',
          'California residents (CCPA/CPRA): you have the right to know what information we collect, delete it, correct it, and not be discriminated against for exercising these rights.',
          'Brazil (LGPD), Argentina (Law 25.326), and other Latin American jurisdictions residents: you have analogous rights according to your local legislation.',
          'To exercise any right, contact us at $_contactEmail. We will respond within the timeframe required by applicable law (typically 30 days).',
        ],
      ),
      LegalSection(
        title: '10. Security',
        paragraphs: [
          'We apply reasonable technical and organizational measures to protect your information: encryption in transit (TLS 1.2+), encryption at rest (Firebase and Stripe), Firebase App Check to prevent API abuse, mandatory authentication, logical separation between Organizations, and audit logs.',
          'No system is 100% secure. In case of a security incident affecting your data, we will notify you without undue delay as required by applicable law.',
        ],
      ),
      LegalSection(
        title: '11. Minors',
        paragraphs: [
          'Pushka is NOT directed to children under 13 (or 16 in EEA jurisdictions). We do not knowingly collect personal data from minors. If we discover we have collected data from a minor without required parental consent, we will delete that information immediately.',
          'If you are a parent or guardian and believe your child has provided us with personal information, contact us at $_contactEmail.',
        ],
      ),
      LegalSection(
        title: '12. International transfers',
        paragraphs: [
          'Pushka operates with servers located primarily in the United States (Firebase, Stripe). By using the app, you understand that your data may be transferred and processed outside your country of residence, in jurisdictions that may have different data protection laws than yours.',
          'We implement standard contractual clauses and other safeguards required by applicable data protection laws to ensure an adequate level of protection.',
        ],
      ),
      LegalSection(
        title: '13. Changes to this policy',
        paragraphs: [
          'We may update this policy to reflect changes in our practices, legal requirements, or service features. When we do, we will update the "Last updated" date above. If changes are material, we will notify you through the app or by email before they take effect.',
          'Your continued use of Pushka after the changes take effect will constitute your acceptance of the revised policy.',
        ],
      ),
      LegalSection(
        title: '14. Contact',
        paragraphs: [
          'If you have questions, comments, or complaints about this Privacy Policy or how we handle your data, write to us at:',
          'Pushka — Support and Privacy',
          'Email: $_contactEmail',
        ],
      ),
    ],
  ),
  terms: LegalDoc(
    title: 'Terms of Service',
    lastUpdated: _lastUpdatedLabelEn,
    intro:
        'These Terms govern your use of Pushka. By creating an account or using the application, you accept these Terms. If you disagree, please do not use the app.',
    sections: [
      LegalSection(
        title: '1. Acceptance of Terms',
        paragraphs: [
          'By registering, installing, or using Pushka, you confirm that you have read, understood, and accepted these Terms of Service and the Privacy Policy. If you use Pushka on behalf of an organization, you represent that you have authority to bind it to these Terms.',
        ],
      ),
      LegalSection(
        title: '2. Service description',
        paragraphs: [
          'Pushka is a multi-organization platform that allows donors to make one-time or recurring donations to charitable Organizations registered on the platform. Each Organization configures its identity, fund designations, and collection details through Stripe Connect.',
          'Pushka acts as a technology facilitator. We are NOT the recipient entity of donated funds — funds travel directly from your payment method to the Stripe Connect account of the chosen Organization, less a platform fee.',
        ],
      ),
      LegalSection(
        title: '3. User account',
        paragraphs: [
          'To use Pushka you need to create an account with a valid email address. You are responsible for providing truthful information and keeping it up to date.',
          'Minimum age: you must be at least 13 years old (16 in EEA jurisdictions). If you are under the legal age of majority in your jurisdiction, you need consent from a parent or guardian to use the app and make donations.',
          'You are responsible for maintaining the security of your credentials. Notify us immediately if you suspect unauthorized access to your account.',
        ],
      ),
      LegalSection(
        title: '4. How donations work',
        paragraphs: [
          '4.1 Single donation ("Donate now"): you make a one-time charge to your payment method. Once confirmed, funds are sent to the chosen Organization minus the platform fee.',
          '4.2 Virtual pushka ("Empty Pushka"): you can accumulate a virtual balance by manually entering it in the app and, when you decide, charge the total accumulated in a single transaction. The app also offers an "Auto Empty" option that periodically charges the accumulated balance.',
          '4.3 Recurring donation: you can create weekly or monthly subscriptions for a fixed amount. Each charge is automatically processed with the card saved as default.',
          '4.4 Platform fee: Pushka charges a fee on each processed donation. The default fee is 3%, but may vary by Organization. This fee covers infrastructure, processing, support, and development costs.',
        ],
      ),
      LegalSection(
        title: '5. Recurring donations — cancellation',
        paragraphs: [
          'You can cancel any recurring subscription at any time from the "My recurring donations" section. Cancellation stops future charges but does not generate automatic refunds for charges already made.',
          'If your payment method fails on a recurring charge, we will notify you and keep the subscription active but paused until you update payment information. After multiple consecutive failed attempts, the subscription may be automatically canceled.',
        ],
      ),
      LegalSection(
        title: '6. Auto-empty',
        paragraphs: [
          'By activating "Auto-empty", you authorize Pushka to charge your default saved card according to the frequency and conditions you configure (weekly, monthly, on Erev Rosh Chodesh, etc.) for the amount you have accumulated in your virtual pushka at the time of charging.',
          'These charges are "off-session" — they execute automatically without requiring your confirmation each time. You can deactivate auto-empty at any time from Settings. Charges already made are not automatically refunded upon deactivation.',
          'If the saved card fails, the app will notify you and retry in 24 hours. If retries fail, you will need to manually re-enable the payment method.',
        ],
      ),
      LegalSection(
        title: '7. Refunds and disputes',
        paragraphs: [
          'Donations are voluntary and, in general, are final. However, if you made a charge by error, fraud, or if the Organization did not properly receive the funds, contact us at $_contactEmail within 60 days.',
          'Pushka coordinates with the recipient Organization and Stripe to process refunds when applicable. The final decision on a refund depends on each case and remains at the reasonable discretion of Pushka and the Organization.',
          'You have the right to initiate a chargeback dispute with your bank or card issuer. In case of chargeback, funds are provisionally withdrawn; we recommend contacting us first as resolving the issue through us is usually faster and keeps your record clean.',
        ],
      ),
      LegalSection(
        title: '8. Prohibited uses',
        paragraphs: [
          'You agree NOT to use Pushka for: (a) illegal activities, fraud, or money laundering; (b) impersonating another person or organization; (c) using cards that do not belong to you or without authorization; (d) attempting to compromise the security or integrity of the app, attempting reverse engineering, scraping, or denial of service attacks; (e) circumventing anti-fraud measures or usage limits; (f) using the app in any way that violates applicable laws or third-party rights.',
          'Failure to comply may result in immediate suspension, account cancellation, and reporting to relevant authorities.',
        ],
      ),
      LegalSection(
        title: '9. Conduct of Organizations',
        paragraphs: [
          'Each Organization registered on Pushka is independently responsible for the use it makes of received funds, complying with tax regulations, and meeting its obligations to its donors.',
          'Pushka does not audit or guarantee the final use of funds by Organizations. If you have doubts about how an Organization uses funds, we recommend contacting that Organization directly and, if you consider it necessary, the relevant authorities.',
        ],
      ),
      LegalSection(
        title: '10. Intellectual property',
        paragraphs: [
          'The Pushka app, its code, design, logos, and brand are property of Pushka and are protected by intellectual property laws. You may not copy, modify, distribute, sell, or create derivative works without our prior written consent.',
          'Logos, names, and brands of Organizations are property of each respective Organization. Pushka displays this information with each Organization\'s authorization to identify donation destinations.',
        ],
      ),
      LegalSection(
        title: '11. Limitation of liability',
        paragraphs: [
          'To the maximum extent permitted by applicable law, Pushka is offered "as is" and "as available", without warranties of any kind, express or implied.',
          'Pushka will not be liable for: (a) service interruptions caused by external providers (Firebase, Stripe, card networks); (b) exchange rate fluctuations between your card currency and the Organization\'s configured currency; (c) decisions made by recipient Organizations on the use of funds; (d) indirect, incidental, or consequential losses.',
          'In no event shall Pushka\'s aggregate liability exceed the amount of fees actually charged to you in the 12 months preceding the event giving rise to the claim.',
          'Some jurisdictions do not allow certain warranty exclusions or liability limitations. In such case, limitations will apply to the extent permitted by law.',
        ],
      ),
      LegalSection(
        title: '12. Indemnification',
        paragraphs: [
          'You agree to defend, indemnify, and hold harmless Pushka and its affiliates from any claim, demand, loss, or expense (including reasonable legal fees) arising from: (a) your breach of these Terms; (b) your misuse of the app; (c) violation of third-party rights caused by your use of Pushka.',
        ],
      ),
      LegalSection(
        title: '13. Suspension and termination',
        paragraphs: [
          'You can terminate your account at any time from Settings → "Delete my account". When you do, we will cancel your active subscriptions and process data deletion according to section 8 of the Privacy Policy.',
          'We may suspend or terminate your account immediately, without prior notice, if: (a) you violate these Terms; (b) we detect fraudulent activity; (c) required by a competent authority. In case of termination by us, non-refundable charges already processed will not be returned.',
        ],
      ),
      LegalSection(
        title: '14. Modifications to Terms',
        paragraphs: [
          'We may update these Terms to reflect changes in the service, legal requirements, or our practices. If changes are material, we will notify you through the app or by email at least 14 days before they take effect.',
          'Your continued use of Pushka after the effective date will constitute your acceptance of the modified Terms. If you do not accept the new Terms, you must stop using the app and, if you wish, close your account.',
        ],
      ),
      LegalSection(
        title: '15. Governing law and jurisdiction',
        paragraphs: [
          'These Terms are governed by the laws of the country where Pushka has its principal operating headquarters. Any dispute will be resolved before the competent courts of that jurisdiction.',
          'If you are a consumer in a jurisdiction requiring specific protections, you retain mandatory rights granted by your local legislation.',
        ],
      ),
      LegalSection(
        title: '16. General provisions',
        paragraphs: [
          'If any provision of these Terms is declared invalid or unenforceable, the remainder of the Terms will remain in full force. Our failure to exercise a right does not constitute waiver. You may not assign your rights under these Terms without our prior written consent.',
        ],
      ),
      LegalSection(
        title: '17. Contact',
        paragraphs: [
          'For questions, complaints, or exercising rights:',
          'Pushka — Support',
          'Email: $_contactEmail',
        ],
      ),
    ],
  ),
);

// ---------------------------------------------------------------------------
// FRANÇAIS
// ---------------------------------------------------------------------------

const _legalContentFr = LegalContent(
  privacy: LegalDoc(
    title: 'Politique de Confidentialité',
    lastUpdated: _lastUpdatedLabelFr,
    intro:
        'Cette Politique décrit comment Pushka collecte, utilise, partage et protège vos informations lorsque vous utilisez l\'application. En utilisant Pushka, vous acceptez les pratiques décrites ici. Si vous n\'êtes pas d\'accord, nous vous demandons de ne pas utiliser l\'application.',
    sections: [
      LegalSection(
        title: '1. Qui sommes-nous',
        paragraphs: [
          'Pushka est une plateforme multi-organisations qui connecte les donateurs avec des organisations caritatives (chacune, une "Organisation"). Chaque Organisation gère sa propre identité, image de marque et destination des fonds dans l\'application.',
          'Pushka n\'est pas l\'organisation bénéficiaire de vos dons. Nous agissons en tant qu\'intermédiaire technologique facilitant le paiement entre vous (donateur) et l\'Organisation que vous choisissez de soutenir.',
        ],
      ),
      LegalSection(
        title: '2. Informations que nous collectons',
        paragraphs: [
          'Données de compte : nom, adresse email, photo de profil (optionnelle), identifiants d\'authentification, langue préférée, pays/devise.',
          'Données de paiement : nous NE stockons PAS les données complètes de votre carte. Le traitement est effectué intégralement via Stripe, Inc. Nous ne conservons qu\'un identifiant client Stripe, les 4 derniers chiffres de la carte et la marque.',
          'Historique de dons : montant, devise, date, Organisation bénéficiaire, désignation choisie, message optionnel et méthode de paiement. Cette information est nécessaire pour respecter les obligations comptables et fiscales.',
          'Données d\'utilisation et d\'appareil : type d\'appareil, système d\'exploitation, langue, identifiant unique de l\'application, région approximative. Nous NE collectons PAS votre localisation GPS précise.',
          'Notifications push : tokens Firebase Cloud Messaging.',
          'Informations que nous NE collectons PAS : contacts, photos de votre galerie (sauf celle que vous téléchargez comme photo de profil), historique de navigation hors application, données de santé, données biométriques (l\'authentification biométrique reste exclusivement sur votre appareil).',
        ],
      ),
      LegalSection(
        title: '3. Comment nous utilisons vos informations',
        paragraphs: [
          'Pour traiter vos dons via Stripe, transférer les fonds à l\'Organisation bénéficiaire via Stripe Connect, gérer votre compte, vos abonnements récurrents et la fonction de vidage automatique, vous envoyer des notifications opérationnelles, prévenir la fraude, améliorer l\'application via des analyses agrégées, et respecter nos obligations légales et fiscales.',
        ],
      ),
      LegalSection(
        title: '4. Stripe et le traitement des paiements',
        paragraphs: [
          'Pushka utilise Stripe, Inc. pour traiter tous les paiements. Vos données de carte sont transmises directement à Stripe via leur SDK certifié PCI DSS Niveau 1, sans passer par nos serveurs.',
          'Stripe est un contrôleur indépendant des données de paiement. Sa politique : https://stripe.com/privacy.',
        ],
      ),
      LegalSection(
        title: '5. Modèle multi-organisations',
        paragraphs: [
          'Lorsque vous donnez à une Organisation, celle-ci reçoit les informations nécessaires pour gérer votre don : votre nom, email, montant, date, désignation, message optionnel.',
          'L\'Organisation NE reçoit PAS les données complètes de carte ni votre historique avec d\'autres organisations.',
          'Chaque Organisation est responsable indépendamment des données qu\'elle reçoit.',
        ],
      ),
      LegalSection(
        title: '6. Services tiers',
        paragraphs: [
          'Nous utilisons : Google Firebase (Authentication, Firestore, Cloud Functions, Cloud Messaging, Analytics, Crashlytics, App Check), Stripe Inc., SendGrid (le cas échéant).',
        ],
      ),
      LegalSection(
        title: '7. Partage des informations',
        paragraphs: [
          'Nous ne vendons ni ne louons vos informations personnelles. Nous les partageons uniquement quand nécessaire pour le service, requis par la loi, ou en cas de fusion/acquisition (avec notification préalable).',
        ],
      ),
      LegalSection(
        title: '8. Conservation et suppression',
        paragraphs: [
          'Nous conservons vos données tant que votre compte est actif. Les données de transactions sont conservées pendant la durée minimale requise par la loi (généralement 5 à 10 ans).',
          'Vous pouvez supprimer votre compte depuis Paramètres → "Supprimer mon compte" : annulation des abonnements, suppression du client Stripe, anonymisation de l\'historique.',
          'Vous pouvez exporter vos données depuis Paramètres → "Exporter mes données".',
        ],
      ),
      LegalSection(
        title: '9. Vos droits',
        paragraphs: [
          'Selon votre juridiction (RGPD pour l\'UE, CCPA pour la Californie, LGPD pour le Brésil, etc.) : accès, rectification, suppression, portabilité, opposition, limitation, retrait du consentement.',
          'Pour exercer un droit : $_contactEmail. Réponse dans les délais légaux (généralement 30 jours).',
        ],
      ),
      LegalSection(
        title: '10. Sécurité',
        paragraphs: [
          'Chiffrement en transit (TLS 1.2+) et au repos, Firebase App Check, authentification obligatoire, séparation logique entre Organisations, journaux d\'audit.',
          'Aucun système n\'est sûr à 100%. En cas d\'incident, nous notifierons selon les exigences légales.',
        ],
      ),
      LegalSection(
        title: '11. Mineurs',
        paragraphs: [
          'Pushka n\'est PAS destiné aux moins de 13 ans (16 dans l\'EEE). Si nous découvrons des données collectées sans consentement parental, nous les supprimerons. Parents ou tuteurs : $_contactEmail.',
        ],
      ),
      LegalSection(
        title: '12. Transferts internationaux',
        paragraphs: [
          'Pushka opère avec des serveurs aux États-Unis (Firebase, Stripe). Vos données peuvent être transférées hors de votre pays. Nous mettons en œuvre des clauses contractuelles types comme garanties.',
        ],
      ),
      LegalSection(
        title: '13. Modifications',
        paragraphs: [
          'Nous pouvons mettre à jour cette Politique. Les changements matériels seront notifiés via l\'application ou par email avant leur entrée en vigueur.',
        ],
      ),
      LegalSection(
        title: '14. Contact',
        paragraphs: [
          'Pour toute question : Pushka — Support et Confidentialité',
          'Email : $_contactEmail',
        ],
      ),
    ],
  ),
  terms: LegalDoc(
    title: 'Conditions d\'Utilisation',
    lastUpdated: _lastUpdatedLabelFr,
    intro:
        'Ces Conditions régissent votre utilisation de Pushka. En créant un compte ou en utilisant l\'application, vous acceptez ces Conditions.',
    sections: [
      LegalSection(
        title: '1. Acceptation des Conditions',
        paragraphs: [
          'En vous inscrivant, installant ou utilisant Pushka, vous confirmez avoir lu, compris et accepté ces Conditions et la Politique de Confidentialité.',
        ],
      ),
      LegalSection(
        title: '2. Description du service',
        paragraphs: [
          'Pushka est une plateforme multi-organisations permettant des dons uniques ou récurrents à des Organisations caritatives. Chaque Organisation configure son identité et reçoit les fonds via Stripe Connect.',
          'Pushka agit comme facilitateur technologique, NON comme bénéficiaire des dons.',
        ],
      ),
      LegalSection(
        title: '3. Compte utilisateur',
        paragraphs: [
          'Email valide requis. Âge minimum : 13 ans (16 dans l\'EEE). Vous êtes responsable de la sécurité de vos identifiants.',
        ],
      ),
      LegalSection(
        title: '4. Fonctionnement des dons',
        paragraphs: [
          'Don unique : charge unique. Pushka virtuelle : balance accumulée. Don récurrent : abonnement hebdomadaire ou mensuel. Vidage automatique : charge périodique de la balance.',
          'Frais de plateforme : 3% par défaut, variable par Organisation.',
        ],
      ),
      LegalSection(
        title: '5. Annulation des abonnements',
        paragraphs: [
          'Annulation à tout moment depuis "Mes dons récurrents". Pas de remboursement automatique des charges passées.',
        ],
      ),
      LegalSection(
        title: '6. Vidage automatique',
        paragraphs: [
          'Autorisation pour des charges off-session selon la fréquence configurée. Désactivable à tout moment.',
        ],
      ),
      LegalSection(
        title: '7. Remboursements',
        paragraphs: [
          'Les dons sont en général définitifs. Pour erreurs ou fraude : $_contactEmail dans les 60 jours.',
        ],
      ),
      LegalSection(
        title: '8. Usages interdits',
        paragraphs: [
          'Activités illégales, fraude, blanchiment, usurpation d\'identité, utilisation de cartes non autorisées, atteinte à la sécurité de l\'application.',
        ],
      ),
      LegalSection(
        title: '9. Responsabilité des Organisations',
        paragraphs: [
          'Chaque Organisation est responsable indépendamment de l\'usage des fonds reçus.',
        ],
      ),
      LegalSection(
        title: '10. Propriété intellectuelle',
        paragraphs: [
          'Pushka, son code, design et marque sont protégés. Les marques des Organisations leur appartiennent.',
        ],
      ),
      LegalSection(
        title: '11. Limitation de responsabilité',
        paragraphs: [
          'Service "tel quel". Pas de responsabilité pour interruptions de prestataires tiers, fluctuations de change, décisions des Organisations, dommages indirects.',
          'Plafond : montants effectivement payés par vous au cours des 12 derniers mois.',
        ],
      ),
      LegalSection(
        title: '12. Suspension et résiliation',
        paragraphs: [
          'Vous pouvez résilier à tout moment. Nous pouvons suspendre en cas de violation des Conditions ou d\'activité frauduleuse.',
        ],
      ),
      LegalSection(
        title: '13. Modifications',
        paragraphs: [
          'Notification au moins 14 jours avant l\'entrée en vigueur de changements matériels.',
        ],
      ),
      LegalSection(
        title: '14. Loi applicable',
        paragraphs: [
          'Lois du pays du siège opérationnel principal de Pushka. Droits impératifs des consommateurs préservés.',
        ],
      ),
      LegalSection(
        title: '15. Contact',
        paragraphs: [
          'Pushka — Support',
          'Email : $_contactEmail',
        ],
      ),
    ],
  ),
);

// ---------------------------------------------------------------------------
// HEBREW
// ---------------------------------------------------------------------------

const _legalContentHe = LegalContent(
  privacy: LegalDoc(
    title: 'מדיניות פרטיות',
    lastUpdated: _lastUpdatedLabelHe,
    intro:
        'מדיניות זו מתארת כיצד Pushka אוספת, משתמשת, משתפת ומגנה על המידע שלך בעת השימוש באפליקציה. שימוש ב-Pushka מהווה הסכמה למדיניות זו. אם אינך מסכים, אנא הימנע משימוש באפליקציה.',
    sections: [
      LegalSection(
        title: '1. מי אנחנו',
        paragraphs: [
          'Pushka היא פלטפורמה רב-ארגונית המחברת תורמים עם ארגוני צדקה (כל אחד, "ארגון"). כל ארגון מנהל את הזהות, המיתוג ויעד הכספים שלו באפליקציה.',
          'Pushka אינה הארגון הנמען של תרומותיך. אנו פועלים כמתווך טכנולוגי המאפשר תשלום בינך (התורם) לבין הארגון שבחרת לתמוך בו.',
        ],
      ),
      LegalSection(
        title: '2. מידע שאנו אוספים',
        paragraphs: [
          'נתוני חשבון: שם, כתובת אימייל, תמונת פרופיל (אופציונלי), פרטי הזדהות מ-Firebase, שפה, מטבע.',
          'נתוני תשלום: איננו שומרים את פרטי הכרטיס המלאים. העיבוד נעשה דרך Stripe, Inc. אנו שומרים רק מזהה לקוח Stripe, 4 ספרות אחרונות וסוג כרטיס.',
          'היסטוריית תרומות: סכום, מטבע, תאריך, ארגון, ייעוד, מסר אופציונלי, אמצעי תשלום.',
          'נתוני שימוש ומכשיר: סוג מכשיר, מערכת הפעלה, שפה, אזור משוער. איננו אוספים מיקום GPS מדויק.',
          'אסימוני התראות פוש (Firebase Cloud Messaging).',
          'מה שאיננו אוספים: אנשי קשר, תמונות מהגלריה (חוץ מתמונת פרופיל), היסטוריית גלישה מחוץ לאפליקציה, נתוני בריאות, נתונים ביומטריים (אימות ביומטרי נשאר אך ורק במכשיר שלך).',
        ],
      ),
      LegalSection(
        title: '3. כיצד אנו משתמשים במידע',
        paragraphs: [
          'לעיבוד תרומות דרך Stripe, להעברת כספים לארגונים דרך Stripe Connect, לניהול חשבונך, מינויים וריקון אוטומטי, להתראות תפעוליות, למניעת הונאה, לאנליטיקה מצרפית, ולעמידה בחובות חוקיים ומיסויים.',
        ],
      ),
      LegalSection(
        title: '4. Stripe ועיבוד תשלומים',
        paragraphs: [
          'Pushka משתמשת ב-Stripe, Inc. לכל התשלומים. נתוני הכרטיס משודרים ישירות ל-Stripe דרך SDK בעל אישור PCI DSS רמה 1.',
          'Stripe מהווה מבקר עצמאי של נתוני התשלום. מדיניותם: https://stripe.com/privacy.',
        ],
      ),
      LegalSection(
        title: '5. מודל רב-ארגוני',
        paragraphs: [
          'הארגון הנתרם מקבל: שם, אימייל, סכום, תאריך, ייעוד, מסר אופציונלי.',
          'הארגון אינו מקבל: נתוני כרטיס מלאים, סיסמה, היסטוריה מול ארגונים אחרים.',
        ],
      ),
      LegalSection(
        title: '6. שירותי צד שלישי',
        paragraphs: [
          'Google Firebase, Stripe Inc., SendGrid (במידת הצורך).',
        ],
      ),
      LegalSection(
        title: '7. שיתוף מידע',
        paragraphs: [
          'איננו מוכרים מידע אישי. שיתוף רק כאשר נדרש לפעולת השירות, על פי חוק, או במקרה של מיזוג/רכישה.',
        ],
      ),
      LegalSection(
        title: '8. שמירה ומחיקה',
        paragraphs: [
          'נתונים נשמרים כל עוד החשבון פעיל. נתוני עסקאות נשמרים לתקופת המינימום שמחייב חוק (בדרך כלל 5–10 שנים).',
          'מחיקת חשבון: הגדרות → "מחק חשבון". ייצוא נתונים: הגדרות → "ייצא את הנתונים שלי".',
        ],
      ),
      LegalSection(
        title: '9. זכויותיך',
        paragraphs: [
          'גישה, תיקון, מחיקה, ניידות, התנגדות, הגבלה, חזרה מהסכמה (בהתאם לתחום שיפוטך: GDPR, CCPA, LGPD, חוק הגנת הפרטיות הישראלי).',
          'לממש זכות: $_contactEmail. תגובה בתוך 30 יום בדרך כלל.',
        ],
      ),
      LegalSection(
        title: '10. אבטחה',
        paragraphs: [
          'הצפנה בתעבורה ובמנוחה, Firebase App Check, אימות חובה, הפרדה לוגית בין ארגונים. שום מערכת אינה בטוחה ב-100%.',
        ],
      ),
      LegalSection(
        title: '11. קטינים',
        paragraphs: [
          'Pushka אינה מיועדת לבני פחות מ-13 שנה. הורים: $_contactEmail.',
        ],
      ),
      LegalSection(
        title: '12. העברות בינלאומיות',
        paragraphs: [
          'שרתים בארה"ב (Firebase, Stripe). אנו מיישמים סעיפים חוזיים סטנדרטיים.',
        ],
      ),
      LegalSection(
        title: '13. שינויים',
        paragraphs: [
          'נעדכן מדיניות זו. שינויים מהותיים יודיעו דרך האפליקציה או באימייל.',
        ],
      ),
      LegalSection(
        title: '14. צור קשר',
        paragraphs: [
          'Pushka — תמיכה ופרטיות',
          'אימייל: $_contactEmail',
        ],
      ),
    ],
  ),
  terms: LegalDoc(
    title: 'תנאי שימוש',
    lastUpdated: _lastUpdatedLabelHe,
    intro:
        'תנאים אלו מסדירים את שימושך ב-Pushka. ביצירת חשבון או שימוש באפליקציה, אתה מסכים לתנאים אלו.',
    sections: [
      LegalSection(
        title: '1. הסכמה',
        paragraphs: [
          'בהרשמה, התקנה או שימוש ב-Pushka, אתה מאשר שקראת והסכמת לתנאים ולמדיניות הפרטיות.',
        ],
      ),
      LegalSection(
        title: '2. תיאור השירות',
        paragraphs: [
          'Pushka היא פלטפורמה רב-ארגונית לתרומות חד-פעמיות וחוזרות. הכספים נעים ישירות אל חשבון Stripe Connect של הארגון, פחות עמלת פלטפורמה.',
        ],
      ),
      LegalSection(
        title: '3. חשבון משתמש',
        paragraphs: [
          'אימייל תקף נדרש. גיל מינימום: 13. אתה אחראי על אבטחת פרטי ההזדהות.',
        ],
      ),
      LegalSection(
        title: '4. אופן פעולת התרומות',
        paragraphs: [
          'תרומה חד-פעמית, פושקה וירטואלית, תרומה חוזרת (שבועית/חודשית), ריקון אוטומטי. עמלת פלטפורמה: 3% כברירת מחדל, משתנה לפי ארגון.',
        ],
      ),
      LegalSection(
        title: '5. ביטול מינויים',
        paragraphs: [
          'ביטול בכל עת מ-"התרומות החוזרות שלי". ללא החזרים אוטומטיים על חיובים שכבר בוצעו.',
        ],
      ),
      LegalSection(
        title: '6. ריקון אוטומטי',
        paragraphs: [
          'הרשאה לחיובים off-session לפי תדירות מוגדרת. ניתן לבטל בכל עת.',
        ],
      ),
      LegalSection(
        title: '7. החזרים',
        paragraphs: [
          'התרומות סופיות בדרך כלל. לטעויות או הונאה: $_contactEmail בתוך 60 יום.',
        ],
      ),
      LegalSection(
        title: '8. שימושים אסורים',
        paragraphs: [
          'פעילות בלתי חוקית, הונאה, הלבנת הון, התחזות, שימוש בכרטיסים לא מורשים, פגיעה באבטחה.',
        ],
      ),
      LegalSection(
        title: '9. אחריות הארגונים',
        paragraphs: [
          'כל ארגון אחראי באופן עצמאי על השימוש בכספים.',
        ],
      ),
      LegalSection(
        title: '10. קניין רוחני',
        paragraphs: [
          'Pushka, הקוד, העיצוב והמותג מוגנים. סמלי ארגונים שייכים להם.',
        ],
      ),
      LegalSection(
        title: '11. הגבלת אחריות',
        paragraphs: [
          'שירות "כפי שהוא". איננו אחראים על הפסקות שירות של ספקי צד שלישי, תנודות שער, החלטות ארגונים.',
          'תקרה: סכום העמלות שגבית ב-12 חודשים האחרונים.',
        ],
      ),
      LegalSection(
        title: '12. סיום',
        paragraphs: [
          'ניתן לסיים בכל עת. אנו עשויים להשעות במקרה של הפרה או הונאה.',
        ],
      ),
      LegalSection(
        title: '13. שינויים',
        paragraphs: [
          'הודעה לפחות 14 יום לפני כניסת שינויים מהותיים לתוקף.',
        ],
      ),
      LegalSection(
        title: '14. דין חל',
        paragraphs: [
          'דיני המדינה של מטה Pushka. זכויות הצרכן הקוגנטיות נשמרות.',
        ],
      ),
      LegalSection(
        title: '15. צור קשר',
        paragraphs: [
          'Pushka — תמיכה',
          'אימייל: $_contactEmail',
        ],
      ),
    ],
  ),
);
