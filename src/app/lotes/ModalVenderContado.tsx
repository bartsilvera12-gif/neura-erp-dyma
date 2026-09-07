"use client";

import { useEffect, useState } from "react";
import { X } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import SmartSearchSelect, { type SmartOption } from "@/components/ui/SmartSearchSelect";
import { FancySelect } from "@/components/ui/FancySelect";
import MontoInput from "@/components/ui/MontoInput";
import { FechaSelect } from "@/components/ui/FechaSelect";
import { FormParte } from "./ModalVenderLote";
import type { Lote } from "@/lib/lotes/types";
import type { ContratoTipo, ParteContrato, RolParte } from "@/lib/contratos/types";
import type { Vendedor } from "@/lib/vendedores/types";

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400";
const labelClass =
  "mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-500";

const METODOS = [
  { id: "efectivo", label: "Efectivo" },
  { id: "transferencia", label: "Transferencia" },
  { id: "cheque", label: "Cheque" },
  { id: "tarjeta", label: "Tarjeta" },
  { id: "otro", label: "Otro" },
];

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

function hoyYmd(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Asuncion",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

const fmt = (v: number, moneda: string) =>
  moneda === "USD"
    ? `USD ${v.toLocaleString("es-PY", { minimumFractionDigits: 2 })}`
    : `Gs. ${Math.round(v).toLocaleString("es-PY")}`;

/**
 * Venta de un lote al contado: se paga todo en el acto.
 *
 * Por dentro es el mismo contrato que una venta financiada, con una sola cuota
 * que vence el día de la venta y sin recargo. Se hace así para que la operación
 * entre al mismo circuito de factura, cobranza, comisión y documento en vez de
 * abrir un camino paralelo que después no cuadre con los reportes.
 *
 * Son dos pasos: primero se crea el contrato, después se cobra esa única cuota
 * con la ruta de cobro de siempre. Si el cobro fallara, queda un contrato con la
 * cuota pendiente —visible en Contratos y cobrable desde ahí—, no un registro roto.
 */
export default function ModalVenderContado({
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
  const [fecha, setFecha] = useState(hoyYmd());
  const [precio, setPrecio] = useState(String(lote.precio_contado ?? 0));
  const [metodo, setMetodo] = useState("efectivo");
  const [referencia, setReferencia] = useState("");
  const [observacion, setObservacion] = useState("");
  const [tipos, setTipos] = useState<ContratoTipo[]>([]);
  const [tipoId, setTipoId] = useState("");
  const [vendedores, setVendedores] = useState<Vendedor[]>([]);
  const [vendedorId, setVendedorId] = useState("");
  /** En porcentaje, como lo piensa el negocio; la API lo pasa a fracción. */
  const [comision, setComision] = useState("0");
  const [conyuge, setConyuge] = useState<ParteContrato>(() => parteVacia("conyuge"));
  const [codeudores, setCodeudores] = useState<ParteContrato[]>([]);
  const [guardando, setGuardando] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    fetchWithSupabaseSession("/api/lotes/contrato-tipos", { cache: "no-store" })
      .then((r) => r.json())
      .then((j: { success?: boolean; data?: { tipos: ContratoTipo[] } }) => {
        const lista = j.success === true && j.data ? j.data.tipos : [];
        setTipos(lista);
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

  /** Al elegir vendedor se propone SU comisión; queda editable para esta venta. */
  function elegirVendedor(id: string) {
    setVendedorId(id);
    const v = vendedores.find((x) => x.id === id);
    setComision(v ? String(Math.round(v.comision_pct * 1e6) / 1e4) : "0");
  }

  const tipoElegido = tipos.find((t) => t.id === tipoId) ?? null;

  function elegirTipo(id: string) {
    setTipoId(id);
    const t = tipos.find((x) => x.id === id) ?? null;
    if (!t?.requiere_conyuge) setConyuge(parteVacia("conyuge"));
    if (t?.requiere_codeudor && codeudores.length === 0) setCodeudores([parteVacia("codeudor")]);
    if (!t?.requiere_codeudor) setCodeudores([]);
  }

  const monto = Number(precio);
  const faltaConyuge = tipoElegido?.requiere_conyuge === true && !conyuge.nombre.trim();
  const faltaCodeudor =
    tipoElegido?.requiere_codeudor === true && !codeudores.some((c) => c.nombre.trim());
  const invalido =
    !clienteId || !Number.isFinite(monto) || monto <= 0 || guardando || faltaConyuge || faltaCodeudor;

  async function confirmar() {
    setErr(null);
    setGuardando(true);
    try {
      const resVenta = await fetchWithSupabaseSession("/api/lotes/ventas", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          modalidad: "contado",
          lote_id: lote.id,
          cliente_id: clienteId,
          fecha_venta: fecha,
          primer_vencimiento: fecha,
          precio_contado: monto,
          tipo_contrato_id: tipoId || null,
          vendedor_id: vendedorId || null,
          comision_pct: vendedorId ? comision : 0,
          partes: [
            ...(tipoElegido?.requiere_conyuge ? [conyuge] : []),
            ...(tipoElegido?.requiere_codeudor ? codeudores : []),
          ].filter((x) => x.nombre.trim()),
          observacion,
        }),
      });
      const jsonVenta = (await resVenta.json()) as {
        success?: boolean;
        error?: string;
        data?: { numero_contrato?: string; primera_cuota_id?: string | null };
      };
      if (!resVenta.ok || jsonVenta.success !== true) {
        throw new Error(jsonVenta.error ?? `Error ${resVenta.status}`);
      }

      const numero = jsonVenta.data?.numero_contrato ?? "";
      const cuotaId = jsonVenta.data?.primera_cuota_id ?? null;

      if (!cuotaId) {
        await onVendido(
          `Contrato ${numero} generado, pero no se pudo identificar la cuota para cobrarla. Cobrala desde Contratos.`
        );
        return;
      }

      const resCobro = await fetchWithSupabaseSession(
        `/api/lotes/cuotas/${encodeURIComponent(cuotaId)}/cobrar`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            monto,
            fecha_pago: fecha,
            metodo_pago: metodo,
            referencia: referencia.trim(),
            cobrar_mora: false,
          }),
        }
      );
      const jsonCobro = (await resCobro.json()) as { success?: boolean; error?: string };
      if (!resCobro.ok || jsonCobro.success !== true) {
        // El contrato quedó creado: se avisa para que lo cobren desde Contratos
        // en vez de intentar vender el lote otra vez.
        await onVendido(
          `Contrato ${numero} generado, pero el cobro falló: ${jsonCobro.error ?? `Error ${resCobro.status}`}. Cobralo desde Contratos.`
        );
        return;
      }

      await onVendido(`Venta al contado registrada. Contrato ${numero} cobrado y facturado.`);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "No se pudo registrar la venta");
    } finally {
      setGuardando(false);
    }
  }

  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-slate-900/50 p-4" onClick={onCancel}>
      <div
        className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-2xl border border-slate-200 bg-white p-5 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-base font-semibold text-slate-900">Vender lote {lote.numero} al contado</h3>
            <p className="mt-0.5 text-[11px] text-slate-500">
              Se paga todo en el acto: sin recargo ni plan de cuotas. Se emite la factura y queda cobrada.
            </p>
          </div>
          <button type="button" onClick={onCancel} className="rounded-lg p-1 text-slate-400 hover:bg-slate-100">
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <label className={labelClass}>Tipo de contrato</label>
            <FancySelect
              value={tipoId}
              onChange={elegirTipo}
              placeholder={tipos.length === 0 ? "Sin tipos configurados" : "Elegí el tipo"}
              options={tipos.map((t) => ({ value: t.id, label: t.nombre, description: t.descripcion ?? undefined }))}
            />
          </div>

          <div className="sm:col-span-2">
            <label className={labelClass}>Cliente comprador</label>
            <SmartSearchSelect
              options={opcionesCliente}
              value={clienteId}
              onChange={setClienteId}
              placeholder="Buscar cliente…"
              required
            />
          </div>

          {tipoElegido?.requiere_conyuge ? (
            <div className="sm:col-span-2">
              <FormParte titulo="Datos del cónyuge" parte={conyuge} onChange={setConyuge} />
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
            <label className={labelClass}>Fecha de la venta</label>
            <FechaSelect value={fecha} onChange={(e) => setFecha(e.target.value)} className={inputClass} />
          </div>
          <div>
            <label className={labelClass}>Precio de venta</label>
            <MontoInput
              value={precio}
              onChange={(n) => setPrecio(String(n))}
              decimals={lote.moneda === "USD"}
              onFocus={(e) => e.currentTarget.select()}
              className={inputClass}
            />
            {lote.precio_contado ? (
              <p className="mt-1 text-[10px] text-slate-400">
                Precio de lista: {fmt(lote.precio_contado, lote.moneda)}
              </p>
            ) : (
              <p className="mt-1 text-[10px] text-amber-600">
                Este lote no tiene precio de lista cargado.
              </p>
            )}
          </div>
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
              className={inputClass}
            />
            <p className="mt-1 text-[10px] text-slate-400">
              Se liquida sobre el cobro, que en esta venta ocurre hoy mismo.
            </p>
          </div>
          <div>
            <label className={labelClass}>Método de pago</label>
            <FancySelect
              value={metodo}
              onChange={setMetodo}
              options={METODOS.map((m) => ({ value: m.id, label: m.label }))}
            />
          </div>
          <div>
            <label className={labelClass}>
              Referencia <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input value={referencia} onChange={(e) => setReferencia(e.target.value)} className={inputClass} />
          </div>
          <div className="sm:col-span-2">
            <label className={labelClass}>
              Observación <span className="font-normal text-slate-400">(opcional)</span>
            </label>
            <input value={observacion} onChange={(e) => setObservacion(e.target.value)} className={inputClass} />
          </div>
        </div>

        <div className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2.5 text-sm text-emerald-800">
          Cobra <strong>{fmt(monto || 0, lote.moneda)}</strong> el {fecha.split("-").reverse().join("/")} y el lote
          queda vendido.
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
            disabled={invalido}
            className="rounded-xl bg-emerald-600 px-3.5 py-2 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
          >
            {guardando ? "Registrando…" : "Confirmar venta al contado"}
          </button>
        </div>
      </div>
    </div>
  );
}
