-- =====================================================================
-- Contabilidad AFC — Migración 007: aguinaldo, liquidaciones y activos fijos
-- Ejecutar después de 006-pago-planilla.sql.
--
-- Aguinaldo (décimo tercer mes, Código del Trabajo):
--   * Período del 1 de diciembre al 30 de noviembre; se paga a más tardar el 10 de diciembre.
--   * Un mes de salario por año completo, proporcional a los días trabajados (año comercial de 360 días).
--   * Exento de IR (Ley 822, art. 19 num. 2) y no cotiza INSS ni INATEC.
--   * Es una planilla más (tipo 'aguinaldo'): se elabora, la aprueba otra persona,
--     se paga con el archivo BANPRO y se envían las colillas.
--
-- Liquidación (cuando alguien deja de trabajar):
--   * Salario pendiente, vacaciones no gozadas, aguinaldo proporcional e
--     indemnización por antigüedad (Código del Trabajo, art. 45): un mes por cada
--     uno de los tres primeros años y 20 días por cada año a partir del cuarto,
--     fracciones proporcionales, máximo cinco meses (mínimo un mes si es despido sin causa).
--   * La indemnización se marca según el motivo y se puede cambiar: despido sin causa
--     y renuncia con preaviso la pagan; despido con causa justa (art. 48) no.
--   * Hasta cinco meses de indemnización está exenta de IR (Ley 822, art. 19 num. 3).
--   * Es una planilla tipo 'liquidacion' de una sola persona; al aprobarla el
--     colaborador queda inactivo y su saldo de vacaciones en cero.
--
-- Activos fijos y depreciación:
--   * Línea recta: (costo − valor residual) ÷ vida útil en meses.
--   * Vidas útiles sugeridas del Reglamento de la Ley 822, art. 34 (se pueden cambiar).
--   * Cada mes se registra un asiento: gasto de depreciación contra depreciación acumulada.
--   * Al dar de baja (venta, robo o descarte) se registra el asiento de la baja.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Permisos
-- ---------------------------------------------------------------------
create or replace function permisos_validos() returns text[]
language sql immutable as $$
  select array['contabilidad.ver','contabilidad.editar','contabilidad.periodos',
               'inventario.ver','inventario.editar','inventario.anular','inventario.catalogo','inventario.todas_bodegas',
               'bancos.ver','bancos.emitir','bancos.aprobar','bancos.anular','bancos.cuentas',
               'planilla.ver','planilla.editar','planilla.aprobar','planilla.config','vacaciones.aprobar',
               'activos.ver','activos.editar',
               'admin.usuarios']
$$;

update roles set permisos = permisos || array['activos.ver','activos.editar']
 where 'contabilidad.editar' = any(permisos) and not 'activos.editar' = any(permisos);
update roles set permisos = permisos || array['activos.ver']
 where 'contabilidad.ver' = any(permisos) and not 'activos.ver' = any(permisos);

alter table asientos drop constraint asientos_origen_check;
alter table asientos add constraint asientos_origen_check check (origen in ('manual','inventario','cheque','planilla','activos'));

create or replace function anular_asiento(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare v_estado estado_asiento; v_origen text;
begin
  if not puede_editar() then raise exception 'No tiene permiso para anular asientos'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo de la anulación'; end if;
  select estado, origen into v_estado, v_origen from asientos where id = p_id for update;
  if not found then raise exception 'El asiento % no existe', p_id; end if;
  if v_origen = 'inventario' then
    raise exception 'Este asiento lo generó el inventario; para revertirlo, anule el movimiento de inventario';
  end if;
  if v_origen = 'cheque' then
    raise exception 'Este asiento lo generó un cheque; para revertirlo, anule el cheque';
  end if;
  if v_origen = 'planilla' then
    raise exception 'Este asiento lo generó una planilla; para revertirlo, anule la planilla';
  end if;
  if v_origen = 'activos' then
    raise exception 'Este asiento lo generó activos fijos; para revertirlo, anule la depreciación o la baja';
  end if;
  if v_estado <> 'contabilizado' then raise exception 'Solo se anulan asientos contabilizados'; end if;
  update asientos
     set estado = 'anulado', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo)
   where id = p_id;
end $$;

-- Días entre dos fechas, ambas incluidas, en año comercial (meses de 30 días)
create or replace function dias360(p_desde date, p_hasta date) returns int
language plpgsql immutable as $$
declare d1 int; d2 int;
begin
  if p_desde is null or p_hasta is null or p_hasta < p_desde then return 0; end if;
  d1 := least(extract(day from p_desde)::int, 30);
  d2 := least(extract(day from p_hasta)::int, 30);
  -- el último día de febrero cuenta como día 30
  if extract(month from p_hasta) = 2 and extract(month from p_hasta + 1) = 3 then d2 := 30; end if;
  return (extract(year from p_hasta)::int - extract(year from p_desde)::int) * 360
       + (extract(month from p_hasta)::int - extract(month from p_desde)::int) * 30
       + (d2 - d1) + 1;
end $$;

-- ---------------------------------------------------------------------
-- 2. Planilla: tipos aguinaldo y liquidación
-- ---------------------------------------------------------------------
alter table planillas drop constraint planillas_tipo_check;
alter table planillas add constraint planillas_tipo_check check (tipo in ('quincenal','mensual','aguinaldo','liquidacion'));
alter table planillas
  add column liq_empleado_id bigint references empleados(id),
  add column liq_motivo      text check (liq_motivo in ('renuncia','renuncia_sin_preaviso','despido_sin_causa','despido_causa_justa',
                                                         'mutuo_acuerdo','fin_contrato','fallecimiento','otro')),
  add column liq_indemnizar  boolean not null default false,
  add column liq_detalle     jsonb;
create unique index planillas_una_liquidacion on planillas (liq_empleado_id) where tipo = 'liquidacion' and estado <> 'anulada';

alter table planilla_parametros add column cuenta_prestaciones_id bigint references cuentas(id);
update planilla_parametros set cuenta_prestaciones_id = _cuenta_planilla('Prestaciones sociales', '6.1', 'gasto', 'deudora', '6.1.02')
 where cuenta_prestaciones_id is null;

alter table conceptos_planilla add column sistema boolean not null default false;   -- los calcula la app; no se agregan a mano
alter table planilla_novedades add column automatica boolean not null default false;

insert into conceptos_planilla (codigo, nombre, tipo, afecta_inss, afecta_ir, cuenta_id, sistema) values
  ('VACLIQ', 'Vacaciones no gozadas',                 'ingreso', true,  true,  _cuenta_planilla('Prestaciones sociales', '6.1', 'gasto', 'deudora', '6.1.02'), true),
  ('AGULIQ', 'Aguinaldo proporcional',                'ingreso', false, false, _cuenta_planilla('Prestaciones sociales', '6.1', 'gasto', 'deudora', '6.1.02'), true),
  ('INDEM',  'Indemnización por antigüedad (art. 45)', 'ingreso', false, false, _cuenta_planilla('Prestaciones sociales', '6.1', 'gasto', 'deudora', '6.1.02'), true)
on conflict (codigo) do nothing;

alter table vacaciones_movimientos drop constraint vacaciones_movimientos_tipo_check;
alter table vacaciones_movimientos add constraint vacaciones_movimientos_tipo_check
  check (tipo in ('saldo_inicial','acumulado','tomadas','dia_extra','ajuste','liquidadas'));

-- Días de indemnización del art. 45
create or replace function dias_indemnizacion(p_ingreso date, p_salida date, p_minimo_un_mes boolean default false) returns numeric
language plpgsql immutable as $$
declare v_anios numeric := dias360(p_ingreso, p_salida) / 360.0; v numeric;
begin
  v := least(v_anios, 3) * 30 + greatest(v_anios - 3, 0) * 20;
  if p_minimo_un_mes then v := greatest(v, 30); end if;
  return round(least(v, 150), 2);
end $$;

create or replace function _recalcular_planilla(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  pl planillas%rowtype; par planilla_parametros; l record; e empleados%rowtype;
  v_dias_std numeric; v_per int; v_ini date; v_fin date; v_dias numeric; v_sal numeric;
  v_ing numeric; v_ing_inss numeric; v_ing_ir numeric; v_ded numeric; v_bruto numeric;
  v_base_inss numeric; v_inss numeric; v_base_ir numeric; v_ir numeric; v_techo numeric;
  v_inss_pat numeric; v_inatec numeric;
  -- liquidación
  v_saldo numeric; v_vac_acum numeric; v_vac numeric; v_dic date; v_dias_agui int; v_dias_ind numeric;
begin
  select * into pl from planillas where id = p_id;
  par := _parametros_planilla(pl.hasta);
  if par.id is null then raise exception 'Configure los parámetros de planilla vigentes para %', pl.hasta; end if;
  v_dias_std := case pl.tipo when 'mensual' then 30 when 'quincenal' then 15 when 'aguinaldo' then 360
                             else least(dias360(pl.desde, pl.hasta), 30) end;
  v_per      := case pl.tipo when 'quincenal' then 24 else 12 end;
  v_techo    := case when par.techo_inss is null then null
                     when pl.tipo = 'liquidacion' then par.techo_inss
                     else par.techo_inss * v_dias_std / 30 end;

  for l in select * from planilla_lineas where planilla_id = p_id loop
    select * into e from empleados where id = l.empleado_id;
    v_ini := greatest(pl.desde, coalesce(e.fecha_ingreso, pl.desde));
    v_fin := least(pl.hasta, coalesce(e.fecha_baja, pl.hasta));
    if pl.tipo = 'aguinaldo' then
      v_dias := least(dias360(v_ini, v_fin), 360);
    elsif pl.tipo = 'liquidacion' then
      v_dias := least(dias360(v_ini, pl.hasta), 30);
    elsif v_ini = pl.desde and v_fin = pl.hasta then v_dias := v_dias_std;
    else v_dias := least(v_dias_std, greatest(v_fin - v_ini + 1, 0)); end if;
    if pl.tipo in ('aguinaldo','liquidacion') then
      update planilla_lineas set dias_periodo = v_dias, dias_no_pagados = least(dias_no_pagados, v_dias) where id = l.id;
      l.dias_no_pagados := least(l.dias_no_pagados, v_dias);
    end if;
    v_dias := greatest(v_dias - l.dias_no_pagados, 0);
    v_sal  := case when pl.tipo = 'aguinaldo' then round(e.salario_mensual / 360 * v_dias, 2)
                   else round(e.salario_mensual / 30 * v_dias, 2) end;

    -- Liquidación: vacaciones, aguinaldo proporcional e indemnización se recalculan siempre
    if pl.tipo = 'liquidacion' then
      if e.fecha_ingreso is null then raise exception 'Registre la fecha de ingreso de % para calcular la liquidación', e.nombre; end if;
      delete from planilla_novedades where planilla_id = p_id and empleado_id = e.id and automatica;
      select coalesce(sum(dias), 0) into v_saldo from vacaciones_movimientos
       where empleado_id = e.id and estado = 'aprobado';
      v_vac_acum := round(par.dias_vacaciones_mes * v_dias / 30, 2);
      v_vac := v_saldo + v_vac_acum;
      v_dic := make_date(extract(year from pl.hasta)::int - case when extract(month from pl.hasta) = 12 then 0 else 1 end, 12, 1);
      v_dias_agui := least(dias360(greatest(v_dic, e.fecha_ingreso), pl.hasta), 360);
      v_dias_ind := case when pl.liq_indemnizar
                         then dias_indemnizacion(e.fecha_ingreso, pl.hasta, pl.liq_motivo = 'despido_sin_causa') else 0 end;
      if v_vac > 0 then
        insert into planilla_novedades (planilla_id, empleado_id, concepto_id, monto, descripcion, automatica)
        select p_id, e.id, id, round(e.salario_mensual / 30 * v_vac, 2), v_vac || ' días', true
          from conceptos_planilla where codigo = 'VACLIQ' and round(e.salario_mensual / 30 * v_vac, 2) > 0;
      end if;
      insert into planilla_novedades (planilla_id, empleado_id, concepto_id, monto, descripcion, automatica)
      select p_id, e.id, id, round(e.salario_mensual / 360 * v_dias_agui, 2),
             v_dias_agui || ' días desde el ' || to_char(greatest(v_dic, e.fecha_ingreso), 'DD/MM/YYYY'), true
        from conceptos_planilla where codigo = 'AGULIQ' and round(e.salario_mensual / 360 * v_dias_agui, 2) > 0;
      insert into planilla_novedades (planilla_id, empleado_id, concepto_id, monto, descripcion, automatica)
      select p_id, e.id, id, round(e.salario_mensual / 30 * v_dias_ind, 2), v_dias_ind || ' días', true
        from conceptos_planilla where codigo = 'INDEM' and round(e.salario_mensual / 30 * v_dias_ind, 2) > 0;
      update planillas set liq_detalle = jsonb_build_object(
          'fecha_ingreso', e.fecha_ingreso, 'fecha_salida', pl.hasta, 'salario_mensual', e.salario_mensual,
          'anios', round(dias360(e.fecha_ingreso, pl.hasta) / 360.0, 2),
          'dias_salario', v_dias, 'saldo_vacaciones', v_saldo, 'vacaciones_periodo', v_vac_acum,
          'dias_vacaciones', greatest(v_vac, 0), 'vacaciones_negativas', least(v_vac, 0),
          'inicio_aguinaldo', greatest(v_dic, e.fecha_ingreso), 'dias_aguinaldo', v_dias_agui,
          'dias_indemnizacion', v_dias_ind)
       where id = p_id;
    end if;

    select coalesce(sum(n.monto) filter (where c.tipo = 'ingreso'), 0),
           coalesce(sum(n.monto) filter (where c.tipo = 'ingreso' and c.afecta_inss), 0),
           coalesce(sum(n.monto) filter (where c.tipo = 'ingreso' and c.afecta_ir), 0),
           coalesce(sum(n.monto) filter (where c.tipo = 'deduccion'), 0)
      into v_ing, v_ing_inss, v_ing_ir, v_ded
      from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id
     where n.planilla_id = p_id and n.empleado_id = l.empleado_id;

    v_bruto := v_sal + v_ing;
    if pl.tipo = 'aguinaldo' then
      -- El décimo tercer mes no cotiza INSS ni INATEC y está exento de IR
      v_base_inss := 0; v_inss := 0; v_base_ir := 0; v_ir := 0; v_inss_pat := 0; v_inatec := 0;
    else
      v_base_inss := v_sal + v_ing_inss;
      if v_techo is not null then v_base_inss := least(v_base_inss, v_techo); end if;
      v_inss      := round(v_base_inss * par.inss_laboral / 100, 2);
      v_base_ir   := greatest(v_sal + v_ing_ir - v_inss, 0);
      v_ir        := ir_periodo(v_base_ir, v_per, pl.hasta);
      v_inss_pat  := round(v_base_inss * par.inss_patronal / 100, 2);
      v_inatec    := round(case when pl.tipo = 'liquidacion' then v_sal + v_ing_inss else v_bruto end * par.inatec / 100, 2);
    end if;

    update planilla_lineas set
      salario_mensual = e.salario_mensual,
      dias_periodo = case when pl.tipo in ('aguinaldo','liquidacion') then dias_periodo else v_dias_std end,
      salario_periodo = v_sal, ingresos = v_ing, ingresos_inss = v_ing_inss, ingresos_ir = v_ing_ir, bruto = v_bruto,
      base_inss = v_base_inss, inss_laboral = v_inss, base_ir = v_base_ir, ir = v_ir,
      deducciones = v_ded, neto = v_bruto - v_inss - v_ir - v_ded,
      inss_patronal = v_inss_pat, inatec = v_inatec
     where id = l.id;
  end loop;

  update planillas p set
    empleados = s.n, total_bruto = s.b, total_inss_laboral = s.il, total_ir = s.ir, total_deducciones = s.d,
    total_neto = s.ne, total_inss_patronal = s.ip, total_inatec = s.it
    from (select count(*) n, coalesce(sum(bruto), 0) b, coalesce(sum(inss_laboral), 0) il, coalesce(sum(ir), 0) ir,
                 coalesce(sum(deducciones), 0) d, coalesce(sum(neto), 0) ne, coalesce(sum(inss_patronal), 0) ip,
                 coalesce(sum(inatec), 0) it
            from planilla_lineas where planilla_id = p_id) s
   where p.id = p_id;
end $$;

-- Planilla quincenal, mensual o de aguinaldo (la liquidación tiene su propia función)
create or replace function guardar_planilla(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p->>'id', '')::bigint; pl planillas%rowtype;
  v_tipo text := p->>'tipo'; v_desde date := (p->>'desde')::date; v_hasta date := (p->>'hasta')::date;
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso para elaborar planillas'; end if;
  if v_id is null then
    if v_tipo not in ('quincenal','mensual','aguinaldo') then raise exception 'Tipo de planilla no válido'; end if;
    if v_tipo = 'aguinaldo' then
      -- Período legal: 1 de diciembre al 30 de noviembre del año indicado por "hasta"
      v_hasta := make_date(extract(year from coalesce(v_hasta, v_desde, (now() at time zone 'America/Managua')::date))::int, 11, 30);
      v_desde := make_date(extract(year from v_hasta)::int - 1, 12, 1);
    end if;
    if v_desde is null or v_hasta is null or v_hasta < v_desde then raise exception 'Revise las fechas del período'; end if;
    if v_tipo <> 'aguinaldo' and v_hasta - v_desde > 31 then raise exception 'El período no puede pasar de un mes'; end if;
    if exists (select 1 from planillas where tipo = v_tipo and estado <> 'anulada' and desde <= v_hasta and hasta >= v_desde) then
      raise exception 'Ya existe una planilla de % que cubre esas fechas', v_tipo;
    end if;
    insert into planillas (tipo, desde, hasta, fecha_pago, descripcion)
    values (v_tipo, v_desde, v_hasta,
            coalesce(nullif(p->>'fecha_pago', '')::date,
                     case when v_tipo = 'aguinaldo' then make_date(extract(year from v_hasta)::int, 12, 10) else v_hasta end),
            coalesce(nullif(trim(p->>'descripcion'), ''),
                     case when v_tipo = 'aguinaldo' then 'Aguinaldo ' || extract(year from v_hasta) || ' (del ' || to_char(v_desde, 'DD/MM/YYYY') || ' al ' || to_char(v_hasta, 'DD/MM/YYYY') || ')'
                          else 'Planilla ' || v_tipo || ' del ' || to_char(v_desde, 'DD/MM/YYYY') || ' al ' || to_char(v_hasta, 'DD/MM/YYYY') end))
    returning id into v_id;
  else
    pl := _planilla_editable(v_id);
    update planillas set fecha_pago = coalesce(nullif(p->>'fecha_pago', '')::date, fecha_pago),
                         descripcion = coalesce(nullif(trim(p->>'descripcion'), ''), descripcion)
     where id = v_id;
  end if;
  select * into pl from planillas where id = v_id;
  if pl.tipo <> 'liquidacion' then
    insert into planilla_lineas (planilla_id, empleado_id, centro_costo_id)
    select v_id, e.id, e.centro_costo_id from empleados e
     where e.activo and e.salario_mensual > 0 and (pl.tipo = 'aguinaldo' or e.tipo_pago = pl.tipo)
       and coalesce(e.fecha_ingreso, pl.desde) <= pl.hasta and coalesce(e.fecha_baja, pl.hasta) >= pl.desde
    on conflict (planilla_id, empleado_id) do nothing;
  end if;
  perform _recalcular_planilla(v_id);
  return v_id;
end $$;

create or replace function crear_liquidacion(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  e empleados%rowtype; v_id bigint; v_salida date := (p->>'fecha_salida')::date;
  v_ultimo date := (p->>'ultimo_dia_pagado')::date; v_motivo text := p->>'motivo'; v_desde date;
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso para elaborar liquidaciones'; end if;
  select * into e from empleados where id = (p->>'empleado_id')::bigint;
  if not found then raise exception 'El colaborador no existe'; end if;
  if not e.activo then raise exception '% ya está inactivo', e.nombre; end if;
  if e.fecha_ingreso is null then raise exception 'Registre primero la fecha de ingreso de %', e.nombre; end if;
  if v_salida is null or v_salida < e.fecha_ingreso then raise exception 'La fecha de salida no puede ser anterior al ingreso'; end if;
  if v_motivo is null then raise exception 'Indique el motivo de la salida'; end if;
  if exists (select 1 from planillas where tipo = 'liquidacion' and liq_empleado_id = e.id and estado <> 'anulada') then
    raise exception '% ya tiene una liquidación', e.nombre;
  end if;
  v_ultimo := coalesce(v_ultimo, e.fecha_ingreso - 1);
  if v_ultimo > v_salida then raise exception 'El último día pagado no puede ser posterior a la salida'; end if;
  v_desde := least(v_ultimo + 1, v_salida);

  insert into planillas (tipo, desde, hasta, fecha_pago, descripcion, liq_empleado_id, liq_motivo, liq_indemnizar)
  values ('liquidacion', v_desde, v_salida, coalesce(nullif(p->>'fecha_pago', '')::date, v_salida),
          'Liquidación de ' || e.nombre || ' (salida ' || to_char(v_salida, 'DD/MM/YYYY') || ')',
          e.id, v_motivo,
          coalesce((p->>'indemnizar')::boolean, v_motivo in ('renuncia','despido_sin_causa','mutuo_acuerdo')))
  returning id into v_id;
  insert into planilla_lineas (planilla_id, empleado_id, centro_costo_id, dias_no_pagados)
  values (v_id, e.id, e.centro_costo_id, case when v_ultimo >= v_salida then 30 else 0 end);
  perform _recalcular_planilla(v_id);
  return v_id;
end $$;

create or replace function editar_liquidacion(p_id bigint, p_motivo text, p_indemnizar boolean) returns void
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype;
begin
  pl := _planilla_editable(p_id);
  if pl.tipo <> 'liquidacion' then raise exception 'No es una liquidación'; end if;
  update planillas set liq_motivo = coalesce(p_motivo, liq_motivo), liq_indemnizar = coalesce(p_indemnizar, liq_indemnizar) where id = p_id;
  perform _recalcular_planilla(p_id);
end $$;

create or replace function guardar_novedad(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype; v_id bigint; c conceptos_planilla%rowtype;
begin
  pl := _planilla_editable((p->>'planilla_id')::bigint);
  select * into c from conceptos_planilla where id = (p->>'concepto_id')::bigint and activo;
  if not found then raise exception 'Concepto no válido'; end if;
  if c.sistema then raise exception '"%" lo calcula la app; no se agrega a mano', c.nombre; end if;
  if not exists (select 1 from planilla_lineas where planilla_id = pl.id and empleado_id = (p->>'empleado_id')::bigint) then
    raise exception 'El colaborador no está en esta planilla';
  end if;
  if coalesce((p->>'monto')::numeric, 0) <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  insert into planilla_novedades (planilla_id, empleado_id, concepto_id, monto, descripcion)
  values (pl.id, (p->>'empleado_id')::bigint, c.id, round((p->>'monto')::numeric, 2), nullif(trim(p->>'descripcion'), ''))
  returning id into v_id;
  perform _recalcular_planilla(pl.id);
  return v_id;
end $$;

create or replace function eliminar_novedad(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare n planilla_novedades%rowtype; pl planillas%rowtype;
begin
  select * into n from planilla_novedades where id = p_id;
  if not found then raise exception 'La novedad no existe'; end if;
  pl := _planilla_editable(n.planilla_id);
  if n.automatica then raise exception 'Este monto lo calcula la app; cambie los datos de la liquidación'; end if;
  delete from planilla_novedades where id = p_id;
  perform _recalcular_planilla(pl.id);
end $$;

create or replace function aprobar_planilla(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  pl planillas%rowtype; par planilla_parametros; v_as bigint; i int := 0; r record; v_cta_sal bigint; v_vac numeric;
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'No tiene permiso para aprobar planillas'; end if;
  select * into pl from planillas where id = p_id for update;
  if not found then raise exception 'La planilla no existe'; end if;
  if pl.estado <> 'por_aprobar' then raise exception 'Solo se aprueban planillas enviadas a aprobación'; end if;
  if pl.creado_por = auth.uid() then raise exception 'Quien elaboró la planilla no puede aprobarla; debe hacerlo otra persona'; end if;
  par := _parametros_planilla(pl.hasta);
  v_cta_sal := case when pl.tipo = 'aguinaldo' then coalesce(par.cuenta_prestaciones_id, par.cuenta_salarios_id) else par.cuenta_salarios_id end;

  insert into asientos (fecha, tipo, concepto, referencia, moneda, origen)
  values (pl.hasta, 'diario', left(pl.descripcion, 500), 'PL-' || pl.id, 'NIO', 'planilla')
  returning id into v_as;

  for r in
    select cuenta_id, centro_costo_id, descripcion, sum(monto) monto from (
      select v_cta_sal cuenta_id, l.centro_costo_id,
             case pl.tipo when 'aguinaldo' then 'Aguinaldo (décimo tercer mes)' when 'liquidacion' then 'Salario pendiente' else 'Salarios' end descripcion,
             l.salario_periodo monto
        from planilla_lineas l where l.planilla_id = p_id
      union all
      select coalesce(c.cuenta_id, par.cuenta_salarios_id), l.centro_costo_id, c.nombre, n.monto
        from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id and c.tipo = 'ingreso'
        join planilla_lineas l on l.planilla_id = n.planilla_id and l.empleado_id = n.empleado_id
       where n.planilla_id = p_id
      union all
      select par.cuenta_patronal_id, l.centro_costo_id, 'INSS patronal e INATEC', l.inss_patronal + l.inatec
        from planilla_lineas l where l.planilla_id = p_id
    ) x group by cuenta_id, centro_costo_id, descripcion having sum(monto) > 0
    order by descripcion, centro_costo_id
  loop
    i := i + 1;
    insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
    values (v_as, i, r.cuenta_id, r.centro_costo_id, r.descripcion, r.monto, 0);
  end loop;

  for r in
    select cuenta_id, descripcion, sum(monto) monto from (
      select par.cuenta_inss_pagar_id cuenta_id, 'INSS laboral y patronal' descripcion, pl.total_inss_laboral + pl.total_inss_patronal monto
      union all select par.cuenta_ir_pagar_id, 'IR retenido a colaboradores', pl.total_ir
      union all select par.cuenta_inatec_pagar_id, 'INATEC', pl.total_inatec
      union all
      select c.cuenta_id, c.nombre, n.monto
        from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id and c.tipo = 'deduccion'
       where n.planilla_id = p_id
      union all select par.cuenta_neto_pagar_id, 'Neto a pagar a colaboradores', pl.total_neto
    ) x group by cuenta_id, descripcion having sum(monto) > 0
  loop
    i := i + 1;
    insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber)
    values (v_as, i, r.cuenta_id, r.descripcion, 0, r.monto);
  end loop;
  perform _contabilizar(v_as);

  -- Vacaciones acumuladas del período (el aguinaldo no acumula)
  if pl.tipo <> 'aguinaldo' then
    insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen, planilla_id, revisado_por, revisado_en)
    select l.empleado_id, pl.hasta, 'acumulado',
           round(par.dias_vacaciones_mes * (case when l.salario_mensual > 0 then l.salario_periodo / l.salario_mensual else 0 end), 2),
           pl.descripcion, 'aprobado', 'planilla', pl.id, auth.uid(), now()
      from planilla_lineas l
     where l.planilla_id = p_id
       and round(par.dias_vacaciones_mes * (case when l.salario_mensual > 0 then l.salario_periodo / l.salario_mensual else 0 end), 2) <> 0;
  end if;

  -- Liquidación: se pagan las vacaciones pendientes y el colaborador queda inactivo
  if pl.tipo = 'liquidacion' then
    select coalesce(sum(dias), 0) into v_vac from vacaciones_movimientos where empleado_id = pl.liq_empleado_id and estado = 'aprobado';
    if v_vac > 0 then
      insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen, planilla_id, revisado_por, revisado_en)
      values (pl.liq_empleado_id, pl.hasta, 'liquidadas', -v_vac, 'Pagadas en la liquidación', 'aprobado', 'planilla', pl.id, auth.uid(), now());
    end if;
    update empleados set activo = false, fecha_baja = pl.hasta where id = pl.liq_empleado_id;
  end if;

  update planillas set estado = 'aprobada', asiento_id = v_as, aprobado_por = auth.uid(), aprobado_en = now() where id = p_id;
  return v_as;
end $$;

create or replace function anular_planilla(p_id bigint, p_motivo text, p_fecha date default null) returns void
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype; v_f date; v_as bigint;
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'No tiene permiso para anular planillas'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo de la anulación'; end if;
  select * into pl from planillas where id = p_id for update;
  if not found then raise exception 'La planilla no existe'; end if;
  if pl.estado <> 'aprobada' then raise exception 'Solo se anulan planillas aprobadas; los borradores se eliminan'; end if;
  v_f := coalesce(p_fecha, greatest(pl.hasta, (now() at time zone 'America/Managua')::date));
  if v_f < pl.hasta then raise exception 'La fecha de anulación no puede ser anterior al cierre del período'; end if;
  v_as := _revertir_asiento(pl.asiento_id, v_f, 'Anulación: ' || pl.descripcion || '. ' || trim(p_motivo), 'planilla');
  update vacaciones_movimientos set estado = 'anulado', motivo = 'Planilla anulada' where planilla_id = p_id;
  if pl.tipo = 'liquidacion' then
    update empleados set activo = true, fecha_baja = null where id = pl.liq_empleado_id and fecha_baja = pl.hasta;
  end if;
  update planillas set estado = 'anulada', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo),
         asiento_anulacion_id = v_as
   where id = p_id;
end $$;

-- Cálculo rápido sin guardar nada (para consultar "¿cuánto le toca?")
create or replace function simular_liquidacion(p_empleado bigint, p_fecha_salida date, p_ultimo_dia_pagado date,
                                               p_motivo text, p_indemnizar boolean default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e empleados%rowtype; par planilla_parametros; v_ultimo date; v_dias numeric; v_saldo numeric; v_vac numeric;
  v_dic date; v_agui int; v_ind numeric; v_indem boolean; v_sal numeric; m_vac numeric; m_agui numeric; m_ind numeric;
  v_inss numeric; v_ir numeric;
begin
  if not tiene_permiso('planilla.ver') then raise exception 'No tiene permiso'; end if;
  select * into e from empleados where id = p_empleado;
  if not found then raise exception 'El colaborador no existe'; end if;
  if e.fecha_ingreso is null then raise exception 'Registre primero la fecha de ingreso de %', e.nombre; end if;
  if p_fecha_salida is null or p_fecha_salida < e.fecha_ingreso then raise exception 'Revise la fecha de salida'; end if;
  par := _parametros_planilla(p_fecha_salida);
  v_ultimo := coalesce(p_ultimo_dia_pagado, e.fecha_ingreso - 1);
  v_dias := case when v_ultimo >= p_fecha_salida then 0 else least(dias360(greatest(v_ultimo + 1, e.fecha_ingreso), p_fecha_salida), 30) end;
  v_sal := round(e.salario_mensual / 30 * v_dias, 2);
  select coalesce(sum(dias), 0) into v_saldo from vacaciones_movimientos where empleado_id = e.id and estado = 'aprobado';
  v_vac := greatest(v_saldo + round(par.dias_vacaciones_mes * v_dias / 30, 2), 0);
  v_dic := make_date(extract(year from p_fecha_salida)::int - case when extract(month from p_fecha_salida) = 12 then 0 else 1 end, 12, 1);
  v_agui := least(dias360(greatest(v_dic, e.fecha_ingreso), p_fecha_salida), 360);
  v_indem := coalesce(p_indemnizar, p_motivo in ('renuncia','despido_sin_causa','mutuo_acuerdo'));
  v_ind := case when v_indem then dias_indemnizacion(e.fecha_ingreso, p_fecha_salida, p_motivo = 'despido_sin_causa') else 0 end;
  m_vac := round(e.salario_mensual / 30 * v_vac, 2);
  m_agui := round(e.salario_mensual / 360 * v_agui, 2);
  m_ind := round(e.salario_mensual / 30 * v_ind, 2);
  v_inss := round(least(v_sal + m_vac, coalesce(par.techo_inss, v_sal + m_vac)) * par.inss_laboral / 100, 2);
  v_ir := ir_periodo(greatest(v_sal + m_vac - v_inss, 0), 12, p_fecha_salida);
  return jsonb_build_object('nombre', e.nombre, 'fecha_ingreso', e.fecha_ingreso, 'salario_mensual', e.salario_mensual,
    'anios', round(dias360(e.fecha_ingreso, p_fecha_salida) / 360.0, 2),
    'dias_salario', v_dias, 'salario', v_sal, 'dias_vacaciones', v_vac, 'vacaciones', m_vac,
    'inicio_aguinaldo', greatest(v_dic, e.fecha_ingreso), 'dias_aguinaldo', v_agui, 'aguinaldo', m_agui,
    'indemniza', v_indem, 'dias_indemnizacion', v_ind, 'indemnizacion', m_ind,
    'bruto', v_sal + m_vac + m_agui + m_ind, 'inss', v_inss, 'ir', v_ir,
    'neto', v_sal + m_vac + m_agui + m_ind - v_inss - v_ir);
end $$;

-- Colillas: se agrega el tipo de planilla y los días reales de aguinaldo o liquidación
create or replace function colillas_planilla(p_clave text, p_planilla bigint, p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype; v jsonb;
begin
  if not exists (select 1 from integracion_claves where hash = _hash_clave(regexp_replace(coalesce(p_clave, ''), '^afc_', '')) and activa) then
    raise exception 'Clave de integración no válida';
  end if;
  select * into pl from planillas where id = p_planilla and pagada_en is not null;
  if not found then raise exception 'La planilla no está pagada'; end if;
  delete from planilla_tokens where planilla_id = p_planilla and token = coalesce(p_token, '')
     and creado_en > now() - interval '2 hours';   -- un solo uso, vence en 2 horas
  if not found then raise exception 'Este envío ya se hizo o no está autorizado'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'correo', e.correo, 'nombre', e.nombre, 'cargo', e.cargo, 'cedula', e.cedula,
      'cuenta', case when length(coalesce(e.cuenta_banco, '')) > 4 then '•••• ' || right(e.cuenta_banco, 4) else e.cuenta_banco end,
      'salario_mensual', l.salario_mensual,
      'dias_pagados', case when pl.tipo in ('aguinaldo','liquidacion') then l.dias_periodo - l.dias_no_pagados
                           when l.salario_mensual > 0 then round(l.salario_periodo * 30 / l.salario_mensual, 2) else 0 end,
      'salario', l.salario_periodo, 'bruto', l.bruto, 'inss', l.inss_laboral, 'ir', l.ir, 'deducciones', l.deducciones, 'neto', l.neto,
      'novedades', coalesce((select jsonb_agg(jsonb_build_object('concepto', c.nombre, 'tipo', c.tipo, 'monto', n.monto, 'detalle', n.descripcion) order by c.tipo, n.id)
                               from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id
                              where n.planilla_id = pl.id and n.empleado_id = e.id), '[]'),
      'vacaciones', (select round(coalesce(sum(m.dias), 0), 2) from vacaciones_movimientos m where m.empleado_id = e.id and m.estado = 'aprobado')
    ) order by e.nombre), '[]') into v
    from planilla_lineas l join empleados e on e.id = l.empleado_id
   where l.planilla_id = pl.id and l.neto > 0;

  return jsonb_build_object('id', pl.id, 'tipo', pl.tipo, 'descripcion', pl.descripcion, 'desde', pl.desde, 'hasta', pl.hasta,
                            'fecha_pagado', pl.fecha_pagado, 'empleados', v);
end $$;

-- ---------------------------------------------------------------------
-- 3. Activos fijos
-- ---------------------------------------------------------------------
create table activos_categorias (
  id                 bigint generated always as identity primary key,
  nombre             text not null unique,
  vida_util_meses    int not null check (vida_util_meses > 0),
  cuenta_activo_id   bigint not null references cuentas(id),
  cuenta_dep_acum_id bigint not null references cuentas(id),
  cuenta_gasto_id    bigint not null references cuentas(id),
  activa             boolean not null default true
);
create trigger bitacora_activos_categorias after insert or update or delete on activos_categorias for each row execute function registrar_bitacora();

create table activos_fijos (
  id                  bigint generated always as identity primary key,
  codigo              text not null unique check (length(trim(codigo)) > 0),
  nombre              text not null check (length(trim(nombre)) > 0),
  categoria_id        bigint not null references activos_categorias(id),
  descripcion         text,
  marca               text,
  serie               text,
  ubicacion           text,
  responsable         text,
  centro_costo_id     bigint references centros_costo(id),
  fecha_adquisicion   date not null,
  inicio_depreciacion date not null,          -- primer mes que se deprecia
  costo               numeric(16,2) not null check (costo > 0),
  valor_residual      numeric(16,2) not null default 0 check (valor_residual >= 0),
  vida_util_meses     int not null check (vida_util_meses > 0),
  dep_inicial         numeric(16,2) not null default 0 check (dep_inicial >= 0),   -- acumulada antes de usar esta app
  estado              text not null default 'activo' check (estado in ('activo','baja')),
  fecha_baja          date,
  tipo_baja           text check (tipo_baja in ('venta','descarte','robo','donacion')),
  valor_venta         numeric(16,2),
  motivo_baja         text,
  asiento_baja_id     bigint references asientos(id),
  creado_por          uuid default auth.uid(),
  creado_en           timestamptz not null default now(),
  check (valor_residual < costo),
  check (dep_inicial <= costo - valor_residual)
);
create trigger bitacora_activos_fijos after insert or update or delete on activos_fijos for each row execute function registrar_bitacora();

create table depreciaciones (
  id                   bigint generated always as identity primary key,
  anio                 int not null,
  mes                  int not null check (mes between 1 and 12),
  estado               text not null default 'registrada' check (estado in ('registrada','anulada')),
  total                numeric(16,2) not null default 0,
  activos              int not null default 0,
  asiento_id           bigint references asientos(id),
  asiento_anulacion_id bigint references asientos(id),
  creado_por           uuid default auth.uid(),
  creado_en            timestamptz not null default now(),
  anulado_por          uuid,
  anulado_en           timestamptz,
  motivo_anulacion     text
);
create unique index depreciaciones_mes on depreciaciones (anio, mes) where estado = 'registrada';
create trigger bitacora_depreciaciones after insert or update or delete on depreciaciones for each row execute function registrar_bitacora();

create table depreciacion_lineas (
  id              bigint generated always as identity primary key,
  depreciacion_id bigint not null references depreciaciones(id) on delete cascade,
  activo_id       bigint not null references activos_fijos(id),
  monto           numeric(16,2) not null check (monto > 0),
  unique (depreciacion_id, activo_id)
);

-- Depreciación acumulada hasta hoy (inicial + meses registrados)
create or replace function dep_acumulada(p_activo bigint) returns numeric
language sql stable security definer set search_path = public as $$
  select a.dep_inicial + coalesce((select sum(l.monto) from depreciacion_lineas l join depreciaciones d on d.id = l.depreciacion_id
                                     where l.activo_id = a.id and d.estado = 'registrada'), 0)
    from activos_fijos a where a.id = p_activo
$$;

-- Cuota del mes: línea recta, sin pasar del valor depreciable
create or replace function cuota_depreciacion(p_activo bigint, p_anio int, p_mes int) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare a activos_fijos%rowtype; v_fin_mes date := (make_date(p_anio, p_mes, 1) + interval '1 month - 1 day')::date; v_pend numeric;
begin
  select * into a from activos_fijos where id = p_activo;
  if not found then return 0; end if;
  if date_trunc('month', a.inicio_depreciacion) > make_date(p_anio, p_mes, 1) then return 0; end if;
  if a.estado = 'baja' and a.fecha_baja < make_date(p_anio, p_mes, 1) then return 0; end if;
  v_pend := a.costo - a.valor_residual - dep_acumulada(a.id)
          + coalesce((select l.monto from depreciacion_lineas l join depreciaciones d on d.id = l.depreciacion_id
                       where l.activo_id = a.id and d.estado = 'registrada' and d.anio = p_anio and d.mes = p_mes), 0);
  return greatest(least(round((a.costo - a.valor_residual) / a.vida_util_meses, 2), v_pend), 0);
end $$;

create or replace function calcular_depreciacion(p_anio int, p_mes int)
returns table (activo_id bigint, monto numeric)
language sql stable security definer set search_path = public as $$
  select a.id, cuota_depreciacion(a.id, p_anio, p_mes) from activos_fijos a
   where tiene_permiso('activos.ver') and cuota_depreciacion(a.id, p_anio, p_mes) > 0
$$;

create or replace function registrar_depreciacion(p_anio int, p_mes int) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_as bigint; v_fecha date := (make_date(p_anio, p_mes, 1) + interval '1 month - 1 day')::date; i int := 0; r record;
begin
  if not tiene_permiso('activos.editar') then raise exception 'No tiene permiso para registrar la depreciación'; end if;
  if exists (select 1 from depreciaciones where anio = p_anio and mes = p_mes and estado = 'registrada') then
    raise exception 'La depreciación de %/% ya está registrada', lpad(p_mes::text, 2, '0'), p_anio;
  end if;
  insert into depreciaciones (anio, mes) values (p_anio, p_mes) returning id into v_id;
  insert into depreciacion_lineas (depreciacion_id, activo_id, monto)
  select v_id, a.id, cuota_depreciacion(a.id, p_anio, p_mes) from activos_fijos a
   where cuota_depreciacion(a.id, p_anio, p_mes) > 0;
  if not found then raise exception 'No hay activos que depreciar en %/%', lpad(p_mes::text, 2, '0'), p_anio; end if;

  insert into asientos (fecha, tipo, concepto, referencia, moneda, origen)
  values (v_fecha, 'ajuste', 'Depreciación de activos fijos de ' || to_char(v_fecha, 'MM/YYYY'), 'DEP-' || p_anio || '-' || lpad(p_mes::text, 2, '0'), 'NIO', 'activos')
  returning id into v_as;
  for r in
    select c.cuenta_gasto_id cuenta_id, a.centro_costo_id, 'Depreciación ' || c.nombre descripcion, sum(l.monto) monto, 1 lado
      from depreciacion_lineas l join activos_fijos a on a.id = l.activo_id join activos_categorias c on c.id = a.categoria_id
     where l.depreciacion_id = v_id group by 1, 2, 3
    union all
    select c.cuenta_dep_acum_id, null::bigint, 'Depreciación acumulada ' || c.nombre, sum(l.monto), 2
      from depreciacion_lineas l join activos_fijos a on a.id = l.activo_id join activos_categorias c on c.id = a.categoria_id
     where l.depreciacion_id = v_id group by 1, 2, 3
    order by 5, 3
  loop
    i := i + 1;
    insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
    values (v_as, i, r.cuenta_id, r.centro_costo_id, r.descripcion,
            case when r.lado = 1 then r.monto else 0 end, case when r.lado = 2 then r.monto else 0 end);
  end loop;
  perform _contabilizar(v_as);
  update depreciaciones d set asiento_id = v_as,
         total = (select sum(monto) from depreciacion_lineas where depreciacion_id = v_id),
         activos = (select count(*) from depreciacion_lineas where depreciacion_id = v_id)
   where d.id = v_id;
  return v_id;
end $$;

create or replace function anular_depreciacion(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare d depreciaciones%rowtype; v_as bigint;
begin
  if not tiene_permiso('activos.editar') then raise exception 'No tiene permiso'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo de la anulación'; end if;
  select * into d from depreciaciones where id = p_id for update;
  if not found or d.estado <> 'registrada' then raise exception 'Solo se anulan depreciaciones registradas'; end if;
  if exists (select 1 from depreciaciones where estado = 'registrada' and (anio, mes) > (d.anio, d.mes)) then
    raise exception 'Anule primero los meses posteriores';
  end if;
  if exists (select 1 from depreciacion_lineas l join activos_fijos a on a.id = l.activo_id
              where l.depreciacion_id = p_id and a.estado = 'baja') then
    raise exception 'Hay activos de este mes que ya se dieron de baja; anule primero la baja';
  end if;
  v_as := _revertir_asiento(d.asiento_id, greatest((make_date(d.anio, d.mes, 1) + interval '1 month - 1 day')::date,
                                                   (now() at time zone 'America/Managua')::date),
                            'Anulación de depreciación ' || lpad(d.mes::text, 2, '0') || '/' || d.anio || '. ' || trim(p_motivo), 'activos');
  update depreciaciones set estado = 'anulada', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo),
         asiento_anulacion_id = v_as where id = p_id;
end $$;

-- Baja: sale el costo y la depreciación acumulada; la diferencia con lo recibido es pérdida o ganancia
create or replace function dar_baja_activo(p_id bigint, p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare a activos_fijos%rowtype; c activos_categorias%rowtype; v_fecha date := (p->>'fecha')::date; v_tipo text := p->>'tipo';
  v_venta numeric := coalesce(nullif(p->>'valor_venta', '')::numeric, 0); v_cta_cobro bigint := nullif(p->>'cuenta_cobro_id', '')::bigint;
  v_acum numeric; v_libros numeric; v_as bigint; i int := 0;
begin
  if not tiene_permiso('activos.editar') then raise exception 'No tiene permiso para dar de baja activos'; end if;
  select * into a from activos_fijos where id = p_id for update;
  if not found then raise exception 'El activo no existe'; end if;
  if a.estado = 'baja' then raise exception 'El activo ya está dado de baja'; end if;
  if v_fecha is null or v_fecha < a.fecha_adquisicion then raise exception 'Revise la fecha de la baja'; end if;
  if v_tipo not in ('venta','descarte','robo','donacion') then raise exception 'Tipo de baja no válido'; end if;
  if coalesce(trim(p->>'motivo'), '') = '' then raise exception 'Explique el motivo de la baja'; end if;
  if v_venta < 0 then raise exception 'El valor recibido no puede ser negativo'; end if;
  if v_venta > 0 and v_cta_cobro is null then raise exception 'Indique la cuenta donde entró el dinero de la venta'; end if;
  if exists (select 1 from depreciaciones where estado = 'registrada' and make_date(anio, mes, 1) > v_fecha) then
    raise exception 'Ya hay depreciación registrada después de esa fecha; anúlela primero';
  end if;
  select * into c from activos_categorias where id = a.categoria_id;
  v_acum := dep_acumulada(a.id);
  v_libros := a.costo - v_acum;

  insert into asientos (fecha, tipo, concepto, referencia, moneda, origen)
  values (v_fecha, 'diario', left('Baja de activo ' || a.codigo || ' ' || a.nombre || ' (' || v_tipo || ')', 500), 'AF-' || a.codigo, 'NIO', 'activos')
  returning id into v_as;
  if v_acum > 0 then
    i := i + 1; insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber)
    values (v_as, i, c.cuenta_dep_acum_id, 'Depreciación acumulada', v_acum, 0);
  end if;
  if v_venta > 0 then
    i := i + 1; insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber)
    values (v_as, i, v_cta_cobro, 'Valor recibido', v_venta, 0);
  end if;
  if v_libros > v_venta then
    i := i + 1; insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
    values (v_as, i, _cuenta_planilla('Pérdida en baja de activos fijos', '6.1', 'gasto', 'deudora'), a.centro_costo_id, 'Pérdida en la baja', v_libros - v_venta, 0);
  end if;
  i := i + 1; insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber)
  values (v_as, i, c.cuenta_activo_id, 'Costo del activo', 0, a.costo);
  if v_venta > v_libros then
    i := i + 1; insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber)
    values (v_as, i, _cuenta_planilla('Otros ingresos', '4', 'ingreso', 'acreedora', '4.4'), 'Ganancia en venta de activo', 0, v_venta - v_libros);
  end if;
  perform _contabilizar(v_as);
  update activos_fijos set estado = 'baja', fecha_baja = v_fecha, tipo_baja = v_tipo, valor_venta = v_venta,
         motivo_baja = trim(p->>'motivo'), asiento_baja_id = v_as where id = p_id;
  return v_as;
end $$;

create or replace function anular_baja_activo(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare a activos_fijos%rowtype;
begin
  if not tiene_permiso('activos.editar') then raise exception 'No tiene permiso'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo'; end if;
  select * into a from activos_fijos where id = p_id for update;
  if not found or a.estado <> 'baja' then raise exception 'El activo no está dado de baja'; end if;
  perform _revertir_asiento(a.asiento_baja_id, greatest(a.fecha_baja, (now() at time zone 'America/Managua')::date),
                            'Anulación de baja del activo ' || a.codigo || '. ' || trim(p_motivo), 'activos');
  update activos_fijos set estado = 'activo', fecha_baja = null, tipo_baja = null, valor_venta = null, motivo_baja = null, asiento_baja_id = null
   where id = p_id;
end $$;

-- Vista con valores al día
create or replace function resumen_activos()
returns table (activo_id bigint, dep_acumulada numeric, valor_libros numeric, cuota_mensual numeric, meses_restantes int)
language sql stable security definer set search_path = public as $$
  select a.id, dep_acumulada(a.id), a.costo - dep_acumulada(a.id),
         round((a.costo - a.valor_residual) / a.vida_util_meses, 2),
         ceil((a.costo - a.valor_residual - dep_acumulada(a.id)) / nullif(round((a.costo - a.valor_residual) / a.vida_util_meses, 2), 0))::int
    from activos_fijos a where tiene_permiso('activos.ver')
$$;

-- No se puede cambiar el costo ni la vida útil de un activo con depreciación registrada
create or replace function _proteger_activo() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from depreciacion_lineas where activo_id = old.id) or old.asiento_baja_id is not null then
      raise exception 'El activo ya tiene depreciación o baja registrada; no se puede eliminar';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and exists (select 1 from depreciacion_lineas l join depreciaciones d on d.id = l.depreciacion_id
                                   where l.activo_id = old.id and d.estado = 'registrada')
     and (new.costo, new.valor_residual, new.vida_util_meses, new.dep_inicial, new.inicio_depreciacion, new.categoria_id)
         is distinct from (old.costo, old.valor_residual, old.vida_util_meses, old.dep_inicial, old.inicio_depreciacion, old.categoria_id) then
    raise exception 'El activo ya tiene depreciación registrada: no se cambian costo, vida útil, categoría ni fechas';
  end if;
  return new;
end $$;
create trigger proteger_activo before update or delete on activos_fijos for each row execute function _proteger_activo();

alter table activos_categorias  enable row level security;
alter table activos_fijos       enable row level security;
alter table depreciaciones      enable row level security;
alter table depreciacion_lineas enable row level security;
create policy leer   on activos_categorias  for select to authenticated using (tiene_permiso('activos.ver'));
create policy editar on activos_categorias  for all    to authenticated using (tiene_permiso('activos.editar')) with check (tiene_permiso('activos.editar'));
create policy leer   on activos_fijos       for select to authenticated using (tiene_permiso('activos.ver'));
create policy editar on activos_fijos       for all    to authenticated using (tiene_permiso('activos.editar') and estado = 'activo')
                                                                        with check (tiene_permiso('activos.editar') and estado = 'activo' and asiento_baja_id is null);
create policy leer   on depreciaciones      for select to authenticated using (tiene_permiso('activos.ver'));
create policy leer   on depreciacion_lineas for select to authenticated using (tiene_permiso('activos.ver'));

drop policy leer on cuentas;
drop policy leer on centros_costo;
create policy leer on cuentas       for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver') or tiene_permiso('bancos.ver') or tiene_permiso('planilla.ver') or tiene_permiso('activos.ver'));
create policy leer on centros_costo for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver') or tiene_permiso('bancos.ver') or tiene_permiso('planilla.ver') or tiene_permiso('vacaciones.aprobar') or tiene_permiso('activos.ver'));

grant select on activos_categorias, activos_fijos, depreciaciones, depreciacion_lineas to authenticated;
grant insert, update, delete on activos_categorias, activos_fijos to authenticated;
revoke all on activos_categorias, activos_fijos, depreciaciones, depreciacion_lineas from anon;

-- Categorías con la vida útil del Reglamento de la Ley 822 (art. 34)
insert into activos_categorias (nombre, vida_util_meses, cuenta_activo_id, cuenta_dep_acum_id, cuenta_gasto_id)
select x.nombre, x.anios * 12,
       _cuenta_planilla('Propiedad, planta y equipo', '1.2', 'activo', 'deudora', '1.2.01'),
       _cuenta_planilla('Depreciación acumulada', '1.2', 'activo', 'acreedora', '1.2.02'),
       _cuenta_planilla('Depreciación', '6.1', 'gasto', 'deudora', '6.1.04')
  from (values ('Edificios', 20), ('Instalaciones', 10), ('Vehículos', 5), ('Equipo de transporte de carga', 5),
               ('Maquinaria y equipo', 5), ('Equipo agrícola', 5), ('Mobiliario y equipo de oficina', 5),
               ('Equipo de comunicación', 5), ('Equipo de cómputo', 2), ('Equipo audiovisual', 2),
               ('Aire acondicionado y elevadores', 10), ('Otros activos', 5)) x(nombre, anios)
on conflict (nombre) do nothing;

select _cuenta_planilla('Pérdida en baja de activos fijos', '6.1', 'gasto', 'deudora');

-- Funciones internas
revoke execute on function _recalcular_planilla(bigint), _proteger_activo() from public, anon, authenticated;
revoke execute on function crear_liquidacion(jsonb), editar_liquidacion(bigint, text, boolean), simular_liquidacion(bigint, date, date, text, boolean),
  registrar_depreciacion(int, int), anular_depreciacion(bigint, text), dar_baja_activo(bigint, jsonb), anular_baja_activo(bigint, text),
  calcular_depreciacion(int, int), resumen_activos(), dep_acumulada(bigint), cuota_depreciacion(bigint, int, int),
  dias360(date, date), dias_indemnizacion(date, date, boolean) from public, anon;
grant execute on function crear_liquidacion(jsonb), editar_liquidacion(bigint, text, boolean), simular_liquidacion(bigint, date, date, text, boolean),
  registrar_depreciacion(int, int), anular_depreciacion(bigint, text), dar_baja_activo(bigint, jsonb), anular_baja_activo(bigint, text),
  calcular_depreciacion(int, int), resumen_activos(), dep_acumulada(bigint), cuota_depreciacion(bigint, int, int),
  dias360(date, date), dias_indemnizacion(date, date, boolean) to authenticated;

commit;
