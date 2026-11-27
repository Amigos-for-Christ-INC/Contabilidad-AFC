-- =====================================================================
-- Simulación de datos ficticios — Paso 1: preparar
-- Crea el registro de todo lo que la simulación inserta, para poder
-- borrarlo después sin tocar los datos reales (ver sim-9-borrar.sql).
-- No inserta datos todavía.
-- =====================================================================
create table if not exists _simulacion (
  tabla text not null,
  clave text not null,
  primary key (tabla, clave)
);
revoke all on _simulacion from anon, authenticated;
alter table _simulacion enable row level security;

create table if not exists _simulacion_salidas (empleado_id bigint primary key, fecha date not null, motivo text not null);
revoke all on _simulacion_salidas from anon, authenticated;
alter table _simulacion_salidas enable row level security;

-- Anota cada fila que inserta la simulación (solo dentro de las funciones sim_*)
create or replace function _sim_capturar() returns trigger language plpgsql as $$
declare j jsonb;
begin
  if current_setting('sim.activo', true) = '1' then
    j := to_jsonb(new);
    insert into _simulacion (tabla, clave)
    values (tg_table_name, coalesce(j->>'id', j->>'id_externo', (j->>'producto_id') || '-' || (j->>'bodega_id'),
                                    (j->>'anio') || '-' || (j->>'mes'), j->>'planilla_id'))
    on conflict do nothing;
  end if;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['asientos','asiento_lineas','periodos','empleados','planillas','planilla_lineas','planilla_novedades',
    'vacaciones_movimientos','ahorro_movimientos','cheques','cheque_lineas','cuentas_bancarias','bodegas','categorias_producto',
    'productos','existencias','inv_movimientos','inv_movimiento_lineas','inv_kardex','activos_fijos','depreciaciones',
    'depreciacion_lineas','marcaje_permisos','bitacora','planilla_tokens','planilla_parametros','cuentas'] loop
    execute format('drop trigger if exists zz_sim_capturar on %I', t);
    execute format('create trigger zz_sim_capturar after insert on %I for each row execute function _sim_capturar()', t);
  end loop;
end $$;

-- Activa la captura y actúa como un administrador (solo dura lo que dura la llamada)
create or replace function _sim_contexto() returns uuid language plpgsql as $$
declare v uuid;
begin
  select p.id into v from perfiles p join roles r on r.id = p.rol_id where r.nombre = 'Administrador' order by p.id limit 1;
  if v is null then raise exception 'No hay un usuario Administrador para la simulación'; end if;
  perform set_config('sim.activo', '1', true);
  perform set_config('request.jwt.claim.sub', v::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  return v;
end $$;

create or replace function _sim_azar(a numeric, b numeric) returns numeric language sql volatile as $$ select a + random() * (b - a) $$;
create or replace function _sim_uno(arr text[]) returns text language sql volatile as $$ select arr[1 + floor(random() * array_length(arr, 1))::int] $$;
create or replace function _sim_cuenta(p_like text) returns bigint language sql volatile as $$
  select id from cuentas where acepta_movimientos and activa and codigo like p_like order by random() limit 1 $$;

revoke execute on function _sim_capturar(), _sim_contexto(), _sim_azar(numeric, numeric), _sim_uno(text[]), _sim_cuenta(text) from public, anon, authenticated;

select 'Simulación preparada' as resultado;
