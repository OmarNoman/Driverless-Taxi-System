// Road-graph / A* tests. Run: npm test  (node --test). No DB or broker needed.

import test from "node:test";
import assert from "node:assert/strict";
import { loadGraph, haversineKm } from "./graph.js";

const g = loadGraph();

test("loads all 21 landmark nodes", () => {
  assert.equal(g.names().length, 21);
});

test("idByName is case-insensitive and trims; unknown -> null", () => {
  assert.equal(g.idByName("  camBERwell "), g.idByName("Camberwell"));
  assert.equal(g.idByName("Nowhere"), null);
});

test("nearestNode snaps a coordinate to the closest landmark", () => {
  assert.equal(g.name(g.nearestNode({ lat: -37.814, lon: 144.963 })), "Melbourne CBD");
  assert.equal(g.name(g.nearestNode({ lat: -37.9990779, lon: 145.0913484 })), "Mordialloc");
});

test("aStar to the same node is a zero-cost single-node path", () => {
  const r = g.aStar(g.idByName("Melbourne CBD"), g.idByName("Melbourne CBD"));
  assert.deepEqual(r, { path: [g.idByName("Melbourne CBD")], costKm: 0 });
});

test("aStar finds the known shortest path CBD -> Boxhill", () => {
  const r = g.aStar(g.idByName("Melbourne CBD"), g.idByName("Boxhill"));
  assert.deepEqual(r.path.map((id) => g.name(id)), ["Melbourne CBD", "Camberwell", "Boxhill"]);
  assert.ok(Math.abs(r.costKm - 14.93) < 0.1, `costKm ${r.costKm}`);
});

test("aStar path cost is the sum of its edge lengths", () => {
  const r = g.aStar(g.idByName("Sunshine"), g.idByName("St Kilda"));
  let sum = 0;
  for (let i = 1; i < r.path.length; i++) {
    sum += haversineKm(g.node.get(r.path[i - 1]), g.node.get(r.path[i]));
  }
  assert.ok(Math.abs(sum - r.costKm) < 1e-9);
});

test("the heuristic never overestimates (straight line <= road cost)", () => {
  const ids = [...g.node.keys()];
  for (const a of ids) {
    for (const b of ids) {
      const r = g.aStar(a, b);
      assert.ok(r, `unreachable ${a}->${b}`);
      const straight = haversineKm(g.node.get(a), g.node.get(b));
      assert.ok(r.costKm >= straight - 1e-9, `${a}->${b}: road ${r.costKm} < straight ${straight}`);
    }
  }
});

test("aStar is symmetric on an undirected graph", () => {
  const ab = g.aStar(g.idByName("Truganina"), g.idByName("Greensborough"));
  const ba = g.aStar(g.idByName("Greensborough"), g.idByName("Truganina"));
  assert.ok(Math.abs(ab.costKm - ba.costKm) < 1e-9);
});
