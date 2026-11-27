-- =====================================================================
-- Contabilidad AFC — Migración 010: inventario rápido con muchos movimientos
-- Ejecutar después de 009-rendimiento.sql.
-- Las reglas de acceso por bodega se evaluaban fila por fila (12 s para
-- 4,000 movimientos). Ahora se resuelven una vez por consulta.
-- Mismo resultado: cada quien ve solo sus bodegas, salvo quien tiene
-- "inventario.todas_bodegas".
-- =====================================================================
begin;

create or replace function mis_bodegas() returns bigint[]
language sql stable security definer set search_path = public as $$
  select case when tiene_permiso('inventario.todas_bodegas') then (select array_agg(id) from bodegas)
              else coalesce((select array_agg(bodega_id) from perfil_bodegas where perfil_id = auth.uid()), '{}') end
$$;
revoke execute on function mis_bodegas() from public, anon;
grant execute on function mis_bodegas() to authenticated;

drop policy leer on existencias;
drop policy leer on inv_kardex;
drop policy leer on inv_movimientos;
drop policy leer on inv_movimiento_lineas;
create policy leer on existencias for select to authenticated
  using ((select tiene_permiso('inventario.ver')) and bodega_id in (select unnest(mis_bodegas())));
create policy leer on inv_kardex for select to authenticated
  using ((select tiene_permiso('inventario.ver')) and bodega_id in (select unnest(mis_bodegas())));
create policy leer on inv_movimientos for select to authenticated
  using ((select tiene_permiso('inventario.ver')) and (bodega_id in (select unnest(mis_bodegas())) or bodega_destino_id in (select unnest(mis_bodegas()))));
create policy leer on inv_movimiento_lineas for select to authenticated
  using (movimiento_id in (select id from inv_movimientos));

commit;
