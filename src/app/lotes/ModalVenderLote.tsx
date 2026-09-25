"use client";

import { useEffect, useMemo, useState } from "react";
import { X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import SmartSearchSelect, { type SmartOption } from "@/components/ui/SmartSearchSelect";
import { FancySelect } from "@/components/ui/FancySelect";
import MontoInput from "@/components/ui/MontoInput";
import { FechaSelect } from "@/components/ui/FechaSelect";
import {
  generarPlanCuotas,
  generarPlanManual,
  diasEntre,
  FRECUENCIAS,
  MAX_CUOTAS,
  DIAS_GRACIA,
  MORA_ADMINISTRATIVA_DIARIA,
  MORA_MORATORIA_DIARIA,
  RECARGO_FINANCIACION,
} from "@/lib/financiacion/plan-cuotas";
import type { Frecuencia } from "@/lib/financiacion/plan-cuotas";
import type { Lote } from "@/lib/lotes/types";
import type { Vendedor } from "@/lib/vendedores/types";
import type { ContratoTipo, ParteContrato, RolParte } from "@/lib/contratos/types";

/** Parte vacía: el formulario arranca en blanco y se completa a mano. */
function parteVacia(rol: RolParte): ParteContrato {
  return {
    rol,
    cliente_id: null,
    nombre: "",
    documento: "",
    nacionalidad: "paraguaya",
    estado_civil: "",
    domicilio: "",
    telefono: "",
    email: "",
    observacion: null,
  };
}

/** Condiciones que llegan del simulador, para no volver a cargarlas a mano. */
export interface CondicionesIniciales {
  simulacion_id: string;
  cliente_id: string | null;
  precio_contado: number;
  entrega_inicial: number;
  cantidad_cuotas: number;
  primer_vencimiento: string;
  recargo_pct: number;
  frecuencia: Frecuencia;
  /** Tipo de plan traído del simulador. */
  plan_tipo?: "automatica" | "personalizada";
  /** Solo plan personalizado: cuotas cargadas a mano (sin la de cancelación). */
  cuotas_manuales?: { vencimiento: string; monto: number }[] | null;
  /** Solo plan personalizado: fecha de la cuota de cancelación. */
  cancelacion_vencimiento?: string | null;
}

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400";
const labelClass =
  "mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-500";

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
  inicial,
  onCancel,
  onVendido,
}: {
  lote: Lote;
  opcionesCliente: SmartOption[];
  /** Plan aprobado en el simulador; sin esto el modal arranca en blanco. */
  inicial?: CondicionesIniciales;
  onCancel: () => void;
  onVendido: (msg: string) => void | Promise<void>;
}) {
  const [clienteId, setClienteId] = useState(inicial?.cliente_id ?? lote.cliente_id ?? "");
  const [tipos, setTipos] = useState<ContratoTipo[]>([]);
  const [tipoId, setTipoId] = useState("");
  const [conyuge, setConyuge] = useState<ParteContrato>(() => parteVacia("conyuge"));
  const [codeudores, setCodeudores] = useState<ParteContrato[]>([]);
  const [fechaVenta, setFechaVenta] = useState(hoyYmd());
  const [primerVencimiento, setPrimerVencimiento] = useState(inicial?.primer_vencimiento ?? hoyYmd());
  const [precioContado, setPrecioContado] = useState(
    String(inicial?.precio_contado ?? lote.precio_contado ?? lote.precio_financiado ?? 0)
  );
  const [entrega, setEntrega] = useState(String(inicial?.entrega_inicial ?? 0));
  const [cuotas, setCuotas] = useState(String(inicial?.cantidad_cuotas ?? 12));
  const [recargo] = useState(inicial?.recargo_pct ?? RECARGO_FINANCIACION);
  const [frecuencia, setFrecuencia] = useState<Frecuencia>(inicial?.frecuencia ?? "mensual");
  // Tipo de plan: automático (amortización francesa) o personalizado (cuotas a mano).
  const [planTipo, setPlanTipo] = useState<"automatica" | "personalizada">(inicial?.plan_tipo ?? "automatica");
  // Cuotas del plan personalizado (montos limpios, sin interés). La cancelación va aparte.
  const [cuotasManuales, setCuotasManuales] = useState<{ vencimiento: string; monto: string }[]>(() =>
    inicial?.cuotas_manuales && inicial.cuotas_manuales.length > 0
      ? inicial.cuotas_manuales.map((c) => ({ vencimiento: c.vencimiento, monto: String(c.monto) }))
      : [{ vencimiento: hoyYmd(), monto: "" }]
  );
  const [cancelacionVenc, setCancelacionVenc] = useState(inicial?.cancelacion_vencimiento ?? hoyYmd());
  // ¿Se agrega una cuota final que se lleva el saldo restante? Opcional: si se
  // desactiva, las cuotas cargadas tienen que sumar exactamente el financiado.
  const [conCancelacion, setConCancelacion] = useState(
    inicial?.plan_tipo === "personalizada" ? Boolean(inicial?.cancelacion_vencimiento) : true
  );
  const [observacion, setObservacion] = useState("");
  const [vendedorId, setVendedorId] = useState("");
  /** En porcentaje, como lo escribe el vendedor ("3"); la API lo pasa a fracción. */
  const [comision, setComision] = useState("0");
  const [vendedores, setVendedores] = useState<Vendedor[]>([]);
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    fetchWithSupabaseSession("/api/lotes/contrato-tipos", { cache: "no-store" })
      .then((r) => r.json())
      .then((j: { success?: boolean; data?: { tipos: ContratoTipo[] } }) => {
        const lista = j.success === true && j.data ? j.data.tipos : [];
        setTipos(lista);
        // El primero del catálogo es el contrato normal; se preselecciona.
        if (lista.length > 0) setTipoId((prev) => prev || lista[0]!.id);
      })
      .catch(() => setTipos([]));

    fetchWithSupabaseSession("/api/lotes/vendedores", { cache: "no-store" })
      .then((r) => r.json())
      .then((j: { success?: boolean; data?: { vendedores: Vendedor[] } }) => {
        setVendedores(j.success === true && j.data ? j.data.vendedores : []);
      })
      .catch(() => setVendedores([]));
  }, []);

  const tipoElegido = tipos.find((t) => t.id === tipoId) ?? null;

  function elegirTipo(id: string) {
    setTipoId(id);
    const t = tipos.find((x) => x.id === id) ?? null;
    if (!t?.requiere_conyuge) setConyuge(parteVacia("conyuge"));
    if (t?.requiere_codeudor && codeudores.length === 0) setCodeudores([parteVacia("codeudor")]);
    if (!t?.requiere_codeudor) setCodeudores([]);
  }

  /** Al elegir vendedor se propone SU comisión; queda editable para esta venta. */
  function elegirVendedor(id: string) {
    setVendedorId(id);
    const v = vendedores.find((x) => x.id === id);
    setComision(v ? String(Math.round(v.comision_pct * 1e6) / 1e4) : "0");
  }

  const moneda = lote.moneda;
  const esPersonalizada = planTipo === "personalizada";

  // Cuotas personalizadas con monto cargado (las vacías se ignoran para la previa).
  const cuotasManualesLimpias = useMemo(
    () =>
      cuotasManuales
        .filter((c) => Number(c.monto) > 0)
        .map((c) => ({ vencimiento: c.vencimiento, monto: Number(c.monto) })),
    [cuotasManuales]
  );
  const financiado = Math.max(0, Math.round(Number(precioContado) || 0) - Math.round(Number(entrega) || 0));
  const sumaManual = cuotasManualesLimpias.reduce((a, c) => a + c.monto, 0);
  const saldoCancelacion = financiado - sumaManual;
  // Recargo prorrateado por el plazo (venta → cancelación); lo absorbe la cancelación.
  const aniosPlazo =
    conCancelacion && /^\d{4}-\d{2}-\d{2}$/.test(fechaVenta) && /^\d{4}-\d{2}-\d{2}$/.test(cancelacionVenc)
      ? Math.max(0, diasEntre(fechaVenta, cancelacionVenc)) / 365
      : 0;
  const recargoMonto = conCancelacion ? Math.round(financiado * recargo * aniosPlazo) : 0;
  const cancelacionImporte = saldoCancelacion + recargoMonto;

  /** Vista previa del plan. Si los datos no cierran, el motor avisa por qué. */
  const preview = useMemo(() => {
    try {
      return {
        plan: esPersonalizada
          ? generarPlanManual({
              precioContado: Number(precioContado),
              entregaInicial: Number(entrega),
              cuotas: cuotasManualesLimpias,
              cancelacionVencimiento: conCancelacion ? cancelacionVenc : undefined,
              fechaVenta,
              recargo,
            })
          : generarPlanCuotas({
              precioContado: Number(precioContado),
              entregaInicial: Number(entrega),
              cantidadCuotas: Number(cuotas),
              primerVencimiento,
              recargo,
              frecuencia,
            }),
        error: null as string | null,
      };
    } catch (e) {
      return { plan: null, error: e instanceof Error ? e.message : "Datos inválidos" };
    }
  }, [
    esPersonalizada,
    precioContado,
    entrega,
    cuotas,
    primerVencimiento,
    recargo,
    frecuencia,
    cuotasManualesLimpias,
    cancelacionVenc,
    conCancelacion,
    fechaVenta,
  ]);

  const faltaConyuge = tipoElegido?.requiere_conyuge === true && !conyuge.nombre.trim();
  const faltaCodeudor =
    tipoElegido?.requiere_codeudor === true && !codeudores.some((c) => c.nombre.trim());
  const invalido = !clienteId || !preview.plan || guardando || faltaConyuge || faltaCodeudor;

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
          tipo_contrato_id: tipoId || null,
          partes: [
            ...(tipoElegido?.requiere_conyuge ? [conyuge] : []),
            ...(tipoElegido?.requiere_codeudor ? codeudores : []),
          ].filter((x) => x.nombre.trim()),
          fecha_venta: fechaVenta,
          primer_vencimiento: esPersonalizada
            ? cuotasManualesLimpias[0]?.vencimiento ?? ""
            : primerVencimiento,
          precio_contado: Number(precioContado),
          entrega_inicial: Number(entrega),
          cantidad_cuotas: Number(cuotas),
          recargo_pct: recargo,
          frecuencia,
          plan_tipo: planTipo,
          cuotas_manuales: esPersonalizada ? cuotasManualesLimpias : undefined,
          cancelacion_vencimiento: esPersonalizada && conCancelacion ? cancelacionVenc : undefined,
          simulacion_id: inicial?.simulacion_id ?? null,
          observacion,
          vendedor_id: vendedorId || null,
          comision_pct: vendedorId ? comision : 0,
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
              {esPersonalizada
                ? "Plan personalizado: cargá cada cuota a mano (sin interés) y una cuota final de cancelación con el saldo restante."
                : `Cuota fija por sistema de amortización francés (calculadora del BCP), con tasa del ${(recargo * 100).toFixed(2).replace(/\.?0+$/, "")}% anual sobre el saldo.`}
            </p>
          </div>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        {inicial ? (
          <p className="mt-3 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-[11px] text-emerald-800">
            Condiciones traídas del plan aprobado en el simulador. Podés ajustarlas antes de confirmar; al
            generar el contrato, esa simulación queda como aprobada.
          </p>
        ) : null}

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <label className={labelClass}>Tipo de contrato</label>
            <FancySelect
              value={tipoId}
              onChange={elegirTipo}
              placeholder={tipos.length === 0 ? "Sin tipos configurados" : "Elegí el tipo"}
              options={tipos.map((t) => ({ value: t.id, label: t.nombre, description: t.descripcion ?? undefined }))}
            />
            {tipoElegido?.descripcion ? (
              <p className="mt-1 text-[10px] text-slate-400">{tipoElegido.descripcion}</p>
            ) : null}
          </div>
          <div className="sm:col-span-2">
            <label className={labelClass}>Cliente titular</label>
            <SmartSearchSelect
              options={opcionesCliente}
              value={clienteId}
              onChange={setClienteId}
              placeholder="Buscar cliente…"
            />
          </div>
          {tipoElegido?.requiere_conyuge ? (
            <div className="sm:col-span-2">
              <FormParte
                titulo="Datos del cónyuge"
                parte={conyuge}
                onChange={setConyuge}
              />
            </div>
          ) : null}

          {tipoElegido?.requiere_codeudor ? (
            <div className="sm:col-span-2 space-y-3">
              {codeudores.map((c, i) => (
                <FormParte
                  key={i}
                  titulo={codeudores.length > 1 ? `Datos del codeudor ${i + 1}` : "Datos del codeudor"}
                  parte={c}
                  onChange={(v) => setCodeudores((prev) => prev.map((x, j) => (j === i ? v : x)))}
                  onQuitar={
                    codeudores.length > 1
                      ? () => setCodeudores((prev) => prev.filter((_, j) => j !== i))
                      : undefined
                  }
                />
              ))}
              <button
                type="button"
                onClick={() => setCodeudores((prev) => [...prev, parteVacia("codeudor")])}
                className="text-[11px] font-semibold text-[#0EA5E9] hover:underline"
              >
                + Agregar otro codeudor
              </button>
            </div>
          ) : null}
          <div>
            <label className={labelClass}>
              Vendedor <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <FancySelect
              value={vendedorId}
              onChange={elegirVendedor}
              options={[
                { value: "", label: "Sin vendedor" },
                ...vendedores.map((v) => ({ value: v.id, label: `${v.codigo} — ${v.nombre}` })),
              ]}
            />
          </div>
          <div>
            <label className={labelClass}>Comisión del vendedor (%)</label>
            <input
              type="number"
              min={0}
              max={100}
              step="0.01"
              value={comision}
              onChange={(e) => setComision(e.target.value)}
              onFocus={(e) => e.currentTarget.select()}
              disabled={!vendedorId}
              className={`${inputClass} disabled:bg-slate-50 disabled:text-slate-400`}
            />
            <p className="mt-1 text-[10px] text-slate-400">
              Se liquida sobre cada cuota cobrada, no al firmar.
            </p>
          </div>
          <div>
            <label className={labelClass}>Fecha de la venta</label>
            <FechaSelect value={fechaVenta} onChange={(e) => setFechaVenta(e.target.value)} className={inputClass} />
          </div>
          {!esPersonalizada ? (
            <div>
              <label className={labelClass}>Vencimiento de la primera cuota</label>
              <FechaSelect
                value={primerVencimiento}
                onChange={(e) => setPrimerVencimiento(e.target.value)}
                className={inputClass}
              />
            </div>
          ) : null}
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

          {/* Tipo de plan: automático (francés) o personalizado (cuotas a mano). */}
          <div className="sm:col-span-2">
            <label className={labelClass}>Tipo de plan</label>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => setPlanTipo("automatica")}
                className={`rounded-xl border px-3 py-2 text-left text-xs font-semibold transition-colors ${
                  !esPersonalizada
                    ? "border-[#0EA5E9] bg-[#0EA5E9]/10 text-[#0284C7]"
                    : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"
                }`}
              >
                Plan automático
                <span className="mt-0.5 block text-[10px] font-normal text-slate-400">Cuota fija (sistema francés)</span>
              </button>
              <button
                type="button"
                onClick={() => setPlanTipo("personalizada")}
                className={`rounded-xl border px-3 py-2 text-left text-xs font-semibold transition-colors ${
                  esPersonalizada
                    ? "border-[#0EA5E9] bg-[#0EA5E9]/10 text-[#0284C7]"
                    : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"
                }`}
              >
                Plan personalizado
                <span className="mt-0.5 block text-[10px] font-normal text-slate-400">Cuotas a mano + cancelación</span>
              </button>
            </div>
          </div>

          {esPersonalizada ? (
            <div className="sm:col-span-2">
              <div className="mb-2 flex items-center justify-between">
                <label className={labelClass + " mb-0"}>Cuotas del plan</label>
                <span className="text-[10px] text-slate-400">Montos sin interés</span>
              </div>
              <div className="space-y-2">
                {cuotasManuales.map((c, i) => (
                  <div key={i} className="flex items-center gap-2">
                    <span className="w-5 shrink-0 text-center text-xs font-semibold text-slate-500">{i + 1}</span>
                    <div className="flex-1">
                      <FechaSelect
                        value={c.vencimiento}
                        onChange={(e) =>
                          setCuotasManuales((prev) =>
                            prev.map((x, j) => (j === i ? { ...x, vencimiento: e.target.value } : x))
                          )
                        }
                        className={inputClass}
                      />
                    </div>
                    <div className="flex-1">
                      <MontoInput
                        value={c.monto}
                        onChange={(n) =>
                          setCuotasManuales((prev) => prev.map((x, j) => (j === i ? { ...x, monto: String(n) } : x)))
                        }
                        decimals={moneda === "USD"}
                        className={inputClass}
                      />
                    </div>
                    <button
                      type="button"
                      onClick={() =>
                        setCuotasManuales((prev) => (prev.length > 1 ? prev.filter((_, j) => j !== i) : prev))
                      }
                      disabled={cuotasManuales.length <= 1}
                      className="shrink-0 rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-rose-600 disabled:opacity-30"
                      aria-label="Quitar cuota"
                    >
                      <X className="h-3.5 w-3.5" />
                    </button>
                  </div>
                ))}
              </div>
              <button
                type="button"
                onClick={() =>
                  setCuotasManuales((prev) => [
                    ...prev,
                    { vencimiento: prev[prev.length - 1]?.vencimiento ?? hoyYmd(), monto: "" },
                  ])
                }
                className="mt-2 text-[11px] font-semibold text-[#0EA5E9] hover:underline"
              >
                + Agregar cuota
              </button>

              <label className="mt-3 flex items-center gap-2 text-xs font-medium text-slate-600">
                <input
                  type="checkbox"
                  checked={conCancelacion}
                  onChange={(e) => setConCancelacion(e.target.checked)}
                  className="h-3.5 w-3.5"
                />
                Agregar cuota final de cancelación (se lleva el saldo restante)
              </label>

              {conCancelacion ? (
                <div className="mt-2 rounded-xl border border-slate-200 bg-slate-50/60 p-3">
                  <div className="flex items-center justify-between gap-2">
                    <div>
                      <p className="text-xs font-semibold text-slate-700">Cuota final — Cancelación de saldo</p>
                      <p className="text-[10px] text-slate-400">
                        Saldo restante {recargoMonto > 0 ? "+ recargo del plazo" : ""}.
                      </p>
                    </div>
                    <div className="text-right">
                      <p className="text-[10px] font-semibold uppercase tracking-wider text-slate-500">Importe</p>
                      <p
                        className={`text-sm font-bold tabular-nums ${
                          cancelacionImporte > 0 ? "text-slate-900" : "text-rose-600"
                        }`}
                      >
                        {fmt(Math.max(0, cancelacionImporte), moneda)}
                      </p>
                    </div>
                  </div>
                  <div className="mt-2">
                    <label className={labelClass}>Vencimiento de la cancelación</label>
                    <FechaSelect
                      value={cancelacionVenc}
                      onChange={(e) => setCancelacionVenc(e.target.value)}
                      className={inputClass}
                    />
                  </div>
                </div>
              ) : null}

              <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-slate-500">
                <span>
                  Saldo a financiar: <b className="tabular-nums text-slate-700">{fmt(financiado, moneda)}</b>
                </span>
                <span>
                  Suma de cuotas: <b className="tabular-nums text-slate-700">{fmt(sumaManual, moneda)}</b>
                </span>
                {conCancelacion && recargoMonto > 0 ? (
                  <span>
                    Recargo del plazo: <b className="tabular-nums text-slate-700">{fmt(recargoMonto, moneda)}</b>
                  </span>
                ) : null}
                {conCancelacion ? (
                  <span>
                    Va a la cancelación:{" "}
                    <b className={`tabular-nums ${cancelacionImporte > 0 ? "text-slate-700" : "text-rose-600"}`}>
                      {fmt(cancelacionImporte, moneda)}
                    </b>
                  </span>
                ) : (
                  <span>
                    Diferencia:{" "}
                    <b className={`tabular-nums ${saldoCancelacion === 0 ? "text-emerald-600" : "text-rose-600"}`}>
                      {fmt(saldoCancelacion, moneda)}
                    </b>
                    {saldoCancelacion !== 0 ? " — debe quedar en 0" : ""}
                  </span>
                )}
              </div>
            </div>
          ) : (
            <>
              <div>
                <label className={labelClass}>Frecuencia de pago</label>
                <FancySelect
                  value={frecuencia}
                  onChange={(v) => setFrecuencia(v as Frecuencia)}
                  options={Object.entries(FRECUENCIAS).map(([k, f]) => ({ value: k, label: f.label }))}
                />
              </div>
              <div>
                <label className={labelClass}>Cantidad de cuotas</label>
                <input
                  type="number"
                  min={1}
                  max={MAX_CUOTAS}
                  value={cuotas}
                  onChange={(e) => setCuotas(e.target.value)}
                  className={inputClass}
                />
              </div>
            </>
          )}
          <div className={esPersonalizada ? "sm:col-span-2" : undefined}>
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
              {esPersonalizada ? (
                <>
                  <Dato titulo="Saldo financiado" valor={fmt(p.capital, moneda)} />
                  <Dato titulo="Cuotas" valor={String(p.cuotas.length)} />
                  <Dato titulo="Cancelación" valor={fmt(p.cuotas[p.cuotas.length - 1]?.total ?? 0, moneda)} />
                  <Dato titulo="Total a pagar" valor={fmt(p.monto_financiado, moneda)} destacado />
                </>
              ) : (
                <>
                  <Dato titulo="Capital" valor={fmt(p.capital, moneda)} />
                  <Dato titulo="Total intereses" valor={fmt(p.interes_total, moneda)} />
                  <Dato titulo="Total a pagar" valor={fmt(p.monto_financiado, moneda)} />
                  <Dato titulo="Cuota fija" valor={fmt(p.cuotas[0]?.total ?? 0, moneda)} destacado />
                </>
              )}
            </div>

            <div className="mt-3 max-h-52 overflow-y-auto rounded-xl border border-slate-200">
              <table className="w-full text-xs">
                <thead className="sticky top-0 bg-slate-50">
                  <tr className="text-left text-[10px] font-semibold uppercase tracking-wider text-slate-500">
                    <th className="px-3 py-2">Cuota</th>
                    <th className="px-3 py-2">Vence</th>
                    <th className="px-3 py-2 text-right">Capital</th>
                    <th className="px-3 py-2 text-right">Interés</th>
                    <th className="px-3 py-2 text-right">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {p.cuotas.map((c) => (
                    <tr key={c.numero}>
                      <td className="px-3 py-1.5 text-slate-700">
                        {c.numero}
                        {esPersonalizada && c.numero === p.cuotas.length ? (
                          <span className="ml-1 rounded bg-amber-100 px-1 py-0.5 text-[9px] font-semibold text-amber-700">
                            Cancelación
                          </span>
                        ) : null}
                      </td>
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

/**
 * Datos completos de una parte que firma. Se guardan con el contrato y no con el
 * cliente: un codeudor puede no ser cliente de la empresa, y el contrato firmado
 * no debe cambiar si mañana se edita esa ficha.
 */
export function FormParte({
  titulo,
  parte,
  onChange,
  onQuitar,
}: {
  titulo: string;
  parte: ParteContrato;
  onChange: (p: ParteContrato) => void;
  onQuitar?: () => void;
}) {
  const set = (campo: keyof ParteContrato) => (e: React.ChangeEvent<HTMLInputElement>) =>
    onChange({ ...parte, [campo]: e.target.value });

  return (
    <div className="rounded-xl border border-slate-200 bg-slate-50/60 p-3">
      <div className="mb-2 flex items-center justify-between">
        <p className="text-xs font-semibold text-slate-600">{titulo}</p>
        {onQuitar ? (
          <button type="button" onClick={onQuitar} className="text-[11px] text-slate-400 hover:text-rose-600">
            Quitar
          </button>
        ) : null}
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        <div className="sm:col-span-2">
          <label className={labelClass}>Nombre y apellido</label>
          <input value={parte.nombre} onChange={set("nombre")} className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>C.I. / RUC</label>
          <input value={parte.documento ?? ""} onChange={set("documento")} className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Estado civil</label>
          <input value={parte.estado_civil ?? ""} onChange={set("estado_civil")} className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Nacionalidad</label>
          <input value={parte.nacionalidad ?? ""} onChange={set("nacionalidad")} className={inputClass} />
        </div>
        <div>
          <label className={labelClass}>Teléfono</label>
          <input value={parte.telefono ?? ""} onChange={set("telefono")} className={inputClass} />
        </div>
        <div className="sm:col-span-2">
          <label className={labelClass}>Domicilio real</label>
          <input value={parte.domicilio ?? ""} onChange={set("domicilio")} className={inputClass} />
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
