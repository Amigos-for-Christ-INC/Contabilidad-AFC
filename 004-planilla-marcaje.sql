-- =====================================================================
-- Contabilidad AFC — Migración 004: planilla, vacaciones y app de marcaje
-- Ejecutar UNA vez, después de 003-bancos-cheques.sql.
--
-- Reglas de AFC:
--   * No se pagan horas extra. Cada día extra trabajado se suma al saldo
--     de vacaciones cuando Administración lo aprueba.
--   * La planilla la elabora una persona y la aprueba otra; al aprobarla se
--     registra el asiento contable y se acumulan las vacaciones del período.
--   * Tasas de INSS, INATEC, techo del INSS y tramos del IR viven en tablas
--     con fecha de vigencia. Confirmarlas con el contador.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Permisos y roles
--   planilla.ver        ver colaboradores, salarios, planillas y vacaciones
--   planilla.editar     colaboradores, elaborar planillas, novedades y vacaciones
--   planilla.aprobar    aprobar, devolver y anular planillas (nunca las que uno elaboró)
--   planilla.config     tasas, tramos del IR, conceptos, cuentas e integración con marcaje
--   vacaciones.aprobar  aprobar o rechazar los días extra que suman a vacaciones
-- ---------------------------------------------------------------------
create or replace function permisos_validos() returns text[]
language sql immutable as $$
  select array['contabilidad.ver','contabilidad.editar','contabilidad.periodos',
               'inventario.ver','inventario.editar','inventario.anular','inventario.catalogo','inventario.todas_bodegas',
               'bancos.ver','bancos.emitir','bancos.aprobar','bancos.anular','bancos.cuentas',
               'planilla.ver','planilla.editar','planilla.aprobar','planilla.config','vacaciones.aprobar',
               'admin.usuarios']
$$;

insert into roles (nombre, descripcion, permisos) values
  ('Recursos Humanos', 'Colaboradores, elaboración de planillas y vacaciones',
   array['planilla.ver','planilla.editar','planilla.config']),
  ('Administración', 'Aprueba planillas y los días extra que suman a vacaciones',
   array['planilla.ver','planilla.aprobar','vacaciones.aprobar'])
on conflict (nombre) do nothing;

alter table asientos drop constraint asientos_origen_check;
alter table asientos add constraint asientos_origen_check check (origen in ('manual','inventario','cheque','planilla'));

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
  if v_estado <> 'contabilizado' then raise exception 'Solo se anulan asientos contabilizados'; end if;
  update asientos
     set estado = 'anulado', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo)
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 2. Cuentas contables de la planilla (se reutilizan si ya existen por nombre)
-- ---------------------------------------------------------------------
create or replace function _cuenta_planilla(p_nombre text, p_padre text, p_tipo tipo_cuenta, p_nat naturaleza, p_codigo text default null)
returns bigint language plpgsql set search_path = public as $$
declare v_id bigint; v_cod text; n int;
begin
  select id into v_id from cuentas where lower(nombre) = lower(p_nombre) and acepta_movimientos order by id limit 1;
  if v_id is not null then return v_id; end if;
  if p_codigo is not null then
    select id into v_id from cuentas where codigo = p_codigo and acepta_movimientos and tipo = p_tipo;
    if v_id is not null then return v_id; end if;
  end if;
  select coalesce(max(nullif(regexp_replace(substr(codigo, length(p_padre) + 2), '\D', '', 'g'), '')::int), 0) + 1 into n
    from cuentas where codigo like p_padre || '.%' and codigo !~ ('^' || replace(p_padre, '.', '\.') || '\.[^.]+\.');
  v_cod := p_padre || '.' || lpad(n::text, 2, '0');
  insert into cuentas (codigo, nombre, tipo, naturaleza) values (v_cod, p_nombre, p_tipo, p_nat) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- 3. Colaboradores
-- ---------------------------------------------------------------------
create table empleados (
  id              bigint generated always as identity primary key,
  codigo          text unique,
  nombre          text not null check (length(trim(nombre)) > 0),
  correo          text unique check (correo = lower(trim(correo))),
  cedula          text,
  inss_numero     text,
  cargo           text,
  lugar           text,
  lider_correo    text,
  centro_costo_id bigint references centros_costo(id),
  fecha_ingreso   date,
  fecha_baja      date,
  tipo_pago       text not null default 'quincenal' check (tipo_pago in ('quincenal','mensual')),
  salario_mensual numeric(14,2) not null default 0 check (salario_mensual >= 0),
  cuenta_banco    text,
  activo          boolean not null default true,
  origen          text not null default 'manual' check (origen in ('manual','marcaje')),
  notas           text,
  creado_en       timestamptz not null default now(),
  actualizado_en  timestamptz not null default now(),
  check (fecha_baja is null or fecha_ingreso is null or fecha_baja >= fecha_ingreso)
);
create trigger bitacora_empleados after insert or update or delete on empleados for each row execute function registrar_bitacora();
create or replace function _empleado_actualizado() returns trigger language plpgsql as $$
begin new.actualizado_en := now(); if new.correo is not null then new.correo := lower(trim(new.correo)); end if; return new; end $$;
create trigger empleado_actualizado before insert or update on empleados for each row execute function _empleado_actualizado();

-- ---------------------------------------------------------------------
-- 4. Parámetros legales con vigencia
-- ---------------------------------------------------------------------
create table planilla_parametros (
  id                     bigint generated always as identity primary key,
  vigente_desde          date not null unique,
  inss_laboral           numeric(6,3) not null check (inss_laboral between 0 and 100),
  inss_patronal          numeric(6,3) not null check (inss_patronal between 0 and 100),
  inatec                 numeric(6,3) not null check (inatec between 0 and 100),
  techo_inss             numeric(14,2) check (techo_inss > 0),          -- mensual; vacío = sin techo
  dias_vacaciones_mes    numeric(5,2) not null default 2.5,
  cuenta_salarios_id     bigint not null references cuentas(id),
  cuenta_patronal_id     bigint not null references cuentas(id),
  cuenta_inss_pagar_id   bigint not null references cuentas(id),
  cuenta_ir_pagar_id     bigint not null references cuentas(id),
  cuenta_inatec_pagar_id bigint not null references cuentas(id),
  cuenta_neto_pagar_id   bigint not null references cuentas(id)
);
create trigger bitacora_planilla_parametros after insert or update or delete on planilla_parametros for each row execute function registrar_bitacora();

create table ir_tramos (
  id            bigint generated always as identity primary key,
  vigente_desde date not null,
  desde         numeric(14,2) not null check (desde >= 0),   -- renta anual, exclusivo
  hasta         numeric(14,2),                               -- inclusivo; vacío = sin límite
  base          numeric(14,2) not null default 0,
  porcentaje    numeric(6,3) not null check (porcentaje between 0 and 100),
  unique (vigente_desde, desde)
);
create trigger bitacora_ir_tramos after insert or update or delete on ir_tramos for each row execute function registrar_bitacora();

create table conceptos_planilla (
  id          bigint generated always as identity primary key,
  codigo      text not null unique,
  nombre      text not null,
  tipo        text not null check (tipo in ('ingreso','deduccion')),
  afecta_inss boolean not null default true,     -- solo ingresos
  afecta_ir   boolean not null default true,     -- solo ingresos
  cuenta_id   bigint references cuentas(id),     -- ingreso: gasto (vacío = sueldos); deducción: obligatoria
  activo      boolean not null default true
);
create trigger bitacora_conceptos_planilla after insert or update or delete on conceptos_planilla for each row execute function registrar_bitacora();

-- ---------------------------------------------------------------------
-- 5. Planillas
-- ---------------------------------------------------------------------
create table planillas (
  id                   bigint generated always as identity primary key,
  tipo                 text not null check (tipo in ('quincenal','mensual')),
  desde                date not null,
  hasta                date not null,
  fecha_pago           date not null,
  descripcion          text not null,
  estado               text not null default 'borrador' check (estado in ('borrador','por_aprobar','aprobada','anulada')),
  empleados            int not null default 0,
  total_bruto          numeric(16,2) not null default 0,
  total_inss_laboral   numeric(16,2) not null default 0,
  total_ir             numeric(16,2) not null default 0,
  total_deducciones    numeric(16,2) not null default 0,
  total_neto           numeric(16,2) not null default 0,
  total_inss_patronal  numeric(16,2) not null default 0,
  total_inatec         numeric(16,2) not null default 0,
  creado_por           uuid default auth.uid(),
  creado_en            timestamptz not null default now(),
  enviado_en           timestamptz,
  aprobado_por         uuid,
  aprobado_en          timestamptz,
  devuelto_por         uuid,
  motivo_devolucion    text,
  asiento_id           bigint references asientos(id),
  asiento_anulacion_id bigint references asientos(id),
  anulado_por          uuid,
  anulado_en           timestamptz,
  motivo_anulacion     text,
  check (hasta >= desde)
);
create trigger bitacora_planillas after insert or update or delete on planillas for each row execute function registrar_bitacora();

create table planilla_lineas (
  id               bigint generated always as identity primary key,
  planilla_id      bigint not null references planillas(id) on delete cascade,
  empleado_id      bigint not null references empleados(id),
  centro_costo_id  bigint references centros_costo(id),
  salario_mensual  numeric(14,2) not null default 0,
  dias_periodo     numeric(5,2) not null default 0,
  dias_no_pagados  numeric(5,2) not null default 0 check (dias_no_pagados >= 0),
  salario_periodo  numeric(14,2) not null default 0,
  ingresos         numeric(14,2) not null default 0,
  ingresos_inss    numeric(14,2) not null default 0,
  ingresos_ir      numeric(14,2) not null default 0,
  bruto            numeric(14,2) not null default 0,
  base_inss        numeric(14,2) not null default 0,
  inss_laboral     numeric(14,2) not null default 0,
  base_ir          numeric(14,2) not null default 0,
  ir               numeric(14,2) not null default 0,
  deducciones      numeric(14,2) not null default 0,
  neto             numeric(14,2) not null default 0,
  inss_patronal    numeric(14,2) not null default 0,
  inatec           numeric(14,2) not null default 0,
  unique (planilla_id, empleado_id)
);

create table planilla_novedades (
  id          bigint generated always as identity primary key,
  planilla_id bigint not null references planillas(id) on delete cascade,
  empleado_id bigint not null references empleados(id),
  concepto_id bigint not null references conceptos_planilla(id),
  monto       numeric(14,2) not null check (monto > 0),
  descripcion text
);

-- ---------------------------------------------------------------------
-- 6. Vacaciones (saldo = suma de movimientos aprobados)
-- ---------------------------------------------------------------------
create table vacaciones_movimientos (
  id           bigint generated always as identity primary key,
  empleado_id  bigint not null references empleados(id),
  fecha        date not null,
  tipo         text not null check (tipo in ('saldo_inicial','acumulado','tomadas','dia_extra','ajuste')),
  dias         numeric(6,2) not null check (dias <> 0),
  descripcion  text,
  estado       text not null default 'aprobado' check (estado in ('pendiente','aprobado','rechazado','anulado')),
  origen       text not null default 'manual' check (origen in ('manual','marcaje','planilla')),
  planilla_id  bigint references planillas(id),
  ref_externa  text unique,
  creado_por   uuid default auth.uid(),
  creado_en    timestamptz not null default now(),
  revisado_por uuid,
  revisado_en  timestamptz,
  motivo       text
);
create trigger bitacora_vacaciones after insert or update or delete on vacaciones_movimientos for each row execute function registrar_bitacora();

-- ---------------------------------------------------------------------
-- 7. Datos recibidos de la app de marcaje
-- ---------------------------------------------------------------------
create table marcaje_marcas (
  id_externo  text primary key,
  fecha       date not null,
  correo      text not null,
  nombre      text,
  entrada     text,
  salida      text,
  horas       numeric(6,2),
  lugar       text,
  recibido_en timestamptz not null default now()
);
create index on marcaje_marcas (correo, fecha);

create table marcaje_permisos (
  id_externo  text primary key,
  correo      text not null,
  tipo        text,
  desde       date,
  hasta       date,
  hora_desde  text,
  hora_hasta  text,
  estado      text,
  motivo      text,
  recibido_en timestamptz not null default now()
);

create table integracion_claves (
  id         bigint generated always as identity primary key,
  nombre     text not null,
  hash       text not null unique,
  activa     boolean not null default true,
  creado_por uuid default auth.uid(),
  creado_en  timestamptz not null default now(),
  ultimo_uso timestamptz,
  ultimo_resultado jsonb
);

-- ---------------------------------------------------------------------
-- 8. Cálculo
-- ---------------------------------------------------------------------
create or replace function _parametros_planilla(p_fecha date) returns planilla_parametros
language sql stable set search_path = public as $$
  select * from planilla_parametros where vigente_desde <= p_fecha order by vigente_desde desc limit 1
$$;

-- IR del período: se proyecta la base al año, se aplica la tabla y se divide
create or replace function ir_periodo(p_base numeric, p_periodos_anio int, p_fecha date) returns numeric
language plpgsql stable set search_path = public as $$
declare v_anual numeric := greatest(p_base, 0) * p_periodos_anio; v_vig date; t ir_tramos%rowtype;
begin
  select max(vigente_desde) into v_vig from ir_tramos where vigente_desde <= p_fecha;
  if v_vig is null then raise exception 'No hay tabla del IR vigente para %', p_fecha; end if;
  select * into t from ir_tramos
   where vigente_desde = v_vig and v_anual > desde and (hasta is null or v_anual <= hasta)
   order by desde desc limit 1;
  if not found then return 0; end if;
  return round((t.base + (v_anual - t.desde) * t.porcentaje / 100) / p_periodos_anio, 2);
end $$;

create or replace function _recalcular_planilla(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  pl planillas%rowtype; par planilla_parametros; l record; e empleados%rowtype;
  v_dias_std numeric; v_per int; v_ini date; v_fin date; v_dias numeric; v_sal numeric;
  v_ing numeric; v_ing_inss numeric; v_ing_ir numeric; v_ded numeric; v_bruto numeric;
  v_base_inss numeric; v_inss numeric; v_base_ir numeric; v_ir numeric; v_techo numeric;
begin
  select * into pl from planillas where id = p_id;
  par := _parametros_planilla(pl.hasta);
  if par.id is null then raise exception 'Configure los parámetros de planilla vigentes para %', pl.hasta; end if;
  v_dias_std := case pl.tipo when 'mensual' then 30 else 15 end;
  v_per      := case pl.tipo when 'mensual' then 12 else 24 end;
  v_techo    := case when par.techo_inss is null then null else par.techo_inss * v_dias_std / 30 end;

  for l in select * from planilla_lineas where planilla_id = p_id loop
    select * into e from empleados where id = l.empleado_id;
    -- Días del período: completos salvo ingreso o baja dentro del período
    v_ini := greatest(pl.desde, coalesce(e.fecha_ingreso, pl.desde));
    v_fin := least(pl.hasta, coalesce(e.fecha_baja, pl.hasta));
    if v_ini = pl.desde and v_fin = pl.hasta then v_dias := v_dias_std;
    else v_dias := least(v_dias_std, greatest(v_fin - v_ini + 1, 0)); end if;
    v_dias := greatest(v_dias - l.dias_no_pagados, 0);
    v_sal  := round(e.salario_mensual / 30 * v_dias, 2);

    select coalesce(sum(n.monto) filter (where c.tipo = 'ingreso'), 0),
           coalesce(sum(n.monto) filter (where c.tipo = 'ingreso' and c.afecta_inss), 0),
           coalesce(sum(n.monto) filter (where c.tipo = 'ingreso' and c.afecta_ir), 0),
           coalesce(sum(n.monto) filter (where c.tipo = 'deduccion'), 0)
      into v_ing, v_ing_inss, v_ing_ir, v_ded
      from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id
     where n.planilla_id = p_id and n.empleado_id = l.empleado_id;

    v_bruto     := v_sal + v_ing;
    v_base_inss := v_sal + v_ing_inss;
    if v_techo is not null then v_base_inss := least(v_base_inss, v_techo); end if;
    v_inss      := round(v_base_inss * par.inss_laboral / 100, 2);
    v_base_ir   := greatest(v_sal + v_ing_ir - v_inss, 0);
    v_ir        := ir_periodo(v_base_ir, v_per, pl.hasta);

    update planilla_lineas set
      salario_mensual = e.salario_mensual, dias_periodo = v_dias_std, salario_periodo = v_sal,
      ingresos = v_ing, ingresos_inss = v_ing_inss, ingresos_ir = v_ing_ir, bruto = v_bruto,
      base_inss = v_base_inss, inss_laboral = v_inss, base_ir = v_base_ir, ir = v_ir,
      deducciones = v_ded, neto = v_bruto - v_inss - v_ir - v_ded,
      inss_patronal = round(v_base_inss * par.inss_patronal / 100, 2),
      inatec = round(v_bruto * par.inatec / 100, 2)
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

create or replace function _planilla_editable(p_id bigint) returns planillas
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype;
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso para elaborar planillas'; end if;
  select * into pl from planillas where id = p_id for update;
  if not found then raise exception 'La planilla no existe'; end if;
  if pl.estado <> 'borrador' then raise exception 'Solo se modifican planillas en borrador'; end if;
  return pl;
end $$;

-- Crea o actualiza el encabezado y agrega a los colaboradores activos que correspondan
create or replace function guardar_planilla(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p->>'id', '')::bigint; pl planillas%rowtype;
  v_tipo text := p->>'tipo'; v_desde date := (p->>'desde')::date; v_hasta date := (p->>'hasta')::date;
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso para elaborar planillas'; end if;
  if v_tipo not in ('quincenal','mensual') then raise exception 'Tipo de planilla no válido'; end if;
  if v_desde is null or v_hasta is null or v_hasta < v_desde then raise exception 'Revise las fechas del período'; end if;
  if v_hasta - v_desde > 31 then raise exception 'El período no puede pasar de un mes'; end if;
  if v_id is null then
    if exists (select 1 from planillas where tipo = v_tipo and estado <> 'anulada' and desde <= v_hasta and hasta >= v_desde) then
      raise exception 'Ya existe una planilla % que cubre esas fechas', v_tipo;
    end if;
    insert into planillas (tipo, desde, hasta, fecha_pago, descripcion)
    values (v_tipo, v_desde, v_hasta, coalesce(nullif(p->>'fecha_pago', '')::date, v_hasta),
            coalesce(nullif(trim(p->>'descripcion'), ''), 'Planilla ' || v_tipo || ' del ' || to_char(v_desde, 'DD/MM/YYYY') || ' al ' || to_char(v_hasta, 'DD/MM/YYYY')))
    returning id into v_id;
  else
    pl := _planilla_editable(v_id);
    update planillas set fecha_pago = coalesce(nullif(p->>'fecha_pago', '')::date, fecha_pago),
                         descripcion = coalesce(nullif(trim(p->>'descripcion'), ''), descripcion)
     where id = v_id;
  end if;
  select * into pl from planillas where id = v_id;
  insert into planilla_lineas (planilla_id, empleado_id, centro_costo_id)
  select v_id, e.id, e.centro_costo_id from empleados e
   where e.activo and e.tipo_pago = pl.tipo and e.salario_mensual > 0
     and coalesce(e.fecha_ingreso, pl.desde) <= pl.hasta and coalesce(e.fecha_baja, pl.hasta) >= pl.desde
  on conflict (planilla_id, empleado_id) do nothing;
  perform _recalcular_planilla(v_id);
  return v_id;
end $$;

create or replace function agregar_empleado_planilla(p_planilla bigint, p_empleado bigint) returns void
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype;
begin
  pl := _planilla_editable(p_planilla);
  insert into planilla_lineas (planilla_id, empleado_id, centro_costo_id)
  select pl.id, id, centro_costo_id from empleados where id = p_empleado
  on conflict do nothing;
  perform _recalcular_planilla(pl.id);
end $$;

create or replace function quitar_empleado_planilla(p_linea bigint) returns void
language plpgsql security definer set search_path = public as $$
declare l planilla_lineas%rowtype; pl planillas%rowtype;
begin
  select * into l from planilla_lineas where id = p_linea;
  if not found then raise exception 'La línea no existe'; end if;
  pl := _planilla_editable(l.planilla_id);
  delete from planilla_novedades where planilla_id = l.planilla_id and empleado_id = l.empleado_id;
  delete from planilla_lineas where id = p_linea;
  perform _recalcular_planilla(pl.id);
end $$;

create or replace function actualizar_linea_planilla(p_linea bigint, p_dias_no_pagados numeric, p_centro bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare l planilla_lineas%rowtype; pl planillas%rowtype;
begin
  select * into l from planilla_lineas where id = p_linea;
  if not found then raise exception 'La línea no existe'; end if;
  pl := _planilla_editable(l.planilla_id);
  if p_dias_no_pagados < 0 or p_dias_no_pagados > l.dias_periodo then raise exception 'Días no pagados fuera del rango del período'; end if;
  update planilla_lineas set dias_no_pagados = coalesce(p_dias_no_pagados, 0), centro_costo_id = coalesce(p_centro, centro_costo_id)
   where id = p_linea;
  perform _recalcular_planilla(pl.id);
end $$;

create or replace function guardar_novedad(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype; v_id bigint; c conceptos_planilla%rowtype;
begin
  pl := _planilla_editable((p->>'planilla_id')::bigint);
  select * into c from conceptos_planilla where id = (p->>'concepto_id')::bigint and activo;
  if not found then raise exception 'Concepto no válido'; end if;
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
  delete from planilla_novedades where id = p_id;
  perform _recalcular_planilla(pl.id);
end $$;

create or replace function recalcular_planilla(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype;
begin pl := _planilla_editable(p_id); perform _recalcular_planilla(p_id); end $$;

create or replace function eliminar_planilla(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype;
begin pl := _planilla_editable(p_id); delete from planillas where id = p_id; end $$;

create or replace function enviar_planilla(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype;
begin
  pl := _planilla_editable(p_id);
  perform _recalcular_planilla(p_id);
  if not exists (select 1 from planilla_lineas where planilla_id = p_id) then raise exception 'La planilla no tiene colaboradores'; end if;
  if exists (select 1 from planilla_lineas where planilla_id = p_id and neto < 0) then
    raise exception 'Hay colaboradores con neto negativo; revise sus deducciones';
  end if;
  update planillas set estado = 'por_aprobar', enviado_en = now(), motivo_devolucion = null where id = p_id;
end $$;

create or replace function retirar_planilla(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso'; end if;
  update planillas set estado = 'borrador' where id = p_id and estado = 'por_aprobar' and creado_por = auth.uid();
  if not found then raise exception 'Solo quien elaboró la planilla puede retirarla mientras espera aprobación'; end if;
end $$;

create or replace function devolver_planilla(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'No tiene permiso para revisar planillas'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo de la devolución'; end if;
  update planillas set estado = 'borrador', devuelto_por = auth.uid(), motivo_devolucion = trim(p_motivo)
   where id = p_id and estado = 'por_aprobar';
  if not found then raise exception 'Solo se devuelven planillas enviadas a aprobación'; end if;
end $$;

create or replace function aprobar_planilla(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  pl planillas%rowtype; par planilla_parametros; v_as bigint; i int := 0; r record;
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'No tiene permiso para aprobar planillas'; end if;
  select * into pl from planillas where id = p_id for update;
  if not found then raise exception 'La planilla no existe'; end if;
  if pl.estado <> 'por_aprobar' then raise exception 'Solo se aprueban planillas enviadas a aprobación'; end if;
  if pl.creado_por = auth.uid() then raise exception 'Quien elaboró la planilla no puede aprobarla; debe hacerlo otra persona'; end if;
  par := _parametros_planilla(pl.hasta);

  insert into asientos (fecha, tipo, concepto, referencia, moneda, origen)
  values (pl.hasta, 'diario', left(pl.descripcion, 500), 'PL-' || pl.id, 'NIO', 'planilla')
  returning id into v_as;

  -- Gasto: salarios e ingresos por centro de costo; aportes patronales por centro
  for r in
    select cuenta_id, centro_costo_id, descripcion, sum(monto) monto from (
      select par.cuenta_salarios_id cuenta_id, l.centro_costo_id, 'Salarios' descripcion, l.salario_periodo monto
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

  -- Pasivos y deducciones
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

  -- Vacaciones acumuladas del período (2.5 días por mes trabajado)
  insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen, planilla_id, revisado_por, revisado_en)
  select l.empleado_id, pl.hasta, 'acumulado',
         round(par.dias_vacaciones_mes * (case when l.salario_mensual > 0 then l.salario_periodo / l.salario_mensual else 0 end), 2),
         pl.descripcion, 'aprobado', 'planilla', pl.id, auth.uid(), now()
    from planilla_lineas l
   where l.planilla_id = p_id
     and round(par.dias_vacaciones_mes * (case when l.salario_mensual > 0 then l.salario_periodo / l.salario_mensual else 0 end), 2) <> 0;

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
  update planillas set estado = 'anulada', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo),
         asiento_anulacion_id = v_as
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 9. Vacaciones
-- ---------------------------------------------------------------------
create or replace function registrar_vacaciones(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_tipo text := p->>'tipo'; v_dias numeric := (p->>'dias')::numeric; v_id bigint;
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso para registrar vacaciones'; end if;
  if v_tipo not in ('saldo_inicial','tomadas','dia_extra','ajuste') then raise exception 'Tipo de movimiento no válido'; end if;
  if v_dias is null or v_dias = 0 then raise exception 'Indique los días'; end if;
  if v_tipo = 'tomadas' then v_dias := -abs(v_dias); end if;
  if v_tipo = 'dia_extra' then v_dias := abs(v_dias); end if;
  if v_tipo = 'ajuste' and coalesce(trim(p->>'descripcion'), '') = '' then raise exception 'Explique el motivo del ajuste'; end if;
  insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen)
  values ((p->>'empleado_id')::bigint, coalesce((p->>'fecha')::date, (now() at time zone 'America/Managua')::date), v_tipo, v_dias,
          nullif(trim(p->>'descripcion'), ''), case when v_tipo = 'dia_extra' then 'pendiente' else 'aprobado' end, 'manual')
  returning id into v_id;
  return v_id;
end $$;

create or replace function revisar_dia_extra(p_id bigint, p_aprobar boolean, p_motivo text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('vacaciones.aprobar') then raise exception 'Solo Administración aprueba los días extra'; end if;
  if not p_aprobar and coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo del rechazo'; end if;
  update vacaciones_movimientos
     set estado = case when p_aprobar then 'aprobado' else 'rechazado' end,
         revisado_por = auth.uid(), revisado_en = now(), motivo = nullif(trim(p_motivo), '')
   where id = p_id and tipo = 'dia_extra' and estado = 'pendiente';
  if not found then raise exception 'Ese día extra ya fue revisado'; end if;
end $$;

create or replace function anular_vacaciones(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('planilla.editar') then raise exception 'No tiene permiso'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo'; end if;
  update vacaciones_movimientos set estado = 'anulado', motivo = trim(p_motivo), revisado_por = auth.uid(), revisado_en = now()
   where id = p_id and origen = 'manual' and estado in ('aprobado','pendiente');
  if not found then raise exception 'Solo se anulan movimientos registrados a mano; los de planilla o marcaje se corrigen en su origen'; end if;
end $$;

create or replace function saldos_vacaciones()
returns table (empleado_id bigint, saldo numeric, extra_pendientes numeric, tomadas_anio numeric)
language sql stable security definer set search_path = public as $$
  select e.id,
         coalesce(sum(m.dias) filter (where m.estado = 'aprobado'), 0),
         coalesce(sum(m.dias) filter (where m.estado = 'pendiente'), 0),
         coalesce(-sum(m.dias) filter (where m.estado = 'aprobado' and m.tipo = 'tomadas'
                                       and extract(year from m.fecha) = extract(year from now() at time zone 'America/Managua')), 0)
    from empleados e left join vacaciones_movimientos m on m.empleado_id = e.id
   where tiene_permiso('planilla.ver') or tiene_permiso('vacaciones.aprobar')
   group by e.id
$$;

-- ---------------------------------------------------------------------
-- 10. Puente con la app de marcaje
-- ---------------------------------------------------------------------
create or replace function _hash_clave(p text) returns text language sql immutable as $$
  select encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex')
$$;

create or replace function crear_clave_integracion(p_nombre text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not tiene_permiso('planilla.config') then raise exception 'No tiene permiso para crear claves de integración'; end if;
  insert into integracion_claves (nombre, hash) values (coalesce(nullif(trim(p_nombre), ''), 'App de marcaje'), _hash_clave(v));
  return 'afc_' || v;
end $$;

create or replace function desactivar_clave_integracion(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('planilla.config') then raise exception 'No tiene permiso'; end if;
  update integracion_claves set activa = false where id = p_id;
end $$;

-- Días laborables entre dos fechas (sin fines de semana ni feriados)
create or replace function _dias_laborables(p_desde date, p_hasta date, p_dias int[], p_feriados date[]) returns int
language sql immutable as $$
  select count(*)::int from generate_series(p_desde, p_hasta, interval '1 day') g
   where extract(isodow from g)::int = any(p_dias) and not (g::date = any(coalesce(p_feriados, '{}')))
$$;

-- La llama el Apps Script del marcaje con su clave. Recibe empleados,
-- marcas y permisos; devuelve cuántos registros procesó.
create or replace function recibir_marcaje(p_clave text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_clave integracion_claves%rowtype; x jsonb; v_emp bigint; v_dias int[]; v_fer date[];
  v_horas_dia numeric := coalesce(nullif(p->>'horas_dia', '')::numeric, 8);
  n_emp int := 0; n_mar int := 0; n_per int := 0; n_ext int := 0; n_vac int := 0; v_d numeric; v_fecha date; v_res jsonb;
begin
  select * into v_clave from integracion_claves where hash = _hash_clave(regexp_replace(coalesce(p_clave, ''), '^afc_', '')) and activa;
  if not found then raise exception 'Clave de integración no válida'; end if;

  v_dias := coalesce((select array_agg(value::int) from jsonb_array_elements_text(p->'dias_laborales')), array[1,2,3,4,5]);
  v_fer  := coalesce((select array_agg(value::date) from jsonb_array_elements_text(p->'feriados') where value ~ '^\d{4}-\d{2}-\d{2}$'), '{}');

  -- Colaboradores: nombre, cargo, lugar, líder y estado los manda el marcaje
  for x in select * from jsonb_array_elements(coalesce(p->'empleados', '[]')) loop
    continue when coalesce(trim(x->>'correo'), '') = '' or coalesce(trim(x->>'nombre'), '') = '';
    insert into empleados (correo, nombre, cargo, lugar, lider_correo, activo, origen)
    values (lower(trim(x->>'correo')), trim(x->>'nombre'), nullif(trim(x->>'cargo'), ''), nullif(trim(x->>'lugar'), ''),
            nullif(lower(trim(x->>'lider')), ''), coalesce((x->>'activo')::boolean, true), 'marcaje')
    on conflict (correo) do update set
      nombre = excluded.nombre, cargo = coalesce(excluded.cargo, empleados.cargo), lugar = coalesce(excluded.lugar, empleados.lugar),
      lider_correo = excluded.lider_correo, activo = excluded.activo;
    n_emp := n_emp + 1;
  end loop;

  -- Marcas; una marca en día no laborable es un día extra que espera a Administración
  for x in select * from jsonb_array_elements(coalesce(p->'marcas', '[]')) loop
    continue when coalesce(x->>'id', '') = '' or coalesce(x->>'fecha', '') !~ '^\d{4}-\d{2}-\d{2}$';
    v_fecha := (x->>'fecha')::date;
    insert into marcaje_marcas (id_externo, fecha, correo, nombre, entrada, salida, horas, lugar)
    values (x->>'id', v_fecha, lower(trim(x->>'correo')), x->>'nombre', nullif(x->>'entrada', ''), nullif(x->>'salida', ''),
            case when x->>'horas' ~ '^\d+(\.\d+)?$' then (x->>'horas')::numeric end, nullif(x->>'lugar', ''))
    on conflict (id_externo) do update set entrada = excluded.entrada, salida = excluded.salida, horas = excluded.horas,
      lugar = excluded.lugar, nombre = excluded.nombre, recibido_en = now();
    n_mar := n_mar + 1;
    -- (una reposición de horas acordada con el líder no es día extra)
    if (not (extract(isodow from v_fecha)::int = any(v_dias)) or v_fecha = any(v_fer)) and nullif(x->>'entrada', '') is not null
       and coalesce(x->>'reposicion', 'false') <> 'true' then
      select id into v_emp from empleados where correo = lower(trim(x->>'correo'));
      if v_emp is not null then
        insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen, ref_externa, creado_por)
        values (v_emp, v_fecha, 'dia_extra', 1,
                'Día extra trabajado (' || to_char(v_fecha, 'DD/MM/YYYY') || coalesce(', ' || nullif(x->>'horas', '') || ' h', '') || ')',
                'pendiente', 'marcaje', 'extra:' || (x->>'id'), null)
        on conflict (ref_externa) do nothing;
        if found then n_ext := n_ext + 1; end if;
      end if;
    end if;
  end loop;

  -- Permisos; las vacaciones aprobadas se descuentan del saldo
  for x in select * from jsonb_array_elements(coalesce(p->'permisos', '[]')) loop
    continue when coalesce(x->>'id', '') = '';
    insert into marcaje_permisos (id_externo, correo, tipo, desde, hasta, hora_desde, hora_hasta, estado, motivo)
    values (x->>'id', lower(trim(x->>'correo')), x->>'tipo',
            case when x->>'desde' ~ '^\d{4}-\d{2}-\d{2}$' then (x->>'desde')::date end,
            case when x->>'hasta' ~ '^\d{4}-\d{2}-\d{2}$' then (x->>'hasta')::date end,
            nullif(x->>'horaDesde', ''), nullif(x->>'horaHasta', ''), x->>'estado', x->>'motivo')
    on conflict (id_externo) do update set tipo = excluded.tipo, desde = excluded.desde, hasta = excluded.hasta,
      hora_desde = excluded.hora_desde, hora_hasta = excluded.hora_hasta, estado = excluded.estado, motivo = excluded.motivo, recibido_en = now();
    n_per := n_per + 1;

    select id into v_emp from empleados where correo = lower(trim(x->>'correo'));
    continue when v_emp is null or x->>'tipo' <> 'Vacaciones' or x->>'desde' !~ '^\d{4}-\d{2}-\d{2}$';
    if x->>'estado' = 'Aprobado' then
      if nullif(x->>'horaDesde', '') is not null and nullif(x->>'horaHasta', '') is not null and coalesce(x->>'hasta', x->>'desde') = x->>'desde' then
        v_d := round(extract(epoch from ((x->>'horaHasta')::time - (x->>'horaDesde')::time)) / 3600 / v_horas_dia, 2);
      else
        v_d := _dias_laborables((x->>'desde')::date, coalesce(nullif(x->>'hasta', '')::date, (x->>'desde')::date), v_dias, v_fer);
      end if;
      if v_d > 0 then
        insert into vacaciones_movimientos (empleado_id, fecha, tipo, dias, descripcion, estado, origen, ref_externa, creado_por)
        values (v_emp, (x->>'desde')::date, 'tomadas', -v_d, 'Vacaciones aprobadas en la app de marcaje', 'aprobado', 'marcaje', 'perm:' || (x->>'id'), null)
        on conflict (ref_externa) do update set dias = excluded.dias, fecha = excluded.fecha, estado = 'aprobado';
        n_vac := n_vac + 1;
      end if;
    else
      update vacaciones_movimientos set estado = 'anulado', motivo = 'El permiso cambió a ' || coalesce(x->>'estado', '—') || ' en el marcaje'
       where ref_externa = 'perm:' || (x->>'id') and estado = 'aprobado';
    end if;
  end loop;

  v_res := jsonb_build_object('empleados', n_emp, 'marcas', n_mar, 'permisos', n_per, 'dias_extra_nuevos', n_ext, 'vacaciones', n_vac, 'recibido', now());
  update integracion_claves set ultimo_uso = now(), ultimo_resultado = v_res where id = v_clave.id;
  return v_res;
end $$;

-- ---------------------------------------------------------------------
-- 11. Seguridad
-- ---------------------------------------------------------------------
alter table empleados              enable row level security;
alter table planilla_parametros    enable row level security;
alter table ir_tramos              enable row level security;
alter table conceptos_planilla     enable row level security;
alter table planillas              enable row level security;
alter table planilla_lineas        enable row level security;
alter table planilla_novedades     enable row level security;
alter table vacaciones_movimientos enable row level security;
alter table marcaje_marcas         enable row level security;
alter table marcaje_permisos       enable row level security;
alter table integracion_claves     enable row level security;

create policy leer   on empleados for select to authenticated using (tiene_permiso('planilla.ver') or tiene_permiso('vacaciones.aprobar'));
create policy editar on empleados for all    to authenticated using (tiene_permiso('planilla.editar')) with check (tiene_permiso('planilla.editar'));
create policy leer   on planilla_parametros for select to authenticated using (tiene_permiso('planilla.ver'));
create policy editar on planilla_parametros for all    to authenticated using (tiene_permiso('planilla.config')) with check (tiene_permiso('planilla.config'));
create policy leer   on ir_tramos for select to authenticated using (tiene_permiso('planilla.ver'));
create policy editar on ir_tramos for all    to authenticated using (tiene_permiso('planilla.config')) with check (tiene_permiso('planilla.config'));
create policy leer   on conceptos_planilla for select to authenticated using (tiene_permiso('planilla.ver'));
create policy editar on conceptos_planilla for all    to authenticated using (tiene_permiso('planilla.config')) with check (tiene_permiso('planilla.config'));
create policy leer   on planillas          for select to authenticated using (tiene_permiso('planilla.ver'));
create policy leer   on planilla_lineas    for select to authenticated using (tiene_permiso('planilla.ver'));
create policy leer   on planilla_novedades for select to authenticated using (tiene_permiso('planilla.ver'));
create policy leer   on vacaciones_movimientos for select to authenticated using (tiene_permiso('planilla.ver') or tiene_permiso('vacaciones.aprobar'));
create policy leer   on marcaje_marcas     for select to authenticated using (tiene_permiso('planilla.ver') or tiene_permiso('vacaciones.aprobar'));
create policy leer   on marcaje_permisos   for select to authenticated using (tiene_permiso('planilla.ver') or tiene_permiso('vacaciones.aprobar'));
create policy leer   on integracion_claves for select to authenticated using (tiene_permiso('planilla.config'));

-- Planilla y vacaciones necesitan ver el catálogo de cuentas y los centros de costo
drop policy leer on cuentas;
drop policy leer on centros_costo;
create policy leer on cuentas       for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver') or tiene_permiso('bancos.ver') or tiene_permiso('planilla.ver'));
create policy leer on centros_costo for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver') or tiene_permiso('bancos.ver') or tiene_permiso('planilla.ver') or tiene_permiso('vacaciones.aprobar'));

grant select on all tables in schema public to authenticated;
grant usage on all sequences in schema public to authenticated;
grant insert, update, delete on empleados, planilla_parametros, ir_tramos, conceptos_planilla to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function recibir_marcaje(text, jsonb) to anon;

-- ---------------------------------------------------------------------
-- 12. Valores iniciales (confirmar con el contador)
-- ---------------------------------------------------------------------
insert into planilla_parametros (vigente_desde, inss_laboral, inss_patronal, inatec, techo_inss, dias_vacaciones_mes,
  cuenta_salarios_id, cuenta_patronal_id, cuenta_inss_pagar_id, cuenta_ir_pagar_id, cuenta_inatec_pagar_id, cuenta_neto_pagar_id)
values ('2026-01-01', 7, 22.5, 2, null, 2.5,
  _cuenta_planilla('Sueldos y salarios', '6.1', 'gasto', 'deudora', '6.1.01'),
  _cuenta_planilla('Aportes patronales INSS e INATEC', '6.1', 'gasto', 'deudora'),
  _cuenta_planilla('INSS por pagar', '2.1', 'pasivo', 'acreedora', '2.1.04'),
  _cuenta_planilla('IR retenido a colaboradores por pagar', '2.1', 'pasivo', 'acreedora'),
  _cuenta_planilla('INATEC por pagar', '2.1', 'pasivo', 'acreedora'),
  _cuenta_planilla('Salarios por pagar', '2.1', 'pasivo', 'acreedora'));

insert into ir_tramos (vigente_desde, desde, hasta, base, porcentaje) values
  ('2013-01-01',      0, 100000,     0,  0),
  ('2013-01-01', 100000, 200000,     0, 15),
  ('2013-01-01', 200000, 350000, 15000, 20),
  ('2013-01-01', 350000, 500000, 45000, 25),
  ('2013-01-01', 500000,   null, 82500, 30);

insert into conceptos_planilla (codigo, nombre, tipo, afecta_inss, afecta_ir, cuenta_id) values
  ('BONO',  'Bono',                              'ingreso',   true,  true,  null),
  ('VIAT',  'Viáticos (no salariales)',          'ingreso',   false, false, null),
  ('PREST', 'Préstamo a colaborador',            'deduccion', false, false, _cuenta_planilla('Préstamos y adelantos a colaboradores', '1.1', 'activo', 'deudora')),
  ('ADEL',  'Adelanto de salario',               'deduccion', false, false, _cuenta_planilla('Préstamos y adelantos a colaboradores', '1.1', 'activo', 'deudora')),
  ('EMB',   'Embargo judicial',                  'deduccion', false, false, _cuenta_planilla('Embargos judiciales por pagar', '2.1', 'pasivo', 'acreedora')),
  ('OTRA',  'Otra deducción',                    'deduccion', false, false, _cuenta_planilla('Otras deducciones de planilla por pagar', '2.1', 'pasivo', 'acreedora'));

-- Funciones internas que cambian datos sin revisar permisos: solo las usan
-- otras funciones del sistema, nadie debe poder llamarlas directamente
-- (por ejemplo, para contabilizar un asiento sin tener permiso).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('_contabilizar','_revertir_asiento','_inv_mover','_asiento_inventario','_costo_salida',
                                '_recalcular_planilla','_cuenta_planilla','_parametros_planilla') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

commit;
