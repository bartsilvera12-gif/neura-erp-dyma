import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { comisionDeCobro } from "@/lib/vendedores/calculo-comision";
import { toCalendarDateStr } from "@/lib/fechas/calendario";
import type { ComisionCobro, ComisionVendedor, ComisionesPayload } from "@/lib/vendedores/types";

export const dynamic = "force-dynamic";

const FECHA_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

/** Trae en tandas: PostgREST limita el largo de un `in(...)`. */
async function enTandas<T>(ids: string[], tam: number, fn: (slice: string[]) => Promise<T[]>): Promise<T[]> {
  const out: T[] = [];
  for (let i = 0; i < ids.length; i += tam) {
    const slice = ids.slice(i, i + tam);
    if (slice.length === 0) break;
    out.push(...(await fn(slice)));
  }
  return out;
}

/**
 * GET /api/lotes/comisiones?desde=&hasta=&vendedor_id=
 *
 * Comisión de cada vendedor por las cuotas COBRADAS en el período. La fuente es
 * el pago imputado a la factura de la cuota, no la cuota misma: así un pago
 * parcial comisiona solo lo que entró, y una cuota que se cobra tarde cae en el
 * mes en que se cobró, no en el de su vencimiento. Las cuotas pendientes no
 * aparecen hasta que alguien las paga.
 *
 * El porcentaje sale del contrato (`lote_ventas.comision_pct`), congelado al
 * vender: renegociar con el vendedor no reescribe liquidaciones viejas.
 */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const url = new URL(request.url);
  const desde = (url.searchParams.get("desde") ?? "").trim();
  const hasta = (url.searchParams.get("hasta") ?? "").trim();
  const vendedorFiltro = (url.searchParams.get("vendedor_id") ?? "").trim();

  if (!FECHA_RE.test(desde) || !FECHA_RE.test(hasta)) {
    return NextResponse.json(errorResponse("Rango de fechas inválido (YYYY-MM-DD)"), { status: 400 });
  }
  if (desde > hasta) {
    return NextResponse.json(errorResponse("La fecha inicial no puede ser posterior a la final"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;

    const { data: ventasRaw, error: errVentas } = await sb
      .from("lote_ventas")
      .select("id, numero_contrato, cliente_id, lote_id, vendedor_id, comision_pct, moneda")
      .eq("empresa_id", empresaId);
    if (errVentas) throw new Error(errVentas.message);

    const ventas = (ventasRaw ?? []) as Record<string, unknown>[];
    if (ventas.length === 0) {
      return NextResponse.json(
        successResponse({
          desde,
          hasta,
          vendedores: [],
          total_cobrado: 0,
          total_comision: 0,
          cobros_sin_vendedor: 0,
          monto_sin_vendedor: 0,
        } satisfies ComisionesPayload)
      );
    }

    const ventaPorId = new Map(ventas.map((v) => [String(v.id), v]));
    const ventaIds = [...ventaPorId.keys()];

    // Cuotas de esos contratos: la factura de cada una es el puente hacia el pago.
    const cuotas = await enTandas(ventaIds, 120, async (slice) => {
      const { data, error } = await sb
        .from("lote_venta_cuotas")
        .select("id, venta_id, numero, vencimiento, factura_id")
        .eq("empresa_id", empresaId)
        .in("venta_id", slice);
      if (error) throw new Error(error.message);
      return (data ?? []) as Record<string, unknown>[];
    });

    const cuotaPorFactura = new Map<string, Record<string, unknown>>();
    for (const c of cuotas) {
      const fid = c.factura_id ? String(c.factura_id) : "";
      if (fid) cuotaPorFactura.set(fid, c);
    }
    const facturaIds = [...cuotaPorFactura.keys()];
    if (facturaIds.length === 0) {
      return NextResponse.json(
        successResponse({
          desde,
          hasta,
          vendedores: [],
          total_cobrado: 0,
          total_comision: 0,
          cobros_sin_vendedor: 0,
          monto_sin_vendedor: 0,
        } satisfies ComisionesPayload)
      );
    }

    const pagos = await enTandas(facturaIds, 120, async (slice) => {
      const { data, error } = await sb
        .from("pagos")
        .select("id, factura_id, monto, fecha_pago")
        .eq("empresa_id", empresaId)
        .in("factura_id", slice)
        .gte("fecha_pago", desde)
        .lte("fecha_pago", hasta);
      if (error) throw new Error(error.message);
      return (data ?? []) as Record<string, unknown>[];
    });

    if (pagos.length === 0) {
      return NextResponse.json(
        successResponse({
          desde,
          hasta,
          vendedores: [],
          total_cobrado: 0,
          total_comision: 0,
          cobros_sin_vendedor: 0,
          monto_sin_vendedor: 0,
        } satisfies ComisionesPayload)
      );
    }

    // Etiquetas: se resuelven una vez para todo el listado.
    const clienteIds = [...new Set(ventas.map((v) => String(v.cliente_id)).filter(Boolean))];
    const loteIds = [...new Set(ventas.map((v) => String(v.lote_id)).filter(Boolean))];
    const vendedorIds = [
      ...new Set(ventas.map((v) => (v.vendedor_id ? String(v.vendedor_id) : "")).filter(Boolean)),
    ];
    const facturasCobradas = [...new Set(pagos.map((p) => String(p.factura_id)))];

    const [clientesRes, lotesRes, vendedoresRes, facturasRes] = await Promise.all([
      clienteIds.length
        ? sb.from("clientes").select("id, empresa, nombre_contacto, nombre").in("id", clienteIds)
        : Promise.resolve({ data: [] }),
      loteIds.length ? sb.from("lotes").select("id, numero").in("id", loteIds) : Promise.resolve({ data: [] }),
      vendedorIds.length
        ? sb.from("vendedores").select("id, codigo, nombre").in("id", vendedorIds)
        : Promise.resolve({ data: [] }),
      sb
        .from("facturas")
        .select("id, numero_factura")
        .eq("empresa_id", empresaId)
        .in("id", facturasCobradas),
    ]);

    const etiquetaCliente = new Map<string, string>();
    for (const c of (clientesRes.data ?? []) as Record<string, string | null>[]) {
      if (!c.id) continue;
      etiquetaCliente.set(
        c.id,
        (c.empresa || c.nombre_contacto || c.nombre || "").trim() || "Cliente sin nombre"
      );
    }
    const etiquetaLote = new Map<string, string>();
    for (const l of (lotesRes.data ?? []) as Record<string, string>[]) {
      etiquetaLote.set(l.id, `Lote ${l.numero}`);
    }
    const datosVendedor = new Map<string, { codigo: string; nombre: string }>();
    for (const v of (vendedoresRes.data ?? []) as Record<string, string>[]) {
      datosVendedor.set(v.id, { codigo: v.codigo ?? "", nombre: v.nombre ?? "" });
    }
    const numeroFactura = new Map<string, string | null>();
    for (const f of (facturasRes.data ?? []) as Record<string, unknown>[]) {
      numeroFactura.set(String(f.id), (f.numero_factura as string) ?? null);
    }

    const porVendedor = new Map<string, ComisionVendedor>();
    let cobrosSinVendedor = 0;
    let montoSinVendedor = 0;

    for (const p of pagos) {
      const facturaId = String(p.factura_id);
      const cuota = cuotaPorFactura.get(facturaId);
      if (!cuota) continue;
      const venta = ventaPorId.get(String(cuota.venta_id));
      if (!venta) continue;

      const vendedorId = venta.vendedor_id ? String(venta.vendedor_id) : "";
      const monto = Number(p.monto ?? 0);

      if (!vendedorId) {
        // Sin vendedor no hay comisión, pero el total se informa: casi siempre es
        // una venta a la que se olvidaron de asignarle el vendedor.
        cobrosSinVendedor += 1;
        montoSinVendedor += monto;
        continue;
      }
      if (vendedorFiltro && vendedorId !== vendedorFiltro) continue;

      const moneda = String(venta.moneda ?? "GS");
      const pct = Number(venta.comision_pct ?? 0);
      const cobro: ComisionCobro = {
        pago_id: String(p.id),
        fecha_pago: toCalendarDateStr(String(p.fecha_pago ?? "")),
        monto_cobrado: monto,
        venta_id: String(venta.id),
        numero_contrato: String(venta.numero_contrato ?? ""),
        lote_label: etiquetaLote.get(String(venta.lote_id)) ?? "Lote",
        cliente_id: String(venta.cliente_id ?? ""),
        cliente_label: etiquetaCliente.get(String(venta.cliente_id)) ?? "Cliente sin nombre",
        cuota_numero: Number(cuota.numero ?? 0),
        cuota_vencimiento: toCalendarDateStr(String(cuota.vencimiento ?? "")),
        factura_numero: numeroFactura.get(facturaId) ?? null,
        moneda,
        comision_pct: pct,
        comision: comisionDeCobro(monto, pct, moneda),
      };

      let g = porVendedor.get(vendedorId);
      if (!g) {
        const d = datosVendedor.get(vendedorId);
        g = {
          vendedor_id: vendedorId,
          codigo: d?.codigo ?? "",
          nombre: d?.nombre ?? "Vendedor",
          cobros: [],
          ventas: 0,
          clientes: 0,
          cuotas_cobradas: 0,
          total_cobrado: 0,
          total_comision: 0,
        };
        porVendedor.set(vendedorId, g);
      }
      g.cobros.push(cobro);
      g.total_cobrado += cobro.monto_cobrado;
      g.total_comision += cobro.comision;
    }

    const vendedores = [...porVendedor.values()].map((g) => {
      g.cobros.sort((a, b) =>
        a.fecha_pago === b.fecha_pago
          ? a.numero_contrato.localeCompare(b.numero_contrato) || a.cuota_numero - b.cuota_numero
          : a.fecha_pago.localeCompare(b.fecha_pago)
      );
      g.cuotas_cobradas = g.cobros.length;
      g.ventas = new Set(g.cobros.map((c) => c.venta_id)).size;
      g.clientes = new Set(g.cobros.map((c) => c.cliente_id)).size;
      return g;
    });
    vendedores.sort((a, b) => b.total_comision - a.total_comision || a.nombre.localeCompare(b.nombre));

    return NextResponse.json(
      successResponse({
        desde,
        hasta,
        vendedores,
        total_cobrado: vendedores.reduce((a, v) => a + v.total_cobrado, 0),
        total_comision: vendedores.reduce((a, v) => a + v.total_comision, 0),
        cobros_sin_vendedor: cobrosSinVendedor,
        monto_sin_vendedor: montoSinVendedor,
      } satisfies ComisionesPayload)
    );
  } catch (e) {
    console.error("[api/lotes/comisiones GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
