"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { ArrowLeft, ChevronRight, Plus, RefreshCw, Trash2, X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import type { EstructuraPayload, NivelEstructura } from "@/lib/lotes/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";
const labelClass = "block text-xs font-medium text-slate-500 mb-1";

const TITULO_NIVEL: Record<NivelEstructura, string> = {
  loteamiento: "Loteamiento",
  fraccion: "Fracción",
  manzana: "Manzana",
};

export default function EstructuraClient() {
  const [data, setData] = useState<EstructuraPayload | null>(null);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [alta, setAlta] = useState<{ nivel: NivelEstructura; padreId: string; padreLabel: string } | null>(null);
  const [expandidos, setExpandidos] = useState<Set<string>>(new Set());

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 4000);
  }, []);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const res = await fetchWithSupabaseSession("/api/lotes/estructura", { cache: "no-store" });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: EstructuraPayload };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudo cargar la estructura");
    } finally {
      setCargando(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const toggle = (id: string) =>
    setExpandidos((prev) => {
      const s = new Set(prev);
      if (s.has(id)) s.delete(id);
      else s.add(id);
      return s;
    });

  const eliminar = useCallback(
    async (nivel: NivelEstructura, id: string, label: string) => {
      const ok = window.confirm(
        `¿Eliminar ${TITULO_NIVEL[nivel].toLowerCase()} "${label}"?\n\nSe elimina también todo lo que cuelga debajo.`
      );
      if (!ok) return;
      try {
        const res = await fetchWithSupabaseSession(
          `/api/lotes/estructura/${encodeURIComponent(id)}?nivel=${nivel}`,
          { method: "DELETE" }
        );
        const json = (await res.json()) as { success?: boolean; error?: string };
        if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
        showToast("Eliminado.");
        await load();
      } catch (e) {
        showToast(e instanceof Error ? e.message : "No se pudo eliminar");
      }
    },
    [load, showToast]
  );

  /**
   * El árbol, con la fracción escondida cuando hay una sola.
   *
   * El modelo sigue siendo loteamiento → fracción → manzana, pero un
   * loteamiento sin fraccionar no tiene por qué mostrar un nivel intermedio
   * vacío de sentido: se listan sus manzanas directo. El nivel reaparece solo
   * cuando de verdad hay más de una fracción.
   */
  const arbol = useMemo(() => {
    if (!data) return [];
    return data.loteamientos.map((lo) => {
      const fracciones = data.fracciones
        .filter((f) => f.loteamiento_id === lo.id)
        .map((f) => ({ ...f, manzanas: data.manzanas.filter((m) => m.fraccion_id === f.id) }));
      return {
        ...lo,
        fracciones,
        manzanas: fracciones.flatMap((f) => f.manzanas),
        variasFracciones: fracciones.length > 1,
      };
    });
  }, [data]);

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
          <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Estructura del loteamiento</h1>
          <p className="mt-1 text-sm text-slate-500">
            Loteamientos y sus manzanas. La fracción solo hace falta si el loteamiento viene dividido.
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
          <button
            type="button"
            onClick={() => setAlta({ nivel: "loteamiento", padreId: "", padreLabel: "" })}
            className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7]"
          >
            <Plus className="h-3.5 w-3.5" />
            Nuevo loteamiento
          </button>
        </div>
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      {cargando ? (
        <div className="rounded-2xl border border-slate-200 bg-white p-10 text-center text-sm text-slate-400">
          Cargando…
        </div>
      ) : arbol.length === 0 ? (
        <div className="rounded-2xl border border-slate-200 bg-white p-10 text-center">
          <p className="text-sm font-medium text-slate-700">Todavía no hay loteamientos.</p>
          <p className="mt-1 text-xs text-slate-500">Creá el primero y después cargá sus manzanas.</p>
        </div>
      ) : (
        <div className="space-y-3">
          {arbol.map((lo) => (
            <div key={lo.id} className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
              <div className="flex flex-wrap items-center justify-between gap-2 border-b border-slate-100 px-4 py-3">
                <button
                  type="button"
                  onClick={() => toggle(lo.id)}
                  className="flex min-w-0 items-center gap-2 text-left"
                >
                  <ChevronRight
                    className={`h-4 w-4 shrink-0 text-slate-400 transition-transform ${
                      expandidos.has(lo.id) ? "rotate-90" : ""
                    }`}
                  />
                  <span className="truncate text-sm font-semibold text-slate-900">
                    {lo.codigo} — {lo.nombre}
                  </span>
                  {lo.ubicacion ? (
                    <span className="truncate text-xs text-slate-400">· {lo.ubicacion}</span>
                  ) : null}
                </button>
                <div className="flex items-center gap-2">
                  <span className="text-xs text-slate-500">
                    {lo.manzanas.length} manzana{lo.manzanas.length === 1 ? "" : "s"}
                    {lo.variasFracciones ? ` · ${lo.fracciones.length} fracciones` : ""}
                  </span>
                  {/* La manzana cuelga directo del loteamiento: la fracción, si
                      hace falta, la resuelve el servidor. */}
                  <button
                    type="button"
                    onClick={() =>
                      setAlta({ nivel: "manzana", padreId: lo.id, padreLabel: `${lo.codigo} — ${lo.nombre}` })
                    }
                    className="rounded-lg bg-[#0EA5E9] px-2 py-1 text-[11px] font-semibold text-white hover:bg-[#0284C7]"
                  >
                    + Manzana
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      setAlta({ nivel: "fraccion", padreId: lo.id, padreLabel: `${lo.codigo} — ${lo.nombre}` })
                    }
                    title="Solo si el loteamiento viene dividido en fracciones"
                    className="rounded-lg border border-slate-200 px-2 py-1 text-[11px] font-semibold text-slate-500 hover:bg-slate-50"
                  >
                    + Fracción
                  </button>
                  <button
                    type="button"
                    onClick={() => void eliminar("loteamiento", lo.id, lo.nombre)}
                    className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>

              {expandidos.has(lo.id) ? (
                <div className="divide-y divide-slate-100">
                  {!lo.variasFracciones ? (
                    <div className="px-4 py-3">
                      {lo.manzanas.length === 0 ? (
                        <p className="text-xs text-slate-400">
                          Sin manzanas todavía. Creá la primera con <strong>+ Manzana</strong> y después cargá
                          sus lotes.
                        </p>
                      ) : (
                        <div className="flex flex-wrap gap-2">
                          {lo.manzanas.map((mz) => (
                            <span
                              key={mz.id}
                              className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs text-slate-700"
                            >
                              Manzana {mz.codigo}
                              <button
                                type="button"
                                onClick={() => void eliminar("manzana", mz.id, mz.codigo)}
                                className="text-slate-400 hover:text-rose-600"
                              >
                                <X className="h-3 w-3" />
                              </button>
                            </span>
                          ))}
                        </div>
                      )}
                    </div>
                  ) : (
                    lo.fracciones.map((fr) => (
                      <div key={fr.id} className="px-4 py-3">
                        <div className="flex flex-wrap items-center justify-between gap-2">
                          <span className="text-sm font-medium text-slate-800">
                            Fracción {fr.codigo}
                            {fr.nombre ? <span className="ml-2 text-xs text-slate-500">{fr.nombre}</span> : null}
                          </span>
                          <div className="flex items-center gap-2">
                            <button
                              type="button"
                              onClick={() =>
                                setAlta({ nivel: "manzana", padreId: fr.id, padreLabel: `Fracción ${fr.codigo}` })
                              }
                              className="rounded-lg border border-slate-200 px-2 py-1 text-[11px] font-semibold text-slate-600 hover:bg-slate-50"
                            >
                              + Manzana
                            </button>
                            <button
                              type="button"
                              onClick={() => void eliminar("fraccion", fr.id, fr.codigo)}
                              className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                            >
                              <Trash2 className="h-3.5 w-3.5" />
                            </button>
                          </div>
                        </div>
                        <div className="mt-2 flex flex-wrap gap-2">
                          {fr.manzanas.length === 0 ? (
                            <span className="text-xs text-slate-400">Sin manzanas.</span>
                          ) : (
                            fr.manzanas.map((mz) => (
                              <span
                                key={mz.id}
                                className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs text-slate-700"
                              >
                                Manzana {mz.codigo}
                                <button
                                  type="button"
                                  onClick={() => void eliminar("manzana", mz.id, mz.codigo)}
                                  className="text-slate-400 hover:text-rose-600"
                                >
                                  <X className="h-3 w-3" />
                                </button>
                              </span>
                            ))
                          )}
                        </div>
                      </div>
                    ))
                  )}
                </div>
              ) : null}
            </div>
          ))}
        </div>
      )}

      {alta ? (
        <ModalAlta
          nivel={alta.nivel}
          padreId={alta.padreId}
          padreLabel={alta.padreLabel}
          onCancel={() => setAlta(null)}
          onSaved={async (msg) => {
            setAlta(null);
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

function ModalAlta({
  nivel,
  padreId,
  padreLabel,
  onCancel,
  onSaved,
}: {
  nivel: NivelEstructura;
  padreId: string;
  padreLabel: string;
  onCancel: () => void;
  onSaved: (msg: string) => void | Promise<void>;
}) {
  const [codigo, setCodigo] = useState("");
  const [nombre, setNombre] = useState("");
  const [ubicacion, setUbicacion] = useState("");
  const [orden, setOrden] = useState("0");
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const esLoteamiento = nivel === "loteamiento";
  const invalido = !codigo.trim() || (esLoteamiento && !nombre.trim());

  async function guardar() {
    setErr(null);
    setGuardando(true);
    try {
      const res = await fetchWithSupabaseSession("/api/lotes/estructura", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          nivel,
          padre_id: padreId || undefined,
          codigo: codigo.trim(),
          nombre: nombre.trim(),
          ubicacion: esLoteamiento ? ubicacion.trim() : undefined,
          orden: esLoteamiento ? undefined : Number(orden) || 0,
        }),
      });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await onSaved(`${TITULO_NIVEL[nivel]} creada.`);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo crear");
    } finally {
      setGuardando(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-slate-900/40 p-4" onClick={onCancel}>
      <div
        className="w-full max-w-md rounded-2xl border border-slate-200 bg-white p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-slate-900">Nueva {TITULO_NIVEL[nivel].toLowerCase()}</h3>
            {padreLabel ? <p className="mt-0.5 text-[11px] text-slate-500">Dentro de {padreLabel}</p> : null}
          </div>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-4 grid gap-3">
          <div>
            <label className={labelClass}>Código</label>
            <input
              value={codigo}
              onChange={(e) => setCodigo(e.target.value)}
              placeholder={esLoteamiento ? "Ej: SC" : "Ej: A"}
              className={inputClass}
            />
            <p className="mt-1 text-[11px] text-slate-400">
              Tiene que ser único {esLoteamiento ? "en la empresa" : "dentro de su padre"}.
            </p>
          </div>
          <div>
            <label className={labelClass}>
              Nombre {esLoteamiento ? "" : <span className="font-normal text-slate-400">(opcional)</span>}
            </label>
            <input value={nombre} onChange={(e) => setNombre(e.target.value)} className={inputClass} />
          </div>
          {esLoteamiento ? (
            <div>
              <label className={labelClass}>
                Ubicación <span className="font-normal text-slate-400">(opcional)</span>
              </label>
              <input value={ubicacion} onChange={(e) => setUbicacion(e.target.value)} className={inputClass} />
            </div>
          ) : (
            <div>
              <label className={labelClass}>Orden</label>
              <input type="number" value={orden} onChange={(e) => setOrden(e.target.value)} className={inputClass} />
            </div>
          )}
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
            onClick={() => void guardar()}
            disabled={guardando || invalido}
            className="rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            {guardando ? "Creando…" : "Crear"}
          </button>
        </div>
      </div>
    </div>
  );
}
