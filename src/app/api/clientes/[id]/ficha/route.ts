import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { logoIncrustado } from "@/lib/contratos/cargar-datos";
import {
  plantillaFichaCliente,
  type ContratoFicha,
  type LimpiezaFicha,
} from "@/lib/contratos/plantilla-ficha-cliente";
import { calcularMoraCuota, DIAS_GRACIA } from "@/lib/financiacion/plan-cuotas";
import { hoyAsuncion } from "@/lib/reportes/calculo";
import { toCalendarDateStr } from "@/lib/fechas/calendario";
import type { ContratoConfig } from "@/lib/contratos/types";

export const dynamic = "force-dynamic";

const ESTADO_VENTA: Record<string, string> = {
  vigente: "Vigente",
  cancelada: "Cancelada",
  anulada: "Anulada",
};

/**
 * GET /api/clientes/[id]/ficha?auto=1
 *
 * Ficha del cliente imprimible: quién es, qué lotes compró, cómo viene pagando
 * y qué servicios de limpieza se le facturaron. Reúne en una hoja lo que hoy hay
 * que ir a buscar a cuatro pantallas distintas.
 *
 * Va bajo el módulo Lotes porque su contenido es el negocio de loteamiento.
 */
export async function GET(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return new NextResponse(auth.message, { status: auth.status });

  const { id } = await ctx.params;
  const auto = new URL(request.url).searchParams.get("auto") === "1";

  try {
    const { sb, empresaId } = auth;
    const hoy = hoyAsuncion();

    const { data: cli, error: errCli } = await sb
      .from("clientes")
      .select("*")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errCli) throw new Error(errCli.message);
    if (!cli) return new NextResponse("Cliente no encontrado", { status: 404 });
    const c = cli as Record<string, unknown>;

    const [cfgRes, ventasRes, limpiezaRes] = await Promise.all([
      sb.from("contrato_config").select("*").eq("empresa_id", empresaId).maybeSingle(),
      sb.from("lote_ventas").select("*").eq("empresa_id", empresaId).eq("cliente_id", id).order("fecha_venta"),
      sb
        .from("servicios_limpieza")
        .select("fecha_servicio, importe, observacion, factura_id")
        .eq("empresa_id", empresaId)
        .eq("cliente_id", id)
        .order("fecha_servicio", { ascending: false }),
    ]);

    const cfgRow = (cfgRes.data ?? null) as Record<string, unknown> | null;
    const config: ContratoConfig = {
      razon_social: String(cfgRow?.razon_social ?? "DYMA SA"),
      ruc: (cfgRow?.ruc as string) ?? null,
      representante_nombre: (cfgRow?.representante_nombre as string) ?? null,
      representante_documento: (cfgRow?.representante_documento as string) ?? null,
      domicilio: (cfgRow?.domicilio as string) ?? null,
      ciudad_firma: (cfgRow?.ciudad_firma as string) ?? null,
      departamento: (cfgRow?.departamento as string) ?? null,
      lugar_pago: (cfgRow?.lugar_pago as string) ?? null,
      dia_pago_desde: Number(cfgRow?.dia_pago_desde ?? 1),
      dia_pago_hasta: Number(cfgRow?.dia_pago_hasta ?? 5),
      ejemplares: Number(cfgRow?.ejemplares ?? 3),
    };

    const ventas = (ventasRes.data ?? []) as Record<string, unknown>[];
    const ventaIds = ventas.map((v) => String(v.id));

    // Cuotas y lotes de todos sus contratos, en dos consultas y no una por fila.
    const [cuotasRes, lotesRes] = await Promise.all([
      ventaIds.length
        ? sb
            .from("lote_venta_cuotas")
            .select("venta_id, saldo, estado, vencimiento")
            .eq("empresa_id", empresaId)
            .in("venta_id", ventaIds)
        : Promise.resolve({ data: [] }),
      ventas.length
        ? sb.from("lotes").select("id, numero").in("id", [...new Set(ventas.map((v) => String(v.lote_id)))])
        : Promise.resolve({ data: [] }),
    ]);

    const etiquetaLote = new Map<string, string>();
    for (const l of (lotesRes.data ?? []) as Record<string, string>[]) {
      etiquetaLote.set(l.id, `Lote ${l.numero}`);
    }

    const cuotasPorVenta = new Map<string, Record<string, unknown>[]>();
    for (const q of (cuotasRes.data ?? []) as Record<string, unknown>[]) {
      const k = String(q.venta_id);
      cuotasPorVenta.set(k, [...(cuotasPorVenta.get(k) ?? []), q]);
    }

    const contratos: ContratoFicha[] = ventas.map((v) => {
      const cuotas = cuotasPorVenta.get(String(v.id)) ?? [];
      const pendientes = cuotas.filter((q) => q.estado === "pendiente");
      let mora = 0;
      for (const q of pendientes) {
        mora += calcularMoraCuota({
          montoCuota: Number(q.saldo ?? 0),
          vencimiento: toCalendarDateStr(String(q.vencimiento ?? "")),
          hoy,
          diasGracia: Number(v.dias_gracia ?? DIAS_GRACIA),
        }).total;
      }
      return {
        numero: String(v.numero_contrato ?? ""),
        fecha: toCalendarDateStr(String(v.fecha_venta ?? "")),
        lote: etiquetaLote.get(String(v.lote_id)) ?? "Lote",
        modalidad: v.modalidad === "contado" ? "Contado" : "Financiada",
        precio_total: Number(v.entrega_inicial ?? 0) + Number(v.monto_financiado ?? 0),
        cuotas: Number(v.cantidad_cuotas ?? 0),
        cuotas_pagadas: cuotas.filter((q) => q.estado === "pagada").length,
        saldo: pendientes.reduce((a, q) => a + Number(q.saldo ?? 0), 0),
        mora,
        estado: ESTADO_VENTA[String(v.estado ?? "")] ?? String(v.estado ?? ""),
      };
    });

    // Estado de la factura de cada servicio de limpieza.
    const limpiezasRaw = (limpiezaRes.data ?? []) as Record<string, unknown>[];
    const facturaIds = [
      ...new Set(limpiezasRaw.map((l) => (l.factura_id ? String(l.factura_id) : "")).filter(Boolean)),
    ];
    const facturas = new Map<string, { numero: string | null; estado: string | null }>();
    if (facturaIds.length > 0) {
      const { data } = await sb
        .from("facturas")
        .select("id, numero_factura, estado")
        .eq("empresa_id", empresaId)
        .in("id", facturaIds);
      for (const f of (data ?? []) as Record<string, unknown>[]) {
        facturas.set(String(f.id), {
          numero: (f.numero_factura as string) ?? null,
          estado: (f.estado as string) ?? null,
        });
      }
    }

    const limpiezas: LimpiezaFicha[] = limpiezasRaw.map((l) => {
      const fac = l.factura_id ? facturas.get(String(l.factura_id)) : undefined;
      return {
        fecha: toCalendarDateStr(String(l.fecha_servicio ?? "")),
        importe: Number(l.importe ?? 0),
        observacion: (l.observacion as string) ?? null,
        factura: fac?.numero ?? null,
        estado: fac?.estado ?? null,
      };
    });

    const html = plantillaFichaCliente(
      {
        config,
        logoUrl: logoIncrustado(),
        emitida: hoy,
        cliente: {
          codigo: (c.codigo_cliente as string) ?? null,
          nombre:
            String(c.empresa ?? "").trim() ||
            String(c.nombre_contacto ?? c.nombre ?? "").trim() ||
            "Cliente sin nombre",
          tipo: c.tipo_cliente === "empresa" ? "Empresa" : "Persona",
          documento: (c.documento as string) ?? null,
          ruc: (c.ruc as string) ?? null,
          nacionalidad: (c.nacionalidad as string) ?? null,
          estado_civil: (c.estado_civil as string) ?? null,
          telefono: (c.telefono as string) ?? null,
          telefono_secundario: (c.telefono_secundario as string) ?? null,
          email: (c.email as string) ?? null,
          direccion: (c.direccion as string) ?? null,
          ciudad: (c.ciudad as string) ?? null,
          estado: c.estado === "inactivo" ? "Inactivo" : "Activo",
          alta: toCalendarDateStr(String(c.created_at ?? "")) || null,
        },
        contratos,
        limpiezas,
      },
      { autoImprimir: auto }
    );

    return new NextResponse(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  } catch (e) {
    console.error("[api/clientes/[id]/ficha GET]", e instanceof Error ? e.message : e);
    return new NextResponse("No se pudo generar la ficha", { status: 500 });
  }
}
