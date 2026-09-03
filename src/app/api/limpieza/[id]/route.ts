import { NextResponse } from "next/server";
import { requireLimpiezaModuleAccess } from "@/lib/limpieza/limpieza-auth";
import {
  actualizarFacturaSimple,
  borrarFacturaSiNoTienePagos,
  facturaTieneCobros,
} from "@/lib/facturacion/emitir-factura-simple";
import { getFacturasServiceClientForEmpresa } from "@/lib/facturacion/facturas-service-client";
import { errorResponse, successResponse } from "@/lib/api/response";
import { toCalendarDateStr } from "@/lib/fechas/calendario";
import type { MonedaLimpieza, TipoFacturaLimpieza } from "@/lib/limpieza/types";

export const dynamic = "force-dynamic";

const FECHA_RE = /^d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]d|3[01])$/;

/**
 * PATCH /api/limpieza/[id] — corrige un servicio ya cargado.
 *
 * Existe para no obligar a borrar y volver a cargar por un dato mal tipeado.
 * Reescribe también la factura del servicio, que es lo que ve Cobranzas: si no,
 * el registro y el documento contable quedarían diciendo cosas distintas.
 *
 * Con cobros ya imputados solo se admite retocar la observación. Cambiar importe,
 * cliente, moneda o fecha movería un saldo ya conciliado; eso se corrige desde
 * Facturas (anulación o nota de crédito).
 */
export async function PATCH(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLimpiezaModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  if (!id?.trim()) return NextResponse.json(errorResponse("id requerido"), { status: 400 });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const clienteId = typeof body.cliente_id === "string" ? body.cliente_id.trim() : "";
  const fechaRaw = typeof body.fecha_servicio === "string" ? body.fecha_servicio.trim() : "";
  const fecha = toCalendarDateStr(fechaRaw) || fechaRaw.slice(0, 10);
  const importe = Number(body.importe);
  const moneda: MonedaLimpieza = body.moneda === "USD" ? "USD" : "GS";
  const tipo: TipoFacturaLimpieza = body.tipo_factura === "credito" ? "credito" : "contado";
  const observacion = typeof body.observacion === "string" ? body.observacion.trim() : "";
  const ivaTipo = typeof body.iva_tipo === "string" ? body.iva_tipo : undefined;

  if (!clienteId) return NextResponse.json(errorResponse("cliente_id es obligatorio"), { status: 400 });
  if (!FECHA_RE.test(fecha)) {
    return NextResponse.json(errorResponse("fecha_servicio inválida (YYYY-MM-DD)"), { status: 400 });
  }
  if (!Number.isFinite(importe) || importe <= 0) {
    return NextResponse.json(errorResponse("El importe debe ser mayor a 0"), { status: 400 });
  }
  if (ivaTipo && !["exenta", "iva_5", "iva_10"].includes(ivaTipo)) {
    return NextResponse.json(errorResponse("iva_tipo inválido: use 'exenta', 'iva_5' o 'iva_10'."), { status: 400 });
  }

  try {
    const sb = await getFacturasServiceClientForEmpresa(auth.empresaId);

    const { data: servicio, error: errGet } = await sb
      .from("servicios_limpieza")
      .select("id, cliente_id, fecha_servicio, importe, moneda, factura_id")
      .eq("id", id)
      .eq("empresa_id", auth.empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!servicio) return NextResponse.json(errorResponse("Servicio no encontrado"), { status: 404 });

    const actual = servicio as {
      cliente_id: string;
      fecha_servicio: string;
      importe: number | string;
      moneda: string;
      factura_id: string | null;
    };

    const cambiaLoFacturable =
      actual.cliente_id !== clienteId ||
      String(actual.fecha_servicio) !== fecha ||
      Number(actual.importe) !== importe ||
      (actual.moneda === "USD" ? "USD" : "GS") !== moneda;

    if (actual.factura_id && cambiaLoFacturable) {
      if (await facturaTieneCobros(sb, auth.empresaId, actual.factura_id)) {
        return NextResponse.json(
          errorResponse(
            "La factura de este servicio ya tiene cobros registrados: no se puede cambiar importe, cliente, moneda ni fecha. " +
              "Corregilo desde Facturas (anulación o nota de crédito). Sí podés editar la observación."
          ),
          { status: 409 }
        );
      }
    }

    if (clienteId !== actual.cliente_id) {
      const { data: cliente, error: errCli } = await sb
        .from("clientes")
        .select("id")
        .eq("id", clienteId)
        .eq("empresa_id", auth.empresaId)
        .maybeSingle();
      if (errCli) throw new Error(errCli.message);
      if (!cliente) return NextResponse.json(errorResponse("Cliente no encontrado"), { status: 404 });
    }

    const descripcion = observacion
      ? `Servicio de limpieza — ${observacion}`
      : "Servicio de limpieza de lote";

    // Primero la factura: si falla, el registro queda como estaba y no hay desfase.
    if (actual.factura_id) {
      await actualizarFacturaSimple(sb, {
        empresaId: auth.empresaId,
        facturaId: actual.factura_id,
        clienteId,
        fecha,
        importe,
        moneda,
        tipo,
        ivaTipo,
        descripcion,
      });
    }

    const { error } = await sb
      .from("servicios_limpieza")
      .update({
        cliente_id: clienteId,
        fecha_servicio: fecha,
        importe,
        moneda,
        observacion: observacion || null,
      })
      .eq("id", id)
      .eq("empresa_id", auth.empresaId);
    if (error) throw new Error(error.message);

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/limpieza PATCH]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/**
 * DELETE /api/limpieza/[id] — anula un servicio cargado por error.
 *
 * Se niega si la factura ya tiene cobros: en ese caso el saldo se movió y la
 * corrección corresponde al circuito de Facturas (anulación / nota de crédito),
 * no a borrar el registro por atrás.
 */
export async function DELETE(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLimpiezaModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  if (!id?.trim()) return NextResponse.json(errorResponse("id requerido"), { status: 400 });

  try {
    const sb = await getFacturasServiceClientForEmpresa(auth.empresaId);

    const { data: servicio, error: errGet } = await sb
      .from("servicios_limpieza")
      .select("id, factura_id")
      .eq("id", id)
      .eq("empresa_id", auth.empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!servicio) return NextResponse.json(errorResponse("Servicio no encontrado"), { status: 404 });

    const facturaId = (servicio as { factura_id: string | null }).factura_id;
    if (facturaId) {
      const borrada = await borrarFacturaSiNoTienePagos(sb, auth.empresaId, facturaId);
      if (!borrada) {
        return NextResponse.json(
          errorResponse(
            "La factura de este servicio ya tiene cobros registrados. Anulala o emití una nota de crédito desde Facturas."
          ),
          { status: 409 }
        );
      }
    }

    const { error } = await sb
      .from("servicios_limpieza")
      .delete()
      .eq("id", id)
      .eq("empresa_id", auth.empresaId);
    if (error) throw new Error(error.message);

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/limpieza DELETE]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
