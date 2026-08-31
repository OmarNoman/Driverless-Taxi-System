// Week 4 - Event Router validation tests. Run: npm test  (node --test)
// Covers the "malformed test messages correctly rejected" part of the Week 4 validation.

import test from "node:test";
import assert from "node:assert/strict";
import { loadValidator, checkMessage } from "./validator.js";

const validate = loadValidator();

const good = {
  vehicleID: "TAXI-001",
  coordinates: { lat: -37.8136, lon: 144.9631 },
  speed: 34.21,
  batteryLevel: 87.4,
  currentState: "driving",
  seatWeightKg: 72.5,
  timestamp: 1725000000000,
};

const on = "fleet/TAXI-001/telemetry";

test("accepts a well-formed telemetry packet", () => {
  assert.equal(checkMessage(on, JSON.stringify(good), validate).ok, true);
});

test("accepts a packet without the optional seatWeightKg", () => {
  const { seatWeightKg, ...rest } = good;
  assert.equal(checkMessage(on, JSON.stringify(rest), validate).ok, true);
});

test("rejects a non-JSON payload", () => {
  assert.equal(checkMessage(on, "{ not json", validate).ok, false);
});

test("rejects an unknown currentState", () => {
  assert.equal(
    checkMessage(on, JSON.stringify({ ...good, currentState: "flying" }), validate).ok,
    false
  );
});

test("rejects a missing required field", () => {
  const { speed, ...rest } = good;
  assert.equal(checkMessage(on, JSON.stringify(rest), validate).ok, false);
});

test("rejects an out-of-range batteryLevel", () => {
  assert.equal(
    checkMessage(on, JSON.stringify({ ...good, batteryLevel: 120 }), validate).ok,
    false
  );
});

test("rejects an unknown extra property", () => {
  assert.equal(
    checkMessage(on, JSON.stringify({ ...good, heading: 1.2 }), validate).ok,
    false
  );
});

test("rejects a topic / payload vehicleID mismatch", () => {
  assert.equal(checkMessage("fleet/TAXI-999/telemetry", JSON.stringify(good), validate).ok, false);
});
