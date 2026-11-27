-- =====================================================================
-- Simulación de datos ficticios — Paso 2: funciones que generan los datos
-- Todo lo ficticio lleva la marca [SIM] o el código SIM-, y los correos
-- terminan en @simulacion.invalid (dominio que no existe: no llega ningún correo).
-- =====================================================================

-- Colaboradores, bodegas, productos, activos fijos y una cuenta bancaria ficticia
create or replace function sim_maestros() returns text language plpgsql as $$
declare
  nombres text[] := array['José','María','Juan','Ana','Carlos','Rosa','Luis','Carmen','Pedro','Marta','Jorge','Elena','Miguel','Lucía',
    'Francisco','Isabel','Manuel','Patricia','Ricardo','Sofía','Roberto','Daniela','Fernando','Gabriela','Óscar','Valeria','Julio','Andrea',
    'Mario','Karla','Ernesto','Yolanda','Rafael','Claudia','Byron','Massiel','Wilber','Xiomara','Danilo','Scarleth'];
  apellidos text[] := array['López','García','Martínez','Hernández','González','Pérez','Rodríguez','Sánchez','Ramírez','Cruz','Flores','Gómez',
    'Morales','Reyes','Jiménez','Torres','Díaz','Vargas','Castillo','Rivera','Mendoza','Ruiz','Aguilar','Ortiz','Gutiérrez','Chavarría',
    'Zeledón','Obando','Arróliga','Membreño','Somarriba','Alvarado','Espinoza','Picado','Úbeda','Lacayo'];
  cargos text[] := array['Técnico de agua','Promotora de salud','Conductor','Coordinador de proyecto','Asistente administrativo','Contador',
    'Bodeguero','Guarda de seguridad','Albañil','Maestro de obra','Enfermera','Educadora','Cocinera','Afanadora','Técnico agrícola',
    'Oficial de programas','Recepcionista','Mecánico','Electricista','Fontanero'];
  lugares text[] := array['Chinandega','Chichigalpa','El Viejo','Posoltega','Corinto','Managua','León','Somotillo'];
  v_admin uuid := _sim_contexto();
  i int; v_nom text; v_ape text; v_ing date; v_sal numeric; v_id bigint; v_pct numeric; v_cta_inv bigint; v_cb bigint;
  v_cat bigint; v_uni bigint; c record; v_costo numeric; v_vida int; v_fecha date; v_ini date; v_meses int; v_cuota numeric;
  n_emp int := 0; n_prod int := 0; n_act int := 0;
begin
  perform setseed(0.27);
  if exists (select 1 from empleados where correo like '%@simulacion.invalid') then raise exception 'La simulación ya se cargó'; end if;

  -- 200 colaboradores (85 % quincenales)
  for i in 1..200 loop
    v_nom := _sim_uno(nombres); v_ape := _sim_uno(apellidos) || ' ' || _sim_uno(apellidos);
    v_ing := date '2012-01-01' + floor(random() * 4800)::int;
    v_sal := round(case when random() < 0.6 then _sim_azar(9000, 16000) when random() < 0.85 then _sim_azar(16000, 32000) else _sim_azar(32000, 65000) end / 50) * 50;
    v_pct := case when random() < 0.45 then (array[2,3,5,5,8,10,10,15,20])[1 + floor(random() * 9)::int] else 0 end;
    insert into empleados (codigo, nombre, correo, cedula, inss_numero, cargo, lugar, centro_costo_id, fecha_ingreso, tipo_pago,
                           salario_mensual, cuenta_banco, activo, origen, ahorro_porcentaje, ahorro_inicio)
    values ('SIM-' || lpad(i::text, 3, '0'), v_nom || ' ' || v_ape,
            lower(translate(v_nom, 'áéíóúÁÉÍÓÚñÑ ', 'aeiouAEIOUnN')) || '.sim' || i || '@simulacion.invalid',
            '081-' || to_char(date '1970-01-01' + floor(random() * 12000)::int, 'DDMMYY') || '-' || lpad(i::text, 4, '0') || 'S',
            (1000000 + floor(random() * 8999999))::text, _sim_uno(cargos), _sim_uno(lugares),
            (select id from centros_costo where activo order by random() limit 1), v_ing,
            case when random() < 0.85 then 'quincenal' else 'mensual' end, v_sal,
            '1001' || lpad(floor(random() * 9999999999)::bigint::text, 10, '0'), true, 'manual', v_pct,
            case when v_pct > 0 then greatest(v_ing, date '2024-01-01') end)
    returning id into v_id;
    n_emp := n_emp + 1;
    -- saldo de vacaciones al empezar 2024 y ahorro que ya traían
    if v_ing < date '2024-01-01' then
      insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen)
      values (v_id, date '2023-12-31', 'saldo_inicial', round(_sim_azar(0, 25), 2), '[SIM] Saldo inicial', 'aprobado', 'manual');
      if v_pct > 0 and random() < 0.6 then
        perform saldo_inicial_ahorro(v_id, date '2023-12-31', round(_sim_azar(2000, 60000), 2), round(_sim_azar(1000, 30000), 2), '[SIM] Saldo traído');
      end if;
    end if;
    -- 12 % se irán de AFC entre mediados de 2024 y septiembre de 2026
    if random() < 0.12 then
      insert into _simulacion_salidas values (v_id, date '2024-06-01' + floor(random() * 840)::int,
        _sim_uno(array['renuncia','renuncia','renuncia','despido_sin_causa','mutuo_acuerdo','despido_causa_justa','fin_contrato']));
    end if;
  end loop;

  -- Parámetros de planilla para 2024-2025 (copia de los vigentes; los reales no cambian)
  insert into planilla_parametros (vigente_desde, inss_laboral, inss_patronal, inatec, techo_inss, dias_vacaciones_mes, cuenta_salarios_id,
    cuenta_patronal_id, cuenta_inss_pagar_id, cuenta_ir_pagar_id, cuenta_inatec_pagar_id, cuenta_neto_pagar_id, cuenta_prestaciones_id,
    ahorro_afc_pct, ahorro_anios_retiro, cuenta_ahorro_pagar_id, cuenta_aporte_ahorro_id)
  select date '2023-01-01', inss_laboral, inss_patronal, inatec, techo_inss, dias_vacaciones_mes, cuenta_salarios_id,
    cuenta_patronal_id, cuenta_inss_pagar_id, cuenta_ir_pagar_id, cuenta_inatec_pagar_id, cuenta_neto_pagar_id, cuenta_prestaciones_id,
    ahorro_afc_pct, ahorro_anios_retiro, cuenta_ahorro_pagar_id, cuenta_aporte_ahorro_id
    from planilla_parametros order by vigente_desde limit 1
  on conflict do nothing;

  -- Cuenta bancaria ficticia: los cheques y pagos simulados no tocan la numeración de la cuenta real
  insert into cuentas_bancarias (banco, nombre, numero_cuenta, moneda, cuenta_contable_id, proximo_cheque)
  values ('BANPRO', '[SIM] Cuenta de simulación', '0000000000', 'NIO', coalesce(_sim_cuenta('1.1.02'), _sim_cuenta('1.1.0%')), 1001)
  returning id into v_cb;

  -- Inventario: 4 bodegas, 12 categorías y 300 productos
  v_cta_inv := coalesce((select id from cuentas where acepta_movimientos and activa and nombre ilike 'inventario%' order by codigo limit 1), _sim_cuenta('1.1.07'));
  insert into bodegas (codigo, nombre, ubicacion, cuenta_inventario_id)
  select 'SIM-B' || g, '[SIM] ' || (array['Bodega central','Bodega de proyectos','Bodega de clínica','Bodega de construcción'])[g],
         (array['Chinandega','El Viejo','Chichigalpa','Posoltega'])[g], v_cta_inv
    from generate_series(1, 4) g;
  insert into categorias_producto (nombre)
  select '[SIM] ' || x from unnest(array['Materiales de construcción','Tuberías y accesorios','Medicamentos','Útiles de oficina','Herramientas',
    'Alimentos','Limpieza','Eléctricos','Agrícola','Combustible','Uniformes','Repuestos']) x
  on conflict (nombre) do nothing;
  for i in 1..300 loop
    select id into v_cat from categorias_producto where nombre like '[SIM]%' order by random() limit 1;
    v_nom := _sim_uno(array['UND','UND','UND','CAJA','PAQ','SACO','LB','GAL','M','ROLLO','BOLSA','LT']);
    select id into v_uni from unidades where codigo = v_nom;
    insert into productos (codigo, nombre, categoria_id, unidad_id, stock_minimo)
    values ('SIM-P' || lpad(i::text, 4, '0'),
            _sim_uno(array['Cemento','Tubo PVC','Codo PVC','Varilla','Clavo','Alambre','Paracetamol','Amoxicilina','Suero oral','Papel bond',
              'Lapicero','Folder','Pala','Machete','Martillo','Arroz','Frijol','Aceite','Cloro','Jabón','Cable','Bombillo','Semilla','Fertilizante',
              'Diésel','Gasolina','Camiseta','Bota','Filtro','Llanta']) || ' ' || (array['estándar','reforzado','pequeño','grande','2"','1/2"','industrial','económico'])[1 + floor(random() * 8)::int] || ' #' || i,
            v_cat, v_uni, round(_sim_azar(0, 50)))
    returning id into v_id;
    n_prod := n_prod + 1;
  end loop;

  -- 250 activos fijos comprados entre 2015 y 2026
  for i in 1..250 loop
    select * into c from activos_categorias where activa order by random() limit 1;
    v_costo := round(case c.nombre when 'Edificios' then _sim_azar(800000, 6000000) when 'Vehículos' then _sim_azar(450000, 1800000)
                 when 'Equipo de cómputo' then _sim_azar(12000, 60000) when 'Maquinaria y equipo' then _sim_azar(50000, 600000)
                 else _sim_azar(3000, 90000) end, 2);
    v_fecha := date '2015-01-01' + floor(random() * 4290)::int;
    v_ini := date_trunc('month', v_fecha + interval '1 month')::date;
    v_meses := greatest((extract(year from age(date '2024-01-01', v_ini)) * 12 + extract(month from age(date '2024-01-01', v_ini)))::int, 0);
    v_cuota := round(v_costo * 0.95 / c.vida_util_meses, 2);
    insert into activos_fijos (codigo, nombre, categoria_id, marca, serie, ubicacion, responsable, centro_costo_id, fecha_adquisicion,
                               inicio_depreciacion, costo, valor_residual, vida_util_meses, dep_inicial)
    values ('SIM-AF' || lpad(i::text, 4, '0'), '[SIM] ' || c.nombre || ' ' || i,
            c.id, _sim_uno(array['Toyota','Dell','HP','Lenovo','Samsung','Honda','Caterpillar','Sin marca']),
            upper(substr(md5(random()::text), 1, 10)), _sim_uno(lugares), _sim_uno(nombres) || ' ' || _sim_uno(apellidos),
            (select id from centros_costo where activo order by random() limit 1), v_fecha, v_ini, v_costo, round(v_costo * 0.05, 2),
            c.vida_util_meses, least(v_meses * v_cuota, v_costo - round(v_costo * 0.05, 2)));
    n_act := n_act + 1;
  end loop;

  return format('Colaboradores %s, productos %s, activos %s', n_emp, n_prod, n_act);
end $$;

-- Marcas de entrada y salida de un año (lunes a viernes, ~95 % de asistencia)
create or replace function sim_marcaje(p_anio int) returns text language plpgsql as $$
declare v_admin uuid := _sim_contexto(); n int;
begin
  perform setseed(0.31 + p_anio / 100000.0);
  insert into marcaje_marcas (id_externo, fecha, correo, nombre, entrada, salida, horas, lugar)
  select 'SIM-' || e.id || '-' || to_char(d, 'YYYYMMDD'), d, e.correo, e.nombre,
         '07:' || lpad(floor(random() * 30)::text, 2, '0'), '16:' || lpad(floor(random() * 50)::text, 2, '0'),
         round((8.5 + random() * 1.2)::numeric, 2), e.lugar
    from empleados e cross join generate_series(make_date(p_anio, 1, 1), least(make_date(p_anio, 12, 31), date '2026-10-31'), interval '1 day') g(d0)
    cross join lateral (select g.d0::date d) x
   where e.correo like '%@simulacion.invalid' and extract(isodow from d) <= 5 and random() < 0.95
     and d >= e.fecha_ingreso and d <= coalesce((select fecha from _simulacion_salidas s where s.empleado_id = e.id), d)
  on conflict do nothing;
  get diagnostics n = row_count;
  insert into marcaje_permisos (id_externo, correo, tipo, desde, hasta, motivo, estado)
  select 'SIM-P' || e.id || '-' || p_anio || '-' || g, e.correo,
         _sim_uno(array['Cita médica','Personal','Vacaciones','Cita médica','Llegada tarde']),
         make_date(p_anio, 1, 1) + floor(random() * 300)::int, null, '[SIM] Permiso', _sim_uno(array['Aprobado','Aprobado','Aprobado','Rechazado'])
    from empleados e cross join generate_series(1, 4) g
   where e.correo like '%@simulacion.invalid' and random() < 0.6
  on conflict do nothing;
  update marcaje_permisos set hasta = desde where id_externo like 'SIM-P%' and hasta is null;
  return format('Marcas %s: %s', p_anio, n);
end $$;

-- Planillas de un año: quincenas, mensuales, aguinaldo, liquidaciones, vacaciones, novedades y pago
create or replace function sim_planillas(p_anio int, p_mes_desde int default 1, p_mes_hasta int default 12) returns text language plpgsql as $$
declare
  v_admin uuid := _sim_contexto(); m int; q int; v_desde date; v_hasta date; v_id bigint; s record; v_cb bigint;
  n_pl int := 0; n_liq int := 0; v_ult date;
begin
  perform setseed(0.41 + p_anio / 100000.0 + p_mes_desde / 1000.0);
  select id into v_cb from cuentas_bancarias where nombre = '[SIM] Cuenta de simulación';
  for m in p_mes_desde..least(p_mes_hasta, case when p_anio = 2026 then 10 else 12 end) loop
    -- Aguinaldo antes de la primera quincena de diciembre
    if m = 12 then
      v_id := guardar_planilla(jsonb_build_object('tipo', 'aguinaldo', 'hasta', make_date(p_anio, 11, 30), 'descripcion', '[SIM] Aguinaldo ' || p_anio));
      delete from planilla_lineas l using empleados e where l.planilla_id = v_id and e.id = l.empleado_id and e.correo not like '%@simulacion.invalid';
      perform _recalcular_planilla(v_id);
      perform enviar_planilla(v_id); update planillas set creado_por = null where id = v_id;
      perform aprobar_planilla(v_id);
      perform pagar_planilla(v_id, v_cb, make_date(p_anio, 12, 10), 'SIM-AG' || p_anio, false);
      n_pl := n_pl + 1;
    end if;
    for q in 1..2 loop
      v_desde := make_date(p_anio, m, case q when 1 then 1 else 16 end);
      v_hasta := case q when 1 then make_date(p_anio, m, 15) else (make_date(p_anio, m, 1) + interval '1 month - 1 day')::date end;
      -- Quien sale en esta quincena: liquidación
      for s in select x.* from _simulacion_salidas x join empleados e on e.id = x.empleado_id
                where x.fecha between v_desde and v_hasta and e.activo and e.fecha_ingreso <= x.fecha loop
        v_ult := case when (select tipo_pago from empleados where id = s.empleado_id) = 'mensual'
                      then (date_trunc('month', s.fecha) - interval '1 day')::date else v_desde - 1 end;
        v_id := crear_liquidacion(jsonb_build_object('empleado_id', s.empleado_id, 'fecha_salida', s.fecha,
                                                     'ultimo_dia_pagado', least(v_ult, s.fecha), 'motivo', s.motivo));
        update planillas set descripcion = '[SIM] ' || descripcion where id = v_id;
        perform enviar_planilla(v_id); update planillas set creado_por = null where id = v_id;
        perform aprobar_planilla(v_id);
        perform pagar_planilla(v_id, v_cb, s.fecha, 'SIM-LQ' || v_id, false);
        n_liq := n_liq + 1;
      end loop;
      -- Quincenal
      v_id := guardar_planilla(jsonb_build_object('tipo', 'quincenal', 'desde', v_desde, 'hasta', v_hasta,
                                                  'descripcion', '[SIM] Quincena del ' || to_char(v_desde, 'DD/MM/YYYY') || ' al ' || to_char(v_hasta, 'DD/MM/YYYY')));
      delete from planilla_lineas l using empleados e where l.planilla_id = v_id and e.id = l.empleado_id and e.correo not like '%@simulacion.invalid';
      perform sim_novedades(v_id);
      perform enviar_planilla(v_id); update planillas set creado_por = null where id = v_id;
      perform aprobar_planilla(v_id);
      perform pagar_planilla(v_id, v_cb, v_hasta, 'SIM-Q' || v_id, false);
      n_pl := n_pl + 1;
    end loop;
    -- Mensual
    v_id := guardar_planilla(jsonb_build_object('tipo', 'mensual', 'desde', make_date(p_anio, m, 1), 'hasta', (make_date(p_anio, m, 1) + interval '1 month - 1 day')::date,
                                                'descripcion', '[SIM] Planilla mensual ' || to_char(make_date(p_anio, m, 1), 'MM/YYYY')));
    delete from planilla_lineas l using empleados e where l.planilla_id = v_id and e.id = l.empleado_id and e.correo not like '%@simulacion.invalid';
    perform sim_novedades(v_id);
    perform enviar_planilla(v_id); update planillas set creado_por = null where id = v_id;
    perform aprobar_planilla(v_id);
    perform pagar_planilla(v_id, v_cb, (make_date(p_anio, m, 1) + interval '1 month - 1 day')::date, 'SIM-M' || v_id, false);
    n_pl := n_pl + 1;
    -- Vacaciones tomadas en el mes
    insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen)
    select e.id, make_date(p_anio, m, 1 + floor(random() * 27)::int), 'tomadas', -(1 + floor(random() * 5)), '[SIM] Vacaciones', 'aprobado', 'manual'
      from empleados e where e.correo like '%@simulacion.invalid' and e.activo and random() < 0.08;
  end loop;
  return format('Planillas %s (%s-%s): %s, liquidaciones: %s', p_anio, p_mes_desde, p_mes_hasta, n_pl, n_liq);
end $$;

-- Bonos, viáticos, préstamos y adelantos al azar (directo y un solo recálculo)
create or replace function sim_novedades(p_planilla bigint) returns void language plpgsql as $$
begin
  insert into planilla_novedades (planilla_id, empleado_id, concepto_id, monto, descripcion)
  select l.planilla_id, l.empleado_id, c.id, round(_sim_azar(300, 3000) / 50) * 50, '[SIM]'
    from planilla_lineas l
    cross join lateral (select id from conceptos_planilla where codigo in ('BONO','VIAT','PREST','ADEL') and not sistema and l.empleado_id is not null order by random() limit 1) c
   where l.planilla_id = p_planilla and random() < 0.14;
  perform _recalcular_planilla(p_planilla);
end $$;

-- Asientos manuales de un mes (gastos, donaciones y traslados)
create or replace function sim_contabilidad(p_anio int, p_mes int, p_cantidad int default 320) returns text language plpgsql as $$
declare
  v_admin uuid := _sim_contexto(); i int; v_as bigint; v_tipo text; v_monto numeric; v_fecha date; v_ult int;
  gastos bigint[]; ingresos bigint[]; bancos bigint[]; v_g bigint; v_b bigint; n int := 0;
begin
  perform setseed(0.53 + p_anio / 100000.0 + p_mes / 1000.0);
  select array_agg(id) into gastos from cuentas where acepta_movimientos and activa and tipo in ('gasto','costo')
     and codigo not in ('6.1.01','6.1.02','6.1.04') and nombre not ilike '%aporte%' and nombre not ilike '%pérdida en baja%';
  select array_agg(id) into ingresos from cuentas where acepta_movimientos and activa and tipo = 'ingreso';
  select array_agg(id) into bancos from cuentas where acepta_movimientos and activa and codigo in ('1.1.01','1.1.02');
  v_ult := extract(day from make_date(p_anio, p_mes, 1) + interval '1 month - 1 day')::int;
  for i in 1..p_cantidad loop
    v_fecha := make_date(p_anio, p_mes, 1 + floor(random() * v_ult)::int);
    v_tipo := case when random() < 0.7 then 'egreso' when random() < 0.85 then 'ingreso' else 'diario' end;
    v_b := bancos[1 + floor(random() * array_length(bancos, 1))::int];
    insert into asientos (fecha, tipo, concepto, referencia, moneda)
    values (v_fecha, v_tipo, '[SIM] ' || case v_tipo when 'egreso' then _sim_uno(array['Pago de energía','Pago de agua','Compra de papelería','Combustible',
              'Viáticos de campo','Mantenimiento de vehículo','Pago a proveedor','Internet y teléfono','Materiales de proyecto','Alimentación de brigada'])
            when 'ingreso' then _sim_uno(array['Donación recibida','Aporte de iglesia hermana','Donación de brigada','Servicios de clínica','Reintegro'])
            else 'Reclasificación de gastos' end,
            'SIM-' || p_anio || lpad(p_mes::text, 2, '0') || '-' || i, 'NIO')
    returning id into v_as;
    v_monto := round(case when v_tipo = 'ingreso' then _sim_azar(5000, 450000) else _sim_azar(150, 60000) end, 2);
    if v_tipo = 'ingreso' then
      insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber) values
        (v_as, 1, v_b, 'Depósito', v_monto, 0),
        (v_as, 2, ingresos[1 + floor(random() * array_length(ingresos, 1))::int], '[SIM]', 0, v_monto);
    elsif v_tipo = 'egreso' then
      v_g := gastos[1 + floor(random() * array_length(gastos, 1))::int];
      insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
      select v_as, k, gastos[1 + floor(random() * array_length(gastos, 1))::int], (select id from centros_costo where activo order by random() limit 1),
             '[SIM]', round(v_monto / 3, 2), 0 from generate_series(1, 2) k;
      insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
      values (v_as, 3, v_g, (select id from centros_costo where activo order by random() limit 1), '[SIM]', v_monto - 2 * round(v_monto / 3, 2), 0),
             (v_as, 4, v_b, null, 'Pago', 0, v_monto);
    else
      insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber) values
        (v_as, 1, gastos[1 + floor(random() * array_length(gastos, 1))::int], (select id from centros_costo where activo order by random() limit 1), '[SIM]', v_monto, 0),
        (v_as, 2, gastos[1 + floor(random() * array_length(gastos, 1))::int], (select id from centros_costo where activo order by random() limit 1), '[SIM]', 0, v_monto);
    end if;
    perform _contabilizar(v_as);
    n := n + 1;
  end loop;
  return format('Asientos %s/%s: %s', p_mes, p_anio, n);
end $$;

-- Cheques de un mes, aprobados y la mayoría cobrados
create or replace function sim_cheques(p_anio int, p_mes int, p_cantidad int default 50) returns text language plpgsql as $$
declare v_admin uuid := _sim_contexto(); i int; v_id bigint; v_cb bigint; v_m numeric; v_f date; gastos bigint[]; n int := 0;
begin
  perform setseed(0.61 + p_anio / 100000.0 + p_mes / 1000.0);
  select id into v_cb from cuentas_bancarias where nombre = '[SIM] Cuenta de simulación';
  select array_agg(id) into gastos from cuentas where acepta_movimientos and activa and tipo in ('gasto','costo') and codigo not in ('6.1.01','6.1.02','6.1.04');
  for i in 1..p_cantidad loop
    v_m := round(_sim_azar(500, 120000), 2);
    v_f := make_date(p_anio, p_mes, 1 + floor(random() * 27)::int);
    v_id := guardar_cheque(jsonb_build_object('cuenta_bancaria_id', v_cb, 'fecha', v_f, 'monto', v_m,
              'beneficiario', '[SIM] ' || _sim_uno(array['Ferretería El Halcón','Distribuidora del Norte','ENATREL','ENACAL','Claro Nicaragua',
                'Gasolinera Puma','Farmacia Saba','Transportes Rivera','Librería Jardín','Constructora Occidente']),
              'concepto', '[SIM] ' || _sim_uno(array['Pago de factura','Compra de materiales','Servicios','Anticipo']),
              'lineas', jsonb_build_array(jsonb_build_object('cuenta_id', gastos[1 + floor(random() * array_length(gastos, 1))::int],
                'centro_costo_id', (select id from centros_costo where activo order by random() limit 1), 'debe', v_m))), true);
    update cheques set creado_por = null where id = v_id;
    perform aprobar_cheque(v_id);
    if random() < 0.85 then perform marcar_cobrado(v_id, true, least(v_f + floor(random() * 20)::int, date '2026-10-31')); end if;
    n := n + 1;
  end loop;
  return format('Cheques %s/%s: %s', p_mes, p_anio, n);
end $$;

-- Movimientos de inventario de un mes: compras, despachos y traslados
create or replace function sim_inventario(p_anio int, p_mes int) returns text language plpgsql as $$
declare
  v_admin uuid := _sim_contexto(); i int; v_bod bigint; v_dest bigint; v_f date; lineas jsonb; n int := 0;
  v_prov bigint := coalesce(_sim_cuenta('2.1.01'), _sim_cuenta('2.1.%')); v_gasto bigint := coalesce(_sim_cuenta('5.1'), _sim_cuenta('6.1.05'));
begin
  perform setseed(0.71 + p_anio / 100000.0 + p_mes / 1000.0);
  -- 40 compras
  for i in 1..40 loop
    v_bod := (select id from bodegas where codigo like 'SIM-B%' order by random() limit 1);
    v_f := make_date(p_anio, p_mes, 1 + floor(random() * 27)::int);
    select jsonb_agg(jsonb_build_object('producto_id', id, 'cantidad', round(_sim_azar(5, 120)), 'costo', round(_sim_azar(15, 2500), 2)))
      into lineas from (select id from productos where codigo like 'SIM-P%' order by random() limit (2 + floor(random() * 5))::int) p;
    perform guardar_movimiento(jsonb_build_object('tipo', 'entrada', 'fecha', v_f, 'bodega_id', v_bod, 'concepto', '[SIM] Compra a proveedor',
      'referencia', 'SIM-F' || p_anio || p_mes || i, 'cuenta_contrapartida_id', v_prov, 'lineas', lineas), true);
    n := n + 1;
  end loop;
  -- 80 despachos (sin pasar de la existencia)
  for i in 1..80 loop
    select e.bodega_id into v_bod from existencias e join bodegas b on b.id = e.bodega_id where b.codigo like 'SIM-B%' and e.cantidad > 2 order by random() limit 1;
    exit when v_bod is null;
    v_f := make_date(p_anio, p_mes, 1 + floor(random() * 27)::int);
    select jsonb_agg(jsonb_build_object('producto_id', producto_id, 'cantidad', greatest(1, floor(cantidad * _sim_azar(0.05, 0.35)))))
      into lineas from (select producto_id, cantidad from existencias where bodega_id = v_bod and cantidad > 2 order by random() limit (1 + floor(random() * 4))::int) x;
    perform guardar_movimiento(jsonb_build_object('tipo', 'salida', 'fecha', v_f, 'bodega_id', v_bod, 'concepto', '[SIM] Despacho a proyecto',
      'cuenta_contrapartida_id', v_gasto, 'centro_costo_id', (select id from centros_costo where activo order by random() limit 1), 'lineas', lineas), true);
    n := n + 1;
  end loop;
  -- 8 traslados
  for i in 1..8 loop
    select e.bodega_id into v_bod from existencias e join bodegas b on b.id = e.bodega_id where b.codigo like 'SIM-B%' and e.cantidad > 5 order by random() limit 1;
    exit when v_bod is null;
    select id into v_dest from bodegas where codigo like 'SIM-B%' and id <> v_bod order by random() limit 1;
    select jsonb_agg(jsonb_build_object('producto_id', producto_id, 'cantidad', greatest(1, floor(cantidad * 0.2))))
      into lineas from (select producto_id, cantidad from existencias where bodega_id = v_bod and cantidad > 5 order by random() limit 2) x;
    perform guardar_movimiento(jsonb_build_object('tipo', 'traslado', 'fecha', make_date(p_anio, p_mes, 28), 'bodega_id', v_bod,
      'bodega_destino_id', v_dest, 'concepto', '[SIM] Traslado entre bodegas', 'lineas', lineas), true);
    n := n + 1;
  end loop;
  return format('Inventario %s/%s: %s movimientos', p_mes, p_anio, n);
end $$;

-- Depreciación mensual y algunas bajas
create or replace function sim_activos(p_anio int) returns text language plpgsql as $$
declare v_admin uuid := _sim_contexto(); m int; a record; n int := 0;
begin
  perform setseed(0.83 + p_anio / 100000.0);
  for m in 1..case when p_anio = 2026 then 10 else 12 end loop
    -- un par de bajas al año (antes de depreciar el mes)
    if m in (4, 9) then
      for a in select id from activos_fijos where codigo like 'SIM-AF%' and estado = 'activo' and fecha_adquisicion < make_date(p_anio, m, 1) order by random() limit 2 loop
        perform dar_baja_activo(a.id, jsonb_build_object('fecha', (make_date(p_anio, m, 1) - 1), 'tipo', _sim_uno(array['descarte','venta','robo']),
          'valor_venta', 0, 'motivo', '[SIM] Baja simulada'));
      end loop;
    end if;
    if exists (select 1 from depreciaciones where anio = p_anio and mes = m and estado = 'registrada') then
      raise exception 'Ya hay depreciación real de %/%; la simulación no la puede registrar', m, p_anio;
    end if;
    perform registrar_depreciacion(p_anio, m);
    n := n + 1;
  end loop;
  return format('Depreciación %s: %s meses', p_anio, n);
end $$;

-- Cuánto ocupa la base de datos
create or replace function sim_resumen() returns table (tabla text, filas bigint, tamano text) language sql as $$
  select tabla, filas, tamano from (
  select c.relname::text tabla, c.reltuples::bigint filas, pg_size_pretty(pg_total_relation_size(c.oid)) tamano, pg_total_relation_size(c.oid) b
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
  union all select '— TOTAL BASE DE DATOS —', null, pg_size_pretty(pg_database_size(current_database())), pg_database_size(current_database())
  ) x order by b desc
$$;

revoke execute on function sim_maestros(), sim_marcaje(int), sim_planillas(int, int, int), sim_novedades(bigint), sim_contabilidad(int, int, int),
  sim_cheques(int, int, int), sim_inventario(int, int), sim_activos(int), sim_resumen() from public, anon, authenticated;

select 'Funciones de simulación listas' as resultado;
