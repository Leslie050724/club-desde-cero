-- ============================================================
--  CLUB DESDE CERO · Enlace de invitación (+15 puntos)
--  Pegar entero en Supabase → SQL Editor → New query → Run
-- ============================================================

alter table public.socios add column if not exists invitado_por uuid references public.socios on delete set null;
alter table public.socios add column if not exists invitacion_pagada boolean not null default false;

-- Hacerse socio, ahora con el @ de quien te invitó (opcional)
drop function if exists public.hacerse_socio(text, text, text);
create or replace function public.hacerse_socio(p_ig text, p_pais text, p_provincia text, p_ref text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_num bigint; v_cod text; v_ref uuid;
begin
  if auth.uid() is null then raise exception 'Tienes que entrar con tu cuenta'; end if;
  if exists (select 1 from socios where id = auth.uid()) then raise exception 'Ya eres socio'; end if;
  if coalesce(trim(p_ref), '') <> '' then
    select id into v_ref from socios where ig = trim(both '@' from trim(p_ref))::citext;
  end if;
  insert into socios (id, ig, pais, provincia, invitado_por)
    values (auth.uid(), trim(both '@' from trim(p_ig)), upper(p_pais), trim(p_provincia), v_ref)
    returning numero into v_num;
  loop
    v_cod := 'SOCIO-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 5));
    begin
      insert into codigos values (auth.uid(), v_cod); exit;
    exception when unique_violation then null;
    end;
  end loop;
  return json_build_object('numero', v_num, 'codigo', v_cod);
end $$;

-- Al activar un carnet, quien le invitó gana +15 (una sola vez por invitado)
create or replace function public.admin_activar(p_codigo text) returns text
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_ig text; v_ref uuid; v_pagada boolean;
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  update socios s set verificado = true, puntos = puntos + 10
    from codigos c
    where c.socio_id = s.id and c.codigo = upper(trim(p_codigo)) and not s.verificado
    returning s.id, s.ig::text, s.invitado_por, s.invitacion_pagada into v_id, v_ig, v_ref, v_pagada;
  if v_ig is null then raise exception 'Código no encontrado o ya activado'; end if;
  if v_ref is not null and not v_pagada then
    update socios set puntos = puntos + 15 where id = v_ref;
    update socios set invitacion_pagada = true where id = v_id;
  end if;
  return v_ig;
end $$;

-- Mi perfil: ahora con cuántos amigos has traído
create or replace function public.mi_perfil() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'numero', (select count(*) from socios s2 where not s2.es_admin and s2.numero <= s.numero),
    'ig', s.ig::text, 'pais', s.pais, 'provincia', s.provincia,
    'puntos', s.puntos, 'verificado', s.verificado, 'creado', s.creado, 'es_admin', s.es_admin,
    'codigo', c.codigo,
    'propuesta', (select nombre from propuestas where autor = s.id),
    'apoyados', coalesce((select json_agg(a.propuesta_id) from apoyos a where a.socio_id = s.id), '[]'::json),
    'apoyos_usados', (select count(*) from apoyos a join propuestas p on p.id = a.propuesta_id
                      where a.socio_id = s.id and p.autor <> s.id),
    'invitados', (select count(*) from socios i where i.invitado_por = s.id),
    'invitados_activos', (select count(*) from socios i where i.invitado_por = s.id and i.invitacion_pagada)
  )
  from socios s left join codigos c on c.socio_id = s.id
  where s.id = auth.uid();
$$;

revoke all on function public.hacerse_socio(text,text,text,text), public.admin_activar(text) from public, anon;
grant execute on function public.hacerse_socio(text,text,text,text), public.mi_perfil(), public.admin_activar(text) to authenticated;

notify pgrst, 'reload schema';
