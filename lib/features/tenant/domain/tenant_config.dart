import 'dart:ui';

class TenantConfig {
  const TenantConfig({
    required this.tenantId,
    required this.name,
    required this.appName,
    required this.showPoweredBy,
    this.welcomeText,
    this.primaryColor,
    this.secondaryColor,
    this.logoUrl,
    this.defaultLanguage,
    this.defaultCurrency,
    this.defaultCountry,
    this.contactEmail,
    this.privacyPolicyUrl,
    this.termsUrl,
    this.donationReasons = const [],
  });

  final String tenantId;
  final String name;
  final String appName;
  final bool showPoweredBy;
  final String? welcomeText;
  final Color? primaryColor;
  final Color? secondaryColor;
  final String? logoUrl;
  final String? defaultLanguage;
  final String? defaultCurrency;
  final String? defaultCountry;
  final String? contactEmail;
  final String? privacyPolicyUrl;
  final String? termsUrl;
  /// Optional per-tenant list of donation reasons ("designaciones") shown
  /// to the donor at payment time. Empty list = picker is hidden.
  final List<String> donationReasons;

  factory TenantConfig.fromMap(String tenantId, Map<String, dynamic> data) {
    return TenantConfig(
      tenantId: tenantId,
      name: (data['name'] as String?) ?? '',
      appName: (data['appName'] as String?) ?? 'Pushka',
      showPoweredBy: (data['showPoweredBy'] as bool?) ?? true,
      welcomeText: _nonEmpty(data['welcomeText'] as String?),
      primaryColor: _parseColor(data['primaryColor'] as String?),
      secondaryColor: _parseColor(data['secondaryColor'] as String?),
      logoUrl: _nonEmpty(data['logoUrl'] as String?),
      defaultLanguage: _nonEmpty(data['defaultLanguage'] as String?),
      defaultCurrency: _nonEmpty(data['defaultCurrency'] as String?),
      defaultCountry: _nonEmpty(data['defaultCountry'] as String?),
      contactEmail: _nonEmpty(data['contactEmail'] as String?),
      privacyPolicyUrl: _nonEmpty(data['privacyPolicyUrl'] as String?),
      termsUrl: _nonEmpty(data['termsUrl'] as String?),
      donationReasons: _stringList(data['donationReasons']),
    );
  }

  /// Round-trippable with [TenantConfig.fromMap]. Used by HiveCache to persist
  /// the last-known tenant config so the app can render branding immediately
  /// on cold-start before the network call completes.
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'appName': appName,
      'showPoweredBy': showPoweredBy,
      if (welcomeText != null) 'welcomeText': welcomeText,
      if (primaryColor != null) 'primaryColor': _formatColor(primaryColor!),
      if (secondaryColor != null) 'secondaryColor': _formatColor(secondaryColor!),
      if (logoUrl != null) 'logoUrl': logoUrl,
      if (defaultLanguage != null) 'defaultLanguage': defaultLanguage,
      if (defaultCurrency != null) 'defaultCurrency': defaultCurrency,
      if (defaultCountry != null) 'defaultCountry': defaultCountry,
      if (contactEmail != null) 'contactEmail': contactEmail,
      if (privacyPolicyUrl != null) 'privacyPolicyUrl': privacyPolicyUrl,
      if (termsUrl != null) 'termsUrl': termsUrl,
      if (donationReasons.isNotEmpty) 'donationReasons': donationReasons,
    };
  }

  static String? _nonEmpty(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  static Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final clean = hex.replaceFirst('#', '');
    if (clean.length != 6 && clean.length != 8) return null;
    try {
      final value = int.parse(
        clean.length == 6 ? 'FF$clean' : clean,
        radix: 16,
      );
      return Color(value);
    } catch (_) {
      return null;
    }
  }

  static String _formatColor(Color c) {
    // Convert ARGB 32-bit int to "#RRGGBB" — matches what the backend stores
    // (alpha channel is implied to be 0xFF and dropped on the wire).
    final r = ((c.r * 255.0).round() & 0xff).toRadixString(16).padLeft(2, '0');
    final g = ((c.g * 255.0).round() & 0xff).toRadixString(16).padLeft(2, '0');
    final b = ((c.b * 255.0).round() & 0xff).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }

  // Equality + hashCode let the 60s tenant-status poll's invalidate→re-fetch
  // chain skip MaterialApp/ThemeData rebuilds when the tenant config didn't
  // actually change. Without this every tick rebuilds the entire UI tree.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TenantConfig &&
          tenantId == other.tenantId &&
          name == other.name &&
          appName == other.appName &&
          showPoweredBy == other.showPoweredBy &&
          welcomeText == other.welcomeText &&
          primaryColor == other.primaryColor &&
          secondaryColor == other.secondaryColor &&
          logoUrl == other.logoUrl &&
          defaultLanguage == other.defaultLanguage &&
          defaultCurrency == other.defaultCurrency &&
          defaultCountry == other.defaultCountry &&
          contactEmail == other.contactEmail &&
          privacyPolicyUrl == other.privacyPolicyUrl &&
          termsUrl == other.termsUrl &&
          _listEquals(donationReasons, other.donationReasons);

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        tenantId, name, appName, showPoweredBy, welcomeText,
        primaryColor, secondaryColor, logoUrl,
        defaultLanguage, defaultCurrency, defaultCountry,
        contactEmail, privacyPolicyUrl, termsUrl,
        Object.hashAll(donationReasons),
      );
}
