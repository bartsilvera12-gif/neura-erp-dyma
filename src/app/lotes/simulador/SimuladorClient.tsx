"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { ArrowLeft, Check, RefreshCw, Save, Trash2, Undo2 } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { getClientes } from "@/lib/clientes/storage";
import SmartSearchSelect, { type SmartOption } from "@/components/ui/SmartSearchSelect";
import MontoInput from "@/components/ui/MontoInput";
import { FechaSelect } from "@/components/ui/FechaSelect";
import ModalVenderLote, { type CondicionesIniciales } from "../ModalVenderLote";
import {
  FRECUENCIAS,
  RECARGO_FINANCIACION,
  simularPlan,
  type Frecuencia,
  type Simulacion,
} from "@/lib/financiacion/plan-cuotas";
import { ESTADO_SIMULACION_UI, type SimulacionGuardada } from "@/lib/financiacion/simulaciones";
import type { Cliente } from "@/lib/clientes/types";
import type { Lote } from "@/lib/lotes/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";
const labelClass = "block text-xs font-medium text-slate-500 mb-1";

const gs = (v: number) => `Gs. ${Math.round(v).toLocaleString("es-PY")}`;

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

/** Qué dato pone el usuario y cuál deduce el sistema. */
type Modo = "por_cuota" | "por_cantidad";

export default function SimuladorClient() {
  const [clienteId, setClienteId] = useState("");
  const [loteId, setLoteId] = useState("");
  const [nombre, setNombre] = useState("");
  const [precio, setPrecio] = useState("0");
  const [entrega, setEntrega] = useState("0");
  const [modo, setModo] = useState<Modo>("por_cuota");
  const [cuotaPropuesta, setCuotaPropuesta] = useState("0");
  const [cantidadCuotas, setCantidadCuotas] = useState("12");
  const [primerVencimiento, setPrimerVencimiento] = useState(hoyYmd());
  const [frecuencia, setFrecuencia] = useState<Frecuencia>("mensual");
  const [recargoPct, setRecargoPct] = useState(String(RECARGO_FINANCIACION * 100));
  const [observacion, setObservacion] = useState("");

  const [clientes, setClientes] = useState<Cliente[]>([]);
  const [lotes, setLotes] = useState<Lote[]>([]);
  const [historial, setHistorial] = useState<SimulacionGuardada[]>([]);
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [vendiendo, setVendiendo] = useState<{ lote: Lote; inicial: CondicionesIniciales } | null>(null);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 4000);
  }, []);

  useEffect(() => {
    getClientes().then(setClientes).catch(() => setClientes([]));
    fetchWithSupabaseSession("/api/lotes", { cache: "no-store" })
      .then((r) => r.json())
      .then((j: { success?: boolean; data?: { lotes?: Lote[] } }) => {
        setLotes(j.success === true && j.data?.lotes ? j.data.lotes : []);
      })
      .catch(() => setLotes([]));
  }, []);

  const cargarHistorial = useCallback(async () => {
    try {
      const qs = clienteId ? `?cliente_id=${encodeURIComponent(clienteId)}` : "";
      const res = await fetchWithSupabaseSession(`/api/lotes/simulaciones${qs}`, { cache: "no-store" });
      const json = (await res.json()) as { success?: boolean; data?: { simulaciones: SimulacionGuardada[] } };
      setHistorial(json.success === true && json.data ? json.data.simulaciones : []);
    } catch {
      setHistorial([]);
    }
  }, [clienteId]);

  useEffect(() => {
    void cargarHistorial();
  }, [cargarHistorial]);

  const opcionesCliente: SmartOption[] = useMemo(
    () =>
      clientes.map((c) => ({
        id: c.id,
        label: ((c.empresa ?? c.nombre_contacto) || "").trim() || "Cliente sin nombre",
        sub: c.codigo_cliente,
        keywords: `${c.ruc ?? ""} ${c.documento ?? ""} ${c.nombre_contacto ?? ""}`,
      })),
    [clientes]
  );

  const loteElegido = lotes.find((l) => l.id === loteId) ?? null;

  /** El cálculo corre en cada tecla: es la herramienta de análisis que se pide. */
  const resultado = useMemo(() => {
    try {
      const plan = simularPlan({
        precioContado: Number(precio),
        entregaInicial: Number(entrega),
        primerVencimiento,
        frecuencia,
        recargo: Number(recargoPct) / 100,
        cantidadCuotas: modo === "por_cantidad" ? Number(cantidadCuotas) : undefined,
        cuotaPropuesta: modo === "por_cuota" ? Number(cuotaPropuesta) : undefined,
      });
      return { plan, error: null as string | null };
    } catch (e) {
      return { plan: null as Simulacion | null, error: e instanceof Error ? e.message : "Datos inválidos" };
    }
  }, [precio, entrega, primerVencimiento, frecuencia, recargoPct, modo, cantidadCuotas, cuotaPropuesta]);

  const p = resultado.plan;

  async function guardar() {
    if (!p) return;
    setErr(null);
    setGuardando(true);
    try {
      const res = await fetchWithSupabaseSession("/api/lotes/simulaciones", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          cliente_id: clienteId || null,
          lote_id: loteId || null,
          nombre: nombre.trim() || null,
          precio_contado: Number(precio),
          entrega_inicial: Number(entrega),
          recargo_pct: Number(recargoPct) / 100,
          frecuencia,
          primer_vencimiento: primerVencimiento,
          cantidad_cuotas: modo === "por_cantidad" ? Number(cantidadCuotas) : null,
          cuota_propuesta: modo === "por_cuota" ? Number(cuotaPropuesta) : null,
          observacion: observacion.trim() || null,
        }),
      });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      showToast("Simulación guardada en el historial.");
      setNombre("");
      await cargarHistorial();
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo guardar la simulación");
    } finally {
      setGuardando(false);
    }
  }

  /** Vuelve a poner una propuesta guardada en el formulario, para seguir tocándola. */
  function retomar(s: SimulacionGuardada) {
    setClienteId(s.cliente_id ?? "");
    setLoteId(s.lote_id ?? "");
    setPrecio(String(s.precio_contado));
    setEntrega(String(s.entrega_inicial));
    setRecargoPct(String(s.recargo_pct * 100));
    setFrecuencia(s.frecuencia);
    setPrimerVencimiento(s.primer_vencimiento);
    setModo(s.modo);
    if (s.modo === "por_cuota") setCuotaPropuesta(String(s.cuota_propuesta ?? 0));
    else setCantidadCuotas(String(s.cantidad_cuotas));
    setObservacion(s.observacion ?? "");
    setNombre(s.nombre ? `${s.nombre} (copia)` : "");
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function cambiarEstado(s: SimulacionGuardada, estado: "borrador" | "descartada") {
    try {
      const res = await fetchWithSupabaseSession(`/api/lotes/simulaciones/${encodeURIComponent(s.id)}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ estado }),
      });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await cargarHistorial();
    } catch (e) {
      showToast(e instanceof Error ? e.message : "No se pudo cambiar el estado");
    }
  }

  async function borrar(s: SimulacionGuardada) {
    if (!window.confirm("¿Borrar esta simulación del historial?")) return;
    try {
      const res = await fetchWithSupabaseSession(`/api/lotes/simulaciones/${encodeURIComponent(s.id)}`, {
        method: "DELETE",
      });
      const json = (await res.json()) as { success?: boolean; error?: string };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      await cargarHistorial();
    } catch (e) {
      showToast(e instanceof Error ? e.message : "No se pudo borrar");
    }
  }

  /** Abre la venta con las condiciones de la propuesta ya cargadas. */
  function generarContrato(s: SimulacionGuardada) {
    const lote = lotes.find((l) => l.id === s.lote_id);
    if (!lote) {
      showToast("Esta simulación no tiene un lote asignado, o el lote ya no está disponible.");
      return;
    }
    setVendiendo({
      lote,
      inicial: {
        simulacion_id: s.id,
        cliente_id: s.cliente_id,
        precio_contado: s.precio_contado,
        entrega_inicial: s.entrega_inicial,
        cantidad_cuotas: s.cantidad_cuotas,
        primer_vencimiento: s.primer_vencimiento,
        recargo_pct: s.recargo_pct,
        frecuencia: s.frecuencia,
      },
    });
  }

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
          <h1 className="text-2xl font-bold text-gray-800">Simulador de plan de pago</h1>
          <p className="mt-0.5 text-sm text-gray-500">
            Probá propuestas antes de firmar. Nada de esto genera contrato ni cuotas hasta que lo apruebes.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void cargarHistorial()}
          className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-600 hover:bg-slate-50"
        >
          <RefreshCw className="h-3.5 w-3.5" />
          Actualizar historial
        </button>
      </div>

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,20rem)]">
        {/* Entrada */}
        <div className="space-y-4 rounded-2xl border border-slate-200 bg-white p-4">
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className={labelClass}>
                Cliente <span className="font-normal text-slate-400">(opcional)</span>
              </label>
              <SmartSearchSelect
                options={[{ id: "", label: "Sin cliente" }, ...opcionesCliente]}
                value={clienteId}
                onChange={setClienteId}
                placeholder="Buscar cliente…"
              />
            </div>
            <div>
              <label className={labelClass}>
                Lote <span className="font-normal text-slate-400">(necesario para generar contrato)</span>
              </label>
              <select value={loteId} onChange={(e) => setLoteId(e.target.value)} className={inputClass}>
                <option value="">Sin lote</option>
                {lotes
                  .filter((l) => l.estado === "disponible" || l.estado === "reservado" || l.id === loteId)
                  .map((l) => (
                    <option key={l.id} value={l.id}>
                      Lote {l.numero} — {l.estado}
                    </option>
                  ))}
              </select>
            </div>

            <div>
              <label className={labelClass}>Valor total del lote</label>
              <MontoInput
                value={precio}
                onChange={(n) => setPrecio(String(n))}
                decimals={false}
                onFocus={(e) => e.currentTarget.select()}
                className={inputClass}
              />
              {loteElegido && Number(precio) === 0 ? (
                <button
                  type="button"
                  onClick={() => setPrecio(String(loteElegido.precio_contado ?? 0))}
                  className="mt-1 text-[11px] font-medium text-[#0EA5E9] hover:underline"
                >
                  Usar el precio del lote ({gs(loteElegido.precio_contado ?? 0)})
                </button>
              ) : null}
            </div>
            <div>
              <label className={labelClass}>Entrega inicial</label>
              <MontoInput
                value={entrega}
                onChange={(n) => setEntrega(String(n))}
                decimals={false}
                onFocus={(e) => e.currentTarget.select()}
                className={inputClass}
              />
            </div>
          </div>

          <div className="rounded-xl border border-slate-200 bg-slate-50/60 p-3">
            <p className="mb-2 text-xs font-semibold text-slate-600">¿Qué dato conocés?</p>
            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                onClick={() => setModo("por_cuota")}
                className={`rounded-lg border px-3 py-1.5 text-xs font-semibold ${
                  modo === "por_cuota"
                    ? "border-[#0EA5E9] bg-[#0EA5E9] text-white"
                    : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"
                }`}
              >
                La cuota que puede pagar
              </button>
              <button
                type="button"
                onClick={() => setModo("por_cantidad")}
                className={`rounded-lg border px-3 py-1.5 text-xs font-semibold ${
                  modo === "por_cantidad"
                    ? "border-[#0EA5E9] bg-[#0EA5E9] text-white"
                    : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"
                }`}
              >
                En cuántas cuotas
              </button>
            </div>

            <div className="mt-3">
              {modo === "por_cuota" ? (
                <>
                  <label className={labelClass}>Cuota propuesta por el cliente</label>
                  <MontoInput
                    value={cuotaPropuesta}
                    onChange={(n) => setCuotaPropuesta(String(n))}
                    decimals={false}
                    onFocus={(e) => e.currentTarget.select()}
                    className={inputClass}
                  />
                </>
              ) : (
                <>
                  <label className={labelClass}>Cantidad de cuotas</label>
                  <input
                    type="number"
                    min={1}
                    value={cantidadCuotas}
                    onChange={(e) => setCantidadCuotas(e.target.value)}
                    onFocus={(e) => e.currentTarget.select()}
                    className={inputClass}
                  />
                </>
              )}
            </div>
          </div>

          <div className="grid gap-3 sm:grid-cols-3">
            <div>
              <label className={labelClass}>Inicio de las cuotas</label>
              <FechaSelect
                value={primerVencimiento}
                onChange={(e) => setPrimerVencimiento(e.target.value)}
                className={inputClass}
              />
            </div>
            <div>
              <label className={labelClass}>Frecuencia</label>
              <select
                value={frecuencia}
                onChange={(e) => setFrecuencia(e.target.value as Frecuencia)}
                className={inputClass}
              >
                {Object.entries(FRECUENCIAS).map(([k, f]) => (
                  <option key={k} value={k}>
                    {f.label}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className={labelClass}>Recargo (%)</label>
              <input
                type="number"
                min={0}
                max={100}
                step="0.01"
                value={recargoPct}
                onChange={(e) => setRecargoPct(e.target.value)}
                onFocus={(e) => e.currentTarget.select()}
                className={inputClass}
              />
              <p className="mt-1 text-[10px] text-slate-400">
                El estándar es {RECARGO_FINANCIACION * 100}%. Ponelo en 0 para una condición especial.
              </p>
            </div>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <label className={labelClass}>
                Nombre de la propuesta <span className="font-normal text-slate-400">(opcional)</span>
              </label>
              <input
                value={nombre}
                onChange={(e) => setNombre(e.target.value)}
                placeholder="Ej: Contrapropuesta del cliente"
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

          {err ? <p className="text-xs text-rose-600">{err}</p> : null}

          <button
            type="button"
            onClick={() => void guardar()}
            disabled={!p || guardando}
            className="inline-flex items-center gap-1.5 rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            <Save className="h-3.5 w-3.5" />
            {guardando ? "Guardando…" : "Guardar esta propuesta"}
          </button>
        </div>

        {/* Resultado */}
        <div className="space-y-3">
          {resultado.error ? (
            <div className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-xs text-amber-800">
              {resultado.error}
            </div>
          ) : p ? (
            <>
              <div className="rounded-2xl border border-slate-200 bg-white p-4">
                <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                  Resultado de la simulación
                </p>
                <dl className="mt-2 space-y-1.5 text-sm">
                  <Fila k="Valor del lote" v={gs(p.precio_contado)} />
                  <Fila k="Entrega" v={gs(p.entrega_inicial)} />
                  <Fila k="Saldo a financiar" v={gs(p.capital)} />
                  {p.interes_total > 0 ? (
                    <Fila k={`Recargo ${(p.recargo_pct * 100).toFixed(2).replace(/\.?0+$/, "")}%`} v={gs(p.interes_total)} />
                  ) : null}
                  <Fila k="Saldo financiado" v={gs(p.monto_financiado)} destacado />
                </dl>
              </div>

              <div className="rounded-2xl border-2 border-[#0EA5E9] bg-sky-50/50 p-4">
                <p className="text-3xl font-bold tabular-nums text-[#0EA5E9]">{p.cantidad_cuotas}</p>
                <p className="text-xs font-semibold text-slate-600">
                  cuotas {FRECUENCIAS[p.frecuencia].label.toLowerCase()}es de{" "}
                  <span className="tabular-nums">{gs(p.cuota)}</span>
                </p>
                {p.cuota_final !== p.cuota ? (
                  <p className="mt-1 text-[11px] text-slate-500">
                    La última es de {gs(p.cuota_final)} y cierra el saldo exacto.
                  </p>
                ) : null}
                {p.modo === "por_cuota" && p.cuota_propuesta && p.cuota !== p.cuota_propuesta ? (
                  <p className="mt-1 text-[11px] text-slate-500">
                    Pidió {gs(p.cuota_propuesta)}: con {p.cantidad_cuotas} cuotas queda en {gs(p.cuota)}.
                  </p>
                ) : null}
                <p className="mt-2 border-t border-sky-200 pt-2 text-[11px] text-slate-600">
                  De {fmtFecha(p.primer_vencimiento)} a {fmtFecha(p.ultimo_vencimiento)}
                </p>
                <p className="text-[11px] text-slate-600">
                  Total de la operación: <span className="font-semibold">{gs(p.total_operacion)}</span>
                </p>
              </div>

              <div className="max-h-72 overflow-y-auto rounded-2xl border border-slate-200 bg-white">
                <table className="w-full text-xs">
                  <thead className="sticky top-0 bg-slate-50">
                    <tr className="text-left text-[10px] font-semibold uppercase tracking-wider text-slate-500">
                      <th className="px-3 py-2">#</th>
                      <th className="px-3 py-2">Vence</th>
                      <th className="px-3 py-2 text-right">Cuota</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {p.cuotas.map((c) => (
                      <tr key={c.numero}>
                        <td className="px-3 py-1.5 text-slate-600">{c.numero}</td>
                        <td className="px-3 py-1.5 tabular-nums text-slate-600">{fmtFecha(c.vencimiento)}</td>
                        <td className="px-3 py-1.5 text-right font-semibold tabular-nums text-slate-900">
                          {gs(c.total)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          ) : null}
        </div>
      </div>

      {/* Historial */}
      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
        <div className="border-b border-slate-200 bg-slate-50/70 px-4 py-3">
          <p className="text-sm font-bold text-slate-900">Historial de simulaciones</p>
          <p className="text-[11px] text-slate-500">
            {clienteId
              ? "Propuestas del cliente elegido arriba."
              : "Últimas propuestas de todos los clientes. Elegí un cliente para filtrar."}
          </p>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[60rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                <th className="px-4 py-2.5">Propuesta</th>
                <th className="px-4 py-2.5">Cliente</th>
                <th className="px-4 py-2.5">Lote</th>
                <th className="px-4 py-2.5 text-right">Valor</th>
                <th className="px-4 py-2.5 text-right">Entrega</th>
                <th className="px-4 py-2.5 text-right">Cuotas</th>
                <th className="px-4 py-2.5 text-right">Cuota</th>
                <th className="px-4 py-2.5">Estado</th>
                <th className="px-4 py-2.5" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {historial.length === 0 ? (
                <tr>
                  <td colSpan={9} className="px-4 py-10 text-center text-sm text-slate-400">
                    Todavía no hay simulaciones guardadas.
                  </td>
                </tr>
              ) : (
                historial.map((s) => (
                  <tr key={s.id} className="hover:bg-slate-50/60">
                    <td className="px-4 py-2.5">
                      <p className="font-medium text-slate-900">{s.nombre ?? "Sin nombre"}</p>
                      <p className="text-[10px] text-slate-400">
                        {FRECUENCIAS[s.frecuencia].label} · recargo{" "}
                        {(s.recargo_pct * 100).toFixed(2).replace(/\.?0+$/, "")}%
                      </p>
                    </td>
                    <td className="px-4 py-2.5 text-slate-600">{s.cliente_label ?? "—"}</td>
                    <td className="px-4 py-2.5 text-slate-600">{s.lote_label ?? "—"}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums text-slate-700">{gs(s.precio_contado)}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums text-slate-700">{gs(s.entrega_inicial)}</td>
                    <td className="px-4 py-2.5 text-right tabular-nums text-slate-700">{s.cantidad_cuotas}</td>
                    <td className="px-4 py-2.5 text-right font-semibold tabular-nums text-slate-900">
                      {gs(s.cuota)}
                    </td>
                    <td className="px-4 py-2.5">
                      <span
                        className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                          ESTADO_SIMULACION_UI[s.estado].chip
                        }`}
                      >
                        {ESTADO_SIMULACION_UI[s.estado].label}
                      </span>
                    </td>
                    <td className="whitespace-nowrap px-4 py-2.5 text-right">
                      {s.estado !== "aprobada" ? (
                        <>
                          <button
                            type="button"
                            onClick={() => retomar(s)}
                            title="Retomar en el formulario"
                            className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                          >
                            <Undo2 className="h-4 w-4" />
                          </button>
                          {s.lote_id ? (
                            <button
                              type="button"
                              onClick={() => generarContrato(s)}
                              title="Aprobar plan y generar contrato"
                              className="rounded-lg p-1.5 text-emerald-600 hover:bg-emerald-50"
                            >
                              <Check className="h-4 w-4" />
                            </button>
                          ) : null}
                          {s.estado === "borrador" ? (
                            <button
                              type="button"
                              onClick={() => void cambiarEstado(s, "descartada")}
                              title="Descartar propuesta"
                              className="rounded-lg px-2 py-1 text-[10px] font-semibold text-slate-500 hover:bg-slate-100"
                            >
                              Descartar
                            </button>
                          ) : (
                            <button
                              type="button"
                              onClick={() => void cambiarEstado(s, "borrador")}
                              title="Volver a análisis"
                              className="rounded-lg px-2 py-1 text-[10px] font-semibold text-slate-500 hover:bg-slate-100"
                            >
                              Reactivar
                            </button>
                          )}
                          <button
                            type="button"
                            onClick={() => void borrar(s)}
                            title="Borrar del historial"
                            className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                          >
                            <Trash2 className="h-4 w-4" />
                          </button>
                        </>
                      ) : (
                        <span className="text-[10px] text-slate-400">Generó contrato</span>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {vendiendo ? (
        <ModalVenderLote
          lote={vendiendo.lote}
          opcionesCliente={opcionesCliente}
          inicial={vendiendo.inicial}
          onCancel={() => setVendiendo(null)}
          onVendido={async (msg) => {
            setVendiendo(null);
            showToast(msg);
            await cargarHistorial();
          }}
        />
      ) : null}

      {toast ? (
        <div className="fixed bottom-5 left-1/2 z-[80] -translate-x-1/2 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-sm font-medium text-emerald-800 shadow-lg">
          {toast}
        </div>
      ) : null}
    </div>
  );
}

function Fila({ k, v, destacado }: { k: string; v: string; destacado?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-xs text-slate-500">{k}</dt>
      <dd className={`tabular-nums ${destacado ? "font-bold text-slate-900" : "text-slate-700"}`}>{v}</dd>
    </div>
  );
}
