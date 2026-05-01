/**
 * Seed script — Chabad México tenant + migrate existing users
 *
 * Run with: node scripts/seed_chabad_mexico.js
 * From inside: functions/
 *
 * What it does:
 *   1. Creates tenant doc "chabadmexico" in /tenants
 *   2. Sets super_admin claim on ioelkatz@gmail.com
 *   3. Sets tenant_admin claim on jymmexico@gmail.com (+ tenantId: "chabadmexico")
 *   4. Adds tenantId: "chabadmexico" to ALL existing users (non-destructive)
 */

const admin = require("firebase-admin");

admin.initializeApp({ projectId: "pushka-app-ioel" });
const db = admin.firestore();
const auth = admin.auth();

const TENANT_ID = "chabadmexico";
const SUPER_ADMIN_EMAIL = "ioelkatz@gmail.com";
const TENANT_ADMIN_EMAIL = "jymmexico@gmail.com";

async function createTenantDoc() {
  const ref = db.collection("tenants").doc(TENANT_ID);
  const existing = await ref.get();

  if (existing.exists) {
    console.log("Tenant doc already exists, skipping creation.");
    return;
  }

  await ref.set({
    name: "Chabad México",
    slug: TENANT_ID,
    status: "active",

    // Branding — default values, will be updated via admin web
    primaryColor: "#FF6B35",
    secondaryColor: "#FFD700",
    logoUrl: null,
    appName: "Chabad Pushka México",
    welcomeText: "Tzedakah",
    showPoweredBy: true,

    // Localización
    defaultLanguage: "es",
    defaultCurrency: "MXN",
    defaultCountry: "México",

    // Legal / Contacto
    contactEmail: TENANT_ADMIN_EMAIL,
    contactPhone: null,
    privacyPolicyUrl: null,
    termsUrl: null,
    city: "Ciudad de México",
    country: "México",

    // Stripe Connect (not connected yet)
    stripeConnectAccountId: null,
    stripeConnectStatus: "not_connected",
    commissionRate: 0.03,

    // Billing (not set up yet)
    planPrice: 0,
    stripeSubscriptionId: null,
    stripeCustomerId: null,
    paymentStatus: "current",
    billingCycleStart: null,
    billingNextDue: null,
    gracePeriodEndsAt: null,

    // Admin
    adminUid: null,
    adminEmail: TENANT_ADMIN_EMAIL,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    createdBy: "seed_script",
  });

  console.log(`Tenant doc created: /tenants/${TENANT_ID}`);
}

async function setSuperAdminClaim() {
  try {
    const user = await auth.getUserByEmail(SUPER_ADMIN_EMAIL);
    await auth.setCustomUserClaims(user.uid, {
      role: "super_admin",
      admin: true,
    });
    console.log(`super_admin claim set for ${SUPER_ADMIN_EMAIL} (uid: ${user.uid})`);
  } catch (err) {
    if (err.code === "auth/user-not-found") {
      console.warn(`WARN: ${SUPER_ADMIN_EMAIL} not found in Firebase Auth — skipping.`);
    } else {
      throw err;
    }
  }
}

async function setTenantAdminClaim() {
  try {
    const user = await auth.getUserByEmail(TENANT_ADMIN_EMAIL);
    await auth.setCustomUserClaims(user.uid, {
      role: "tenant_admin",
      tenantId: TENANT_ID,
    });

    // Also update the tenant doc with the admin's uid
    await db.collection("tenants").doc(TENANT_ID).update({
      adminUid: user.uid,
    });

    console.log(`tenant_admin claim set for ${TENANT_ADMIN_EMAIL} (uid: ${user.uid})`);
  } catch (err) {
    if (err.code === "auth/user-not-found") {
      console.warn(`WARN: ${TENANT_ADMIN_EMAIL} not found in Firebase Auth — they must register first.`);
    } else {
      throw err;
    }
  }
}

async function migrateExistingUsers() {
  console.log("Migrating existing users...");
  const snap = await db.collection("users").get();

  let updated = 0;
  let skipped = 0;
  const batch = db.batch();

  for (const doc of snap.docs) {
    const data = doc.data();
    if (data.tenantId) {
      skipped++;
      continue;
    }
    batch.update(doc.ref, { tenantId: TENANT_ID });
    updated++;
  }

  if (updated > 0) {
    await batch.commit();
  }

  console.log(`Users migrated: ${updated} updated, ${skipped} already had tenantId.`);
}

async function main() {
  console.log("=== Seed script: Chabad México ===\n");

  await createTenantDoc();
  await setSuperAdminClaim();
  await setTenantAdminClaim();
  await migrateExistingUsers();

  console.log("\n=== Done ===");
  process.exit(0);
}

main().catch((err) => {
  console.error("Error:", err);
  process.exit(1);
});
