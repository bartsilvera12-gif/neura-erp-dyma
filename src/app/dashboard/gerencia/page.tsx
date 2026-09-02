import GerenciaClient from "./GerenciaClient";

export const dynamic = "force-dynamic";

/** Módulo Gerencia — tablero comercial read-only sobre las views `v_*` del schema. */
export default function GerenciaPage() {
  return <GerenciaClient />;
}
