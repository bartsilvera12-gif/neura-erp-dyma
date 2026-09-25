import { NextRequest, NextResponse } from "next/server";
import { getTenantSupabaseFromAuth } from "@/lib/supabase/tenant-api";
import { successResponse, errorResponse } from "@/lib/api/response";
import { API_ERRORS } from "@/lib/api/errors";

export const dynamic = "force-dynamic";

/**
 * GET /api/productos/precios — lista para la Consulta de precios.
 *
 * Devuelve SOLO lo que un vendedor necesita para atender a un cliente: nombre,
 * SKU, precio de venta, unidad y las presentaciones (variantes) con su precio.
 * NO devuelve costo, proveedor, stock, valuación ni margen. Es una ruta separada
 * a propósito, para no arrastrar los campos sensibles de /api/productos.
 */
function toNumber(v: unknown): number | null {
  if (v == null) return null;
  const n = typeof v === "string" ? Number(v) : (v as number);
  return Number.isFinite(n) ? n : null;
}

export async function GET(request: NextRequest) {
  try {
    const ctx = await getTenantSupabaseFromAuth(request);
    if (!ctx) return NextResponse.json(errorResponse(API_ERRORS.UNAUTHORIZED), { status: 401 });
    const empresaId = ctx.auth.empresa_id;
    const sb = ctx.supabase;

    const { data: prodData, error } = await sb
      .from("productos")
      .select("id, nombre, sku, precio_venta, unidad_medida, imagen_url, descripcion")
      .eq("empresa_id", empresaId)
      .eq("activo", true)
      .eq("es_vendible", true)
      .order("nombre");
    if (error) throw new Error(error.message);

    const productos = (prodData ?? []) as Record<string, unknown>[];
    const ids = productos.map((p) => String(p.id));

    // Presentaciones (variantes) con su precio; solo nombre + precio, nada sensible.
    const presentacionesPorProducto = new Map<
      string,
      { nombre: string; precio_venta: number | null; es_default: boolean }[]
    >();
    if (ids.length > 0) {
      const { data: presData, error: errPres } = await sb
        .from("producto_presentaciones")
        .select("producto_id, nombre, precio_venta, es_default, activo")
        .eq("empresa_id", empresaId)
        .in("producto_id", ids)
        .eq("activo", true);
      if (errPres) throw new Error(errPres.message);
      for (const r of (presData ?? []) as Record<string, unknown>[]) {
        const pid = String(r.producto_id);
        const list = presentacionesPorProducto.get(pid) ?? [];
        list.push({
          nombre: String(r.nombre ?? ""),
          precio_venta: toNumber(r.precio_venta),
          es_default: r.es_default === true,
        });
        presentacionesPorProducto.set(pid, list);
      }
    }

    const rows = productos.map((p) => ({
      id: String(p.id),
      nombre: String(p.nombre ?? ""),
      sku: (p.sku as string) ?? null,
      precio_venta: toNumber(p.precio_venta),
      unidad_medida: (p.unidad_medida as string) ?? null,
      imagen_url: (p.imagen_url as string) ?? null,
      descripcion: (p.descripcion as string) ?? null,
      presentaciones: presentacionesPorProducto.get(String(p.id)) ?? [],
    }));

    return NextResponse.json(successResponse({ productos: rows }));
  } catch (err) {
    console.error("[/api/productos/precios GET]", err instanceof Error ? err.message : err);
    return NextResponse.json(errorResponse("No se pudieron cargar los precios."), { status: 500 });
  }
}
