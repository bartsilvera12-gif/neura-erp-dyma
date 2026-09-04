"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { ArrowLeft, Printer, RefreshCw, X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import MontoInput from "@/components/ui/MontoInput";
import { FechaSelect } from "@/components/ui/FechaSelect";
import { ESTADO_CUOTA_UI, ESTADO_VENTA_UI, type CuotaVenta, type VentaLote } from "@/lib/financiacion/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";
const labelClass = "block text-xs font-medium text-slate-500 mb-1";

const fmt = (v: number, moneda: string) =>
  moneda === "USD"
    ? `USD ${v.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`
    : `Gs. ${Math.round(v).toLocaleString("es-PY")}`;

function fmtFecha(ymd: string | null): string {
  if (!ymd) return "—";
  const [y, m, d] = ymd.slice(0, 10).split("-");
  return `${d}/${m}/${y}`;
}

function hoyYmd(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Asuncion",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

export default function ContratoClient({ ventaId }: { ventaId: string }) {
  const [data, setData] = useState<VentaLote | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [cobrando, setCobrando] = useState<CuotaVenta | null>(null);

  const showToast = useCallback((m: string) => {
    setToast(m);
    setTimeout(() => setToast(null), 4000);
  }, []);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const res = await fetchWithSupabaseSession(`/api/lotes/ventas/${encodeURIComponent(ventaId)}`, {
        cache: "no-store",
      });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: VentaLote };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudo cargar el contrato");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [ventaId]);

  useEffect(() => {
    void load();
  }, [load]);

  if (cargando) {
    return <p className="p-10 text-center text-sm text-slate-400">Cargando…</p>;
  }
  if (error || !data) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">
          {error ?? "Contrato no encontrado"}
        </div>
      </div>
    );
  }

  const m = data.moneda;
  const r = data.resumen;

  return (
    <div className="mx-auto w-full max-w-6xl space-y-6 px-4 pb-10 sm:px-6 lg:px-8">
      <div className="flex flex-wrap items-start justify-between gap-3 print:hidden">
        <div>
          <Link
            href="/lotes/ventas"
            className="mb-1 inline-flex items-center gap-1 text-xs font-medium text-slate-500 hover:text-[#0EA5E9]"
          >
            <ArrowLeft className="h-3.5 w-3.5" />
            Volver a contratos
          </Link>
          <h1 className="flex items-center gap-2 text-2xl font-bold text-slate-900">
            {data.numero_contrato}
            <span
              className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                ESTADO_VENTA_UI[data.estado].chip
              }`}
            >
              {ESTADO_VENTA_UI[data.estado].label}
            </span>
          </h1>
          <p className="mt-0.5 text-sm text-slate-600">
            {data.lote_label} · {data.cliente_label} · vendido el {fmtFecha(data.fecha_venta)}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={() => void load()}
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
          >
            <RefreshCw className="h-3.5 w-3.5" />
            Actualizar
          </button>
          <button
            type="button"
            onClick={() => window.print()}
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
          >
            <Printer className="h-3.5 w-3.5" />
            Imprimir
          </button>
        </div>
      </div>

      {/* Condiciones */}
      <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-3 lg:grid-cols-6">
        <Dato titulo="Precio contado" valor={fmt(data.precio_contado, m)} />
        <Dato titulo="Entrega" valor={fmt(data.entrega_inicial, m)} />
        <Dato titulo="Capital" valor={fmt(data.capital, m)} />
        <Dato titulo={`Recargo ${(data.recargo_pct * 100).toFixed(0)}%`} valor={fmt(data.interes_total, m)} />
        <Dato titulo="Financiado" valor={fmt(data.monto_financiado, m)} />
        <Dato titulo="Cuotas" valor={String(data.cantidad_cuotas)} />
      </div>

      {/* Situación */}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <Tarjeta titulo="Cobrado" valor={fmt(r.cobrado, m)} />
        <Tarjeta titulo="Saldo de capital" valor={fmt(r.saldo, m)} />
        <Tarjeta titulo="Mora acumulada" valor={fmt(r.mora_acumulada, m)} tono={r.mora_acumulada > 0 ? "rose" : undefined} />
        <Tarjeta titulo="Deuda total hoy" valor={fmt(r.deuda_total, m)} tono={r.deuda_total > 0 ? "rose" : undefined} />
        <Tarjeta
          titulo="Cuotas"
          valor={`${r.cuotas_pagadas} / ${data.cantidad_cuotas}`}
          extra={r.cuotas_vencidas > 0 ? `${r.cuotas_vencidas} vencida(s)` : "al día"}
        />
      </div>

      {/* Partes */}
      <div className="rounded-2xl border border-slate-200 bg-white p-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">
              Partes del contrato
            </p>
            {data.tipo_contrato ? (
              <p className="mt-0.5 text-[11px] text-slate-500">{data.tipo_contrato.nombre}</p>
            ) : null}
          </div>
          <a
            href={`/api/lotes/ventas/${data.id}/contrato`}
            target="_blank"
            rel="noopener"
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
          >
            <Printer className="h-3.5 w-3.5" />
            Imprimir contrato
          </a>
        </div>
        <div className="mt-2 flex flex-wrap items-center gap-2 text-sm">
          <Link href={`/clientes/${data.cliente_id}`} className="font-medium text-slate-900 hover:underline">
            {data.cliente_label}
          </Link>
          <span className="rounded-full border border-sky-200 bg-sky-50 px-2 py-0.5 text-[10px] font-semibold text-sky-700">
            Titular
          </span>
          {data.partes.map((p) => (
            <span key={p.id} className="flex items-center gap-1.5">
              <span className="text-slate-700">{p.nombre}</span>
              <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 text-[10px] font-semibold text-slate-600">
                {p.rol === "conyuge" ? "Cónyuge" : "Codeudor"}
              </span>
            </span>
          ))}
          {data.partes.length === 0 ? (
            <span className="text-xs text-slate-400">Sin cónyuge ni codeudores.</span>
          ) : null}
        </div>
      </div>

      {/* Plan de cuotas */}
      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[60rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50/70 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                <th className="px-3 py-3">#</th>
                <th className="px-3 py-3">Vence</th>
                <th className="px-3 py-3 text-right">Cuota</th>
                <th className="px-3 py-3 text-right">Saldo</th>
                <th className="px-3 py-3">Atraso</th>
                <th className="px-3 py-3 text-right">Mora</th>
                <th className="px-3 py-3 text-right">A pagar</th>
                <th className="px-3 py-3">Estado</th>
                <th className="px-3 py-3">Factura</th>
                <th className="px-3 py-3 print:hidden" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {data.cuotas.map((c) => (
                <tr key={c.id} className={c.dias_atraso > 0 && c.estado === "pendiente" ? "bg-rose-50/40" : ""}>
                  <td className="px-3 py-2.5 font-medium text-slate-700">{c.numero}</td>
                  <td className="whitespace-nowrap px-3 py-2.5 tabular-nums text-slate-600">
                    {fmtFecha(c.vencimiento)}
                  </td>
                  <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">{fmt(c.total, m)}</td>
                  <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">{fmt(c.saldo, m)}</td>
                  <td className="whitespace-nowrap px-3 py-2.5 text-xs">
                    {c.estado !== "pendiente" ? (
                      <span className="text-slate-400">—</span>
                    ) : c.dias_atraso === 0 ? (
                      <span className="text-slate-400">al día</span>
                    ) : (
                      <span className="font-semibold text-rose-700">
                        {c.dias_atraso} d
                        {c.dias_en_mora === 0 ? <span className="ml-1 font-normal text-slate-400">(gracia)</span> : null}
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2.5 text-right tabular-nums text-rose-700">
                    {c.mora_total > 0 ? fmt(c.mora_total, m) : "—"}
                  </td>
                  <td className="px-3 py-2.5 text-right font-semibold tabular-nums text-slate-900">
                    {c.estado === "pendiente" ? fmt(c.total_a_pagar, m) : "—"}
                  </td>
                  <td className="px-3 py-2.5">
                    <span
                      className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                        ESTADO_CUOTA_UI[c.estado].chip
                      }`}
                    >
                      {ESTADO_CUOTA_UI[c.estado].label}
                    </span>
                  </td>
                  <td className="px-3 py-2.5 text-xs">
                    {c.factura_id ? (
                      <Link href={`/facturas/${c.factura_id}`} className="text-slate-600 hover:underline">
                        {c.factura_numero ?? "Ver"}
                      </Link>
                    ) : (
                      <span className="text-slate-400">—</span>
                    )}
                  </td>
                  <td className="px-3 py-2.5 text-right print:hidden">
                    {c.estado === "pendiente" && data.estado === "vigente" ? (
                      <button
                        type="button"
                        onClick={() => setCobrando(c)}
                        className="rounded-lg bg-[#0EA5E9] px-2.5 py-1 text-[11px] font-semibold text-white hover:bg-[#0284C7]"
                      >
                        Cobrar
                      </button>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <p className="text-[11px] text-slate-400">
        Mora: {(data.mora_administrativa_pct * 100).toFixed(1)}% administrativo +{" "}
        {(data.mora_moratoria_pct * 100).toFixed(1)}% moratorio por día, desde el día {data.dias_gracia + 1} de atraso.
        Se calcula sobre el saldo impago de cada cuota.
      </p>

      {cobrando ? (
        <ModalCobrar
          cuota={cobrando}
          moneda={m}
          onCancel={() => setCobrando(null)}
          onCobrado={async (msg) => {
            setCobrando(null);
            showToast(msg);
            await load();
          }}
        />
      ) : null}

      {toast ? (
        <div className="fixed bottom-5 left-1/2 z-[70] -translate-x-1/2 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-sm font-medium text-emerald-800 shadow-lg">
          {toast}
        </div>
      ) : null}
    </div>
  );
}

function Dato({ titulo, valor }: { titulo: string; valor: string }) {
  return (
    <div>
      <p className="text-[10px] font-semibold uppercase tracking-wider text-slate-500">{titulo}</p>
      <p className="text-sm font-bold tabular-nums text-slate-900">{valor}</p>
    </div>
  );
}

function Tarjeta({ titulo, valor, extra, tono }: { titulo: string; valor: string; extra?: string; tono?: "rose" }) {
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

/** Cobro de una cuota. Admite pago parcial y decidir si se cobra la mora. */
function ModalCobrar({
  cuota,
  moneda,
  onCancel,
  onCobrado,
}: {
  cuota: CuotaVenta;
  moneda: string;
  onCancel: () => void;
  onCobrado: (msg: string) => void | Promise<void>;
}) {
  const [cobrarMora, setCobrarMora] = useState(true);
  const exigible = cuota.saldo + (cobrarMora ? cuota.mora_total : 0);
  const [monto, setMonto] = useState(String(exigible));
  const [fecha, setFecha] = useState(hoyYmd());
  const [metodo, setMetodo] = useState("efectivo");
  const [referencia, setReferencia] = useState("");
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const montoNum = Number(monto);
  const invalido = !Number.isFinite(montoNum) || montoNum <= 0 || montoNum > exigible;

  async function confirmar() {
    setErr(null);
    setGuardando(true);
    try {
      const res = await fetchWithSupabaseSession(`/api/lotes/cuotas/${encodeURIComponent(cuota.id)}/cobrar`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          monto: montoNum,
          fecha_pago: fecha,
          metodo_pago: metodo,
          referencia,
          cobrar_mora: cobrarMora,
        }),
      });
      const json = (await res.json()) as {
        success?: boolean;
        error?: string;
        data?: { cuota_pagada?: boolean };
      };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await onCobrado(json.data?.cuota_pagada ? "Cuota cobrada por completo." : "Pago parcial registrado.");
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo registrar el cobro");
    } finally {
      setGuardando(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-slate-900/50 p-4" onClick={onCancel}>
      <div
        className="w-full max-w-md rounded-2xl border border-slate-200 bg-white p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-slate-900">Cobrar cuota {cuota.numero}</h3>
            <p className="mt-0.5 text-[11px] text-slate-500">
              Vence {fmtFecha(cuota.vencimiento)} · se emite la factura de la cuota.
            </p>
          </div>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-3 space-y-1 rounded-xl border border-slate-200 bg-slate-50/60 px-3 py-2 text-xs">
          <div className="flex justify-between">
            <span className="text-slate-600">Saldo de la cuota</span>
            <span className="font-semibold tabular-nums text-slate-900">{fmt(cuota.saldo, moneda)}</span>
          </div>
          {cuota.mora_total > 0 ? (
            <>
              <div className="flex justify-between">
                <span className="text-slate-600">
                  Mora ({cuota.dias_en_mora} día{cuota.dias_en_mora === 1 ? "" : "s"})
                </span>
                <span className="font-semibold tabular-nums text-rose-700">{fmt(cuota.mora_total, moneda)}</span>
              </div>
              <p className="text-[10px] text-slate-400">
                Administrativo {fmt(cuota.mora_administrativa, moneda)} · moratorio{" "}
                {fmt(cuota.mora_moratoria, moneda)}
              </p>
            </>
          ) : null}
          <div className="flex justify-between border-t border-slate-200 pt-1">
            <span className="font-semibold text-slate-700">Total a cobrar</span>
            <span className="font-bold tabular-nums text-slate-900">{fmt(exigible, moneda)}</span>
          </div>
        </div>

        {cuota.mora_total > 0 ? (
          <label className="mt-3 flex items-center gap-2 text-xs text-slate-600">
            <input
              type="checkbox"
              checked={cobrarMora}
              onChange={(e) => {
                setCobrarMora(e.target.checked);
                setMonto(String(cuota.saldo + (e.target.checked ? cuota.mora_total : 0)));
              }}
              className="h-3.5 w-3.5"
            />
            Cobrar también la mora
          </label>
        ) : null}

        <div className="mt-3 grid gap-3">
          <div>
            <label className={labelClass}>Monto cobrado</label>
            <MontoInput
              value={monto}
              onChange={(n) => setMonto(String(n))}
              decimals={moneda === "USD"}
              className={inputClass}
            />
            {montoNum > exigible ? (
              <span className="mt-1 block text-[11px] text-rose-600">No puede superar lo adeudado.</span>
            ) : montoNum > 0 && montoNum < exigible ? (
              <span className="mt-1 block text-[11px] text-amber-600">
                Pago parcial: la cuota queda pendiente por el resto.
              </span>
            ) : null}
          </div>
          <div>
            <label className={labelClass}>Fecha del cobro</label>
            <FechaSelect value={fecha} onChange={(e) => setFecha(e.target.value)} className={inputClass} />
          </div>
          <div>
            <label className={labelClass}>Método</label>
            <select value={metodo} onChange={(e) => setMetodo(e.target.value)} className={inputClass}>
              <option value="efectivo">Efectivo</option>
              <option value="transferencia">Transferencia</option>
              <option value="cheque">Cheque</option>
              <option value="tarjeta">Tarjeta</option>
              <option value="otro">Otro</option>
            </select>
          </div>
          <div>
            <label className={labelClass}>
              Referencia <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input value={referencia} onChange={(e) => setReferencia(e.target.value)} className={inputClass} />
          </div>
        </div>

        {err ? <p className="mt-3 text-xs text-rose-600">{err}</p> : null}

        <div className="mt-4 flex justify-end gap-2">
          <button
            type="button"
            onClick={onCancel}
            disabled={guardando}
            className="rounded-xl border border-slate-200 bg-white px-3.5 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            onClick={() => void confirmar()}
            disabled={guardando || invalido}
            className="rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            {guardando ? "Registrando…" : "Registrar cobro"}
          </button>
        </div>
      </div>
    </div>
  );
}
