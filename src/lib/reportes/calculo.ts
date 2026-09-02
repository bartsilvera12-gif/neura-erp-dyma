import type { TramoMora } from "@/lib/reportes/types";

/** Fecha de hoy en Asunción, como YYYY-MM-DD. */
export function hoyAsuncion(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Asuncion",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

/**
 * Días de `desde` a `hasta`, ambos YYYY-MM-DD.
 * Positivo = `hasta` está en el futuro respecto de `desde`.
 * Se comparan en UTC a propósito: son fechas de calendario, no instantes, así que
 * el huso no debe correr el resultado en un día.
 */
export function diasEntre(desde: string, hasta: string): number {
  return Math.round((Date.parse(`${hasta}T00:00:00Z`) - Date.parse(`${desde}T00:00:00Z`)) / 86_400_000);
}

/** Tramo de antigüedad de la deuda a partir de los días de atraso. */
export function tramoDeMora(dias: number): TramoMora {
  if (dias <= 30) return "1_30";
  if (dias <= 60) return "31_60";
  if (dias <= 90) return "61_90";
  return "90_mas";
}

/** Claves de la proyección de cobros, en el orden en que se muestran. */
export type ClaveProyeccion = "vencido" | "7" | "30" | "60" | "mas" | "sin_fecha";

/**
 * Ubica una factura pendiente en su tramo de proyección según el vencimiento.
 * `null` en el vencimiento cae en "sin_fecha": no se puede proyectar sin fecha.
 */
export function claveProyeccion(vencimiento: string | null, hoy: string): ClaveProyeccion {
  if (!vencimiento) return "sin_fecha";
  const dias = diasEntre(hoy, vencimiento);
  if (dias < 0) return "vencido";
  if (dias <= 7) return "7";
  if (dias <= 30) return "30";
  if (dias <= 60) return "60";
  return "mas";
}

/**
 * Días de atraso de una factura pendiente. 0 si todavía no venció o vence hoy.
 * `null` cuando no hay fecha de vencimiento.
 */
export function diasAtraso(vencimiento: string | null, hoy: string): number | null {
  if (!vencimiento) return null;
  const dias = diasEntre(vencimiento, hoy);
  return dias > 0 ? dias : 0;
}
