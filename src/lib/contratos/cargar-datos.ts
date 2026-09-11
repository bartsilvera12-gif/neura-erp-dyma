import "server-only";
import { leerLogoInstancia } from "@/lib/documentos/logo-instancia";
import { FRACCION_UNICA } from "@/lib/lotes/estructura-implicita";
import type { AppSupabaseClient } from "@/lib/supabase/schema";
import type {
  ContratoConfig,
  ContratoTipo,
  CuotaContrato,
  DatosContrato,
  InmuebleContrato,
  PersonaContrato,
} from "./types";

function ymd(v: unknown): string {
  return String(v ?? "").slice(0, 10);
}

/**
 * La fracción que va escrita en el contrato.
 *
 * Manda el dato registral del loteamiento. Si todavía no se cargó, se cae a la
 * subdivisión operativa —que a veces coincide— salvo cuando es la que el
 * sistema crea solo para poder colgar manzanas: esa no existe en ningún título
 * y no puede terminar impresa.
 */
export function fraccionRegistral(
  loteamiento: Record<string, unknown> | null,
  fraccion: Record<string, unknown> | null
): string | null {
  const registral = String(loteamiento?.fraccion ?? "").trim();
  if (registral) return registral;

  const operativa = String(fraccion?.nombre ?? "").trim() || String(fraccion?.codigo ?? "").trim();
  if (!operativa) return null;
  return operativa.toLocaleUpperCase("es") === FRACCION_UNICA ? null : operativa;
}

/** Nombre visible del cliente: razón social si es empresa, si no el contacto. */
function nombreCliente(c: Record<string, unknown> | null): string {
  if (!c) return "";
  const empresa = String(c.empresa ?? "").trim();
  const contacto = String(c.nombre_contacto ?? c.nombre ?? "").trim();
  return empresa || contacto;
}

/**
 * Logo incrustado en el propio documento, no linkeado.
 *
 * Apuntar a /api/brand/logo con una URL absoluta armada desde `request.url`
 * fallaba detrás del proxy: esa URL resuelve al origen interno, que el navegador
 * del usuario no alcanza. Incrustarlo además deja el documento autocontenido,
 * que es lo que corresponde a algo que se imprime, se guarda como PDF o se
 * manda por correo.
 */
export function logoIncrustado(): string | undefined {
  const logo = leerLogoInstancia();
  if (!logo) return undefined;
  const tipo = logo.tipo === "png" ? "image/png" : "image/jpeg";
  return `data:${tipo};base64,${Buffer.from(logo.bytes).toString("base64")}`;
}

/**
 * Reúne todo lo que necesitan los documentos de un contrato: partes, inmueble,
 * condiciones y plan de cuotas.
 *
 * Vive acá y no en la ruta porque lo usan el contrato y los pagarés, y los dos
 * tienen que decir exactamente lo mismo: si divergieran, el cliente firmaría
 * dos papeles que no coinciden.
 *
 * Devuelve `null` si el contrato no existe o no es de esa empresa.
 */
export async function cargarDatosContrato(
  sb: AppSupabaseClient,
  empresaId: string,
  id: string
): Promise<DatosContrato | null> {
  const { data: venta, error: errVenta } = await sb
    .from("lote_ventas")
    .select("*")
    .eq("id", id)
    .eq("empresa_id", empresaId)
    .maybeSingle();
  if (errVenta) throw new Error(errVenta.message);
  if (!venta) return null;
  const v = venta as Record<string, unknown>;

  const [clienteRes, partesRes, loteRes, configRes, tipoRes] = await Promise.all([
    sb.from("clientes").select("*").eq("id", String(v.cliente_id)).maybeSingle(),
    sb
      .from("lote_venta_partes")
      .select("*")
      .eq("venta_id", id)
      .eq("empresa_id", empresaId)
      .order("created_at"),
    sb.from("lotes").select("*").eq("id", String(v.lote_id)).maybeSingle(),
    sb.from("contrato_config").select("*").eq("empresa_id", empresaId).maybeSingle(),
    v.tipo_contrato_id
      ? sb.from("contrato_tipos").select("*").eq("id", String(v.tipo_contrato_id)).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const cli = (clienteRes.data ?? null) as Record<string, unknown> | null;
  const partes = (partesRes.data ?? []) as Record<string, unknown>[];
  const lote = (loteRes.data ?? null) as Record<string, unknown> | null;
  const cfgRow = (configRes.data ?? null) as Record<string, unknown> | null;
  const tipoRow = (tipoRes.data ?? null) as Record<string, unknown> | null;

  // Manzana → fracción → loteamiento: el contrato nombra los tres niveles.
  let manzana: Record<string, unknown> | null = null;
  let fraccion: Record<string, unknown> | null = null;
  let loteamiento: Record<string, unknown> | null = null;
  if (lote?.manzana_id) {
    const m = await sb.from("loteamiento_manzanas").select("*").eq("id", String(lote.manzana_id)).maybeSingle();
    manzana = (m.data ?? null) as Record<string, unknown> | null;
    if (manzana?.fraccion_id) {
      const f = await sb
        .from("loteamiento_fracciones")
        .select("*")
        .eq("id", String(manzana.fraccion_id))
        .maybeSingle();
      fraccion = (f.data ?? null) as Record<string, unknown> | null;
      if (fraccion?.loteamiento_id) {
        const l = await sb
          .from("loteamientos")
          .select("*")
          .eq("id", String(fraccion.loteamiento_id))
          .maybeSingle();
        loteamiento = (l.data ?? null) as Record<string, unknown> | null;
      }
    }
  }

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

  const tipo: ContratoTipo | null = tipoRow
    ? {
        id: String(tipoRow.id),
        slug: String(tipoRow.slug),
        nombre: String(tipoRow.nombre),
        descripcion: (tipoRow.descripcion as string) ?? null,
        requiere_conyuge: tipoRow.requiere_conyuge === true,
        requiere_codeudor: tipoRow.requiere_codeudor === true,
        plantilla: String(tipoRow.plantilla ?? "compraventa_plazos"),
        activo: tipoRow.activo !== false,
      }
    : null;

  const comprador: PersonaContrato = {
    nombre: nombreCliente(cli),
    documento: (cli?.documento as string) || (cli?.ruc as string) || null,
    nacionalidad: (cli?.nacionalidad as string) ?? null,
    estado_civil: (cli?.estado_civil as string) ?? null,
    domicilio: (cli?.direccion as string) ?? null,
  };

  const aPersona = (p: Record<string, unknown>): PersonaContrato => ({
    nombre: String(p.nombre ?? ""),
    documento: (p.documento as string) ?? null,
    nacionalidad: (p.nacionalidad as string) ?? null,
    estado_civil: (p.estado_civil as string) ?? null,
    domicilio: (p.domicilio as string) ?? null,
  });

  const conyugeRow = partes.find((p) => p.rol === "conyuge") ?? null;
  const codeudores = partes.filter((p) => p.rol === "codeudor").map(aPersona);

  const inmueble: InmuebleContrato = {
    loteamiento: (loteamiento?.nombre as string) ?? null,
    // La fracción del contrato es la registral, cargada una vez en el
    // loteamiento. La subdivisión operativa solo se usa como respaldo, y nunca
    // la que el sistema crea solo: imprimir "Fracción ÚNICA" en un contrato
    // sería inventar un dato del título.
    fraccion: fraccionRegistral(loteamiento, fraccion),
    manzana: (manzana?.nombre as string) || (manzana?.codigo as string) || null,
    lote: (lote?.numero as string) ?? null,
    superficie_m2: lote?.superficie_m2 == null ? null : Number(lote.superficie_m2),
    frente_m: lote?.frente_m == null ? null : Number(lote.frente_m),
    fondo_m: lote?.fondo_m == null ? null : Number(lote.fondo_m),
    finca_matriz: (loteamiento?.finca_matriz as string) ?? null,
    matricula: (loteamiento?.matricula as string) ?? null,
    cuenta_corriente_catastral: (loteamiento?.cuenta_corriente_catastral as string) ?? null,
    padron: (loteamiento?.padron as string) ?? null,
    departamento: (loteamiento?.departamento as string) ?? config.departamento,
    distrito: (loteamiento?.distrito as string) ?? null,
    resolucion_municipal: (loteamiento?.resolucion_municipal as string) ?? null,
    run_expediente: (loteamiento?.run_expediente as string) ?? null,
    linda_norte: (lote?.lindero_norte as string) ?? null,
    linda_sur: (lote?.lindero_sur as string) ?? null,
    linda_este: (lote?.lindero_este as string) ?? null,
    linda_oeste: (lote?.lindero_oeste as string) ?? null,
  };

  const entrega = Number(v.entrega_inicial ?? 0);
  const financiado = Number(v.monto_financiado ?? 0);
  const cantidad = Number(v.cantidad_cuotas ?? 0);

  // El plan real, no uno recalculado: el anexo tiene que decir exactamente lo
  // que el comprador va a pagar, incluida la última cuota con su redondeo.
  const { data: cuotasRaw } = await sb
    .from("lote_venta_cuotas")
    .select("numero, vencimiento, capital, interes, total, saldo, estado, pagada_at")
    .eq("venta_id", id)
    .eq("empresa_id", empresaId)
    .order("numero");

  const cuotas: CuotaContrato[] = ((cuotasRaw ?? []) as Record<string, unknown>[]).map((c) => ({
    numero: Number(c.numero ?? 0),
    vencimiento: ymd(c.vencimiento),
    capital: Number(c.capital ?? 0),
    interes: Number(c.interes ?? 0),
    total: Number(c.total ?? 0),
    estado: c.estado === "pagada" || c.estado === "anulada" ? c.estado : "pendiente",
    saldo: c.saldo == null ? undefined : Number(c.saldo),
    pagada_at: (c.pagada_at as string) ?? null,
  }));

  const datos: DatosContrato = {
    cuotas,
    logoUrl: logoIncrustado(),
    config,
    tipo,
    comprador,
    conyuge: conyugeRow ? aPersona(conyugeRow) : null,
    codeudores,
    inmueble,
    operacion: {
      numero_contrato: String(v.numero_contrato ?? ""),
      fecha_venta: ymd(v.fecha_venta),
      moneda: String(v.moneda ?? "GS"),
      // Lo que el comprador termina pagando: entrega + saldo financiado.
      precio_total: entrega + financiado,
      entrega_inicial: entrega,
      monto_financiado: financiado,
      cantidad_cuotas: cantidad,
      cuota: cuotas[0]?.total ?? 0,
      primer_vencimiento: ymd(v.primer_vencimiento),
    },
  };

  return datos;
}
