// Week 6 - vehicle selection.
//
// Plan (p4): "make use of an A* search heuristic to determine the optimal vehicle dispatch
// and the Haversine formula [...] to calculate the distances."
//
// There is no road network in this project, so A* is applied as its cost model rather than
// as graph search: each available vehicle is scored f(v) = g(v) + h(v), and the minimum is
// chosen.
//   h(v) = Haversine distance from the vehicle to the pickup  (admissible heuristic, km)
//   g(v) = real-cost term, in km-equivalent penalties:
//            + low / mid battery penalty   (a near-flat taxi is a poor choice)
//            + moving penalty              (a parked taxi dispatches more cleanly)

export const DEFAULTS = {
  lowBatteryPct: 20,
  lowBatteryPenaltyKm: 5,
  midBatteryPct: 40,
  midBatteryPenaltyKm: 2,
  movingPenaltyKm: 1,
};

const R_KM = 6371;
const toRad = (deg) => (deg * Math.PI) / 180;

export function haversineKm(a, b) {
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R_KM * Math.asin(Math.sqrt(s));
}

function gCost(v, cfg) {
  let g = 0;
  if (v.batteryLevel < cfg.lowBatteryPct) g += cfg.lowBatteryPenaltyKm;
  else if (v.batteryLevel < cfg.midBatteryPct) g += cfg.midBatteryPenaltyKm;
  if (v.currentState === "driving") g += cfg.movingPenaltyKm;
  return g;
}

// candidates: [{ vehicleId, lat, lon, batteryLevel, currentState }]
// pickup:     { lat, lon }
// returns the best { vehicleId, h, g, f, distanceKm, batteryLevel } or null
export function selectVehicle(candidates, pickup, opts = {}) {
  const cfg = { ...DEFAULTS, ...opts };
  let best = null;
  for (const v of candidates) {
    const h = haversineKm({ lat: v.lat, lon: v.lon }, pickup);
    const g = gCost(v, cfg);
    const f = g + h;
    if (!best || f < best.f) {
      best = { vehicleId: v.vehicleId, h, g, f, distanceKm: h, batteryLevel: v.batteryLevel };
    }
  }
  return best;
}
