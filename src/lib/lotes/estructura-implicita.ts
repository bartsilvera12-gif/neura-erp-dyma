import "server-only";
import type { AppSupabaseClient } from "@/lib/supabase/schema";

/**
 * La fracción, sin que nadie tenga que saber que existe.
 *
 * El modelo es loteamiento → fracción → manzana → lote, pero DYMA no fracciona:
 * piensa en "Manzana X, lote 1". Obligarlos a inventar una fracción para poder
 * cargar la primera manzana los dejaba trabados, con el loteamiento creado y
 * ningún lugar donde poner los lotes.
 *
 * Acá se resuelve sola: si el loteamiento no tiene ninguna, se crea una única
 * fracción y las manzanas cuelgan de ella. El modelo queda intacto para el día
 * que un loteamiento sí venga fraccionado, y la interfaz solo muestra el nivel
 * cuando de verdad hay más de una.
 */

/** Código de la fracción que se crea sola. Visible solo si alguien mira la base. */
export const FRACCION_UNICA = "ÚNICA";

/**
 * La fracción donde colgar una manzana nueva de este loteamiento.
 *
 * Devuelve la primera que exista —respetando el orden con el que se listan— y
 * si no hay ninguna, crea la única. Nunca crea una segunda: un loteamiento que
 * ya tiene fracciones reales no debe recibir una "ÚNICA" extra.
 */
export async function fraccionParaManzana(
  sb: AppSupabaseClient,
  empresaId: string,
  loteamientoId: string
): Promise<string> {
  const { data, error } = await sb
    .from("loteamiento_fracciones")
    .select("id")
    .eq("empresa_id", empresaId)
    .eq("loteamiento_id", loteamientoId)
    .order("orden")
    .order("codigo")
    .limit(1);
  if (error) throw new Error(error.message);

  const existente = (data ?? [])[0] as { id?: string } | undefined;
  if (existente?.id) return String(existente.id);

  const { data: creada, error: errIns } = await sb
    .from("loteamiento_fracciones")
    .insert({
      empresa_id: empresaId,
      loteamiento_id: loteamientoId,
      codigo: FRACCION_UNICA,
      nombre: null,
      orden: 0,
    })
    .select("id")
    .single();

  if (errIns) {
    // 23505: otro pedido la creó entre la lectura y el insert. Se relee.
    if ((errIns as { code?: string }).code === "23505") {
      const { data: reintento } = await sb
        .from("loteamiento_fracciones")
        .select("id")
        .eq("empresa_id", empresaId)
        .eq("loteamiento_id", loteamientoId)
        .order("orden")
        .order("codigo")
        .limit(1);
      const fila = (reintento ?? [])[0] as { id?: string } | undefined;
      if (fila?.id) return String(fila.id);
    }
    throw new Error(errIns.message);
  }

  return String((creada as { id: string }).id);
}

/**
 * La manzana de ese código dentro del loteamiento, creándola si no está.
 *
 * Sirve para cargar lotes escribiendo la manzana en el mismo formulario, que es
 * como lo pidió el cliente: manzana, número de lote y dimensiones de una sola
 * vez, sin ir antes a otra pantalla a darla de alta.
 */
export async function manzanaPorCodigo(
  sb: AppSupabaseClient,
  empresaId: string,
  loteamientoId: string,
  codigoRaw: string
): Promise<{ id: string; creada: boolean }> {
  const codigo = String(codigoRaw ?? "").trim();
  if (!codigo) throw new Error("El código de la manzana es obligatorio");

  const fraccionId = await fraccionParaManzana(sb, empresaId, loteamientoId);

  // Se busca en todas las fracciones del loteamiento, no solo en la de por
  // defecto: para quien carga, "Manzana B" es una sola aunque el loteamiento
  // esté fraccionado.
  const { data: fracciones } = await sb
    .from("loteamiento_fracciones")
    .select("id")
    .eq("empresa_id", empresaId)
    .eq("loteamiento_id", loteamientoId);
  const fraccionIds = ((fracciones ?? []) as { id: string }[]).map((f) => f.id);

  if (fraccionIds.length > 0) {
    const { data: existentes } = await sb
      .from("loteamiento_manzanas")
      .select("id, codigo")
      .eq("empresa_id", empresaId)
      .in("fraccion_id", fraccionIds);
    const igual = ((existentes ?? []) as { id: string; codigo: string }[]).find(
      (m) => m.codigo.trim().toLocaleUpperCase("es") === codigo.toLocaleUpperCase("es")
    );
    if (igual) return { id: igual.id, creada: false };
  }

  const { data: creada, error } = await sb
    .from("loteamiento_manzanas")
    .insert({ empresa_id: empresaId, fraccion_id: fraccionId, codigo, nombre: null, orden: 0 })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  return { id: String((creada as { id: string }).id), creada: true };
}
