// Supabase Edge Function: vies-check
// Valida un NIF-IVA en VIES (Comisión Europea) identificando a TB como solicitante,
// para obtener el nº de consulta (requestIdentifier) que sirve de prueba, y lo registra
// en erp_fiscal_vies_consulta. Desplegar con verify_jwt = true.
// Body: { "vat": "FR12345678901", "requester": "ESB02989630" }
import { createClient } from "jsr:@supabase/supabase-js@2";

const VIES = "https://ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { vat, requester } = await req.json();
    const limpio = String(vat || "").replace(/[\s.\-]/g, "").toUpperCase();
    const req_ = String(requester || "").replace(/[\s.\-]/g, "").toUpperCase();
    if (!/^[A-Z]{2}[0-9A-Z]{2,13}$/.test(limpio)) {
      return json({ error: "Formato de NIF-IVA no válido" }, 400);
    }
    const body = {
      countryCode: limpio.slice(0, 2),
      vatNumber: limpio.slice(2),
      requesterMemberStateCode: req_.slice(0, 2) || undefined,
      requesterNumber: req_.slice(2) || undefined,
    };
    const r = await fetch(VIES, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body),
    });
    const data = await r.json();
    if (!r.ok || data.errorWrappers) {
      // VIES caído o EM no disponible: no es "inválido", es "no verificado"
      return json({ estado: "NO_VERIFICADO", detalle: data.errorWrappers ?? data }, 200);
    }
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const fila = {
      pais: body.countryCode,
      numero: body.vatNumber,
      valido: !!data.valid,
      nombre: data.name ?? null,
      direccion: data.address ?? null,
      request_identifier: data.requestIdentifier ?? null,
      respuesta: data,
    };
    const { error } = await sb.from("erp_fiscal_vies_consulta").insert(fila);
    if (error) console.error("registro VIES:", error.message);
    return json({
      estado: data.valid ? "VALIDO" : "INVALIDO",
      fecha: new Date().toISOString().slice(0, 10),
      consulta_id: fila.request_identifier,
      nombre: fila.nombre,
      direccion: fila.direccion,
    });
  } catch (e) {
    return json({ estado: "NO_VERIFICADO", error: String(e) }, 200);
  }
});

function json(o: unknown, status = 200) {
  return new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });
}
