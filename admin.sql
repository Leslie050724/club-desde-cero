-- ============================================================
--  CLUB DESDE CERO · Administración
--  Pegar entero en Supabase → SQL Editor → New query → Run
-- ============================================================

-- 1) Columna de admin (nadie puede cambiarla desde la web)
alter table public.socios add column if not exists es_admin boolean not null default false;

-- 2) Tu cuenta es la de admin
update public.socios set es_admin = true where ig = 'club.desdecero';

-- Comprobación interna
create or replace function public._soy_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select es_admin from public.socios where id = auth.uid()), false);
$$;

-- 3) Mi perfil ahora dice si eres admin
create or replace function public.mi_perfil() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'numero', s.numero, 'ig', s.ig::text, 'pais', s.pais, 'provincia', s.provincia,
    'puntos', s.puntos, 'verificado', s.verificado, 'creado', s.creado, 'es_admin', s.es_admin,
    'codigo', c.codigo,
    'propuesta', (select nombre from propuestas where autor = s.id),
    'apoyados', coalesce((select json_agg(a.propuesta_id) from apoyos a where a.socio_id = s.id), '[]'::json),
    'apoyos_usados', (select count(*) from apoyos a join propuestas p on p.id = a.propuesta_id
                      where a.socio_id = s.id and p.autor <> s.id)
  )
  from socios s left join codigos c on c.socio_id = s.id
  where s.id = auth.uid();
$$;

-- 4) Socios sin activar, con su código (solo admin)
create or replace function public.admin_pendientes() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  return coalesce((select json_agg(x order by x.numero) from (
    select s.numero, s.ig::text as ig, s.pais, s.provincia, c.codigo, s.creado
    from socios s left join codigos c on c.socio_id = s.id
    where not s.verificado) x), '[]'::json);
end $$;

-- 5) Activar carnet con el código que te mandan por DM (+10 puntos)
create or replace function public.admin_activar(p_codigo text) returns text
language plpgsql security definer set search_path = public as $$
declare v_ig text;
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  update socios s set verificado = true, puntos = puntos + 10
    from codigos c
    where c.socio_id = s.id and c.codigo = upper(trim(p_codigo)) and not s.verificado
    returning s.ig::text into v_ig;
  if v_ig is null then raise exception 'Código no encontrado o ya activado'; end if;
  return v_ig;
end $$;

-- 6) Dar o quitar puntos a un socio
create or replace function public.admin_puntos(p_ig text, p_cantidad int) returns int
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  update socios set puntos = greatest(0, puntos + p_cantidad)
    where ig = trim(both '@' from trim(p_ig))::citext returning puntos into v;
  if v is null then raise exception 'No existe ese socio'; end if;
  return v;
end $$;

-- 7) Borrar una propuesta (nombres feos o de broma)
create or replace function public.admin_borrar_propuesta(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  delete from propuestas where id = p_id;
end $$;

-- 8) Borrar un socio entero (cuando te piden BORRAR por DM)
create or replace function public.admin_borrar_socio(p_ig text) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  select id into v_id from public.socios where ig = trim(both '@' from trim(p_ig))::citext;
  if v_id is null then raise exception 'No existe ese socio'; end if;
  if v_id = auth.uid() then raise exception 'No puedes borrar tu propia cuenta de admin'; end if;
  delete from auth.users where id = v_id;
end $$;

revoke all on function public._soy_admin(), public.admin_pendientes(), public.admin_activar(text),
  public.admin_puntos(text,int), public.admin_borrar_propuesta(bigint), public.admin_borrar_socio(text)
  from public, anon, authenticated;
grant execute on function public.mi_perfil(), public.admin_pendientes(), public.admin_activar(text),
  public.admin_puntos(text,int), public.admin_borrar_propuesta(bigint), public.admin_borrar_socio(text)
  to authenticated;

notify pgrst, 'reload schema';

-- Debe devolver una fila con tu @ y es_admin = true
select ig, es_admin from public.socios where es_admin;
