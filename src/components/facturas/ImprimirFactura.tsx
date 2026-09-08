"use client";

import { useEffect, useState } from "react";
import { Eye, Printer } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";

/**
 * Emitir e imprimir la factura por autoimpresor.
 *
 * Son dos actos distintos y por eso son dos botones: emitir le clava el número
 * del timbrado y no tiene vuelta atrás; imprimir se puede repetir cuantas veces
 * haga falta. Mientras no esté emitida solo se ofrece la vista previa, que sale
 * marcada como sin numerar.
 */
export default function ImprimirFactura({ facturaId }: { facturaId: string }) {
  const [numero, setNumero] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);
  const [emitiendo, setEmitiendo] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const docUrl = `/api/facturas/${facturaId}/imprimir?auto=1`;

  useEffect(() => {
    let vivo = true;
    fetchWithSupabaseSession(`/api/facturas/${facturaId}/emitir`, { cache: "no-store" })
      .then((r) => r.json())
      .then((j: { success?: boolean; data?: { numero: string | null } }) => {
        if (vivo && j.success && j.data) setNumero(j.data.numero);
      })
      .catch(() => {})
      .finally(() => {
        if (vivo) setCargando(false);
      });
    return () => {
      vivo = false;
    };
  }, [facturaId]);

  async function emitir() {
    setEmitiendo(true);
    setError(null);
    try {
      const res = await fetchWithSupabaseSession(`/api/facturas/${facturaId}/emitir`, { method: "POST" });
      const j = (await res.json()) as { success?: boolean; data?: { numero: string }; error?: string };
      if (!res.ok || !j.success || !j.data) {
        setError(j.error ?? "No se pudo emitir la factura");
        return;
      }
      setNumero(j.data.numero);
      window.open(docUrl, "_blank", "noopener,noreferrer");
    } catch {
      setError("Error de red al emitir");
    } finally {
      setEmitiendo(false);
    }
  }

  const btn =
    "inline-flex items-center gap-1.5 text-xs font-semibold px-3 py-2 rounded-lg border border-slate-200 text-slate-700 hover:bg-slate-50";

  if (cargando) return <span className="text-xs text-slate-400">Cargando…</span>;

  return (
    <div className="flex flex-col items-end gap-1.5">
      <div className="flex gap-2">
        {numero ? (
          <a href={docUrl} target="_blank" rel="noopener" className={btn}>
            <Printer className="h-3.5 w-3.5" />
            Imprimir factura
          </a>
        ) : (
          <>
            <a href={docUrl} target="_blank" rel="noopener" className={btn}>
              <Eye className="h-3.5 w-3.5" />
              Vista previa
            </a>
            <button
              type="button"
              onClick={emitir}
              disabled={emitiendo}
              className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
            >
              <Printer className="h-3.5 w-3.5" />
              {emitiendo ? "Emitiendo…" : "Emitir e imprimir"}
            </button>
          </>
        )}
      </div>
      {numero ? (
        <p className="text-[11px] text-slate-500">
          Emitida con el N° <span className="font-semibold text-slate-700">{numero}</span>
        </p>
      ) : (
        <p className="text-[11px] text-slate-400">Todavía sin número de timbrado.</p>
      )}
      {error ? <p className="max-w-xs text-right text-[11px] text-red-600">{error}</p> : null}
    </div>
  );
}
