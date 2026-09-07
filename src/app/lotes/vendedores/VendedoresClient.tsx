"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { ArrowLeft, Pencil, Plus, RefreshCw, Trash2, X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { pctVisible } from "@/lib/vendedores/calculo-comision";
import type { Vendedor } from "@/lib/vendedores/types";

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400";
const labelClass =
  "mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-500";

export default function VendedoresClient() {
  const [vendedores, setVendedores] = useState<Vendedor[]>([]);
  const [incluirInactivos, setIncluirInactivos] = useState(true);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [modal, setModal] = useState<{ abierto: boolean; vendedor: Vendedor | null }>({
    abierto: false,
    vendedor: null,
  });

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 4000);
  }, []);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const qs = incluirInactivos ? "?incluir_inactivos=1" : "";
      const res = await fetchWithSupabaseSession(`/api/lotes/vendedores${qs}`, { cache: "no-store" });
      const json = (await res.json()) as {
        success?: boolean;
        error?: string;
        data?: { vendedores: Vendedor[] };
      };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setVendedores(json.data.vendedores);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudieron cargar los vendedores");
      setVendedores([]);
    } finally {
      setCargando(false);
    }
  }, [incluirInactivos]);

  useEffect(() => {
    void load();
  }, [load]);

  const borrar = useCallback(
    async (v: Vendedor) => {
      if (!window.confirm(`¿Borrar al vendedor ${v.nombre} (${v.codigo})?`)) return;
      try {
        const res = await fetchWithSupabaseSession(`/api/lotes/vendedores/${encodeURIComponent(v.id)}`, {
          method: "DELETE",
        });
        const json = (await res.json()) as { success?: boolean; error?: string };
        if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
        showToast("Vendedor borrado.");
        await load();
      } catch (e) {
        showToast(e instanceof Error ? e.message : "No se pudo borrar");
      }
    },
    [load, showToast]
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
          <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Vendedores</h1>
          <p className="mt-1 text-sm text-slate-500">
            Cada venta se asocia a un vendedor. Su comisión se liquida sobre las cuotas cobradas.
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
            onClick={() => setModal({ abierto: true, vendedor: null })}
            className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7]"
          >
            <Plus className="h-3.5 w-3.5" />
            Nuevo vendedor
          </button>
        </div>
      </div>

      <label className="inline-flex items-center gap-2 text-xs font-medium text-slate-600">
        <input
          type="checkbox"
          checked={incluirInactivos}
          onChange={(e) => setIncluirInactivos(e.target.checked)}
          className="h-3.5 w-3.5 rounded border-slate-300"
        />
        Mostrar también los inactivos
      </label>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[48rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50/70 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                <th className="px-4 py-3">Código</th>
                <th className="px-4 py-3">Nombre</th>
                <th className="px-4 py-3">Documento</th>
                <th className="px-4 py-3">Contacto</th>
                <th className="px-4 py-3 text-right">Comisión</th>
                <th className="px-4 py-3 text-right">Ventas</th>
                <th className="px-4 py-3">Estado</th>
                <th className="px-4 py-3" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {cargando ? (
                <tr>
                  <td colSpan={8} className="px-4 py-10 text-center text-sm text-slate-400">
                    Cargando…
                  </td>
                </tr>
              ) : vendedores.length === 0 ? (
                <tr>
                  <td colSpan={8} className="px-4 py-10 text-center text-sm text-slate-400">
                    Todavía no hay vendedores cargados.
                  </td>
                </tr>
              ) : (
                vendedores.map((v) => (
                  <tr key={v.id} className="hover:bg-slate-50/60">
                    <td className="px-4 py-3 font-semibold tabular-nums text-slate-900">{v.codigo}</td>
                    <td className="px-4 py-3 text-slate-800">{v.nombre}</td>
                    <td className="px-4 py-3 text-slate-600">{v.documento ?? "—"}</td>
                    <td className="px-4 py-3 text-xs text-slate-500">
                      {[v.telefono, v.email].filter(Boolean).join(" · ") || "—"}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-slate-800">
                      {pctVisible(v.comision_pct)}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-slate-600">{v.ventas ?? 0}</td>
                    <td className="px-4 py-3">
                      <span
                        className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                          v.activo
                            ? "border-emerald-200 bg-emerald-50 text-emerald-700"
                            : "border-slate-200 bg-slate-100 text-slate-500"
                        }`}
                      >
                        {v.activo ? "Activo" : "Inactivo"}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <button
                        type="button"
                        onClick={() => setModal({ abierto: true, vendedor: v })}
                        title="Editar vendedor"
                        className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                      >
                        <Pencil className="h-4 w-4" />
                      </button>
                      <button
                        type="button"
                        onClick={() => void borrar(v)}
                        title={
                          (v.ventas ?? 0) > 0
                            ? "Tiene ventas: marcalo inactivo en vez de borrarlo"
                            : "Borrar vendedor"
                        }
                        className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {modal.abierto ? (
        <ModalVendedor
          vendedor={modal.vendedor}
          onCancel={() => setModal({ abierto: false, vendedor: null })}
          onDone={async (msg) => {
            setModal({ abierto: false, vendedor: null });
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

/** Alta y edición comparten formulario, para que no se desvíen entre sí. */
function ModalVendedor({
  vendedor,
  onCancel,
  onDone,
}: {
  vendedor: Vendedor | null;
  onCancel: () => void;
  onDone: (msg: string) => void | Promise<void>;
}) {
  const editar = vendedor != null;
  const [codigo, setCodigo] = useState(vendedor?.codigo ?? "");
  const [nombre, setNombre] = useState(vendedor?.nombre ?? "");
  const [documento, setDocumento] = useState(vendedor?.documento ?? "");
  const [telefono, setTelefono] = useState(vendedor?.telefono ?? "");
  const [email, setEmail] = useState(vendedor?.email ?? "");
  // En porcentaje, como lo piensa el negocio; la API lo guarda como fracción.
  const [comision, setComision] = useState(
    vendedor ? String(Math.round(vendedor.comision_pct * 1e6) / 1e4) : "3"
  );
  const [activo, setActivo] = useState(vendedor?.activo ?? true);
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const invalido = !codigo.trim() || !nombre.trim() || guardando;

  async function guardar() {
    setErr(null);
    setGuardando(true);
    try {
      const url = editar
        ? `/api/lotes/vendedores/${encodeURIComponent(vendedor.id)}`
        : "/api/lotes/vendedores";
      const res = await fetchWithSupabaseSession(url, {
        method: editar ? "PATCH" : "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          codigo: codigo.trim(),
          nombre: nombre.trim(),
          documento: documento.trim() || null,
          telefono: telefono.trim() || null,
          email: email.trim() || null,
          comision_pct: comision,
          activo,
        }),
      });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await onDone(editar ? "Vendedor actualizado." : "Vendedor creado.");
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo guardar");
    } finally {
      setGuardando(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-slate-900/40 p-4" onClick={onCancel}>
      <div
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-2xl border border-slate-200 bg-white p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <h3 className="text-base font-semibold text-slate-900">
            {editar ? "Editar vendedor" : "Nuevo vendedor"}
          </h3>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div>
            <label className={labelClass}>Código</label>
            <input
              value={codigo}
              onChange={(e) => setCodigo(e.target.value)}
              placeholder="10663"
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Comisión (%)</label>
            <input
              type="number"
              min={0}
              max={100}
              step="0.01"
              value={comision}
              onChange={(e) => setComision(e.target.value)}
              onFocus={(e) => e.currentTarget.select()}
              className={inputClass}
            />
          </div>
          <div className="sm:col-span-2">
            <label className={labelClass}>Nombre</label>
            <input
              value={nombre}
              onChange={(e) => setNombre(e.target.value)}
              placeholder="Nombre y apellido"
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>
              Documento <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input value={documento} onChange={(e) => setDocumento(e.target.value)} className={inputClass} />
          </div>
          <div>
            <label className={labelClass}>
              Teléfono <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input value={telefono} onChange={(e) => setTelefono(e.target.value)} className={inputClass} />
          </div>
          <div className="sm:col-span-2">
            <label className={labelClass}>
              Email <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input value={email} onChange={(e) => setEmail(e.target.value)} className={inputClass} />
          </div>
          <label className="sm:col-span-2 inline-flex items-center gap-2 text-xs font-medium text-slate-600">
            <input
              type="checkbox"
              checked={activo}
              onChange={(e) => setActivo(e.target.checked)}
              className="h-3.5 w-3.5 rounded border-slate-300"
            />
            Activo (se ofrece al cargar ventas nuevas)
          </label>
        </div>

        <p className="mt-3 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-[11px] text-slate-500">
          Este porcentaje es el sugerido para las ventas nuevas. Cada contrato guarda el suyo, así que
          cambiarlo acá no altera las comisiones de las ventas ya cargadas.
        </p>

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
            disabled={invalido}
            className="rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            {guardando ? "Guardando…" : editar ? "Guardar cambios" : "Crear vendedor"}
          </button>
        </div>
      </div>
    </div>
  );
}
