// Week 5 - telemetry batching.
//
// Plan (p4): "the microservice will batch state updates over a 5 second window before
// executing bulk database inserts [to] reduce transaction overhead."
// Plan (p6): out-of-order packets must not regress a vehicle's stored state - every packet
// carries an edge timestamp and "the database write logic will drop packets that have
// older timestamps than the current ones".
//
// The telemetry collection stores CURRENT state (one document per vehicle), so within a
// window only the newest packet per vehicle matters. add() is synchronous and never awaits,
// keeping the ingestion path off the database. Every batchMs the buffer is swapped and
// written with a single bulkWrite of upserts; the last-write-wins guard lives in the update
// pipeline so a concurrently-stored newer document is never overwritten.

export const STATE_FIELDS = [
  "coordinates",
  "speed",
  "batteryLevel",
  "currentState",
  "seatWeightKg",
  "timestamp",
];

// One bulkWrite op: upsert this vehicle's document, but only let fields move forward when
// the incoming edge timestamp is newer than what is stored (or the document is new).
export function buildUpsert(pkt) {
  const newer = { $gte: [pkt.timestamp, { $ifNull: ["$timestamp", Number.MIN_SAFE_INTEGER] }] };
  const set = { vehicleID: pkt.vehicleID };
  for (const field of STATE_FIELDS) {
    if (pkt[field] !== undefined) {
      set[field] = { $cond: [newer, pkt[field], "$" + field] };
    }
  }
  return {
    updateOne: {
      filter: { vehicleID: pkt.vehicleID },
      update: [{ $set: set }],
      upsert: true,
    },
  };
}

export class TelemetryBatcher {
  constructor({ collection, batchMs = 5000, logger = console } = {}) {
    this.collection = collection;
    this.batchMs = batchMs;
    this.log = logger;
    this.buffer = new Map(); // vehicleID -> newest packet seen this window
    this.flushing = false;
    this.timer = null;
    this.stats = { received: 0, dropped: 0, flushes: 0, upserts: 0 };
  }

  // synchronous on purpose - the MQTT handler must not wait on Mongo
  add(pkt) {
    this.stats.received++;
    const held = this.buffer.get(pkt.vehicleID);
    if (held && held.timestamp > pkt.timestamp) {
      this.stats.dropped++; // arrived out of order, older than what is already buffered
      return;
    }
    this.buffer.set(pkt.vehicleID, pkt);
  }

  start() {
    if (this.timer) return;
    this.timer = setInterval(() => {
      this.flush().catch((e) => this.log.error("[telemetry] flush error:", e.message));
    }, this.batchMs);
  }

  async stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    await this.flush();
  }

  async flush() {
    if (this.flushing || this.buffer.size === 0) return { flushed: 0 };
    this.flushing = true;

    const batch = this.buffer;
    this.buffer = new Map(); // new packets during the write land here

    try {
      const ops = [...batch.values()].map(buildUpsert);
      const started = Date.now();
      const res = await this.collection.bulkWrite(ops, { ordered: false });
      const ms = Date.now() - started;

      this.stats.flushes++;
      this.stats.upserts += ops.length;
      this.log.log(
        `[telemetry] flushed ${ops.length} vehicles in ${ms}ms ` +
          `(upserted=${res.upsertedCount ?? 0} modified=${res.modifiedCount ?? 0})`
      );
      return { flushed: ops.length };
    } catch (e) {
      // write failed - return the batch to the buffer so nothing is lost, newest wins
      for (const [id, pkt] of batch) {
        const held = this.buffer.get(id);
        if (!held || held.timestamp < pkt.timestamp) this.buffer.set(id, pkt);
      }
      throw e;
    } finally {
      this.flushing = false;
    }
  }
}
