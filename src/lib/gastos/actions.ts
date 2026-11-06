import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";
import { getEmpresaId } from "@/lib/db/empresa";
import { ymdInicioFinMesLocal } from "@/lib/fechas/calendario";
import { getBrowserSupabaseForEmpresaData } from "@/lib/supabase/browser-data-client";

/** Una cuenta del plan de gastos: es el renglón del estado de resultado. */
export type CuentaGasto = {
  id: string;
  codigo: string;
  nombre: string;
  orden: number;
  activo: boolean;
};

export type Gasto = {
  id: string;
  empresa_id: string;
  /** Cuenta del plan. Null solo en gastos viejos, previos al catálogo. */
  cuenta_id: string | null;
  categoria: string;
  descripcion: string;
  monto: number;
  tipo: "fijo" | "variable";
  recurrente: boolean;
  frecuencia?: string;
  fecha: string;
  created_at: string;
};

export type GastoInput = {
  cuenta_id: string;
  categoria: string;
  descripcion: string;
  monto: number;
  tipo: "fijo" | "variable";
  recurrente: boolean;
  frecuencia?: string;
  fecha: string;
};

function mapRow(r: Record<string, unknown>): Gasto {
  return {
    id: r.id as string,
    empresa_id: r.empresa_id as string,
    cuenta_id: (r.cuenta_id as string) ?? null,
    categoria: (r.categoria as string) ?? "",
    descripcion: (r.descripcion as string) ?? "",
    monto: Number(r.monto) ?? 0,
    tipo: (r.tipo as "fijo" | "variable") ?? "variable",
    recurrente: Boolean(r.recurrente),
    frecuencia: r.frecuencia as string | undefined,
    fecha: (r.fecha as string) ?? "",
    created_at: (r.created_at as string) ?? "",
  };
}

/**
 * Las cuentas del plan de gastos, en el orden del estado de resultado.
 *
 * Solo las activas: una cuenta que se dio de baja no debe ofrecerse para
 * gastos nuevos, pero los que ya la usan la conservan.
 */
export async function getCuentasGasto(): Promise<CuentaGasto[]> {
  const supabase = await getBrowserSupabaseForEmpresaData();
  const { data, error } = await supabase
    .from("gasto_cuentas")
    .select("id, codigo, nombre, orden, activo")
    .eq("activo", true)
    .order("orden")
    .order("nombre");
  if (error) throw new Error(error.message);
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    id: String(r.id),
    codigo: String(r.codigo ?? ""),
    nombre: String(r.nombre ?? ""),
    orden: Number(r.orden) || 0,
    activo: r.activo !== false,
  }));
}

/**
 * Crea una cuenta de gasto nueva para la empresa del usuario y la deja activa
 * y disponible para futuros registros.
 *
 * El nombre se normaliza (trim + mayúsculas) para que coincida con la
 * convención del plan de cuentas y no se dupliquen renglones del estado de
 * resultado por diferencias de capitalización. Si ya existe una cuenta con ese
 * nombre:
 *   - activa: se devuelve tal cual (no se duplica).
 *   - inactiva: se reactiva y se devuelve.
 *
 * El código sigue la convención de las cuentas creadas a mano: `M` + un orden
 * libre al final del plan (p. ej. `M190`), para no chocar con los códigos del
 * modelo que trajo el cliente.
 */
export async function createCuentaGasto(nombre: string): Promise<CuentaGasto> {
  const nombreLimpio = (nombre ?? "").trim().toUpperCase();
  if (!nombreLimpio) throw new Error("Escribí un nombre para la cuenta");

  const supabase = await getBrowserSupabaseForEmpresaData();
  const empresa_id = await getEmpresaId();

  // Todas las cuentas de la empresa (activas e inactivas): el nombre y el código
  // son únicos por empresa sin importar el estado.
  const { data: existentesRaw, error: errExist } = await supabase
    .from("gasto_cuentas")
    .select("id, codigo, nombre, orden, activo")
    .eq("empresa_id", empresa_id);
  if (errExist) throw new Error(errExist.message);

  const existentes = (existentesRaw ?? []) as Record<string, unknown>[];

  // ¿Ya existe una cuenta con ese nombre (sin distinguir mayúsculas)?
  const yaExiste = existentes.find(
    (c) => String(c.nombre ?? "").trim().toUpperCase() === nombreLimpio,
  );
  if (yaExiste) {
    if (yaExiste.activo === false) {
      const { data, error } = await supabase
        .from("gasto_cuentas")
        .update({ activo: true })
        .eq("id", String(yaExiste.id))
        .select("id, codigo, nombre, orden, activo")
        .single();
      if (error) throw new Error(error.message);
      const r = data as Record<string, unknown>;
      return {
        id: String(r.id),
        codigo: String(r.codigo ?? ""),
        nombre: String(r.nombre ?? ""),
        orden: Number(r.orden) || 0,
        activo: r.activo !== false,
      };
    }
    throw new Error("Ya existe una cuenta con ese nombre");
  }

  // Orden y código libres al final del plan.
  const maxOrden = existentes.reduce((m, c) => Math.max(m, Number(c.orden) || 0), 0);
  const codigosUsados = new Set(existentes.map((c) => String(c.codigo ?? "")));
  let orden = maxOrden + 10;
  let codigo = `M${String(orden).padStart(3, "0")}`;
  while (codigosUsados.has(codigo)) {
    orden += 10;
    codigo = `M${String(orden).padStart(3, "0")}`;
  }

  const { data, error } = await supabase
    .from("gasto_cuentas")
    .insert({ empresa_id, codigo, nombre: nombreLimpio, orden, activo: true })
    .select("id, codigo, nombre, orden, activo")
    .single();
  if (error) throw new Error(error.message);

  const r = data as Record<string, unknown>;
  return {
    id: String(r.id),
    codigo: String(r.codigo ?? ""),
    nombre: String(r.nombre ?? ""),
    orden: Number(r.orden) || 0,
    activo: r.activo !== false,
  };
}

/** Obtiene todos los gastos de la empresa, ordenados por fecha desc. */
export async function getGastos(): Promise<Gasto[]> {
  if (typeof window !== "undefined") {
    const res = await fetchWithSupabaseSession("/api/gastos", { cache: "no-store" });
    if (!res.ok) {
      const t = await res.text().catch(() => "");
      throw new Error(t || `Error ${res.status}`);
    }
    const json = (await res.json()) as { success?: boolean; data?: Record<string, unknown>[] };
    if (!json.success || !Array.isArray(json.data)) return [];
    return json.data.map(mapRow);
  }

  const supabase = await getBrowserSupabaseForEmpresaData();
  const { data, error } = await supabase
    .from("gastos")
    .select("*")
    .order("fecha", { ascending: false });

  if (error) throw new Error(error.message);
  return (data ?? []).map(mapRow);
}

/** Obtiene los gastos del mes actual (para Dashboard). RLS filtra por empresa. */
export async function getGastosMesActual(): Promise<Gasto[]> {
  const supabase = await getBrowserSupabaseForEmpresaData();
  const hoy = new Date();
  const { inicioYmd: inicioMes, finYmd: finMes } = ymdInicioFinMesLocal(hoy);

  const { data, error } = await supabase
    .from("gastos")
    .select("*")
    .gte("fecha", inicioMes)
    .lte("fecha", finMes)
    .order("fecha", { ascending: false });

  if (error) throw new Error(error.message);
  return (data ?? []).map(mapRow);
}

export async function createGasto(input: GastoInput): Promise<Gasto> {
  if (input.monto <= 0) throw new Error("El monto debe ser mayor a 0");

  const supabase = await getBrowserSupabaseForEmpresaData();
  const empresa_id = await getEmpresaId();

  if (!input.cuenta_id) throw new Error("Elegí la cuenta del gasto");

  const { data, error } = await supabase
    .from("gastos")
    .insert({
      empresa_id,
      cuenta_id: input.cuenta_id,
      // Se guarda también el nombre de la cuenta en el campo viejo: las
      // pantallas que todavía leen `categoria` siguen mostrando algo.
      categoria: input.categoria.trim() || null,
      descripcion: input.descripcion.trim() || null,
      monto: input.monto,
      tipo: input.tipo,
      recurrente: input.recurrente,
      frecuencia: input.frecuencia?.trim() || null,
      fecha: input.fecha,
    })
    .select()
    .single();

  if (error) throw new Error(error.message);
  return mapRow(data as Record<string, unknown>);
}

export async function updateGasto(id: string, input: Partial<GastoInput>): Promise<Gasto> {
  if (input.monto !== undefined && input.monto <= 0) throw new Error("El monto debe ser mayor a 0");

  const supabase = await getBrowserSupabaseForEmpresaData();
  const update: Record<string, unknown> = {};
  if (input.cuenta_id !== undefined) {
    if (!input.cuenta_id) throw new Error("Elegí la cuenta del gasto");
    update.cuenta_id = input.cuenta_id;
  }
  if (input.categoria !== undefined) update.categoria = input.categoria.trim() || null;
  if (input.descripcion !== undefined) update.descripcion = input.descripcion.trim() || null;
  if (input.monto !== undefined) update.monto = input.monto;
  if (input.tipo !== undefined) update.tipo = input.tipo;
  if (input.recurrente !== undefined) update.recurrente = input.recurrente;
  if (input.frecuencia !== undefined) update.frecuencia = input.frecuencia?.trim() || null;
  if (input.fecha !== undefined) update.fecha = input.fecha;

  const { data, error } = await supabase
    .from("gastos")
    .update(update)
    .eq("id", id)
    .select()
    .single();

  if (error) throw new Error(error.message);
  return mapRow(data as Record<string, unknown>);
}

export async function deleteGasto(id: string): Promise<void> {
  const supabase = await getBrowserSupabaseForEmpresaData();
  const { error } = await supabase.from("gastos").delete().eq("id", id);

  if (error) throw new Error(error.message);
}
