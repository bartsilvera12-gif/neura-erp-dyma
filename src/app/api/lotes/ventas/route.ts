import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import {
  calcularMoraCuota,
  generarPlanCuotas,
  DIAS_GRACIA,
  MORA_ADMINISTRATIVA_DIARIA,
  MORA_MORATORIA_DIARIA,
  RECARGO_FINANCIACION,
} from "@/lib/financiacion/plan-cuotas";
import { hoyAsuncion } from "@/lib/reportes/calculo";
import type { AppSupabaseClient } from "@/lib/supabase/schema";
import type { EstadoVenta, VentaResumen } from "@/lib/financiacion/types";

export const dynamic = "force-dynamic";

const FECHA_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

/** Siguiente número de contrato de la empresa, con formato CTR-000001. */
async function siguienteNumeroContrato(sb: AppSupabaseClient, empresaId: string): Promise<string> {
  const { data } = await sb
    .from("lote_ventas")
    .select("numero_contrato")
    .eq("empresa_id", empresaId)
    .order("numero_contrato", { ascending: false })
    .limit(1);
  const ultimo = (data ?? [])[0]?.numero_contrato as string | undefined;
  const n = ultimo ? Number(ultimo.replace(/\D/g, "")) : 0;
  return `CTR-${String((Number.isFinite(n) ? n : 0) + 1).padStart(6, "0")}`;
}

/** GET /api/lotes/ventas?estado=&cliente_id= — listado de contratos. */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const url = new URL(request.url);
    const estado = (url.searchParams.get("estado") ?? "").trim();
    const clienteId = (url.searchParams.get("cliente_id") ?? "").trim();

    let q = sb
      .from("lote_ventas")
      .select("*")
      .eq("empresa_id", empresaId)
      .order("fecha_venta", { ascending: false });
    if (estado) q = q.eq("estado", estado);
    if (clienteId) q = q.eq("cliente_id", clienteId);

    const { data, error } = await q;
    if (error) throw new Error(error.message);
    const ventas = (data ?? []) as Record<string, unknown>[];
    if (ventas.length === 0) return NextResponse.json(successResponse({ ventas: [] }));

    const ventaIds = ventas.map((v) => String(v.id));
    const clienteIds = [...new Set(ventas.map((v) => String(v.cliente_id)))];
    const loteIds = [...new Set(ventas.map((v) => String(v.lote_id)))];

    const [cuotasRes, clientesRes, lotesRes] = await Promise.all([
      sb
        .from("lote_venta_cuotas")
        .select("venta_id, total, saldo, estado, vencimiento")
        .eq("empresa_id", empresaId)
        .in("venta_id", ventaIds),
      sb.from("clientes").select("id, empresa, nombre_contacto, nombre").in("id", clienteIds),
      sb.from("lotes").select("id, numero").in("id", loteIds),
    ]);
    if (cuotasRes.error) throw new Error(cuotasRes.error.message);

    const etiquetaCliente: Record<string, string> = {};
    for (const c of (clientesRes.data ?? []) as Record<string, string | null>[]) {
      if (!c.id) continue;
      etiquetaCliente[c.id] = (c.empresa || c.nombre_contacto || c.nombre || "").trim() || "Cliente sin nombre";
    }
    const etiquetaLote: Record<string, string> = {};
    for (const l of (lotesRes.data ?? []) as Record<string, string>[]) {
      etiquetaLote[l.id] = `Lote ${l.numero}`;
    }

    const hoy = hoyAsuncion();
    const cuotasPorVenta = new Map<string, Record<string, unknown>[]>();
    for (const c of (cuotasRes.data ?? []) as Record<string, unknown>[]) {
      const k = String(c.venta_id);
      cuotasPorVenta.set(k, [...(cuotasPorVenta.get(k) ?? []), c]);
    }

    const lista: VentaResumen[] = ventas.map((v) => {
      const cuotas = cuotasPorVenta.get(String(v.id)) ?? [];
      const pendientes = cuotas.filter((c) => c.estado === "pendiente");
      let mora = 0;
      let vencidas = 0;
      for (const c of pendientes) {
        const m = calcularMoraCuota({
          montoCuota: Number(c.saldo ?? 0),
          vencimiento: String(c.vencimiento),
          hoy,
          diasGracia: Number(v.dias_gracia ?? DIAS_GRACIA),
        });
        mora += m.total;
        if (m.dias_atraso > 0) vencidas += 1;
      }
      return {
        id: String(v.id),
        numero_contrato: String(v.numero_contrato),
        fecha_venta: String(v.fecha_venta),
        lote_label: etiquetaLote[String(v.lote_id)] ?? "Lote",
        cliente_id: String(v.cliente_id),
        cliente_label: etiquetaCliente[String(v.cliente_id)] ?? "Cliente sin nombre",
        monto_financiado: Number(v.monto_financiado ?? 0),
        cantidad_cuotas: Number(v.cantidad_cuotas ?? 0),
        moneda: String(v.moneda ?? "GS"),
        estado: v.estado as EstadoVenta,
        cuotas_pagadas: cuotas.filter((c) => c.estado === "pagada").length,
        cuotas_vencidas: vencidas,
        saldo: pendientes.reduce((a, c) => a + Number(c.saldo ?? 0), 0),
        mora_acumulada: mora,
      };
    });

    return NextResponse.json(successResponse({ ventas: lista }));
  } catch (e) {
    console.error("[api/lotes/ventas GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/**
 * POST /api/lotes/ventas — vende un lote y genera su plan de cuotas.
 *
 * Hace tres cosas que van juntas: crea el contrato, genera las cuotas y marca el
 * lote como vendido a nombre del titular. Si algo falla en el medio se deshace lo
 * anterior, para no dejar un lote vendido sin plan o un contrato sin cuotas.
 */
export async function POST(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const loteId = typeof body.lote_id === "string" ? body.lote_id.trim() : "";
  const clienteId = typeof body.cliente_id === "string" ? body.cliente_id.trim() : "";
  const fechaVenta = typeof body.fecha_venta === "string" ? body.fecha_venta.trim() : "";
  const primerVencimiento = typeof body.primer_vencimiento === "string" ? body.primer_vencimiento.trim() : "";
  const cantidadCuotas = Number(body.cantidad_cuotas);
  const precioContado = Number(body.precio_contado);
  const entregaInicial = Number(body.entrega_inicial ?? 0);
  const recargo = body.recargo_pct == null ? RECARGO_FINANCIACION : Number(body.recargo_pct);
  const codeudores = Array.isArray(body.codeudores)
    ? [...new Set(body.codeudores.filter((c): c is string => typeof c === "string" && !!c.trim()))]
    : [];
  const observacion = typeof body.observacion === "string" ? body.observacion.trim() : "";

  if (!loteId) return NextResponse.json(errorResponse("Falta el lote"), { status: 400 });
  if (!clienteId) return NextResponse.json(errorResponse("Falta el cliente titular"), { status: 400 });
  if (!FECHA_RE.test(fechaVenta)) return NextResponse.json(errorResponse("Fecha de venta inválida"), { status: 400 });
  if (!FECHA_RE.test(primerVencimiento)) {
    return NextResponse.json(errorResponse("Fecha del primer vencimiento inválida"), { status: 400 });
  }
  if (codeudores.includes(clienteId)) {
    return NextResponse.json(errorResponse("El titular no puede figurar además como codeudor"), { status: 400 });
  }

  let plan;
  try {
    plan = generarPlanCuotas({
      precioContado,
      entregaInicial,
      cantidadCuotas,
      primerVencimiento,
      recargo,
    });
  } catch (e) {
    // Los errores del motor son de negocio y ya vienen redactados para el usuario.
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Plan inválido"), { status: 400 });
  }

  let ventaId: string | null = null;
  try {
    const { sb, empresaId, usuarioCatalogId } = auth;

    const { data: lote, error: errLote } = await sb
      .from("lotes")
      .select("id, estado, moneda")
      .eq("id", loteId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errLote) throw new Error(errLote.message);
    if (!lote) return NextResponse.json(errorResponse("Lote no encontrado"), { status: 404 });
    if ((lote as { estado: string }).estado === "vendido") {
      return NextResponse.json(errorResponse("El lote ya está vendido."), { status: 409 });
    }
    if ((lote as { estado: string }).estado === "bloqueado") {
      return NextResponse.json(errorResponse("El lote está bloqueado: desbloquealo antes de venderlo."), { status: 409 });
    }

    const { data: cli } = await sb
      .from("clientes")
      .select("id")
      .eq("id", clienteId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (!cli) return NextResponse.json(errorResponse("Cliente no encontrado"), { status: 404 });

    const numeroContrato = await siguienteNumeroContrato(sb, empresaId);
    const moneda = (lote as { moneda?: string }).moneda === "USD" ? "USD" : "GS";

    const { data: venta, error: errVenta } = await sb
      .from("lote_ventas")
      .insert({
        empresa_id: empresaId,
        lote_id: loteId,
        cliente_id: clienteId,
        numero_contrato: numeroContrato,
        fecha_venta: fechaVenta,
        precio_contado: plan.precio_contado,
        entrega_inicial: plan.entrega_inicial,
        capital: plan.capital,
        interes_total: plan.interes_total,
        monto_financiado: plan.monto_financiado,
        cantidad_cuotas: plan.cuotas.length,
        primer_vencimiento: primerVencimiento,
        moneda,
        recargo_pct: recargo,
        dias_gracia: DIAS_GRACIA,
        mora_administrativa_pct: MORA_ADMINISTRATIVA_DIARIA,
        mora_moratoria_pct: MORA_MORATORIA_DIARIA,
        estado: "vigente",
        observacion: observacion || null,
        created_by: usuarioCatalogId,
      })
      .select()
      .single();

    if (errVenta || !venta?.id) {
      if ((errVenta as { code?: string } | null)?.code === "23505") {
        return NextResponse.json(
          errorResponse("Ese lote ya tiene un contrato vigente."),
          { status: 409 }
        );
      }
      throw new Error(errVenta?.message ?? "No se pudo crear el contrato");
    }
    ventaId = String(venta.id);

    const { error: errCuotas } = await sb.from("lote_venta_cuotas").insert(
      plan.cuotas.map((c) => ({
        empresa_id: empresaId,
        venta_id: ventaId,
        numero: c.numero,
        vencimiento: c.vencimiento,
        capital: c.capital,
        interes: c.interes,
        total: c.total,
        saldo: c.total,
        estado: "pendiente",
      }))
    );
    if (errCuotas) throw new Error(`No se pudieron generar las cuotas: ${errCuotas.message}`);

    if (codeudores.length > 0) {
      const { error: errCod } = await sb.from("lote_venta_codeudores").insert(
        codeudores.map((cid) => ({ empresa_id: empresaId, venta_id: ventaId, cliente_id: cid }))
      );
      if (errCod) throw new Error(`No se pudieron registrar los codeudores: ${errCod.message}`);
    }

    const { error: errLoteUpd } = await sb
      .from("lotes")
      .update({ estado: "vendido", cliente_id: clienteId })
      .eq("id", loteId)
      .eq("empresa_id", empresaId);
    if (errLoteUpd) throw new Error(`No se pudo marcar el lote como vendido: ${errLoteUpd.message}`);

    return NextResponse.json(
      successResponse({
        id: ventaId,
        numero_contrato: numeroContrato,
        cuotas: plan.cuotas.length,
        monto_financiado: plan.monto_financiado,
      })
    );
  } catch (e) {
    // Rollback manual: PostgREST no da transacciones entre tablas.
    if (ventaId) {
      await auth.sb.from("lote_venta_cuotas").delete().eq("venta_id", ventaId).eq("empresa_id", auth.empresaId);
      await auth.sb.from("lote_venta_codeudores").delete().eq("venta_id", ventaId).eq("empresa_id", auth.empresaId);
      await auth.sb.from("lote_ventas").delete().eq("id", ventaId).eq("empresa_id", auth.empresaId);
    }
    console.error("[api/lotes/ventas POST]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
