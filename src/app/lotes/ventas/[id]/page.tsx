import ContratoClient from "./ContratoClient";

/** Detalle del contrato: condiciones, codeudores y plan de cuotas con su mora. */
export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return <ContratoClient ventaId={id} />;
}
