import 'package:flutter/foundation.dart' show kIsWeb;

/// Static mapping: web hostname → tenant slug.
///
/// When a tenant points their custom domain (e.g. `app.jabadencampus.com`) at
/// our Firebase Hosting site, we auto-select their tenant instead of asking
/// new users for an invite code. Zero-friction onboarding for donors who
/// arrive via the tenant's branded URL.
///
/// Add one entry per tenant when their DNS is confirmed live. The slug on
/// the RIGHT must match the `slug` field on the tenant's Firestore doc
/// (verify in the admin panel → Organizations → tenant detail).
///
/// If the hostname isn't in this map (or we're running on mobile/desktop),
/// the app falls back to the normal `/tenant-setup` code-entry flow.
///
/// Non-web platforms always return `null` — a mobile app installed from
/// a store doesn't have a hostname to key off of, and the user's tenant
/// selection is either persisted server-side or entered via code.
const Map<String, String> _hostnameToTenantSlug = {
  // First production tenant. TODO: verify the slug matches the actual
  // `tenants/{tid}.slug` value in prod Firestore before enabling the
  // custom domain — a mismatch here silently sends users to the "code
  // not found" screen instead of joining. The admin panel's tenant
  // detail page shows the canonical slug.
  'app.jabadencampus.com': 'jabadencampus',
  'www.app.jabadencampus.com': 'jabadencampus',
};

/// Returns the tenant slug bound to the current web hostname, or `null`
/// when no mapping exists or we're not running on the web.
String? tenantSlugFromHostname() {
  if (!kIsWeb) return null;
  final host = Uri.base.host.toLowerCase();
  if (host.isEmpty) return null;
  return _hostnameToTenantSlug[host];
}
