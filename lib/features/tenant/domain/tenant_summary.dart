import 'dart:ui';

/// Lightweight tenant info for the discoverable list shown during onboarding.
/// Heavier branding/config is loaded only after the user picks one.
class TenantSummary {
  const TenantSummary({
    required this.tenantId,
    required this.name,
    required this.appName,
    required this.slug,
    this.city,
    this.neighborhood,
    this.country,
    this.logoUrl,
    this.primaryColor,
  });

  final String tenantId;
  final String name;
  final String appName;
  final String slug;
  final String? city;
  final String? neighborhood;
  final String? country;
  final String? logoUrl;
  final Color? primaryColor;

  /// "Polanco · Ciudad de México" / "Ciudad de México" / "" depending on what's set.
  String get locationLabel {
    final parts = <String>[
      if (neighborhood != null && neighborhood!.isNotEmpty) neighborhood!,
      if (city != null && city!.isNotEmpty) city!,
    ];
    return parts.join(' · ');
  }

  /// Concatenated, lowercased haystack used for client-side filtering.
  String get searchHaystack {
    return [name, appName, city, neighborhood, country]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(' ')
        .toLowerCase();
  }

  factory TenantSummary.fromMap(Map<String, dynamic> data) {
    return TenantSummary(
      tenantId: (data['tenantId'] as String?) ?? '',
      name: (data['name'] as String?) ?? '',
      appName: (data['appName'] as String?) ?? (data['name'] as String?) ?? '',
      slug: (data['slug'] as String?) ?? '',
      city: data['city'] as String?,
      neighborhood: data['neighborhood'] as String?,
      country: data['country'] as String?,
      logoUrl: data['logoUrl'] as String?,
      primaryColor: _parseColor(data['primaryColor'] as String?),
    );
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
}
