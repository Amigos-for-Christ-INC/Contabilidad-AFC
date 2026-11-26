-- =====================================================================
-- Contabilidad AFC — núcleo contable para Supabase (PostgreSQL)
-- Pegar completo en Supabase > SQL Editor > New query > Run.
-- Moneda funcional: córdobas (C$). Los asientos en dólares guardan el
-- monto original y su equivalente en C$ al tipo de cambio del día.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------
create type tipo_cuenta    as enum ('activo','pasivo','patrimonio','ingreso','costo','gasto');
create type naturaleza     as enum ('deudora','acreedora');
create type estado_asiento as enum ('borrador','contabilizado','anulado');
create type rol_usuario    as enum ('admin','contador','consulta');

-- ---------------------------------------------------------------------
-- 2. Usuarios y roles
--    admin    : todo, incluye cerrar/abrir períodos y asignar roles
--    contador : catálogo, centros, tipos de cambio y asientos
--    consulta : solo lectura
-- ---------------------------------------------------------------------
create table perfiles (
  id        uuid primary key references auth.users(id) on delete cascade,
  nombre    text,
  correo    text,
  rol       rol_usuario not null default 'consulta',
  creado_en timestamptz not null default now()
);

create or replace function mi_rol() returns rol_usuario
language sql stable security definer set search_path = public as $$
  select rol from perfiles where id = auth.uid()
$$;

create or replace function puede_editar() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(mi_rol() in ('admin','contador'), false)
$$;

create or replace function es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(mi_rol() = 'admin', false)
$$;

-- El primer usuario que se registra queda como admin; los demás, consulta.
create or replace function nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (id, nombre, correo, rol)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name',
             new.raw_user_meta_data->>'name',
             split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from perfiles) then 'consulta'::rol_usuario
         else 'admin'::rol_usuario end
  );
  return new;
end $$;

create trigger al_crear_usuario
  after insert on auth.users
  for each row execute function nuevo_usuario();

-- ---------------------------------------------------------------------
-- 3. Catálogos
-- ---------------------------------------------------------------------
create table cuentas (
  id                 bigint generated always as identity primary key,
  codigo             text not null unique check (codigo ~ '^[0-9]+(\.[0-9]+)*$'),
  nombre             text not null check (length(trim(nombre)) > 0),
  tipo               tipo_cuenta not null,
  naturaleza         naturaleza not null,
  padre_id           bigint references cuentas(id),
  nivel              int generated always as (array_length(string_to_array(codigo, '.'), 1)) stored,
  acepta_movimientos boolean not null default true,
  activa             boolean not null default true,
  creado_en          timestamptz not null default now()
);

create table centros_costo (
  id     bigint generated always as identity primary key,
  codigo text not null unique,
  nombre text not null,
  activo boolean not null default true
);

-- C$ por cada US$ 1
create table tipos_cambio (
  fecha date primary key,
  tasa  numeric(12,4) not null check (tasa > 0)
);

create table periodos (
  anio        int not null,
  mes         int not null check (mes between 1 and 12),
  estado      text not null default 'abierto' check (estado in ('abierto','cerrado')),
  cerrado_por uuid,
  cerrado_en  timestamptz,
  primary key (anio, mes)
);

-- ---------------------------------------------------------------------
-- 4. Asientos (partida doble)
-- ---------------------------------------------------------------------
create table asientos (
  id                bigint generated always as identity primary key,
  numero            int,                               -- se asigna al contabilizar, correlativo por año
  fecha             date not null,
  anio              int not null,
  mes               int not null,
  tipo              text not null default 'diario'
                    check (tipo in ('diario','ingreso','egreso','ajuste','apertura','cierre')),
  concepto          text not null check (length(trim(concepto)) > 0),
  referencia        text,
  moneda            text not null default 'NIO' check (moneda in ('NIO','USD')),
  tipo_cambio       numeric(12,4) check (tipo_cambio > 0),
  estado            estado_asiento not null default 'borrador',
  creado_por        uuid default auth.uid(),
  creado_en         timestamptz not null default now(),
  contabilizado_por uuid,
  contabilizado_en  timestamptz,
  anulado_por       uuid,
  anulado_en        timestamptz,
  motivo_anulacion  text,
  foreign key (anio, mes) references periodos (anio, mes),
  unique (anio, numero)
);

create table asiento_lineas (
  id              bigint generated always as identity primary key,
  asiento_id      bigint not null references asientos(id) on delete cascade,
  orden           int not null default 0,
  cuenta_id       bigint not null references cuentas(id),
  centro_costo_id bigint references centros_costo(id),
  descripcion     text,
  debe            numeric(18,2) not null default 0 check (debe  >= 0),  -- siempre en C$
  haber           numeric(18,2) not null default 0 check (haber >= 0),  -- siempre en C$
  debe_me         numeric(18,2),                                        -- monto original en US$
  haber_me        numeric(18,2),
  check ((debe > 0 and haber = 0) or (haber > 0 and debe = 0))
);

create index on asientos (fecha);
create index on asientos (estado);
create index on asiento_lineas (asiento_id);
create index on asiento_lineas (cuenta_id);
create index on asiento_lineas (centro_costo_id);

-- ---------------------------------------------------------------------
-- 5. Bitácora de auditoría
-- ---------------------------------------------------------------------
create table bitacora (
  id            bigint generated always as identity primary key,
  tabla         text not null,
  operacion     text not null,
  registro      text,
  datos_antes   jsonb,
  datos_despues jsonb,
  usuario       uuid default auth.uid(),
  fecha         timestamptz not null default now()
);

create or replace function registrar_bitacora() returns trigger
language plpgsql security definer set search_path = public as $$
declare j jsonb := to_jsonb(coalesce(new, old));
begin
  insert into bitacora (tabla, operacion, registro, datos_antes, datos_despues)
  values (
    tg_table_name, tg_op,
    coalesce(j->>'id', j->>'fecha', (j->>'anio') || '-' || (j->>'mes')),
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

create trigger bitacora_cuentas  after insert or update or delete on cuentas       for each row execute function registrar_bitacora();
create trigger bitacora_centros  after insert or update or delete on centros_costo for each row execute function registrar_bitacora();
create trigger bitacora_tc       after insert or update or delete on tipos_cambio  for each row execute function registrar_bitacora();
create trigger bitacora_periodos after insert or update or delete on periodos      for each row execute function registrar_bitacora();
create trigger bitacora_asientos after insert or update or delete on asientos      for each row execute function registrar_bitacora();
create trigger bitacora_perfiles after update or delete on perfiles                for each row execute function registrar_bitacora();

-- ---------------------------------------------------------------------
-- 6. Reglas de integridad (triggers)
-- ---------------------------------------------------------------------

-- Cuentas: padre según el código, mismo tipo que el padre, el padre pasa a
-- ser de agrupación, y una cuenta con movimientos no deja de aceptarlos.
create or replace function validar_cuenta() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_padre_cod text;
  p cuentas%rowtype;
begin
  if tg_op = 'UPDATE' and new.codigo <> old.codigo
     and exists (select 1 from asiento_lineas where cuenta_id = old.id) then
    raise exception 'No se puede cambiar el código de la cuenta %: ya tiene movimientos', old.codigo;
  end if;

  if position('.' in new.codigo) > 0 then
    v_padre_cod := regexp_replace(new.codigo, '\.[0-9]+$', '');
    select * into p from cuentas where codigo = v_padre_cod;
    if not found then
      raise exception 'Primero cree la cuenta padre %', v_padre_cod;
    end if;
    if p.tipo <> new.tipo then
      raise exception 'La cuenta % debe ser del mismo tipo que su padre % (%)', new.codigo, p.codigo, p.tipo;
    end if;
    if p.acepta_movimientos then
      if exists (select 1 from asiento_lineas where cuenta_id = p.id) then
        raise exception 'La cuenta padre % ya tiene movimientos y no puede tener subcuentas', p.codigo;
      end if;
      update cuentas set acepta_movimientos = false where id = p.id;
    end if;
    new.padre_id := p.id;
  else
    new.padre_id := null;
  end if;

  if tg_op = 'UPDATE' and old.acepta_movimientos and not new.acepta_movimientos
     and exists (select 1 from asiento_lineas where cuenta_id = new.id) then
    raise exception 'La cuenta % tiene movimientos; no puede pasar a ser de agrupación', new.codigo;
  end if;

  if tg_op = 'UPDATE' and new.acepta_movimientos and not old.acepta_movimientos
     and exists (select 1 from cuentas where padre_id = new.id) then
    raise exception 'La cuenta % tiene subcuentas; no puede recibir movimientos', new.codigo;
  end if;

  return new;
end $$;

create trigger validar_cuenta before insert or update on cuentas
  for each row execute function validar_cuenta();

-- Asientos: año/mes desde la fecha, período abierto (se crea si no existe),
-- y nada contabilizado o anulado se puede modificar.
create or replace function validar_asiento() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_estado text;
begin
  if tg_op = 'DELETE' then
    if old.estado <> 'borrador' then
      raise exception 'Solo se pueden eliminar asientos en borrador';
    end if;
    return old;
  end if;

  new.anio := extract(year from new.fecha)::int;
  new.mes  := extract(month from new.fecha)::int;

  if tg_op = 'UPDATE' then
    if old.estado = 'anulado' then
      raise exception 'El asiento % está anulado y no se puede modificar', old.numero;
    end if;
    if old.estado = 'contabilizado' and (
         new.estado = 'borrador' or
         new.fecha is distinct from old.fecha or new.concepto is distinct from old.concepto or
         new.referencia is distinct from old.referencia or new.moneda is distinct from old.moneda or
         new.tipo_cambio is distinct from old.tipo_cambio or new.tipo is distinct from old.tipo or
         new.numero is distinct from old.numero) then
      raise exception 'El asiento % ya está contabilizado; para corregirlo, anúlelo y registre uno nuevo', old.numero;
    end if;
    if old.anio <> new.anio or old.mes <> new.mes then
      select estado into v_estado from periodos where anio = old.anio and mes = old.mes;
      if v_estado = 'cerrado' then
        raise exception 'El período %/% está cerrado', lpad(old.mes::text, 2, '0'), old.anio;
      end if;
    end if;
  end if;

  insert into periodos (anio, mes) values (new.anio, new.mes) on conflict do nothing;
  select estado into v_estado from periodos where anio = new.anio and mes = new.mes;
  if v_estado = 'cerrado' then
    raise exception 'El período %/% está cerrado', lpad(new.mes::text, 2, '0'), new.anio;
  end if;

  return new;
end $$;

create trigger validar_asiento before insert or update or delete on asientos
  for each row execute function validar_asiento();

-- Líneas: solo se tocan mientras el asiento es borrador.
create or replace function validar_linea() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_estado estado_asiento;
begin
  select estado into v_estado from asientos where id = coalesce(new.asiento_id, old.asiento_id);
  if v_estado is not null and v_estado <> 'borrador' then
    raise exception 'Las líneas de un asiento contabilizado o anulado no se pueden modificar';
  end if;
  return coalesce(new, old);
end $$;

create trigger validar_linea before insert or update or delete on asiento_lineas
  for each row execute function validar_linea();

-- ---------------------------------------------------------------------
-- 7. Operaciones (la app escribe asientos solo por estas funciones)
-- ---------------------------------------------------------------------

-- Contabiliza un borrador: valida cuadre y cuentas, asigna número del año.
create or replace function contabilizar_asiento(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare
  a asientos%rowtype;
  n int; d numeric; h numeric; v_cta text; v_num int;
begin
  if not puede_editar() then raise exception 'No tiene permiso para contabilizar asientos'; end if;

  select * into a from asientos where id = p_id for update;
  if not found then raise exception 'El asiento % no existe', p_id; end if;
  if a.estado <> 'borrador' then raise exception 'Solo se contabilizan asientos en borrador'; end if;

  select count(*), coalesce(sum(debe), 0), coalesce(sum(haber), 0)
    into n, d, h from asiento_lineas where asiento_id = p_id;
  if n < 2 then raise exception 'El asiento necesita al menos dos líneas'; end if;
  if d = 0 then raise exception 'El asiento no tiene montos'; end if;
  if d <> h then
    raise exception 'El asiento no cuadra: Debe C$ % y Haber C$ % (diferencia C$ %)',
      to_char(d, 'FM999,999,999,990.00'), to_char(h, 'FM999,999,999,990.00'),
      to_char(abs(d - h), 'FM999,999,999,990.00');
  end if;

  select c.codigo || ' ' || c.nombre into v_cta
    from asiento_lineas l join cuentas c on c.id = l.cuenta_id
   where l.asiento_id = p_id and (not c.acepta_movimientos or not c.activa)
   limit 1;
  if v_cta is not null then
    raise exception 'La cuenta % es de agrupación o está inactiva; use una subcuenta', v_cta;
  end if;

  perform pg_advisory_xact_lock(hashtext('numero_asiento_' || a.anio));
  select coalesce(max(numero), 0) + 1 into v_num from asientos where anio = a.anio;

  update asientos
     set estado = 'contabilizado', numero = v_num,
         contabilizado_por = auth.uid(), contabilizado_en = now()
   where id = p_id;
  return v_num;
end $$;

-- Crea o reemplaza un borrador en una sola transacción.
-- p = {id?, fecha, tipo, concepto, referencia, moneda, tipo_cambio?,
--      lineas:[{cuenta_id, centro_costo_id?, descripcion?, debe, haber}]}
-- En asientos en US$, debe/haber vienen en dólares y se convierten a C$.
create or replace function guardar_asiento(p jsonb, p_contabilizar boolean default false) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_estado estado_asiento;
  v_fecha date := (p->>'fecha')::date;
  v_moneda text := coalesce(nullif(p->>'moneda', ''), 'NIO');
  v_tc numeric;
  l jsonb; i int := 0;
  v_cta bigint; v_d numeric; v_h numeric;
  v_dif numeric; v_lin bigint;
begin
  if not puede_editar() then raise exception 'No tiene permiso para registrar asientos'; end if;
  if v_fecha is null then raise exception 'Indique la fecha del asiento'; end if;
  if coalesce(trim(p->>'concepto'), '') = '' then raise exception 'Indique el concepto del asiento'; end if;

  if v_moneda = 'USD' then
    v_tc := coalesce(nullif(p->>'tipo_cambio', '')::numeric,
                     (select tasa from tipos_cambio where fecha = v_fecha));
    if v_tc is null then
      raise exception 'No hay tipo de cambio registrado para el %; regístrelo o escríbalo en el asiento',
        to_char(v_fecha, 'DD/MM/YYYY');
    end if;
  end if;

  if v_id is null then
    insert into asientos (fecha, tipo, concepto, referencia, moneda, tipo_cambio)
    values (v_fecha, coalesce(nullif(p->>'tipo', ''), 'diario'), trim(p->>'concepto'),
            nullif(trim(p->>'referencia'), ''), v_moneda, v_tc)
    returning id into v_id;
  else
    select estado into v_estado from asientos where id = v_id for update;
    if not found then raise exception 'El asiento % no existe', v_id; end if;
    if v_estado <> 'borrador' then raise exception 'Solo se pueden modificar asientos en borrador'; end if;
    update asientos
       set fecha = v_fecha, tipo = coalesce(nullif(p->>'tipo', ''), 'diario'),
           concepto = trim(p->>'concepto'), referencia = nullif(trim(p->>'referencia'), ''),
           moneda = v_moneda, tipo_cambio = v_tc
     where id = v_id;
    delete from asiento_lineas where asiento_id = v_id;
  end if;

  for l in select * from jsonb_array_elements(coalesce(p->'lineas', '[]'::jsonb)) loop
    v_cta := nullif(l->>'cuenta_id', '')::bigint;
    v_d := coalesce(nullif(l->>'debe', '')::numeric, 0);
    v_h := coalesce(nullif(l->>'haber', '')::numeric, 0);
    continue when v_cta is null and v_d = 0 and v_h = 0;   -- fila vacía
    i := i + 1;
    if v_cta is null then raise exception 'Línea %: seleccione la cuenta', i; end if;
    if v_d < 0 or v_h < 0 then raise exception 'Línea %: los montos no pueden ser negativos', i; end if;
    if v_d > 0 and v_h > 0 then raise exception 'Línea %: ponga el monto en Debe o en Haber, no en ambos', i; end if;
    if v_d = 0 and v_h = 0 then raise exception 'Línea %: falta el monto', i; end if;

    if v_moneda = 'USD' then
      insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion,
                                  debe, haber, debe_me, haber_me)
      values (v_id, i, v_cta, nullif(l->>'centro_costo_id', '')::bigint, nullif(trim(l->>'descripcion'), ''),
              round(v_d * v_tc, 2), round(v_h * v_tc, 2), round(v_d, 2), round(v_h, 2));
    else
      insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, descripcion, debe, haber)
      values (v_id, i, v_cta, nullif(l->>'centro_costo_id', '')::bigint, nullif(trim(l->>'descripcion'), ''),
              round(v_d, 2), round(v_h, 2));
    end if;
  end loop;

  -- En US$: si el asiento cuadra en dólares pero el redondeo a C$ deja
  -- centavos de diferencia, se ajustan en la línea más grande.
  if v_moneda = 'USD'
     and (select sum(coalesce(debe_me, 0)) = sum(coalesce(haber_me, 0)) from asiento_lineas where asiento_id = v_id) then
    select sum(debe) - sum(haber) into v_dif from asiento_lineas where asiento_id = v_id;
    if v_dif <> 0 and abs(v_dif) <= 0.01 * i then
      if v_dif > 0 then
        select id into v_lin from asiento_lineas where asiento_id = v_id and haber > 0 order by haber desc limit 1;
        update asiento_lineas set haber = haber + v_dif where id = v_lin;
      else
        select id into v_lin from asiento_lineas where asiento_id = v_id and debe > 0 order by debe desc limit 1;
        update asiento_lineas set debe = debe - v_dif where id = v_lin;
      end if;
    end if;
  end if;

  if p_contabilizar then perform contabilizar_asiento(v_id); end if;
  return v_id;
end $$;

create or replace function eliminar_borrador(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not puede_editar() then raise exception 'No tiene permiso para eliminar asientos'; end if;
  delete from asientos where id = p_id;   -- el trigger impide borrar si no es borrador
  if not found then raise exception 'El asiento % no existe', p_id; end if;
end $$;

create or replace function anular_asiento(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare v_estado estado_asiento;
begin
  if not puede_editar() then raise exception 'No tiene permiso para anular asientos'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo de la anulación'; end if;
  select estado into v_estado from asientos where id = p_id for update;
  if not found then raise exception 'El asiento % no existe', p_id; end if;
  if v_estado <> 'contabilizado' then raise exception 'Solo se anulan asientos contabilizados'; end if;
  update asientos
     set estado = 'anulado', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo)
   where id = p_id;
end $$;

create or replace function cerrar_periodo(p_anio int, p_mes int) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not es_admin() then raise exception 'Solo un administrador puede cerrar períodos'; end if;
  insert into periodos (anio, mes) values (p_anio, p_mes) on conflict do nothing;
  select count(*) into n from asientos where anio = p_anio and mes = p_mes and estado = 'borrador';
  if n > 0 then
    raise exception 'Hay % asiento(s) en borrador en %/%; contabilícelos o elimínelos antes de cerrar',
      n, lpad(p_mes::text, 2, '0'), p_anio;
  end if;
  update periodos set estado = 'cerrado', cerrado_por = auth.uid(), cerrado_en = now()
   where anio = p_anio and mes = p_mes;
end $$;

create or replace function abrir_periodo(p_anio int, p_mes int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'Solo un administrador puede reabrir períodos'; end if;
  update periodos set estado = 'abierto', cerrado_por = null, cerrado_en = null
   where anio = p_anio and mes = p_mes;
  if not found then raise exception 'El período %/% no existe', lpad(p_mes::text, 2, '0'), p_anio; end if;
end $$;

-- Genera (en borrador) el asiento que lleva a cero las cuentas de
-- ingresos, costos y gastos del año contra una cuenta de patrimonio.
create or replace function generar_asiento_cierre(p_anio int, p_cuenta_destino bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  dest cuentas%rowtype;
  v_id bigint; r record; v_total numeric := 0; i int := 0;
begin
  if not puede_editar() then raise exception 'No tiene permiso para generar el cierre'; end if;
  select * into dest from cuentas where id = p_cuenta_destino;
  if not found or dest.tipo <> 'patrimonio' or not dest.acepta_movimientos then
    raise exception 'La cuenta destino debe ser de patrimonio y aceptar movimientos';
  end if;
  if exists (select 1 from asientos where anio = p_anio and tipo = 'cierre' and estado <> 'anulado') then
    raise exception 'Ya existe un asiento de cierre para %; anúlelo o elimínelo primero', p_anio;
  end if;

  insert into asientos (fecha, tipo, concepto)
  values (make_date(p_anio, 12, 31), 'cierre', 'Cierre del ejercicio ' || p_anio)
  returning id into v_id;

  for r in
    select l.cuenta_id, sum(l.debe - l.haber) as neto
      from asiento_lineas l
      join asientos a on a.id = l.asiento_id
      join cuentas c on c.id = l.cuenta_id
     where a.estado = 'contabilizado' and a.anio = p_anio
       and c.tipo in ('ingreso','costo','gasto')
     group by l.cuenta_id
    having sum(l.debe - l.haber) <> 0
     order by min(c.codigo)
  loop
    i := i + 1;
    insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber)
    values (v_id, i, r.cuenta_id, 'Cierre ' || p_anio,
            case when r.neto < 0 then -r.neto else 0 end,
            case when r.neto > 0 then  r.neto else 0 end);
    v_total := v_total + r.neto;
  end loop;

  if i = 0 then raise exception 'No hay saldos de resultados para cerrar en %', p_anio; end if;

  if v_total <> 0 then
    insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber)
    values (v_id, i + 1, dest.id,
            case when v_total < 0 then 'Utilidad del ejercicio ' else 'Pérdida del ejercicio ' end || p_anio,
            case when v_total > 0 then  v_total else 0 end,
            case when v_total < 0 then -v_total else 0 end);
  end if;
  return v_id;
end $$;

create or replace function cambiar_rol(p_usuario uuid, p_rol rol_usuario) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'Solo un administrador puede cambiar roles'; end if;
  if p_rol <> 'admin'
     and (select rol from perfiles where id = p_usuario) = 'admin'
     and (select count(*) from perfiles where rol = 'admin') = 1 then
    raise exception 'Debe quedar al menos un administrador';
  end if;
  update perfiles set rol = p_rol where id = p_usuario;
end $$;

-- ---------------------------------------------------------------------
-- 8. Reportes (respetan los permisos de lectura del usuario)
-- ---------------------------------------------------------------------

-- Balanza de comprobación. Las cuentas de agrupación suman a sus subcuentas.
-- Saldos con el signo de la naturaleza de cada cuenta.
create or replace function balanza(p_desde date, p_hasta date, p_centro bigint default null)
returns table (
  cuenta_id bigint, codigo text, nombre text, tipo tipo_cuenta, naturaleza naturaleza,
  nivel int, acepta_movimientos boolean,
  saldo_inicial numeric, debe numeric, haber numeric, saldo_final numeric
)
language sql stable set search_path = public as $$
  with mov as (
    select l.cuenta_id,
           sum(case when a.fecha <  p_desde then l.debe - l.haber else 0 end) as ini,
           sum(case when a.fecha >= p_desde then l.debe  else 0 end)          as debe,
           sum(case when a.fecha >= p_desde then l.haber else 0 end)          as haber
      from asiento_lineas l
      join asientos a on a.id = l.asiento_id
     where a.estado = 'contabilizado' and a.fecha <= p_hasta
       and (p_centro is null or l.centro_costo_id = p_centro)
     group by l.cuenta_id
  ),
  hoja as (select c.codigo, m.ini, m.debe, m.haber from mov m join cuentas c on c.id = m.cuenta_id)
  select c.id, c.codigo, c.nombre, c.tipo, c.naturaleza, c.nivel, c.acepta_movimientos,
         s.ini * x.sg, s.debe, s.haber, (s.ini + s.debe - s.haber) * x.sg
    from cuentas c
    cross join lateral (select case when c.naturaleza = 'deudora' then 1 else -1 end as sg) x
    cross join lateral (
      select coalesce(sum(h.ini), 0) as ini, coalesce(sum(h.debe), 0) as debe, coalesce(sum(h.haber), 0) as haber
        from hoja h
       where h.codigo = c.codigo or h.codigo like c.codigo || '.%'
    ) s
   order by string_to_array(c.codigo, '.')::int[]
$$;

-- Libro mayor de una cuenta (con sus subcuentas si es de agrupación).
create or replace function libro_mayor(p_cuenta bigint, p_desde date, p_hasta date, p_centro bigint default null)
returns table (
  fecha date, asiento_id bigint, numero int, concepto text, cuenta text,
  descripcion text, debe numeric, haber numeric, saldo numeric
)
language sql stable set search_path = public as $$
  with c as (
    select codigo, case when naturaleza = 'deudora' then 1 else -1 end as sg from cuentas where id = p_cuenta
  ),
  lin as (
    select a.fecha, a.id as asiento_id, a.numero, a.concepto,
           cu.codigo || ' ' || cu.nombre as cuenta, l.descripcion, l.debe, l.haber, l.id as lid
      from asiento_lineas l
      join asientos a on a.id = l.asiento_id
      join cuentas cu on cu.id = l.cuenta_id
      cross join c
     where a.estado = 'contabilizado' and a.fecha <= p_hasta
       and (cu.codigo = c.codigo or cu.codigo like c.codigo || '.%')
       and (p_centro is null or l.centro_costo_id = p_centro)
  ),
  ini as (select coalesce(sum(debe - haber), 0) as v from lin where fecha < p_desde),
  todo as (
    select 0 as k, p_desde as fecha, null::bigint as asiento_id, null::int as numero,
           'Saldo inicial'::text as concepto, null::text as cuenta, null::text as descripcion,
           null::numeric as debe, null::numeric as haber,
           (select v from ini) * (select sg from c) as saldo, 0::bigint as lid
    union all
    select 1, l.fecha, l.asiento_id, l.numero, l.concepto, l.cuenta, l.descripcion, l.debe, l.haber,
           ((select v from ini) + sum(l.debe - l.haber) over (order by l.fecha, l.numero, l.lid)) * (select sg from c),
           l.lid
      from lin l where l.fecha >= p_desde
  )
  select fecha, asiento_id, numero, concepto, cuenta, descripcion, debe, haber, saldo
    from todo order by k, fecha, numero, lid
$$;

-- ---------------------------------------------------------------------
-- 9. Seguridad: RLS. La app lee tablas; los asientos, períodos y roles
--    solo se escriben por las funciones de arriba.
-- ---------------------------------------------------------------------
alter table perfiles       enable row level security;
alter table cuentas        enable row level security;
alter table centros_costo  enable row level security;
alter table tipos_cambio   enable row level security;
alter table periodos       enable row level security;
alter table asientos       enable row level security;
alter table asiento_lineas enable row level security;
alter table bitacora       enable row level security;

create policy leer on perfiles       for select to authenticated using (mi_rol() is not null);
create policy leer on cuentas        for select to authenticated using (mi_rol() is not null);
create policy leer on centros_costo  for select to authenticated using (mi_rol() is not null);
create policy leer on tipos_cambio   for select to authenticated using (mi_rol() is not null);
create policy leer on periodos       for select to authenticated using (mi_rol() is not null);
create policy leer on asientos       for select to authenticated using (mi_rol() is not null);
create policy leer on asiento_lineas for select to authenticated using (mi_rol() is not null);
create policy leer on bitacora       for select to authenticated using (es_admin());

create policy editar on cuentas       for all to authenticated using (puede_editar()) with check (puede_editar());
create policy editar on centros_costo for all to authenticated using (puede_editar()) with check (puede_editar());
create policy editar on tipos_cambio  for all to authenticated using (puede_editar()) with check (puede_editar());

revoke all on all tables in schema public from anon;
grant select on all tables in schema public to authenticated;
grant insert, update, delete on cuentas, centros_costo, tipos_cambio to authenticated;
grant usage on all sequences in schema public to authenticated;

-- Funciones: solo usuarios con sesión las ejecutan (las reglas internas validan el rol)
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant usage on schema public to authenticated;

-- ---------------------------------------------------------------------
-- 10. Catálogo de ejemplo (el contador debe revisarlo y ajustarlo)
-- ---------------------------------------------------------------------
insert into cuentas (codigo, nombre, tipo, naturaleza, acepta_movimientos) values
  ('1',        'Activo',                                  'activo',     'deudora',   false),
  ('1.1',      'Activo corriente',                        'activo',     'deudora',   false),
  ('1.1.01',   'Efectivo en caja',                        'activo',     'deudora',   true),
  ('1.1.02',   'Bancos córdobas',                         'activo',     'deudora',   true),
  ('1.1.03',   'Bancos dólares',                          'activo',     'deudora',   true),
  ('1.1.04',   'Cuentas por cobrar',                      'activo',     'deudora',   true),
  ('1.1.05',   'Anticipos a proveedores',                 'activo',     'deudora',   true),
  ('1.1.06',   'IVA acreditable (crédito fiscal)',        'activo',     'deudora',   true),
  ('1.1.07',   'Inventario',                              'activo',     'deudora',   true),
  ('1.2',      'Activo no corriente',                     'activo',     'deudora',   false),
  ('1.2.01',   'Propiedad, planta y equipo',              'activo',     'deudora',   true),
  ('1.2.02',   'Depreciación acumulada',                  'activo',     'acreedora', true),
  ('2',        'Pasivo',                                  'pasivo',     'acreedora', false),
  ('2.1',      'Pasivo corriente',                        'pasivo',     'acreedora', false),
  ('2.1.01',   'Proveedores',                             'pasivo',     'acreedora', true),
  ('2.1.02',   'IVA por pagar',                           'pasivo',     'acreedora', true),
  ('2.1.03',   'Retenciones IR por pagar',                'pasivo',     'acreedora', true),
  ('2.1.04',   'INSS por pagar',                          'pasivo',     'acreedora', true),
  ('2.1.05',   'Gastos acumulados por pagar',             'pasivo',     'acreedora', true),
  ('3',        'Patrimonio',                              'patrimonio', 'acreedora', false),
  ('3.1',      'Patrimonio institucional',                'patrimonio', 'acreedora', true),
  ('3.2',      'Resultados acumulados',                   'patrimonio', 'acreedora', true),
  ('4',        'Ingresos',                                'ingreso',    'acreedora', false),
  ('4.1',      'Donaciones recibidas',                    'ingreso',    'acreedora', true),
  ('4.2',      'Ingresos por servicios',                  'ingreso',    'acreedora', true),
  ('4.3',      'Ganancia cambiaria',                      'ingreso',    'acreedora', true),
  ('4.4',      'Otros ingresos',                          'ingreso',    'acreedora', true),
  ('5',        'Costos',                                  'costo',      'deudora',   false),
  ('5.1',      'Costo de programas',                      'costo',      'deudora',   true),
  ('6',        'Gastos',                                  'gasto',      'deudora',   false),
  ('6.1',      'Gastos administrativos',                  'gasto',      'deudora',   false),
  ('6.1.01',   'Sueldos y salarios',                      'gasto',      'deudora',   true),
  ('6.1.02',   'Prestaciones sociales',                   'gasto',      'deudora',   true),
  ('6.1.03',   'Servicios básicos',                       'gasto',      'deudora',   true),
  ('6.1.04',   'Depreciación',                            'gasto',      'deudora',   true),
  ('6.1.05',   'Papelería y útiles',                      'gasto',      'deudora',   true),
  ('6.2',      'Gastos financieros',                      'gasto',      'deudora',   false),
  ('6.2.01',   'Comisiones bancarias',                    'gasto',      'deudora',   true),
  ('6.2.02',   'Pérdida cambiaria',                       'gasto',      'deudora',   true);

insert into centros_costo (codigo, nombre) values ('ADM', 'Administración');
