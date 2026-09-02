// Vehicle selection.
//
// Plan (p4): "an A* search heuristic to determine the optimal vehicle dispatch and the
// Haversine formula ... to calculate the distances."
//
// With the real road graph, A* is graph search. For each capacity-eligible available
// vehicle: snap its live position to the nearest node, run A* to the pickup node, and
// score it
//   score(v) = roadKm(v)              A* road distance the taxi must drive to the pickup
//            + batteryPenaltyKm(v)    km-equivalent penalty for low battery / mid-charge
//            + sizePenaltyKm(v)       gentle right-size preference (unused seats)
// The lowest score wins. Capacity is a hard filter applied before this (see store.js).

export const DEFAULTS = {
  lowBatteryPct: 20,
  lowBatteryPenaltyKm: 5,
  midBatteryPct: 40,
  midBatteryPenaltyKm: 2,
  chargingPenaltyKm: 8,
  oversizeKmPerSeat: 0.25,
};

// candidates: [{ vehicleId, vehicleType, seats, lat, lon, batteryLevel, currentState }]
// returns the best { vehicleId, vehicleType, startNode, route:[nodeIds], roadKm,
//                    batteryPenaltyKm, sizePenaltyKm, score } or null
export function selectVehicle(candidates, pickupNodeId, graph, partySize = 1, opts = {}) {
  const cfg = { ...DEFAULTS, ...opts };
  let best = null;

  for (const c of candidates) {
    const startNode = graph.nearestNode({ lat: c.lat, lon: c.lon });
    const path = graph.aStar(startNode, pickupNodeId);
    if (!path) continue; // unreachable (should not happen on a connected graph)

    const roadKm = path.costKm;

    let batteryPenaltyKm = 0;
    if (c.currentState === "charging") batteryPenaltyKm += cfg.chargingPenaltyKm;
    if (c.batteryLevel < cfg.lowBatteryPct) batteryPenaltyKm += cfg.lowBatteryPenaltyKm;
    else if (c.batteryLevel < cfg.midBatteryPct) batteryPenaltyKm += cfg.midBatteryPenaltyKm;

    const sizePenaltyKm = Math.max(0, c.seats - partySize) * cfg.oversizeKmPerSeat;

    const score = roadKm + batteryPenaltyKm + sizePenaltyKm;
    if (!best || score < best.score) {
      best = {
        vehicleId: c.vehicleId,
        vehicleType: c.vehicleType,
        startNode,
        route: path.path,
        roadKm,
        batteryPenaltyKm,
        sizePenaltyKm,
        score,
      };
    }
  }

  return best;
}
