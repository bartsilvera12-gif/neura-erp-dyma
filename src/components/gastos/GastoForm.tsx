"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createGasto, updateGasto, getCuentasGasto, createCuentaGasto } from "@/lib/gastos/actions";
import MontoInput from "@/components/ui/MontoInput";
import { FancySelect } from "@/components/ui/FancySelect";
import type { CuentaGasto, Gasto, GastoInput } from "@/lib/gastos/actions";

const fLabel = "block text-xs font-semibold text-slate-500 uppercase tracking-wide mb-1";
const fInput =
  "w-full px-3 py-2 text-sm border border-slate-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-[#0EA5E9] bg-white";

type Props = {
  gasto?: Gasto | null;
  onSuccess?: () => void;
};

export default function GastoForm({ gasto, onSuccess }: Props) {
  const router = useRouter();
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [cuentas, setCuentas] = useState<CuentaGasto[]>([]);
  const [cuentasError, setCuentasError] = useState<string | null>(null);

  // Alta de cuenta nueva desde el propio formulario.
  const [creandoCuenta, setCreandoCuenta] = useState(false);
  const [nuevaCuenta, setNuevaCuenta] = useState("");
  const [guardandoCuenta, setGuardandoCuenta] = useState(false);
  const [cuentaError, setCuentaError] = useState<string | null>(null);

  const [form, setForm] = useState<GastoInput>({
    cuenta_id: gasto?.cuenta_id ?? "",
    categoria: gasto?.categoria ?? "",
    descripcion: gasto?.descripcion ?? "",
    monto: gasto?.monto ?? 0,
    tipo: gasto?.tipo ?? "variable",
    recurrente: gasto?.recurrente ?? false,
    frecuencia: gasto?.frecuencia ?? "",
    fecha: gasto?.fecha ?? new Date().toISOString().slice(0, 10),
  });

  // El plan de cuentas se carga una vez: alimenta el selector y, de paso, el
  // texto que se guarda en el campo viejo `categoria`.
  useEffect(() => {
    getCuentasGasto()
      .then((c) => {
        setCuentas(c);
        setCuentasError(null);
      })
      .catch((e: unknown) => setCuentasError(e instanceof Error ? e.message : "No se pudo cargar el plan de cuentas"));
  }, []);

  function elegirCuenta(id: string) {
    const c = cuentas.find((x) => x.id === id);
    setForm((prev) => ({ ...prev, cuenta_id: id, categoria: c?.nombre ?? prev.categoria }));
  }

  async function handleCrearCuenta() {
    const nombre = nuevaCuenta.trim();
    if (!nombre) {
      return setCuentaError("Escribí un nombre para la cuenta");
    }
    setCuentaError(null);
    setGuardandoCuenta(true);
    try {
      const creada = await createCuentaGasto(nombre);
      // La metemos en el listado respetando el orden del plan de cuentas y la
      // dejamos seleccionada para que el usuario siga cargando el gasto.
      setCuentas((prev) => {
        const sinDuplicar = prev.filter((c) => c.id !== creada.id);
        return [...sinDuplicar, creada].sort(
          (a, b) => a.orden - b.orden || a.nombre.localeCompare(b.nombre),
        );
      });
      setForm((prev) => ({ ...prev, cuenta_id: creada.id, categoria: creada.nombre }));
      setCuentasError(null);
      setNuevaCuenta("");
      setCreandoCuenta(false);
    } catch (err: unknown) {
      setCuentaError(err instanceof Error ? err.message : "No se pudo crear la cuenta");
    } finally {
      setGuardandoCuenta(false);
    }
  }

  function handleChange(e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) {
    const { name, value, type } = e.target;
    if (type === "checkbox") {
      setForm((prev) => ({ ...prev, recurrente: (e.target as HTMLInputElement).checked }));
    } else if (name !== "monto") {
      const normalized = ["categoria", "descripcion", "frecuencia"].includes(name) ? value.toUpperCase() : value;
      setForm((prev) => ({ ...prev, [name]: normalized }));
    }
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (!form.cuenta_id) {
      return setError("Elegí la cuenta del gasto: es la que lo ubica en el estado de resultado.");
    }
    if (form.monto <= 0) {
      return setError("El monto debe ser mayor a 0.");
    }

    setGuardando(true);

    try {
      if (gasto) {
        await updateGasto(gasto.id, form);
      } else {
        await createGasto(form);
      }
      onSuccess?.();
      router.push("/gastos");
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Error al guardar");
    } finally {
      setGuardando(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-6 max-w-2xl">
      {error && (
        <div className="bg-red-50 border border-red-200 text-red-700 text-sm rounded-lg px-4 py-3">
          {error}
        </div>
      )}

      <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-6">
        <div className="flex items-center gap-2 mb-5 pb-2 border-b border-slate-200">
          <span className="text-base">📋</span>
          <h3 className="text-sm font-bold text-slate-700 uppercase tracking-wider">
            Datos del gasto
          </h3>
        </div>
        <div className="space-y-4">
          <div>
            <label className={fLabel}>Cuenta *</label>
            <FancySelect
              value={form.cuenta_id}
              onChange={elegirCuenta}
              options={[
                { value: "", label: "Elegí una cuenta…" },
                ...cuentas.map((c) => ({ value: c.id, label: c.nombre })),
              ]}
            />
            <p className="mt-1 text-xs text-slate-500">
              Es el renglón en el que el gasto aparece en el estado de resultado.
            </p>
            {cuentasError ? <p className="mt-1 text-xs text-red-600">{cuentasError}</p> : null}
            {!cuentasError && cuentas.length === 0 ? (
              <p className="mt-1 text-xs text-amber-700">
                Todavía no hay cuentas cargadas. Creá la primera con el botón de abajo.
              </p>
            ) : null}

            {/* Alta de cuenta nueva cuando no está en el listado */}
            {creandoCuenta ? (
              <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50 p-3">
                <label className={fLabel}>Nombre de la cuenta nueva</label>
                <div className="flex flex-col gap-2 sm:flex-row">
                  <input
                    type="text"
                    value={nuevaCuenta}
                    onChange={(e) => setNuevaCuenta(e.target.value.toUpperCase())}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") {
                        e.preventDefault();
                        void handleCrearCuenta();
                      }
                    }}
                    placeholder="Ej: ALQUILER DE OFICINA"
                    className={fInput}
                    autoFocus
                  />
                  <div className="flex gap-2">
                    <button
                      type="button"
                      onClick={() => void handleCrearCuenta()}
                      disabled={guardandoCuenta}
                      className="whitespace-nowrap bg-[#0EA5E9] hover:bg-[#0284C7] text-white text-sm font-semibold px-4 py-2 rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      {guardandoCuenta ? "Creando…" : "Crear"}
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        setCreandoCuenta(false);
                        setNuevaCuenta("");
                        setCuentaError(null);
                      }}
                      disabled={guardandoCuenta}
                      className="whitespace-nowrap border border-slate-200 text-sm px-4 py-2 rounded-lg hover:bg-white transition-colors"
                    >
                      Cancelar
                    </button>
                  </div>
                </div>
                {cuentaError ? <p className="mt-2 text-xs text-red-600">{cuentaError}</p> : null}
                <p className="mt-2 text-xs text-slate-500">
                  Queda guardada y disponible para los próximos gastos.
                </p>
              </div>
            ) : (
              <button
                type="button"
                onClick={() => {
                  setCreandoCuenta(true);
                  setCuentaError(null);
                }}
                className="mt-2 inline-flex items-center gap-1 text-xs font-semibold text-[#0EA5E9] hover:text-[#0284C7] transition-colors"
              >
                <span className="text-sm leading-none">＋</span>
                ¿No encontrás la cuenta? Creá una nueva
              </button>
            )}
          </div>
          <div>
            <label className={fLabel}>Descripción</label>
            <textarea
              name="descripcion"
              value={form.descripcion}
              onChange={handleChange}
              placeholder="Descripción del gasto"
              className={fInput}
              rows={2}
            />
          </div>
          <div>
            <label className={fLabel}>Monto (Gs.) *</label>
            <MontoInput
              value={form.monto}
              onChange={(n) => setForm((prev) => ({ ...prev, monto: n }))}
              placeholder="0"
              className={fInput}
              required
            />
          </div>
          <div>
            <label className={fLabel}>Tipo</label>
            <select
              name="tipo"
              value={form.tipo}
              onChange={handleChange}
              className={fInput}
            >
              <option value="variable">Variable</option>
              <option value="fijo">Fijo</option>
            </select>
          </div>
          <div className="flex items-center gap-2">
            <input
              type="checkbox"
              id="recurrente"
              name="recurrente"
              checked={form.recurrente}
              onChange={handleChange}
              className="rounded border-slate-300 text-[#0EA5E9] focus:ring-[#0EA5E9]"
            />
            <label htmlFor="recurrente" className="text-sm text-slate-700">
              Gasto recurrente
            </label>
          </div>
          {form.recurrente && (
            <div>
              <label className={fLabel}>Frecuencia</label>
              <input
                type="text"
                name="frecuencia"
                value={form.frecuencia ?? ""}
                onChange={handleChange}
                placeholder="Ej: Mensual, Semanal"
                className={fInput}
              />
            </div>
          )}
          <div>
            <label className={fLabel}>Fecha *</label>
            <input
              type="date"
              name="fecha"
              value={form.fecha}
              onChange={handleChange}
              className={fInput}
              required
            />
          </div>
        </div>
      </div>

      <div className="flex gap-4">
        <button
          type="submit"
          disabled={guardando}
          className="bg-[#0EA5E9] hover:bg-[#0284C7] text-white text-sm font-semibold px-6 py-2.5 rounded-lg transition-colors shadow-sm disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {guardando ? "Guardando…" : gasto ? "Guardar cambios" : "Crear gasto"}
        </button>
        <button
          type="button"
          onClick={() => router.push("/gastos")}
          className="border border-slate-200 text-sm px-6 py-2.5 rounded-lg hover:bg-slate-50 transition-colors"
        >
          Cancelar
        </button>
      </div>
    </form>
  );
}
