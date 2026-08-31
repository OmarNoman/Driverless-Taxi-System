// Week 6 - vehicle selection tests. Run: npm test  (node --test). No DB or broker needed.

import test from "node:test";
import assert from "node:assert/strict";
import { haversineKm, selectVehicle } from "./select.js";

test("haversineKm matches a known short distance", () => {
  // 0.01 deg of latitude is about 1.111 km
  const d = haversineKm({ lat: 0, lon: 0 }, { lat: 0.01, lon: 0 });
  assert.ok(Math.abs(d - 1.111) < 0.01, `got ${d}`);
});

const pickup = { lat: -37.814, lon: 144.963 };

test("picks the nearest vehicle when batteries are healthy", () => {
  const near = { vehicleId: "TAXI-001", lat: -37.8145, lon: 144.9635, batteryLevel: 90, currentState: "parked" };
  const far = { vehicleId: "TAXI-002", lat: -37.83, lon: 144.98, batteryLevel: 90, currentState: "parked" };
  assert.equal(selectVehicle([far, near], pickup).vehicleId, "TAXI-001");
});

test("a low-battery near vehicle loses to a healthy farther one", () => {
  const nearLow = { vehicleId: "TAXI-001", lat: -37.8146, lon: 144.9636, batteryLevel: 10, currentState: "parked" };
  const farOk = { vehicleId: "TAXI-002", lat: -37.8155, lon: 144.9645, batteryLevel: 95, currentState: "parked" };
  assert.equal(selectVehicle([nearLow, farOk], pickup).vehicleId, "TAXI-002");
});

test("returns null when there are no candidates", () => {
  assert.equal(selectVehicle([], pickup), null);
});

test("f = g + h, and a moving vehicle carries a penalty a parked one does not", () => {
  const at = { lat: -37.8142, lon: 144.9632 };
  const parked = { vehicleId: "P", ...at, batteryLevel: 80, currentState: "parked" };
  const moving = { vehicleId: "M", ...at, batteryLevel: 80, currentState: "driving" };
  const rp = selectVehicle([parked], pickup);
  const rm = selectVehicle([moving], pickup);
  assert.equal(rp.g, 0);
  assert.ok(rm.g > 0);
  assert.ok(Math.abs(rp.f - (rp.g + rp.h)) < 1e-9);
  assert.ok(Math.abs(rm.f - (rm.g + rm.h)) < 1e-9);
});
