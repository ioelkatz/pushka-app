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
    this.brandingVersion,
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
  // Round-11 audit MEDIO fix: monotonic timestamp used to cache-bust
  // logoUrl. When an admin uploads a new logo to the SAME URL (or the
  // CDN returns the same URL with different bytes), CachedNetworkImage
  // keeps the old bytes forever. Appending `?v=<brandingVersion>` to
  // the URL forces a re-fetch when it changes. Populated from the
  // tenant doc's `updatedAt` field.
  final int? brandingVersion;

  /// Logo URL with a cache-bust query param appended when a
  /// brandingVersion is known. Returns null when no logo is set.
  String? get cacheBustedLogoUrl {
    if (logoUrl == null || logoUrl!.isEmpty) return null;
    if (brandingVersion == null) return logoUrl;
    final sep = logoUrl!.contains('?') ? '&' : '?';
    return '${logoUrl!}${sep}v=$brandingVersion';
  }

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
    // Extract a numeric branding version from either a Firestore Timestamp
    // (which arrives as a Map with seconds/nanoseconds) or a millis int.
    int? extractVersion(dynamic raw) {
      if (raw == null) return null;
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      if (raw is Map) {
        final secs = raw['_seconds'] ?? raw['seconds'];
        if (secs is num) return secs.toInt() * 1000;
      }
      // DateTime shape via toDate() isn't reachable here because we already
      // received parsed data. Any exotic shape falls through to null.
      return null;
    }
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
      brandingVersion: extractVersion(data['updatedAt']) ?? extractVersion(data['brandingUpdatedAt']),
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
