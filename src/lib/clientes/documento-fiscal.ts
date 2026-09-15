/**
 * Documento fiscal del cliente para la factura y el contrato.
 *
 * Regla del negocio:
 *   - Si el cliente tiene RUC, se usa el RUC. Con dígito verificador cargado
 *     aparte, se arma "RUC-DV" (80012345-6). Si el DV no está cargado, se usa el
 *     RUC tal cual: cubre las cargas viejas donde el verificador iba pegado al
 *     final del propio RUC.
 *   - Si no tiene RUC, se factura con el documento (CI) como no contribuyente.
 *
 * La cédula y el RUC son columnas distintas, así que cargar el RUC nunca pisa la
 * cédula: esta función solo decide cuál mostrar, no toca los datos.
 */
export function documentoFiscalCliente(cliente: {
  ruc?: string | null;
  dv?: string | null;
  documento?: string | null;
}): string | null {
  const ruc = String(cliente.ruc ?? "").trim();
  const dv = String(cliente.dv ?? "").trim();
  if (ruc) return dv ? `${ruc}-${dv}` : ruc;
  const documento = String(cliente.documento ?? "").trim();
  return documento || null;
}

/** Igual que `documentoFiscalCliente`, tomando los campos de una fila cruda. */
export function documentoFiscalDesdeRow(row: Record<string, unknown> | null): string | null {
  if (!row) return null;
  return documentoFiscalCliente({
    ruc: row.ruc as string | null | undefined,
    dv: row.dv as string | null | undefined,
    documento: row.documento as string | null | undefined,
  });
}
