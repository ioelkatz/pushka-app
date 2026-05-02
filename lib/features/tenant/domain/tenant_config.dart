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

  factory TenantConfig.fromMap(String tenantId, Map<String, dynamic> data) {
    return TenantConfig(
      tenantId: tenantId,
      name: (data['name'] as String?) ?? '',
      appName: (data['appName'] as String?) ?? 'Pushka',
      showPoweredBy: (data['showPoweredBy'] as bool?) ?? true,
      welcomeText: data['welcomeText'] as String?,
      primaryColor: _parseColor(data['primaryColor'] as String?),
      secondaryColor: _parseColor(data['secondaryColor'] as String?),
      logoUrl: data['logoUrl'] as String?,
      defaultLanguage: data['defaultLanguage'] as String?,
      defaultCurrency: data['defaultCurrency'] as String?,
      defaultCountry: data['defaultCountry'] as String?,
      contactEmail: data['contactEmail'] as String?,
      privacyPolicyUrl: data['privacyPolicyUrl'] as String?,
      termsUrl: data['termsUrl'] as String?,
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
    };
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
}
