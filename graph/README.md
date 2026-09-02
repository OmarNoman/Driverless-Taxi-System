# Road network graph

`melbourne.json` is the road network the Dispatch service routes over and the Node-RED
simulator drives along. It is the single source of truth for both.

## Source

A user-supplied Melbourne suburb graph (21 landmark nodes, 36 edges). Only the topology
and coordinates are reused; the original context (cargo delivery planning, road
"bumpiness") is not. No bumpiness data was provided, so edge cost is plain distance.

The source stored coordinates as `(lon, lat)`. They are converted here to `{lat, lon}` to
match the telemetry payload shape used everywhere else in this repo.

## Shape

```json
{
  "nodes": [ { "id": 0, "name": "Melbourne CBD", "lat": -37.8135637, "lon": 144.9616326 }, ... ],
  "edges": [ [0, 1], [0, 2], ... ]
}
```

- `edges` are **undirected** pairs of node ids (roads go both ways). Duplicates are
  removed; ids in each pair are sorted ascending.
- The graph is connected (every node reachable from every other), node degree 2 to 5,
  edge lengths 3.8 to 15.1 km, ~311 km of road total.

## How it is used

- **A\* edge cost** = Haversine distance in km between the two endpoints' coordinates.
- **A\* heuristic** `h(n)` = Haversine distance from node `n` straight-line to the goal
  node (admissible and consistent).
- **Dispatch** (`services/dispatch-service/src/graph.js`) loads this file, snaps each
  available vehicle's live position to the nearest node, and runs A* from there to the
  pickup node. Ride requests name the pickup and dropoff **nodes** (by `name`).
- **Node-RED** loads this file via `settings.js` `functionGlobalContext.melbourneGraph`.
  Each simulated vehicle sits at a home node until dispatched, then follows the node
  path from the dispatch command, interpolating along each edge at road speed. The bus
  runs a fixed loop of nodes instead.
