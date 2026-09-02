// Event Router validation tests. Run: npm test  (node --test)
// Covers "malformed test messages correctly rejected" against the per-vehicle-type schema.

import test from "node:test";
import assert from "node:assert/strict";
import { loadValidator, checkMessage } from "./validator.js";

const validate = loadValidator();
const on = (id) => `fleet/${id}/telemetry`;

const common = {
  coordinates: { lat: -37.8136, lon: 144.9631 },
  heading: 90,
  speed: 34.21,
  batteryLevel: 87.4,
  currentState: "driving",
  timestamp: 1725000000000,
};
const sedan = {
  vehicleID: "TAXI-001", vehicleType: "sedan", ...common,
  occupancy: { seatsTotal: 4, seatsOccupied: 2, seatWeightKg: 138.5 },
  doorsLocked: true,
};
const van = {
  vehicleID: "TAXI-002", vehicleType: "van", ...common,
  occupancy: { seatsTotal: 7, seatsOccupied: 3, seatWeightKg: 210 },
  doorState: { front: "closed", slidingLeft: "closed", rear: "closed" },
  cargoLoadKg: 40,
};
const bus = {
  vehicleID: "TAXI-003", vehicleType: "bus", ...common,
  passengerCount: 22, passengerCapacity: 40,
  doorState: { front: "open", middle: "closed", rear: "closed" },
  wheelchairRampDeployed: false, nextStopId: 14,
};

test("accepts a well-formed packet of each vehicle type", () => {
  for (const p of [sedan, van, bus]) {
    assert.equal(checkMessage(on(p.vehicleID), JSON.stringify(p), validate).ok, true, p.vehicleType);
  }
});

test("accepts currentState 'charging'", () => {
  assert.equal(checkMessage(on("TAXI-001"), JSON.stringify({ ...sedan, currentState: "charging" }), validate).ok, true);
});

test("rejects a non-JSON payload", () => {
  assert.equal(checkMessage(on("TAXI-001"), "{ not json", validate).ok, false);
});

test("rejects an unknown currentState", () => {
  assert.equal(checkMessage(on("TAXI-001"), JSON.stringify({ ...sedan, currentState: "flying" }), validate).ok, false);
});

test("rejects a missing type-specific field", () => {
  const { doorsLocked, ...rest } = sedan;
  assert.equal(checkMessage(on("TAXI-001"), JSON.stringify(rest), validate).ok, false);
});

test("rejects a missing common field", () => {
  const { heading, ...rest } = bus;
  assert.equal(checkMessage(on("TAXI-003"), JSON.stringify(rest), validate).ok, false);
});

test("rejects an out-of-range batteryLevel", () => {
  assert.equal(checkMessage(on("TAXI-001"), JSON.stringify({ ...sedan, batteryLevel: 120 }), validate).ok, false);
});

test("rejects a field from another vehicle type", () => {
  assert.equal(checkMessage(on("TAXI-001"), JSON.stringify({ ...sedan, cargoLoadKg: 5 }), validate).ok, false);
});

test("rejects an unknown extra property", () => {
  assert.equal(checkMessage(on("TAXI-003"), JSON.stringify({ ...bus, foo: 1 }), validate).ok, false);
});

test("rejects a topic / payload vehicleID mismatch", () => {
  assert.equal(checkMessage("fleet/TAXI-999/telemetry", JSON.stringify(sedan), validate).ok, false);
});
