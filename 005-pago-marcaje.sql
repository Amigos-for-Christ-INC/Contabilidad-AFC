-- =====================================================================
-- Contabilidad AFC — Migración 005: "Mi pago" en la app de marcaje
-- Ejecutar después de 004-planilla-marcaje.sql.
--
-- La app de marcaje (Apps Script) pide aquí el pago de UN colaborador:
-- el servidor del marcaje valida la sesión del trabajador y solo pregunta
-- por el correo de quien inició sesión. Se usa la misma clave de
-- integración del puente; sin clave válida no devuelve nada.
-- =====================================================================
begin;

create or replace function pago_colaborador(p_clave text, p_correo text, p_anio int, p_mes int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  e empleados%rowtype; v_ini date; v_fin date; v_saldo numeric; v_planillas jsonb;
begin
  if not exists (select 1 from integracion_claves
                  where hash = _hash_clave(regexp_replace(coalesce(p_clave, ''), '^afc_', '')) and activa) then
    raise exception 'Clave de integración no válida';
  end if;
  if p_mes not between 1 and 12 or p_anio not between 2000 and 2100 then raise exception 'Mes no válido'; end if;
  select * into e from empleados where correo = lower(trim(p_correo));
  if not found then return jsonb_build_object('encontrado', false); end if;

  v_ini := make_date(p_anio, p_mes, 1);
  v_fin := (v_ini + interval '1 month - 1 day')::date;

  select coalesce(sum(dias), 0) into v_saldo from vacaciones_movimientos where empleado_id = e.id and estado = 'aprobado';

  -- Planillas aprobadas cuyo pago cae en el mes
  select coalesce(jsonb_agg(x order by x->>'fecha_pago', x->>'desde'), '[]') into v_planillas from (
    select jsonb_build_object(
      'descripcion', p.descripcion, 'desde', p.desde, 'hasta', p.hasta, 'fecha_pago', p.fecha_pago, 'tipo', p.tipo,
      'dias_pagados', case when l.salario_mensual > 0 then round(l.salario_periodo * 30 / l.salario_mensual, 2) else 0 end,
      'salario', l.salario_periodo, 'otros_ingresos', l.ingresos, 'bruto', l.bruto,
      'inss', l.inss_laboral, 'ir', l.ir, 'otras_deducciones', l.deducciones, 'neto', l.neto,
      'novedades', coalesce((select jsonb_agg(jsonb_build_object('concepto', c.nombre, 'tipo', c.tipo, 'monto', n.monto, 'detalle', n.descripcion) order by c.tipo, n.id)
                               from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id
                              where n.planilla_id = p.id and n.empleado_id = e.id), '[]')
    ) x
      from planillas p join planilla_lineas l on l.planilla_id = p.id and l.empleado_id = e.id
     where p.estado = 'aprobada' and p.fecha_pago between v_ini and v_fin
  ) s;

  return jsonb_build_object(
    'encontrado', true, 'nombre', e.nombre, 'cargo', e.cargo, 'tipo_pago', e.tipo_pago,
    'salario_mensual', e.salario_mensual, 'anio', p_anio, 'mes', p_mes,
    'planillas', v_planillas,
    'total_bruto',       (select coalesce(sum((x->>'bruto')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_inss',        (select coalesce(sum((x->>'inss')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_ir',          (select coalesce(sum((x->>'ir')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_deducciones', (select coalesce(sum((x->>'otras_deducciones')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_neto',        (select coalesce(sum((x->>'neto')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'vacaciones_saldo', round(v_saldo, 2));
end $$;

revoke execute on function pago_colaborador(text, text, int, int) from public;
grant execute on function pago_colaborador(text, text, int, int) to anon, authenticated;

commit;
