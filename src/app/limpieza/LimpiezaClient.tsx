"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { Pencil, Plus, RefreshCw, Trash2, X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { getClientes } from "@/lib/clientes/storage";
import SmartSearchSelect, { type SmartOption } from "@/components/ui/SmartSearchSelect";
import { FechaSelect } from "@/components/ui/FechaSelect";
import type { Cliente } from "@/lib/clientes/types";
import type {
  LimpiezaPayload,
  MonedaLimpieza,
  ServicioLimpieza,
  TipoFacturaLimpieza,
} from "@/lib/limpieza/types";

const inputClass =
  "w-full border border-slate-200 rounded-lg px-3 py-2 outline-none focus:ring-2 focus:ring-[#0EA5E9] focus:outline-none bg-white text-sm";
const labelClass = "block text-xs font-medium text-slate-500 mb-1";

/** Etiqueta visible del cliente: razón social si es empresa, si no el contacto. */
function etiquetaCliente(c: Cliente): string {
  return ((c.empresa ?? c.nombre_contacto) || "").trim() || "Cliente sin nombre";
}

function fmtMoneda(valor: number, moneda: MonedaLimpieza): string {
  if (moneda === "USD") return `USD ${valor.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`;
  return `Gs. ${Math.round(valor).toLocaleString("es-PY")}`;
}

function fmtFecha(ymd: string): string {
  if (!ymd) return "—";
  const [y, m, d] = ymd.split("-");
  return `${d}/${m}/${y}`;
}

/** Primer y último día del mes en curso, que es el rango con el que se abre la vista. */
function rangoMesActual(): { desde: string; hasta: string } {
  const hoy = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  const y = hoy.getFullYear();
  const m = hoy.getMonth();
  const fin = new Date(y, m + 1, 0);
  return { desde: `${y}-${p(m + 1)}-01`, hasta: `${fin.getFullYear()}-${p(fin.getMonth() + 1)}-${p(fin.getDate())}` };
}

function hoyYmd(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Asuncion",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

const BADGE_FACTURA: Record<string, string> = {
  Pagado: "border-emerald-200 bg-emerald-50 text-emerald-700",
  Pendiente: "border-amber-200 bg-amber-50 text-amber-700",
  Vencido: "border-rose-200 bg-rose-50 text-rose-700",
  Anulado: "border-slate-200 bg-slate-100 text-slate-500",
};

export default function LimpiezaClient() {
  const rangoInicial = useMemo(rangoMesActual, []);
  const [desde, setDesde] = useState(rangoInicial.desde);
  const [hasta, setHasta] = useState(rangoInicial.hasta);
  const [clienteFiltro, setClienteFiltro] = useState("");

  const [data, setData] = useState<LimpiezaPayload | null>(null);
  const [clientes, setClientes] = useState<Cliente[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [modalAbierto, setModalAbierto] = useState(false);
  /** Servicio que se está corrigiendo; null cuando el modal es un alta. */
  const [editando, setEditando] = useState<ServicioLimpieza | null>(null);
  const [borrandoId, setBorrandoId] = useState<string | null>(null);

  const showToast = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => setToast(null), 4000);
  }, []);

  const load = useCallback(async () => {
    setCargando(true);
    setError(null);
    try {
      const params = new URLSearchParams();
      if (desde) params.set("desde", desde);
      if (hasta) params.set("hasta", hasta);
      if (clienteFiltro) params.set("cliente_id", clienteFiltro);
      const res = await fetchWithSupabaseSession(`/api/limpieza?${params.toString()}`, { cache: "no-store" });
      const json = (await res.json()) as { success?: boolean; error?: string; data?: LimpiezaPayload };
      if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
      setData(json.data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "No se pudieron cargar los servicios");
      setData(null);
    } finally {
      setCargando(false);
    }
  }, [desde, hasta, clienteFiltro]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    getClientes().then(setClientes).catch(() => setClientes([]));
  }, []);

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

  const eliminar = useCallback(
    async (s: ServicioLimpieza) => {
      const ok = window.confirm(
        `¿Anular el servicio del ${fmtFecha(s.fecha_servicio)} de ${s.cliente_label}?\n\n` +
          "Se elimina también la factura que generó (solo si todavía no tiene cobros registrados)."
      );
      if (!ok) return;
      setBorrandoId(s.id);
      try {
        const res = await fetchWithSupabaseSession(`/api/limpieza/${encodeURIComponent(s.id)}`, {
          method: "DELETE",
        });
        const json = (await res.json()) as { success?: boolean; error?: string };
        if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
        showToast("Servicio anulado.");
        await load();
      } catch (e) {
        showToast(e instanceof Error ? e.message : "No se pudo anular el servicio");
      } finally {
        setBorrandoId(null);
      }
    },
    [load, showToast]
  );

  const resumen = data?.resumen;
  const servicios = data?.servicios ?? [];

  return (
    <div className="w-full min-w-0 max-w-full space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold text-gray-800">Limpieza</h1>
          <p className="mt-0.5 text-sm text-gray-500">
            Servicios de limpieza de lote. Se cargan a mano, solo cuando el servicio se realizó.
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
            onClick={() => setModalAbierto(true)}
            className="inline-flex items-center gap-1.5 rounded-lg bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7]"
          >
            <Plus className="h-3.5 w-3.5" />
            Registrar servicio
          </button>
        </div>
      </div>

      {/* Filtros */}
      <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 lg:grid-cols-4">
        <div>
          <label className={labelClass}>Desde</label>
          <FechaSelect value={desde} onChange={(e) => setDesde(e.target.value)} className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Hasta</label>
          <FechaSelect value={hasta} onChange={(e) => setHasta(e.target.value)} className={inputClass} />
        </div>
        <div className="lg:col-span-2">
          <label className={labelClass}>Cliente</label>
          <SmartSearchSelect
            options={[{ id: "", label: "Todos los clientes" }, ...opcionesCliente]}
            value={clienteFiltro}
            onChange={setClienteFiltro}
            placeholder="Todos los clientes"
          />
        </div>
      </div>

      {/* Totales del rango filtrado */}
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tarjeta titulo="Servicios" valor={String(resumen?.servicios ?? 0)} />
        <Tarjeta titulo="Clientes" valor={String(resumen?.clientes ?? 0)} />
        <Tarjeta
          titulo="Total facturado"
          valor={fmtMoneda(resumen?.total_gs ?? 0, "GS")}
          extra={resumen?.total_usd ? fmtMoneda(resumen.total_usd, "USD") : undefined}
        />
        <Tarjeta
          titulo="Pendiente de cobro"
          valor={fmtMoneda(resumen?.pendiente_gs ?? 0, "GS")}
          extra={resumen?.pendiente_usd ? fmtMoneda(resumen.pendiente_usd, "USD") : undefined}
          tono="rose"
        />
      </div>

      {error ? (
        <div className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : null}

      {/* Listado */}
      <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[52rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50/70 text-left text-[11px] font-semibold uppercase tracking-wider text-slate-500">
                <th className="px-4 py-3">Fecha</th>
                <th className="px-4 py-3">Cliente</th>
                <th className="px-4 py-3">Observación</th>
                <th className="px-4 py-3 text-right">Importe</th>
                <th className="px-4 py-3">Factura</th>
                <th className="px-4 py-3">Cargado por</th>
                <th className="px-4 py-3" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {cargando ? (
                <tr>
                  <td colSpan={7} className="px-4 py-10 text-center text-sm text-slate-400">
                    Cargando…
                  </td>
                </tr>
              ) : servicios.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-4 py-10 text-center text-sm text-slate-400">
                    Sin servicios de limpieza en el período.
                  </td>
                </tr>
              ) : (
                servicios.map((s) => (
                  <tr key={s.id} className="hover:bg-slate-50/60">
                    <td className="whitespace-nowrap px-4 py-3 tabular-nums text-slate-700">
                      {fmtFecha(s.fecha_servicio)}
                    </td>
                    <td className="px-4 py-3">
                      <Link
                        href={`/clientes/${s.cliente_id}`}
                        className="font-medium text-slate-900 hover:text-[#0EA5E9] hover:underline"
                      >
                        {s.cliente_label}
                      </Link>
                    </td>
                    <td className="max-w-[20rem] px-4 py-3 text-slate-600">{s.observacion ?? "—"}</td>
                    <td className="whitespace-nowrap px-4 py-3 text-right font-semibold tabular-nums text-slate-900">
                      {fmtMoneda(s.importe, s.moneda)}
                    </td>
                    <td className="whitespace-nowrap px-4 py-3">
                      {s.factura_id ? (
                        <span className="inline-flex items-center gap-2">
                          <Link
                            href={`/facturas/${s.factura_id}`}
                            className="text-slate-700 hover:text-[#0EA5E9] hover:underline"
                          >
                            {s.factura_numero ?? "Ver"}
                          </Link>
                          {s.factura_estado ? (
                            <span
                              className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold ${
                                BADGE_FACTURA[s.factura_estado] ?? "border-slate-200 bg-slate-50 text-slate-600"
                              }`}
                            >
                              {s.factura_estado}
                            </span>
                          ) : null}
                        </span>
                      ) : (
                        <span className="text-xs text-slate-400">Sin factura</span>
                      )}
                    </td>
                    <td className="max-w-[14rem] truncate px-4 py-3 text-xs text-slate-500">
                      {s.creado_por_email ?? "—"}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <button
                        type="button"
                        onClick={() => setEditando(s)}
                        title="Editar servicio"
                        className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                      >
                        <Pencil className="h-4 w-4" />
                      </button>
                      <button
                        type="button"
                        onClick={() => void eliminar(s)}
                        disabled={borrandoId === s.id}
                        title="Anular servicio"
                        className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600 disabled:opacity-40"
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

      {modalAbierto || editando ? (
        <ModalServicio
          servicio={editando}
          opcionesCliente={opcionesCliente}
          onCancel={() => {
            setModalAbierto(false);
            setEditando(null);
          }}
          onDone={async (msg) => {
            setModalAbierto(false);
            setEditando(null);
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
  extra,
  tono,
}: {
  titulo: string;
  valor: string;
  extra?: string;
  tono?: "rose";
}) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-4">
      <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-500">{titulo}</p>
      <p className={`mt-1 text-xl font-bold tabular-nums ${tono === "rose" ? "text-rose-700" : "text-slate-900"}`}>
        {valor}
      </p>
      {extra ? <p className="mt-0.5 text-xs text-slate-500">{extra}</p> : null}
    </div>
  );
}

/** Alta y corrección del servicio comparten formulario, para que no se desvíen entre sí. */
function ModalServicio({
  servicio,
  opcionesCliente,
  onCancel,
  onDone,
}: {
  servicio: ServicioLimpieza | null;
  opcionesCliente: SmartOption[];
  onCancel: () => void;
  onDone: (msg: string) => void | Promise<void>;
}) {
  const editar = servicio != null;
  /** Con cobros imputados solo se puede retocar la observación; el resto queda congelado. */
  const congelado = servicio?.factura_con_cobros === true;

  const [clienteId, setClienteId] = useState(servicio?.cliente_id ?? "");
  const [fecha, setFecha] = useState(servicio?.fecha_servicio ?? hoyYmd());
  const [importe, setImporte] = useState(servicio ? String(servicio.importe) : "");
  const [moneda, setMoneda] = useState<MonedaLimpieza>(servicio?.moneda ?? "GS");
  const [tipoFactura, setTipoFactura] = useState<TipoFacturaLimpieza>(servicio?.factura_tipo ?? "contado");
  const [observacion, setObservacion] = useState(servicio?.observacion ?? "");
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const importeNum = Number(importe);
  const invalido = !clienteId || !fecha || !Number.isFinite(importeNum) || importeNum <= 0;

  async function guardar() {
    setErr(null);
    setGuardando(true);
    try {
      const url = editar ? `/api/limpieza/${encodeURIComponent(servicio.id)}` : "/api/limpieza";
      const res = await fetchWithSupabaseSession(url, {
        method: editar ? "PATCH" : "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          cliente_id: clienteId,
          fecha_servicio: fecha,
          importe: importeNum,
          moneda,
          tipo_factura: tipoFactura,
          observacion: observacion.trim() || null,
        }),
      });
      const json = (await res.json()) as {
        success?: boolean;
        error?: string;
        data?: { factura_numero?: string };
      };
      if (!res.ok || json.success !== true) throw new Error(json.error ?? `Error ${res.status}`);
      if (editar) {
        await onDone("Servicio actualizado.");
      } else {
        await onDone(
          json.data?.factura_numero
            ? `Servicio registrado. Factura ${json.data.factura_numero} emitida.`
            : "Servicio registrado."
        );
      }
    } catch (e) {
      const fallback = editar ? "No se pudo actualizar el servicio" : "No se pudo registrar el servicio";
      setErr(e instanceof Error ? e.message : fallback);
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
            <h3 className="text-base font-semibold text-slate-900">
              {editar ? "Editar servicio de limpieza" : "Registrar servicio de limpieza"}
            </h3>
            <p className="mt-0.5 text-[11px] text-slate-500">
              {editar
                ? `Se corrige también la factura ${servicio.factura_numero ?? "asociada"}.`
                : "Se emite una factura al cliente, que pasa a Cobranzas y Estado de cuenta."}
            </p>
          </div>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        {congelado ? (
          <p className="mt-3 rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-[11px] text-amber-800">
            La factura de este servicio ya tiene cobros: solo se puede corregir la observación. Para cambiar el
            importe o el cliente, anulala o emití una nota de crédito desde Facturas.
          </p>
        ) : null}

        <div className="mt-4 grid gap-3">
          <div>
            <label className={labelClass}>Cliente</label>
            {congelado ? (
              <input
                type="text"
                value={servicio.cliente_label}
                readOnly
                className={`${inputClass} bg-slate-50 text-slate-500`}
              />
            ) : (
              <SmartSearchSelect
                options={opcionesCliente}
                value={clienteId}
                onChange={setClienteId}
                placeholder="Buscar cliente…"
                required
              />
            )}
          </div>
          <div>
            <label className={labelClass}>Fecha del servicio</label>
            <FechaSelect
              value={fecha}
              onChange={(e) => setFecha(e.target.value)}
              className={inputClass}
              disabled={congelado}
            />
          </div>
          <div className="grid grid-cols-3 gap-3">
            <div className="col-span-2">
              <label className={labelClass}>Importe cobrado</label>
              <input
                type="number"
                min={0}
                value={importe}
                onChange={(e) => setImporte(e.target.value)}
                placeholder="0"
                className={inputClass}
                disabled={congelado}
              />
            </div>
            <div>
              <label className={labelClass}>Moneda</label>
              <select
                value={moneda}
                onChange={(e) => setMoneda(e.target.value as MonedaLimpieza)}
                className={inputClass}
                disabled={congelado}
              >
                <option value="GS">Gs.</option>
                <option value="USD">USD</option>
              </select>
            </div>
          </div>
          <div>
            <label className={labelClass}>Condición de la factura</label>
            <select
              value={tipoFactura}
              onChange={(e) => setTipoFactura(e.target.value as TipoFacturaLimpieza)}
              className={inputClass}
              disabled={congelado}
            >
              <option value="contado">Contado — vence el mismo día</option>
              <option value="credito">Crédito — vence según el plazo de la instancia</option>
            </select>
          </div>
          <div>
            <label className={labelClass}>
              Observación <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input
              type="text"
              value={observacion}
              onChange={(e) => setObservacion(e.target.value)}
              placeholder="Ej: limpieza de terreno sin construcción"
              className={inputClass}
            />
            <p className="mt-1 text-[11px] text-slate-400">Se usa como detalle de la línea de la factura.</p>
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
            disabled={guardando || invalido}
            className="rounded-xl bg-[#0EA5E9] px-3.5 py-2 text-xs font-semibold text-white hover:bg-[#0284C7] disabled:opacity-50"
          >
            {guardando ? "Guardando…" : editar ? "Guardar cambios" : "Registrar y facturar"}
          </button>
        </div>
      </div>
    </div>
  );
}
