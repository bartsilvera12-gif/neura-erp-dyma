import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { camposLoteDesdeBody, validarEstadoYTitular } from "@/lib/lotes/lote-campos";
import { errorResponse, successResponse } from "@/lib/api/response";
import { ESTADOS_LOTE, type EstadoLote } from "@/lib/lotes/types";

export const dynamic = "force-dynamic";

/**
 * PATCH /api/lotes/[id] — edita datos del lote y/o cambia su estado.
 *
 * El estado y el titular viajan juntos a propósito: son un solo hecho comercial
 * ("este lote pasa a vendido a nombre de X"), y la base los valida como par.
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

  const cambios = camposLoteDesdeBody(body);
  if ("numero" in cambios && !cambios.numero) {
    return NextResponse.json(errorResponse("El número de lote no puede quedar vacío"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;
    const { data: actual, error: errGet } = await sb
      .from("lotes")
      .select("id, estado, cliente_id")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!actual) return NextResponse.json(errorResponse("Lote no encontrado"), { status: 404 });

    if ("estado" in body || "cliente_id" in body) {
      const estado = ("estado" in body ? body.estado : (actual as { estado: string }).estado) as EstadoLote;
      if (!(ESTADOS_LOTE as string[]).includes(estado)) {
        return NextResponse.json(errorResponse("Estado inválido"), { status: 400 });
      }
      const clienteRaw =
        "cliente_id" in body ? body.cliente_id : (actual as { cliente_id: string | null }).cliente_id;
      let clienteId = typeof clienteRaw === "string" && clienteRaw.trim() ? clienteRaw.trim() : null;
      // Bloqueado y disponible no llevan titular: se limpia en vez de rechazar.
      if (estado === "disponible" || estado === "bloqueado") clienteId = null;

      const chequeo = validarEstadoYTitular(estado, clienteId);
      if (!chequeo.ok) return NextResponse.json(errorResponse(chequeo.error), { status: 400 });

      if (clienteId) {
        const { data: cli } = await sb
          .from("clientes")
          .select("id")
          .eq("id", clienteId)
          .eq("empresa_id", empresaId)
          .maybeSingle();
        if (!cli) return NextResponse.json(errorResponse("Cliente no encontrado"), { status: 404 });
      }

      cambios.estado = estado;
      cambios.cliente_id = clienteId;
    }

    if (Object.keys(cambios).length === 0) {
      return NextResponse.json(errorResponse("Nada para actualizar"), { status: 400 });
    }

    const { data, error } = await sb
      .from("lotes")
      .update(cambios)
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .select()
      .single();
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        return NextResponse.json(errorResponse("Ya existe un lote con ese número en la manzana."), { status: 409 });
      }
      throw new Error(error.message);
    }
    return NextResponse.json(successResponse(data));
  } catch (e) {
    console.error("[api/lotes PATCH]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/** DELETE /api/lotes/[id] — solo si está disponible; el resto tiene historia comercial. */
export async function DELETE(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  try {
    const { sb, empresaId } = auth;
    const { data: lote, error: errGet } = await sb
      .from("lotes")
      .select("id, estado")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!lote) return NextResponse.json(errorResponse("Lote no encontrado"), { status: 404 });

    if ((lote as { estado: string }).estado !== "disponible") {
      return NextResponse.json(
        errorResponse("Solo se puede eliminar un lote disponible. Liberalo primero."),
        { status: 409 }
      );
    }

    const { error } = await sb.from("lotes").delete().eq("id", id).eq("empresa_id", empresaId);
    if (error) throw new Error(error.message);
    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/lotes DELETE]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
