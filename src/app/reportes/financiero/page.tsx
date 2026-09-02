"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { ArrowLeft, RefreshCw } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { FechaSelect } from "@/components/ui/FechaSelect";
import { TRAMO_MORA_UI, type FinancieroPayload } from "@/lib/reportes/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";
const labelClass = "block text-xs font-medium text-slate-500 mb-1";

const fmtGs = (v: number) => `Gs. ${Math.round(v).toLocaleString("es-PY")}`;

function fmtFecha(ymd: string | null): string {
  if (!ymd) return "—";
  const [y, m, d] = ymd.split("-");
  return `${d}/${m}/${y}`;
}

function nombreMes(mes: string): string {
  const [y, m] = mes.split("-");
  const nombres = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
  return `${nombres[Number(m) - 1] ?? m} ${y}`;
}

/** Primer día de hace 5 meses y último del mes actual: medio año de flujo. */
function rangoPorDefecto(): { desde: string; hasta: string } {
  const hoy = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  const ini = new Date(hoy.getFullYear(), hoy.getMonth() - 5, 1);
  const fin = new Date(hoy.getFullYear(), hoy.getMonth() + 1, 0);
  return {
    desde: `${ini.getFullYear()}-${p(ini.getMonth() + 1)}-01`,
    hasta: `${fin.getFullYear()}-${p(fin.getMonth() + 1)}-${p(fin.getDate())}`,
  };
}

export default function ReporteFinancieroPage() {
  const inicial = useMemo(rangoPorDefecto, []);
  const [desde, setDesde] = useState(inicial.desde);
  const [hasta, setHasta] = useState(inicial.hasta);
  const [data, setData] = useState<FinancieroPayload | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const params = new URLSearchParams();
      if (desde) params.set("desde", desde);
      if (hasta) params.set("hasta", hasta);
      const res = await fetchWithSupabaseSession(`/api/reportes/financiero?${params.toString()}`, {
        cache: "no-store",
      });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: FinancieroPayload };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudo cargar el reporte");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [desde, hasta]);

  useEffect(() => {
    void load();
  }, [load]);

  const r = data?.resumen;
  const maxFlujo = Math.max(1, ...(data?.flujo ?? []).map((m) => Math.max(m.cobrado, m.egresos)));
  const maxProy = Math.max(1, ...(data?.proyeccion ?? []).map((t) => t.monto));

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
          <h1 className="text-2xl font-bold text-slate-900">Flujo, proyección y mora</h1>
          <p className="mt-0.5 text-sm text-slate-600">
            Lo que entró, lo que está por entrar y lo que está atrasado.
          </p>
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

      <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 lg:max-w-lg">
        <div>
          <label className={labelClass}>Desde</label>
          <FechaSelect value={desde} onChange={(e) => setDesde(e.target.value)} className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Hasta</label>
          <FechaSelect value={hasta} onChange={(e) => setHasta(e.target.value)} className={inputClass} />
        </div>
        <p className="text-[11px] text-slate-400 sm:col-span-2">
          El período aplica al flujo de caja. La proyección y la mora son siempre una foto de hoy.
        </p>
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tarjeta titulo="Cobrado en el período" valor={fmtGs(r?.cobrado_periodo ?? 0)} />
        <Tarjeta titulo="Egresos en el período" valor={fmtGs(r?.egresos_periodo ?? 0)} />
        <Tarjeta titulo="Total por cobrar" valor={fmtGs(r?.por_cobrar_total ?? 0)} />
        <Tarjeta
          titulo="En mora"
          valor={fmtGs(r?.en_mora_total ?? 0)}
          extra={`${r?.clientes_en_mora ?? 0} cliente(s)`}
          tono="rose"
        />
      </div>

      {data && !data.egresos_disponibles ? (
        <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-xs text-amber-800">
          Los egresos figuran en cero: el módulo Gastos no está habilitado para esta empresa, así que no hay salidas
          de caja registradas. El flujo muestra solo los cobros.
        </div>
      ) : null}

      {/* Flujo de caja */}
      <Seccion titulo="Flujo de caja" descripcion="Cobros reales contra egresos, mes a mes.">
        {cargando ? (
          <p className="py-8 text-center text-sm text-slate-400">Cargando…</p>
        ) : (data?.flujo ?? []).length === 0 ? (
          <p className="py-8 text-center text-sm text-slate-400">Sin movimientos en el período.</p>
        ) : (
          <div className="space-y-3">
            {data!.flujo.map((m) => (
              <div key={m.mes} className="grid grid-cols-[5rem_1fr_auto] items-center gap-3">
                <span className="text-xs font-medium text-slate-600">{nombreMes(m.mes)}</span>
                <div className="space-y-1">
                  <div className="h-2.5 w-full overflow-hidden rounded-full bg-slate-100">
                    <div
                      style={{ width: `${(m.cobrado / maxFlujo) * 100}%` }}
                      className="h-full bg-emerald-500"
                      title={`Cobrado: ${fmtGs(m.cobrado)}`}
                    />
                  </div>
                  <div className="h-2.5 w-full overflow-hidden rounded-full bg-slate-100">
                    <div
                      style={{ width: `${(m.egresos / maxFlujo) * 100}%` }}
                      className="h-full bg-rose-400"
                      title={`Egresos: ${fmtGs(m.egresos)}`}
                    />
                  </div>
                </div>
                <span
                  className={`text-right text-xs font-semibold tabular-nums ${
                    m.neto >= 0 ? "text-emerald-700" : "text-rose-700"
                  }`}
                >
                  {fmtGs(m.neto)}
                </span>
              </div>
            ))}
            <div className="flex items-center gap-4 pt-1 text-[11px] text-slate-500">
              <span className="inline-flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-full bg-emerald-500" /> Cobrado
              </span>
              <span className="inline-flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-full bg-rose-400" /> Egresos
              </span>
              <span className="ml-auto">La cifra de la derecha es el neto del mes.</span>
            </div>
          </div>
        )}
      </Seccion>

      {/* Proyección de cobros */}
      <Seccion
        titulo="Proyección de cobros"
        descripcion="Facturas pendientes agrupadas por cuándo vencen. Es lo que debería entrar."
      >
        {cargando ? (
          <p className="py-8 text-center text-sm text-slate-400">Cargando…</p>
        ) : (
          <div className="space-y-2">
            {(data?.proyeccion ?? []).map((t) => (
              <div key={t.clave} className="grid grid-cols-[9rem_1fr_auto] items-center gap-3">
                <span className={`text-xs font-medium ${t.clave === "vencido" ? "text-rose-700" : "text-slate-600"}`}>
                  {t.label}
                </span>
                <div className="h-2.5 w-full overflow-hidden rounded-full bg-slate-100">
                  <div
                    style={{ width: `${(t.monto / maxProy) * 100}%` }}
                    className={`h-full ${t.clave === "vencido" ? "bg-rose-500" : "bg-sky-500"}`}
                  />
                </div>
                <span className="text-right text-xs tabular-nums text-slate-700">
                  {fmtGs(t.monto)}
                  <span className="ml-2 text-slate-400">({t.facturas})</span>
                </span>
              </div>
            ))}
          </div>
        )}
      </Seccion>

      {/* Cartera en mora */}
      <Seccion titulo="Cartera en mora" descripcion="Facturas vencidas con saldo, de la más atrasada a la más nueva.">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[44rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                <th className="py-2 pr-4">Cliente</th>
                <th className="py-2 pr-4">Factura</th>
                <th className="py-2 pr-4">Venció</th>
                <th className="py-2 pr-4">Atraso</th>
                <th className="py-2 pr-4">Tramo</th>
                <th className="py-2 text-right">Saldo</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {cargando ? (
                <tr>
                  <td colSpan={6} className="py-8 text-center text-sm text-slate-400">
                    Cargando…
                  </td>
                </tr>
              ) : (data?.mora ?? []).length === 0 ? (
                <tr>
                  <td colSpan={6} className="py-8 text-center text-sm text-slate-400">
                    No hay facturas vencidas. La cartera está al día.
                  </td>
                </tr>
              ) : (
                data!.mora.map((m) => (
                  <tr key={m.factura_id} className="hover:bg-slate-50/60">
                    <td className="py-2.5 pr-4">
                      <Link
                        href={`/clientes/${m.cliente_id}`}
                        className="font-medium text-slate-900 hover:text-[#0EA5E9] hover:underline"
                      >
                        {m.cliente}
                      </Link>
                    </td>
                    <td className="py-2.5 pr-4">
                      <Link href={`/facturas/${m.factura_id}`} className="text-slate-600 hover:underline">
                        {m.numero_factura}
                      </Link>
                    </td>
                    <td className="whitespace-nowrap py-2.5 pr-4 tabular-nums text-slate-600">
                      {fmtFecha(m.fecha_vencimiento)}
                    </td>
                    <td className="whitespace-nowrap py-2.5 pr-4 tabular-nums font-semibold text-rose-700">
                      {m.dias_atraso} días
                    </td>
                    <td className="py-2.5 pr-4">
                      <span
                        className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                          TRAMO_MORA_UI[m.tramo].chip
                        }`}
                      >
                        {TRAMO_MORA_UI[m.tramo].label}
                      </span>
                    </td>
                    <td className="py-2.5 text-right font-semibold tabular-nums text-slate-900">{fmtGs(m.saldo)}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </Seccion>
    </div>
  );
}

function Seccion({
  titulo,
  descripcion,
  children,
}: {
  titulo: string;
  descripcion: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-2xl border border-slate-200 bg-white p-4">
      <div className="mb-3">
        <h2 className="text-base font-semibold text-slate-900">{titulo}</h2>
        <p className="text-xs text-slate-500">{descripcion}</p>
      </div>
      {children}
    </section>
  );
}

function Tarjeta({
  titulo,
  valor,
  extra,
  tono,
}: {
  titulo: string;
  valor: string;
  extra?: string;
  tono?: "rose";
}) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-4">
      <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">{titulo}</p>
      <p className={`mt-1 text-lg font-bold tabular-nums ${tono === "rose" ? "text-rose-700" : "text-slate-900"}`}>
        {valor}
      </p>
      {extra ? <p className="mt-0.5 text-xs text-slate-500">{extra}</p> : null}
    </div>
  );
}
