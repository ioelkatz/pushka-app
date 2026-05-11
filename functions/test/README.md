# Cloud Functions tests

Skeleton creado por el Audit Round 4 (2026-05-11). Ver
`audit_round4_phase9_tests.md` para el plan completo.

## Setup

```bash
cd functions
npm install --save-dev jest @firebase/rules-unit-testing firebase-functions-test
```

Agregar a `package.json`:

```json
"scripts": {
  "test": "jest",
  "test:rules": "jest test/rules --runInBand"
}
```

Iniciar emulator antes de tests de rules:
```bash
firebase emulators:start --only firestore,auth --project pushka-app-ioel-test
```

## Estructura propuesta

```
functions/test/
  ├── README.md                          ← este archivo
  ├── createPaymentIntent.test.js        ← ejemplo skeleton
  ├── rules/
  │   ├── users.test.js
  │   ├── tenants.test.js
  │   ├── transactions.test.js
  │   ├── tenantState.test.js
  │   └── _internal.test.js
  ├── fixtures/
  │   └── stripe/
  │       ├── payment_intent_succeeded.json
  │       ├── charge_refunded.json
  │       ├── dispute_created.json
  │       └── ...
  └── helpers/
      ├── mockStripe.js
      └── authClaims.js
```

## Bug crítico a testear primero (BUG-035)

Es esencial cubrir el bug de case-sensitivity en setAdminClaim:

```js
test('setAdminClaim: tenant_admin cannot revoke super_admin via uppercase email', async () => {
  // setup: tenant_admin is first admin of tenant X
  // attack: tenant_admin calls setAdminClaim({ targetEmail: "IOELKATZ@GMAIL.COM", revoke: true })
  // expected: HttpsError('permission-denied')
  // actual (pre-fix): claims wiped
});
```
