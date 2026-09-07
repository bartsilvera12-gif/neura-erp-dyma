"use client";

import { useCallback, useEffect, useState } from "react";
import Select from "@/components/ui/Select";
import Link from "next/link";
import { ArrowLeft, RefreshCw } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { ESTADO_VENTA_UI, type VentaResumen } from "@/lib/financiacion/types";

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400";

const fmt = (v: number, moneda: string) =>
  moneda === "USD"
    ? `USD ${v.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`
    : `Gs. ${Math.round(v).toLocaleString("es-PY")}`;

function fmtFecha(ymd: string): string {
  if (!ymd) return "—";
  const [y, m, d] = ymd.split("-");
  return `${d}/${m}/${y}`;
}

export default function VentasPage() {
  const [ventas, setVentas] = useState<VentaResumen[]>([]);
  const [estado, setEstado] = useState("vigente");
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const qs = estado ? `?estado=${encodeURIComponent(estado)}` : "";
      const res = await fetchWithSupabaseSession(`/api/lotes/ventas${qs}`, { cache: "no-store" });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: { ventas: VentaResumen[] } };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setVentas(json.data.ventas);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudieron cargar los contratos");
      setVentas([]);
    } finally {
      setCargando(false);
    }
  }, [estado]);

  useEffect(() => {
    void load();
  }, [load]);

  const totalSaldo = ventas.reduce((a, v) => a + v.saldo, 0);
  const totalMora = ventas.reduce((a, v) => a + v.mora_acumulada, 0);
  const conVencidas = ventas.filter((v) => v.cuotas_vencidas > 0).length;

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
          <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Contratos</h1>
          <p className="mt-1 text-sm text-slate-500">Ventas financiadas de lotes, con su saldo y su mora al día.</p>
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

      <div className="rounded-2xl border border-slate-200 bg-white p-4 sm:max-w-xs">
        <label className="mb-1 block text-xs font-medium text-slate-500">Estado</label>
        <Select value={estado} onChange={(e) => setEstado(e.target.value)}>
          <option value="vigente">Vigentes</option>
          <option value="cancelada">Canceladas</option>
          <option value="anulada">Anuladas</option>
          <option value="">Todos</option>
        </Select>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tarjeta titulo="Contratos" valor={String(ventas.length)} />
        <Tarjeta titulo="Saldo por cobrar" valor={fmt(totalSaldo, "GS")} />
        <Tarjeta titulo="Mora acumulada" valor={fmt(totalMora, "GS")} tono={totalMora > 0 ? "rose" : undefined} />
        <Tarjeta titulo="Con cuotas vencidas" valor={String(conVencidas)} tono={conVencidas > 0 ? "rose" : undefined} />
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[56rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50/70 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                <th className="px-4 py-3">Contrato</th>
                <th className="px-4 py-3">Fecha</th>
                <th className="px-4 py-3">Lote</th>
                <th className="px-4 py-3">Cliente</th>
                <th className="px-4 py-3">Cuotas</th>
                <th className="px-4 py-3 text-right">Saldo</th>
                <th className="px-4 py-3 text-right">Mora</th>
                <th className="px-4 py-3">Estado</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {cargando ? (
                <tr>
                  <td colSpan={8} className="px-4 py-10 text-center text-sm text-slate-400">
                    Cargando…
                  </td>
                </tr>
              ) : ventas.length === 0 ? (
                <tr>
                  <td colSpan={8} className="px-4 py-10 text-center text-sm text-slate-400">
                    No hay contratos con ese filtro.
                  </td>
                </tr>
              ) : (
                ventas.map((v) => (
                  <tr key={v.id} className="hover:bg-slate-50/60">
                    <td className="px-4 py-3">
                      <Link
                        href={`/lotes/ventas/${v.id}`}
                        className="font-semibold text-slate-900 hover:text-[#0EA5E9] hover:underline"
                      >
                        {v.numero_contrato}
                      </Link>
                    </td>
                    <td className="whitespace-nowrap px-4 py-3 tabular-nums text-slate-600">
                      {fmtFecha(v.fecha_venta)}
                    </td>
                    <td className="px-4 py-3 text-slate-600">{v.lote_label}</td>
                    <td className="px-4 py-3">
                      <Link href={`/clientes/${v.cliente_id}`} className="text-slate-700 hover:underline">
                        {v.cliente_label}
                      </Link>
                    </td>
                    <td className="px-4 py-3 text-xs text-slate-600">
                      {v.cuotas_pagadas} / {v.cantidad_cuotas}
                      {v.cuotas_vencidas > 0 ? (
                        <span className="ml-1.5 rounded-full border border-rose-200 bg-rose-50 px-1.5 py-0.5 text-[10px] font-semibold text-rose-700">
                          {v.cuotas_vencidas} vencida{v.cuotas_vencidas === 1 ? "" : "s"}
                        </span>
                      ) : null}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-slate-800">{fmt(v.saldo, v.moneda)}</td>
                    <td className="px-4 py-3 text-right tabular-nums text-rose-700">
                      {v.mora_acumulada > 0 ? fmt(v.mora_acumulada, v.moneda) : "—"}
                    </td>
                    <td className="px-4 py-3">
                      <span
                        className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                          ESTADO_VENTA_UI[v.estado].chip
                        }`}
                      >
                        {ESTADO_VENTA_UI[v.estado].label}
                      </span>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

function Tarjeta({ titulo, valor, tono }: { titulo: string; valor: string; tono?: "rose" }) {
  return (
    <div className="group relative overflow-hidden rounded-2xl border border-slate-200 bg-white p-5 shadow-sm transition-shadow hover:shadow-md">
      <span className={`absolute inset-x-0 top-0 h-1 ${tono === "rose" ? "bg-rose-400" : "bg-[#0EA5E9]"}`} />
      <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">{titulo}</p>
      <p className={`mt-1.5 text-2xl font-bold tabular-nums tracking-tight ${tono === "rose" ? "text-rose-700" : "text-slate-900"}`}>
        {valor}
      </p>
    </div>
  );
}
