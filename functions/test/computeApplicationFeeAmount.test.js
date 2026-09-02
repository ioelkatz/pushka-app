/**
 * Guard tests for computeApplicationFeeAmount — the single-source-of-truth
 * helper that decides whether Stripe skims a platform commission on Direct
 * Charges. The chabadmexico tenant runs at commissionRate=0 (Jym Inc.
 * agreement + Apple non-profit fee waiver depends on it).
 *
 * If ANY of these tests fail: Apple could revoke the 30% waiver, the Rab
 * could get charged commission, or the platform could accidentally start
 * paying Stripe fees out of pocket. Do NOT relax these assertions without
 * updating the Rab agreement first.
 *
 * Run: cd functions && node --test test/computeApplicationFeeAmount.test.js
 */

const test = require("node:test");
const assert = require("node:assert/strict");

// Load ONLY the exported testable helper — do NOT require the full index.js
// entry points, or they'll try to bootstrap admin SDK credentials.
const { __testables } = require("../index.js");
const { computeApplicationFeeAmount } = __testables;

test("returns null when commissionRate is 0 (chabadmexico contract)", () => {
  assert.equal(computeApplicationFeeAmount(10000, 0), null);
  assert.equal(computeApplicationFeeAmount(1, 0), null);
  assert.equal(computeApplicationFeeAmount(99999999, 0), null);
});

test("returns null when commissionRate is negative or NaN", () => {
  assert.equal(computeApplicationFeeAmount(10000, -0.05), null);
  assert.equal(computeApplicationFeeAmount(10000, NaN), null);
  assert.equal(computeApplicationFeeAmount(10000, null), null);
  assert.equal(computeApplicationFeeAmount(10000, undefined), null);
});

test("returns null when amount is 0, negative, or invalid", () => {
  assert.equal(computeApplicationFeeAmount(0, 0.03), null);
  assert.equal(computeApplicationFeeAmount(-100, 0.03), null);
  assert.equal(computeApplicationFeeAmount(NaN, 0.03), null);
  assert.equal(computeApplicationFeeAmount("100", 0.03), null);
});

test("computes commission at standard 3% rate", () => {
  const r = computeApplicationFeeAmount(10000, 0.03);
  assert.equal(r.fee, 300);
  assert.equal(r.clamped, false);
  assert.equal(r.rawFee, 300);
});

test("floors the raw fee (Stripe requires integer minor units)", () => {
  const r = computeApplicationFeeAmount(333, 0.03); // 9.99 -> 9
  assert.equal(r.fee, 9);
  assert.equal(r.clamped, false);
});

test("returns null when floored fee rounds down to 0", () => {
  // 10 * 0.03 = 0.30 -> floor 0 -> null
  assert.equal(computeApplicationFeeAmount(10, 0.03), null);
});

test("clamps fee to amount-1 to keep the merchant net-positive", () => {
  // 100% commission on 500 would take everything -> clamp to 499.
  const r = computeApplicationFeeAmount(500, 1.0);
  assert.equal(r.fee, 499);
  assert.equal(r.clamped, true);
  assert.equal(r.rawFee, 500);
});

test("does NOT clamp when raw fee already less than amount", () => {
  const r = computeApplicationFeeAmount(1000, 0.5);
  assert.equal(r.fee, 500);
  assert.equal(r.clamped, false);
});

test("REGRESSION: 500 cents at 0% must be null (Ioel's dollar test)", () => {
  // The $1 pushka empty for chabadmexico: 100 cents, 0% commission.
  // If this ever returns a non-null value, Ioel's tests will start
  // showing tiny fees again.
  assert.equal(computeApplicationFeeAmount(100, 0), null);
  assert.equal(computeApplicationFeeAmount(500, 0), null);
});

test("REGRESSION: large donation at 0% still null", () => {
  // 1000 USD (100000 minor units) — still zero commission for chabadmexico.
  assert.equal(computeApplicationFeeAmount(100000, 0), null);
});
