-- =====================================================================
-- Contabilidad AFC — Migración 006: pago de planilla y colillas por correo
-- Ejecutar después de 005-pago-marcaje.sql.
--
-- El depósito se hace en Banpro en Línea (Plan Nómina) subiendo el archivo
-- que genera la app y aprobándolo con el token del banco. Luego se confirma
-- aquí el pago: se registra el asiento (Salarios por pagar contra Banco) y
-- la app de marcaje envía a cada trabajador su colilla por correo.
-- =====================================================================
begin;

alter table planillas
  add column fecha_pagado       date,
  add column pagada_en          timestamptz,
  add column pagado_por         uuid,
  add column cuenta_bancaria_id bigint references cuentas_bancarias(id),
  add column referencia_pago    text,
  add column asiento_pago_id    bigint references asientos(id),
  add column correos_enviados   int not null default 0,
  add column correos_error      int not null default 0,
  add column correos_en         timestamptz,
  add column correos_detalle    jsonb;

-- Token de un solo uso para que la app de marcaje envíe las colillas.
-- Vive en su propia tabla, sin acceso desde la app (solo lo usan las funciones).
create table planilla_tokens (
  planilla_id bigint primary key references planillas(id) on delete cascade,
  token       text not null,
  creado_en   timestamptz not null default now()
);
alter table planilla_tokens enable row level security;
revoke all on planilla_tokens from public, anon, authenticated;

create or replace function _token_correo() returns text language sql volatile as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

-- Confirmar que el banco ya depositó: asiento de pago y token para enviar las colillas
create or replace function pagar_planilla(p_id bigint, p_cuenta_bancaria bigint, p_fecha date, p_referencia text, p_enviar_correos boolean default true)
returns text language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype; par planilla_parametros; cb cuentas_bancarias%rowtype; v_as bigint; v_tok text;
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'Solo Administración confirma el pago de la planilla'; end if;
  select * into pl from planillas where id = p_id for update;
  if not found then raise exception 'La planilla no existe'; end if;
  if pl.estado <> 'aprobada' then raise exception 'Solo se pagan planillas aprobadas'; end if;
  if pl.pagada_en is not null then raise exception 'Esta planilla ya está pagada'; end if;
  if p_fecha is null or p_fecha < pl.desde then raise exception 'Revise la fecha del depósito'; end if;
  select * into cb from cuentas_bancarias where id = p_cuenta_bancaria and activa;
  if not found then raise exception 'Elija una cuenta bancaria activa'; end if;
  if cb.moneda <> 'NIO' then raise exception 'La planilla se paga desde una cuenta en córdobas'; end if;
  par := _parametros_planilla(pl.hasta);

  insert into asientos (fecha, tipo, concepto, referencia, moneda, origen)
  values (p_fecha, 'egreso', left('Pago de ' || pl.descripcion, 500), coalesce(nullif(trim(p_referencia), ''), 'PL-' || pl.id), 'NIO', 'planilla')
  returning id into v_as;
  insert into asiento_lineas (asiento_id, orden, cuenta_id, descripcion, debe, haber) values
    (v_as, 1, par.cuenta_neto_pagar_id, 'Neto pagado a ' || pl.empleados || ' colaboradores', pl.total_neto, 0),
    (v_as, 2, cb.cuenta_contable_id, 'Depósito ' || cb.banco || coalesce(' · ' || nullif(trim(p_referencia), ''), ''), 0, pl.total_neto);
  perform _contabilizar(v_as);

  v_tok := case when p_enviar_correos then _token_correo() end;
  update planillas set fecha_pagado = p_fecha, pagada_en = now(), pagado_por = auth.uid(), cuenta_bancaria_id = cb.id,
         referencia_pago = nullif(trim(p_referencia), ''), asiento_pago_id = v_as
   where id = p_id;
  if v_tok is not null then
    insert into planilla_tokens (planilla_id, token) values (p_id, v_tok)
    on conflict (planilla_id) do update set token = excluded.token, creado_en = now();
  end if;
  return v_tok;
end $$;

create or replace function reenviar_colillas(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare v_tok text := _token_correo();
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'Solo Administración envía las colillas'; end if;
  if not exists (select 1 from planillas where id = p_id and pagada_en is not null and estado = 'aprobada') then
    raise exception 'Solo se envían colillas de planillas pagadas';
  end if;
  insert into planilla_tokens (planilla_id, token) values (p_id, v_tok)
  on conflict (planilla_id) do update set token = excluded.token, creado_en = now();
  return v_tok;
end $$;

create or replace function anular_pago_planilla(p_id bigint, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare pl planillas%rowtype;
begin
  if not tiene_permiso('planilla.aprobar') then raise exception 'No tiene permiso'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Indique el motivo'; end if;
  select * into pl from planillas where id = p_id for update;
  if pl.pagada_en is null then raise exception 'La planilla no está pagada'; end if;
  perform _revertir_asiento(pl.asiento_pago_id, greatest(pl.fecha_pagado, (now() at time zone 'America/Managua')::date),
                            'Anulación del pago: ' || pl.descripcion || '. ' || trim(p_motivo), 'planilla');
  update planillas set fecha_pagado = null, pagada_en = null, pagado_por = null, cuenta_bancaria_id = null, referencia_pago = null,
         asiento_pago_id = null where id = p_id;
  delete from planilla_tokens where planilla_id = p_id;
end $$;

-- Una planilla pagada no se anula sin anular antes el pago
create or replace function _bloquear_anular_pagada() returns trigger language plpgsql as $$
begin
  if new.estado = 'anulada' and old.pagada_en is not null then
    raise exception 'La planilla ya se pagó; anule primero el pago';
  end if;
  return new;
end $$;
create trigger bloquear_anular_pagada before update on planillas for each row execute function _bloquear_anular_pagada();

-- La app de marcaje pide las colillas con la clave de integración y el token de un solo uso
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
      'dias_pagados', case when l.salario_mensual > 0 then round(l.salario_periodo * 30 / l.salario_mensual, 2) else 0 end,
      'salario', l.salario_periodo, 'bruto', l.bruto, 'inss', l.inss_laboral, 'ir', l.ir, 'deducciones', l.deducciones, 'neto', l.neto,
      'novedades', coalesce((select jsonb_agg(jsonb_build_object('concepto', c.nombre, 'tipo', c.tipo, 'monto', n.monto, 'detalle', n.descripcion) order by c.tipo, n.id)
                               from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id
                              where n.planilla_id = pl.id and n.empleado_id = e.id), '[]'),
      'vacaciones', (select round(coalesce(sum(m.dias), 0), 2) from vacaciones_movimientos m where m.empleado_id = e.id and m.estado = 'aprobado')
    ) order by e.nombre), '[]') into v
    from planilla_lineas l join empleados e on e.id = l.empleado_id
   where l.planilla_id = pl.id and l.neto > 0;

  return jsonb_build_object('id', pl.id, 'descripcion', pl.descripcion, 'desde', pl.desde, 'hasta', pl.hasta,
                            'fecha_pagado', pl.fecha_pagado, 'empleados', v);
end $$;

create or replace function registrar_envio_colillas(p_clave text, p_planilla bigint, p_enviados int, p_errores int, p_detalle jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from integracion_claves where hash = _hash_clave(regexp_replace(coalesce(p_clave, ''), '^afc_', '')) and activa) then
    raise exception 'Clave de integración no válida';
  end if;
  update planillas set correos_enviados = coalesce(p_enviados, 0), correos_error = coalesce(p_errores, 0),
         correos_en = now(), correos_detalle = p_detalle
   where id = p_planilla and pagada_en is not null;
end $$;

-- "Mi pago": la planilla cuenta en el mes en que se depositó (o en su fecha de pago si aún no se confirma)
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

  select coalesce(jsonb_agg(x order by x->>'fecha_pago', x->>'desde'), '[]') into v_planillas from (
    select jsonb_build_object(
      'descripcion', p.descripcion, 'desde', p.desde, 'hasta', p.hasta, 'fecha_pago', coalesce(p.fecha_pagado, p.fecha_pago),
      'depositada', p.pagada_en is not null, 'tipo', p.tipo,
      'dias_pagados', case when l.salario_mensual > 0 then round(l.salario_periodo * 30 / l.salario_mensual, 2) else 0 end,
      'salario', l.salario_periodo, 'otros_ingresos', l.ingresos, 'bruto', l.bruto,
      'inss', l.inss_laboral, 'ir', l.ir, 'otras_deducciones', l.deducciones, 'neto', l.neto,
      'novedades', coalesce((select jsonb_agg(jsonb_build_object('concepto', c.nombre, 'tipo', c.tipo, 'monto', n.monto, 'detalle', n.descripcion) order by c.tipo, n.id)
                               from planilla_novedades n join conceptos_planilla c on c.id = n.concepto_id
                              where n.planilla_id = p.id and n.empleado_id = e.id), '[]')
    ) x
      from planillas p join planilla_lineas l on l.planilla_id = p.id and l.empleado_id = e.id
     where p.estado = 'aprobada' and coalesce(p.fecha_pagado, p.fecha_pago) between v_ini and v_fin
  ) s;

  return jsonb_build_object(
    'encontrado', true, 'nombre', e.nombre, 'cargo', e.cargo, 'tipo_pago', e.tipo_pago,
    'salario_mensual', e.salario_mensual, 'anio', p_anio, 'mes', p_mes, 'planillas', v_planillas,
    'total_bruto',       (select coalesce(sum((x->>'bruto')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_inss',        (select coalesce(sum((x->>'inss')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_ir',          (select coalesce(sum((x->>'ir')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_deducciones', (select coalesce(sum((x->>'otras_deducciones')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'total_neto',        (select coalesce(sum((x->>'neto')::numeric), 0) from jsonb_array_elements(v_planillas) x),
    'vacaciones_saldo', round(v_saldo, 2));
end $$;

revoke execute on function _token_correo() from public, anon, authenticated;
revoke execute on function pagar_planilla(bigint, bigint, date, text, boolean) from public, anon;
revoke execute on function reenviar_colillas(bigint) from public, anon;
revoke execute on function anular_pago_planilla(bigint, text) from public, anon;
grant execute on function pagar_planilla(bigint, bigint, date, text, boolean), reenviar_colillas(bigint), anular_pago_planilla(bigint, text) to authenticated;
revoke execute on function colillas_planilla(text, bigint, text) from public;
revoke execute on function registrar_envio_colillas(text, bigint, int, int, jsonb) from public;
grant execute on function colillas_planilla(text, bigint, text), registrar_envio_colillas(text, bigint, int, int, jsonb) to anon, authenticated;

-- Quien aprueba planillas necesita ver las cuentas bancarias para registrar el pago (solo lectura)
drop policy if exists leer_pago_planilla on cuentas_bancarias;
create policy leer_pago_planilla on cuentas_bancarias for select to authenticated using (tiene_permiso('planilla.aprobar'));

commit;
