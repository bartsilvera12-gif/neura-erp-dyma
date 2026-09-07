"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { FancySelect } from "@/components/ui/FancySelect";
import Link from "next/link";
import { ArrowLeft, RefreshCw, Users } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { pctVisible, rangoDelMes } from "@/lib/vendedores/calculo-comision";
import type { ComisionesPayload, ComisionVendedor, Vendedor } from "@/lib/vendedores/types";

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400";
const labelClass =
  "mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-500";

const fmt = (v: number, moneda = "GS") =>
  moneda === "USD"
    ? `USD ${v.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`
    : `Gs. ${Math.round(v).toLocaleString("es-PY")}`;

function fmtFecha(ymd: string): string {
  if (!ymd) return "—";
  const [y, m, d] = ymd.split("-");
  return `${d}/${m}/${y}`;
}

/** Mes en curso en Asunción, como YYYY-MM. */
function mesActual(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Asuncion",
    year: "numeric",
    month: "2-digit",
  })
    .format(new Date())
    .slice(0, 7);
}

function etiquetaMes(mes: string): string {
  const r = rangoDelMes(mes);
  if (!r) return mes;
  const [y, m] = mes.split("-").map(Number);
  const nombre = new Intl.DateTimeFormat("es-PY", { month: "long", year: "numeric", timeZone: "UTC" }).format(
    new Date(Date.UTC(y, m - 1, 1))
  );
  return nombre.charAt(0).toUpperCase() + nombre.slice(1);
}

export default function ComisionesClient() {
  const [mes, setMes] = useState(mesActual);
  const [vendedorId, setVendedorId] = useState("");
  const [vendedores, setVendedores] = useState<Vendedor[]>([]);
  const [data, setData] = useState<ComisionesPayload | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchWithSupabaseSession("/api/lotes/vendedores?incluir_inactivos=1", { cache: "no-store" })
      .then((r) => r.json())
      .then((j: { success?: boolean; data?: { vendedores: Vendedor[] } }) => {
        setVendedores(j.success === true && j.data ? j.data.vendedores : []);
      })
      .catch(() => setVendedores([]));
  }, []);

  const load = useCallback(async () => {
    const rango = rangoDelMes(mes);
    if (!rango) {
      setError("Mes inválido");
      setData(null);
      setCargando(false);
      return;
    }
    setCargando(true);
    setError(null);
    try {
      const params = new URLSearchParams({ desde: rango.desde, hasta: rango.hasta });
      if (vendedorId) params.set("vendedor_id", vendedorId);
      const res = await fetchWithSupabaseSession(`/api/lotes/comisiones?${params.toString()}`, {
        cache: "no-store",
      });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: ComisionesPayload };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudieron calcular las comisiones");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [mes, vendedorId]);

  useEffect(() => {
    void load();
  }, [load]);

  const vendedoresConCobros = data?.vendedores ?? [];
  const resumen = useMemo(
    () => ({
      vendedores: vendedoresConCobros.length,
      cuotas: vendedoresConCobros.reduce((a, v) => a + v.cuotas_cobradas, 0),
    }),
    [vendedoresConCobros]
  );

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
          <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Comisiones</h1>
          <p className="mt-1 text-sm text-slate-500">
            Lo que le corresponde a cada vendedor por las cuotas cobradas en el mes. Una cuota pendiente no
            genera comisión hasta que se cobra.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Link
            href="/lotes/vendedores"
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
          >
            <Users className="h-3.5 w-3.5" />
            Vendedores
          </Link>
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
      </div>

      <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <label className={labelClass}>Mes</label>
          <input type="month" value={mes} onChange={(e) => setMes(e.target.value)} className={inputClass} />
        </div>
        <div className="lg:col-span-2">
          <label className={labelClass}>Vendedor</label>
          <FancySelect
            value={vendedorId}
            onChange={setVendedorId}
            options={[
              { value: "", label: "Todos los vendedores" },
              ...vendedores.map((v) => ({ value: v.id, label: `${v.codigo} — ${v.nombre}` })),
            ]}
          />
        </div>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tarjeta titulo="Vendedores con cobros" valor={String(resumen.vendedores)} />
        <Tarjeta titulo="Cuotas cobradas" valor={String(resumen.cuotas)} />
        <Tarjeta titulo="Total cobrado" valor={fmt(data?.total_cobrado ?? 0)} />
        <Tarjeta titulo="Total a pagar en comisiones" valor={fmt(data?.total_comision ?? 0)} destacado />
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      {data && data.cobros_sin_vendedor > 0 ? (
        <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-xs text-amber-800">
          {data.cobros_sin_vendedor} cobro{data.cobros_sin_vendedor === 1 ? "" : "s"} de{" "}
          {fmt(data.monto_sin_vendedor)} en {etiquetaMes(mes)} corresponden a contratos sin vendedor asignado, así
          que no generan comisión.
        </div>
      ) : null}

      {cargando ? (
        <div className="rounded-2xl border border-slate-200 bg-white px-4 py-10 text-center text-sm text-slate-400">
          Calculando…
        </div>
      ) : vendedoresConCobros.length === 0 ? (
        <div className="rounded-2xl border border-slate-200 bg-white px-4 py-10 text-center text-sm text-slate-400">
          No hubo cuotas cobradas en {etiquetaMes(mes)}.
        </div>
      ) : (
        vendedoresConCobros.map((v) => <BloqueVendedor key={v.vendedor_id} vendedor={v} />)
      )}
    </div>
  );
}

function BloqueVendedor({ vendedor: v }: { vendedor: ComisionVendedor }) {
  return (
    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 bg-slate-50/70 px-4 py-3">
        <div>
          <p className="text-sm font-bold text-slate-900">{v.nombre}</p>
          <p className="text-[11px] text-slate-500">
            Código {v.codigo} · {v.ventas} venta{v.ventas === 1 ? "" : "s"} · {v.clientes} cliente
            {v.clientes === 1 ? "" : "s"} · {v.cuotas_cobradas} cuota{v.cuotas_cobradas === 1 ? "" : "s"} cobrada
            {v.cuotas_cobradas === 1 ? "" : "s"}
          </p>
        </div>
        <div className="text-right">
          <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">A pagar</p>
          <p className="text-lg font-bold tabular-nums text-[#0EA5E9]">{fmt(v.total_comision)}</p>
          <p className="text-[11px] text-slate-500">sobre {fmt(v.total_cobrado)} cobrados</p>
        </div>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full min-w-[52rem] text-sm">
          <thead>
            <tr className="border-b border-slate-200 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
              <th className="px-4 py-2.5">Contrato</th>
              <th className="px-4 py-2.5">Cliente</th>
              <th className="px-4 py-2.5">Lote</th>
              <th className="px-4 py-2.5 text-right">Cuota</th>
              <th className="px-4 py-2.5">Cobrado el</th>
              <th className="px-4 py-2.5">Factura</th>
              <th className="px-4 py-2.5 text-right">Monto cobrado</th>
              <th className="px-4 py-2.5 text-right">%</th>
              <th className="px-4 py-2.5 text-right">Comisión</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {v.cobros.map((c) => (
              <tr key={c.pago_id} className="hover:bg-slate-50/60">
                <td className="px-4 py-2.5">
                  <Link
                    href={`/lotes/ventas/${c.venta_id}`}
                    className="font-medium text-slate-900 hover:text-[#0EA5E9] hover:underline"
                  >
                    {c.numero_contrato}
                  </Link>
                </td>
                <td className="px-4 py-2.5">
                  <Link href={`/clientes/${c.cliente_id}`} className="text-slate-700 hover:underline">
                    {c.cliente_label}
                  </Link>
                </td>
                <td className="px-4 py-2.5 text-slate-600">{c.lote_label}</td>
                <td className="px-4 py-2.5 text-right tabular-nums text-slate-600">
                  {c.cuota_numero}
                  <span className="ml-1 text-[10px] text-slate-400">
                    vence {fmtFecha(c.cuota_vencimiento)}
                  </span>
                </td>
                <td className="whitespace-nowrap px-4 py-2.5 tabular-nums text-slate-700">
                  {fmtFecha(c.fecha_pago)}
                </td>
                <td className="px-4 py-2.5 text-xs text-slate-500">{c.factura_numero ?? "—"}</td>
                <td className="px-4 py-2.5 text-right tabular-nums text-slate-800">
                  {fmt(c.monto_cobrado, c.moneda)}
                </td>
                <td className="px-4 py-2.5 text-right tabular-nums text-slate-600">
                  {pctVisible(c.comision_pct)}
                </td>
                <td className="px-4 py-2.5 text-right font-semibold tabular-nums text-slate-900">
                  {fmt(c.comision, c.moneda)}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-slate-200 bg-slate-50/70 text-sm font-bold">
              <td className="px-4 py-2.5 text-slate-600" colSpan={6}>
                Total {v.nombre}
              </td>
              <td className="px-4 py-2.5 text-right tabular-nums text-slate-800">{fmt(v.total_cobrado)}</td>
              <td />
              <td className="px-4 py-2.5 text-right tabular-nums text-[#0EA5E9]">{fmt(v.total_comision)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
  );
}

function Tarjeta({ titulo, valor, destacado }: { titulo: string; valor: string; destacado?: boolean }) {
  return (
    <div
      className={`group relative overflow-hidden rounded-2xl border p-5 shadow-sm transition-shadow hover:shadow-md ${
        destacado ? "border-[#0EA5E9]/40 bg-sky-50/40" : "border-slate-200 bg-white"
      }`}
    >
      <span className={`absolute inset-x-0 top-0 h-1 ${destacado ? "bg-[#0EA5E9]" : "bg-slate-200"}`} />
      <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">{titulo}</p>
      <p
        className={`mt-1.5 text-2xl font-bold tabular-nums tracking-tight ${destacado ? "text-[#0EA5E9]" : "text-slate-900"}`}
      >
        {valor}
      </p>
    </div>
  );
}
