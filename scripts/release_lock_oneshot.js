// One-shot: release a stuck _autoEmptyChargeLockAt for the given uid in dev.
// Usage:
//   cd functions && node ../scripts/release_lock_oneshot.js <uid>
// Uses ADC (run `firebase login` + `gcloud auth application-default login`
// or set GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON).
const admin = require("firebase-admin");

admin.initializeApp({ projectId: "pushka-app-ioel-test" });
const db = admin.firestore();

(async () => {
  const uid = process.argv[2];
  if (!uid) { console.error("uid required"); process.exit(1); }

  const userSnap = await db.collection("users").doc(uid).get();
  if (!userSnap.exists) { console.error("user not found"); process.exit(1); }

  const tenantId = userSnap.data()?.tenantId;
  if (!tenantId) { console.error("no tenantId on user"); process.exit(1); }

  const stateRef = db.collection("users").doc(uid)
    .collection("tenantState").doc(tenantId);
  const before = (await stateRef.get()).data() || {};
  console.log("before:", {
    lockAt: before._autoEmptyChargeLockAt?.toMillis?.() || null,
    source: before._autoEmptyChargeLockSource || null,
  });

  await stateRef.set({
    _autoEmptyChargeLockAt: admin.firestore.FieldValue.delete(),
    _autoEmptyChargeLockSource: admin.firestore.FieldValue.delete(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  const after = (await stateRef.get()).data() || {};
  console.log("after:", {
    lockAt: after._autoEmptyChargeLockAt?.toMillis?.() || null,
    source: after._autoEmptyChargeLockSource || null,
  });
  console.log("done.");
  process.exit(0);
})();
