# Software integration — reference copies

This directory holds **read-only reference copies** of the files that
connect this repo's FPGA core into the
[Low-Latency-Trading-Exchange](https://github.com/Nukebyt/Low-Latency-Trading-Exchange)
project's live Kafka/Postgres/Redis/API/dashboard stack. They're kept
here so this repo is browsable on its own, without also needing that
one open — but they are **not built from here**, and editing a copy in
this directory has no effect on the running system.

The software repo is the buildable, live source of truth for everything
below:

| Copy here | Live original |
|---|---|
| `fpga-latency/` (full module: `FpgaLatencyCache`, `fpga_latency_forwarder`) | [`fpga-latency/`](https://github.com/Nukebyt/Low-Latency-Trading-Exchange/tree/master/fpga-latency) |
| `frontend/useFpgaLatency.ts` | [`frontend/src/hooks/useFpgaLatency.ts`](https://github.com/Nukebyt/Low-Latency-Trading-Exchange/blob/master/frontend/src/hooks/useFpgaLatency.ts) |
| `frontend/FpgaLatencyComparison.tsx` | [`frontend/src/components/FpgaLatencyComparison.tsx`](https://github.com/Nukebyt/Low-Latency-Trading-Exchange/blob/master/frontend/src/components/FpgaLatencyComparison.tsx) |

Not copied here, since they're small, targeted edits deep inside files
that otherwise belong entirely to the software project (copying them in
isolation would be more confusing than useful) — see these paths in the
software repo directly if you need the full wiring:

- `CMakeLists.txt`, `api/CMakeLists.txt` — added `fpga-latency` as a
  subdirectory/link dependency
- `docker/kafka/create-topics.sh`, `docker/postgres/schema.sql` — the
  `fpga-latency`/`fpga-latency-dlq` Kafka topics and the
  `fpga_latency_windows` Postgres table
- `kafka/include/kafka_client/topics.hpp` — the `kFpgaLatency` topic
  constant
- `persistence/include/persistence/{record_types.hpp,event_parsing.hpp}`,
  `persistence/src/{event_parsing.cpp,postgres_writer.cpp}`,
  `persistence/include/persistence/postgres_writer.hpp`,
  `persistence/src/main.cpp` — the `FpgaLatencyWindowRecord` batcher/
  writer wiring
- `api/include/api/postgres_reader.hpp`, `api/src/postgres_reader.cpp` —
  `get_fpga_latency_history()`
- `api/src/rest_server.cpp` — `GET /api/fpga-latency/history`
- `api/include/api/websocket_server.hpp`, `api/src/websocket_server.cpp` —
  the `"FPGA_LATENCY"` reserved pseudo-symbol on the WebSocket subscribe
  protocol
- `api/src/main.cpp` — constructs `FpgaLatencyCache` and wires it into
  `WebSocketServer`
- `frontend/src/{types.ts,api.ts,App.tsx,App.css}` — the type, fetch
  helper, and panel-mounting additions

See [`docs/fpga-matching-engine.md`](../docs/fpga-matching-engine.md)
for the full data-flow diagram this all implements.
