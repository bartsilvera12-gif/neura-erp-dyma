"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { ArrowLeft, FileDown, RefreshCw } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { FancySelect } from "@/components/ui/FancySelect";
import MontoInput from "@/components/ui/MontoInput";
import { ESTADO_LOTE_UI, ESTADOS_LOTE, type EstructuraPayload, type Lote } from "@/lib/lotes/types";
import {
  plantillaReportePrecios,
  type FilaReportePrecio,
} from "@/lib/lotes/plantilla-reporte-precios";

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25";
const labelClass = "mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-500";

const gs = (v: number | null): string => (v == null ? "—" : `Gs. ${Math.round(v).toLocaleString("es-PY")}`);
const usdFmt = (v: number | null): string =>
  v == null ? "—" : `USD ${Number(v).toLocaleString("es-PY", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

function hoyYmd(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Asuncion",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

/** Primer número del código de lote, para ordenar y filtrar por rango. */
function numLote(numero: string): number | null {
  const m = /\d+/.exec(numero ?? "");
  return m ? Number(m[0]) : null;
}

export default function ReportePreciosClient() {
  const [estructura, setEstructura] = useState<EstructuraPayload | null>(null);
  const [lotes, setLotes] = useState<Lote[]>([]);
  const [cargandoEstructura, setCargandoEstructura] = useState(true);
  const [cargandoLotes, setCargandoLotes] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [loteamientoId, setLoteamientoId] = useState("");
  const [fraccionId, setFraccionId] = useState("");
  const [manzanaId, setManzanaId] = useState("");
  const [estado, setEstado] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [cotizacion, setCotizacion] = useState("");
  const [incluirFinanciado, setIncluirFinanciado] = useState(false);

  useEffect(() => {
    (async () => {
      setCargandoEstructura(true);
      try {
        const res = await fetchWithSupabaseSession("/api/lotes/estructura", { cache: "no-store" });
        const json = (await res.json()) as { success?: boolean; error?: string; data?: EstructuraPayload };
        if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
        setEstructura(json.data);
      } catch (e) {
        setError(e instanceof Error ? e.message : "No se pudo cargar la estructura");
      } finally {
        setCargandoEstructura(false);
      }
    })();
  }, []);

  // Cada vez que cambia la urbanización se traen sus lotes; el resto se filtra en el cliente.
  const cargarLotes = useCallback(async () => {
    if (!loteamientoId) {
      setLotes([]);
      return;
    }
    setCargandoLotes(true);
    setError(null);
    try {
      const res = await fetchWithSupabaseSession(
        `/api/lotes?loteamiento_id=${encodeURIComponent(loteamientoId)}`,
        { cache: "no-store" }
      );
      const json = (await res.json()) as { success?: boolean; error?: string; data?: { lotes?: Lote[] } };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setLotes(json.data.lotes ?? []);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudieron cargar los lotes");
      setLotes([]);
    } finally {
      setCargandoLotes(false);
    }
  }, [loteamientoId]);

  useEffect(() => {
    void cargarLotes();
  }, [cargarLotes]);

  const fraccionesDe = useMemo(
    () => (estructura?.fracciones ?? []).filter((f) => f.loteamiento_id === loteamientoId),
    [estructura, loteamientoId]
  );
  // Manzanas de la fracción elegida; si no hay fracción, las de todas las fracciones de la urbanización.
  const manzanasDe = useMemo(() => {
    const fraccIds = fraccionId ? [fraccionId] : fraccionesDe.map((f) => f.id);
    return (estructura?.manzanas ?? []).filter((m) => fraccIds.includes(m.fraccion_id));
  }, [estructura, fraccionId, fraccionesDe]);

  // Mapa manzana_id -> { codigo manzana, fraccion_id } para columna y filtros.
  const manzanaInfo = useMemo(() => {
    const map = new Map<string, { codigo: string; fraccionId: string }>();
    for (const m of estructura?.manzanas ?? []) map.set(m.id, { codigo: m.codigo, fraccionId: m.fraccion_id });
    return map;
  }, [estructura]);

  const cot = Number(cotizacion) > 0 ? Number(cotizacion) : null;

  const filas: FilaReportePrecio[] = useMemo(() => {
    const d = desde.trim() ? Number(desde) : null;
    const h = hasta.trim() ? Number(hasta) : null;
    const fraccIdsVisibles = fraccionId ? [fraccionId] : fraccionesDe.map((f) => f.id);

    return lotes
      .filter((l) => {
        const info = manzanaInfo.get(l.manzana_id);
        if (manzanaId) {
          if (l.manzana_id !== manzanaId) return false;
        } else if (fraccionId && (!info || !fraccIdsVisibles.includes(info.fraccionId))) {
          return false;
        }
        if (estado && l.estado !== estado) return false;
        const n = numLote(l.numero);
        if (d != null && (n == null || n < d)) return false;
        if (h != null && (n == null || n > h)) return false;
        return true;
      })
      .sort((a, b) => {
        const na = numLote(a.numero);
        const nb = numLote(b.numero);
        if (na != null && nb != null && na !== nb) return na - nb;
        return a.numero.localeCompare(b.numero, "es", { numeric: true });
      })
      .map((l) => {
        const esUsd = l.moneda === "USD";
        const convGs = (v: number | null) => (v == null ? null : esUsd ? (cot ? v * cot : null) : v);
        const convUsd = (v: number | null) => (v == null ? null : esUsd ? v : cot ? v / cot : null);
        return {
          numero: l.numero,
          manzana: manzanaInfo.get(l.manzana_id)?.codigo ?? "",
          superficie_m2: l.superficie_m2,
          contado_gs: convGs(l.precio_contado),
          contado_usd: convUsd(l.precio_contado),
          financiado_gs: convGs(l.precio_financiado),
          financiado_usd: convUsd(l.precio_financiado),
          estado_label: ESTADO_LOTE_UI[l.estado].label,
        };
      });
  }, [lotes, manzanaInfo, manzanaId, fraccionId, fraccionesDe, estado, desde, hasta, cot]);

  const urbanizacion = estructura?.loteamientos.find((x) => x.id === loteamientoId)?.nombre ?? "";

  function textoFiltro(): string | null {
    const partes: string[] = [];
    if (fraccionId) partes.push(`Fracción ${fraccionesDe.find((f) => f.id === fraccionId)?.codigo ?? ""}`.trim());
    if (manzanaId) partes.push(`Manzana ${manzanaInfo.get(manzanaId)?.codigo ?? ""}`.trim());
    if (estado) partes.push(ESTADO_LOTE_UI[estado as (typeof ESTADOS_LOTE)[number]].label);
    if (desde.trim() || hasta.trim()) partes.push(`Lotes ${desde.trim() || "1"} al ${hasta.trim() || "…"}`);
    return partes.length ? partes.join(" · ") : null;
  }

  function verPdf() {
    const html = plantillaReportePrecios({
      urbanizacion,
      filtro: textoFiltro(),
      cotizacion: cot,
      emitida: hoyYmd(),
      incluir_financiado: incluirFinanciado,
      filas,
    });
    const w = window.open("", "_blank");
    if (w) {
      w.document.write(html);
      w.document.close();
    }
  }

  return (
    <div className="w-full min-w-0 max-w-full space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link
            href="/lotes"
            className="mb-1 inline-flex items-center gap-1 text-xs font-medium text-slate-500 hover:text-[#0EA5E9]"
          >
            <ArrowLeft className="h-3.5 w-3.5" />
            Volver a Lotes
          </Link>
          <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Reporte de precios</h1>
          <p className="mt-1 text-sm text-slate-500">
            Elegí una urbanización y generá la lista de precios de los lotes, en orden, con guaraníes y dólares.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void cargarLotes()}
          disabled={!loteamientoId || cargandoLotes}
          className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50 disabled:opacity-50"
        >
          <RefreshCw className="h-3.5 w-3.5" />
          Actualizar
        </button>
      </div>

      {/* Filtros */}
      <div className="space-y-4 rounded-2xl border border-slate-200 bg-white p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div>
            <label className={labelClass}>Urbanización</label>
            <FancySelect
              value={loteamientoId}
              onChange={(v) => {
                setLoteamientoId(v);
                setFraccionId("");
                setManzanaId("");
              }}
              options={[
                { value: "", label: cargandoEstructura ? "Cargando…" : "Elegí una urbanización" },
                ...(estructura?.loteamientos ?? []).map((l) => ({ value: l.id, label: l.nombre })),
              ]}
            />
          </div>
          <div>
            <label className={labelClass}>
              Fracción <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <FancySelect
              value={fraccionId}
              onChange={(v) => {
                setFraccionId(v);
                setManzanaId("");
              }}
              options={[
                { value: "", label: "Todas" },
                ...fraccionesDe.map((f) => ({ value: f.id, label: f.nombre ? `${f.codigo} — ${f.nombre}` : f.codigo })),
              ]}
            />
          </div>
          <div>
            <label className={labelClass}>
              Manzana <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <FancySelect
              value={manzanaId}
              onChange={setManzanaId}
              options={[
                { value: "", label: "Todas" },
                ...manzanasDe.map((m) => ({ value: m.id, label: m.nombre ? `${m.codigo} — ${m.nombre}` : m.codigo })),
              ]}
            />
          </div>
          <div>
            <label className={labelClass}>
              Estado <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <FancySelect
              value={estado}
              onChange={setEstado}
              options={[
                { value: "", label: "Todos" },
                ...ESTADOS_LOTE.map((e) => ({ value: e, label: ESTADO_LOTE_UI[e].label })),
              ]}
            />
          </div>
          <div>
            <label className={labelClass}>
              Lote desde <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input
              type="number"
              min={0}
              value={desde}
              onChange={(e) => setDesde(e.target.value)}
              placeholder="Ej: 1"
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>
              Lote hasta <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input
              type="number"
              min={0}
              value={hasta}
              onChange={(e) => setHasta(e.target.value)}
              placeholder="Ej: 40"
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>
              Cotización (Gs por 1 USD) <span className="font-normal text-slate-400">(para ver USD)</span>
            </label>
            <MontoInput
              value={cotizacion}
              onChange={(n) => setCotizacion(String(n))}
              decimals={false}
              onFocus={(e) => e.currentTarget.select()}
              className={inputClass}
            />
          </div>
        </div>

        <label className="flex items-center gap-2 text-xs font-medium text-slate-600">
          <input
            type="checkbox"
            checked={incluirFinanciado}
            onChange={(e) => setIncluirFinanciado(e.target.checked)}
            className="h-3.5 w-3.5"
          />
          Incluir también el precio financiado
        </label>

        {error ? <p className="text-xs text-rose-600">{error}</p> : null}

        <div className="flex justify-end">
          <button
            type="button"
            onClick={verPdf}
            disabled={!loteamientoId || filas.length === 0}
            className="inline-flex items-center gap-1.5 rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            <FileDown className="h-3.5 w-3.5" />
            Ver / descargar PDF
          </button>
        </div>
      </div>

      {/* Vista previa */}
      {!loteamientoId ? (
        <div className="rounded-2xl border border-slate-200 bg-slate-50/60 px-4 py-12 text-center text-sm text-slate-400">
          Elegí una urbanización para ver la lista de precios.
        </div>
      ) : cargandoLotes ? (
        <p className="py-16 text-center text-sm text-slate-400">Cargando lotes…</p>
      ) : filas.length === 0 ? (
        <div className="rounded-2xl border border-slate-200 bg-slate-50/60 px-4 py-12 text-center text-sm text-slate-400">
          No hay lotes para los filtros elegidos.
        </div>
      ) : (
        <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
          <div className="border-b border-slate-200 bg-slate-50/70 px-4 py-3">
            <p className="text-sm font-bold text-slate-900">{urbanizacion}</p>
            <p className="text-[11px] text-slate-500">
              {filas.length} lote{filas.length === 1 ? "" : "s"}
              {textoFiltro() ? ` · ${textoFiltro()}` : ""}
              {cot ? ` · Cotización Gs. ${Math.round(cot).toLocaleString("es-PY")}` : " · Sin cotización (solo Gs)"}
            </p>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[46rem] text-sm">
              <thead>
                <tr className="border-b border-slate-200 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                  <th className="px-4 py-2.5">Lote</th>
                  <th className="px-4 py-2.5">Manzana</th>
                  <th className="px-4 py-2.5 text-right">Superficie</th>
                  <th className="px-4 py-2.5 text-right">Contado Gs</th>
                  {cot ? <th className="px-4 py-2.5 text-right">Contado USD</th> : null}
                  {incluirFinanciado ? <th className="px-4 py-2.5 text-right">Financiado Gs</th> : null}
                  {incluirFinanciado && cot ? <th className="px-4 py-2.5 text-right">Financiado USD</th> : null}
                  <th className="px-4 py-2.5">Estado</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {filas.map((f, i) => (
                  <tr key={`${f.numero}-${i}`} className="hover:bg-slate-50/60">
                    <td className="px-4 py-2 font-semibold text-slate-900">{f.numero}</td>
                    <td className="px-4 py-2 text-slate-600">{f.manzana || "—"}</td>
                    <td className="px-4 py-2 text-right tabular-nums text-slate-600">
                      {f.superficie_m2 == null ? "—" : `${f.superficie_m2.toLocaleString("es-PY")} m²`}
                    </td>
                    <td className="px-4 py-2 text-right font-semibold tabular-nums text-slate-900">{gs(f.contado_gs)}</td>
                    {cot ? <td className="px-4 py-2 text-right tabular-nums text-slate-700">{usdFmt(f.contado_usd)}</td> : null}
                    {incluirFinanciado ? (
                      <td className="px-4 py-2 text-right tabular-nums text-slate-700">{gs(f.financiado_gs)}</td>
                    ) : null}
                    {incluirFinanciado && cot ? (
                      <td className="px-4 py-2 text-right tabular-nums text-slate-700">{usdFmt(f.financiado_usd)}</td>
                    ) : null}
                    <td className="px-4 py-2">
                      <span className="text-[11px] text-slate-500">{f.estado_label}</span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
