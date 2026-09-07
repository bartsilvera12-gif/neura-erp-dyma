"use client";

import { useEffect, useState } from "react";
import { FileText, Printer, ReceiptText, ScrollText } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import type { VentaResumen } from "@/lib/financiacion/types";

/**
 * Los documentos imprimibles del cliente, todos desde un lugar.
 *
 * La ficha es siempre una; el contrato, el plan de pago y los pagarés son por
 * contrato, porque un cliente puede tener más de un lote. Cada uno se abre en
 * pestaña nueva y trae su propio botón de imprimir.
 */
export default function DocumentosCliente({ clienteId }: { clienteId: string }) {
  const [ventas, setVentas] = useState<VentaResumen[]>([]);
  const [cargando, setCargando] = useState(true);

  useEffect(() => {
    fetchWithSupabaseSession(`/api/lotes/ventas?cliente_id=${encodeURIComponent(clienteId)}`, {
      cache: "no-store",
    })
      .then((r) => r.json())
      .then((j: { success?: boolean; data?: { ventas: VentaResumen[] } }) => {
        setVentas(j.success === true && j.data ? j.data.ventas : []);
      })
      .catch(() => setVentas([]))
      .finally(() => setCargando(false));
  }, [clienteId]);

  const btn =
    "inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 transition-colors hover:border-slate-300 hover:bg-slate-50";

  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">Documentos</p>
      <p className="mt-0.5 text-xs text-slate-500">
        Se abren en una pestaña nueva, listos para imprimir o guardar como PDF.
      </p>

      <div className="mt-3">
        <a
          href={`/api/clientes/${encodeURIComponent(clienteId)}/ficha`}
          target="_blank"
          rel="noopener"
          className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7]"
        >
          <Printer className="h-3.5 w-3.5" />
          Ficha del cliente
        </a>
        <span className="ml-2 text-[11px] text-slate-400">
          Datos, lotes, estado de pago y servicios de limpieza.
        </span>
      </div>

      {cargando ? (
        <p className="mt-4 text-xs text-slate-400">Buscando contratos…</p>
      ) : ventas.length === 0 ? (
        <p className="mt-4 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2.5 text-xs text-slate-500">
          Este cliente todavía no tiene contratos de lote. El contrato, el plan de pago y los pagarés aparecen
          acá cuando se le venda uno.
        </p>
      ) : (
        <div className="mt-4 space-y-2.5">
          {ventas.map((v) => (
            <div
              key={v.id}
              className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-slate-200 bg-slate-50/60 px-3 py-2.5"
            >
              <div className="min-w-0">
                <p className="text-sm font-semibold text-slate-900">{v.numero_contrato}</p>
                <p className="text-[11px] text-slate-500">
                  {v.lote_label} · {v.modalidad === "contado" ? "Contado" : `${v.cantidad_cuotas} cuotas`}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <a href={`/api/lotes/ventas/${v.id}/contrato`} target="_blank" rel="noopener" className={btn}>
                  <ScrollText className="h-3.5 w-3.5" />
                  Contrato
                </a>
                {/* Sin cuotas no hay plan ni pagarés que emitir. */}
                {v.modalidad === "financiada" ? (
                  <>
                    <a href={`/api/lotes/ventas/${v.id}/plan`} target="_blank" rel="noopener" className={btn}>
                      <FileText className="h-3.5 w-3.5" />
                      Plan de pago
                    </a>
                    <a href={`/api/lotes/ventas/${v.id}/pagares`} target="_blank" rel="noopener" className={btn}>
                      <ReceiptText className="h-3.5 w-3.5" />
                      Pagarés
                    </a>
                  </>
                ) : null}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
