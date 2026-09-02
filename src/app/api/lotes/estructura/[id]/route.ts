import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import type { NivelEstructura } from "@/lib/lotes/types";

export const dynamic = "force-dynamic";

const TABLA: Record<NivelEstructura, string> = {
  loteamiento: "loteamientos",
  fraccion: "loteamiento_fracciones",
  manzana: "loteamiento_manzanas",
};

function parseNivel(v: unknown): NivelEstructura | null {
  return v === "loteamiento" || v === "fraccion" || v === "manzana" ? v : null;
}

/** PATCH /api/lotes/estructura/[id]?nivel= — renombra o reordena un nivel. */
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

  const nivel = parseNivel(body.nivel);
  if (!nivel) return NextResponse.json(errorResponse("nivel inválido"), { status: 400 });

  const cambios: Record<string, unknown> = {};
  if (typeof body.codigo === "string" && body.codigo.trim()) cambios.codigo = body.codigo.trim();
  if (typeof body.nombre === "string") cambios.nombre = body.nombre.trim() || null;
  if (typeof body.ubicacion === "string") cambios.ubicacion = body.ubicacion.trim() || null;
  if (typeof body.descripcion === "string") cambios.descripcion = body.descripcion.trim() || null;
  if (typeof body.activo === "boolean") cambios.activo = body.activo;
  if (Number.isFinite(Number(body.orden))) cambios.orden = Number(body.orden);

  if (Object.keys(cambios).length === 0) {
    return NextResponse.json(errorResponse("Nada para actualizar"), { status: 400 });
  }

  try {
    const { data, error } = await auth.sb
      .from(TABLA[nivel])
      .update(cambios)
      .eq("id", id)
      .eq("empresa_id", auth.empresaId)
      .select()
      .single();
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        return NextResponse.json(errorResponse("Ya existe un elemento con ese código."), { status: 409 });
      }
      throw new Error(error.message);
    }
    if (!data) return NextResponse.json(errorResponse("No encontrado"), { status: 404 });
    return NextResponse.json(successResponse(data));
  } catch (e) {
    console.error("[api/lotes/estructura PATCH]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/**
 * DELETE /api/lotes/estructura/[id]?nivel= — elimina un nivel.
 * Se niega si abajo hay lotes que no están disponibles: borrar en cascada un
 * lote reservado o vendido se llevaría puesta información comercial.
 */
export async function DELETE(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  const nivel = parseNivel(new URL(request.url).searchParams.get("nivel"));
  if (!nivel) return NextResponse.json(errorResponse("nivel inválido"), { status: 400 });

  try {
    const { sb, empresaId } = auth;

    // Manzanas alcanzadas por el borrado, para revisar sus lotes.
    let manzanaIds: string[] = [];
    if (nivel === "manzana") {
      manzanaIds = [id];
    } else {
      let fraccionIds: string[] = [];
      if (nivel === "fraccion") {
        fraccionIds = [id];
      } else {
        const { data } = await sb
          .from("loteamiento_fracciones")
          .select("id")
          .eq("empresa_id", empresaId)
          .eq("loteamiento_id", id);
        fraccionIds = ((data ?? []) as { id: string }[]).map((f) => f.id);
      }
      if (fraccionIds.length > 0) {
        const { data } = await sb
          .from("loteamiento_manzanas")
          .select("id")
          .eq("empresa_id", empresaId)
          .in("fraccion_id", fraccionIds);
        manzanaIds = ((data ?? []) as { id: string }[]).map((m) => m.id);
      }
    }

    if (manzanaIds.length > 0) {
      const { data: ocupados, error: errOc } = await sb
        .from("lotes")
        .select("id")
        .eq("empresa_id", empresaId)
        .in("manzana_id", manzanaIds)
        .neq("estado", "disponible")
        .limit(1);
      if (errOc) throw new Error(errOc.message);
      if ((ocupados ?? []).length > 0) {
        return NextResponse.json(
          errorResponse(
            "No se puede eliminar: hay lotes reservados, vendidos o bloqueados debajo. Liberalos primero."
          ),
          { status: 409 }
        );
      }
    }

    const { error } = await sb.from(TABLA[nivel]).delete().eq("id", id).eq("empresa_id", empresaId);
    if (error) throw new Error(error.message);
    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/lotes/estructura DELETE]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
