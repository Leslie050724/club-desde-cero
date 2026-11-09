-- ============================================================
--  CLUB DESDE CERO · Entrar con el @ además del correo
--  Pegar entero en Supabase → SQL Editor → New query → Run
-- ============================================================

-- Intentos fallidos, para frenar a quien pruebe contraseñas a lo loco
create table if not exists public.login_intentos (
  ig      citext not null,
  cuando  timestamptz not null default now()
);
alter table public.login_intentos enable row level security;
revoke all on public.login_intentos from anon, authenticated;

-- Devuelve el correo SOLO si la contraseña es correcta.
-- Con una contraseña mala no devuelve nada, así nadie puede sacar el correo de otro.
create or replace function public.correo_para_entrar(p_ig text, p_pass text) returns text
language plpgsql security definer set search_path = public, extensions, auth as $$
declare v_ig citext := trim(both '@' from trim(p_ig)); v_email text; v_hash text;
begin
  if (select count(*) from public.login_intentos
      where ig = v_ig and cuando > now() - interval '15 minutes') >= 5 then
    raise exception 'Demasiados intentos. Espera 15 minutos y vuelve a probar.';
  end if;

  select u.email, u.encrypted_password into v_email, v_hash
    from auth.users u join public.socios s on s.id = u.id
    where s.ig = v_ig;

  if v_hash is not null and v_hash = extensions.crypt(p_pass, v_hash) then
    delete from public.login_intentos where ig = v_ig;
    return v_email;
  end if;

  insert into public.login_intentos (ig) values (v_ig);
  delete from public.login_intentos where cuando < now() - interval '1 day';
  return null;
end $$;

revoke all on function public.correo_para_entrar(text, text) from public;
grant execute on function public.correo_para_entrar(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
