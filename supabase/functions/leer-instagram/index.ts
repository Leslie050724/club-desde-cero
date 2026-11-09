// Club desde Cero · Lee los comentarios (y sus likes) del último vídeo de @club.desdecero
// y los guarda en la tabla ig_comentarios. Lo ejecuta un cron cada 5 minutos.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const IG = "https://graph.instagram.com";

// Saca un nombre de club del texto del comentario (sin @menciones, #hashtags ni emojis)
function limpiar(texto: string): string | null {
  const s = (texto.split("\n")[0] ?? "")
    .replace(/@[\w.]+/g, "")
    .replace(/#[\p{L}\p{N}_]+/gu, "")
    .replace(/[^\p{L}\p{N} .'-]/gu, "")
    .replace(/\s+/g, " ")
    .trim();
  return s.length >= 3 && s.length <= 30 ? s : null;
}

Deno.serve(async (req) => {
  // Solo el cron (que conoce el secreto) puede llamar a esta función
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return new Response("No autorizado", { status: 401 });
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: cfg } = await sb.from("ig_config").select("clave,valor");
  const get = (k: string) => cfg?.find((c) => c.clave === k)?.valor ?? null;
  const guardar = (clave: string, valor: string) =>
    sb.from("ig_config").upsert({ clave, valor });

  // Token: el último renovado, o el que pegaste en Secrets
  let token: string | null = get("token") ?? Deno.env.get("IG_TOKEN") ?? null;
  if (!token) return Response.json({ ok: false, error: "Falta IG_TOKEN en Secrets" }, { status: 500 });

  // Dos tipos de token: de Instagram ("IG…", graph.instagram.com) o de Facebook ("EAA…", graph.facebook.com)
  const esFB = token.startsWith("EAA");
  const API = esFB ? "https://graph.facebook.com/v21.0" : IG;
  let yo = "me";
  if (esFB) {
    yo = Deno.env.get("IG_USER_ID") ?? get("ig_user_id") ?? "";
    if (!yo) {
      const r = await fetch(`${API}/me/accounts?fields=instagram_business_account&access_token=${token}`);
      const j = await r.json();
      yo = j.data?.find((p: { instagram_business_account?: { id: string } }) => p.instagram_business_account)
        ?.instagram_business_account?.id ?? "";
      if (yo) await guardar("ig_user_id", yo);
    }
    if (!yo) return Response.json({ ok: false, error: "Falta IG_USER_ID en Secrets" }, { status: 500 });
  }

  // Renovar el token de Instagram cada 7 días (dura 60). El de Facebook (SUAT) no caduca.
  const renovado = get("token_renovado");
  if (!esFB && (!renovado || Date.now() - Date.parse(renovado) > 7 * 864e5)) {
    const r = await fetch(`${IG}/refresh_access_token?grant_type=ig_refresh_token&access_token=${token}`);
    if (r.ok) {
      const j = await r.json();
      token = j.access_token;
      await guardar("token", token!);
      await guardar("token_renovado", new Date().toISOString());
    }
  }

  // Vídeo a leer: el que fijes en ig_config.media_id, o el último publicado
  let mediaId = get("media_id");
  if (!mediaId) {
    const r = await fetch(`${API}/${yo}/media?fields=id,timestamp&limit=1&access_token=${token}`);
    const j = await r.json();
    if (!r.ok) return Response.json({ ok: false, error: j.error?.message ?? "Error leyendo vídeos" }, { status: 502 });
    mediaId = j.data?.[0]?.id ?? null;
  }
  if (!mediaId) return Response.json({ ok: true, guardados: 0, nota: "Todavía no hay vídeos" });

  // Leer todos los comentarios con sus likes (paginando)
  const filas: Record<string, unknown>[] = [];
  let url: string | null =
    `${API}/${mediaId}/comments?fields=id,text,like_count,username,timestamp&limit=50&access_token=${token}`;
  while (url && filas.length < 5000) {
    const r = await fetch(url);
    const j = await r.json();
    if (!r.ok) return Response.json({ ok: false, error: j.error?.message ?? "Error leyendo comentarios" }, { status: 502 });
    for (const c of j.data ?? []) {
      filas.push({
        id: c.id,
        media_id: mediaId,
        username: c.username ?? null,
        texto: c.text ?? "",
        nombre: limpiar(c.text ?? ""),
        likes: c.like_count ?? 0,
        creado: c.timestamp,
        actualizado: new Date().toISOString(),
      });
    }
    url = j.paging?.next ?? null;
  }

  // Guardar (sin tocar la columna "oculto", que la decide el admin)
  for (let i = 0; i < filas.length; i += 500) {
    const { error } = await sb.from("ig_comentarios").upsert(filas.slice(i, i + 500), { onConflict: "id" });
    if (error) return Response.json({ ok: false, error: error.message }, { status: 500 });
  }
  await guardar("ultima_lectura", new Date().toISOString());

  return Response.json({ ok: true, video: mediaId, guardados: filas.length });
});
