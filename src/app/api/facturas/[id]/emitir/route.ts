import { NextRequest, NextResponse } from "next/server";
import { getFacturasSupabaseFromAuth } from "@/lib/facturacion/facturas-service-client";
import { successResponse, errorResponse } from "@/lib/api/response";
import { cargarFactura, emitirFactura } from "@/lib/facturas/cargar-factura";
import { hoyAsuncion } from "@/lib/reportes/calculo";

export const dynamic = "force-dynamic";

/**
 * GET  /api/facturas/[id]/emitir  → estado de emisión (para pintar el botón).
 * POST /api/facturas/[id]/emitir  → le asigna el número de timbrado.
 *
 * La asignación está separada de la impresión a propósito: imprimir se puede
 * repetir todas las veces que haga falta, emitir no. Un GET que numerara de
 * paso convertiría un refresh del navegador en una factura quemada.
 */
export async function GET(request: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const auth = await getFacturasSupabaseFromAuth(request);
  if (!auth) return NextResponse.json(errorResponse("No autorizado"), { status: 401 });

  try {
    const { id } = await ctx.params;
    const cargada = await cargarFactura(auth.supabase, auth.auth.empresa_id, id);
    if (!cargada) return NextResponse.json(errorResponse("Factura no encontrada"), { status: 404 });

    return NextResponse.json(
      successResponse({
        emitida: cargada.emitida !== null,
        numero: cargada.emitida?.numero_completo ?? null,
        autoimpresor_activo: cargada.config?.activo === true,
        timbrado: cargada.config?.timbrado_numero ?? null,
      })
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Error";
    return NextResponse.json(errorResponse(msg), { status: 500 });
  }
}

export async function POST(request: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const auth = await getFacturasSupabaseFromAuth(request);
  if (!auth) return NextResponse.json(errorResponse("No autorizado"), { status: 401 });

  try {
    const { id } = await ctx.params;
    const cargada = await cargarFactura(auth.supabase, auth.auth.empresa_id, id);
    if (!cargada) return NextResponse.json(errorResponse("Factura no encontrada"), { status: 404 });

    const res = await emitirFactura(auth.supabase, auth.auth.empresa_id, cargada, hoyAsuncion(), {
      id: auth.auth.usuarioCatalogId ?? null,
      email: auth.auth.user?.email ?? null,
    });

    if (!res.ok) return NextResponse.json(errorResponse(res.motivo), { status: 409 });

    return NextResponse.json(
      successResponse({ numero: res.numero, secuencia: res.secuencia, ya_estaba: res.yaEstaba })
    );
  } catch (e) {
    console.error("[api/facturas/[id]/emitir POST]", e instanceof Error ? e.message : e);
    const msg = e instanceof Error ? e.message : "Error";
    return NextResponse.json(errorResponse(msg), { status: 500 });
  }
}
