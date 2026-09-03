import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";

export const dynamic = "force-dynamic";

const ESTADOS = ["borrador", "descartada"] as const;

/**
 * PATCH /api/lotes/simulaciones/[id] — descartar, reactivar o renombrar.
 *
 * A `aprobada` no se llega por acá: una simulación queda aprobada cuando se
 * genera su contrato, y lo hace la ruta de venta. Marcarla aprobada a mano
 * dejaría un plan "aprobado" sin contrato detrás.
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
  if (body.estado !== undefined) {
    const e = String(body.estado);
    if (!(ESTADOS as readonly string[]).includes(e)) {
      return NextResponse.json(
        errorResponse("Estado inválido: una simulación se aprueba generando su contrato."),
        { status: 400 }
      );
    }
    patch.estado = e;
  }
  if (body.nombre !== undefined) {
    patch.nombre = typeof body.nombre === "string" && body.nombre.trim() ? body.nombre.trim() : null;
  }
  if (body.observacion !== undefined) {
    patch.observacion =
      typeof body.observacion === "string" && body.observacion.trim() ? body.observacion.trim() : null;
  }
  if (Object.keys(patch).length === 0) {
    return NextResponse.json(errorResponse("No hay nada para actualizar"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;

    const { data: actual, error: errGet } = await sb
      .from("plan_simulaciones")
      .select("id, estado")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!actual) return NextResponse.json(errorResponse("Simulación no encontrada"), { status: 404 });

    if ((actual as { estado: string }).estado === "aprobada" && patch.estado) {
      return NextResponse.json(
        errorResponse("Esta simulación ya generó un contrato: su estado no se cambia."),
        { status: 409 }
      );
    }

    const { error } = await sb
      .from("plan_simulaciones")
      .update(patch)
      .eq("id", id)
      .eq("empresa_id", empresaId);
    if (error) throw new Error(error.message);

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/lotes/simulaciones PATCH]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/** DELETE /api/lotes/simulaciones/[id] — borra una propuesta que no llegó a contrato. */
export async function DELETE(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  if (!id?.trim()) return NextResponse.json(errorResponse("id requerido"), { status: 400 });

  try {
    const { sb, empresaId } = auth;

    const { data: actual, error: errGet } = await sb
      .from("plan_simulaciones")
      .select("id, estado")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!actual) return NextResponse.json(errorResponse("Simulación no encontrada"), { status: 404 });

    if ((actual as { estado: string }).estado === "aprobada") {
      return NextResponse.json(
        errorResponse(
          "Esta simulación generó un contrato: es el respaldo de lo que se le prometió al cliente y no se borra."
        ),
        { status: 409 }
      );
    }

    const { error } = await sb.from("plan_simulaciones").delete().eq("id", id).eq("empresa_id", empresaId);
    if (error) throw new Error(error.message);

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/lotes/simulaciones DELETE]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
