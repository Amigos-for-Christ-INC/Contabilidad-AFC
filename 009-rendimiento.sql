-- =====================================================================
-- Contabilidad AFC — Migración 009: rendimiento con muchos datos
-- Ejecutar después de 008-plan-ahorro.sql.
--
-- Con tres años de datos simulados (17,000 asientos, 130,000 marcas,
-- 78,000 registros de bitácora) la bitácora no cargaba y algunos
-- reportes tardaban 3 segundos. Esta migración:
--   1. Hace que las reglas de acceso (RLS) verifiquen el permiso una vez por
--      consulta y no una vez por fila (recomendación oficial de Supabase).
--   2. Agrega índices para las consultas más usadas.
-- No cambia datos ni permisos.
-- =====================================================================
begin;

-- 1. Permisos evaluados una sola vez por consulta: tiene_permiso('x') → (select tiene_permiso('x'))
do $$
declare p record; v_using text; v_check text; patron text := '(?<!select )\m(tiene_permiso|puede_editar|es_admin|mis_permisos)\(([^()]*)\)';
begin
  for p in select schemaname, tablename, policyname, qual, with_check from pg_policies where schemaname = 'public' loop
    v_using := case when p.qual is not null then regexp_replace(p.qual, patron, '(select \1(\2))', 'gi') end;
    v_check := case when p.with_check is not null then regexp_replace(p.with_check, patron, '(select \1(\2))', 'gi') end;
    if v_using is distinct from p.qual or v_check is distinct from p.with_check then
      execute format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename)
           || case when v_using is not null then format(' using (%s)', v_using) else '' end
           || case when v_check is not null then format(' with check (%s)', v_check) else '' end;
    end if;
  end loop;
end $$;

-- 2. Índices
create index if not exists bitacora_fecha_idx            on bitacora (fecha desc);
create index if not exists bitacora_tabla_idx            on bitacora (tabla, fecha desc);
create index if not exists asientos_anio_mes_idx         on asientos (anio, mes);
create index if not exists asientos_fecha_numero_idx     on asientos (fecha desc, numero desc);
create index if not exists cheques_cuenta_fecha_idx      on cheques (cuenta_bancaria_id, fecha);
create index if not exists inv_kardex_bodega_prod_idx    on inv_kardex (bodega_id, producto_id, fecha);
create index if not exists inv_mov_lineas_producto_idx   on inv_movimiento_lineas (producto_id);
create index if not exists vacaciones_empleado_idx       on vacaciones_movimientos (empleado_id, estado);
create index if not exists vacaciones_planilla_idx       on vacaciones_movimientos (planilla_id);
create index if not exists vacaciones_fecha_idx          on vacaciones_movimientos (fecha desc, id desc);
create index if not exists ahorro_planilla_idx           on ahorro_movimientos (planilla_id);
create index if not exists ahorro_fecha_idx              on ahorro_movimientos (fecha desc, id desc);
create index if not exists planilla_lineas_empleado_idx  on planilla_lineas (empleado_id);
create index if not exists planilla_novedades_pl_idx     on planilla_novedades (planilla_id, empleado_id);
create index if not exists planillas_desde_idx           on planillas (desde desc, id desc);
create index if not exists marcaje_marcas_fecha_idx      on marcaje_marcas (fecha);
create index if not exists depreciacion_lineas_act_idx   on depreciacion_lineas (activo_id);

analyze;
commit;
