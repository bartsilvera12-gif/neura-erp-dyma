/** Rol de una parte que firma además del titular. */
export type RolParte = "conyuge" | "codeudor";

export const ROL_PARTE_UI: Record<RolParte, { label: string; singular: string }> = {
  conyuge: { label: "Cónyuge", singular: "cónyuge" },
  codeudor: { label: "Codeudor", singular: "codeudor" },
};

/** Datos completos de una parte. Se guardan con el contrato, no con el cliente. */
export interface ParteContrato {
  id?: string;
  rol: RolParte;
  /** Vínculo opcional al cliente, cuando la parte además es cliente de la empresa. */
  cliente_id: string | null;
  nombre: string;
  documento: string | null;
  nacionalidad: string | null;
  estado_civil: string | null;
  domicilio: string | null;
  telefono: string | null;
  email: string | null;
  observacion: string | null;
}

/** Tipo de contrato del catálogo. Qué partes exige define qué formularios se piden. */
export interface ContratoTipo {
  id: string;
  slug: string;
  nombre: string;
  descripcion: string | null;
  requiere_conyuge: boolean;
  requiere_codeudor: boolean;
  plantilla: string;
  activo: boolean;
}

/** Datos de LA VENDEDORA que van en el encabezado. */
export interface ContratoConfig {
  razon_social: string;
  ruc: string | null;
  representante_nombre: string | null;
  representante_documento: string | null;
  domicilio: string | null;
  ciudad_firma: string | null;
  departamento: string | null;
  lugar_pago: string | null;
  dia_pago_desde: number;
  dia_pago_hasta: number;
  ejemplares: number;
}

/** Una persona tal como la nombra el contrato. */
export interface PersonaContrato {
  nombre: string;
  documento: string | null;
  nacionalidad: string | null;
  estado_civil: string | null;
  domicilio: string | null;
}

/** El lote y su loteamiento, para el apartado "Datos del Loteamiento". */
export interface InmuebleContrato {
  loteamiento: string | null;
  fraccion: string | null;
  manzana: string | null;
  lote: string | null;
  superficie_m2: number | null;
  finca_matriz: string | null;
  matricula: string | null;
  cuenta_corriente_catastral: string | null;
  padron: string | null;
  departamento: string | null;
  distrito: string | null;
  resolucion_municipal: string | null;
  run_expediente: string | null;
  linda_norte: string | null;
  linda_sur: string | null;
  linda_este: string | null;
  linda_oeste: string | null;
}

/** Condiciones económicas del contrato. */
export interface OperacionContrato {
  numero_contrato: string;
  fecha_venta: string;
  moneda: string;
  /** Lo que el comprador paga en total: entrega + monto financiado. */
  precio_total: number;
  entrega_inicial: number;
  monto_financiado: number;
  cantidad_cuotas: number;
  cuota: number;
  primer_vencimiento: string;
}

/** Una cuota del plan, como se transcribe en el anexo del contrato. */
export interface CuotaContrato {
  numero: number;
  vencimiento: string;
  capital: number;
  interes: number;
  total: number;
}

/** Todo lo que necesita la plantilla para armar el documento. */
export interface DatosContrato {
  /** Plan de pago completo. Va como anexo firmado junto al contrato. */
  cuotas: CuotaContrato[];
  /** URL del logo de la empresa; vacío = el documento sale sin membrete. */
  logoUrl?: string;
  config: ContratoConfig;
  tipo: ContratoTipo | null;
  comprador: PersonaContrato;
  conyuge: PersonaContrato | null;
  codeudores: PersonaContrato[];
  inmueble: InmuebleContrato;
  operacion: OperacionContrato;
}
