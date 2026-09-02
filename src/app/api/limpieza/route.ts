import { NextResponse } from "next/server";
import { requireLimpiezaModuleAccess } from "@/lib/limpieza/limpieza-auth";
import { emitirFacturaSimple } from "@/lib/facturacion/emitir-factura-simple";
import { getFacturasServiceClientForEmpresa } from "@/lib/facturacion/facturas-service-client";
import { errorResponse, successResponse } from "@/lib/api/response";
import { emitEvent, EVENT_TYPES } from "@/lib/integrations/events";
import { toCalendarDateStr } from "@/lib/fechas/calendario";
import type {
  LimpiezaPayload,
  MonedaLimpieza,
  ResumenLimpieza,
  ServicioLimpieza,
  TipoFacturaLimpieza,
} from "@/lib/limpieza/types";

export const dynamic = "force-dynamic";

const FECHA_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

type FilaServicio = {
  id: string;
  cliente_id: string;
  fecha_servicio: string;
  importe: number | string;
  moneda: string;
  observacion: string | null;
  factura_id: string | null;
  creado_por_email: string | null;
  created_at: string;
};

/**
 * GET /api/limpieza?desde=&hasta=&cliente_id=
 * Servicios de limpieza prestados, con el estado de la factura de cada uno.
 */
export async function GET(request: Request) {
  const auth = await requireLimpiezaModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const sb = await getFacturasServiceClientForEmpresa(auth.empresaId);
    const url = new URL(request.url);
    const desde = url.searchParams.get("desde") ?? "";
    const hasta = url.searchParams.get("hasta") ?? "";
    const clienteId = url.searchParams.get("cliente_id") ?? "";

    let q = sb
      .from("servicios_limpieza")
      .select("*")
      .eq("empresa_id", auth.empresaId)
      .order("fecha_servicio", { ascending: false })
      .order("created_at", { ascending: false });

    if (FECHA_RE.test(desde)) q = q.gte("fecha_servicio", desde);
    if (FECHA_RE.test(hasta)) q = q.lte("fecha_servicio", hasta);
    if (clienteId.trim()) q = q.eq("cliente_id", clienteId.trim());

    const { data, error } = await q;
    if (error) throw new Error(error.message);
    const filas = (data ?? []) as FilaServicio[];

    // Etiquetas de cliente y estado de factura en dos consultas, no una por fila.
    const clienteIds = [...new Set(filas.map((f) => f.cliente_id).filter(Boolean))];
    const facturaIds = [...new Set(filas.map((f) => f.factura_id).filter((v): v is string => !!v))];

    const etiquetas: Record<string, string> = {};
    if (clienteIds.length > 0) {
      const { data: cls } = await sb
        .from("clientes")
        .select("id, empresa, nombre_contacto, nombre")
        .in("id", clienteIds);
      for (const c of (cls ?? []) as Record<string, string | null>[]) {
        const id = c.id ?? "";
        if (!id) continue;
        etiquetas[id] = (c.empresa || c.nombre_contacto || c.nombre || "").trim() || "Cliente sin nombre";
      }
    }

    const facturas: Record<string, { numero: string | null; estado: string | null; saldo: number | null }> = {};
    if (facturaIds.length > 0) {
      const { data: facs } = await sb
        .from("facturas")
        .select("id, numero_factura, estado, saldo")
        .eq("empresa_id", auth.empresaId)
        .in("id", facturaIds);
      for (const f of (facs ?? []) as Record<string, unknown>[]) {
        const id = String(f.id ?? "");
        if (!id) continue;
        facturas[id] = {
          numero: (f.numero_factura as string) ?? null,
          estado: (f.estado as string) ?? null,
          saldo: f.saldo == null ? null : Number(f.saldo),
        };
      }
    }

    const servicios: ServicioLimpieza[] = filas.map((f) => {
      const fac = f.factura_id ? facturas[f.factura_id] : undefined;
      return {
        id: f.id,
        cliente_id: f.cliente_id,
        cliente_label: etiquetas[f.cliente_id] ?? "Cliente sin nombre",
        fecha_servicio: f.fecha_servicio,
        importe: Number(f.importe),
        moneda: f.moneda === "USD" ? "USD" : "GS",
        observacion: f.observacion,
        factura_id: f.factura_id,
        factura_numero: fac?.numero ?? null,
        factura_estado: fac?.estado ?? null,
        factura_saldo: fac?.saldo ?? null,
        creado_por_email: f.creado_por_email,
        created_at: f.created_at,
      };
    });

    const resumen: ResumenLimpieza = {
      servicios: servicios.length,
      clientes: new Set(servicios.map((s) => s.cliente_id)).size,
      total_gs: servicios.filter((s) => s.moneda === "GS").reduce((a, s) => a + s.importe, 0),
      total_usd: servicios.filter((s) => s.moneda === "USD").reduce((a, s) => a + s.importe, 0),
      // "Pendiente" mira el saldo vivo de la factura, no el importe original.
      pendiente_gs: servicios
        .filter((s) => s.moneda === "GS" && s.factura_estado === "Pendiente")
        .reduce((a, s) => a + (s.factura_saldo ?? 0), 0),
      pendiente_usd: servicios
        .filter((s) => s.moneda === "USD" && s.factura_estado === "Pendiente")
        .reduce((a, s) => a + (s.factura_saldo ?? 0), 0),
    };

    return NextResponse.json(successResponse({ resumen, servicios } satisfies LimpiezaPayload));
  } catch (e) {
    console.error("[api/limpieza GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/**
 * POST /api/limpieza — registra un servicio prestado y emite su factura.
 * Alta siempre manual: el usuario lo carga el día que el servicio se hizo.
 */
export async function POST(request: Request) {
  const auth = await requireLimpiezaModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

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

    const { data: cliente, error: errCli } = await sb
      .from("clientes")
      .select("id")
      .eq("id", clienteId)
      .eq("empresa_id", auth.empresaId)
      .maybeSingle();
    if (errCli) throw new Error(errCli.message);
    if (!cliente) {
      return NextResponse.json(errorResponse("Cliente no encontrado"), { status: 404 });
    }

    const descripcion = observacion
      ? `Servicio de limpieza — ${observacion}`
      : "Servicio de limpieza de lote";

    const factura = await emitirFacturaSimple(sb, {
      empresaId: auth.empresaId,
      clienteId,
      fecha,
      importe,
      moneda,
      tipo,
      ivaTipo,
      descripcion,
    });

    const { data, error } = await sb
      .from("servicios_limpieza")
      .insert({
        empresa_id: auth.empresaId,
        cliente_id: clienteId,
        fecha_servicio: fecha,
        importe,
        moneda,
        observacion: observacion || null,
        factura_id: factura.id,
        creado_por: auth.usuarioCatalogId,
        creado_por_email: auth.email,
      })
      .select()
      .single();

    if (error || !data?.id) {
      // El servicio no quedó registrado: se deshace la factura para no dejarla huérfana.
      await sb.from("factura_items").delete().eq("factura_id", factura.id).eq("empresa_id", auth.empresaId);
      await sb.from("facturas").delete().eq("id", factura.id).eq("empresa_id", auth.empresaId);
      throw new Error(error?.message ?? "No se pudo registrar el servicio");
    }

    await emitEvent(EVENT_TYPES.factura_creada, {
      factura_id: factura.id,
      cliente_id: clienteId,
      monto: importe,
    });

    return NextResponse.json(
      successResponse({
        id: String(data.id),
        factura_id: factura.id,
        factura_numero: factura.numero_factura,
        fecha_vencimiento: factura.fecha_vencimiento,
      })
    );
  } catch (e) {
    console.error("[api/limpieza POST]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
