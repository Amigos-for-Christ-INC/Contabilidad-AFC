-- =====================================================================
-- Simulación de datos ficticios — BORRAR TODO LO SIMULADO
-- Borra únicamente las filas que anotó la simulación (tabla _simulacion),
-- las marcas y permisos SIM- y las funciones y tablas de la simulación.
-- Los datos reales no se tocan.
-- =====================================================================
begin;
set local session_replication_role = replica;   -- sin disparadores ni validaciones mientras se borra

create temporary table _sim_ids on commit drop as select tabla, clave from _simulacion;
create index on _sim_ids (tabla, clave);

delete from planilla_tokens  where planilla_id::text in (select clave from _sim_ids where tabla = 'planilla_tokens');
delete from existencias      where producto_id || '-' || bodega_id in (select clave from _sim_ids where tabla = 'existencias');

do $$
declare t text;
begin
  foreach t in array array['depreciacion_lineas','depreciaciones','activos_fijos','inv_kardex','inv_movimiento_lineas','inv_movimientos',
    'productos','categorias_producto','bodegas','cheque_lineas','cheques','ahorro_movimientos','vacaciones_movimientos',
    'planilla_novedades','planilla_lineas','planillas','asiento_lineas','asientos','empleados','cuentas_bancarias',
    'planilla_parametros','bitacora'] loop
    execute format('delete from %I where id::text in (select clave from _sim_ids where tabla = %L)', t, t);
  end loop;
end $$;

delete from marcaje_marcas   where id_externo like 'SIM-%';
delete from marcaje_permisos where id_externo like 'SIM-P%';
-- períodos y cuentas que creó la simulación, solo si quedaron sin movimientos
delete from periodos p where anio || '-' || mes in (select clave from _sim_ids where tabla = 'periodos')
   and not exists (select 1 from asientos a where a.anio = p.anio and a.mes = p.mes);
delete from cuentas c where id::text in (select clave from _sim_ids where tabla = 'cuentas')
   and not exists (select 1 from asiento_lineas l where l.cuenta_id = c.id);

-- Quitar las herramientas de la simulación
do $$
declare t text; f text;
begin
  for t in select c.relname from pg_trigger g join pg_class c on c.oid = g.tgrelid where g.tgname = 'zz_sim_capturar' loop
    execute format('drop trigger zz_sim_capturar on %I', t);
  end loop;
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'sim\_%' or p.proname like '\_sim\_%') loop
    execute 'drop function ' || f;
  end loop;
end $$;
drop table _simulacion;
drop table _simulacion_salidas;

commit;
select 'Simulación borrada' as resultado, pg_size_pretty(pg_database_size(current_database())) as tamano_actual;
