// TelemetryBatcher tests. Run: npm test  (node --test). No MongoDB required.

import test from "node:test";
import assert from "node:assert/strict";
import { TelemetryBatcher, buildUpsert, stateFields } from "./batcher.js";

const sedan = (id, ts, over = {}) => ({
  vehicleID: id,
  vehicleType: "sedan",
  coordinates: { lat: -37.8, lon: 144.9 },
  heading: 90,
  speed: 10,
  batteryLevel: 90,
  currentState: "driving",
  timestamp: ts,
  occupancy: { seatsTotal: 4, seatsOccupied: 1, seatWeightKg: 70 },
  doorsLocked: true,
  ...over,
});

function fakeCollection() {
  return {
    calls: [],
    async bulkWrite(ops) {
      this.calls.push(ops);
      return { upsertedCount: ops.length, modifiedCount: 0 };
    },
  };
}
function fakeHistory() {
  return {
    docs: [],
    async insertMany(rows) {
      this.docs.push(...rows);
      return { insertedCount: rows.length };
    },
  };
}
const silent = { log() {}, error() {}, warn() {} };

test("stateFields is every key except vehicleID and _id", () => {
  const f = stateFields(sedan("TAXI-001", 1));
  assert.ok(f.includes("vehicleType") && f.includes("occupancy") && f.includes("doorsLocked"));
  assert.ok(!f.includes("vehicleID"));
});

test("buildUpsert carries the packet's own fields, whatever the type", () => {
  const bus = {
    vehicleID: "TAXI-003", vehicleType: "bus", coordinates: { lat: -37.8, lon: 145.1 },
    heading: 10, speed: 20, batteryLevel: 80, currentState: "driving", timestamp: 500,
    passengerCount: 12, passengerCapacity: 40,
    doorState: { front: "closed", middle: "closed", rear: "closed" },
    wheelchairRampDeployed: false, nextStopId: 14,
  };
  const set = buildUpsert(bus).updateOne.update[0].$set;
  assert.ok("passengerCount" in set && "doorState" in set && "nextStopId" in set);
  assert.ok(!("occupancy" in set));
  assert.equal(set.passengerCount.$cond[1], 12);
});

test("buildUpsert guards against older timestamps", () => {
  const set = buildUpsert(sedan("TAXI-001", 500)).updateOne.update[0].$set;
  assert.deepEqual(set.speed.$cond[0], {
    $gte: [500, { $ifNull: ["$timestamp", Number.MIN_SAFE_INTEGER] }],
  });
  assert.equal(set.speed.$cond[2], "$speed");
});

test("buffers only the newest packet per vehicle for current state", () => {
  const b = new TelemetryBatcher({ collection: fakeCollection(), logger: silent });
  b.add(sedan("TAXI-001", 100));
  b.add(sedan("TAXI-001", 300));
  b.add(sedan("TAXI-001", 200)); // out of order
  assert.equal(b.buffer.size, 1);
  assert.equal(b.buffer.get("TAXI-001").timestamp, 300);
  assert.equal(b.stats.dropped, 1);
});

test("history buffer keeps every packet, including out-of-order ones", async () => {
  const col = fakeCollection();
  const hist = fakeHistory();
  const b = new TelemetryBatcher({ collection: col, historyCollection: hist, logger: silent });
  b.add(sedan("TAXI-001", 100));
  b.add(sedan("TAXI-001", 300));
  b.add(sedan("TAXI-001", 200));
  await b.flush();
  assert.equal(col.calls[0].length, 1); // one upsert (newest only)
  assert.equal(hist.docs.length, 3); // all three appended
  assert.ok(hist.docs.every((d) => d.ingestedAt instanceof Date));
});

test("flush clears both buffers", async () => {
  const b = new TelemetryBatcher({
    collection: fakeCollection(), historyCollection: fakeHistory(), logger: silent,
  });
  b.add(sedan("TAXI-001", 100));
  b.add(sedan("TAXI-002", 100));
  const r = await b.flush();
  assert.equal(r.flushed, 2);
  assert.equal(r.history, 2);
  assert.equal(b.buffer.size, 0);
  assert.equal(b.historyBuffer.length, 0);
});

test("empty flush does not call either collection", async () => {
  const col = fakeCollection();
  const hist = fakeHistory();
  const b = new TelemetryBatcher({ collection: col, historyCollection: hist, logger: silent });
  await b.flush();
  assert.equal(col.calls.length, 0);
  assert.equal(hist.docs.length, 0);
});

test("with no history collection, only current state is written", async () => {
  const col = fakeCollection();
  const b = new TelemetryBatcher({ collection: col, logger: silent });
  b.add(sedan("TAXI-001", 100));
  await b.flush();
  assert.equal(col.calls[0].length, 1);
  assert.equal(b.stats.history, 0);
});

test("a failed flush returns both batches to their buffers", async () => {
  const col = {
    async bulkWrite() {
      throw new Error("mongo down");
    },
  };
  const b = new TelemetryBatcher({
    collection: col, historyCollection: fakeHistory(), logger: silent,
  });
  b.add(sedan("TAXI-001", 100));
  await assert.rejects(() => b.flush(), /mongo down/);
  assert.equal(b.buffer.size, 1);
  assert.equal(b.historyBuffer.length, 1);
});
