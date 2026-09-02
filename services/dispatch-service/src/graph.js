// The Melbourne road-network graph and A* over it.
//
// Nodes are the suburb landmarks in graph/melbourne.json; edges are undirected roads whose
// cost is the Haversine distance in km between the endpoints. A* uses Haversine straight-
// line to the goal node as its heuristic (admissible and consistent). The graph is tiny
// (21 nodes), so the open set is a plain scan.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
export const GRAPH_PATH =
  process.env.GRAPH_PATH || resolve(here, "../../../graph/melbourne.json");

const R_KM = 6371;
const rad = (d) => (d * Math.PI) / 180;

export function haversineKm(a, b) {
  const dLat = rad(b.lat - a.lat);
  const dLon = rad(b.lon - a.lon);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R_KM * Math.asin(Math.sqrt(s));
}

export function loadGraph(path = GRAPH_PATH) {
  const raw = JSON.parse(readFileSync(path, "utf8"));
  const node = new Map(raw.nodes.map((n) => [n.id, n]));
  const byName = new Map(raw.nodes.map((n) => [n.name.toLowerCase(), n.id]));
  const adj = new Map(raw.nodes.map((n) => [n.id, []]));
  for (const [a, b] of raw.edges) {
    const w = haversineKm(node.get(a), node.get(b));
    adj.get(a).push([b, w]);
    adj.get(b).push([a, w]);
  }
  return new RoadGraph(node, byName, adj);
}

export class RoadGraph {
  constructor(node, byName, adj) {
    this.node = node;
    this.byName = byName;
    this.adj = adj;
  }

  name(id) {
    return this.node.get(id)?.name ?? null;
  }

  names() {
    return [...this.node.values()].map((n) => n.name);
  }

  // resolve a landmark name (case-insensitive, trimmed) to its node id, or null
  idByName(name) {
    return this.byName.get(String(name).trim().toLowerCase()) ?? null;
  }

  // snap a {lat, lon} to the id of the closest landmark
  nearestNode(pos) {
    let best = null;
    let bestD = Infinity;
    for (const n of this.node.values()) {
      const d = haversineKm(pos, n);
      if (d < bestD) {
        bestD = d;
        best = n.id;
      }
    }
    return best;
  }

  // A* from startId to goalId. Returns { path: [ids], costKm } or null if unreachable.
  aStar(startId, goalId) {
    if (startId === goalId) return { path: [startId], costKm: 0 };
    const goal = this.node.get(goalId);
    const g = new Map([[startId, 0]]);
    const f = new Map([[startId, haversineKm(this.node.get(startId), goal)]]);
    const cameFrom = new Map();
    const open = new Set([startId]);

    while (open.size) {
      let cur = null;
      let curF = Infinity;
      for (const id of open) {
        const fi = f.get(id) ?? Infinity;
        if (fi < curF) {
          curF = fi;
          cur = id;
        }
      }

      if (cur === goalId) {
        const path = [cur];
        while (cameFrom.has(path[0])) path.unshift(cameFrom.get(path[0]));
        return { path, costKm: g.get(goalId) };
      }

      open.delete(cur);
      for (const [nb, w] of this.adj.get(cur)) {
        const tentative = g.get(cur) + w;
        if (tentative < (g.get(nb) ?? Infinity)) {
          cameFrom.set(nb, cur);
          g.set(nb, tentative);
          f.set(nb, tentative + haversineKm(this.node.get(nb), goal));
          open.add(nb);
        }
      }
    }
    return null;
  }
}
