import type { ContratoConfig } from "./types";

/**
 * Ficha del cliente imprimible.
 *
 * Es la hoja de datos personales que se archiva en la carpeta del cliente y que
 * el cliente firma al pie. A pedido de la clienta, muestra únicamente los datos
 * personales: los contratos, saldos y servicios se consultan desde sus propias
 * pantallas, no en esta hoja.
 *
 * Los datos que faltan salen como raya, igual que en el contrato: la ficha se
 * completa a mano antes de archivarla, no se inventa nada.
 *
 * Función pura: recibe datos y devuelve HTML.
 */

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function d(v: unknown, largo = 18): string {
  const s = String(v ?? "").trim();
  return s ? esc(s) : "_".repeat(largo);
}

function fmtFecha(ymd: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd).slice(0, 10));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : "—";
}

export interface ClienteFicha {
  codigo: string | null;
  nombre: string;
  tipo: string;
  documento: string | null;
  ruc: string | null;
  dv: string | null;
  profesion: string | null;
  lugar_trabajo: string | null;
  nacionalidad: string | null;
  estado_civil: string | null;
  telefono: string | null;
  telefono_secundario: string | null;
  email: string | null;
  direccion: string | null;
  ciudad: string | null;
  estado: string;
  alta: string | null;
}

export interface ContratoFicha {
  numero: string;
  fecha: string;
  lote: string;
  modalidad: string;
  precio_total: number;
  cuotas: number;
  cuotas_pagadas: number;
  saldo: number;
  mora: number;
  estado: string;
}

export interface LimpiezaFicha {
  fecha: string;
  importe: number;
  observacion: string | null;
  factura: string | null;
  estado: string | null;
}

export interface DatosFichaCliente {
  config: ContratoConfig;
  logoUrl?: string;
  emitida: string;
  cliente: ClienteFicha;
  contratos: ContratoFicha[];
  limpiezas: LimpiezaFicha[];
}

function fila(k: string, v: string): string {
  return `<div class="dato"><div class="k">${esc(k)}</div><div class="v">${v}</div></div>`;
}

export function plantillaFichaCliente(
  datos: DatosFichaCliente,
  opciones?: { autoImprimir?: boolean }
): string {
  const { config, cliente, logoUrl } = datos;

  // Documento que se transcribe bajo la firma: RUC-DV si es contribuyente, si no la C.I.
  const docFirma = cliente.ruc
    ? `RUC ${cliente.dv ? `${cliente.ruc}-${cliente.dv}` : cliente.ruc}`
    : cliente.documento
      ? `C.I. ${cliente.documento}`
      : "C.I. / RUC";

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ficha de ${esc(cliente.nombre)}</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#111827;background:#f3f4f6;font-size:11pt;line-height:1.45}
  .page{width:210mm;min-height:257mm;margin:0 auto;background:#fff;padding:18mm 20mm;display:flex;flex-direction:column}
  .membrete{display:flex;justify-content:space-between;align-items:flex-start;gap:18px;border-bottom:2px solid #111827;padding-bottom:10px;margin-bottom:14px}
  .membrete .logo{max-width:180px;max-height:70px;object-fit:contain;display:block}
  .membrete .logo-txt{font-size:15pt;font-weight:800}
  .membrete-datos{text-align:right;font-size:9pt;color:#374151;line-height:1.4}
  .membrete-datos .razon{font-weight:800;color:#111827;font-size:10.5pt}
  h1{font-size:15pt;margin:0 0 2px}
  .sub{font-size:9.5pt;color:#6b7280;margin-bottom:16px}
  h2{font-size:10pt;text-transform:uppercase;letter-spacing:.05em;color:#6b7280;margin:20px 0 8px;padding-bottom:4px;border-bottom:1px solid #e5e7eb}
  .datos{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
  .dato{border:1px solid #e5e7eb;border-radius:6px;padding:7px 9px}
  .dato .k{font-size:8pt;text-transform:uppercase;letter-spacing:.04em;color:#6b7280}
  .dato .v{font-size:10.5pt;font-weight:600;margin-top:1px;word-break:break-word}
  .resumen{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:14px 0}
  .kpi{border:1px solid #d1d5db;border-radius:8px;padding:10px 12px}
  .kpi .k{font-size:8pt;text-transform:uppercase;letter-spacing:.04em;color:#6b7280}
  .kpi .v{font-size:14pt;font-weight:800;margin-top:2px}
  .kpi.alerta .v{color:#b91c1c}
  table{width:100%;border-collapse:collapse;font-size:9.5pt}
  th,td{border:1px solid #d1d5db;padding:4px 7px;text-align:left}
  th{background:#f3f4f6;font-weight:700;text-align:center;font-size:8.5pt;text-transform:uppercase;letter-spacing:.03em}
  td.c{text-align:center} td.n{text-align:right}
  tfoot td{background:#f9fafb;font-weight:800}
  .firma-wrap{margin-top:auto;padding-top:40px}
  .firma{width:70mm;margin:48px auto 0;text-align:center}
  .firma .linea{border-top:1px solid #111827;padding-top:6px}
  .firma .nombre{font-size:11pt;font-weight:700}
  .firma .doc{font-size:9pt;color:#374151;margin-top:1px}
  .firma .label{font-size:9pt;color:#6b7280;text-transform:uppercase;letter-spacing:.05em;margin-top:2px}
  .pie{margin-top:20px;font-size:8.5pt;color:#9ca3af;border-top:1px solid #e5e7eb;padding-top:8px}
  .toolbar{max-width:210mm;margin:12px auto;text-align:right}
  .toolbar button{font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;background:#0EA5E9;color:#fff;cursor:pointer}
  @media print{
    body{background:#fff} .toolbar{display:none} .page{width:auto;padding:0;margin:0}
    thead{display:table-header-group} tr{break-inside:avoid} h2{break-after:avoid}
    @page{size:A4;margin:14mm}
  }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir / Guardar PDF</button></div>
<div class="page">

<div class="membrete">
  ${logoUrl ? `<img class="logo" src="${esc(logoUrl)}" alt="${esc(config.razon_social)}" />` : `<div class="logo-txt">${esc(config.razon_social)}</div>`}
  <div class="membrete-datos">
    <div class="razon">${esc(config.razon_social)}</div>
    ${config.ruc ? `<div>RUC ${esc(config.ruc)}</div>` : ""}
    ${config.domicilio ? `<div>${esc(config.domicilio)}</div>` : ""}
  </div>
</div>

<h1>${esc(cliente.nombre)}</h1>
<div class="sub">Ficha de cliente${cliente.codigo ? ` · ${esc(cliente.codigo)}` : ""} · emitida el ${esc(
    fmtFecha(datos.emitida)
  )}</div>

<h2>Datos del cliente</h2>
<div class="datos">
  ${fila("Tipo", esc(cliente.tipo))}
  ${cliente.documento ? fila("C.I. / Documento", d(cliente.documento, 14)) : ""}
  ${cliente.ruc ? fila("RUC", d(cliente.dv ? `${cliente.ruc}-${cliente.dv}` : cliente.ruc, 14)) : ""}
  ${!cliente.documento && !cliente.ruc ? fila("C.I. / Documento", "—") : ""}
  ${fila("Estado", esc(cliente.estado))}
  ${fila("Profesión / Ocupación", d(cliente.profesion, 20))}
  ${fila("Lugar de trabajo", d(cliente.lugar_trabajo, 24))}
  ${fila("Nacionalidad", d(cliente.nacionalidad, 12))}
  ${fila("Estado civil", d(cliente.estado_civil, 12))}
  ${fila("Cliente desde", cliente.alta ? esc(fmtFecha(cliente.alta)) : "—")}
  ${fila("Teléfono", d(cliente.telefono, 14))}
  ${fila("Teléfono alternativo", d(cliente.telefono_secundario, 14))}
  ${fila("Email", d(cliente.email, 18))}
  ${fila("Domicilio", d(cliente.direccion, 30))}
  ${fila("Ciudad", d(cliente.ciudad, 14))}
</div>

<div class="firma-wrap">
  <div class="firma">
    <div class="linea">
      <div class="nombre">${esc(cliente.nombre)}</div>
      <div class="doc">${esc(docFirma)}</div>
      <div class="label">Firma del cliente</div>
    </div>
  </div>
  <p class="pie">Documento interno, no fiscal. Emitida el ${esc(fmtFecha(datos.emitida))}.</p>
</div>

</div>
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
