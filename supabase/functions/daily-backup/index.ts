// Ежедневная резервная копия: все таблицы public -> private-бакет backups/ГГГГ-ММ-ДД.json.gz.
// Запускается из pg_cron (задача daily-backup) с токеном из Vault; хранит последние 60 копий.
import { createClient } from "jsr:@supabase/supabase-js@2";

const KEEP_DAYS = 60;

Deno.serve(async (req) => {
  const token = req.headers.get("x-backup-token") ?? "";
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const snap = await db.rpc("backup_snapshot", { p_token: token });
  if (snap.error) {
    const status = /forbidden/.test(snap.error.message) ? 403 : 500;
    return Response.json({ ok: false, error: status === 403 ? "forbidden" : snap.error.message }, { status });
  }

  const json = JSON.stringify(snap.data);
  const gz = await new Response(
    new Blob([json]).stream().pipeThrough(new CompressionStream("gzip")),
  ).arrayBuffer();
  const day = new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Moscow" });
  const up = await db.storage.from("backups").upload(`${day}.json.gz`, gz, {
    contentType: "application/gzip",
    upsert: true,
  });
  if (up.error) return Response.json({ ok: false, error: up.error.message }, { status: 500 });

  // Удаляем копии старше KEEP_DAYS дней.
  const list = await db.storage.from("backups").list("", { limit: 1000 });
  const cutoff = new Date(Date.now() - KEEP_DAYS * 86400000).toISOString().slice(0, 10);
  const old = (list.data ?? []).map((f) => f.name).filter((n) => /^\d{4}-\d{2}-\d{2}\.json\.gz$/.test(n) && n.slice(0, 10) < cutoff);
  if (old.length) await db.storage.from("backups").remove(old);

  const tables = snap.data?.tables ?? {};
  const rows = Object.values(tables).reduce((a: number, t) => a + (Array.isArray(t) ? t.length : 0), 0);
  return Response.json({ ok: true, file: `${day}.json.gz`, tables: Object.keys(tables).length, rows, bytes: gz.byteLength, removed: old.length });
});
