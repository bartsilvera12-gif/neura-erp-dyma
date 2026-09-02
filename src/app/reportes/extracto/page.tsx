"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { ArrowLeft, Printer, RefreshCw } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { getClientes } from "@/lib/clientes/storage";
import SmartSearchSelect, { type SmartOption } from "@/components/ui/SmartSearchSelect";
import { FechaSelect } from "@/components/ui/FechaSelect";
import type { Cliente } from "@/lib/clientes/types";
import type { ExtractoPayload } from "@/lib/reportes/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";
const labelClass = "block text-xs font-medium text-slate-500 mb-1";

function fmt(v: number, moneda: string): string {
  if (v === 0) return "—";
  if (moneda === "USD") return `USD ${v.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`;
  return Math.round(v).toLocaleString("es-PY");
}

function fmtFecha(ymd: string): string {
  if (!ymd) return "—";
  const [y, m, d] = ymd.split("-");
  return `${d}/${m}/${y}`;
}

export default function ExtractoPage() {
  const [clientes, setClientes] = useState<Cliente[]>([]);
  const [clienteId, setClienteId] = useState("");
  const [desde, setDesde] = useState("");
  const [hasta, setHasta] = useState("");
  const [data, setData] = useState<ExtractoPayload | null>(null);
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getClientes().then(setClientes).catch(() => setClientes([]));
  }, []);

  const opciones: SmartOption[] = useMemo(
    () =>
      clientes.map((c) => ({
        id: c.id,
        label: ((c.empresa ?? c.nombre_contacto) || "").trim() || "Cliente sin nombre",
        sub: c.codigo_cliente,
        keywords: `${c.ruc ?? ""} ${c.documento ?? ""} ${c.nombre_contacto ?? ""}`,
      })),
    [clientes]
  );

  const load = useCallback(async () => {
    if (!clienteId) {
      setData(null);
      return;
    }
    setCargando(true);
    setError(null);
    try {
      const params = new URLSearchParams({ cliente_id: clienteId });
      if (desde) params.set("desde", desde);
      if (hasta) params.set("hasta", hasta);
      const res = await fetchWithSupabaseSession(`/api/reportes/extracto?${params.toString()}`, {
        cache: "no-store",
      });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: ExtractoPayload };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudo cargar el extracto");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [clienteId, desde, hasta]);

  useEffect(() => {
    void load();
  }, [load]);

  const moneda = data?.moneda ?? "GS";
  const r = data?.resumen;

  /** Saldo acumulado línea a línea: es lo que la gente busca en un extracto. */
  const filas = useMemo(() => {
    let acumulado = 0;
    return (data?.movimientos ?? []).map((m) => {
      acumulado += m.debe - m.haber;
      return { ...m, acumulado };
    });
  }, [data]);

  return (
    <div className="mx-auto w-full max-w-6xl space-y-6 px-4 pb-10 sm:px-6 lg:px-8">
      <div className="flex flex-wrap items-start justify-between gap-3 print:hidden">
        <div>
          <Link
            href="/reportes"
            className="mb-1 inline-flex items-center gap-1 text-xs font-medium text-slate-500 hover:text-[#0EA5E9]"
          >
            <ArrowLeft className="h-3.5 w-3.5" />
            Volver a Reportes
          </Link>
          <h1 className="text-2xl font-bold text-slate-900">Extracto de cuenta</h1>
          <p className="mt-0.5 text-sm text-slate-600">
            Movimiento completo del cliente: lo facturado, lo cobrado y el saldo.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => void load()}
            disabled={cargando || !clienteId}
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50 disabled:opacity-50"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${cargando ? "animate-spin" : ""}`} />
            Actualizar
          </button>
          <button
            type="button"
            onClick={() => window.print()}
            disabled={!data}
            className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            <Printer className="h-3.5 w-3.5" />
            Imprimir
          </button>
        </div>
      </div>

      <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 lg:grid-cols-4 print:hidden">
        <div className="lg:col-span-2">
          <label className={labelClass}>Cliente</label>
          <SmartSearchSelect
            options={opciones}
            value={clienteId}
            onChange={setClienteId}
            placeholder="Buscar cliente…"
          />
        </div>
        <div>
          <label className={labelClass}>Desde</label>
          <FechaSelect value={desde} onChange={(e) => setDesde(e.target.value)} className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Hasta</label>
          <FechaSelect value={hasta} onChange={(e) => setHasta(e.target.value)} className={inputClass} />
        </div>
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      {!clienteId ? (
        <div className="rounded-2xl border border-slate-200 bg-white p-10 text-center text-sm text-slate-400">
          Elegí un cliente para ver su extracto.
        </div>
      ) : cargando ? (
        <div className="rounded-2xl border border-slate-200 bg-white p-10 text-center text-sm text-slate-400">
          Cargando…
        </div>
      ) : data ? (
        <>
          <div className="rounded-2xl border border-slate-200 bg-white p-4">
            <h2 className="text-base font-semibold text-slate-900">{data.cliente?.label}</h2>
            <p className="mt-0.5 text-xs text-slate-500">
              {data.cliente?.ruc ? `RUC ${data.cliente.ruc}` : data.cliente?.documento ? `Doc. ${data.cliente.documento}` : "Sin documento"}
              {desde || hasta ? ` · Período ${fmtFecha(desde)} a ${fmtFecha(hasta)}` : " · Todo el historial"}
            </p>
          </div>

          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Tarjeta titulo="Facturado" valor={fmt(r?.facturado ?? 0, moneda)} />
            <Tarjeta titulo="Cobrado" valor={fmt(r?.cobrado ?? 0, moneda)} />
            <Tarjeta titulo="Saldo" valor={fmt(r?.saldo ?? 0, moneda)} tono={(r?.saldo ?? 0) > 0 ? "rose" : undefined} />
            <Tarjeta
              titulo="Saldo vencido"
              valor={fmt(r?.saldo_vencido ?? 0, moneda)}
              extra={`${r?.facturas_vencidas ?? 0} de ${r?.facturas_pendientes ?? 0} pendiente(s)`}
              tono={(r?.saldo_vencido ?? 0) > 0 ? "rose" : undefined}
            />
          </div>

          <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
            <div className="overflow-x-auto">
              <table className="w-full min-w-[52rem] text-sm">
                <thead>
                  <tr className="border-b border-slate-200 bg-slate-50/70 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                    <th className="px-4 py-3">Fecha</th>
                    <th className="px-4 py-3">Documento</th>
                    <th className="px-4 py-3">Detalle</th>
                    <th className="px-4 py-3">Vence</th>
                    <th className="px-4 py-3 text-right">Debe</th>
                    <th className="px-4 py-3 text-right">Haber</th>
                    <th className="px-4 py-3 text-right">Saldo</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {filas.length === 0 ? (
                    <tr>
                      <td colSpan={7} className="px-4 py-10 text-center text-sm text-slate-400">
                        Sin movimientos en el período.
                      </td>
                    </tr>
                  ) : (
                    filas.map((m, i) => (
                      <tr key={`${m.tipo}-${m.documento}-${i}`} className="hover:bg-slate-50/60">
                        <td className="whitespace-nowrap px-4 py-3 tabular-nums text-slate-700">
                          {fmtFecha(m.fecha)}
                        </td>
                        <td className="px-4 py-3 text-slate-700">{m.documento}</td>
                        <td className="px-4 py-3 text-slate-600">
                          {m.tipo === "pago" ? (
                            <span className="mr-1.5 rounded-full border border-emerald-200 bg-emerald-50 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-700">
                              Cobro
                            </span>
                          ) : null}
                          {m.detalle}
                        </td>
                        <td className="whitespace-nowrap px-4 py-3 text-xs text-slate-500">
                          {m.vencimiento ? fmtFecha(m.vencimiento) : "—"}
                          {m.dias_atraso && m.dias_atraso > 0 ? (
                            <span className="ml-1.5 rounded-full border border-rose-200 bg-rose-50 px-1.5 py-0.5 text-[10px] font-semibold text-rose-700">
                              {m.dias_atraso}d
                            </span>
                          ) : null}
                        </td>
                        <td className="px-4 py-3 text-right tabular-nums text-slate-800">{fmt(m.debe, moneda)}</td>
                        <td className="px-4 py-3 text-right tabular-nums text-emerald-700">{fmt(m.haber, moneda)}</td>
                        <td className="px-4 py-3 text-right font-semibold tabular-nums text-slate-900">
                          {Math.round(m.acumulado).toLocaleString("es-PY")}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </>
      ) : null}
    </div>
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
      <p className={`mt-1 text-xl font-bold tabular-nums ${tono === "rose" ? "text-rose-700" : "text-slate-900"}`}>
        {valor}
      </p>
      {extra ? <p className="mt-0.5 text-xs text-slate-500">{extra}</p> : null}
    </div>
  );
}
