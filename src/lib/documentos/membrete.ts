/**
 * Membrete (encabezado) común para todos los documentos imprimibles del ERP.
 * Devuelve HTML con estilos inline para no depender del CSS de cada endpoint.
 *
 * SOLO presentación: no toca datos de negocio.
 */

export const EMPRESA_DOC = {
  nombre: "DYMA",
  actividad: ["Soluciones industriales"],
  telefono: "",
  email: "",
  direccion: [] as string[],
  /** Logo del cliente. Lo resuelve el servidor, así la extensión del archivo no importa. */
  logoUrl: "/api/brand/logo",
};

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Membrete A4: logo a la izquierda, datos comerciales a la derecha, línea divisoria.
 * `origin` opcional para URL absoluta del logo (útil al imprimir/guardar PDF).
 */
export function membreteA4(origin = ""): string {
  const e = EMPRESA_DOC;
  const logo = origin ? `${origin}${e.logoUrl}` : e.logoUrl;
  const actividadHtml = e.actividad.length
    ? e.actividad.map((a) => `<div style="color:#6b7280;">${esc(a)}</div>`).join("")
    : "";
  const telHtml = e.telefono ? `<div style="margin-top:4px;"><strong>Tel:</strong> ${esc(e.telefono)}</div>` : "";
  const emailHtml = e.email ? `<div><strong>Email:</strong> ${esc(e.email)}</div>` : "";
  const dirHtml = e.direccion.length ? `<div>${e.direccion.map(esc).join(" · ")}</div>` : "";
  return `
  <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:18px;border-bottom:2px solid #1e3a8a;padding-bottom:12px;margin-bottom:16px;">
    <div style="flex:0 0 auto;">
      <img src="${esc(logo)}" alt="${esc(e.nombre)}" style="max-width:240px;max-height:130px;width:auto;height:auto;object-fit:contain;display:block;" />
    </div>
    <div style="flex:1;min-width:0;text-align:right;font-size:11px;color:#374151;line-height:1.55;">
      <div style="font-size:14px;font-weight:800;color:#1f2937;">${esc(e.nombre)}</div>
      ${actividadHtml}
      ${telHtml}
      ${emailHtml}
      ${dirHtml}
    </div>
  </div>`;
}

/**
 * Membrete compacto para ticket angosto (58/80mm): logo arriba, datos centrados.
 */
export function membreteTicket(origin = ""): string {
  const e = EMPRESA_DOC;
  const logo = origin ? `${origin}${e.logoUrl}` : e.logoUrl;
  const telHtml = e.telefono ? `<div style="font-size:10px;">Tel: ${esc(e.telefono)}</div>` : "";
  const emailHtml = e.email ? `<div style="font-size:10px;word-break:break-all;">${esc(e.email)}</div>` : "";
  const dirHtml = e.direccion.length
    ? e.direccion.map((d) => `<div style="font-size:10px;">${esc(d)}</div>`).join("")
    : "";
  return `
  <div style="text-align:center;padding-bottom:6px;margin-bottom:6px;border-bottom:1px dashed #000;">
    <img src="${esc(logo)}" alt="${esc(e.nombre)}" style="max-width:210px;max-height:110px;width:auto;height:auto;object-fit:contain;display:inline-block;margin:0 auto 4px;" />
    <div style="font-weight:700;font-size:12px;">${esc(e.nombre)}</div>
    ${dirHtml}
    ${telHtml}
    ${emailHtml}
  </div>`;
}
