-- ============================================================
--  CLUB DESDE CERO · Las cuentas de admin no cuentan en rankings
--  Pegar entero en Supabase → SQL Editor → New query → Run
-- ============================================================

create or replace view public.v_socios as
  select numero, ig::text as ig, pais, provincia, puntos, verificado, creado
  from public.socios where not es_admin;

create or replace view public.v_provincias as
  select pais, provincia, count(*)::int as socios
  from public.socios where not es_admin group by pais, provincia;

create or replace view public.v_stats as
  select (select count(*) from public.socios where not es_admin)::int             as socios,
         (select count(distinct pais) from public.socios where not es_admin)::int as paises,
         (select count(*) from public.apoyos)::int                                as apoyos;

-- Número de socio sin contar al admin (el primer socio real es el nº 1)
create or replace function public.mi_perfil() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'numero', (select count(*) from socios s2 where not s2.es_admin and s2.numero <= s.numero), 'ig', s.ig::text, 'pais', s.pais, 'provincia', s.provincia,
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

notify pgrst, 'reload schema';

-- Debe salir 0 socios y 0 países
select * from public.v_stats;
