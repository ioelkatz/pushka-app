// One-off local runner for the donation-reasons backfill. Uses Application
// Default Credentials (set via `gcloud auth application-default login`) so
// it bypasses App Check the same way other admin-SDK code does.
//
// Usage:
//   GCLOUD_PROJECT=pushka-app-ioel-test node backfill-donation-reasons.js
//   GCLOUD_PROJECT=pushka-app-ioel       node backfill-donation-reasons.js

const admin = require("firebase-admin");

const projectId = process.env.GCLOUD_PROJECT || process.env.FIREBASE_PROJECT;
if (!projectId) {
  console.error("Set GCLOUD_PROJECT to pushka-app-ioel-test or pushka-app-ioel");
  process.exit(1);
}

admin.initializeApp({ projectId });
const db = admin.firestore();

const DEFAULT_CHABAD_DONATION_REASONS = [
  "Donde más se necesite",
  "Comida para familias",
  "Estudios de Torá",
  "Festividades",
  "Edificio / Beit Jabad",
  "Becas para niños",
];

(async () => {
  const tenantsSnap = await db.collection("tenants").get();
  let scanned = 0, updated = 0, skipped = 0;

  for (const tenantDoc of tenantsSnap.docs) {
    scanned += 1;
    const existing = tenantDoc.data()?.donationReasons;
    if (Array.isArray(existing) && existing.length > 0) {
      skipped += 1;
      continue;
    }
    await tenantDoc.ref.set({
      donationReasons: DEFAULT_CHABAD_DONATION_REASONS,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    updated += 1;
    console.log(`  • ${tenantDoc.id}: stamped ${DEFAULT_CHABAD_DONATION_REASONS.length} reasons`);
  }

  console.log(`\nDone. scanned=${scanned} updated=${updated} skipped=${skipped}`);
  process.exit(0);
})().catch((err) => {
  console.error("Backfill failed:", err);
  process.exit(1);
});
