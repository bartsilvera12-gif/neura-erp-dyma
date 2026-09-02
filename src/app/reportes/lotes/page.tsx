"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { ArrowLeft, RefreshCw } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { ESTADO_LOTE_UI } from "@/lib/lotes/types";
import type { EstructuraPayload } from "@/lib/lotes/types";
import type { ReporteLotesPayload } from "@/lib/reportes/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";

const fmtGs = (v: number) => `Gs. ${Math.round(v).toLocaleString("es-PY")}`;
const fmtUsd = (v: number) => `USD ${v.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`;
const fmtM2 = (v: number) => `${Math.round(v).toLocaleString("es-PY")} m²`;
const pct = (parte: number, total: number) => (total > 0 ? Math.round((parte / total) * 100) : 0);

export default function ReporteLotesPage() {
  const [data, setData] = useState<ReporteLotesPayload | null>(null);
  const [loteamientos, setLoteamientos] = useState<EstructuraPayload["loteamientos"]>([]);
  const [loteamientoId, setLoteamientoId] = useState("");
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchWithSupabaseSession("/api/lotes/estructura", { cache: "no-store" })
      .then(async (r) => {
        const j = (await r.json()) as { success?: boolean; data?: EstructuraPayload };
        if (j.success && j.data) setLoteamientos(j.data.loteamientos);
      })
      .catch(() => setLoteamientos([]));
  }, []);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const qs = loteamientoId ? `?loteamiento_id=${encodeURIComponent(loteamientoId)}` : "";
      const res = await fetchWithSupabaseSession(`/api/reportes/lotes${qs}`, { cache: "no-store" });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: ReporteLotesPayload };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudo cargar el reporte");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [loteamientoId]);

  useEffect(() => {
    void load();
  }, [load]);

  const t = data?.totales;
  const filas = useMemo(() => data?.fracciones ?? [], [data]);

  return (
    <div className="mx-auto w-full max-w-6xl space-y-6 px-4 pb-10 sm:px-6 lg:px-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link
            href="/reportes"
            className="mb-1 inline-flex items-center gap-1 text-xs font-medium text-slate-500 hover:text-[#0EA5E9]"
          >
            <ArrowLeft className="h-3.5 w-3.5" />
            Volver a Reportes
          </Link>
          <h1 className="text-2xl font-bold text-slate-900">Dashboard de ventas</h1>
          <p className="mt-0.5 text-sm text-slate-600">Lotes vendidos contra disponibles, fracción por fracción.</p>
        </div>
        <button
          type="button"
          onClick={() => void load()}
          disabled={cargando}
          className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50 disabled:opacity-50"
        >
          <RefreshCw className={`h-3.5 w-3.5 ${cargando ? "animate-spin" : ""}`} />
          Actualizar
        </button>
      </div>

      <div className="rounded-2xl border border-slate-200 bg-white p-4 sm:max-w-sm">
        <label className="mb-1 block text-xs font-medium text-slate-500">Loteamiento</label>
        <select value={loteamientoId} onChange={(e) => setLoteamientoId(e.target.value)} className={inputClass}>
          <option value="">Todos</option>
          {loteamientos.map((l) => (
            <option key={l.id} value={l.id}>
              {l.codigo} — {l.nombre}
            </option>
          ))}
        </select>
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tarjeta titulo="Lotes totales" valor={String(t?.total ?? 0)} extra={fmtM2(t?.superficie_total ?? 0)} />
        <Tarjeta
          titulo="Vendidos"
          valor={String(t?.vendido ?? 0)}
          extra={`${pct(t?.vendido ?? 0, t?.total ?? 0)}% del total`}
          punto={ESTADO_LOTE_UI.vendido.punto}
        />
        <Tarjeta
          titulo="Disponibles"
          valor={String(t?.disponible ?? 0)}
          extra={`${pct(t?.disponible ?? 0, t?.total ?? 0)}% del total`}
          punto={ESTADO_LOTE_UI.disponible.punto}
        />
        <Tarjeta
          titulo="Valor vendido"
          valor={fmtGs(t?.vendido_gs ?? 0)}
          extra={t?.vendido_usd ? fmtUsd(t.vendido_usd) : "precio de lista"}
        />
      </div>

      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[56rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50/70 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                <th className="px-4 py-3">Loteamiento</th>
                <th className="px-4 py-3">Fracción</th>
                <th className="px-4 py-3 text-right">Total</th>
                <th className="px-4 py-3 text-right">Vendidos</th>
                <th className="px-4 py-3 text-right">Disponibles</th>
                <th className="px-4 py-3 text-right">Reservados</th>
                <th className="px-4 py-3 text-right">Bloqueados</th>
                <th className="px-4 py-3">Avance</th>
                <th className="px-4 py-3 text-right">Valor vendido</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {cargando ? (
                <tr>
                  <td colSpan={9} className="px-4 py-10 text-center text-sm text-slate-400">
                    Cargando…
                  </td>
                </tr>
              ) : filas.length === 0 ? (
                <tr>
                  <td colSpan={9} className="px-4 py-10 text-center text-sm text-slate-400">
                    No hay fracciones cargadas todavía.
                  </td>
                </tr>
              ) : (
                filas.map((f) => (
                  <tr key={f.fraccion_id} className="hover:bg-slate-50/60">
                    <td className="px-4 py-3 text-slate-600">{f.loteamiento}</td>
                    <td className="px-4 py-3 font-medium text-slate-900">{f.fraccion}</td>
                    <td className="px-4 py-3 text-right tabular-nums text-slate-700">{f.total}</td>
                    <td className="px-4 py-3 text-right font-semibold tabular-nums text-sky-700">{f.vendido}</td>
                    <td className="px-4 py-3 text-right tabular-nums text-emerald-700">{f.disponible}</td>
                    <td className="px-4 py-3 text-right tabular-nums text-amber-700">{f.reservado}</td>
                    <td className="px-4 py-3 text-right tabular-nums text-slate-500">{f.bloqueado}</td>
                    <td className="px-4 py-3">
                      <BarraAvance fila={f} />
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-slate-800">
                      {f.vendido_usd > 0 ? fmtUsd(f.vendido_usd) : fmtGs(f.vendido_gs)}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
            {filas.length > 0 && t ? (
              <tfoot>
                <tr className="border-t border-slate-200 bg-slate-50/70 text-sm font-semibold text-slate-800">
                  <td className="px-4 py-3" colSpan={2}>
                    Total
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums">{t.total}</td>
                  <td className="px-4 py-3 text-right tabular-nums text-sky-700">{t.vendido}</td>
                  <td className="px-4 py-3 text-right tabular-nums text-emerald-700">{t.disponible}</td>
                  <td className="px-4 py-3 text-right tabular-nums text-amber-700">{t.reservado}</td>
                  <td className="px-4 py-3 text-right tabular-nums text-slate-500">{t.bloqueado}</td>
                  <td className="px-4 py-3 text-xs font-normal text-slate-500">{fmtM2(t.superficie_total)}</td>
                  <td className="px-4 py-3 text-right tabular-nums">{fmtGs(t.vendido_gs)}</td>
                </tr>
              </tfoot>
            ) : null}
          </table>
        </div>
      </div>
    </div>
  );
}

function Tarjeta({
  titulo,
  valor,
  extra,
  punto,
}: {
  titulo: string;
  valor: string;
  extra?: string;
  punto?: string;
}) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-4">
      <p className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-500">
        {punto ? <span className={`h-2 w-2 rounded-full ${punto}`} /> : null}
        {titulo}
      </p>
      <p className="mt-1 text-xl font-bold tabular-nums text-slate-900">{valor}</p>
      {extra ? <p className="mt-0.5 text-xs text-slate-500">{extra}</p> : null}
    </div>
  );
}

/** Barra apilada con la composición de estados de la fracción. */
function BarraAvance({
  fila,
}: {
  fila: { total: number; vendido: number; reservado: number; disponible: number; bloqueado: number };
}) {
  if (fila.total === 0) return <span className="text-xs text-slate-400">—</span>;
  const p = (n: number) => `${(n / fila.total) * 100}%`;
  return (
    <div className="min-w-[8rem]">
      <div className="flex h-2 w-full overflow-hidden rounded-full bg-slate-100">
        <div style={{ width: p(fila.vendido) }} className="bg-sky-500" title={`Vendidos: ${fila.vendido}`} />
        <div style={{ width: p(fila.reservado) }} className="bg-amber-500" title={`Reservados: ${fila.reservado}`} />
        <div
          style={{ width: p(fila.disponible) }}
          className="bg-emerald-500"
          title={`Disponibles: ${fila.disponible}`}
        />
        <div style={{ width: p(fila.bloqueado) }} className="bg-slate-400" title={`Bloqueados: ${fila.bloqueado}`} />
      </div>
      <p className="mt-1 text-[10px] text-slate-500">
        {Math.round((fila.vendido / fila.total) * 100)}% vendido
      </p>
    </div>
  );
}
