-- =====================================================================
-- Contabilidad AFC — Migración 008: plan de ahorro
-- Ejecutar después de 007-aguinaldo-liquidacion-activos.sql.
--
-- Reglas de AFC:
--   * Cada colaborador elige qué porcentaje de su salario ahorra (0 = no participa).
--   * AFC aporta siempre el 5% del salario (aunque el colaborador ahorre más o menos),
--     mientras participe en el plan. El 5% es un parámetro con vigencia.
--   * Ambos se calculan sobre el salario de la ficha (no se rebajan por días sin goce;
--     sí se prorratean si entra o sale a mitad del período).
--   * Solo en planillas quincenales y mensuales (no en aguinaldo ni liquidación).
--   * El colaborador retira su ahorro cada 5 años; al salir de AFC se le devuelve
--     todo (lo suyo y lo de AFC) en la liquidación, sea cual sea el motivo.
--   * Contabilidad: el ahorro descontado y el aporte de AFC son un pasivo
--     ("Plan de ahorro de colaboradores por pagar"); el aporte de AFC es gasto.
-- =====================================================================
begin;

alter table empleados
  add column ahorro_porcentaje numeric(5,2) not null default 0 check (ahorro_porcentaje between 0 and 50),
  add column ahorro_inicio     date;

alter table planilla_parametros
  add column ahorro_afc_pct          numeric(5,2) not null default 5 check (ahorro_afc_pct between 0 and 50),
  add column ahorro_anios_retiro     int not null default 5 check (ahorro_anios_retiro > 0),
  add column cuenta_ahorro_pagar_id  bigint references cuentas(id),
  add column cuenta_aporte_ahorro_id bigint references cuentas(id);
update planilla_parametros set
  cuenta_ahorro_pagar_id  = _cuenta_planilla('Plan de ahorro de colaboradores por pagar', '2.1', 'pasivo', 'acreedora'),
  cuenta_aporte_ahorro_id = _cuenta_planilla('Aporte de AFC al plan de ahorro', '6.1', 'gasto', 'deudora');

alter table planilla_lineas
  add column ahorro_porcentaje numeric(5,2) not null default 0,
  add column ahorro            numeric(14,2) not null default 0,
  add column ahorro_afc        numeric(14,2) not null default 0;
alter table planillas
  add column total_ahorro     numeric(16,2) not null default 0,
  add column total_ahorro_afc numeric(16,2) not null default 0;

create table ahorro_movimientos (
  id          bigint generated always as identity primary key,
  empleado_id bigint not null references empleados(id),
  fecha       date not null,
  tipo        text not null check (tipo in ('saldo_inicial_colaborador','saldo_inicial_afc','aporte_colaborador','aporte_afc','retiro','ajuste')),
  monto       numeric(14,2) not null check (monto <> 0),     -- positivo = entra al ahorro; negativo = sale
  descripcion text,
  estado      text not null default 'aplicado' check (estado in ('aplicado','anulado')),
  planilla_id bigint references planillas(id),
  asiento_id  bigint references asientos(id),
  asiento_anulacion_id bigint references asientos(id),
  cuenta_bancaria_id bigint references cuentas_bancarias(id),
  referencia  text,
  creado_por  uuid default auth.uid(),
  creado_en   timestamptz not null default now(),
  motivo      text
);
create index on ahorro_movimientos (empleado_id, estado);
create trigger bitacora_ahorro after insert or update or delete on ahorro_movimientos for each row execute function registrar_bitacora();
alter table ahorro_movimientos enable row level security;
create policy leer on ahorro_movimientos for select to authenticated using (tiene_permiso('planilla.ver'));
grant select on ahorro_movimientos to authenticated;
revoke all on ahorro_movimientos from anon;

insert into conceptos_planilla (codigo, nombre, tipo, afecta_inss, afecta_ir, cuenta_id, sistema) values
  ('AHORRO', 'Devolución del plan de ahorro', 'ingreso', false, false,
   _cuenta_planilla('Plan de ahorro de colaboradores por pagar', '2.1', 'pasivo', 'acreedora'), true)
on conflict (codigo) do nothing;

-- Cálculo de planilla con plan de ahorro
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
  -- plan de ahorro
  v_dias_emp numeric; v_aho numeric; v_aho_afc numeric; v_aho_saldo numeric;
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
    v_dias_emp := v_dias;   -- días de empleo en el período (el ahorro no se rebaja por días sin goce)
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
      -- Plan de ahorro: se devuelve todo lo ahorrado (lo del colaborador y el aporte de AFC)
      select coalesce(sum(monto), 0) into v_aho_saldo from ahorro_movimientos where empleado_id = e.id and estado = 'aplicado';
      insert into planilla_novedades (planilla_id, empleado_id, concepto_id, monto, descripcion, automatica)
      select p_id, e.id, id, v_aho_saldo, 'Saldo del plan de ahorro', true
        from conceptos_planilla where codigo = 'AHORRO' and v_aho_saldo > 0;
      update planillas set liq_detalle = jsonb_build_object(
          'fecha_ingreso', e.fecha_ingreso, 'fecha_salida', pl.hasta, 'salario_mensual', e.salario_mensual,
          'anios', round(dias360(e.fecha_ingreso, pl.hasta) / 360.0, 2),
          'dias_salario', v_dias, 'saldo_vacaciones', v_saldo, 'vacaciones_periodo', v_vac_acum,
          'dias_vacaciones', greatest(v_vac, 0), 'vacaciones_negativas', least(v_vac, 0),
          'inicio_aguinaldo', greatest(v_dic, e.fecha_ingreso), 'dias_aguinaldo', v_dias_agui,
          'dias_indemnizacion', v_dias_ind, 'saldo_ahorro', v_aho_saldo)
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

    -- Plan de ahorro: % que eligió el colaborador + aporte fijo de AFC, sobre el salario de la ficha
    v_aho := 0; v_aho_afc := 0;
    if pl.tipo in ('quincenal','mensual') and coalesce(e.ahorro_porcentaje, 0) > 0
       and (e.ahorro_inicio is null or e.ahorro_inicio <= pl.hasta) then
      -- si entró al plan a mitad del período, solo cuentan los días desde entonces
      if e.ahorro_inicio > greatest(pl.desde, coalesce(e.fecha_ingreso, pl.desde)) then
        v_dias_emp := least(v_dias_emp, greatest(v_fin - e.ahorro_inicio + 1, 0));
      end if;
      v_aho     := round(e.salario_mensual * v_dias_emp / 30 * e.ahorro_porcentaje / 100, 2);
      v_aho_afc := round(e.salario_mensual * v_dias_emp / 30 * coalesce(par.ahorro_afc_pct, 0) / 100, 2);
    end if;

    update planilla_lineas set
      salario_mensual = e.salario_mensual, ahorro_porcentaje = case when v_aho > 0 then e.ahorro_porcentaje else 0 end,
      ahorro = v_aho, ahorro_afc = v_aho_afc,
      dias_periodo = case when pl.tipo in ('aguinaldo','liquidacion') then dias_periodo else v_dias_std end,
      salario_periodo = v_sal, ingresos = v_ing, ingresos_inss = v_ing_inss, ingresos_ir = v_ing_ir, bruto = v_bruto,
      base_inss = v_base_inss, inss_laboral = v_inss, base_ir = v_base_ir, ir = v_ir,
      deducciones = v_ded, neto = v_bruto - v_inss - v_ir - v_ded - v_aho,
      inss_patronal = v_inss_pat, inatec = v_inatec
     where id = l.id;
  end loop;

  update planillas p set
    empleados = s.n, total_bruto = s.b, total_inss_laboral = s.il, total_ir = s.ir, total_deducciones = s.d,
    total_neto = s.ne, total_inss_patronal = s.ip, total_inatec = s.it, total_ahorro = s.ah, total_ahorro_afc = s.af
    from (select count(*) n, coalesce(sum(bruto), 0) b, coalesce(sum(inss_laboral), 0) il, coalesce(sum(ir), 0) ir,
                 coalesce(sum(deducciones), 0) d, coalesce(sum(neto), 0) ne, coalesce(sum(inss_patronal), 0) ip,
                 coalesce(sum(inatec), 0) it, coalesce(sum(ahorro), 0) ah, coalesce(sum(ahorro_afc), 0) af
            from planilla_lineas where planilla_id = p_id) s
   where p.id = p_id;
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
      union all
      select par.cuenta_aporte_ahorro_id, l.centro_costo_id, 'Aporte de AFC al plan de ahorro', l.ahorro_afc
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
      union all select par.cuenta_ahorro_pagar_id, 'Plan de ahorro (colaboradores y AFC)', pl.total_ahorro + pl.total_ahorro_afc
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

  -- Plan de ahorro: aportes del período
  insert into ahorro_movimientos (empleado_id, fecha, tipo, monto, descripcion, planilla_id)
  select l.empleado_id, pl.hasta, 'aporte_colaborador', l.ahorro, pl.descripcion || ' (' || l.ahorro_porcentaje || '%)', pl.id
    from planilla_lineas l where l.planilla_id = p_id and l.ahorro > 0
  union all
  select l.empleado_id, pl.hasta, 'aporte_afc', l.ahorro_afc, pl.descripcion, pl.id
    from planilla_lineas l where l.planilla_id = p_id and l.ahorro_afc > 0;

  -- Liquidación: se devuelve el ahorro, se pagan las vacaciones pendientes y el colaborador queda inactivo
  if pl.tipo = 'liquidacion' then
    select coalesce(sum(dias), 0) into v_vac from vacaciones_movimientos where empleado_id = pl.liq_empleado_id and estado = 'aprobado';
    if v_vac > 0 then
      insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen, planilla_id, revisado_por, revisado_en)
      values (pl.liq_empleado_id, pl.hasta, 'liquidadas', -v_vac, 'Pagadas en la liquidación', 'aprobado', 'planilla', pl.id, auth.uid(), now());
    end if;
    insert into ahorro_movimientos (empleado_id, fecha, tipo, monto, descripcion, planilla_id)
    select pl.liq_empleado_id, pl.hasta, 'retiro', -n.monto, 'Devuelto en la liquidación', pl.id
      from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id and c.codigo = 'AHORRO'
     where n.planilla_id = p_id;
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
  update ahorro_movimientos set estado = 'anulado', motivo = 'Planilla anulada' where planilla_id = p_id;
  if pl.tipo = 'liquidacion' then
    update empleados set activo = true, fecha_baja = null where id = pl.liq_empleado_id and fecha_baja = pl.hasta;
  end if;
  update planillas set estado = 'anulada', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo),
         asiento_anulacion_id = v_as
   where id = p_id;
end $$;


-- Colillas con el ahorro del período y el saldo
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
      'ahorro', l.ahorro, 'ahorro_porcentaje', l.ahorro_porcentaje, 'ahorro_afc', l.ahorro_afc,
      'ahorro_saldo', (select coalesce(sum(a.monto), 0) from ahorro_movimientos a where a.empleado_id = e.id and a.estado = 'aplicado'),
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
-- Consultas y operaciones del plan de ahorro
-- ---------------------------------------------------------------------
create or replace function resumen_ahorro()
returns table (empleado_id bigint, porcentaje numeric, inicio date, ahorro_mensual numeric, aporte_afc_mensual numeric,
               saldo_colaborador numeric, saldo_afc numeric, retirado numeric, saldo numeric, ultimo_retiro date, proximo_retiro date)
language sql stable security definer set search_path = public as $$
  with par as (select * from _parametros_planilla((now() at time zone 'America/Managua')::date)),
  m as (
    select a.empleado_id,
           sum(a.monto) filter (where a.tipo in ('aporte_colaborador','saldo_inicial_colaborador')) col,
           sum(a.monto) filter (where a.tipo in ('aporte_afc','saldo_inicial_afc')) afc,
           -sum(a.monto) filter (where a.tipo = 'retiro') ret,
           sum(a.monto) total,
           max(a.fecha) filter (where a.tipo = 'retiro') ult,
           min(a.fecha) primero
      from ahorro_movimientos a where a.estado = 'aplicado' group by a.empleado_id)
  select e.id, e.ahorro_porcentaje, coalesce(e.ahorro_inicio, m.primero),
         case when e.activo and e.ahorro_porcentaje > 0 then round(e.salario_mensual * e.ahorro_porcentaje / 100, 2) else 0 end,
         case when e.activo and e.ahorro_porcentaje > 0 then round(e.salario_mensual * (select ahorro_afc_pct from par) / 100, 2) else 0 end,
         coalesce(m.col, 0), coalesce(m.afc, 0), coalesce(m.ret, 0), coalesce(m.total, 0), m.ult,
         (coalesce(m.ult, e.ahorro_inicio, m.primero) + make_interval(years => (select ahorro_anios_retiro from par)))::date
    from empleados e left join m on m.empleado_id = e.id
   where tiene_permiso('planilla.ver') and (e.ahorro_porcentaje > 0 or m.empleado_id is not null)
$$;

-- Saldo que el colaborador ya traía (por ejemplo, de AG Planilla). No genera asiento:
-- el saldo debe estar en el pasivo por el asiento de apertura.
create or replace function saldo_inicial_ahorro(p_empleado bigint, p_fecha date, p_colaborador numeric, p_afc numeric, p_descripcion text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso'; end if;
  if coalesce(p_colaborador, 0) < 0 or coalesce(p_afc, 0) < 0 then raise exception 'Los saldos no pueden ser negativos'; end if;
  if exists (select 1 from ahorro_movimientos where empleado_id = p_empleado and tipo like 'saldo_inicial%' and estado = 'aplicado') then
    raise exception 'Este colaborador ya tiene saldo inicial; anúlelo primero';
  end if;
  insert into ahorro_movimientos (empleado_id, fecha, tipo, monto, descripcion)
  select p_empleado, p_fecha, t, m, coalesce(nullif(trim(p_descripcion), ''), 'Saldo inicial')
    from (values ('saldo_inicial_colaborador', round(coalesce(p_colaborador, 0), 2)), ('saldo_inicial_afc', round(coalesce(p_afc, 0), 2))) x(t, m)
   where m > 0;
end $$;

create or replace function anular_movimiento_ahorro(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare a ahorro_movimientos%rowtype; v_as bigint;
begin
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo'; end if;
  select * into a from ahorro_movimientos where id = p_id for update;
  if not found or a.estado <> 'aplicado' then raise exception 'El movimiento no existe o ya está anulado'; end if;
  if a.planilla_id is not null then raise exception 'Este movimiento viene de una planilla; anule la planilla'; end if;
  if a.tipo = 'retiro' then
    if not tiene_permiso('planilla.aprobar') then raise exception 'No tiene permiso'; end if;
    v_as := _revertir_asiento(a.asiento_id, greatest(a.fecha, (now() at time zone 'America/Managua')::date),
                              'Anulación de retiro de ahorro. ' || trim(p_motivo), 'planilla');
  elsif not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso';
  end if;
  update ahorro_movimientos set estado = 'anulado', motivo = trim(p_motivo), asiento_anulacion_id = v_as where id = p_id;
end $$;

-- Retiro cada 5 años: se entrega todo el saldo por transferencia o cheque y se registra el asiento
create or replace function retirar_ahorro(p_empleado bigint, p_fecha date, p_cuenta_bancaria bigint, p_referencia text) returns bigint
language plpgsql security definer set search_path = public as $$
declare e empleados%rowtype; r record; cb cuentas_bancarias%rowtype; par planilla_parametros; v_as bigint; v_id bigint;
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'Solo quien aprueba planillas registra retiros del ahorro'; end if;
  select * into e from empleados where id = p_empleado;
  if not found then raise exception 'El colaborador no existe'; end if;
  select * into r from resumen_ahorro() x where x.empleado_id = p_empleado;
  if r is null or r.saldo <= 0 then raise exception '% no tiene saldo de ahorro', e.nombre; end if;
  if p_fecha < r.proximo_retiro then
    raise exception '% podrá retirar su ahorro a partir del %', e.nombre, to_char(r.proximo_retiro, 'DD/MM/YYYY');
  end if;
  select * into cb from cuentas_bancarias where id = p_cuenta_bancaria and activa;
  if not found or cb.moneda <> 'NIO' then raise exception 'Elija una cuenta bancaria activa en córdobas'; end if;
  par := _parametros_planilla(p_fecha);
  insert into asientos (fecha, tipo, concepto, referencia, moneda, origen)
  values (p_fecha, 'egreso', left('Retiro del plan de ahorro: ' || e.nombre, 500), nullif(trim(p_referencia), ''), 'NIO', 'planilla')
  returning id into v_as;
  insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber) values
    (v_as, 1, par.cuenta_ahorro_pagar_id, 'Plan de ahorro de ' || e.nombre, r.saldo, 0),
    (v_as, 2, cb.cuenta_contable_id, cb.nombre, 0, r.saldo);
  perform _contabilizar(v_as);
  insert into ahorro_movimientos (empleado_id, fecha, tipo, monto, descripcion, asiento_id, cuenta_bancaria_id, referencia)
  values (p_empleado, p_fecha, 'retiro', -r.saldo, 'Retiro de los ' || par.ahorro_anios_retiro || ' años', v_as, p_cuenta_bancaria, nullif(trim(p_referencia), ''))
  returning id into v_id;
  return v_id;
end $$;

-- La simulación de liquidación incluye la devolución del ahorro
create or replace function simular_liquidacion(p_empleado bigint, p_fecha_salida date, p_ultimo_dia_pagado date,
                                               p_motivo text, p_indemnizar boolean default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e empleados%rowtype; par planilla_parametros; v_ultimo date; v_dias numeric; v_saldo numeric; v_vac numeric;
  v_dic date; v_agui int; v_ind numeric; v_indem boolean; v_sal numeric; m_vac numeric; m_agui numeric; m_ind numeric;
  v_inss numeric; v_ir numeric; v_aho numeric;
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
  select coalesce(sum(monto), 0) into v_aho from ahorro_movimientos where empleado_id = e.id and estado = 'aplicado';
  v_inss := round(least(v_sal + m_vac, coalesce(par.techo_inss, v_sal + m_vac)) * par.inss_laboral / 100, 2);
  v_ir := ir_periodo(greatest(v_sal + m_vac - v_inss, 0), 12, p_fecha_salida);
  return jsonb_build_object('nombre', e.nombre, 'fecha_ingreso', e.fecha_ingreso, 'salario_mensual', e.salario_mensual,
    'anios', round(dias360(e.fecha_ingreso, p_fecha_salida) / 360.0, 2),
    'dias_salario', v_dias, 'salario', v_sal, 'dias_vacaciones', v_vac, 'vacaciones', m_vac,
    'inicio_aguinaldo', greatest(v_dic, e.fecha_ingreso), 'dias_aguinaldo', v_agui, 'aguinaldo', m_agui,
    'indemniza', v_indem, 'dias_indemnizacion', v_ind, 'indemnizacion', m_ind,
    'ahorro', v_aho, 'bruto', v_sal + m_vac + m_agui + m_ind + v_aho, 'inss', v_inss, 'ir', v_ir,
    'neto', v_sal + m_vac + m_agui + m_ind + v_aho - v_inss - v_ir);
end $$;


revoke execute on function resumen_ahorro(), saldo_inicial_ahorro(bigint, date, numeric, numeric, text), anular_movimiento_ahorro(bigint, text),
  retirar_ahorro(bigint, date, bigint, text) from public, anon;
grant execute on function resumen_ahorro(), saldo_inicial_ahorro(bigint, date, numeric, numeric, text), anular_movimiento_ahorro(bigint, text),
  retirar_ahorro(bigint, date, bigint, text) to authenticated;
revoke execute on function _recalcular_planilla(bigint) from public, anon, authenticated;

commit;
