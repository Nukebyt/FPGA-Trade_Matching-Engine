import { createChart, LineSeries, type IChartApi, type ISeriesApi, type UTCTimestamp } from "lightweight-charts";
import { useEffect, useMemo, useRef, useState } from "react";
import type { FpgaLatencyWindow } from "../types";

// Phase 26/27's four-way comparison, kept deliberately as three SEPARATE
// mini-charts rather than one shared-axis chart - row3 is raw clock
// cycles, rows 2/4 are nanoseconds, and converting cycles to ns would
// assume the nominal (not yet TimeQuest-closed) 50MHz clock as fact -
// see docs/fpga-performance.md. Three single-axis small multiples, not
// a dual-axis chart (see dataviz skill: "never a dual-axis chart").
const ROW_SPECS = [
  {
    key: "row2" as const,
    label: "ARM software reference",
    detail: "Bounded matching engine, native Cortex-A9 — baseline for row 3",
    unit: "ns",
    color: "#3987e5", // dataviz categorical slot 1 (blue), dark-mode step - this dashboard is dark-only
    p50: (w: FpgaLatencyWindow) => w.row2_p50_ns,
    p99: (w: FpgaLatencyWindow) => w.row2_p99_ns,
  },
  {
    key: "row3" as const,
    label: "FPGA fabric-internal",
    detail: "LATENCY_CYCLES register, raw cycles — direct vs. row 2",
    unit: "cycles",
    color: "#d95926", // dataviz categorical slot 2 (orange)
    p50: (w: FpgaLatencyWindow) => w.row3_p50_cycles,
    p99: (w: FpgaLatencyWindow) => w.row3_p99_cycles,
  },
  {
    key: "row4" as const,
    label: "FPGA HPS round-trip",
    detail: "Whole LWH2F bridge hop — the honest deployed-today number",
    unit: "ns",
    color: "#199e70", // dataviz categorical slot 3 (aqua)
    p50: (w: FpgaLatencyWindow) => w.row4_p50_ns,
    p99: (w: FpgaLatencyWindow) => w.row4_p99_ns,
  },
];

const MAX_POINTS = 120; // ~60s of rolling history at the harness's 500ms cadence

function formatValue(v: number, unit: string): string {
  if (unit === "cycles") return v.toFixed(1);
  if (v >= 1000) return `${(v / 1000).toFixed(2)}µs`;
  return `${v.toFixed(0)}ns`;
}

interface Point {
  t: number; // unix seconds
  p50: number;
  p99: number;
}

function RowChart({ spec, points }: { spec: (typeof ROW_SPECS)[number]; points: Point[] }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const p50SeriesRef = useRef<ISeriesApi<"Line"> | null>(null);
  const p99SeriesRef = useRef<ISeriesApi<"Line"> | null>(null);
  const tooltipRef = useRef<HTMLDivElement>(null);

  // Chart/series creation once per mount - same reasoning as
  // CandlestickChart.tsx (re-creating on every data update would drop
  // zoom/scroll state). Colors are literal hex, hand-kept in sync with
  // ROW_SPECS above and index.css's tokens for the chrome (chart takes
  // literal values, not CSS custom properties - lightweight-charts
  // limitation, same as CandlestickChart.tsx).
  useEffect(() => {
    if (!containerRef.current) return;

    const chart = createChart(containerRef.current, {
      layout: { background: { color: "#18181a" }, textColor: "#8f8d87", fontFamily: "IBM Plex Mono, monospace" },
      grid: { vertLines: { color: "#2b2b2f" }, horzLines: { color: "#2b2b2f" } },
      width: containerRef.current.clientWidth,
      height: 130,
      timeScale: { timeVisible: true, secondsVisible: true },
      rightPriceScale: { borderColor: "#2b2b2f" },
      crosshair: { horzLine: { visible: false }, vertLine: { color: "#3a3a3f", width: 1 } },
    });

    // p50 = the row's own color, solid. p99 = the same hue lightened
    // (not a second categorical color - p50/p99 are two views of the
    // SAME series, not two different identities, so this stays a
    // one-hue encoding rather than borrowing another slot).
    const p50Series = chart.addSeries(LineSeries, {
      color: spec.color,
      lineWidth: 2,
      priceLineVisible: false,
      lastValueVisible: false,
      title: "p50",
    });
    const p99Series = chart.addSeries(LineSeries, {
      color: `${spec.color}80`, // ~50% alpha - lighter tint of the same hue
      lineWidth: 2,
      priceLineVisible: false,
      lastValueVisible: false,
      title: "p99",
    });

    chartRef.current = chart;
    p50SeriesRef.current = p50Series;
    p99SeriesRef.current = p99Series;

    // Hover layer (dataviz skill: ship a crosshair+tooltip by default,
    // not as an upgrade). One tooltip, both series, at the crosshair's
    // X - values lead, series name follows.
    chart.subscribeCrosshairMove((param) => {
      const tooltip = tooltipRef.current;
      if (!tooltip) return;
      if (!param.time || !param.point) {
        tooltip.style.opacity = "0";
        return;
      }
      const p50Data = param.seriesData.get(p50Series) as { value: number } | undefined;
      const p99Data = param.seriesData.get(p99Series) as { value: number } | undefined;
      if (!p50Data && !p99Data) {
        tooltip.style.opacity = "0";
        return;
      }
      tooltip.style.opacity = "1";
      tooltip.style.left = `${Math.min(param.point.x + 8, containerRef.current!.clientWidth - 100)}px`;
      tooltip.innerHTML = "";
      if (p50Data) {
        const row = document.createElement("div");
        row.className = "fpga-tooltip-row";
        const key = document.createElement("span");
        key.className = "fpga-tooltip-key";
        key.style.background = spec.color;
        const value = document.createElement("span");
        value.textContent = `p50 ${formatValue(p50Data.value, spec.unit)}`;
        row.append(key, value);
        tooltip.append(row);
      }
      if (p99Data) {
        const row = document.createElement("div");
        row.className = "fpga-tooltip-row";
        const key = document.createElement("span");
        key.className = "fpga-tooltip-key";
        key.style.background = `${spec.color}80`;
        const value = document.createElement("span");
        value.textContent = `p99 ${formatValue(p99Data.value, spec.unit)}`;
        row.append(key, value);
        tooltip.append(row);
      }
    });

    const resize = () => {
      if (containerRef.current) chart.applyOptions({ width: containerRef.current.clientWidth });
    };
    window.addEventListener("resize", resize);

    return () => {
      window.removeEventListener("resize", resize);
      chart.remove();
      chartRef.current = null;
      p50SeriesRef.current = null;
      p99SeriesRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!p50SeriesRef.current || !p99SeriesRef.current || points.length === 0) return;
    p50SeriesRef.current.setData(points.map((p) => ({ time: p.t as UTCTimestamp, value: p.p50 })));
    p99SeriesRef.current.setData(points.map((p) => ({ time: p.t as UTCTimestamp, value: p.p99 })));
  }, [points]);

  return (
    <div className="fpga-row-chart-wrap">
      <div ref={containerRef} />
      <div ref={tooltipRef} className="fpga-tooltip" style={{ opacity: 0 }} />
    </div>
  );
}

interface Props {
  latest: FpgaLatencyWindow | null;
  history: FpgaLatencyWindow[] | null; // newest-first, as returned by the REST endpoint
  connected: boolean;
}

export function FpgaLatencyComparison({ latest, history, connected }: Props) {
  // Rolling buffer per row, seeded once from REST history (real
  // Postgres received_at timestamps) and then appended from live WS
  // pushes (client arrival time - the DE10 board's own
  // window_end_unix_ns is not NTP-synced, so it's never plotted, only
  // ever used upstream as Postgres's idempotency key - see types.ts).
  const [buffers, setBuffers] = useState<Record<string, Point[]>>({ row2: [], row3: [], row4: [] });
  const seededRef = useRef(false);
  const lastWindowEndRef = useRef<number | null>(null);

  useEffect(() => {
    if (seededRef.current || !history || history.length === 0) return;
    seededRef.current = true;
    const oldestFirst = [...history].reverse();
    setBuffers((prev) => {
      const next = { ...prev };
      for (const spec of ROW_SPECS) {
        next[spec.key] = oldestFirst.map((w) => ({
          t: Math.floor((w.received_at_unix_ns ?? Date.now() * 1e6) / 1e9),
          p50: spec.p50(w),
          p99: spec.p99(w),
        }));
      }
      return next;
    });
  }, [history]);

  useEffect(() => {
    if (!latest || latest.window_end_unix_ns === lastWindowEndRef.current) return;
    lastWindowEndRef.current = latest.window_end_unix_ns;
    const t = Math.floor(Date.now() / 1000);
    setBuffers((prev) => {
      const next: Record<string, Point[]> = {};
      for (const spec of ROW_SPECS) {
        const appended = [...prev[spec.key], { t, p50: spec.p50(latest), p99: spec.p99(latest) }];
        next[spec.key] = appended.length > MAX_POINTS ? appended.slice(appended.length - MAX_POINTS) : appended;
      }
      return next;
    });
  }, [latest]);

  const sampleCount = latest?.sample_count ?? null;
  const row2Reject = latest?.row2_reject_pct ?? null;
  const row34Reject = latest?.row34_reject_pct ?? null;

  const rowCards = useMemo(
    () =>
      ROW_SPECS.map((spec) => {
        const p50 = latest ? formatValue(spec.p50(latest), spec.unit) : "—";
        const p99 = latest ? formatValue(spec.p99(latest), spec.unit) : "—";
        return (
          <div className="fpga-row-card" key={spec.key}>
            <div className="fpga-row-title">
              <span className="series-dot" style={{ background: spec.color }} />
              <span>{spec.label}</span>
            </div>
            <div className="fpga-row-detail">{spec.detail}</div>
            <div className="metric-grid">
              <div className="metric">
                <span className="metric-label">p50 ({spec.unit})</span>
                <span className="metric-value">{p50}</span>
              </div>
              <div className="metric">
                <span className="metric-label">p99 ({spec.unit})</span>
                <span className="metric-value">{p99}</span>
              </div>
            </div>
            <RowChart spec={spec} points={buffers[spec.key]} />
          </div>
        );
      }),
    [latest, buffers],
  );

  return (
    <div className="panel fpga-latency-comparison">
      <div className="panel-header">
        <span>FPGA vs ARM Latency Comparison</span>
        <span
          className={connected ? "ws-dot ws-dot-live" : "ws-dot ws-dot-dead"}
          title={connected ? "WS connected" : "WS disconnected"}
        />
      </div>
      {!latest && (!history || history.length === 0) ? (
        <div className="waiting">waiting for fpga_latency_harness data (board must be running it)...</div>
      ) : (
        <>
          <div className="fpga-row-grid">{rowCards}</div>
          <div className="fpga-context-row">
            {sampleCount !== null ? <span>{sampleCount.toLocaleString()} orders in last window</span> : null}
            {row2Reject !== null ? <span>row2 reject {row2Reject.toFixed(1)}%</span> : null}
            {row34Reject !== null ? <span>rows 3/4 reject {row34Reject.toFixed(1)}%</span> : null}
          </div>
        </>
      )}
    </div>
  );
}
