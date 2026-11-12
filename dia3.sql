-- ============================================================
--  CLUB DESDE CERO · Día 3: el escudo
--  Pegar entero en Supabase → SQL Editor → New query → Run
-- ============================================================

-- Se cierra la votación de los colores (ganó Rojo y negro)
update public.votaciones set abierta = false where id = 'colores';

-- Se abre la del escudo
insert into public.votaciones (id, titulo, opciones) values
  ('escudo', '¿Cuál será el escudo del Deportivo de los Volcanes?', '["Clásico", "Moderno"]')
on conflict (id) do update set abierta = true;

notify pgrst, 'reload schema';

-- Debe salir la votación del escudo con 2 opciones
select votacion_id, abierta, opcion, texto, votos from public.v_votos where votacion_id = 'escudo';
