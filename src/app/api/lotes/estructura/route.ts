import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { fraccionParaManzana } from "@/lib/lotes/estructura-implicita";
import type { EstructuraPayload, NivelEstructura } from "@/lib/lotes/types";

export const dynamic = "force-dynamic";

/** Tabla y columna padre de cada nivel de la jerarquía. */
const NIVEL: Record<NivelEstructura, { tabla: string; padre: string | null }> = {
  loteamiento: { tabla: "loteamientos", padre: null },
  fraccion: { tabla: "loteamiento_fracciones", padre: "loteamiento_id" },
  manzana: { tabla: "loteamiento_manzanas", padre: "fraccion_id" },
};

function parseNivel(v: unknown): NivelEstructura | null {
  return v === "loteamiento" || v === "fraccion" || v === "manzana" ? v : null;
}

/** GET /api/lotes/estructura — árbol completo loteamientos → fracciones → manzanas. */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const [lot, fra, man] = await Promise.all([
      sb.from("loteamientos").select("*").eq("empresa_id", empresaId).order("codigo"),
      sb.from("loteamiento_fracciones").select("*").eq("empresa_id", empresaId).order("orden").order("codigo"),
      sb.from("loteamiento_manzanas").select("*").eq("empresa_id", empresaId).order("orden").order("codigo"),
    ]);
    for (const r of [lot, fra, man]) {
      if (r.error) throw new Error(r.error.message);
    }

    const payload: EstructuraPayload = {
      loteamientos: (lot.data ?? []) as EstructuraPayload["loteamientos"],
      fracciones: (fra.data ?? []) as EstructuraPayload["fracciones"],
      manzanas: (man.data ?? []) as EstructuraPayload["manzanas"],
    };
    return NextResponse.json(successResponse(payload));
  } catch (e) {
    console.error("[api/lotes/estructura GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/** POST /api/lotes/estructura — crea un loteamiento, una fracción o una manzana. */
export async function POST(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const nivel = parseNivel(body.nivel);
  if (!nivel) {
    return NextResponse.json(
      errorResponse("nivel inválido: use 'loteamiento', 'fraccion' o 'manzana'"),
      { status: 400 }
    );
  }

  const codigo = typeof body.codigo === "string" ? body.codigo.trim() : "";
  const nombre = typeof body.nombre === "string" ? body.nombre.trim() : "";
  const padreId = typeof body.padre_id === "string" ? body.padre_id.trim() : "";
  const cfg = NIVEL[nivel];

  if (!codigo) return NextResponse.json(errorResponse("El código es obligatorio"), { status: 400 });
  if (nivel === "loteamiento" && !nombre) {
    return NextResponse.json(errorResponse("El nombre del loteamiento es obligatorio"), { status: 400 });
  }
  if (cfg.padre && !padreId) {
    return NextResponse.json(errorResponse("Falta el elemento padre"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;
    const fila: Record<string, unknown> = { empresa_id: empresaId, codigo };

    // Una manzana puede colgar directo del loteamiento: si viene un loteamiento
    // como padre, la fracción se resuelve sola. Nadie tiene que inventar una
    // fracción para poder cargar la primera manzana.
    if (nivel === "manzana") {
      const { data: esLoteamiento } = await sb
        .from("loteamientos")
        .select("id")
        .eq("id", padreId)
        .eq("empresa_id", empresaId)
        .maybeSingle();
      if (esLoteamiento) {
        const fraccionId = await fraccionParaManzana(sb, empresaId, padreId);
        const { data, error } = await sb
          .from("loteamiento_manzanas")
          .insert({
            empresa_id: empresaId,
            fraccion_id: fraccionId,
            codigo,
            nombre: nombre || null,
            orden: Number.isFinite(Number(body.orden)) ? Number(body.orden) : 0,
          })
          .select()
          .single();
        if (error) {
          if ((error as { code?: string }).code === "23505") {
            return NextResponse.json(
              errorResponse(`Ya existe una manzana con el código "${codigo}".`),
              { status: 409 }
            );
          }
          throw new Error(error.message);
        }
        return NextResponse.json(successResponse(data));
      }
    }

    if (nivel === "loteamiento") {
      fila.nombre = nombre;
      fila.ubicacion = typeof body.ubicacion === "string" ? body.ubicacion.trim() || null : null;
      fila.descripcion = typeof body.descripcion === "string" ? body.descripcion.trim() || null : null;
    } else {
      fila.nombre = nombre || null;
      fila.orden = Number.isFinite(Number(body.orden)) ? Number(body.orden) : 0;
      fila[cfg.padre as string] = padreId;
    }

    const { data, error } = await sb.from(cfg.tabla).insert(fila).select().single();
    if (error) {
      // 23505 = unique_violation: el código ya está usado en ese padre.
      if ((error as { code?: string }).code === "23505") {
        return NextResponse.json(errorResponse(`Ya existe un elemento con el código "${codigo}".`), { status: 409 });
      }
      throw new Error(error.message);
    }
    return NextResponse.json(successResponse(data));
  } catch (e) {
    console.error("[api/lotes/estructura POST]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
