export type EstadoLote = "disponible" | "reservado" | "vendido" | "bloqueado";
export type MonedaLote = "GS" | "USD";

export const ESTADOS_LOTE: EstadoLote[] = ["disponible", "reservado", "vendido", "bloqueado"];

/** Etiqueta y color de cada estado. Una sola fuente para grilla, chips y leyenda. */
export const ESTADO_LOTE_UI: Record<
  EstadoLote,
  { label: string; chip: string; celda: string; punto: string }
> = {
  disponible: {
    label: "Disponible",
    chip: "border-emerald-200 bg-emerald-50 text-emerald-700",
    celda: "border-emerald-300 bg-emerald-50 text-emerald-900 hover:bg-emerald-100",
    punto: "bg-emerald-500",
  },
  reservado: {
    label: "Reservado",
    chip: "border-amber-200 bg-amber-50 text-amber-700",
    celda: "border-amber-300 bg-amber-50 text-amber-900 hover:bg-amber-100",
    punto: "bg-amber-500",
  },
  vendido: {
    label: "Vendido",
    chip: "border-sky-200 bg-sky-50 text-sky-700",
    celda: "border-sky-300 bg-sky-50 text-sky-900 hover:bg-sky-100",
    punto: "bg-sky-500",
  },
  bloqueado: {
    label: "Bloqueado",
    chip: "border-slate-300 bg-slate-100 text-slate-600",
    celda: "border-slate-300 bg-slate-100 text-slate-600 hover:bg-slate-200",
    punto: "bg-slate-400",
  },
};

export interface Loteamiento {
  id: string;
  codigo: string;
  nombre: string;
  ubicacion: string | null;
  descripcion: string | null;
  activo: boolean;
}

export interface Fraccion {
  id: string;
  loteamiento_id: string;
  codigo: string;
  nombre: string | null;
  orden: number;
}

export interface Manzana {
  id: string;
  fraccion_id: string;
  codigo: string;
  nombre: string | null;
  orden: number;
}

export interface Lote {
  id: string;
  manzana_id: string;
  numero: string;
  superficie_m2: number | null;
  frente_m: number | null;
  fondo_m: number | null;
  lindero_norte: string | null;
  lindero_sur: string | null;
  lindero_este: string | null;
  lindero_oeste: string | null;
  precio_contado: number | null;
  precio_financiado: number | null;
  moneda: MonedaLote;
  estado: EstadoLote;
  estado_motivo: string | null;
  cliente_id: string | null;
  cliente_label: string | null;
  observacion: string | null;
}

/** Árbol de configuración del loteamiento, para los selectores y la pantalla de estructura. */
export interface EstructuraPayload {
  loteamientos: Loteamiento[];
  fracciones: Fraccion[];
  manzanas: Manzana[];
}

export interface ResumenLotes {
  total: number;
  disponible: number;
  reservado: number;
  vendido: number;
  bloqueado: number;
  superficie_total: number;
}

export interface LotesPayload {
  resumen: ResumenLotes;
  lotes: Lote[];
}

/** Nivel de la jerarquía sobre el que opera el ABM de estructura. */
export type NivelEstructura = "loteamiento" | "fraccion" | "manzana";
