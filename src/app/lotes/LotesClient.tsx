"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { FileText, Plus, RefreshCw, Settings2, Trash2, X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { getClientes } from "@/lib/clientes/storage";
import SmartSearchSelect, { type SmartOption } from "@/components/ui/SmartSearchSelect";
import { FancySelect } from "@/components/ui/FancySelect";
import MontoInput from "@/components/ui/MontoInput";
import ModalVenderLote from "./ModalVenderLote";
import ModalVenderContado from "./ModalVenderContado";
import type { Cliente } from "@/lib/clientes/types";
import {
  ESTADOS_LOTE,
  ESTADO_LOTE_UI,
  type EstadoLote,
  type EstructuraPayload,
  type Lote,
  type LotesPayload,
  type MonedaLote,
} from "@/lib/lotes/types";

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400";
const labelClass =
  "mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-500";

function etiquetaCliente(c: Cliente): string {
  return ((c.empresa ?? c.nombre_contacto) || "").trim() || "Cliente sin nombre";
}

function fmtMoneda(valor: number | null, moneda: MonedaLote): string {
  if (valor == null) return "—";
  if (moneda === "USD") return `USD ${valor.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`;
  return `Gs. ${Math.round(valor).toLocaleString("es-PY")}`;
}

function fmtM2(v: number | null): string {
  return v == null ? "—" : `${v.toLocaleString("es-PY")} m²`;
}

export default function LotesClient() {
  const [estructura, setEstructura] = useState<EstructuraPayload | null>(null);
  const [loteamientoId, setLoteamientoId] = useState("");
  const [manzanaId, setManzanaId] = useState("");
  const [filtroEstado, setFiltroEstado] = useState("");

  const [data, setData] = useState<LotesPayload | null>(null);
  const [clientes, setClientes] = useState<Cliente[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [errorEstructura, setErrorEstructura] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [seleccionado, setSeleccionado] = useState<Lote | null>(null);
  const [modalAlta, setModalAlta] = useState(false);
  const [vendiendo, setVendiendo] = useState<Lote | null>(null);
  const [vendiendoContado, setVendiendoContado] = useState<Lote | null>(null);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 4000);
  }, []);

  // Estructura y clientes se cargan una vez; alimentan selectores y etiquetas.
  // Si la estructura falla hay que decirlo: dejarla en null en silencio mostraba
  // la pantalla vacía como si no hubiera nada cargado, escondiendo el error real.
  useEffect(() => {
    (async () => {
      try {
        const r = await fetchWithSupabaseSession("/api/lotes/estructura", { cache: "no-store" });
        const j = (await r.json()) as { success?: boolean; error?: string; data?: EstructuraPayload };
        if (!r.ok || j.success !== true || !j.data) throw new Error(j.error ?? `Error ${r.status}`);
        setEstructura(j.data);
        if (j.data.loteamientos.length > 0) setLoteamientoId(j.data.loteamientos[0].id);
      } catch (e) {
        setEstructura(null);
        setErrorEstructura(e instanceof Error ? e.message : "No se pudo cargar la estructura del loteamiento");
      }
    })();
    getClientes().then(setClientes).catch(() => setClientes([]));
  }, []);

  const load = useCallback(async () => {
    if (!loteamientoId) {
      setData(null);
      setCargando(false);
      return;
    }
    setCargando(true);
    setError(null);
    try {
      const params = new URLSearchParams();
      if (manzanaId) params.set("manzana_id", manzanaId);
      else params.set("loteamiento_id", loteamientoId);
      if (filtroEstado) params.set("estado", filtroEstado);
      const res = await fetchWithSupabaseSession(`/api/lotes?${params.toString()}`, { cache: "no-store" });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: LotesPayload };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudieron cargar los lotes");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [loteamientoId, manzanaId, filtroEstado]);

  useEffect(() => {
    void load();
  }, [load]);

  const opcionesCliente: SmartOption[] = useMemo(
    () =>
      clientes.map((c) => ({
        id: c.id,
        label: etiquetaCliente(c),
        sub: c.codigo_cliente,
        keywords: `${c.ruc ?? ""} ${c.documento ?? ""} ${c.nombre_contacto ?? ""}`,
      })),
    [clientes]
  );

  /**
   * Manzanas del loteamiento elegido.
   *
   * La fracción solo aparece en la etiqueta cuando el loteamiento tiene más de
   * una: si hay una sola, nombrarla es ruido —el que carga piensa en "Manzana
   * B", no en "Fracción ÚNICA · Manzana B"—.
   */
  const manzanasDelLoteamiento = useMemo(() => {
    if (!estructura || !loteamientoId) return [];
    const fracciones = estructura.fracciones.filter((f) => f.loteamiento_id === loteamientoId);
    const porId = new Map(fracciones.map((f) => [f.id, f]));
    const varias = fracciones.length > 1;
    return estructura.manzanas
      .filter((m) => porId.has(m.fraccion_id))
      .map((m) => ({
        ...m,
        etiqueta: varias
          ? `Fracción ${porId.get(m.fraccion_id)?.codigo ?? "?"} · Manzana ${m.codigo}`
          : `Manzana ${m.codigo}`,
      }));
  }, [estructura, loteamientoId]);

  /** Lotes agrupados por manzana: es la vista que usa la gente en la cancha. */
  const grupos = useMemo(() => {
    const lotes = data?.lotes ?? [];
    const porManzana = new Map<string, Lote[]>();
    for (const l of lotes) {
      const arr = porManzana.get(l.manzana_id) ?? [];
      arr.push(l);
      porManzana.set(l.manzana_id, arr);
    }
    return manzanasDelLoteamiento
      .filter((m) => porManzana.has(m.id))
      .map((m) => ({ manzana: m, lotes: porManzana.get(m.id) ?? [] }));
  }, [data, manzanasDelLoteamiento]);

  const resumen = data?.resumen;
  const sinEstructura = estructura !== null && estructura.loteamientos.length === 0;

  return (
    <div className="w-full min-w-0 max-w-full space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Lotes</h1>
          <p className="mt-1 text-sm text-slate-500">
            Estado de cada lote del loteamiento: disponible, reservado, vendido o bloqueado.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Link
            href="/lotes/ventas"
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
          >
            <FileText className="h-3.5 w-3.5" />
            Contratos
          </Link>
          <Link
            href="/lotes/estructura"
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
          >
            <Settings2 className="h-3.5 w-3.5" />
            Estructura
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
          <button
            type="button"
            onClick={() => setModalAlta(true)}
            disabled={!loteamientoId}
            title={!loteamientoId ? "Elegí primero un loteamiento" : undefined}
            className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            <Plus className="h-3.5 w-3.5" />
            Nuevo lote
          </button>
        </div>
      </div>

      {errorEstructura ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">
          <p className="font-semibold">No se pudo cargar la estructura del loteamiento.</p>
          <p className="mt-0.5 text-xs">{errorEstructura}</p>
        </div>
      ) : null}

      {errorEstructura ? null : sinEstructura ? (
        <div className="rounded-2xl border border-slate-200 bg-white p-8 text-center">
          <p className="text-sm font-medium text-slate-700">Todavía no hay ningún loteamiento cargado.</p>
          <p className="mt-1 text-xs text-slate-500">
            Empezá creando el loteamiento; las manzanas se cargan después, o directo al crear el primer lote.
          </p>
          <Link
            href="/lotes/estructura"
            className="mt-4 inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7]"
          >
            <Settings2 className="h-3.5 w-3.5" />
            Ir a Estructura
          </Link>
        </div>
      ) : (
        <>
          {/* Filtros */}
          <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 lg:grid-cols-3">
            <div>
              <label className={labelClass}>Loteamiento</label>
              <FancySelect
                value={loteamientoId}
                onChange={(v) => {
                  setLoteamientoId(v);
                  setManzanaId("");
                }}
                options={(estructura?.loteamientos ?? []).map((l) => ({
                  value: l.id,
                  label: `${l.codigo} — ${l.nombre}`,
                }))}
              />
            </div>
            <div>
              <label className={labelClass}>Manzana</label>
              <FancySelect
                value={manzanaId}
                onChange={setManzanaId}
                options={[
                  { value: "", label: "Todas las manzanas" },
                  ...manzanasDelLoteamiento.map((m) => ({ value: m.id, label: m.etiqueta })),
                ]}
              />
            </div>
            <div>
              <label className={labelClass}>Estado</label>
              <FancySelect
                value={filtroEstado}
                onChange={setFiltroEstado}
                options={[
                  { value: "", label: "Todos los estados" },
                  ...ESTADOS_LOTE.map((e) => ({ value: e, label: ESTADO_LOTE_UI[e].label })),
                ]}
              />
            </div>
          </div>

          {/* Contadores por estado, que además filtran */}
          <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-6">
            <Tarjeta
              titulo="Total"
              valor={String(resumen?.total ?? 0)}
              activo={filtroEstado === ""}
              onClick={() => setFiltroEstado("")}
            />
            {ESTADOS_LOTE.map((e) => (
              <Tarjeta
                key={e}
                titulo={ESTADO_LOTE_UI[e].label}
                valor={String(resumen?.[e] ?? 0)}
                punto={ESTADO_LOTE_UI[e].punto}
                activo={filtroEstado === e}
                // Volver a tocar la tarjeta activa quita el filtro.
                onClick={() => setFiltroEstado((prev) => (prev === e ? "" : e))}
              />
            ))}
            <Tarjeta titulo="Superficie" valor={fmtM2(resumen?.superficie_total ?? 0)} />
          </div>

          {error ? (
            <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
          ) : null}

          {/* Grilla visual por manzana */}
          {cargando ? (
            <div className="rounded-2xl border border-slate-200 bg-white p-10 text-center text-sm text-slate-400">
              Cargando…
            </div>
          ) : grupos.length === 0 ? (
            <div className="rounded-2xl border border-slate-200 bg-white p-10 text-center text-sm text-slate-400">
              No hay lotes que coincidan con el filtro.
            </div>
          ) : (
            <div className="space-y-4">
              {grupos.map(({ manzana, lotes }) => (
                <div key={manzana.id} className="rounded-2xl border border-slate-200 bg-white p-4">
                  <div className="mb-3 flex items-center justify-between gap-3">
                    <h2 className="text-sm font-semibold text-slate-800">{manzana.etiqueta}</h2>
                    <span className="text-xs text-slate-500">{lotes.length} lote(s)</span>
                  </div>
                  <div className="grid grid-cols-3 gap-2 sm:grid-cols-6 lg:grid-cols-10">
                    {lotes.map((l) => (
                      <button
                        key={l.id}
                        type="button"
                        onClick={() => setSeleccionado(l)}
                        title={`Lote ${l.numero} — ${ESTADO_LOTE_UI[l.estado].label}${
                          l.cliente_label ? ` · ${l.cliente_label}` : ""
                        }`}
                        className={`flex flex-col items-center justify-center rounded-xl border px-2 py-3 text-center transition-colors ${
                          ESTADO_LOTE_UI[l.estado].celda
                        }`}
                      >
                        <span className="text-sm font-bold">{l.numero}</span>
                        <span className="mt-0.5 text-[10px] opacity-80">{fmtM2(l.superficie_m2)}</span>
                      </button>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )}

          {/* Leyenda */}
          <div className="flex flex-wrap items-center gap-4 text-xs text-slate-500">
            {ESTADOS_LOTE.map((e) => (
              <span key={e} className="inline-flex items-center gap-1.5">
                <span className={`h-2.5 w-2.5 rounded-full ${ESTADO_LOTE_UI[e].punto}`} />
                {ESTADO_LOTE_UI[e].label}
              </span>
            ))}
          </div>
        </>
      )}

      {seleccionado ? (
        <PanelLote
          lote={seleccionado}
          opcionesCliente={opcionesCliente}
          onVender={(l) => { setSeleccionado(null); setVendiendo(l); }}
        onVenderContado={(l) => { setSeleccionado(null); setVendiendoContado(l); }}
          onClose={() => setSeleccionado(null)}
          onSaved={async (msg) => {
            setSeleccionado(null);
            showToast(msg);
            await load();
          }}
        />
      ) : null}

      {modalAlta ? (
        <ModalNuevoLote
          loteamientoId={loteamientoId}
          manzanas={manzanasDelLoteamiento}
          manzanaPorDefecto={manzanaId || manzanasDelLoteamiento[0]?.id || ""}
          onCancel={() => setModalAlta(false)}
          onSaved={async (msg) => {
            setModalAlta(false);
            showToast(msg);
            await load();
          }}
        />
      ) : null}

      {vendiendo ? (
        <ModalVenderLote
          lote={vendiendo}
          opcionesCliente={opcionesCliente}
          onCancel={() => setVendiendo(null)}
          onVendido={async (msg) => {
            setVendiendo(null);
            showToast(msg);
            await load();
          }}
        />
      ) : null}

      {vendiendoContado ? (
        <ModalVenderContado
          lote={vendiendoContado}
          opcionesCliente={opcionesCliente}
          onCancel={() => setVendiendoContado(null)}
          onVendido={async (msg) => {
            setVendiendoContado(null);
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

function Tarjeta({
  titulo,
  valor,
  punto,
  activo,
  onClick,
}: {
  titulo: string;
  valor: string;
  punto?: string;
  activo?: boolean;
  onClick?: () => void;
}) {
  // Barra de color del estado arriba: la grilla de abajo usa el mismo código.
  const contenido = (
    <>
      <span className={`absolute inset-x-0 top-0 h-1 ${punto ?? "bg-slate-200"}`} />
      <p className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-slate-500">
        {punto ? <span className={`h-2 w-2 rounded-full ${punto}`} /> : null}
        {titulo}
      </p>
      <p className="mt-1.5 text-2xl font-bold tabular-nums tracking-tight text-slate-900">{valor}</p>
    </>
  );

  const base =
    "group relative w-full overflow-hidden rounded-2xl border bg-white p-5 text-left shadow-sm transition-all";

  if (!onClick) {
    return <div className={`${base} border-slate-200`}>{contenido}</div>;
  }

  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={activo === true}
      title={activo ? "Quitar el filtro" : `Ver solo ${titulo.toLowerCase()}`}
      className={`${base} hover:-translate-y-0.5 hover:shadow-md ${
        activo ? "border-[#0EA5E9] ring-2 ring-[#0EA5E9]/25" : "border-slate-200"
      }`}
    >
      {contenido}
    </button>
  );
}

/** Ficha lateral del lote: datos, precios y cambio de estado. */
function PanelLote({
  lote,
  opcionesCliente,
  onClose,
  onSaved,
  onVender,
  onVenderContado,
}: {
  lote: Lote;
  opcionesCliente: SmartOption[];
  onClose: () => void;
  onSaved: (msg: string) => void | Promise<void>;
  onVender: (lote: Lote) => void;
  onVenderContado: (lote: Lote) => void;
}) {
  const [form, setForm] = useState({
    numero: lote.numero,
    superficie_m2: lote.superficie_m2?.toString() ?? "",
    frente_m: lote.frente_m?.toString() ?? "",
    fondo_m: lote.fondo_m?.toString() ?? "",
    lindero_norte: lote.lindero_norte ?? "",
    lindero_sur: lote.lindero_sur ?? "",
    lindero_este: lote.lindero_este ?? "",
    lindero_oeste: lote.lindero_oeste ?? "",
    precio_contado: lote.precio_contado?.toString() ?? "",
    precio_financiado: lote.precio_financiado?.toString() ?? "",
    moneda: lote.moneda as MonedaLote,
    observacion: lote.observacion ?? "",
  });
  const [estado, setEstado] = useState<EstadoLote>(lote.estado);
  const [clienteId, setClienteId] = useState(lote.cliente_id ?? "");
  const [estadoMotivo, setEstadoMotivo] = useState(lote.estado_motivo ?? "");
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const exigeTitular = estado === "reservado" || estado === "vendido";
  const set = (k: keyof typeof form, v: string) => setForm((f) => ({ ...f, [k]: v }));

  async function guardar() {
    setErr(null);
    if (exigeTitular && !clienteId) {
      setErr(`Un lote ${ESTADO_LOTE_UI[estado].label.toLowerCase()} necesita un cliente asignado.`);
      return;
    }
    setGuardando(true);
    try {
      const res = await fetchWithSupabaseSession(`/api/lotes/${encodeURIComponent(lote.id)}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...form,
          estado,
          cliente_id: exigeTitular ? clienteId : null,
          estado_motivo: estadoMotivo,
        }),
      });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await onSaved("Lote actualizado.");
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo guardar");
    } finally {
      setGuardando(false);
    }
  }

  async function eliminar() {
    if (!window.confirm(`¿Eliminar el lote ${lote.numero}?`)) return;
    setGuardando(true);
    try {
      const res = await fetchWithSupabaseSession(`/api/lotes/${encodeURIComponent(lote.id)}`, { method: "DELETE" });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await onSaved("Lote eliminado.");
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo eliminar");
    } finally {
      setGuardando(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[60] flex justify-end bg-slate-900/40" onClick={onClose}>
      <div
        className="h-full w-full max-w-lg overflow-y-auto border-l border-slate-200 bg-white p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-slate-900">Lote {lote.numero}</h3>
            <span
              className={`mt-1 inline-block rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                ESTADO_LOTE_UI[lote.estado].chip
              }`}
            >
              {ESTADO_LOTE_UI[lote.estado].label}
            </span>
          </div>
          <button type="button" onClick={onClose} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-5 space-y-4">
          {lote.estado === "disponible" || lote.estado === "reservado" ? (
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => onVenderContado(lote)}
                className="rounded-xl bg-emerald-600 px-3 py-2.5 text-xs font-semibold text-white hover:bg-emerald-700"
              >
                Vender al contado
              </button>
              <button
                type="button"
                onClick={() => onVender(lote)}
                className="rounded-xl bg-[#0EA5E9] px-3 py-2.5 text-xs font-semibold text-white hover:bg-[#0284C7]"
              >
                Vender financiado
              </button>
            </div>
          ) : null}

          <section>
            <p className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-500">Estado comercial</p>
            <div className="grid gap-3">
              <div>
                <label className={labelClass}>Estado</label>
                <FancySelect
                  value={estado}
                  onChange={(v) => setEstado(v as EstadoLote)}
                  options={ESTADOS_LOTE.map((e) => ({ value: e, label: ESTADO_LOTE_UI[e].label }))}
                />
              </div>
              {exigeTitular ? (
                <div>
                  <label className={labelClass}>Cliente titular</label>
                  <SmartSearchSelect
                    options={opcionesCliente}
                    value={clienteId}
                    onChange={setClienteId}
                    placeholder="Buscar cliente…"
                  />
                </div>
              ) : null}
              {estado === "bloqueado" ? (
                <div>
                  <label className={labelClass}>Motivo del bloqueo</label>
                  <input
                    type="text"
                    value={estadoMotivo}
                    onChange={(e) => setEstadoMotivo(e.target.value)}
                    placeholder="Ej: litigio, reserva técnica"
                    className={inputClass}
                  />
                </div>
              ) : null}
            </div>
          </section>

          <section>
            <p className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-500">Identificación</p>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className={labelClass}>Número</label>
                <input value={form.numero} onChange={(e) => set("numero", e.target.value)} className={inputClass} />
              </div>
              <div>
                <label className={labelClass}>Superficie (m²)</label>
                <input
                  type="number"
                  value={form.superficie_m2}
                  onChange={(e) => set("superficie_m2", e.target.value)}
                  className={inputClass}
                />
              </div>
              <div>
                <label className={labelClass}>Frente (m)</label>
                <input
                  type="number"
                  value={form.frente_m}
                  onChange={(e) => set("frente_m", e.target.value)}
                  className={inputClass}
                />
              </div>
              <div>
                <label className={labelClass}>Fondo (m)</label>
                <input
                  type="number"
                  value={form.fondo_m}
                  onChange={(e) => set("fondo_m", e.target.value)}
                  className={inputClass}
                />
              </div>
            </div>
          </section>

          <section>
            <p className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-500">Linderos</p>
            <div className="grid grid-cols-2 gap-3">
              {(["norte", "sur", "este", "oeste"] as const).map((d) => (
                <div key={d}>
                  <label className={`${labelClass} capitalize`}>{d}</label>
                  <input
                    value={form[`lindero_${d}` as keyof typeof form] as string}
                    onChange={(e) => set(`lindero_${d}` as keyof typeof form, e.target.value)}
                    className={inputClass}
                  />
                </div>
              ))}
            </div>
          </section>

          <section>
            <p className="mb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-500">Precios de lista</p>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className={labelClass}>Contado</label>
                <MontoInput
                  value={form.precio_contado}
                  onChange={(n) => set("precio_contado", String(n))}
                  decimals={form.moneda === "USD"}
                  className={inputClass}
                />
              </div>
              <div>
                <label className={labelClass}>Financiado</label>
                <MontoInput
                  value={form.precio_financiado}
                  onChange={(n) => set("precio_financiado", String(n))}
                  decimals={form.moneda === "USD"}
                  className={inputClass}
                />
              </div>
              <div>
                <label className={labelClass}>Moneda</label>
                <FancySelect
                  value={form.moneda}
                  onChange={(v) => set("moneda", v)}
                  options={[
                    { value: "GS", label: "Gs." },
                    { value: "USD", label: "USD" },
                  ]}
                />
              </div>
            </div>
            <p className="mt-2 text-[11px] text-slate-400">
              Actual: contado {fmtMoneda(lote.precio_contado, lote.moneda)} · financiado{" "}
              {fmtMoneda(lote.precio_financiado, lote.moneda)}
            </p>
          </section>

          <section>
            <label className={labelClass}>Observación</label>
            <input
              value={form.observacion}
              onChange={(e) => set("observacion", e.target.value)}
              className={inputClass}
            />
          </section>
        </div>

        {err ? <p className="mt-3 text-xs text-rose-600">{err}</p> : null}

        <div className="mt-5 flex items-center justify-between gap-2">
          <button
            type="button"
            onClick={() => void eliminar()}
            disabled={guardando || lote.estado !== "disponible"}
            title={lote.estado !== "disponible" ? "Solo se puede eliminar un lote disponible" : undefined}
            className="inline-flex items-center gap-1.5 rounded-xl border border-rose-200 bg-white px-3 py-2 text-xs font-semibold text-rose-600 hover:bg-rose-50 disabled:opacity-40"
          >
            <Trash2 className="h-3.5 w-3.5" />
            Eliminar
          </button>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={onClose}
              disabled={guardando}
              className="rounded-xl border border-slate-200 bg-white px-3.5 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50 disabled:opacity-50"
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={() => void guardar()}
              disabled={guardando}
              className="rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
            >
              {guardando ? "Guardando…" : "Guardar"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

/** Valor especial del selector de manzana: pedir una nueva escribiéndola. */
const MANZANA_NUEVA = "__nueva__";

function ModalNuevoLote({
  loteamientoId,
  manzanas,
  manzanaPorDefecto,
  onCancel,
  onSaved,
}: {
  loteamientoId: string;
  manzanas: { id: string; etiqueta: string }[];
  manzanaPorDefecto: string;
  onCancel: () => void;
  onSaved: (msg: string) => void | Promise<void>;
}) {
  // Sin manzanas todavía, se arranca directo en "nueva": es el caso del
  // loteamiento recién creado, que es donde la gente se quedaba trabada.
  const [manzana, setManzana] = useState(manzanas.length === 0 ? MANZANA_NUEVA : manzanaPorDefecto);
  const [manzanaNueva, setManzanaNueva] = useState("");
  const [numero, setNumero] = useState("");
  const [superficie, setSuperficie] = useState("");
  const [frente, setFrente] = useState("");
  const [fondo, setFondo] = useState("");
  const [contado, setContado] = useState("");
  const [financiado, setFinanciado] = useState("");
  const [moneda, setMoneda] = useState<MonedaLote>("GS");
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function guardar() {
    setErr(null);
    setGuardando(true);
    try {
      const res = await fetchWithSupabaseSession("/api/lotes", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...(manzana === MANZANA_NUEVA
            ? { loteamiento_id: loteamientoId, manzana_codigo: manzanaNueva.trim() }
            : { manzana_id: manzana }),
          numero,
          superficie_m2: superficie,
          frente_m: frente,
          fondo_m: fondo,
          precio_contado: contado,
          precio_financiado: financiado,
          moneda,
        }),
      });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await onSaved("Lote creado.");
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo crear el lote");
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
          <div>
            <h3 className="text-base font-semibold text-slate-900">Nuevo lote</h3>
            <p className="mt-0.5 text-[11px] text-slate-500">Nace disponible; reservarlo o venderlo es otro paso.</p>
          </div>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-4 grid gap-3">
          <div>
            <label className={labelClass}>Manzana</label>
            <FancySelect
              value={manzana}
              onChange={setManzana}
              options={[
                ...manzanas.map((m) => ({ value: m.id, label: m.etiqueta })),
                { value: MANZANA_NUEVA, label: "+ Manzana nueva…" },
              ]}
            />
            {manzana === MANZANA_NUEVA ? (
              <>
                <input
                  value={manzanaNueva}
                  onChange={(e) => setManzanaNueva(e.target.value)}
                  placeholder="Ej: B"
                  className={`${inputClass} mt-2`}
                />
                <p className="mt-1 text-[11px] text-slate-400">
                  Se crea al guardar el lote. Si ya existe una manzana con ese nombre, el lote entra ahí.
                </p>
              </>
            ) : null}
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className={labelClass}>Número de lote</label>
              <input value={numero} onChange={(e) => setNumero(e.target.value)} className={inputClass} />
            </div>
            <div>
              <label className={labelClass}>Superficie (m²)</label>
              <input
                type="number"
                value={superficie}
                onChange={(e) => setSuperficie(e.target.value)}
                className={inputClass}
              />
            </div>
            <div>
              <label className={labelClass}>Frente (m)</label>
              <input type="number" value={frente} onChange={(e) => setFrente(e.target.value)} className={inputClass} />
            </div>
            <div>
              <label className={labelClass}>Fondo (m)</label>
              <input type="number" value={fondo} onChange={(e) => setFondo(e.target.value)} className={inputClass} />
            </div>
            <div>
              <label className={labelClass}>Precio contado</label>
              <MontoInput
                value={contado}
                onChange={(n) => setContado(String(n))}
                decimals={moneda === "USD"}
                className={inputClass}
              />
            </div>
            <div>
              <label className={labelClass}>Precio financiado</label>
              <MontoInput
                value={financiado}
                onChange={(n) => setFinanciado(String(n))}
                decimals={moneda === "USD"}
                className={inputClass}
              />
            </div>
            <div>
              <label className={labelClass}>Moneda</label>
              <FancySelect
                value={moneda}
                onChange={(v) => setMoneda(v as MonedaLote)}
                options={[
                  { value: "GS", label: "Gs." },
                  { value: "USD", label: "USD" },
                ]}
              />
            </div>
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
            onClick={() => void guardar()}
            disabled={
              guardando ||
              !numero.trim() ||
              (manzana === MANZANA_NUEVA ? !manzanaNueva.trim() : !manzana)
            }
            className="rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            {guardando ? "Creando…" : "Crear lote"}
          </button>
        </div>
      </div>
    </div>
  );
}
