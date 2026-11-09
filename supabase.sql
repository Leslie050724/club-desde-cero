-- ============================================================
--  CLUB DESDE CERO · Base de datos
--  Pegar entero en Supabase → SQL Editor → New query → Run
-- ============================================================

create extension if not exists citext;

-- ---------- TABLAS ----------

-- Un socio por cuenta (la contraseña la guarda Supabase Auth, cifrada)
create table public.socios (
  id          uuid primary key references auth.users on delete cascade,
  numero      bigint generated always as identity unique,
  ig          citext unique not null check (ig ~ '^[a-zA-Z0-9._]{2,30}$'),
  pais        text not null check (pais ~ '^[A-Z]{2}$'),
  provincia   text not null check (char_length(provincia) between 2 and 60),
  puntos      int  not null default 0,
  verificado  boolean not null default false,
  creado      timestamptz not null default now()
);

-- El código de socio es privado: solo lo ve su dueño
create table public.codigos (
  socio_id  uuid primary key references public.socios on delete cascade,
  codigo    text unique not null
);

-- Día 0: cada socio puede proponer UN nombre
create table public.propuestas (
  id      bigint generated always as identity primary key,
  nombre  text not null check (char_length(nombre) between 3 and 30),
  autor   uuid unique not null references public.socios on delete cascade,
  creado  timestamptz not null default now()
);
create unique index propuestas_nombre_unico on public.propuestas (lower(nombre));

-- Apoyos a propuestas (máximo 3 por socio, sin contar el suyo)
create table public.apoyos (
  propuesta_id  bigint references public.propuestas on delete cascade,
  socio_id      uuid   references public.socios on delete cascade,
  creado        timestamptz not null default now(),
  primary key (propuesta_id, socio_id)
);

-- Seguridad: nadie toca las tablas directamente desde la web
alter table public.socios     enable row level security;
alter table public.codigos    enable row level security;
alter table public.propuestas enable row level security;
alter table public.apoyos     enable row level security;
revoke all on public.socios, public.codigos, public.propuestas, public.apoyos from anon, authenticated;

-- ---------- VISTAS PÚBLICAS (solo lectura) ----------

create view public.v_socios as
  select numero, ig::text as ig, pais, provincia, puntos, verificado, creado
  from public.socios;

create view public.v_provincias as
  select pais, provincia, count(*)::int as socios
  from public.socios group by pais, provincia;

create view public.v_propuestas as
  select p.id, p.nombre, s.ig::text as autor,
         (select count(*) from public.apoyos a where a.propuesta_id = p.id)::int as apoyos,
         p.creado
  from public.propuestas p join public.socios s on s.id = p.autor;

create view public.v_stats as
  select (select count(*) from public.socios)::int                    as socios,
         (select count(distinct pais) from public.socios)::int        as paises,
         (select count(*) from public.apoyos)::int                    as apoyos;

grant select on public.v_socios, public.v_provincias, public.v_propuestas, public.v_stats to anon, authenticated;

-- ---------- FUNCIONES (las únicas que pueden escribir) ----------

-- ¿Está libre este @?
create or replace function public.ig_libre(p_ig text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.socios where ig = p_ig::citext);
$$;

-- Hacerse socio (después de crear la cuenta)
create or replace function public.hacerse_socio(p_ig text, p_pais text, p_provincia text)
returns json language plpgsql security definer set search_path = public as $$
declare v_num bigint; v_cod text;
begin
  if auth.uid() is null then raise exception 'Tienes que entrar con tu cuenta'; end if;
  if exists (select 1 from socios where id = auth.uid()) then raise exception 'Ya eres socio'; end if;
  insert into socios (id, ig, pais, provincia)
    values (auth.uid(), trim(both '@' from trim(p_ig)), upper(p_pais), trim(p_provincia))
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

-- Mi perfil (incluye mi código privado)
create or replace function public.mi_perfil() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'numero', s.numero, 'ig', s.ig::text, 'pais', s.pais, 'provincia', s.provincia,
    'puntos', s.puntos, 'verificado', s.verificado, 'creado', s.creado,
    'codigo', c.codigo,
    'propuesta', (select nombre from propuestas where autor = s.id),
    'apoyados', coalesce((select json_agg(a.propuesta_id) from apoyos a where a.socio_id = s.id), '[]'::json),
    'apoyos_usados', (select count(*) from apoyos a join propuestas p on p.id = a.propuesta_id
                      where a.socio_id = s.id and p.autor <> s.id)
  )
  from socios s left join codigos c on c.socio_id = s.id
  where s.id = auth.uid();
$$;

-- Proponer un nombre (1 por socio, +10 puntos)
create or replace function public.proponer_nombre(p_nombre text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not exists (select 1 from socios where id = auth.uid()) then raise exception 'Hazte socio para proponer'; end if;
  if exists (select 1 from propuestas where autor = auth.uid()) then raise exception 'Ya propusiste un nombre'; end if;
  if exists (select 1 from propuestas where lower(nombre) = lower(trim(p_nombre))) then raise exception 'Ese nombre ya está propuesto. Apóyalo en la lista'; end if;
  insert into propuestas (nombre, autor) values (regexp_replace(trim(p_nombre), '\s+', ' ', 'g'), auth.uid()) returning id into v_id;
  insert into apoyos (propuesta_id, socio_id) values (v_id, auth.uid());
  update socios set puntos = puntos + 10 where id = auth.uid();
end $$;

-- Apoyar una propuesta (máx. 3, +5 puntos cada una)
create or replace function public.apoyar(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from socios where id = auth.uid()) then raise exception 'Hazte socio para apoyar'; end if;
  if exists (select 1 from propuestas where id = p_id and autor = auth.uid()) then raise exception 'Tu propia propuesta ya cuenta con tu apoyo'; end if;
  if (select count(*) from apoyos a join propuestas p on p.id = a.propuesta_id
      where a.socio_id = auth.uid() and p.autor <> auth.uid()) >= 3 then
    raise exception 'Ya usaste tus 3 apoyos';
  end if;
  insert into apoyos (propuesta_id, socio_id) values (p_id, auth.uid());
  update socios set puntos = puntos + 5 where id = auth.uid();
exception when unique_violation then raise exception 'Ya apoyaste este nombre';
end $$;

revoke all on function public.ig_libre(text), public.hacerse_socio(text,text,text), public.mi_perfil(),
  public.proponer_nombre(text), public.apoyar(bigint) from public, anon, authenticated;
grant execute on function public.ig_libre(text) to anon, authenticated;
grant execute on function public.hacerse_socio(text,text,text), public.mi_perfil(),
  public.proponer_nombre(text), public.apoyar(bigint) to authenticated;

-- Recargar la API para que vea las funciones nuevas
notify pgrst, 'reload schema';
