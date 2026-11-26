-- =====================================================================
-- Contabilidad AFC — Migración 003: bancos y cheques
-- Ejecutar UNA vez, después de 002-roles-inventario.sql.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Permisos nuevos
--   bancos.ver       ver cuentas bancarias, saldos y cheques
--   bancos.emitir    elaborar cheques, enviarlos a aprobación, imprimir y marcar cobrados
--   bancos.aprobar   aprobar o rechazar cheques (nunca los que uno mismo elaboró)
--   bancos.anular    anular cheques aprobados
--   bancos.cuentas   cuentas bancarias, chequeras y formato de impresión
-- ---------------------------------------------------------------------
create or replace function permisos_validos() returns text[]
language sql immutable as $$
  select array['contabilidad.ver','contabilidad.editar','contabilidad.periodos',
               'inventario.ver','inventario.editar','inventario.anular','inventario.catalogo','inventario.todas_bodegas',
               'bancos.ver','bancos.emitir','bancos.aprobar','bancos.anular','bancos.cuentas',
               'admin.usuarios']
$$;

update roles set permisos = permisos || array['bancos.ver','bancos.emitir','bancos.anular','bancos.cuentas']
 where nombre = 'Contador' and not ('bancos.ver' = any(permisos));
update roles set permisos = permisos || array['bancos.ver']
 where nombre = 'Consulta' and not ('bancos.ver' = any(permisos));
insert into roles (nombre, descripcion, permisos)
values ('Aprobador de cheques', 'Revisa y aprueba los cheques que elabora contabilidad',
        array['contabilidad.ver','bancos.ver','bancos.aprobar'])
on conflict (nombre) do nothing;

-- Asientos generados por cheques
alter table asientos drop constraint asientos_origen_check;
alter table asientos add constraint asientos_origen_check check (origen in ('manual','inventario','cheque'));

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
  if v_estado <> 'contabilizado' then raise exception 'Solo se anulan asientos contabilizados'; end if;
  update asientos
     set estado = 'anulado', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo)
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 2. Tablas
-- ---------------------------------------------------------------------
-- Formato de impresión del cheque, en milímetros desde la esquina superior
-- izquierda del cheque. Son valores iniciales: se calibran con "Imprimir prueba".
create or replace function formato_cheque_inicial() returns jsonb
language sql immutable as $$
  select '{"ancho":175,"alto":76,"fuente":11,
           "fecha":{"x":118,"y":13},
           "beneficiario":{"x":30,"y":26},
           "monto":{"x":140,"y":26},
           "letras":{"x":20,"y":35,"ancho":150}}'::jsonb
$$;

create table cuentas_bancarias (
  id                 bigint generated always as identity primary key,
  banco              text not null default 'BANPRO' check (length(trim(banco)) > 0),
  nombre             text not null check (length(trim(nombre)) > 0),
  numero_cuenta      text,
  moneda             text not null default 'NIO' check (moneda in ('NIO','USD')),
  cuenta_contable_id bigint not null references cuentas(id),
  proximo_cheque     int not null default 1 check (proximo_cheque > 0),
  formato            jsonb not null default formato_cheque_inicial(),
  activa             boolean not null default true,
  creado_en          timestamptz not null default now()
);

create table cheques (
  id                   bigint generated always as identity primary key,
  cuenta_bancaria_id   bigint not null references cuentas_bancarias(id),
  numero               int,
  fecha                date not null,
  beneficiario         text not null check (length(trim(beneficiario)) > 0),
  monto                numeric(18,2) not null check (monto > 0),
  moneda               text not null check (moneda in ('NIO','USD')),
  tipo_cambio          numeric(12,4) check (tipo_cambio > 0),
  concepto             text not null check (length(trim(concepto)) > 0),
  estado               text not null default 'borrador' check (estado in ('borrador','por_aprobar','aprobado','anulado')),
  cobrado              boolean not null default false,
  fecha_cobro          date,
  asiento_id           bigint references asientos(id),
  asiento_anulacion_id bigint references asientos(id),
  impresiones          int not null default 0,
  impreso_en           timestamptz,
  creado_por           uuid default auth.uid(),
  creado_en            timestamptz not null default now(),
  enviado_en           timestamptz,
  aprobado_por         uuid,
  aprobado_en          timestamptz,
  rechazado_por        uuid,
  rechazado_en         timestamptz,
  motivo_rechazo       text,
  anulado_por          uuid,
  anulado_en           timestamptz,
  fecha_anulacion      date,
  motivo_anulacion     text,
  unique (cuenta_bancaria_id, numero)
);

-- Distribución contable: Debe = a qué se carga; Haber = retenciones u otros
-- créditos que se descuentan. Debe − Haber = monto del cheque.
create table cheque_lineas (
  id              bigint generated always as identity primary key,
  cheque_id       bigint not null references cheques(id) on delete cascade,
  orden           int not null default 0,
  cuenta_id       bigint not null references cuentas(id),
  centro_costo_id bigint references centros_costo(id),
  descripcion     text,
  debe            numeric(18,2) not null default 0 check (debe >= 0),
  haber           numeric(18,2) not null default 0 check (haber >= 0),
  check ((debe > 0 and haber = 0) or (haber > 0 and debe = 0))
);

create index on cheques (fecha);
create index on cheques (estado);
create index on cheque_lineas (cheque_id);

create or replace function validar_cuenta_bancaria() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from cuentas where id = new.cuenta_contable_id and tipo = 'activo' and acepta_movimientos) then
    raise exception 'La cuenta contable del banco debe ser de activo y aceptar movimientos';
  end if;
  if tg_op = 'UPDATE' and new.moneda <> old.moneda and exists (select 1 from cheques where cuenta_bancaria_id = old.id) then
    raise exception 'La cuenta bancaria ya tiene cheques; no se puede cambiar su moneda';
  end if;
  return new;
end $$;
create trigger validar_cuenta_bancaria before insert or update on cuentas_bancarias
  for each row execute function validar_cuenta_bancaria();

create or replace function validar_cheque_borrado() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.estado not in ('borrador','por_aprobar') then raise exception 'Solo se eliminan cheques que no han sido aprobados'; end if;
  return old;
end $$;
create trigger validar_cheque_borrado before delete on cheques for each row execute function validar_cheque_borrado();

create trigger bitacora_cuentas_bancarias after insert or update or delete on cuentas_bancarias for each row execute function registrar_bitacora();
create trigger bitacora_cheques           after insert or update or delete on cheques           for each row execute function registrar_bitacora();

-- ---------------------------------------------------------------------
-- 3. Operaciones
-- ---------------------------------------------------------------------
-- p = {id?, cuenta_bancaria_id, fecha, beneficiario, monto, concepto, tipo_cambio?,
--      lineas:[{cuenta_id, centro_costo_id?, descripcion?, debe, haber}]}
-- En cuentas en US$, monto y líneas van en dólares.
create or replace function guardar_cheque(p jsonb, p_enviar boolean default false) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id    bigint := nullif(p->>'id', '')::bigint;
  v_cb    cuentas_bancarias%rowtype;
  v_fecha date := nullif(p->>'fecha', '')::date;
  v_monto numeric := round(coalesce(nullif(p->>'monto', '')::numeric, 0), 2);
  v_tc    numeric;
  v_old   cheques%rowtype;
  l jsonb; i int := 0; v_cta bigint; v_d numeric; v_h numeric; v_neto numeric := 0;
begin
  if not tiene_permiso('bancos.emitir') then raise exception 'No tiene permiso para elaborar cheques'; end if;
  select * into v_cb from cuentas_bancarias where id = nullif(p->>'cuenta_bancaria_id', '')::bigint;
  if not found or not v_cb.activa then raise exception 'Seleccione una cuenta bancaria activa'; end if;
  if v_fecha is null then raise exception 'Indique la fecha del cheque'; end if;
  if coalesce(trim(p->>'beneficiario'), '') = '' then raise exception 'Indique el beneficiario'; end if;
  if coalesce(trim(p->>'concepto'), '') = '' then raise exception 'Indique el concepto del pago'; end if;
  if v_monto <= 0 then raise exception 'El monto del cheque debe ser mayor que cero'; end if;

  if v_cb.moneda = 'USD' then
    v_tc := coalesce(nullif(p->>'tipo_cambio', '')::numeric, (select tasa from tipos_cambio where fecha = v_fecha));
    if v_tc is null then
      raise exception 'No hay tipo de cambio registrado para el %; regístrelo o escríbalo en el cheque', to_char(v_fecha, 'DD/MM/YYYY');
    end if;
  end if;

  if v_id is null then
    insert into cheques (cuenta_bancaria_id, fecha, beneficiario, monto, moneda, tipo_cambio, concepto)
    values (v_cb.id, v_fecha, trim(p->>'beneficiario'), v_monto, v_cb.moneda, v_tc, trim(p->>'concepto'))
    returning id into v_id;
  else
    select * into v_old from cheques where id = v_id for update;
    if not found then raise exception 'El cheque no existe'; end if;
    if v_old.estado <> 'borrador' then raise exception 'Solo se modifican cheques en borrador'; end if;
    update cheques
       set cuenta_bancaria_id = v_cb.id, fecha = v_fecha, beneficiario = trim(p->>'beneficiario'), monto = v_monto,
           moneda = v_cb.moneda, tipo_cambio = v_tc, concepto = trim(p->>'concepto')
     where id = v_id;
    delete from cheque_lineas where cheque_id = v_id;
  end if;

  for l in select * from jsonb_array_elements(coalesce(p->'lineas', '[]'::jsonb)) loop
    v_cta := nullif(l->>'cuenta_id', '')::bigint;
    v_d := round(coalesce(nullif(l->>'debe', '')::numeric, 0), 2);
    v_h := round(coalesce(nullif(l->>'haber', '')::numeric, 0), 2);
    continue when v_cta is null and v_d = 0 and v_h = 0;
    i := i + 1;
    if v_cta is null then raise exception 'Línea %: seleccione la cuenta contable', i; end if;
    if v_cta = v_cb.cuenta_contable_id then raise exception 'Línea %: no use la cuenta del banco; el sistema la acredita sola', i; end if;
    if not exists (select 1 from cuentas where id = v_cta and acepta_movimientos and activa) then
      raise exception 'Línea %: la cuenta es de agrupación o está inactiva', i;
    end if;
    if v_d < 0 or v_h < 0 or (v_d > 0 and v_h > 0) or (v_d = 0 and v_h = 0) then
      raise exception 'Línea %: ponga el monto en Debe o en Haber', i;
    end if;
    insert into cheque_lineas (cheque_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
    values (v_id, i, v_cta, nullif(l->>'centro_costo_id', '')::bigint, nullif(trim(l->>'descripcion'), ''), v_d, v_h);
    v_neto := v_neto + v_d - v_h;
  end loop;

  if p_enviar then
    if i = 0 then raise exception 'Agregue la distribución contable del cheque'; end if;
    if v_neto <> v_monto then
      raise exception 'La distribución contable (Debe − Haber = %) no coincide con el monto del cheque (%)',
        to_char(v_neto, 'FM999,999,990.00'), to_char(v_monto, 'FM999,999,990.00');
    end if;
    update cheques set estado = 'por_aprobar', enviado_en = now(), motivo_rechazo = null where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function aprobar_cheque(p_id bigint, p_numero int default null) returns int
language plpgsql security definer set search_path = public as $$
declare
  c cheques%rowtype; cb cuentas_bancarias%rowtype; l record;
  v_num int; v_as bigint; i int := 0; v_d numeric; v_h numeric; v_neto numeric := 0;
begin
  if not tiene_permiso('bancos.aprobar') then raise exception 'No tiene permiso para aprobar cheques'; end if;
  select * into c from cheques where id = p_id for update;
  if not found then raise exception 'El cheque no existe'; end if;
  if c.estado <> 'por_aprobar' then raise exception 'Solo se aprueban cheques enviados a aprobación'; end if;
  if c.creado_por = auth.uid() then raise exception 'Quien elaboró el cheque no puede aprobarlo; debe hacerlo otra persona'; end if;

  select * into cb from cuentas_bancarias where id = c.cuenta_bancaria_id for update;
  v_num := coalesce(p_numero, cb.proximo_cheque);
  if v_num <= 0 then raise exception 'Número de cheque no válido'; end if;
  if exists (select 1 from cheques where cuenta_bancaria_id = cb.id and numero = v_num) then
    raise exception 'El cheque Nº % ya fue usado en esta cuenta', v_num;
  end if;

  insert into asientos (fecha, tipo, concepto, referencia, moneda, tipo_cambio, origen)
  values (c.fecha, 'egreso', left('Cheque ' || cb.banco || ' Nº ' || v_num || ' a ' || c.beneficiario || ': ' || c.concepto, 500),
          'CK-' || v_num, c.moneda, c.tipo_cambio, 'cheque')
  returning id into v_as;

  for l in select * from cheque_lineas where cheque_id = c.id order by orden, id loop
    i := i + 1;
    if c.moneda = 'USD' then
      v_d := round(l.debe * c.tipo_cambio, 2); v_h := round(l.haber * c.tipo_cambio, 2);
      insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber, debe_me, haber_me)
      values (v_as, i, l.cuenta_id, l.centro_costo_id, l.descripcion, v_d, v_h, l.debe, l.haber);
    else
      v_d := l.debe; v_h := l.haber;
      insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
      values (v_as, i, l.cuenta_id, l.centro_costo_id, l.descripcion, v_d, v_h);
    end if;
    v_neto := v_neto + v_d - v_h;
  end loop;
  if i = 0 then raise exception 'El cheque no tiene distribución contable'; end if;
  if v_neto <= 0 then raise exception 'La distribución contable debe dar un monto positivo'; end if;

  -- El banco se acredita por el neto en C$ (en US$ absorbe los centavos del redondeo)
  insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber, debe_me, haber_me)
  values (v_as, i + 1, cb.cuenta_contable_id, 'Cheque Nº ' || v_num, 0, v_neto,
          case when c.moneda = 'USD' then 0 end, case when c.moneda = 'USD' then c.monto end);
  perform _contabilizar(v_as);

  update cuentas_bancarias set proximo_cheque = greatest(proximo_cheque, v_num + 1) where id = cb.id;
  update cheques set estado = 'aprobado', numero = v_num, asiento_id = v_as, aprobado_por = auth.uid(), aprobado_en = now()
   where id = c.id;
  return v_num;
end $$;

create or replace function rechazar_cheque(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('bancos.aprobar') then raise exception 'No tiene permiso para rechazar cheques'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo del rechazo'; end if;
  update cheques set estado = 'borrador', rechazado_por = auth.uid(), rechazado_en = now(), motivo_rechazo = trim(p_motivo)
   where id = p_id and estado = 'por_aprobar';
  if not found then raise exception 'Solo se rechazan cheques enviados a aprobación'; end if;
end $$;

create or replace function retirar_cheque(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('bancos.emitir') then raise exception 'No tiene permiso'; end if;
  update cheques set estado = 'borrador', enviado_en = null where id = p_id and estado = 'por_aprobar';
  if not found then raise exception 'Solo se retiran cheques que están esperando aprobación'; end if;
end $$;

create or replace function registrar_impresion(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not (tiene_permiso('bancos.emitir') or tiene_permiso('bancos.aprobar')) then raise exception 'No tiene permiso para imprimir cheques'; end if;
  update cheques set impresiones = impresiones + 1, impreso_en = now()
   where id = p_id and estado = 'aprobado' returning impresiones into n;
  if n is null then raise exception 'Solo se imprimen cheques aprobados'; end if;
  return n;
end $$;

create or replace function marcar_cobrado(p_id bigint, p_cobrado boolean, p_fecha date default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('bancos.emitir') then raise exception 'No tiene permiso'; end if;
  update cheques set cobrado = p_cobrado,
         fecha_cobro = case when p_cobrado then coalesce(p_fecha, (now() at time zone 'America/Managua')::date) end
   where id = p_id and estado = 'aprobado';
  if not found then raise exception 'Solo se marcan como cobrados cheques aprobados'; end if;
end $$;

-- Asiento de reversión: copia el asiento con Debe y Haber invertidos
create or replace function _revertir_asiento(p_asiento bigint, p_fecha date, p_concepto text, p_origen text) returns bigint
language plpgsql security definer set search_path = public as $$
declare a asientos%rowtype; v_id bigint;
begin
  select * into a from asientos where id = p_asiento;
  insert into asientos (fecha, tipo, concepto, referencia, moneda, tipo_cambio, origen)
  values (p_fecha, a.tipo, left(p_concepto, 500), a.referencia, a.moneda, a.tipo_cambio, p_origen)
  returning id into v_id;
  insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber, debe_me, haber_me)
  select v_id, orden, cuenta_id, centro_costo_id, descripcion, haber, debe, haber_me, debe_me
    from asiento_lineas where asiento_id = p_asiento order by orden, id;
  perform _contabilizar(v_id);
  return v_id;
end $$;

create or replace function anular_cheque(p_id bigint, p_motivo text, p_fecha date default null) returns void
language plpgsql security definer set search_path = public as $$
declare c cheques%rowtype; v_f date := coalesce(p_fecha, (now() at time zone 'America/Managua')::date); v_as bigint;
begin
  if not tiene_permiso('bancos.anular') then raise exception 'No tiene permiso para anular cheques'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo de la anulación'; end if;
  select * into c from cheques where id = p_id for update;
  if not found then raise exception 'El cheque no existe'; end if;
  if c.estado <> 'aprobado' then raise exception 'Solo se anulan cheques aprobados; los borradores se eliminan'; end if;
  if c.cobrado then raise exception 'El cheque ya fue cobrado; desmárquelo como cobrado antes de anularlo'; end if;
  if v_f < c.fecha then raise exception 'La fecha de anulación no puede ser anterior a la del cheque'; end if;
  v_as := _revertir_asiento(c.asiento_id, v_f, 'Anulación del cheque Nº ' || c.numero || ' a ' || c.beneficiario || ': ' || trim(p_motivo), 'cheque');
  update cheques set estado = 'anulado', anulado_por = auth.uid(), anulado_en = now(), fecha_anulacion = v_f,
         motivo_anulacion = trim(p_motivo), asiento_anulacion_id = v_as
   where id = p_id;
end $$;

create or replace function eliminar_cheque(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('bancos.emitir') then raise exception 'No tiene permiso para eliminar cheques'; end if;
  delete from cheques where id = p_id;   -- el trigger impide borrar aprobados o anulados
  if not found then raise exception 'El cheque no existe'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Reportes para el panel
-- ---------------------------------------------------------------------
-- Saldo en libros de cada cuenta bancaria y cheques en circulación
create or replace function saldos_bancos()
returns table (cuenta_bancaria_id bigint, saldo_libros numeric, en_circulacion numeric, cheques_circulacion int, por_aprobar int)
language sql stable set search_path = public as $$
  select cb.id,
         coalesce((select sum(l.debe - l.haber) from asiento_lineas l join asientos a on a.id = l.asiento_id
                    where a.estado = 'contabilizado' and l.cuenta_id = cb.cuenta_contable_id), 0),
         coalesce((select sum(monto) from cheques where cuenta_bancaria_id = cb.id and estado = 'aprobado' and not cobrado), 0),
         (select count(*)::int from cheques where cuenta_bancaria_id = cb.id and estado = 'aprobado' and not cobrado),
         (select count(*)::int from cheques where cuenta_bancaria_id = cb.id and estado = 'por_aprobar')
    from cuentas_bancarias cb
   order by cb.id
$$;

-- Ingresos y gastos por mes (sin el asiento de cierre anual)
create or replace function resumen_mensual(p_hasta date, p_meses int default 6)
returns table (anio int, mes int, ingresos numeric, gastos numeric)
language sql stable set search_path = public as $$
  with m as (
    select g::date as ini
      from generate_series(date_trunc('month', p_hasta) - make_interval(months => greatest(p_meses, 1) - 1),
                           date_trunc('month', p_hasta), interval '1 month') g
  )
  select extract(year from m.ini)::int, extract(month from m.ini)::int,
         coalesce(sum(case when c.tipo = 'ingreso' then l.haber - l.debe end), 0),
         coalesce(sum(case when c.tipo in ('costo','gasto') then l.debe - l.haber end), 0)
    from m
    left join asientos a on a.estado = 'contabilizado' and a.tipo <> 'cierre'
                        and a.fecha >= m.ini and a.fecha < (m.ini + interval '1 month')
    left join asiento_lineas l on l.asiento_id = a.id
    left join cuentas c on c.id = l.cuenta_id
   group by m.ini
   order by m.ini
$$;

-- ---------------------------------------------------------------------
-- 5. Seguridad
-- ---------------------------------------------------------------------
alter table cuentas_bancarias enable row level security;
alter table cheques           enable row level security;
alter table cheque_lineas     enable row level security;

create policy leer   on cuentas_bancarias for select to authenticated using (tiene_permiso('bancos.ver'));
create policy editar on cuentas_bancarias for all    to authenticated using (tiene_permiso('bancos.cuentas')) with check (tiene_permiso('bancos.cuentas'));
create policy leer   on cheques           for select to authenticated using (tiene_permiso('bancos.ver'));
create policy leer   on cheque_lineas     for select to authenticated using (exists (select 1 from cheques c where c.id = cheque_id));

-- Para elaborar cheques se necesita ver el catálogo de cuentas y los centros
drop policy leer on cuentas;
drop policy leer on centros_costo;
drop policy leer on tipos_cambio;
create policy leer on cuentas       for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver') or tiene_permiso('bancos.ver'));
create policy leer on centros_costo for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver') or tiene_permiso('bancos.ver'));
create policy leer on tipos_cambio  for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver') or tiene_permiso('bancos.ver'));

grant select on all tables in schema public to authenticated;
grant usage on all sequences in schema public to authenticated;
grant insert, update, delete on cuentas_bancarias to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

-- ---------------------------------------------------------------------
-- 6. Cuentas bancarias iniciales (complete el número de cuenta y el próximo cheque)
-- ---------------------------------------------------------------------
insert into cuentas_bancarias (banco, nombre, moneda, cuenta_contable_id)
select 'BANPRO', 'BANPRO córdobas', 'NIO', id from cuentas where codigo = '1.1.02' and acepta_movimientos and tipo = 'activo';
insert into cuentas_bancarias (banco, nombre, moneda, cuenta_contable_id)
select 'BANPRO', 'BANPRO dólares', 'USD', id from cuentas where codigo = '1.1.03' and acepta_movimientos and tipo = 'activo';

commit;
