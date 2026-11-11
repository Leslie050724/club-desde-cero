-- ============================================================
--  CLUB DESDE CERO · Votaciones (Día 2: los colores)
--  Pegar entero en Supabase → SQL Editor → New query → Run
-- ============================================================

create table if not exists public.votaciones (
  id        text primary key,
  titulo    text not null,
  opciones  jsonb not null,
  abierta   boolean not null default true,
  creada    timestamptz not null default now()
);

create table if not exists public.votos (
  votacion_id text references public.votaciones on delete cascade,
  socio_id    uuid references public.socios on delete cascade,
  opcion      int not null,
  creado      timestamptz not null default now(),
  primary key (votacion_id, socio_id)
);

alter table public.votaciones enable row level security;
alter table public.votos      enable row level security;
revoke all on public.votaciones, public.votos from anon, authenticated;
grant all on public.votaciones, public.votos to service_role;

insert into public.votaciones (id, titulo, opciones) values
  ('colores', '¿De qué color es el Deportivo de los Volcanes?', '["Negro y blanco", "Rojo y negro"]')
on conflict (id) do nothing;

-- Resultados públicos
create or replace view public.v_votos as
  select v.id as votacion_id, v.titulo, v.abierta, o.idx::int as opcion, o.txt as texto,
         (select count(*) from public.votos x where x.votacion_id = v.id and x.opcion = o.idx)::int as votos
  from public.votaciones v,
       lateral jsonb_array_elements_text(v.opciones) with ordinality as o(txt, idx);

-- Las estadísticas de arriba ahora cuentan apoyos + votos
create or replace view public.v_stats as
  select (select count(*) from public.socios where not es_admin)::int             as socios,
         (select count(distinct pais) from public.socios where not es_admin)::int as paises,
         ((select count(*) from public.apoyos) + (select count(*) from public.votos))::int as apoyos;

grant select on public.v_votos, public.v_stats to anon, authenticated;

-- Votar (1 voto por socio y votación, +5 puntos)
create or replace function public.votar(p_votacion text, p_opcion int) returns void
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not exists (select 1 from socios where id = auth.uid()) then raise exception 'Hazte socio para votar'; end if;
  select jsonb_array_length(opciones) into v_n from votaciones where id = p_votacion and abierta;
  if v_n is null then raise exception 'Esta votación está cerrada'; end if;
  if p_opcion < 1 or p_opcion > v_n then raise exception 'Opción no válida'; end if;
  insert into votos (votacion_id, socio_id, opcion) values (p_votacion, auth.uid(), p_opcion);
  update socios set puntos = puntos + 5 where id = auth.uid();
exception when unique_violation then raise exception 'Ya has votado';
end $$;

-- Mi voto en una votación (o null)
create or replace function public.mi_voto(p_votacion text) returns int
language sql stable security definer set search_path = public as $$
  select opcion from votos where votacion_id = p_votacion and socio_id = auth.uid();
$$;

-- Admin: abrir o cerrar una votación
create or replace function public.admin_votacion(p_votacion text, p_abierta boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _soy_admin() then raise exception 'Solo el admin puede hacer esto'; end if;
  update votaciones set abierta = p_abierta where id = p_votacion;
end $$;

revoke all on function public.votar(text,int), public.mi_voto(text), public.admin_votacion(text,boolean) from public, anon;
grant execute on function public.votar(text,int), public.mi_voto(text), public.admin_votacion(text,boolean) to authenticated;

notify pgrst, 'reload schema';

-- Debe salir la votación de los colores con 2 opciones
select * from public.v_votos;
