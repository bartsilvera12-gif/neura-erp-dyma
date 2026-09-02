"use client";

import { useMemo, useState } from "react";
import { X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import SmartSearchSelect, { type SmartOption } from "@/components/ui/SmartSearchSelect";
import MontoInput from "@/components/ui/MontoInput";
import { FechaSelect } from "@/components/ui/FechaSelect";
import {
  generarPlanCuotas,
  DIAS_GRACIA,
  MORA_ADMINISTRATIVA_DIARIA,
  MORA_MORATORIA_DIARIA,
  RECARGO_FINANCIACION,
} from "@/lib/financiacion/plan-cuotas";
import type { Lote } from "@/lib/lotes/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";
const labelClass = "block text-xs font-medium text-slate-500 mb-1";

const fmt = (v: number, moneda: string) =>
  moneda === "USD"
    ? `USD ${v.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`
    : `Gs. ${Math.round(v).toLocaleString("es-PY")}`;

function fmtFecha(ymd: string): string {
  if (!ymd) return "—";
  const [y, m, d] = ymd.split("-");
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

/**
 * Venta financiada de un lote.
 *
 * El plan se calcula en el navegador con el mismo motor que usa el servidor, así
 * el vendedor ve la tabla exacta antes de confirmar. El servidor lo recalcula al
 * guardar: la vista previa no es la fuente de verdad.
 */
export default function ModalVenderLote({
  lote,
  opcionesCliente,
  onCancel,
  onVendido,
}: {
  lote: Lote;
  opcionesCliente: SmartOption[];
  onCancel: () => void;
  onVendido: (msg: string) => void | Promise<void>;
}) {
  const [clienteId, setClienteId] = useState(lote.cliente_id ?? "");
  const [codeudorId, setCodeudorId] = useState("");
  const [fechaVenta, setFechaVenta] = useState(hoyYmd());
  const [primerVencimiento, setPrimerVencimiento] = useState(hoyYmd());
  const [precioContado, setPrecioContado] = useState(
    String(lote.precio_contado ?? lote.precio_financiado ?? 0)
  );
  const [entrega, setEntrega] = useState("0");
  const [cuotas, setCuotas] = useState("12");
  const [observacion, setObservacion] = useState("");
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const moneda = lote.moneda;

  /** Vista previa del plan. Si los datos no cierran, el motor avisa por qué. */
  const preview = useMemo(() => {
    try {
      return {
        plan: generarPlanCuotas({
          precioContado: Number(precioContado),
          entregaInicial: Number(entrega),
          cantidadCuotas: Number(cuotas),
          primerVencimiento,
        }),
        error: null as string | null,
      };
    } catch (e) {
      return { plan: null, error: e instanceof Error ? e.message : "Datos inválidos" };
    }
  }, [precioContado, entrega, cuotas, primerVencimiento]);

  const invalido = !clienteId || !preview.plan || guardando;

  async function confirmar() {
    setErr(null);
    setGuardando(true);
    try {
      const res = await fetchWithSupabaseSession("/api/lotes/ventas", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          lote_id: lote.id,
          cliente_id: clienteId,
          codeudores: codeudorId ? [codeudorId] : [],
          fecha_venta: fechaVenta,
          primer_vencimiento: primerVencimiento,
          precio_contado: Number(precioContado),
          entrega_inicial: Number(entrega),
          cantidad_cuotas: Number(cuotas),
          observacion,
        }),
      });
      const json = (await res.json()) as {
        success?: boolean;
        error?: string;
        data?: { numero_contrato?: string };
      };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await onVendido(
        json.data?.numero_contrato
          ? `Contrato ${json.data.numero_contrato} generado.`
          : "Venta registrada."
      );
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo registrar la venta");
    } finally {
      setGuardando(false);
    }
  }

  const p = preview.plan;

  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-slate-900/50 p-4" onClick={onCancel}>
      <div
        className="max-h-[92vh] w-full max-w-3xl overflow-y-auto rounded-2xl border border-slate-200 bg-white p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-slate-900">Vender lote {lote.numero}</h3>
            <p className="mt-0.5 text-[11px] text-slate-500">
              Recargo del {(RECARGO_FINANCIACION * 100).toFixed(0)}% sobre el capital, en cuotas iguales.
            </p>
          </div>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <label className={labelClass}>Cliente titular</label>
            <SmartSearchSelect
              options={opcionesCliente}
              value={clienteId}
              onChange={setClienteId}
              placeholder="Buscar cliente…"
            />
          </div>
          <div className="sm:col-span-2">
            <label className={labelClass}>
              Codeudor <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <SmartSearchSelect
              options={[{ id: "", label: "Sin codeudor" }, ...opcionesCliente.filter((o) => o.id !== clienteId)]}
              value={codeudorId}
              onChange={setCodeudorId}
              placeholder="Sin codeudor"
            />
          </div>
          <div>
            <label className={labelClass}>Fecha de la venta</label>
            <FechaSelect value={fechaVenta} onChange={(e) => setFechaVenta(e.target.value)} className={inputClass} />
          </div>
          <div>
            <label className={labelClass}>Vencimiento de la primera cuota</label>
            <FechaSelect
              value={primerVencimiento}
              onChange={(e) => setPrimerVencimiento(e.target.value)}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Precio de contado</label>
            <MontoInput
              value={precioContado}
              onChange={(n) => setPrecioContado(String(n))}
              decimals={moneda === "USD"}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Entrega inicial</label>
            <MontoInput
              value={entrega}
              onChange={(n) => setEntrega(String(n))}
              decimals={moneda === "USD"}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Cantidad de cuotas</label>
            <input
              type="number"
              min={1}
              value={cuotas}
              onChange={(e) => setCuotas(e.target.value)}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>
              Observación <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input value={observacion} onChange={(e) => setObservacion(e.target.value)} className={inputClass} />
          </div>
        </div>

        {/* Resumen del plan */}
        {preview.error ? (
          <p className="mt-4 rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
            {preview.error}
          </p>
        ) : p ? (
          <>
            <div className="mt-4 grid gap-2 rounded-xl border border-slate-200 bg-slate-50/60 p-3 sm:grid-cols-4">
              <Dato titulo="Capital" valor={fmt(p.capital, moneda)} />
              <Dato titulo={`Recargo ${(RECARGO_FINANCIACION * 100).toFixed(0)}%`} valor={fmt(p.interes_total, moneda)} />
              <Dato titulo="A financiar" valor={fmt(p.monto_financiado, moneda)} />
              <Dato titulo="Cuota" valor={fmt(p.cuotas[0]?.total ?? 0, moneda)} destacado />
            </div>

            <div className="mt-3 max-h-52 overflow-y-auto rounded-xl border border-slate-200">
              <table className="w-full text-xs">
                <thead className="sticky top-0 bg-slate-50">
                  <tr className="text-left text-[10px] font-semibold uppercase tracking-wider text-slate-500">
                    <th className="px-3 py-2">Cuota</th>
                    <th className="px-3 py-2">Vence</th>
                    <th className="px-3 py-2 text-right">Capital</th>
                    <th className="px-3 py-2 text-right">Recargo</th>
                    <th className="px-3 py-2 text-right">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {p.cuotas.map((c) => (
                    <tr key={c.numero}>
                      <td className="px-3 py-1.5 text-slate-700">{c.numero}</td>
                      <td className="px-3 py-1.5 tabular-nums text-slate-600">{fmtFecha(c.vencimiento)}</td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-slate-600">{fmt(c.capital, moneda)}</td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-slate-600">{fmt(c.interes, moneda)}</td>
                      <td className="px-3 py-1.5 text-right font-semibold tabular-nums text-slate-900">
                        {fmt(c.total, moneda)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <p className="mt-2 text-[11px] text-slate-400">
              Mora: {(MORA_ADMINISTRATIVA_DIARIA * 100).toFixed(1)}% administrativo +{" "}
              {(MORA_MORATORIA_DIARIA * 100).toFixed(1)}% moratorio por día, desde el día {DIAS_GRACIA + 1} de atraso.
            </p>
          </>
        ) : null}

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
            disabled={invalido}
            className="rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            {guardando ? "Generando…" : "Confirmar venta"}
          </button>
        </div>
      </div>
    </div>
  );
}

function Dato({ titulo, valor, destacado }: { titulo: string; valor: string; destacado?: boolean }) {
  return (
    <div>
      <p className="text-[10px] font-semibold uppercase tracking-wider text-slate-500">{titulo}</p>
      <p className={`text-sm font-bold tabular-nums ${destacado ? "text-[#0EA5E9]" : "text-slate-900"}`}>{valor}</p>
    </div>
  );
}
