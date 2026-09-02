import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { calcularMoraCuota } from "@/lib/financiacion/plan-cuotas";
import { hoyAsuncion } from "@/lib/reportes/calculo";
import { emitirFacturaSimple } from "@/lib/facturacion/emitir-factura-simple";
import { getFacturasServiceClientForEmpresa } from "@/lib/facturacion/facturas-service-client";
import { emitEvent, EVENT_TYPES } from "@/lib/integrations/events";
import { toCalendarDateStr } from "@/lib/fechas/calendario";

export const dynamic = "force-dynamic";

const METODOS = ["efectivo", "transferencia", "cheque", "tarjeta", "otro"] as const;
type Metodo = (typeof METODOS)[number];

/**
 * POST /api/lotes/cuotas/[id]/cobrar — registra el cobro de una cuota.
 *
 * Facturación por cuota: al cobrar se emite una factura individual por esa cuota
 * (si todavía no tenía una) y el pago se imputa contra ella. De esa forma la cuota
 * entra sola al circuito de Cobranzas, Pagos y Estado de cuenta, sin un camino
 * paralelo que después no cuadre.
 *
 * Admite pago parcial: el saldo baja por el monto cobrado y la cuota queda
 * pendiente hasta llegar a cero. La mora se cobra aparte del capital y no reduce
 * el saldo de la cuota; se factura como un ítem propio.
 */
export async function POST(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const montoRaw = Number(body.monto);
  const fechaRaw = typeof body.fecha_pago === "string" ? body.fecha_pago.trim() : "";
  const fechaPago = toCalendarDateStr(fechaRaw) || fechaRaw.slice(0, 10);
  const metodo: Metodo = (METODOS as readonly string[]).includes(String(body.metodo_pago))
    ? (body.metodo_pago as Metodo)
    : "efectivo";
  const referencia = typeof body.referencia === "string" ? body.referencia.trim() : "";
  const cobrarMora = body.cobrar_mora !== false;

  if (!/^\d{4}-\d{2}-\d{2}$/.test(fechaPago)) {
    return NextResponse.json(errorResponse("Fecha de pago inválida"), { status: 400 });
  }
  if (!Number.isFinite(montoRaw) || montoRaw <= 0) {
    return NextResponse.json(errorResponse("El monto debe ser mayor a 0"), { status: 400 });
  }
  const monto = Math.round(montoRaw);

  try {
    const { sb, empresaId } = auth;

    const { data: cuota, error: errCuota } = await sb
      .from("lote_venta_cuotas")
      .select("*")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errCuota) throw new Error(errCuota.message);
    if (!cuota) return NextResponse.json(errorResponse("Cuota no encontrada"), { status: 404 });

    const c = cuota as Record<string, unknown>;
    if (c.estado === "pagada") {
      return NextResponse.json(errorResponse("La cuota ya está pagada."), { status: 409 });
    }
    if (c.estado === "anulada") {
      return NextResponse.json(errorResponse("La cuota está anulada."), { status: 409 });
    }

    const { data: venta, error: errVenta } = await sb
      .from("lote_ventas")
      .select("id, cliente_id, numero_contrato, moneda, dias_gracia, estado")
      .eq("id", String(c.venta_id))
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errVenta) throw new Error(errVenta.message);
    if (!venta) return NextResponse.json(errorResponse("Contrato no encontrado"), { status: 404 });
    const v = venta as Record<string, unknown>;
    if (v.estado !== "vigente") {
      return NextResponse.json(errorResponse("El contrato no está vigente."), { status: 409 });
    }

    const saldo = Number(c.saldo ?? 0);
    const hoy = hoyAsuncion();
    const mora = calcularMoraCuota({
      montoCuota: saldo,
      vencimiento: String(c.vencimiento),
      hoy,
      diasGracia: Number(v.dias_gracia ?? 5),
    });
    const moraACobrar = cobrarMora ? mora.total : 0;
    const totalExigible = saldo + moraACobrar;

    if (monto > totalExigible) {
      return NextResponse.json(
        errorResponse(
          `El cobro supera lo adeudado por la cuota (${totalExigible.toLocaleString("es-PY")}).`
        ),
        { status: 400 }
      );
    }

    // La mora se cobra primero: el resto amortiza la cuota.
    const aplicadoAMora = Math.min(monto, moraACobrar);
    const aplicadoACuota = monto - aplicadoAMora;
    const nuevoSaldo = saldo - aplicadoACuota;

    // Factura de la cuota. Se emite una sola vez y se reutiliza en pagos parciales.
    const sbFact = await getFacturasServiceClientForEmpresa(empresaId);
    let facturaId = (c.factura_id as string) ?? null;

    if (!facturaId) {
      const detalle = `Contrato ${String(v.numero_contrato)} — cuota ${Number(c.numero)} · vence ${String(c.vencimiento)}`;
      const factura = await emitirFacturaSimple(sbFact, {
        empresaId,
        clienteId: String(v.cliente_id),
        fecha: fechaPago,
        importe: Number(c.total ?? 0),
        moneda: v.moneda === "USD" ? "USD" : "GS",
        // Contado: la cuota se factura en el momento del cobro, ya vencida.
        tipo: "contado",
        descripcion: detalle,
      });
      facturaId = factura.id;

      const { error: errLink } = await sb
        .from("lote_venta_cuotas")
        .update({ factura_id: facturaId })
        .eq("id", id)
        .eq("empresa_id", empresaId);
      if (errLink) {
        // Sin el vínculo la cuota volvería a facturarse en el próximo cobro.
        await sbFact.from("factura_items").delete().eq("factura_id", facturaId).eq("empresa_id", empresaId);
        await sbFact.from("facturas").delete().eq("id", facturaId).eq("empresa_id", empresaId);
        throw new Error(`No se pudo vincular la factura a la cuota: ${errLink.message}`);
      }

      await emitEvent(EVENT_TYPES.factura_creada, {
        factura_id: facturaId,
        cliente_id: String(v.cliente_id),
        monto: Number(c.total ?? 0),
      });
    }

    // El pago se imputa a la factura de la cuota, que es lo que ve Cobranzas.
    const referenciaFinal = [referencia, moraACobrar > 0 ? `mora ${aplicadoAMora.toLocaleString("es-PY")}` : ""]
      .filter(Boolean)
      .join(" · ");

    const { error: errPago } = await sbFact.from("pagos").insert({
      empresa_id: empresaId,
      factura_id: facturaId,
      cliente_id: String(v.cliente_id),
      monto: aplicadoACuota > 0 ? aplicadoACuota : monto,
      fecha_pago: fechaPago,
      metodo_pago: metodo,
      referencia: referenciaFinal || null,
    });
    if (errPago) throw new Error(`No se pudo registrar el pago: ${errPago.message}`);

    // Saldo de la factura, en línea con el saldo de la cuota.
    if (aplicadoACuota > 0) {
      const { data: fac } = await sbFact
        .from("facturas")
        .select("saldo")
        .eq("id", facturaId)
        .eq("empresa_id", empresaId)
        .maybeSingle();
      const saldoFactura = Math.max(0, Number((fac as { saldo?: number } | null)?.saldo ?? 0) - aplicadoACuota);
      await sbFact
        .from("facturas")
        .update({ saldo: saldoFactura, estado: saldoFactura <= 0 ? "Pagado" : "Pendiente" })
        .eq("id", facturaId)
        .eq("empresa_id", empresaId);
    }

    const { error: errUpd } = await sb
      .from("lote_venta_cuotas")
      .update({
        saldo: nuevoSaldo,
        estado: nuevoSaldo <= 0 ? "pagada" : "pendiente",
        pagada_at: nuevoSaldo <= 0 ? new Date().toISOString() : null,
      })
      .eq("id", id)
      .eq("empresa_id", empresaId);
    if (errUpd) throw new Error(`No se pudo actualizar la cuota: ${errUpd.message}`);

    // Contrato cancelado cuando no queda ninguna cuota pendiente.
    const { data: restantes } = await sb
      .from("lote_venta_cuotas")
      .select("id")
      .eq("venta_id", String(c.venta_id))
      .eq("empresa_id", empresaId)
      .eq("estado", "pendiente")
      .limit(1);
    if ((restantes ?? []).length === 0) {
      await sb
        .from("lote_ventas")
        .update({ estado: "cancelada" })
        .eq("id", String(c.venta_id))
        .eq("empresa_id", empresaId);
    }

    return NextResponse.json(
      successResponse({
        ok: true,
        cuota_id: id,
        factura_id: facturaId,
        aplicado_a_mora: aplicadoAMora,
        aplicado_a_cuota: aplicadoACuota,
        saldo_cuota: nuevoSaldo,
        cuota_pagada: nuevoSaldo <= 0,
      })
    );
  } catch (e) {
    console.error("[api/lotes/cuotas/[id]/cobrar POST]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
