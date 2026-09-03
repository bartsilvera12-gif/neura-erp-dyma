import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { pctDesdeFormulario } from "@/lib/vendedores/calculo-comision";

export const dynamic = "force-dynamic";

/**
 * PATCH /api/lotes/vendedores/[id] — corrige los datos del vendedor.
 *
 * Cambiar `comision_pct` acá NO toca los contratos ya firmados: cada venta
 * congeló su porcentaje al venderse. Este valor es el sugerido para las próximas.
 */
export async function PATCH(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  if (!id?.trim()) return NextResponse.json(errorResponse("id requerido"), { status: 400 });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const patch: Record<string, unknown> = {};

  if (body.codigo !== undefined) {
    const codigo = typeof body.codigo === "string" ? body.codigo.trim() : "";
    if (!codigo) return NextResponse.json(errorResponse("El código no puede quedar vacío"), { status: 400 });
    patch.codigo = codigo;
  }
  if (body.nombre !== undefined) {
    const nombre = typeof body.nombre === "string" ? body.nombre.trim() : "";
    if (!nombre) return NextResponse.json(errorResponse("El nombre no puede quedar vacío"), { status: 400 });
    patch.nombre = nombre;
  }
  if (body.comision_pct !== undefined) {
    const pct = pctDesdeFormulario(body.comision_pct as string | number);
    if (pct == null) {
      return NextResponse.json(errorResponse("La comisión debe estar entre 0 y 100%"), { status: 400 });
    }
    patch.comision_pct = pct;
  }
  for (const campo of ["documento", "telefono", "email", "observacion"] as const) {
    if (body[campo] === undefined) continue;
    const v = body[campo];
    patch[campo] = typeof v === "string" && v.trim() ? v.trim() : null;
  }
  if (body.activo !== undefined) patch.activo = body.activo === true;

  if (Object.keys(patch).length === 0) {
    return NextResponse.json(errorResponse("No hay nada para actualizar"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;
    const { data, error } = await sb
      .from("vendedores")
      .update(patch)
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .select()
      .maybeSingle();

    if (error) {
      if ((error as { code?: string }).code === "23505") {
        return NextResponse.json(errorResponse("Ya hay otro vendedor con ese código."), { status: 409 });
      }
      throw new Error(error.message);
    }
    if (!data) return NextResponse.json(errorResponse("Vendedor no encontrado"), { status: 404 });

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/lotes/vendedores PATCH]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/**
 * DELETE /api/lotes/vendedores/[id] — solo si no tiene ventas.
 *
 * Con ventas a su nombre, borrarlo dejaría comisiones históricas sin dueño. En
 * ese caso corresponde marcarlo inactivo: deja de ofrecerse en ventas nuevas y
 * sus liquidaciones anteriores siguen enteras.
 */
export async function DELETE(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  if (!id?.trim()) return NextResponse.json(errorResponse("id requerido"), { status: 400 });

  try {
    const { sb, empresaId } = auth;

    const { data: ventas, error: errVentas } = await sb
      .from("lote_ventas")
      .select("id")
      .eq("empresa_id", empresaId)
      .eq("vendedor_id", id)
      .limit(1);
    if (errVentas) throw new Error(errVentas.message);
    if ((ventas ?? []).length > 0) {
      return NextResponse.json(
        errorResponse(
          "Este vendedor tiene ventas asociadas. Marcalo como inactivo en vez de borrarlo, así sus comisiones anteriores no pierden el dueño."
        ),
        { status: 409 }
      );
    }

    const { error } = await sb.from("vendedores").delete().eq("id", id).eq("empresa_id", empresaId);
    if (error) throw new Error(error.message);

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/lotes/vendedores DELETE]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
