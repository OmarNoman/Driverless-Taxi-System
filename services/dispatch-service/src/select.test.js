// Vehicle selection tests. Run: npm test  (node --test). No DB or broker needed.

import test from "node:test";
import assert from "node:assert/strict";
import { loadGraph } from "./graph.js";
import { selectVehicle } from "./select.js";

const g = loadGraph();
const N = (name) => g.idByName(name);
const at = (name) => ({ lat: g.node.get(N(name)).lat, lon: g.node.get(N(name)).lon });

const veh = (id, over = {}) => ({
  vehicleId: id,
  vehicleType: "sedan",
  seats: 4,
  ...at("Melbourne CBD"),
  batteryLevel: 90,
  currentState: "parked",
  ...over,
});

test("returns null when there are no candidates", () => {
  assert.equal(selectVehicle([], N("Boxhill"), g, 1), null);
});

test("picks the vehicle with the shorter A* road distance to the pickup", () => {
  const near = veh("NEAR", { ...at("Camberwell") }); // one hop to Boxhill
  const far = veh("FAR", { ...at("Sunshine") }); // across the city
  const choice = selectVehicle([far, near], N("Boxhill"), g, 1);
  assert.equal(choice.vehicleId, "NEAR");
  assert.deepEqual(choice.route.map((id) => g.name(id)), ["Camberwell", "Boxhill"]);
});

test("route starts at the vehicle's nearest node and ends at the pickup node", () => {
  const choice = selectVehicle([veh("V", { ...at("Sunshine") })], N("St Kilda"), g, 1);
  assert.equal(g.name(choice.startNode), "Sunshine");
  assert.equal(g.name(choice.route.at(-1)), "St Kilda");
});

test("a low-battery near vehicle can lose to a healthy one a little further", () => {
  const nearLow = veh("LOW", { ...at("Camberwell"), batteryLevel: 10 }); // +5 km penalty
  const okFurther = veh("OK", { ...at("Burwood"), batteryLevel: 95 });
  const choice = selectVehicle([nearLow, okFurther], N("Boxhill"), g, 1);
  assert.equal(choice.vehicleId, "OK");
  assert.ok(choice.batteryPenaltyKm === 0);
});

test("a charging vehicle carries the charging penalty", () => {
  const c = selectVehicle([veh("C", { currentState: "charging" })], N("Camberwell"), g, 1);
  assert.ok(c.batteryPenaltyKm >= 8);
});

test("right-size preference: a sedan beats an equally placed van for a small party", () => {
  const sedan = veh("S", { vehicleType: "sedan", seats: 4, ...at("Camberwell") });
  const van = veh("V", { vehicleType: "van", seats: 7, ...at("Camberwell") });
  const choice = selectVehicle([van, sedan], N("Boxhill"), g, 1);
  assert.equal(choice.vehicleId, "S");
  assert.ok(choice.sizePenaltyKm < selectVehicle([van], N("Boxhill"), g, 1).sizePenaltyKm);
});

test("score = roadKm + batteryPenaltyKm + sizePenaltyKm", () => {
  const c = selectVehicle([veh("X", { ...at("Sunshine"), batteryLevel: 30 })], N("St Kilda"), g, 1);
  assert.ok(Math.abs(c.score - (c.roadKm + c.batteryPenaltyKm + c.sizePenaltyKm)) < 1e-9);
  assert.equal(c.batteryPenaltyKm, 2); // mid-battery band
});
