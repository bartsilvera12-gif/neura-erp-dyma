import "server-only";
import type { AppSupabaseClient } from "@/lib/supabase/schema";
import { logoIncrustado } from "@/lib/contratos/cargar-datos";
import {
  calcularTotalesFactura,
  condicionFactura,
  formatearNumeroFiscal,
  lineasImpresas,
  siguienteSecuencia,
  type LineaFactura,
} from "./factura-fiscal";
import type { DatosFactura, EmisorFactura } from "./plantilla-factura";

/**
 * Todo lo que necesita la factura impresa, en un solo lugar.
 *
 * Lo comparten la vista previa y la emisión para que no puedan divergir: si el
 * corte de IVA que se congela al emitir se calculara distinto del que se
 * imprime, el papel diría una cosa y el libro de ventas otra.
 */

export interface TimbradoConfig {
  activo: boolean;
  ruc_emisor: string | null;
  razon_social_emisor: string | null;
  nombre_fantasia: string | null;
  actividad_economica: string | null;
  direccion_matriz: string | null;
  telefono: string | null;
  timbrado_numero: string | null;
  timbrado_inicio_vigencia: string | null;
  timbrado_fin_vigencia: string | null;
  establecimiento_codigo: string | null;
  punto_expedicion_codigo: string | null;
  numero_inicial: number | null;
  numero_final: number | null;
}

export interface FacturaCargada {
  facturaId: string;
  /** Número interno del ERP (FAC-000004), no el fiscal. */
  numeroInterno: string;
  config: TimbradoConfig | null;
  /** Fila de `factura_timbrado` si ya se emitió. */
  emitida: { numero_completo: string; numero_secuencia: number } | null;
  datos: DatosFactura;
}

function fecha(v: unknown): string {
  return String(v ?? "").slice(0, 10);
}

export async function cargarFactura(
  sb: AppSupabaseClient,
  empresaId: string,
  facturaId: string
): Promise<FacturaCargada | null> {
  const { data: fac, error } = await sb
    .from("facturas")
    .select("*")
    .eq("id", facturaId)
    .eq("empresa_id", empresaId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!fac) return null;
  const f = fac as Record<string, unknown>;

  const [itemsRes, cliRes, cfgRes, timRes] = await Promise.all([
    sb.from("factura_items").select("*").eq("empresa_id", empresaId).eq("factura_id", facturaId).order("created_at"),
    sb.from("clientes").select("*").eq("id", String(f.cliente_id)).eq("empresa_id", empresaId).maybeSingle(),
    sb.from("empresa_autoimpresor_config").select("*").eq("empresa_id", empresaId).maybeSingle(),
    sb
      .from("factura_timbrado")
      .select("numero_completo, numero_secuencia")
      .eq("empresa_id", empresaId)
      .eq("factura_id", facturaId)
      .maybeSingle(),
  ]);

  const itemsRaw = (itemsRes.data ?? []) as Record<string, unknown>[];
  const items: LineaFactura[] = itemsRaw.map((it) => ({
    descripcion: String(it.descripcion ?? ""),
    cantidad: Number(it.cantidad ?? 1),
    precio_unitario: Number(it.precio_unitario ?? 0),
    subtotal: Number(it.subtotal ?? 0),
    iva: Number(it.iva ?? 0),
    total: Number(it.total ?? 0),
  }));

  const c = (cliRes.data ?? null) as Record<string, unknown> | null;
  const cfgRow = (cfgRes.data ?? null) as Record<string, unknown> | null;
  const config: TimbradoConfig | null = cfgRow
    ? {
        activo: cfgRow.activo === true,
        ruc_emisor: (cfgRow.ruc_emisor as string) ?? null,
        razon_social_emisor: (cfgRow.razon_social_emisor as string) ?? null,
        nombre_fantasia: (cfgRow.nombre_fantasia as string) ?? null,
        actividad_economica: (cfgRow.actividad_economica as string) ?? null,
        direccion_matriz: (cfgRow.direccion_matriz as string) ?? null,
        telefono: (cfgRow.telefono as string) ?? null,
        timbrado_numero: (cfgRow.timbrado_numero as string) ?? null,
        timbrado_inicio_vigencia: fecha(cfgRow.timbrado_inicio_vigencia) || null,
        timbrado_fin_vigencia: fecha(cfgRow.timbrado_fin_vigencia) || null,
        establecimiento_codigo: (cfgRow.establecimiento_codigo as string) ?? null,
        punto_expedicion_codigo: (cfgRow.punto_expedicion_codigo as string) ?? null,
        numero_inicial: cfgRow.numero_inicial == null ? null : Number(cfgRow.numero_inicial),
        numero_final: cfgRow.numero_final == null ? null : Number(cfgRow.numero_final),
      }
    : null;

  const emitidaRow = (timRes.data ?? null) as { numero_completo?: string; numero_secuencia?: number } | null;
  const emitida = emitidaRow?.numero_completo
    ? { numero_completo: String(emitidaRow.numero_completo), numero_secuencia: Number(emitidaRow.numero_secuencia) }
    : null;

  const emisor: EmisorFactura = {
    razon_social: config?.razon_social_emisor || "CORPORACION DYMA S.A.",
    nombre_fantasia: config?.nombre_fantasia ?? null,
    actividad: config?.actividad_economica ?? null,
    ruc: config?.ruc_emisor ?? null,
    direccion: config?.direccion_matriz ?? null,
    telefono: config?.telefono ?? null,
    timbrado_numero: config?.timbrado_numero ?? null,
    timbrado_inicio: config?.timbrado_inicio_vigencia ?? null,
    timbrado_fin: config?.timbrado_fin_vigencia ?? null,
  };

  return {
    facturaId,
    numeroInterno: String(f.numero_factura ?? ""),
    config,
    emitida,
    datos: {
      emisor,
      logoUrl: logoIncrustado(),
      numero: emitida?.numero_completo ?? null,
      fecha: fecha(f.fecha),
      condicion: condicionFactura(f.tipo as string),
      moneda: String(f.moneda ?? "GS").toUpperCase(),
      cliente: {
        nombre:
          String(c?.empresa ?? "").trim() ||
          String(c?.nombre_contacto ?? c?.nombre ?? "").trim() ||
          "Cliente",
        ruc: (c?.ruc as string) ?? (c?.documento as string) ?? null,
        telefono: (c?.telefono as string) ?? null,
        direccion: [(c?.direccion as string) ?? "", (c?.ciudad as string) ?? ""].filter(Boolean).join(" - ") || null,
        observacion: String(f.numero_factura ?? "") || null,
      },
      lineas: lineasImpresas(items),
      totales: calcularTotalesFactura(items),
    },
  };
}

export type ResultadoEmision =
  | { ok: true; numero: string; secuencia: number; yaEstaba: boolean }
  | { ok: false; motivo: string };

/**
 * Le asigna a la factura su número de timbrado.
 *
 * Idempotente: si ya se emitió, devuelve el número que tiene. Nunca reemite,
 * porque un número entregado al cliente no se puede volver a usar.
 *
 * El correlativo se deriva del máximo ya emitido y no de un contador aparte: si
 * dos personas emiten al mismo tiempo, las dos calculan el mismo número, el
 * índice único rechaza a una y esa vuelve a intentar con el siguiente. Un
 * contador suelto, en cambio, se desincroniza en silencio.
 */
export async function emitirFactura(
  sb: AppSupabaseClient,
  empresaId: string,
  cargada: FacturaCargada,
  hoy: string,
  usuario: { id?: string | null; email?: string | null }
): Promise<ResultadoEmision> {
  if (cargada.emitida) {
    return { ok: true, numero: cargada.emitida.numero_completo, secuencia: cargada.emitida.numero_secuencia, yaEstaba: true };
  }

  const cfg = cargada.config;
  if (!cfg || !cfg.activo) {
    return { ok: false, motivo: "El autoimpresor no está configurado o está desactivado para esta empresa." };
  }
  if (!cfg.timbrado_numero || !cfg.establecimiento_codigo || !cfg.punto_expedicion_codigo) {
    return { ok: false, motivo: "Falta cargar el timbrado, el establecimiento o el punto de expedición." };
  }
  if (cfg.timbrado_inicio_vigencia && hoy < cfg.timbrado_inicio_vigencia) {
    return { ok: false, motivo: `El timbrado ${cfg.timbrado_numero} recién entra en vigencia el ${cfg.timbrado_inicio_vigencia}.` };
  }
  if (cfg.timbrado_fin_vigencia && hoy > cfg.timbrado_fin_vigencia) {
    return { ok: false, motivo: `El timbrado ${cfg.timbrado_numero} venció el ${cfg.timbrado_fin_vigencia}. Hay que cargar el nuevo antes de facturar.` };
  }
  if (cargada.datos.lineas.length === 0) {
    return { ok: false, motivo: "La factura no tiene ítems: no hay nada que facturar." };
  }

  const t = cargada.datos.totales;

  // Cinco vueltas alcanzan de sobra: la colisión solo ocurre si dos personas
  // aprietan emitir en el mismo instante.
  for (let intento = 0; intento < 5; intento++) {
    const { data: ultimaRows, error: errMax } = await sb
      .from("factura_timbrado")
      .select("numero_secuencia")
      .eq("empresa_id", empresaId)
      .eq("timbrado_numero", cfg.timbrado_numero)
      .eq("establecimiento_codigo", cfg.establecimiento_codigo)
      .eq("punto_expedicion_codigo", cfg.punto_expedicion_codigo)
      .order("numero_secuencia", { ascending: false })
      .limit(1);
    if (errMax) throw new Error(errMax.message);

    const ultima = (ultimaRows ?? [])[0] as { numero_secuencia?: number } | undefined;
    const secuencia = siguienteSecuencia(ultima?.numero_secuencia ?? null, cfg.numero_inicial, cfg.numero_final);
    if (secuencia === null) {
      return { ok: false, motivo: `Se agotó el rango habilitado del timbrado ${cfg.timbrado_numero}. Hay que pedir uno nuevo.` };
    }

    const numero = formatearNumeroFiscal(cfg.establecimiento_codigo, cfg.punto_expedicion_codigo, secuencia);
    const { error: errIns } = await sb.from("factura_timbrado").insert({
      empresa_id: empresaId,
      factura_id: cargada.facturaId,
      numero_secuencia: secuencia,
      numero_completo: numero,
      establecimiento_codigo: cfg.establecimiento_codigo,
      punto_expedicion_codigo: cfg.punto_expedicion_codigo,
      timbrado_numero: cfg.timbrado_numero,
      timbrado_inicio_vigencia: cfg.timbrado_inicio_vigencia,
      timbrado_fin_vigencia: cfg.timbrado_fin_vigencia,
      condicion: cargada.datos.condicion,
      gravado_10: t.gravado_10,
      iva_10: t.iva_10,
      gravado_5: t.gravado_5,
      iva_5: t.iva_5,
      exentas: t.exentas,
      total: t.total,
      emitida_por: usuario.id ?? null,
      emitida_por_email: usuario.email ?? null,
    });

    if (!errIns) return { ok: true, numero, secuencia, yaEstaba: false };

    // 23505: alguien se llevó ese número o esta factura ya fue emitida en paralelo.
    if (errIns.code !== "23505") throw new Error(errIns.message);

    const { data: yaRow } = await sb
      .from("factura_timbrado")
      .select("numero_completo, numero_secuencia")
      .eq("empresa_id", empresaId)
      .eq("factura_id", cargada.facturaId)
      .maybeSingle();
    const ya = yaRow as { numero_completo?: string; numero_secuencia?: number } | null;
    if (ya?.numero_completo) {
      return { ok: true, numero: String(ya.numero_completo), secuencia: Number(ya.numero_secuencia), yaEstaba: true };
    }
    // Era colisión de correlativo: se reintenta con el siguiente.
  }

  return { ok: false, motivo: "No se pudo asignar el número: hay otra emisión en curso. Probá de nuevo." };
}
