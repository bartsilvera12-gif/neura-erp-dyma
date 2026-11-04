import "server-only";
import type { AppSupabaseClient } from "@/lib/supabase/schema";
import {
  armarEstadoResultado,
  type BaseReporte,
  type EstadoResultado,
  type GastoPeriodo,
  type VentaPeriodo,
} from "./estado-resultado";

/**
 * De dónde salen los números del estado de resultado.
 *
 * VENTAS — hay dos lecturas y el usuario elige cuál mirar:
 *
 *   Percibido: lo cobrado en el período (los pagos imputados a facturas). Es lo
 *   que el dueño entiende por "cuánto entró este mes". El costo del lote se
 *   reconoce en la misma proporción que lo cobrado: si del contrato se cobró el
 *   10%, pesa el 10% del costo. Así el margen no se dispara el mes de la firma
 *   ni queda en 100% durante los años siguientes.
 *
 *   Devengado: el contrato entra entero el mes en que se firmó, con todo el
 *   costo del lote. Las cuotas que se cobren después ya no suman. Es la lectura
 *   contable clásica.
 *
 * GASTOS — los del período agrupados por cuenta del plan. Los que quedaron sin
 * clasificar se juntan al final en vez de desaparecer del total.
 */

const PAGE = 800;
const CONCEPTO_LOTES = "Venta de lotes";
const CONCEPTO_LIMPIEZA = "Servicio de limpieza";
const CONCEPTO_OTROS = "Otras facturas";
const SIN_CLASIFICAR = "Sin clasificar";

function ymd(v: unknown): string {
  return String(v ?? "").slice(0, 10);
}

/** Trae todas las filas de una consulta paginada, sin traerse la tabla entera de un saque. */
async function paginar<T = Record<string, unknown>>(
  construir: (desde: number, hasta: number) => PromiseLike<{ data: unknown; error: { message: string } | null }>
): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await construir(from, from + PAGE - 1);
    if (error) throw new Error(error.message);
    const chunk = (data ?? []) as T[];
    out.push(...chunk);
    if (chunk.length < PAGE) break;
  }
  return out;
}

interface ContratoCosto {
  /** Precio total pactado: entrega inicial + monto financiado. */
  precio: number;
  /** Costo del lote, o null si todavía no se cargó. */
  costo: number | null;
  fecha_venta: string;
  lote_id: string;
}

/** Contratos de lote con su precio y el costo del lote, por id de contrato. */
async function cargarContratos(sb: AppSupabaseClient, empresaId: string): Promise<Map<string, ContratoCosto>> {
  const ventas = await paginar<Record<string, unknown>>((a, b) =>
    sb
      .from("lote_ventas")
      .select("id, lote_id, fecha_venta, entrega_inicial, monto_financiado, estado")
      .eq("empresa_id", empresaId)
      .neq("estado", "anulada")
      .range(a, b)
  );

  const loteIds = [...new Set(ventas.map((v) => String(v.lote_id ?? "")).filter(Boolean))];
  const costoLote = new Map<string, number | null>();
  for (let i = 0; i < loteIds.length; i += 120) {
    const { data } = await sb.from("lotes").select("id, costo_adquisicion").in("id", loteIds.slice(i, i + 120));
    for (const l of (data ?? []) as Record<string, unknown>[]) {
      costoLote.set(String(l.id), l.costo_adquisicion == null ? null : Number(l.costo_adquisicion));
    }
  }

  const out = new Map<string, ContratoCosto>();
  for (const v of ventas) {
    const loteId = String(v.lote_id ?? "");
    out.set(String(v.id), {
      precio: (Number(v.entrega_inicial) || 0) + (Number(v.monto_financiado) || 0),
      costo: costoLote.get(loteId) ?? null,
      fecha_venta: ymd(v.fecha_venta),
      lote_id: loteId,
    });
  }
  return out;
}

/** Qué contrato hay detrás de cada factura, y cuáles son de limpieza. */
async function cargarOrigenFacturas(
  sb: AppSupabaseClient,
  empresaId: string
): Promise<{ contratoPorFactura: Map<string, string>; facturasLimpieza: Set<string> }> {
  const cuotas = await paginar<Record<string, unknown>>((a, b) =>
    sb
      .from("lote_venta_cuotas")
      .select("factura_id, venta_id")
      .eq("empresa_id", empresaId)
      .not("factura_id", "is", null)
      .range(a, b)
  );
  const contratoPorFactura = new Map<string, string>();
  for (const q of cuotas) contratoPorFactura.set(String(q.factura_id), String(q.venta_id));

  const limpiezas = await paginar<Record<string, unknown>>((a, b) =>
    sb
      .from("servicios_limpieza")
      .select("factura_id")
      .eq("empresa_id", empresaId)
      .not("factura_id", "is", null)
      .range(a, b)
  );
  const facturasLimpieza = new Set(limpiezas.map((l) => String(l.factura_id)));

  return { contratoPorFactura, facturasLimpieza };
}

/** Ventas del período según lo cobrado. */
async function ventasPercibido(
  sb: AppSupabaseClient,
  empresaId: string,
  desde: string,
  hasta: string
): Promise<VentaPeriodo[]> {
  const [pagos, contratos, origen] = await Promise.all([
    paginar<Record<string, unknown>>((a, b) =>
      sb
        .from("pagos")
        .select("factura_id, monto, fecha_pago")
        .eq("empresa_id", empresaId)
        .gte("fecha_pago", desde)
        .lte("fecha_pago", hasta)
        .range(a, b)
    ),
    cargarContratos(sb, empresaId),
    cargarOrigenFacturas(sb, empresaId),
  ]);

  const acumulado = new Map<string, VentaPeriodo>();
  const sumar = (concepto: string, ingreso: number, costo: number) => {
    const v = acumulado.get(concepto) ?? { concepto, ingreso: 0, costo: 0, sin_costo: 0 };
    v.ingreso += ingreso;
    v.costo += costo;
    acumulado.set(concepto, v);
  };
  // Contratos cobrados en el período a los que les falta el costo del lote.
  const contratosSinCosto = new Set<string>();

  for (const p of pagos) {
    const monto = Number(p.monto) || 0;
    if (monto === 0) continue;
    const fid = String(p.factura_id ?? "");
    const ventaId = origen.contratoPorFactura.get(fid);

    if (ventaId) {
      const c = contratos.get(ventaId);
      // El costo se reconoce en la misma proporción que lo cobrado.
      let costo = 0;
      if (c && c.costo != null && c.precio > 0) costo = (c.costo * monto) / c.precio;
      else if (c && c.costo == null) contratosSinCosto.add(ventaId);
      sumar(CONCEPTO_LOTES, monto, costo);
      continue;
    }

    sumar(origen.facturasLimpieza.has(fid) ? CONCEPTO_LIMPIEZA : CONCEPTO_OTROS, monto, 0);
  }

  const lotes = acumulado.get(CONCEPTO_LOTES);
  if (lotes) lotes.sin_costo = contratosSinCosto.size;

  return [...acumulado.values()];
}

/** Ventas del período según lo facturado: el contrato entra el mes en que se firmó. */
async function ventasDevengado(
  sb: AppSupabaseClient,
  empresaId: string,
  desde: string,
  hasta: string
): Promise<VentaPeriodo[]> {
  const [ventasRows, facturas, origen] = await Promise.all([
    paginar<Record<string, unknown>>((a, b) =>
      sb
        .from("lote_ventas")
        .select("id, lote_id, fecha_venta, entrega_inicial, monto_financiado, estado")
        .eq("empresa_id", empresaId)
        .neq("estado", "anulada")
        .gte("fecha_venta", desde)
        .lte("fecha_venta", hasta)
        .range(a, b)
    ),
    paginar<Record<string, unknown>>((a, b) =>
      sb
        .from("facturas")
        .select("id, monto, fecha, estado")
        .eq("empresa_id", empresaId)
        .gte("fecha", desde)
        .lte("fecha", hasta)
        .range(a, b)
    ),
    cargarOrigenFacturas(sb, empresaId),
  ]);

  const loteIds = [...new Set(ventasRows.map((v) => String(v.lote_id ?? "")).filter(Boolean))];
  const costoLote = new Map<string, number | null>();
  for (let i = 0; i < loteIds.length; i += 120) {
    const { data } = await sb.from("lotes").select("id, costo_adquisicion").in("id", loteIds.slice(i, i + 120));
    for (const l of (data ?? []) as Record<string, unknown>[]) {
      costoLote.set(String(l.id), l.costo_adquisicion == null ? null : Number(l.costo_adquisicion));
    }
  }

  const lotes: VentaPeriodo = { concepto: CONCEPTO_LOTES, ingreso: 0, costo: 0, sin_costo: 0 };
  for (const v of ventasRows) {
    lotes.ingreso += (Number(v.entrega_inicial) || 0) + (Number(v.monto_financiado) || 0);
    const costo = costoLote.get(String(v.lote_id ?? "")) ?? null;
    if (costo == null) lotes.sin_costo += 1;
    else lotes.costo += costo;
  }

  // Las facturas de cuotas no suman acá: su contrato ya entró entero al firmarse.
  const otras = new Map<string, VentaPeriodo>();
  for (const f of facturas) {
    if (String(f.estado ?? "").trim().toLowerCase() === "anulado") continue;
    const fid = String(f.id);
    if (origen.contratoPorFactura.has(fid)) continue;
    const concepto = origen.facturasLimpieza.has(fid) ? CONCEPTO_LIMPIEZA : CONCEPTO_OTROS;
    const v = otras.get(concepto) ?? { concepto, ingreso: 0, costo: 0, sin_costo: 0 };
    v.ingreso += Number(f.monto) || 0;
    otras.set(concepto, v);
  }

  return [lotes, ...otras.values()];
}

/** Gastos del período, ya resueltos contra su cuenta del plan. */
async function gastosDelPeriodo(
  sb: AppSupabaseClient,
  empresaId: string,
  desde: string,
  hasta: string
): Promise<GastoPeriodo[]> {
  const [gastos, cuentasRows] = await Promise.all([
    paginar<Record<string, unknown>>((a, b) =>
      sb
        .from("gastos")
        .select("monto, fecha, cuenta_id, categoria")
        .eq("empresa_id", empresaId)
        .gte("fecha", desde)
        .lte("fecha", hasta)
        .range(a, b)
    ),
    paginar<Record<string, unknown>>((a, b) =>
      sb.from("gasto_cuentas").select("id, codigo, nombre, orden").eq("empresa_id", empresaId).range(a, b)
    ),
  ]);

  const cuentas = new Map(
    cuentasRows.map((c) => [
      String(c.id),
      { codigo: String(c.codigo ?? ""), nombre: String(c.nombre ?? ""), orden: Number(c.orden) || 0 },
    ])
  );

  return gastos.map((g) => {
    const c = g.cuenta_id ? cuentas.get(String(g.cuenta_id)) : undefined;
    if (c) return { cuenta_codigo: c.codigo, cuenta_nombre: c.nombre, orden: c.orden, monto: Number(g.monto) || 0 };
    // Sin cuenta: va al final, pero suma. Esconderlo descuadraría el total.
    return {
      cuenta_codigo: "",
      cuenta_nombre: String(g.categoria ?? "").trim() ? `${SIN_CLASIFICAR}: ${String(g.categoria).trim()}` : SIN_CLASIFICAR,
      orden: 99_999,
      monto: Number(g.monto) || 0,
    };
  });
}

/** El estado de resultado completo del período. */
export async function cargarEstadoResultado(
  sb: AppSupabaseClient,
  empresaId: string,
  desde: string,
  hasta: string,
  base: BaseReporte
): Promise<EstadoResultado> {
  const [ventas, gastos] = await Promise.all([
    base === "devengado" ? ventasDevengado(sb, empresaId, desde, hasta) : ventasPercibido(sb, empresaId, desde, hasta),
    gastosDelPeriodo(sb, empresaId, desde, hasta),
  ]);
  return armarEstadoResultado({ desde, hasta, base, ventas, gastos });
}
