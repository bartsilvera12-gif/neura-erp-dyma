"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { AlertTriangle, ArrowLeft, Printer, RefreshCw } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { FancySelect } from "@/components/ui/FancySelect";
import { FechaSelect } from "@/components/ui/FechaSelect";
import { BASES, rangoDelMes, type BaseReporte, type EstadoResultado } from "@/lib/reportes/estado-resultado";

const labelClass = "mb-1 block text-xs font-medium text-slate-500";

const gs = (v: number) => `Gs. ${Math.round(v).toLocaleString("es-PY")}`;
/** En las grillas el cero se deja en blanco, igual que en el formulario en papel. */
const num = (v: number) => (Math.round(v) === 0 ? "—" : Math.round(v).toLocaleString("es-PY"));
const pct = (v: number | null) => (v == null ? "—" : `${v.toLocaleString("es-PY", { maximumFractionDigits: 1 })}%`);

function fmtFecha(ymd: string): string {
  const [y, m, d] = ymd.split("-");
  return `${d}/${m}/${y}`;
}

/** Los últimos doce meses, el actual primero. */
function mesesRecientes(): { value: string; label: string }[] {
  const nombres = [
    "enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
  ];
  const hoy = new Date();
  return Array.from({ length: 12 }, (_, i) => {
    const d = new Date(hoy.getFullYear(), hoy.getMonth() - i, 1);
    const value = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
    return { value, label: `${nombres[d.getMonth()]} ${d.getFullYear()}` };
  });
}

export default function EstadoResultadoPage() {
  const meses = useMemo(mesesRecientes, []);
  const [mes, setMes] = useState(meses[0]!.value);
  const [porRango, setPorRango] = useState(false);
  const inicial = useMemo(() => rangoDelMes(meses[0]!.value), [meses]);
  const [desde, setDesde] = useState(inicial.desde);
  const [hasta, setHasta] = useState(inicial.hasta);
  const [base, setBase] = useState<BaseReporte>("percibido");

  const [data, setData] = useState<EstadoResultado | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // El mes elegido manda sobre el rango mientras no se pase a rango libre.
  const periodo = useMemo(() => (porRango ? { desde, hasta } : rangoDelMes(mes)), [porRango, desde, hasta, mes]);

  const query = useMemo(() => {
    const p = new URLSearchParams();
    p.set("desde", periodo.desde);
    p.set("hasta", periodo.hasta);
    p.set("base", base);
    return p.toString();
  }, [periodo, base]);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const res = await fetchWithSupabaseSession(`/api/reportes/estado-resultado?${query}`, { cache: "no-store" });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: EstadoResultado };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudo cargar el estado de resultado");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [query]);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="mx-auto w-full min-w-0 max-w-6xl space-y-6 px-4 pb-10 sm:px-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link
            href="/reportes"
            className="mb-1 inline-flex items-center gap-1 text-xs font-medium text-slate-500 hover:text-[#0EA5E9]"
          >
            <ArrowLeft className="h-3.5 w-3.5" />
            Volver a Reportes
          </Link>
          <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Estado de resultado</h1>
          <p className="mt-1 text-sm text-slate-500">
            Ventas, costo y gastos del período, con la ganancia al pie. En guaraníes.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => void load()}
            disabled={cargando}
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50 disabled:opacity-50"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${cargando ? "animate-spin" : ""}`} />
            Actualizar
          </button>
          <a
            href={`/api/reportes/estado-resultado/imprimir?${query}`}
            target="_blank"
            rel="noopener"
            className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7]"
          >
            <Printer className="h-3.5 w-3.5" />
            Imprimir
          </a>
        </div>
      </div>

      {/* Período y criterio */}
      <div className="rounded-2xl border border-slate-200 bg-white p-4">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <label className={labelClass}>Período</label>
            <FancySelect
              value={porRango ? "__rango__" : mes}
              onChange={(v) => {
                if (v === "__rango__") {
                  setPorRango(true);
                  return;
                }
                setPorRango(false);
                setMes(v);
                const r = rangoDelMes(v);
                setDesde(r.desde);
                setHasta(r.hasta);
              }}
              options={[...meses, { value: "__rango__", label: "Rango de fechas…" }]}
            />
          </div>
          {porRango ? (
            <>
              <div>
                <label className={labelClass}>Desde</label>
                <FechaSelect value={desde} onChange={(e) => setDesde(e.target.value)} />
              </div>
              <div>
                <label className={labelClass}>Hasta</label>
                <FechaSelect value={hasta} onChange={(e) => setHasta(e.target.value)} />
              </div>
            </>
          ) : null}
          <div className={porRango ? "" : "lg:col-span-2"}>
            <label className={labelClass}>Criterio</label>
            <FancySelect
              value={base}
              onChange={(v) => setBase(v as BaseReporte)}
              options={[
                { value: "percibido", label: BASES.percibido.label },
                { value: "devengado", label: BASES.devengado.label },
              ]}
            />
          </div>
        </div>
        <p className="mt-2 text-xs text-slate-500">{BASES[base].detalle}</p>
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      {cargando ? (
        <div className="rounded-2xl border border-slate-200 bg-white p-10 text-center text-sm text-slate-400">
          Cargando…
        </div>
      ) : !data ? null : (
        <>
          <div className="grid gap-3 sm:grid-cols-3">
            <Tarjeta titulo="Resultado bruto" valor={gs(data.resultado_bruto)} />
            <Tarjeta titulo="Gastos operativos" valor={gs(data.gastos_operativos)} />
            <Tarjeta
              titulo="Resultado neto"
              valor={gs(data.resultado_neto)}
              destacado
              negativo={data.resultado_neto < 0}
            />
          </div>

          {data.ventas_sin_costo > 0 ? (
            <div className="flex items-start gap-2.5 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              <p>
                <strong>El margen está inflado.</strong> Hay {data.ventas_sin_costo} contrato
                {data.ventas_sin_costo === 1 ? "" : "s"} con ventas en el período cuyo lote no tiene cargado el costo
                de adquisición, así que esas ventas figuran sin costo. Cargalo en la ficha del lote.
              </p>
            </div>
          ) : null}

          {/* Ventas */}
          <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
            <div className="border-b border-slate-100 px-4 py-3">
              <h2 className="text-sm font-semibold text-slate-800">Ventas del período</h2>
              <p className="text-xs text-slate-500">
                {fmtFecha(data.desde)} al {fmtFecha(data.hasta)}
              </p>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-2.5 text-left font-semibold">Cuenta</th>
                    <th className="px-4 py-2.5 text-right font-semibold">Ingreso</th>
                    <th className="px-4 py-2.5 text-right font-semibold">Costo</th>
                    <th className="px-4 py-2.5 text-right font-semibold">Utilidad</th>
                    <th className="px-4 py-2.5 text-right font-semibold">%</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {data.ventas.length === 0 ? (
                    <tr>
                      <td colSpan={5} className="px-4 py-6 text-center text-xs text-slate-400">
                        Sin ventas en el período.
                      </td>
                    </tr>
                  ) : (
                    data.ventas.map((v) => (
                      <tr key={v.concepto}>
                        <td className="px-4 py-2.5 text-slate-800">{v.concepto}</td>
                        <td className="px-4 py-2.5 text-right tabular-nums">{num(v.ingreso)}</td>
                        <td className="px-4 py-2.5 text-right tabular-nums">{num(v.costo)}</td>
                        <td className="px-4 py-2.5 text-right font-medium tabular-nums">{num(v.utilidad)}</td>
                        <td className="px-4 py-2.5 text-right tabular-nums text-slate-600">{pct(v.pct)}</td>
                      </tr>
                    ))
                  )}
                </tbody>
                <tfoot>
                  <tr className="bg-amber-50 font-semibold text-slate-900">
                    <td className="px-4 py-2.5">Total ventas del período</td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{num(data.total_ventas.ingreso)}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{num(data.total_ventas.costo)}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{num(data.total_ventas.utilidad)}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{pct(data.total_ventas.pct)}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          </div>

          {/* Gastos */}
          <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
            <div className="border-b border-slate-100 px-4 py-3">
              <h2 className="text-sm font-semibold text-slate-800">Gastos operativos por cuenta</h2>
              <p className="text-xs text-slate-500">
                El Haber recoge las correcciones cargadas en negativo. Solo se listan las cuentas con movimiento.
              </p>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-2.5 text-left font-semibold">Cuenta</th>
                    <th className="px-4 py-2.5 text-right font-semibold">Debe</th>
                    <th className="px-4 py-2.5 text-right font-semibold">Haber</th>
                    <th className="px-4 py-2.5 text-right font-semibold">Neto</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {data.gastos.length === 0 ? (
                    <tr>
                      <td colSpan={4} className="px-4 py-6 text-center text-xs text-slate-400">
                        Sin gastos cargados en el período.{" "}
                        <Link href="/gastos/nuevo" className="font-medium text-[#0EA5E9] hover:underline">
                          Cargar un gasto
                        </Link>
                      </td>
                    </tr>
                  ) : (
                    data.gastos.map((g) => (
                      <tr key={g.codigo || g.cuenta}>
                        <td className="px-4 py-2.5 text-slate-800">{g.cuenta}</td>
                        <td className="px-4 py-2.5 text-right tabular-nums">{num(g.debe)}</td>
                        <td className="px-4 py-2.5 text-right tabular-nums">{num(g.haber)}</td>
                        <td className="px-4 py-2.5 text-right font-medium tabular-nums">{num(g.neto)}</td>
                      </tr>
                    ))
                  )}
                </tbody>
                <tfoot>
                  <tr className="bg-amber-50 font-semibold text-slate-900">
                    <td className="px-4 py-2.5">Total gastos operativos</td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{num(data.total_gastos.debe)}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{num(data.total_gastos.haber)}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums">{num(data.total_gastos.neto)}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

function Tarjeta({
  titulo,
  valor,
  destacado,
  negativo,
}: {
  titulo: string;
  valor: string;
  destacado?: boolean;
  negativo?: boolean;
}) {
  return (
    <div className={`rounded-2xl border bg-white p-4 ${destacado ? "border-slate-300" : "border-slate-200"}`}>
      <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">{titulo}</p>
      <p
        className={`mt-1 text-xl font-bold tabular-nums ${
          negativo ? "text-rose-700" : destacado ? "text-emerald-700" : "text-slate-900"
        }`}
      >
        {valor}
      </p>
    </div>
  );
}
