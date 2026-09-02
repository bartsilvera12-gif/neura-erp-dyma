/**
 * Orquestador server-side de emisión de un Documento Electrónico (DE) SIFEN.
 *
 * Ejecuta el pipeline completo borrador → XML → firmar → (enviar → consulta-lote)
 * reutilizando los cores puros (borrador/xml/firmar) y los handlers de enviar/consulta
 * (invocados server-side con un NextRequest sintético, sin HTTP real).
 *
 * NUNCA lanza: cualquier fallo (SET caído, rechazo, timeout) se captura y se devuelve
 * como `EmitirDeResult` con el mejor estado conocido; el DE queda reintentable desde el
 * panel de la factura. Pensado para invocarse al confirmar una venta sin trabar la venta.
 */
import { NextRequest, type NextResponse } from "next/server";
import type { UsuarioConEmpresa } from "@/lib/middleware/auth";
import type { AppSupabaseClient } from "@/lib/supabase/schema";
import type { EstadoSifen, FacturaElectronicaDTO } from "@/lib/sifen/types";
import { crearBorradorDeCore } from "./crear-borrador-de-core";
import { generarXmlDeCore } from "./generar-xml-de-core";
import { firmarDeCore } from "./firmar-de-core";
import { handleSifenEnviarPost } from "@/lib/sifen/handle-sifen-enviar-post";
import { handleSifenConsultaLotePost } from "@/lib/sifen/handle-sifen-consulta-lote-post";

export interface EmitirDeResult {
  facturaElectronicaId: string | null;
  estadoFinal: EstadoSifen | string;
  cdc: string | null;
  protocoloLote: string | null;
  aprobado: boolean;
  /** true si el DE no llegó a aprobado y puede reintentarse desde el panel de la factura. */
  reintentable: boolean;
  /** true si ya hay XML firmado → KuDE imprimible (aunque el SET aún no haya aprobado). */
  kudeDisponible: boolean;
  error: string | null;
}

const ESTADOS_FINALIZADOS = new Set<string>(["aprobado", "cancelado"]);

/** Invoca un handler SIFEN (enviar / consulta-lote) server-side y parsea su JSON. */
async function llamarHandler(
  handler: (
    request: NextRequest,
    params: Promise<{ id: string }>,
    auth: UsuarioConEmpresa,
    supabase: AppSupabaseClient,
    options: { soloAmbienteTest: boolean }
  ) => Promise<NextResponse>,
  auth: UsuarioConEmpresa,
  supabase: AppSupabaseClient,
  facturaId: string
): Promise<{ success: boolean; data?: { factura_electronica?: FacturaElectronicaDTO }; error?: string }> {
  const req = new NextRequest("http://localhost/api/internal/sifen");
  const res = await handler(req, Promise.resolve({ id: facturaId }), auth, supabase, {
    soloAmbienteTest: false,
  });
  try {
    const json = (await res.json()) as {
      success?: boolean;
      data?: { factura_electronica?: FacturaElectronicaDTO };
      error?: string;
    };
    return { success: !!json.success, data: json.data, error: json.error };
  } catch {
    return { success: false, error: `Respuesta no parseable (HTTP ${res.status})` };
  }
}

function resultadoDesde(
  fe: FacturaElectronicaDTO | null,
  error: string | null
): EmitirDeResult {
  const estado = fe?.estado_sifen ?? "borrador";
  const aprobado = estado === "aprobado";
  const reintentable = !aprobado && estado !== "cancelado";
  const kudeDisponible =
    Boolean(fe?.xml_firmado_path?.trim()) ||
    estado === "firmado" ||
    estado === "enviado" ||
    estado === "aprobado";
  return {
    facturaElectronicaId: fe?.id ?? null,
    estadoFinal: estado,
    cdc: fe?.cdc ?? null,
    protocoloLote: fe?.sifen_d_prot_cons_lote ?? null,
    aprobado,
    reintentable,
    kudeDisponible,
    error,
  };
}

export async function emitirDeFacturaServerSide(args: {
  auth: UsuarioConEmpresa;
  supabase: AppSupabaseClient;
  facturaId: string;
  sync: boolean;
}): Promise<EmitirDeResult> {
  const { auth, supabase, facturaId, sync } = args;
  const empresaId = auth.empresa_id;
  let fe: FacturaElectronicaDTO | null = null;

  try {
    // 1) Borrador (idempotente)
    const borrador = await crearBorradorDeCore(supabase, empresaId, facturaId);
    if (!borrador.ok) return resultadoDesde(null, borrador.message);
    fe = borrador.data;
    let estado = String(fe.estado_sifen);

    if (ESTADOS_FINALIZADOS.has(estado)) return resultadoDesde(fe, null);

    // 2) XML (borrador o rechazado → generado)
    if (estado === "borrador" || estado === "rechazado") {
      const xml = await generarXmlDeCore(supabase, empresaId, facturaId);
      if (!xml.ok) return resultadoDesde(fe, xml.message);
      fe = xml.data.factura_electronica;
      estado = String(fe.estado_sifen);
    }

    // 3) Firmar (generado → firmado)
    if (estado === "generado") {
      const firma = await firmarDeCore(supabase, empresaId, facturaId);
      if (!firma.ok) return resultadoDesde(fe, firma.message);
      fe = firma.data.factura_electronica;
      estado = String(fe.estado_sifen);
    }

    if (!sync) return resultadoDesde(fe, null);

    // 4) Enviar al SET (firmado → enviado | error_envio)
    if (estado === "firmado") {
      const envio = await llamarHandler(handleSifenEnviarPost, auth, supabase, facturaId);
      if (envio.data?.factura_electronica) fe = envio.data.factura_electronica;
      if (!envio.success) return resultadoDesde(fe, envio.error ?? "El SET no aceptó el envío del lote.");
      estado = String(fe?.estado_sifen ?? "");
    }

    // 5) Consulta-lote best-effort (enviado → aprobado | rechazado | sigue enviado)
    if (estado === "enviado") {
      const consulta = await llamarHandler(handleSifenConsultaLotePost, auth, supabase, facturaId);
      if (consulta.data?.factura_electronica) fe = consulta.data.factura_electronica;
      // No es error si sigue "enviado": el SET puede tardar; queda reintentable.
    }

    return resultadoDesde(fe, null);
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Error inesperado al emitir el documento electrónico.";
    console.error("[emitirDeFacturaServerSide]", msg);
    return resultadoDesde(fe, msg);
  }
}
