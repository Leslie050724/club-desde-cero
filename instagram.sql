-- ============================================================
--  CLUB DESDE CERO · Comentarios de Instagram
--  Pegar entero en Supabase → SQL Editor → New query → Run
--  ⚠️ Antes, cambia PON_AQUI_TU_CLAVE_SECRETA (abajo del todo)
--     por la misma clave que pongas en Edge Functions → Secrets → CRON_SECRET
-- ============================================================

create table if not exists public.ig_comentarios (
  id          text primary key,
  media_id    text not null,
  username    text,
  texto       text not null default '',
  nombre      text,
  likes       int  not null default 0,
  creado      timestamptz,
  actualizado timestamptz not null default now(),
  oculto      boolean not null default false
);

-- Ajustes internos (token renovado, vídeo a leer…). Nadie los ve desde la web.
create table if not exists public.ig_config (
  clave text primary key,
  valor text
);

alter table public.ig_comentarios enable row level security;
alter table public.ig_config      enable row level security;
revoke all on public.ig_comentarios, public.ig_config from anon, authenticated;
grant select, insert, update, delete on public.ig_comentarios, public.ig_config to service_role;

-- Lo que ve la web: nombres propuestos en Instagram, agrupados, con sus likes
create or replace view public.v_ig_propuestas as
  select lower(nombre)                                     as clave,
         (array_agg(nombre   order by creado))[1]          as nombre,
         (array_agg(username order by creado))[1]          as autor,
         count(*)::int                                     as comentarios,
         sum(likes)::int                                   as likes
  from public.ig_comentarios
  where nombre is not null and not oculto
  group by lower(nombre);

grant select on public.v_ig_propuestas to anon, authenticated;

-- Admin: ocultar un nombre de Instagram (feo o de broma)
create or replace function public.admin_ocultar_ig(p_clave text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  update ig_comentarios set oculto = true where lower(nombre) = lower(p_clave);
end $$;

-- Admin: elegir qué vídeo se lee (si no, se lee el último publicado)
create or replace function public.admin_video_ig(p_media_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  if coalesce(trim(p_media_id), '') = '' then delete from ig_config where clave = 'media_id';
  else insert into ig_config values ('media_id', trim(p_media_id))
       on conflict (clave) do update set valor = excluded.valor; end if;
end $$;

-- Admin: cuándo se leyó Instagram por última vez
create or replace function public.admin_estado_ig() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  return json_build_object(
    'ultima_lectura', (select valor from ig_config where clave = 'ultima_lectura'),
    'comentarios',    (select count(*) from ig_comentarios));
end $$;

revoke all on function public.admin_ocultar_ig(text), public.admin_video_ig(text), public.admin_estado_ig() from public, anon;
grant execute on function public.admin_ocultar_ig(text), public.admin_video_ig(text), public.admin_estado_ig() to authenticated;

-- Cron: llamar a la función cada 5 minutos
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule('leer-instagram') where exists (select 1 from cron.job where jobname = 'leer-instagram');
select cron.schedule(
  'leer-instagram',
  '*/5 * * * *',
  $$
  select net.http_post(
    url     := 'https://hfifwigvumvxrnljubhk.supabase.co/functions/v1/leer-instagram',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer sb_publishable_5yWCC5MruLVrLlpwAkC2KA_lAFp5t8x',
                                  'apikey', 'sb_publishable_5yWCC5MruLVrLlpwAkC2KA_lAFp5t8x',
                                  'x-cron-secret', 'PON_AQUI_TU_CLAVE_SECRETA'),
    body    := '{}'::jsonb
  );
  $$
);

notify pgrst, 'reload schema';
