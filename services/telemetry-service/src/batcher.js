// Telemetry batching.
//
// Plan (p4): "batch state updates over a 5 second window before executing bulk database
// inserts [to] reduce transaction overhead."
// Plan (p6): out-of-order packets must not regress a vehicle's stored state - every packet
// carries an edge timestamp and "the database write logic will drop packets that have
// older timestamps than the current ones".
//
// Two collections per flush:
//   telemetry          current state, one document per vehicle, upserted with a
//                      last-write-wins guard in the update pipeline. Only the newest packet
//                      per vehicle in the window is written.
//   telemetry_history  append-only, one document per received packet (every packet, not
//                      just the newest), for trajectory and aggregate queries.
//
// add() is synchronous and never awaits - the MQTT handler stays off the database.

// The fields to carry into the current-state document. Everything except vehicleID (the
// filter key) and _id. Works for any vehicleType because the payload only ever contains
// the fields its type defines.
export function stateFields(pkt) {
  return Object.keys(pkt).filter((k) => k !== "vehicleID" && k !== "_id");
}

// One bulkWrite op: upsert this vehicle's document, but only let a field move forward when
// the incoming edge timestamp is newer than the stored one (or the document is new).
export function buildUpsert(pkt) {
  const newer = { $gte: [pkt.timestamp, { $ifNull: ["$timestamp", Number.MIN_SAFE_INTEGER] }] };
  const set = { vehicleID: pkt.vehicleID };
  for (const field of stateFields(pkt)) {
    set[field] = { $cond: [newer, pkt[field], "$" + field] };
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
  constructor({ collection, historyCollection = null, batchMs = 5000, logger = console } = {}) {
    this.collection = collection;
    this.historyCollection = historyCollection;
    this.batchMs = batchMs;
    this.log = logger;
    this.buffer = new Map(); // vehicleID -> newest packet this window (for current state)
    this.historyBuffer = []; // every packet this window (for append-only history)
    this.flushing = false;
    this.timer = null;
    this.stats = { received: 0, dropped: 0, flushes: 0, upserts: 0, history: 0 };
  }

  // synchronous on purpose - the MQTT handler must not wait on Mongo
  add(pkt) {
    this.stats.received++;
    if (this.historyCollection) this.historyBuffer.push(pkt);

    const held = this.buffer.get(pkt.vehicleID);
    if (held && held.timestamp > pkt.timestamp) {
      this.stats.dropped++; // out of order, older than what is already buffered
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
    if (this.flushing || (this.buffer.size === 0 && this.historyBuffer.length === 0)) {
      return { flushed: 0, history: 0 };
    }
    this.flushing = true;

    const batch = this.buffer;
    const history = this.historyBuffer;
    this.buffer = new Map();
    this.historyBuffer = [];

    try {
      const started = Date.now();

      let flushed = 0;
      if (batch.size > 0) {
        const ops = [...batch.values()].map(buildUpsert);
        const res = await this.collection.bulkWrite(ops, { ordered: false });
        flushed = ops.length;
        this.stats.upserts += ops.length;
        this.log.log(
          `[telemetry] flushed ${ops.length} vehicles in ${Date.now() - started}ms ` +
            `(upserted=${res.upsertedCount ?? 0} modified=${res.modifiedCount ?? 0})`
        );
      }

      if (this.historyCollection && history.length > 0) {
        const now = new Date();
        await this.historyCollection.insertMany(
          history.map((p) => ({ ...p, ingestedAt: now })),
          { ordered: false }
        );
        this.stats.history += history.length;
      }

      this.stats.flushes++;
      return { flushed, history: history.length };
    } catch (e) {
      // write failed - return both batches so nothing is lost; newest wins for current state
      for (const [id, pkt] of batch) {
        const held = this.buffer.get(id);
        if (!held || held.timestamp < pkt.timestamp) this.buffer.set(id, pkt);
      }
      this.historyBuffer = history.concat(this.historyBuffer);
      throw e;
    } finally {
      this.flushing = false;
    }
  }
}
