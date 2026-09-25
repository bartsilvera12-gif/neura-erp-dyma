"use client";

import { useEffect, useMemo, useState } from "react";
import { Search, Tag } from "lucide-react";
import { fetchWithSupabaseSession } from "@/lib/api/fetch-with-supabase-session";

interface PresentacionPrecio {
  nombre: string;
  precio_venta: number | null;
  es_default: boolean;
}

interface PrecioProducto {
  id: string;
  nombre: string;
  sku: string | null;
  precio_venta: number | null;
  unidad_medida: string | null;
  imagen_url: string | null;
  descripcion: string | null;
  presentaciones: PresentacionPrecio[];
}

const inputClass =
  "w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2.5 text-sm text-slate-800 shadow-sm outline-none transition-colors placeholder:text-slate-400 hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25";

function gs(v: number | null): string {
  if (v == null) return "—";
  return `Gs. ${Math.round(v).toLocaleString("es-PY")}`;
}

/** Normaliza para búsqueda: sin acentos, minúsculas. */
function norm(s: string): string {
  return s
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{M}/gu, "");
}

export default function ConsultaPreciosClient() {
  const [productos, setProductos] = useState<PrecioProducto[]>([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [q, setQ] = useState("");

  useEffect(() => {
    let vivo = true;
    (async () => {
      setCargando(true);
      setError(null);
      try {
        const res = await fetchWithSupabaseSession("/api/productos/precios", { cache: "no-store" });
        const json = (await res.json()) as {
          success?: boolean;
          error?: string;
          data?: { productos: PrecioProducto[] };
        };
        if (!res.ok || json.success !== true || !json.data) throw new Error(json.error ?? `Error ${res.status}`);
        if (vivo) setProductos(json.data.productos);
      } catch (e) {
        if (vivo) setError(e instanceof Error ? e.message : "No se pudieron cargar los precios");
      } finally {
        if (vivo) setCargando(false);
      }
    })();
    return () => {
      vivo = false;
    };
  }, []);

  const filtrados = useMemo(() => {
    const t = norm(q);
    if (!t) return productos;
    return productos.filter(
      (p) => norm(p.nombre).includes(t) || (p.sku ? norm(p.sku).includes(t) : false)
    );
  }, [productos, q]);

  return (
    <div className="w-full min-w-0 max-w-full space-y-5">
      <div>
        <h1 className="text-[26px] font-bold tracking-tight text-slate-900">Consulta de precios</h1>
        <p className="mt-1 text-sm text-slate-500">
          Buscá un producto y mirá su precio de venta y sus presentaciones. Pantalla de solo lectura.
        </p>
      </div>

      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Buscar por nombre o SKU…"
          className={`${inputClass} pl-9`}
          autoFocus
        />
      </div>

      {cargando ? (
        <p className="py-16 text-center text-sm text-slate-400">Cargando precios…</p>
      ) : error ? (
        <div className="rounded-2xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">{error}</div>
      ) : filtrados.length === 0 ? (
        <div className="rounded-2xl border border-slate-200 bg-slate-50/60 px-4 py-12 text-center text-sm text-slate-400">
          {productos.length === 0 ? "No hay productos cargados." : "Ningún producto coincide con la búsqueda."}
        </div>
      ) : (
        <div className="grid gap-3">
          {filtrados.map((p) => (
            <div key={p.id} className="rounded-2xl border border-slate-200 bg-white p-4">
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-slate-900">{p.nombre}</p>
                  <div className="mt-1 flex flex-wrap items-center gap-2 text-[11px] text-slate-500">
                    {p.sku ? (
                      <span className="inline-flex items-center gap-1 rounded bg-slate-100 px-1.5 py-0.5 font-medium text-slate-600">
                        <Tag className="h-3 w-3" /> {p.sku}
                      </span>
                    ) : null}
                    {p.unidad_medida ? <span>por {p.unidad_medida.toLowerCase()}</span> : null}
                  </div>
                  {p.descripcion ? <p className="mt-1 text-[11px] text-slate-400">{p.descripcion}</p> : null}
                </div>
                <div className="shrink-0 text-right">
                  <p className="text-[10px] font-semibold uppercase tracking-wider text-slate-400">Precio de venta</p>
                  <p className="text-lg font-bold tabular-nums text-slate-900">{gs(p.precio_venta)}</p>
                </div>
              </div>

              {p.presentaciones.length > 0 ? (
                <div className="mt-3 border-t border-slate-100 pt-3">
                  <p className="mb-1.5 text-[10px] font-semibold uppercase tracking-wider text-slate-400">
                    Presentaciones
                  </p>
                  <div className="grid gap-1.5">
                    {p.presentaciones.map((pr, i) => (
                      <div key={i} className="flex items-center justify-between gap-3 text-sm">
                        <span className="flex items-center gap-2 text-slate-700">
                          {pr.nombre}
                          {pr.es_default ? (
                            <span className="rounded bg-sky-50 px-1.5 py-0.5 text-[9px] font-semibold text-sky-700">
                              Principal
                            </span>
                          ) : null}
                        </span>
                        <span className="font-semibold tabular-nums text-slate-900">
                          {gs(pr.precio_venta ?? p.precio_venta)}
                        </span>
                      </div>
                    ))}
                  </div>
                </div>
              ) : null}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
