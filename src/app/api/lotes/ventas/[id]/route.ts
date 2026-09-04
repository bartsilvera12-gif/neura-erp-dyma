import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { calcularMoraCuota } from "@/lib/financiacion/plan-cuotas";
import { hoyAsuncion } from "@/lib/reportes/calculo";
import type { CuotaVenta, EstadoCuota, EstadoVenta, VentaLote } from "@/lib/financiacion/types";

export const dynamic = "force-dynamic";

/**
 * GET /api/lotes/ventas/[id] — contrato con su plan de cuotas.
 *
 * La mora se calcula al vuelo y no se guarda: depende del día en que se mire, así
 * que persistirla obligaría a recalcular todo cada mañana y quedaría desfasada
 * apenas alguien consulte fuera de ese proceso.
 */
export async function GET(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  try {
    const { sb, empresaId } = auth;

    const { data: venta, error: errVenta } = await sb
      .from("lote_ventas")
      .select("*")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errVenta) throw new Error(errVenta.message);
    if (!venta) return NextResponse.json(errorResponse("Contrato no encontrado"), { status: 404 });

    const v = venta as Record<string, unknown>;

    const [cuotasRes, partesRes, loteRes, tipoRes] = await Promise.all([
      sb.from("lote_venta_cuotas").select("*").eq("venta_id", id).eq("empresa_id", empresaId).order("numero"),
      sb
        .from("lote_venta_partes")
        .select("id, rol, nombre, documento, domicilio, telefono")
        .eq("venta_id", id)
        .eq("empresa_id", empresaId)
        .order("created_at"),
      sb.from("lotes").select("id, numero, manzana_id").eq("id", String(v.lote_id)).maybeSingle(),
      v.tipo_contrato_id
        ? sb.from("contrato_tipos").select("id, slug, nombre").eq("id", String(v.tipo_contrato_id)).maybeSingle()
        : Promise.resolve({ data: null }),
    ]);
    if (cuotasRes.error) throw new Error(cuotasRes.error.message);

    const filasCuotas = (cuotasRes.data ?? []) as Record<string, unknown>[];
    const partesRaw = (partesRes.data ?? []) as Record<string, unknown>[];
    const tipoRaw = (tipoRes.data ?? null) as Record<string, unknown> | null;

    const etiquetas: Record<string, string> = {};
    {
      const { data: cls } = await sb
        .from("clientes")
        .select("id, empresa, nombre_contacto, nombre")
        .eq("id", String(v.cliente_id));
      for (const c of (cls ?? []) as Record<string, string | null>[]) {
        if (!c.id) continue;
        etiquetas[c.id] = (c.empresa || c.nombre_contacto || c.nombre || "").trim() || "Cliente sin nombre";
      }
    }

    // Números de las facturas ya emitidas por cuota.
    const facturaIds = filasCuotas
      .map((c) => c.factura_id)
      .filter((x): x is string => typeof x === "string");
    const numeroFactura: Record<string, string> = {};
    if (facturaIds.length > 0) {
      const { data: facs } = await sb
        .from("facturas")
        .select("id, numero_factura")
        .eq("empresa_id", empresaId)
        .in("id", facturaIds);
      for (const f of (facs ?? []) as Record<string, string>[]) {
        numeroFactura[f.id] = f.numero_factura;
      }
    }

    const hoy = hoyAsuncion();
    const diasGracia = Number(v.dias_gracia ?? 5);

    const cuotas: CuotaVenta[] = filasCuotas.map((c) => {
      const saldo = Number(c.saldo ?? 0);
      const pendiente = c.estado === "pendiente";
      // Solo las pendientes generan mora, y sobre el saldo impago, no sobre el
      // total: si hubo un pago parcial la mora corre sobre lo que falta.
      const m = pendiente
        ? calcularMoraCuota({ montoCuota: saldo, vencimiento: String(c.vencimiento), hoy, diasGracia })
        : { dias_atraso: 0, dias_en_mora: 0, gastos_administrativos: 0, gastos_moratorios: 0, total: 0 };

      return {
        id: String(c.id),
        numero: Number(c.numero),
        vencimiento: String(c.vencimiento),
        capital: Number(c.capital ?? 0),
        interes: Number(c.interes ?? 0),
        total: Number(c.total ?? 0),
        saldo,
        estado: c.estado as EstadoCuota,
        factura_id: (c.factura_id as string) ?? null,
        factura_numero: c.factura_id ? numeroFactura[String(c.factura_id)] ?? null : null,
        pagada_at: (c.pagada_at as string) ?? null,
        dias_atraso: m.dias_atraso,
        dias_en_mora: m.dias_en_mora,
        mora_administrativa: m.gastos_administrativos,
        mora_moratoria: m.gastos_moratorios,
        mora_total: m.total,
        total_a_pagar: saldo + m.total,
      };
    });

    const pendientes = cuotas.filter((c) => c.estado === "pendiente");
    const lote = loteRes.data as { numero?: string } | null;

    const payload: VentaLote = {
      id: String(v.id),
      numero_contrato: String(v.numero_contrato),
      fecha_venta: String(v.fecha_venta),
      lote_id: String(v.lote_id),
      lote_label: lote?.numero ? `Lote ${lote.numero}` : "Lote",
      cliente_id: String(v.cliente_id),
      cliente_label: etiquetas[String(v.cliente_id)] ?? "Cliente sin nombre",
      partes: partesRaw.map((p) => ({
        id: String(p.id),
        rol: p.rol === "conyuge" ? ("conyuge" as const) : ("codeudor" as const),
        nombre: String(p.nombre ?? ""),
        documento: (p.documento as string) ?? null,
        domicilio: (p.domicilio as string) ?? null,
        telefono: (p.telefono as string) ?? null,
      })),
      tipo_contrato: tipoRaw
        ? { id: String(tipoRaw.id), slug: String(tipoRaw.slug), nombre: String(tipoRaw.nombre) }
        : null,
      precio_contado: Number(v.precio_contado ?? 0),
      entrega_inicial: Number(v.entrega_inicial ?? 0),
      capital: Number(v.capital ?? 0),
      interes_total: Number(v.interes_total ?? 0),
      monto_financiado: Number(v.monto_financiado ?? 0),
      cantidad_cuotas: Number(v.cantidad_cuotas ?? 0),
      primer_vencimiento: String(v.primer_vencimiento),
      moneda: String(v.moneda ?? "GS"),
      recargo_pct: Number(v.recargo_pct ?? 0.15),
      dias_gracia: diasGracia,
      mora_administrativa_pct: Number(v.mora_administrativa_pct ?? 0.017),
      mora_moratoria_pct: Number(v.mora_moratoria_pct ?? 0.033),
      estado: v.estado as EstadoVenta,
      observacion: (v.observacion as string) ?? null,
      cuotas,
      resumen: {
        cuotas_pagadas: cuotas.filter((c) => c.estado === "pagada").length,
        cuotas_pendientes: pendientes.length,
        cuotas_vencidas: pendientes.filter((c) => c.dias_atraso > 0).length,
        // Lo cobrado es la diferencia entre lo facturado y lo que sigue impago.
        cobrado: cuotas
          .filter((c) => c.estado !== "anulada")
          .reduce((a, c) => a + (c.total - c.saldo), 0),
        saldo: pendientes.reduce((a, c) => a + c.saldo, 0),
        mora_acumulada: pendientes.reduce((a, c) => a + c.mora_total, 0),
        deuda_total: pendientes.reduce((a, c) => a + c.total_a_pagar, 0),
      },
    };

    return NextResponse.json(successResponse(payload));
  } catch (e) {
    console.error("[api/lotes/ventas/[id] GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/**
 * PATCH /api/lotes/ventas/[id] — anula el contrato.
 *
 * Anular libera el lote (vuelve a disponible) solo si ninguna cuota fue cobrada:
 * si ya entró plata, hay que resolver la devolución antes, y eso no se decide acá.
 */
export async function PATCH(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  if (body.estado !== "anulada") {
    return NextResponse.json(errorResponse("Solo se admite anular el contrato"), { status: 400 });
  }
  const motivo = typeof body.motivo === "string" ? body.motivo.trim() : "";
  if (!motivo) return NextResponse.json(errorResponse("Indicá el motivo de la anulación"), { status: 400 });

  try {
    const { sb, empresaId } = auth;
    const { data: venta, error: errGet } = await sb
      .from("lote_ventas")
      .select("id, lote_id, estado")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!venta) return NextResponse.json(errorResponse("Contrato no encontrado"), { status: 404 });
    if ((venta as { estado: string }).estado !== "vigente") {
      return NextResponse.json(errorResponse("El contrato no está vigente."), { status: 409 });
    }

    // Una cuota con saldo menor a su total ya recibio plata.
    const conCobro = await sb
      .from("lote_venta_cuotas")
      .select("id, total, saldo")
      .eq("venta_id", id)
      .eq("empresa_id", empresaId);
    const huboPagos = ((conCobro.data ?? []) as Record<string, unknown>[]).some(
      (c) => Number(c.saldo ?? 0) < Number(c.total ?? 0)
    );
    if (huboPagos) {
      return NextResponse.json(
        errorResponse(
          "El contrato ya tiene cuotas cobradas. Resolvé la devolución antes de anularlo."
        ),
        { status: 409 }
      );
    }
    const { error: errUpd } = await sb
      .from("lote_ventas")
      .update({ estado: "anulada", anulada_motivo: motivo })
      .eq("id", id)
      .eq("empresa_id", empresaId);
    if (errUpd) throw new Error(errUpd.message);

    await sb
      .from("lote_venta_cuotas")
      .update({ estado: "anulada" })
      .eq("venta_id", id)
      .eq("empresa_id", empresaId)
      .eq("estado", "pendiente");

    // El lote vuelve al inventario disponible, sin titular.
    await sb
      .from("lotes")
      .update({ estado: "disponible", cliente_id: null })
      .eq("id", String((venta as { lote_id: string }).lote_id))
      .eq("empresa_id", empresaId);

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/lotes/ventas/[id] PATCH]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
