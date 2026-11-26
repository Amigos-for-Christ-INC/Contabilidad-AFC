-- =====================================================================
-- Contabilidad AFC — Migración 002: roles configurables, bodegas e inventario
-- Ejecutar UNA vez, después de schema.sql (Supabase > SQL Editor > Run).
-- Conserva los usuarios, el catálogo y los asientos existentes.
-- =====================================================================
begin;

-- =====================================================================
-- PARTE A. ROLES Y PERMISOS
-- =====================================================================
-- Permisos disponibles:
--   contabilidad.ver        ver catálogo, asientos y reportes contables
--   contabilidad.editar     registrar asientos, catálogo, centros, tipos de cambio
--   contabilidad.periodos   cerrar y reabrir meses
--   inventario.ver          ver existencias, movimientos y kardex
--   inventario.editar       registrar y aplicar entradas, salidas, traslados y ajustes
--   inventario.anular       anular movimientos aplicados
--   inventario.catalogo     productos, unidades, categorías y bodegas
--   inventario.todas_bodegas  trabajar en todas las bodegas (si no, solo las asignadas)
--   admin.usuarios          usuarios, roles y bitácora
--   *                       todo (rol Administrador)
create or replace function permisos_validos() returns text[]
language sql immutable as $$
  select array['contabilidad.ver','contabilidad.editar','contabilidad.periodos',
               'inventario.ver','inventario.editar','inventario.anular','inventario.catalogo',
               'inventario.todas_bodegas','admin.usuarios']
$$;

create table roles (
  id          bigint generated always as identity primary key,
  nombre      text not null unique check (length(trim(nombre)) > 0),
  descripcion text,
  permisos    text[] not null default '{}' check (permisos <@ (permisos_validos() || '*'::text)),
  sistema     boolean not null default false
);

insert into roles (nombre, descripcion, permisos, sistema) values
  ('Administrador',  'Acceso total: usuarios, roles, contabilidad e inventario', array['*'], true),
  ('Contador',       'Contabilidad completa y cierre de meses; consulta y anula inventario',
     array['contabilidad.ver','contabilidad.editar','contabilidad.periodos','inventario.ver','inventario.anular','inventario.todas_bodegas'], false),
  ('Jefe de bodega', 'Inventario de todas las bodegas, productos y anulaciones',
     array['inventario.ver','inventario.editar','inventario.anular','inventario.catalogo','inventario.todas_bodegas'], false),
  ('Bodeguero',      'Registra movimientos solo en las bodegas que tenga asignadas',
     array['inventario.ver','inventario.editar'], false),
  ('Consulta',       'Solo lectura de contabilidad e inventario',
     array['contabilidad.ver','inventario.ver','inventario.todas_bodegas'], false);

alter table perfiles add column rol_id bigint references roles(id);
update perfiles p set rol_id = r.id
  from roles r
 where r.nombre = case p.rol::text when 'admin' then 'Administrador' when 'contador' then 'Contador' else 'Consulta' end;

create or replace function tiene_permiso(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select '*' = any(r.permisos) or p = any(r.permisos)
      from perfiles u join roles r on r.id = u.rol_id
     where u.id = auth.uid()), false)
$$;

create or replace function mis_permisos() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when '*' = any(r.permisos) then permisos_validos() else r.permisos end
      from perfiles u join roles r on r.id = u.rol_id
     where u.id = auth.uid()), '{}'::text[])
$$;

-- Las funciones de la versión 1 pasan a usar permisos
create or replace function puede_editar() returns boolean
language sql stable security definer set search_path = public as $$ select tiene_permiso('contabilidad.editar') $$;

create or replace function es_admin() returns boolean
language sql stable security definer set search_path = public as $$ select tiene_permiso('admin.usuarios') $$;

-- Se retira el rol fijo de la versión 1
drop policy leer on perfiles;       drop policy leer on cuentas;  drop policy leer on centros_costo;
drop policy leer on tipos_cambio;   drop policy leer on periodos; drop policy leer on asientos;
drop policy leer on asiento_lineas; drop policy leer on bitacora;
drop function mi_rol();
drop function cambiar_rol(uuid, rol_usuario);

-- Usuarios nuevos: el primero es Administrador; los demás entran SIN rol
-- (sin acceso) hasta que un administrador se lo asigne.
create or replace function nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfiles (id, nombre, correo, rol_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from perfiles) then null
         else (select id from roles where nombre = 'Administrador') end
  );
  return new;
end $$;

alter table perfiles drop column rol;
drop type rol_usuario;

create policy leer on perfiles       for select to authenticated using (auth.uid() is not null);
create policy leer on cuentas        for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver'));
create policy leer on centros_costo  for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver'));
create policy leer on tipos_cambio   for select to authenticated using (tiene_permiso('contabilidad.ver') or tiene_permiso('inventario.ver'));
create policy leer on periodos       for select to authenticated using (tiene_permiso('contabilidad.ver'));
create policy leer on asientos       for select to authenticated using (tiene_permiso('contabilidad.ver'));
create policy leer on asiento_lineas for select to authenticated using (tiene_permiso('contabilidad.ver'));
create policy leer on bitacora       for select to authenticated using (es_admin());

-- Roles: el de sistema (Administrador) no se modifica ni se elimina
create or replace function proteger_rol() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then new.sistema := false; return new; end if;
  if old.sistema then raise exception 'El rol % es del sistema y no se puede modificar ni eliminar', old.nombre; end if;
  if tg_op = 'DELETE' then
    if exists (select 1 from perfiles where rol_id = old.id) then
      raise exception 'El rol % tiene usuarios asignados; cámbielos de rol antes de eliminarlo', old.nombre;
    end if;
    return old;
  end if;
  new.sistema := false;
  return new;
end $$;
create trigger proteger_rol before insert or update or delete on roles for each row execute function proteger_rol();

create or replace function cambiar_rol(p_usuario uuid, p_rol bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'Solo un administrador puede cambiar roles'; end if;
  if not exists (select 1 from perfiles where id = p_usuario) then raise exception 'El usuario no existe'; end if;
  if p_rol is not null and not exists (select 1 from roles where id = p_rol) then raise exception 'El rol no existe'; end if;
  if (select '*' = any(r.permisos) from perfiles u join roles r on r.id = u.rol_id where u.id = p_usuario)
     and (p_rol is null or not (select '*' = any(permisos) from roles where id = p_rol))
     and (select count(*) from perfiles u join roles r on r.id = u.rol_id where '*' = any(r.permisos)) = 1 then
    raise exception 'Debe quedar al menos un usuario con el rol Administrador';
  end if;
  update perfiles set rol_id = p_rol where id = p_usuario;
end $$;

create or replace function cerrar_periodo(p_anio int, p_mes int) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not tiene_permiso('contabilidad.periodos') then raise exception 'No tiene permiso para cerrar períodos'; end if;
  insert into periodos (anio, mes) values (p_anio, p_mes) on conflict do nothing;
  select count(*) into n from asientos where anio = p_anio and mes = p_mes and estado = 'borrador';
  if n > 0 then
    raise exception 'Hay % asiento(s) en borrador en %/%; contabilícelos o elimínelos antes de cerrar',
      n, lpad(p_mes::text, 2, '0'), p_anio;
  end if;
  if exists (select 1 from inv_movimientos where anio = p_anio and extract(month from fecha) = p_mes and estado = 'borrador') then
    raise exception 'Hay movimientos de inventario en borrador en %/%; aplíquelos o elimínelos antes de cerrar',
      lpad(p_mes::text, 2, '0'), p_anio;
  end if;
  update periodos set estado = 'cerrado', cerrado_por = auth.uid(), cerrado_en = now()
   where anio = p_anio and mes = p_mes;
end $$;

create or replace function abrir_periodo(p_anio int, p_mes int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tiene_permiso('contabilidad.periodos') then raise exception 'No tiene permiso para reabrir períodos'; end if;
  update periodos set estado = 'abierto', cerrado_por = null, cerrado_en = null
   where anio = p_anio and mes = p_mes;
  if not found then raise exception 'El período %/% no existe', lpad(p_mes::text, 2, '0'), p_anio; end if;
end $$;

-- Contabilizar: la lógica queda en una función interna para que el
-- inventario pueda generar sus asientos sin dar permisos contables.
create or replace function _contabilizar(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare
  a asientos%rowtype;
  n int; d numeric; h numeric; v_cta text; v_num int;
begin
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

create or replace function contabilizar_asiento(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not puede_editar() then raise exception 'No tiene permiso para contabilizar asientos'; end if;
  return _contabilizar(p_id);
end $$;

alter table asientos add column origen text not null default 'manual' check (origen in ('manual','inventario'));

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
  if v_estado <> 'contabilizado' then raise exception 'Solo se anulan asientos contabilizados'; end if;
  update asientos
     set estado = 'anulado', anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(p_motivo)
   where id = p_id;
end $$;

-- =====================================================================
-- PARTE B. BODEGAS E INVENTARIO
-- =====================================================================
create table unidades (
  id     bigint generated always as identity primary key,
  codigo text not null unique check (length(trim(codigo)) > 0),
  nombre text not null
);

create table categorias_producto (
  id     bigint generated always as identity primary key,
  nombre text not null unique check (length(trim(nombre)) > 0),
  activa boolean not null default true
);

create table bodegas (
  id                   bigint generated always as identity primary key,
  codigo               text not null unique check (length(trim(codigo)) > 0),
  nombre               text not null check (length(trim(nombre)) > 0),
  ubicacion            text,
  cuenta_inventario_id bigint not null references cuentas(id),
  activa               boolean not null default true,
  creado_en            timestamptz not null default now()
);

create table perfil_bodegas (
  perfil_id uuid   not null references perfiles(id) on delete cascade,
  bodega_id bigint not null references bodegas(id) on delete cascade,
  primary key (perfil_id, bodega_id)
);

create or replace function puede_bodega(b bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select b is not null and (
    tiene_permiso('inventario.todas_bodegas')
    or exists (select 1 from perfil_bodegas where perfil_id = auth.uid() and bodega_id = b))
$$;

create table productos (
  id             bigint generated always as identity primary key,
  codigo         text not null unique check (length(trim(codigo)) > 0),
  nombre         text not null check (length(trim(nombre)) > 0),
  descripcion    text,
  categoria_id   bigint references categorias_producto(id),
  unidad_id      bigint not null references unidades(id),          -- unidad base: en ella se lleva la existencia
  stock_minimo   numeric(18,4) not null default 0 check (stock_minimo >= 0),
  costo_promedio numeric(18,6) not null default 0,                 -- C$ por unidad base (lo calcula el sistema)
  valor_total    numeric(18,2) not null default 0,                 -- valor del inventario de todas las bodegas
  activo         boolean not null default true,
  creado_en      timestamptz not null default now()
);

-- Presentaciones: otras unidades en que se compra o despacha (Caja de 24, Quintal de 100 lb, ...)
create table producto_presentaciones (
  id          bigint generated always as identity primary key,
  producto_id bigint not null references productos(id) on delete cascade,
  unidad_id   bigint not null references unidades(id),
  factor      numeric(18,6) not null check (factor > 0),           -- cuántas unidades base trae
  unique (producto_id, unidad_id)
);

create table existencias (
  producto_id bigint not null references productos(id),
  bodega_id   bigint not null references bodegas(id),
  cantidad    numeric(18,4) not null default 0 check (cantidad >= 0),
  primary key (producto_id, bodega_id)
);

create table inv_parametros (
  id               int primary key default 1 check (id = 1),
  cuenta_entrada_id bigint references cuentas(id),   -- contrapartida de entradas (p. ej. Proveedores)
  cuenta_salida_id  bigint references cuentas(id),   -- cargo de salidas (p. ej. Costo de programas)
  cuenta_ajuste_id  bigint references cuentas(id)    -- sobrantes, faltantes y diferencias de costo
);

create table inv_movimientos (
  id                      bigint generated always as identity primary key,
  tipo                    text not null check (tipo in ('entrada','salida','traslado','ajuste')),
  numero                  int,                       -- correlativo por tipo y año, al aplicar
  fecha                   date not null,
  anio                    int not null,
  bodega_id               bigint not null references bodegas(id),
  bodega_destino_id       bigint references bodegas(id),
  concepto                text not null check (length(trim(concepto)) > 0),
  referencia              text,
  cuenta_contrapartida_id bigint references cuentas(id),
  centro_costo_id         bigint references centros_costo(id),
  estado                  text not null default 'borrador' check (estado in ('borrador','aplicado','anulado')),
  asiento_id              bigint references asientos(id),
  asiento_anulacion_id    bigint references asientos(id),
  creado_por              uuid default auth.uid(),
  creado_en               timestamptz not null default now(),
  aplicado_por            uuid,
  aplicado_en             timestamptz,
  anulado_por             uuid,
  anulado_en              timestamptz,
  fecha_anulacion         date,
  motivo_anulacion        text,
  unique (tipo, anio, numero),
  check (tipo <> 'traslado' or (bodega_destino_id is not null and bodega_destino_id <> bodega_id))
);

create table inv_movimiento_lineas (
  id             bigint generated always as identity primary key,
  movimiento_id  bigint not null references inv_movimientos(id) on delete cascade,
  orden          int not null default 0,
  producto_id    bigint not null references productos(id),
  unidad_id      bigint not null references unidades(id),
  factor         numeric(18,6) not null default 1,
  cantidad       numeric(18,4) not null check (cantidad <> 0),   -- en la unidad elegida; en ajustes: + sobrante, − faltante
  cantidad_base  numeric(18,4) not null,                          -- cantidad × factor
  costo_unitario numeric(18,6),                                   -- C$ por unidad base
  costo_total    numeric(18,2),
  descripcion    text
);

create table inv_kardex (
  id                bigint generated always as identity primary key,
  movimiento_id     bigint not null references inv_movimientos(id),
  linea_id          bigint references inv_movimiento_lineas(id),
  fecha             date not null,
  producto_id       bigint not null references productos(id),
  bodega_id         bigint not null references bodegas(id),
  cantidad          numeric(18,4) not null,       -- + entra, − sale (unidad base)
  costo_unitario    numeric(18,6),
  costo_total       numeric(18,2) not null,       -- con signo
  costo_promedio    numeric(18,6) not null,       -- después del movimiento
  existencia_total  numeric(18,4) not null,       -- todas las bodegas, después
  existencia_bodega numeric(18,4) not null,       -- esta bodega, después
  es_reversion      boolean not null default false,
  creado_en         timestamptz not null default now()
);

create index on inv_movimientos (fecha);
create index on inv_movimientos (estado);
create index on inv_movimiento_lineas (movimiento_id);
create index on inv_kardex (producto_id, fecha);
create index on inv_kardex (bodega_id);
create index on existencias (bodega_id);

-- Validaciones de catálogo
create or replace function validar_bodega() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from cuentas where id = new.cuenta_inventario_id and tipo = 'activo' and acepta_movimientos) then
    raise exception 'La cuenta de inventario de la bodega debe ser de activo y aceptar movimientos';
  end if;
  return new;
end $$;
create trigger validar_bodega before insert or update on bodegas for each row execute function validar_bodega();

create or replace function validar_producto() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.unidad_id <> old.unidad_id and exists (select 1 from inv_movimiento_lineas where producto_id = old.id) then
    raise exception 'El producto % ya tiene movimientos; no se puede cambiar su unidad base', old.codigo;
  end if;
  return new;
end $$;
create trigger validar_producto before update on productos for each row execute function validar_producto();

create or replace function validar_presentacion() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.unidad_id = (select unidad_id from productos where id = new.producto_id) then
    raise exception 'La presentación debe usar una unidad distinta a la unidad base del producto';
  end if;
  return new;
end $$;
create trigger validar_presentacion before insert or update on producto_presentaciones for each row execute function validar_presentacion();

create or replace function validar_movimiento() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.estado <> 'borrador' then raise exception 'Solo se eliminan movimientos en borrador'; end if;
    return old;
  end if;
  new.anio := extract(year from new.fecha)::int;
  return new;
end $$;
create trigger validar_movimiento before insert or update or delete on inv_movimientos for each row execute function validar_movimiento();

create trigger bitacora_roles       after insert or update or delete on roles           for each row execute function registrar_bitacora();
create trigger bitacora_bodegas     after insert or update or delete on bodegas         for each row execute function registrar_bitacora();
create trigger bitacora_productos   after insert or delete or update of codigo, nombre, descripcion, categoria_id, unidad_id, stock_minimo, activo
  on productos for each row execute function registrar_bitacora();
create trigger bitacora_invparam    after insert or update or delete on inv_parametros  for each row execute function registrar_bitacora();
create trigger bitacora_movimientos after insert or update or delete on inv_movimientos for each row execute function registrar_bitacora();

-- ---------------------------------------------------------------------
-- Funciones internas del inventario
-- ---------------------------------------------------------------------
create or replace function _fmt_cant(x numeric) returns text
language sql immutable as $$
  select regexp_replace(regexp_replace(to_char(x, 'FM999,999,999,990.9999'), '0+$', ''), '\.$', '')
$$;

create or replace function _doc_inventario(p_tipo text, p_anio int, p_numero int) returns text
language sql immutable as $$
  select case p_tipo when 'entrada' then 'E' when 'salida' then 'S' when 'traslado' then 'T' else 'A' end
         || '-' || p_anio || '-' || lpad(coalesce(p_numero, 0)::text, 4, '0')
$$;

create or replace function _verificar_periodo(p_fecha date) returns void
language plpgsql security definer set search_path = public as $$
declare v text; y int := extract(year from p_fecha)::int; m int := extract(month from p_fecha)::int;
begin
  insert into periodos (anio, mes) values (y, m) on conflict do nothing;
  select estado into v from periodos where anio = y and mes = m;
  if v = 'cerrado' then raise exception 'El período %/% está cerrado', lpad(m::text, 2, '0'), y; end if;
end $$;

-- Costo de sacar q unidades base al costo promedio. Si se saca todo, se
-- usa el valor exacto para que el inventario quede en cero sin centavos.
create or replace function _costo_salida(p_prod bigint, p_q numeric) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare v_tot numeric; v_valor numeric; v_prom numeric;
begin
  select valor_total, costo_promedio into v_valor, v_prom from productos where id = p_prod;
  select coalesce(sum(cantidad), 0) into v_tot from existencias where producto_id = p_prod;
  if p_q >= v_tot then return v_valor; end if;
  return round(p_q * v_prom, 2);
end $$;

-- Mueve existencia y valor de un producto en una bodega y escribe el kardex.
create or replace function _inv_mover(p_mov bigint, p_linea bigint, p_fecha date, p_prod bigint, p_bod bigint,
                                      p_qty numeric, p_valor numeric, p_rev boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_valor numeric; v_prom numeric; v_tot numeric; v_ex numeric;
begin
  select valor_total, costo_promedio into v_valor, v_prom from productos where id = p_prod for update;
  select coalesce(sum(cantidad), 0) into v_tot from existencias where producto_id = p_prod;
  select coalesce((select cantidad from existencias where producto_id = p_prod and bodega_id = p_bod), 0) into v_ex;

  if v_ex + p_qty < 0 then
    raise exception 'Existencia insuficiente de % en %: hay %, se necesitan %',
      (select codigo || ' ' || nombre from productos where id = p_prod),
      (select nombre from bodegas where id = p_bod), _fmt_cant(v_ex), _fmt_cant(-p_qty);
  end if;

  update existencias set cantidad = cantidad + p_qty where producto_id = p_prod and bodega_id = p_bod;
  if not found then
    insert into existencias (producto_id, bodega_id, cantidad) values (p_prod, p_bod, p_qty);
  end if;

  v_tot := v_tot + p_qty;
  v_valor := v_valor + p_valor;
  if v_tot > 0 then v_prom := round(v_valor / v_tot, 6); end if;
  update productos set valor_total = v_valor, costo_promedio = v_prom where id = p_prod;

  insert into inv_kardex (movimiento_id, linea_id, fecha, producto_id, bodega_id, cantidad, costo_unitario,
                          costo_total, costo_promedio, existencia_total, existencia_bodega, es_reversion)
  values (p_mov, p_linea, p_fecha, p_prod, p_bod, p_qty,
          case when p_qty <> 0 then round(abs(p_valor / p_qty), 6) end,
          p_valor, v_prom, v_tot, v_ex + p_qty, p_rev);
end $$;

-- Crea y contabiliza el asiento de un movimiento. p_part es una lista de
-- {c: cuenta, cc: centro de costo, d: debe, h: haber}; se agrupa por cuenta.
-- Devuelve null si no hay montos (p. ej. traslado entre bodegas con la misma cuenta).
create or replace function _asiento_inventario(p_fecha date, p_concepto text, p_ref text, p_part jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; r record; i int := 0;
begin
  for r in
    select (e->>'c')::bigint as cta, nullif(e->>'cc', '')::bigint as cc,
           sum(coalesce((e->>'d')::numeric, 0) - coalesce((e->>'h')::numeric, 0)) as neto
      from jsonb_array_elements(p_part) e
     group by 1, 2
    having sum(coalesce((e->>'d')::numeric, 0) - coalesce((e->>'h')::numeric, 0)) <> 0
     order by 3 desc, 1
  loop
    if r.cta is null then raise exception 'Falta configurar una cuenta contable del inventario (vea Bodegas → Cuentas contables)'; end if;
    if v_id is null then
      insert into asientos (fecha, tipo, concepto, referencia, origen)
      values (p_fecha, 'diario', left(p_concepto, 500), p_ref, 'inventario') returning id into v_id;
    end if;
    i := i + 1;
    insert into asiento_lineas (asiento_id, orden, cuenta_id, centro_costo_id, debe, haber)
    values (v_id, i, r.cta, r.cc, case when r.neto > 0 then r.neto else 0 end, case when r.neto < 0 then -r.neto else 0 end);
  end loop;
  if v_id is not null then perform _contabilizar(v_id); end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Operaciones del inventario (la app escribe solo por estas funciones)
-- ---------------------------------------------------------------------

-- p = {id?, tipo, fecha, bodega_id, bodega_destino_id?, concepto, referencia?,
--      cuenta_contrapartida_id?, centro_costo_id?,
--      lineas:[{producto_id, unidad_id?, cantidad, costo?, descripcion?}]}
-- costo = C$ por unidad elegida (obligatorio en entradas; opcional en ajustes positivos).
create or replace function guardar_movimiento(p jsonb, p_aplicar boolean default false) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id   bigint := nullif(p->>'id', '')::bigint;
  v_tipo text   := p->>'tipo';
  v_fecha date  := nullif(p->>'fecha', '')::date;
  v_bod  bigint := nullif(p->>'bodega_id', '')::bigint;
  v_dest bigint := nullif(p->>'bodega_destino_id', '')::bigint;
  v_cta  bigint := nullif(p->>'cuenta_contrapartida_id', '')::bigint;
  v_cc   bigint := nullif(p->>'centro_costo_id', '')::bigint;
  v_old  inv_movimientos%rowtype;
  l jsonb; i int := 0; pr productos%rowtype;
  v_uni bigint; v_fac numeric; v_cant numeric; v_costo numeric; v_ct numeric;
begin
  if not tiene_permiso('inventario.editar') then raise exception 'No tiene permiso para registrar movimientos de inventario'; end if;
  if v_tipo is null or v_tipo not in ('entrada','salida','traslado','ajuste') then raise exception 'Tipo de movimiento no válido'; end if;
  if v_fecha is null then raise exception 'Indique la fecha'; end if;
  if coalesce(trim(p->>'concepto'), '') = '' then raise exception 'Indique el concepto'; end if;
  if v_bod is null then raise exception 'Seleccione la bodega'; end if;
  if not puede_bodega(v_bod) then raise exception 'No tiene acceso a la bodega seleccionada'; end if;
  if not exists (select 1 from bodegas where id = v_bod and activa) then raise exception 'La bodega no existe o está inactiva'; end if;

  if v_tipo = 'traslado' then
    if v_dest is null or v_dest = v_bod then raise exception 'Seleccione una bodega de destino distinta a la de origen'; end if;
    if not exists (select 1 from bodegas where id = v_dest and activa) then raise exception 'La bodega de destino no existe o está inactiva'; end if;
    v_cta := null; v_cc := null;
  else
    v_dest := null;
    if v_cta is null then
      select case v_tipo when 'entrada' then cuenta_entrada_id when 'salida' then cuenta_salida_id else cuenta_ajuste_id end
        into v_cta from inv_parametros where id = 1;
    end if;
    if v_cta is null then raise exception 'Falta la cuenta contable de contrapartida; configúrela en Bodegas → Cuentas contables'; end if;
    if not exists (select 1 from cuentas where id = v_cta and acepta_movimientos and activa) then
      raise exception 'La cuenta de contrapartida debe aceptar movimientos y estar activa';
    end if;
  end if;

  if v_id is null then
    insert into inv_movimientos (tipo, fecha, anio, bodega_id, bodega_destino_id, concepto, referencia, cuenta_contrapartida_id, centro_costo_id)
    values (v_tipo, v_fecha, extract(year from v_fecha)::int, v_bod, v_dest, trim(p->>'concepto'),
            nullif(trim(p->>'referencia'), ''), v_cta, v_cc)
    returning id into v_id;
  else
    select * into v_old from inv_movimientos where id = v_id for update;
    if not found then raise exception 'El movimiento % no existe', v_id; end if;
    if v_old.estado <> 'borrador' then raise exception 'Solo se modifican movimientos en borrador'; end if;
    if not puede_bodega(v_old.bodega_id) then raise exception 'No tiene acceso a la bodega de este movimiento'; end if;
    update inv_movimientos
       set tipo = v_tipo, fecha = v_fecha, bodega_id = v_bod, bodega_destino_id = v_dest, concepto = trim(p->>'concepto'),
           referencia = nullif(trim(p->>'referencia'), ''), cuenta_contrapartida_id = v_cta, centro_costo_id = v_cc
     where id = v_id;
    delete from inv_movimiento_lineas where movimiento_id = v_id;
  end if;

  for l in select * from jsonb_array_elements(coalesce(p->'lineas', '[]'::jsonb)) loop
    continue when nullif(l->>'producto_id', '') is null and coalesce(nullif(l->>'cantidad', '')::numeric, 0) = 0;
    i := i + 1;
    select * into pr from productos where id = nullif(l->>'producto_id', '')::bigint;
    if not found then raise exception 'Línea %: seleccione el producto', i; end if;
    if not pr.activo then raise exception 'Línea %: el producto % está inactivo', i, pr.codigo; end if;

    v_uni := coalesce(nullif(l->>'unidad_id', '')::bigint, pr.unidad_id);
    if v_uni = pr.unidad_id then
      v_fac := 1;
    else
      select factor into v_fac from producto_presentaciones where producto_id = pr.id and unidad_id = v_uni;
      if v_fac is null then raise exception 'Línea %: la unidad elegida no corresponde al producto %', i, pr.codigo; end if;
    end if;

    v_cant := coalesce(nullif(l->>'cantidad', '')::numeric, 0);
    if v_cant = 0 then raise exception 'Línea %: falta la cantidad', i; end if;
    if v_tipo <> 'ajuste' and v_cant < 0 then raise exception 'Línea %: la cantidad debe ser mayor que cero', i; end if;

    v_costo := nullif(l->>'costo', '')::numeric;
    if v_costo < 0 then raise exception 'Línea %: el costo no puede ser negativo', i; end if;
    if v_tipo = 'entrada' and v_costo is null then raise exception 'Línea %: indique el costo unitario', i; end if;
    v_ct := case when v_costo is not null and (v_tipo = 'entrada' or (v_tipo = 'ajuste' and v_cant > 0))
                 then round(v_cant * v_costo, 2) end;

    insert into inv_movimiento_lineas (movimiento_id, orden, producto_id, unidad_id, factor, cantidad, cantidad_base,
                                       costo_unitario, costo_total, descripcion)
    values (v_id, i, pr.id, v_uni, v_fac, v_cant, round(v_cant * v_fac, 4),
            case when v_ct is not null then round(v_ct / abs(v_cant * v_fac), 6) end, v_ct,
            nullif(trim(l->>'descripcion'), ''));
  end loop;

  if p_aplicar then perform aplicar_movimiento(v_id); end if;
  return v_id;
end $$;

-- Aplica un borrador: mueve existencias, calcula costos, numera y contabiliza.
create or replace function aplicar_movimiento(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare
  m inv_movimientos%rowtype; l record;
  v_num int; v_doc text; v_qb numeric; v_ct numeric; v_as bigint;
  cta_o bigint; cta_d bigint; v_part jsonb := '[]'::jsonb;
begin
  if not tiene_permiso('inventario.editar') then raise exception 'No tiene permiso para aplicar movimientos de inventario'; end if;
  select * into m from inv_movimientos where id = p_id for update;
  if not found then raise exception 'El movimiento % no existe', p_id; end if;
  if m.estado <> 'borrador' then raise exception 'Solo se aplican movimientos en borrador'; end if;
  if not puede_bodega(m.bodega_id) then raise exception 'No tiene acceso a la bodega de este movimiento'; end if;
  if not exists (select 1 from inv_movimiento_lineas where movimiento_id = p_id) then raise exception 'El movimiento no tiene líneas'; end if;
  perform _verificar_periodo(m.fecha);

  perform pg_advisory_xact_lock(hashtext('inv_' || m.tipo || '_' || m.anio));
  select coalesce(max(numero), 0) + 1 into v_num from inv_movimientos where tipo = m.tipo and anio = m.anio;
  v_doc := _doc_inventario(m.tipo, m.anio, v_num);

  select cuenta_inventario_id into cta_o from bodegas where id = m.bodega_id;
  select cuenta_inventario_id into cta_d from bodegas where id = m.bodega_destino_id;

  for l in select * from inv_movimiento_lineas where movimiento_id = p_id order by orden, id loop
    v_qb := l.cantidad_base;
    if m.tipo = 'entrada' then
      v_ct := l.costo_total;
      perform _inv_mover(m.id, l.id, m.fecha, l.producto_id, m.bodega_id, v_qb, v_ct, false);
      v_part := v_part || jsonb_build_array(jsonb_build_object('c', cta_o, 'd', v_ct),
                                            jsonb_build_object('c', m.cuenta_contrapartida_id, 'h', v_ct));

    elsif m.tipo = 'salida' or (m.tipo = 'ajuste' and v_qb < 0) then
      v_qb := abs(v_qb);
      v_ct := _costo_salida(l.producto_id, v_qb);
      perform _inv_mover(m.id, l.id, m.fecha, l.producto_id, m.bodega_id, -v_qb, -v_ct, false);
      update inv_movimiento_lineas set costo_total = v_ct, costo_unitario = round(v_ct / v_qb, 6) where id = l.id;
      v_part := v_part || jsonb_build_array(jsonb_build_object('c', m.cuenta_contrapartida_id, 'cc', m.centro_costo_id, 'd', v_ct),
                                            jsonb_build_object('c', cta_o, 'h', v_ct));

    elsif m.tipo = 'traslado' then
      v_ct := _costo_salida(l.producto_id, v_qb);
      perform _inv_mover(m.id, l.id, m.fecha, l.producto_id, m.bodega_id, -v_qb, -v_ct, false);
      perform _inv_mover(m.id, l.id, m.fecha, l.producto_id, m.bodega_destino_id, v_qb, v_ct, false);
      update inv_movimiento_lineas set costo_total = v_ct, costo_unitario = round(v_ct / v_qb, 6) where id = l.id;
      v_part := v_part || jsonb_build_array(jsonb_build_object('c', cta_d, 'd', v_ct),
                                            jsonb_build_object('c', cta_o, 'h', v_ct));

    else -- ajuste positivo (sobrante): al costo indicado o al promedio
      v_ct := coalesce(l.costo_total, round(v_qb * (select costo_promedio from productos where id = l.producto_id), 2));
      perform _inv_mover(m.id, l.id, m.fecha, l.producto_id, m.bodega_id, v_qb, v_ct, false);
      update inv_movimiento_lineas set costo_total = v_ct, costo_unitario = round(v_ct / v_qb, 6) where id = l.id;
      v_part := v_part || jsonb_build_array(jsonb_build_object('c', cta_o, 'd', v_ct),
                                            jsonb_build_object('c', m.cuenta_contrapartida_id, 'cc', m.centro_costo_id, 'h', v_ct));
    end if;
  end loop;

  v_as := _asiento_inventario(m.fecha,
            initcap(m.tipo) || ' de inventario ' || v_doc || ': ' || m.concepto, v_doc, v_part);

  update inv_movimientos
     set estado = 'aplicado', numero = v_num, asiento_id = v_as, aplicado_por = auth.uid(), aplicado_en = now()
   where id = p_id;
  return v_num;
end $$;

-- Anula un movimiento aplicado: revierte existencias en la fecha indicada
-- (hoy por defecto) y genera el asiento de reversión. El asiento original
-- se conserva, como en cualquier anulación contable.
create or replace function anular_movimiento(p_id bigint, p_motivo text, p_fecha date default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  m inv_movimientos%rowtype; l record;
  v_f date := coalesce(p_fecha, (now() at time zone 'America/Managua')::date);
  v_doc text; v_qb numeric; v_now numeric; v_dif numeric; v_as bigint;
  cta_o bigint; cta_d bigint; cta_a bigint; v_part jsonb := '[]'::jsonb;
begin
  if not tiene_permiso('inventario.anular') then raise exception 'No tiene permiso para anular movimientos de inventario'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo de la anulación'; end if;
  select * into m from inv_movimientos where id = p_id for update;
  if not found then raise exception 'El movimiento % no existe', p_id; end if;
  if m.estado <> 'aplicado' then raise exception 'Solo se anulan movimientos aplicados'; end if;
  if not puede_bodega(m.bodega_id) then raise exception 'No tiene acceso a la bodega de este movimiento'; end if;
  if v_f < m.fecha then raise exception 'La fecha de anulación no puede ser anterior a la del movimiento'; end if;
  perform _verificar_periodo(v_f);

  v_doc := _doc_inventario(m.tipo, m.anio, m.numero);
  select cuenta_inventario_id into cta_o from bodegas where id = m.bodega_id;
  select cuenta_inventario_id into cta_d from bodegas where id = m.bodega_destino_id;
  select cuenta_ajuste_id into cta_a from inv_parametros where id = 1;

  for l in select * from inv_movimiento_lineas where movimiento_id = p_id order by orden desc, id desc loop
    v_qb := abs(l.cantidad_base);
    if m.tipo = 'entrada' or (m.tipo = 'ajuste' and l.cantidad_base > 0) then
      -- Sale lo que entró, al costo promedio actual; la diferencia con el costo original va a ajustes
      v_now := _costo_salida(l.producto_id, v_qb);
      perform _inv_mover(m.id, l.id, v_f, l.producto_id, m.bodega_id, -v_qb, -v_now, true);
      v_dif := l.costo_total - v_now;
      v_part := v_part || jsonb_build_array(
        jsonb_build_object('c', m.cuenta_contrapartida_id, 'cc', case when m.tipo = 'ajuste' then m.centro_costo_id end, 'd', l.costo_total),
        jsonb_build_object('c', cta_o, 'h', v_now));
      if v_dif <> 0 then
        if cta_a is null then raise exception 'Configure la cuenta de ajustes de inventario en Bodegas → Cuentas contables'; end if;
        v_part := v_part || jsonb_build_array(jsonb_build_object('c', cta_a, 'h', v_dif));
      end if;

    elsif m.tipo = 'salida' or m.tipo = 'ajuste' then
      -- Regresa lo que salió, al mismo costo con que salió
      perform _inv_mover(m.id, l.id, v_f, l.producto_id, m.bodega_id, v_qb, l.costo_total, true);
      v_part := v_part || jsonb_build_array(jsonb_build_object('c', cta_o, 'd', l.costo_total),
                                            jsonb_build_object('c', m.cuenta_contrapartida_id, 'cc', m.centro_costo_id, 'h', l.costo_total));

    else -- traslado: regresa de destino a origen
      perform _inv_mover(m.id, l.id, v_f, l.producto_id, m.bodega_id, v_qb, l.costo_total, true);
      perform _inv_mover(m.id, l.id, v_f, l.producto_id, m.bodega_destino_id, -v_qb, -l.costo_total, true);
      v_part := v_part || jsonb_build_array(jsonb_build_object('c', cta_o, 'd', l.costo_total),
                                            jsonb_build_object('c', cta_d, 'h', l.costo_total));
    end if;
  end loop;

  v_as := _asiento_inventario(v_f, 'Anulación de ' || v_doc || ': ' || trim(p_motivo), v_doc, v_part);

  update inv_movimientos
     set estado = 'anulado', anulado_por = auth.uid(), anulado_en = now(), fecha_anulacion = v_f,
         motivo_anulacion = trim(p_motivo), asiento_anulacion_id = v_as
   where id = p_id;
end $$;

create or replace function eliminar_movimiento(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_bod bigint;
begin
  if not tiene_permiso('inventario.editar') then raise exception 'No tiene permiso para eliminar movimientos'; end if;
  select bodega_id into v_bod from inv_movimientos where id = p_id;
  if not found then raise exception 'El movimiento % no existe', p_id; end if;
  if not puede_bodega(v_bod) then raise exception 'No tiene acceso a la bodega de este movimiento'; end if;
  delete from inv_movimientos where id = p_id;   -- el trigger impide borrar si no es borrador
end $$;

create or replace function asignar_bodegas(p_usuario uuid, p_bodegas bigint[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then raise exception 'Solo un administrador puede asignar bodegas'; end if;
  delete from perfil_bodegas where perfil_id = p_usuario;
  insert into perfil_bodegas (perfil_id, bodega_id)
  select p_usuario, b from unnest(coalesce(p_bodegas, '{}'::bigint[])) b on conflict do nothing;
end $$;

-- Kardex de un producto (todas las bodegas o una). Respeta las bodegas del usuario.
create or replace function kardex(p_producto bigint, p_bodega bigint, p_desde date, p_hasta date)
returns table (fecha date, movimiento_id bigint, documento text, tipo text, concepto text, bodega text,
               entrada numeric, salida numeric, saldo numeric, costo_unitario numeric, costo_total numeric,
               costo_promedio numeric, es_reversion boolean)
language sql stable set search_path = public as $$
  with k as (
    select k.id, k.fecha, k.movimiento_id, k.cantidad, k.costo_unitario, k.costo_total, k.costo_promedio, k.es_reversion,
           m.tipo, m.anio, m.numero, m.concepto, b.nombre as bod
      from inv_kardex k
      join inv_movimientos m on m.id = k.movimiento_id
      join bodegas b on b.id = k.bodega_id
     where k.producto_id = p_producto and k.fecha <= p_hasta
       and (p_bodega is null or k.bodega_id = p_bodega)
  ),
  ini as (select coalesce(sum(cantidad), 0) as q from k where fecha < p_desde)
  select fecha, movimiento_id, documento, tipo, concepto, bodega, entrada, salida, saldo,
         costo_unitario, costo_total, costo_promedio, es_reversion
    from (
      select 0 as o, 0::bigint as kid, p_desde as fecha, null::bigint as movimiento_id, null::text as documento,
             null::text as tipo, 'Saldo inicial'::text as concepto, null::text as bodega,
             null::numeric as entrada, null::numeric as salida, (select q from ini) as saldo,
             null::numeric as costo_unitario, null::numeric as costo_total, null::numeric as costo_promedio,
             false as es_reversion
      union all
      select 1, k.id, k.fecha, k.movimiento_id, _doc_inventario(k.tipo, k.anio, k.numero), k.tipo,
             case when k.es_reversion then 'Anulación: ' else '' end || k.concepto, k.bod,
             case when k.cantidad > 0 then k.cantidad end, case when k.cantidad < 0 then -k.cantidad end,
             (select q from ini) + sum(k.cantidad) over (order by k.fecha, k.id),
             k.costo_unitario, abs(k.costo_total), k.costo_promedio, k.es_reversion
        from k where k.fecha >= p_desde
    ) x
   order by o, fecha, kid
$$;

-- ---------------------------------------------------------------------
-- Seguridad del inventario
-- ---------------------------------------------------------------------
alter table roles                   enable row level security;
alter table perfil_bodegas          enable row level security;
alter table unidades                enable row level security;
alter table categorias_producto     enable row level security;
alter table bodegas                 enable row level security;
alter table productos               enable row level security;
alter table producto_presentaciones enable row level security;
alter table existencias             enable row level security;
alter table inv_parametros          enable row level security;
alter table inv_movimientos         enable row level security;
alter table inv_movimiento_lineas   enable row level security;
alter table inv_kardex              enable row level security;

create policy leer   on roles for select to authenticated using (auth.uid() is not null);
create policy editar on roles for all    to authenticated using (es_admin()) with check (es_admin());
create policy leer   on perfil_bodegas for select to authenticated using (perfil_id = auth.uid() or es_admin());

create policy leer on unidades                for select to authenticated using (tiene_permiso('inventario.ver') or tiene_permiso('contabilidad.ver'));
create policy leer on categorias_producto     for select to authenticated using (tiene_permiso('inventario.ver') or tiene_permiso('contabilidad.ver'));
create policy leer on bodegas                 for select to authenticated using (tiene_permiso('inventario.ver') or tiene_permiso('contabilidad.ver'));
create policy leer on productos               for select to authenticated using (tiene_permiso('inventario.ver') or tiene_permiso('contabilidad.ver'));
create policy leer on producto_presentaciones for select to authenticated using (tiene_permiso('inventario.ver') or tiene_permiso('contabilidad.ver'));
create policy leer on inv_parametros          for select to authenticated using (tiene_permiso('inventario.ver') or tiene_permiso('contabilidad.ver'));

create policy editar on unidades                for all to authenticated using (tiene_permiso('inventario.catalogo')) with check (tiene_permiso('inventario.catalogo'));
create policy editar on categorias_producto     for all to authenticated using (tiene_permiso('inventario.catalogo')) with check (tiene_permiso('inventario.catalogo'));
create policy editar on bodegas                 for all to authenticated using (tiene_permiso('inventario.catalogo')) with check (tiene_permiso('inventario.catalogo'));
create policy editar on productos               for all to authenticated using (tiene_permiso('inventario.catalogo')) with check (tiene_permiso('inventario.catalogo'));
create policy editar on producto_presentaciones for all to authenticated using (tiene_permiso('inventario.catalogo')) with check (tiene_permiso('inventario.catalogo'));
create policy editar on inv_parametros          for all to authenticated
  using (tiene_permiso('inventario.catalogo') or tiene_permiso('contabilidad.editar'))
  with check (tiene_permiso('inventario.catalogo') or tiene_permiso('contabilidad.editar'));

create policy leer on existencias     for select to authenticated using (tiene_permiso('inventario.ver') and puede_bodega(bodega_id));
create policy leer on inv_kardex      for select to authenticated using (tiene_permiso('inventario.ver') and puede_bodega(bodega_id));
create policy leer on inv_movimientos for select to authenticated
  using (tiene_permiso('inventario.ver') and (puede_bodega(bodega_id) or puede_bodega(bodega_destino_id)));
create policy leer on inv_movimiento_lineas for select to authenticated
  using (exists (select 1 from inv_movimientos m where m.id = movimiento_id));

grant select on all tables in schema public to authenticated;
grant usage on all sequences in schema public to authenticated;
grant insert, update, delete on roles, unidades, categorias_producto, bodegas, producto_presentaciones, inv_parametros to authenticated;
-- productos: el costo promedio y el valor solo los cambia el sistema
grant insert (codigo, nombre, descripcion, categoria_id, unidad_id, stock_minimo, activo) on productos to authenticated;
grant update (codigo, nombre, descripcion, categoria_id, unidad_id, stock_minimo, activo) on productos to authenticated;
grant delete on productos to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

-- ---------------------------------------------------------------------
-- Datos iniciales (el administrador puede cambiarlos)
-- ---------------------------------------------------------------------
insert into unidades (codigo, nombre) values
  ('UND','Unidad'), ('PAR','Par'), ('DOC','Docena'), ('CAJA','Caja'), ('PAQ','Paquete'), ('BOLSA','Bolsa'),
  ('SACO','Saco'), ('ROLLO','Rollo'), ('LB','Libra'), ('KG','Kilogramo'), ('QQ','Quintal'), ('LT','Litro'),
  ('GAL','Galón'), ('M','Metro'), ('M2','Metro cuadrado'), ('M3','Metro cúbico'), ('PIE','Pie'), ('VARA','Vara');

insert into categorias_producto (nombre) values ('General');

-- Cuenta para ajustes de inventario (sobrantes, faltantes y diferencias de costo)
do $$
declare v text;
begin
  if not exists (select 1 from cuentas where nombre ilike 'Ajustes de inventario')
     and exists (select 1 from cuentas where codigo = '6.1') then
    select '6.1.' || lpad((coalesce(max(split_part(codigo, '.', 3)::int), 0) + 1)::text, 2, '0') into v
      from cuentas where codigo ~ '^6\.1\.[0-9]+$';
    insert into cuentas (codigo, nombre, tipo, naturaleza) values (v, 'Ajustes de inventario', 'gasto', 'deudora');
  end if;
end $$;

insert into inv_parametros (id, cuenta_entrada_id, cuenta_salida_id, cuenta_ajuste_id) values (1,
  (select id from cuentas where codigo = '2.1.01' and acepta_movimientos),
  (select id from cuentas where codigo = '5.1' and acepta_movimientos),
  (select id from cuentas where nombre ilike 'Ajustes de inventario' and acepta_movimientos limit 1));

-- Tres bodegas de ejemplo con la cuenta de inventario del catálogo base
insert into bodegas (codigo, nombre, cuenta_inventario_id)
select x.codigo, x.nombre, c.id
  from (values ('B01','Bodega principal'), ('B02','Bodega 2'), ('B03','Bodega 3')) as x(codigo, nombre)
  cross join (select id from cuentas where codigo = '1.1.07' and acepta_movimientos) c;

commit;
