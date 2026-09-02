import { useEffect, useState } from "react";
import { WS_API_BASE } from "../config";
import type { FpgaLatencyWindow } from "../types";

const RECONNECT_DELAY_MS = 2000;

// Same shape as useTopOfBook.ts, but simpler: FPGA_LATENCY is one
// reserved pseudo-symbol on the existing subscribe protocol (not a
// real instrument), and the pushed snapshot is a single global value,
// not a map keyed by symbol - see api/src/websocket_server.cpp's
// kFpgaLatencyPseudoSymbol.
export function useFpgaLatency(): { latest: FpgaLatencyWindow | null; connected: boolean } {
  const [latest, setLatest] = useState<FpgaLatencyWindow | null>(null);
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let socket: WebSocket | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

    function connect() {
      if (cancelled) return;
      socket = new WebSocket(WS_API_BASE);

      socket.onopen = () => {
        setConnected(true);
        socket?.send(JSON.stringify({ action: "subscribe", symbols: "FPGA_LATENCY" }));
      };

      socket.onmessage = (event) => {
        try {
          setLatest(JSON.parse(event.data) as FpgaLatencyWindow);
        } catch {
          // malformed push dropped, fail-soft - same as useTopOfBook
        }
      };

      socket.onclose = () => {
        setConnected(false);
        if (!cancelled) reconnectTimer = setTimeout(connect, RECONNECT_DELAY_MS);
      };

      socket.onerror = () => {
        socket?.close();
      };
    }

    connect();

    return () => {
      cancelled = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, []);

  return { latest, connected };
}
