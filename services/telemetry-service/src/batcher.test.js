// Week 5 - TelemetryBatcher tests. Run: npm test  (node --test). No MongoDB required.

import test from "node:test";
import assert from "node:assert/strict";
import { TelemetryBatcher, buildUpsert } from "./batcher.js";

const pkt = (id, ts, over = {}) => ({
  vehicleID: id,
  coordinates: { lat: -37.8, lon: 144.9 },
  speed: 10,
  batteryLevel: 90,
  currentState: "driving",
  seatWeightKg: 0,
  timestamp: ts,
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

const silent = { log() {}, error() {}, warn() {} };

test("buffers only the newest packet per vehicle within a window", () => {
  const b = new TelemetryBatcher({ collection: fakeCollection(), logger: silent });
  b.add(pkt("TAXI-001", 100));
  b.add(pkt("TAXI-001", 300));
  b.add(pkt("TAXI-001", 200)); // out of order, older than buffered
  b.add(pkt("TAXI-002", 150));
  assert.equal(b.buffer.size, 2);
  assert.equal(b.buffer.get("TAXI-001").timestamp, 300);
  assert.equal(b.stats.dropped, 1);
});

test("flush writes one bulk op per vehicle, then clears the buffer", async () => {
  const col = fakeCollection();
  const b = new TelemetryBatcher({ collection: col, logger: silent });
  b.add(pkt("TAXI-001", 100));
  b.add(pkt("TAXI-002", 100));
  const r = await b.flush();
  assert.equal(r.flushed, 2);
  assert.equal(col.calls.length, 1);
  assert.equal(col.calls[0].length, 2);
  assert.equal(b.buffer.size, 0);
});

test("flush on an empty buffer does not call the database", async () => {
  const col = fakeCollection();
  const b = new TelemetryBatcher({ collection: col, logger: silent });
  await b.flush();
  assert.equal(col.calls.length, 0);
});

test("buildUpsert produces a last-write-wins upsert", () => {
  const op = buildUpsert(pkt("TAXI-001", 500));
  assert.deepEqual(op.updateOne.filter, { vehicleID: "TAXI-001" });
  assert.equal(op.updateOne.upsert, true);
  const set = op.updateOne.update[0].$set;
  assert.deepEqual(set.speed.$cond[0], {
    $gte: [500, { $ifNull: ["$timestamp", Number.MIN_SAFE_INTEGER] }],
  });
  assert.equal(set.speed.$cond[1], 10); // incoming value
  assert.equal(set.speed.$cond[2], "$speed"); // else keep stored
  assert.equal(set.timestamp.$cond[1], 500);
});

test("buildUpsert omits fields absent from the packet", () => {
  const { seatWeightKg, ...noSeat } = pkt("TAXI-001", 100);
  const set = buildUpsert(noSeat).updateOne.update[0].$set;
  assert.ok(!("seatWeightKg" in set));
  assert.ok("speed" in set);
});

test("a failed flush returns the batch to the buffer", async () => {
  const col = {
    async bulkWrite() {
      throw new Error("mongo down");
    },
  };
  const b = new TelemetryBatcher({ collection: col, logger: silent });
  b.add(pkt("TAXI-001", 100));
  await assert.rejects(() => b.flush(), /mongo down/);
  assert.equal(b.buffer.size, 1);
});

test("newer buffered packet is kept when a failed flush merges back", async () => {
  let calls = 0;
  const col = {
    async bulkWrite() {
      calls++;
      throw new Error("mongo down");
    },
  };
  const b = new TelemetryBatcher({ collection: col, logger: silent });
  b.add(pkt("TAXI-001", 100));
  const flushing = b.flush().catch(() => {});
  b.add(pkt("TAXI-001", 400)); // arrives while the (failing) flush is in flight
  await flushing;
  assert.equal(b.buffer.get("TAXI-001").timestamp, 400);
  assert.equal(calls, 1);
});
