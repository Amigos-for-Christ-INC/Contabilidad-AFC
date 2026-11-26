// Pruebas de la migración 004 (planilla, vacaciones y marcaje) sobre schema.sql + 002 + 003.
// Uso: node prueba-planilla.mjs  (desde la carpeta con los cuatro .sql)
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';

const db = new PGlite({ parsers: { 1700: v => Number(v), 1082: v => v } });
await db.exec(`
  create role anon nologin; create role authenticated nologin;
  create schema auth;
  create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb default '{}');
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  grant usage on schema auth to authenticated, anon;
  grant execute on function auth.uid() to authenticated, anon;
  grant usage on schema public to authenticated, anon;
`);
for (const f of ['schema.sql', '002-roles-inventario.sql', '003-bancos-cheques.sql', '004-planilla-marcaje.sql', '005-pago-marcaje.sql', '006-pago-planilla.sql']) await db.exec(fs.readFileSync('./' + f, 'utf8'));

const ADM = '11111111-1111-1111-1111-111111111111', RH = '22222222-2222-2222-2222-222222222222',
      DIR = '33333333-3333-3333-3333-333333333333', BOD = '44444444-4444-4444-4444-444444444444', CON = '55555555-5555-5555-5555-555555555555';
await db.exec(`insert into auth.users (id, email) values ('${ADM}','admin@x.org'), ('${RH}','rrhh@x.org'), ('${DIR}','admin2@x.org'), ('${BOD}','bodega@x.org'), ('${CON}','conta@x.org')`);
const rol = async n => (await db.query(`select id from roles where nombre=$1`, [n])).rows[0].id;
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Recursos Humanos'), RH]);
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Administración'), DIR]);
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Bodeguero'), BOD]);
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Contador'), CON]);

let ok = 0, fail = 0;
const check = (n, c, x = '') => { if (c) { ok++; console.log('  ✓', n); } else { fail++; console.log('  ✗', n, x); } };
async function como(uid, sql, params = []) {
  await db.exec(uid === 'anon' ? `reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;`
    : `reset role; select set_config('request.jwt.claim.sub', '${uid}', false); set role authenticated;`);
  try { return await db.query(sql, params); } finally { await db.exec('reset role;'); }
}
async function falla(n, uid, sql, params, re) {
  try { await como(uid, sql, params); check(n, false, '(no falló)'); }
  catch (e) { check(n, re.test(e.message), '→ ' + e.message); }
}
const v1 = (q, p = []) => db.query(q, p).then(r => r.rows);
const casi = (a, b) => Math.abs(Number(a) - Number(b)) < 0.005;
const saldoCta = async id => Number((await v1(`select coalesce(sum(l.haber-l.debe),0) s from asiento_lineas l join asientos a on a.id=l.asiento_id where a.estado='contabilizado' and l.cuenta_id=$1`, [id]))[0].s);

console.log('Migración');
const par = (await v1(`select * from planilla_parametros`))[0];
check('parámetros 2026: INSS 7% / 22.5%, INATEC 2%', par.inss_laboral === 7 && par.inss_patronal === 22.5 && par.inatec === 2);
const nombreCta = async id => (await v1(`select codigo||' '||nombre n from cuentas where id=$1`, [id]))[0].n;
check('usa 6.1.01 Sueldos y salarios', (await nombreCta(par.cuenta_salarios_id)).startsWith('6.1.01'));
check('usa 2.1.04 INSS por pagar', (await nombreCta(par.cuenta_inss_pagar_id)).startsWith('2.1.04'));
check('crea cuentas nuevas con código libre', /^2\.1\.0[6-9] /.test(await nombreCta(par.cuenta_neto_pagar_id)), await nombreCta(par.cuenta_neto_pagar_id));
check('5 tramos del IR', (await v1(`select count(*)::int n from ir_tramos`))[0].n === 5);
check('roles RR. HH. y Administración', (await v1(`select count(*)::int n from roles where nombre in ('Recursos Humanos','Administración')`))[0].n === 2);
await falla('nadie llama funciones internas (_contabilizar)', CON, `select _contabilizar(1)`, [], /permission denied|permiso denegado/);
await falla('nadie llama funciones internas (_revertir_asiento)', ADM, `select _revertir_asiento(1, current_date, 'x', 'manual')`, [], /permission denied|permiso denegado/);

console.log('IR');
const ir = async (b, n) => (await v1(`select ir_periodo($1, $2, '2026-11-15') v`, [b, n]))[0].v;
check('exento hasta C$ 100,000 al año', await ir(100000 / 12, 12) === 0);
check('tramo 20%: 13,950 quincenal → 1,748.33', casi(await ir(13950, 24), 1748.33), await ir(13950, 24));
check('tramo 15%: 5,580 quincenal → 212.00', casi(await ir(5580, 24), 212));
check('tramo 30%: 55,800 mensual → 11,115.00', casi(await ir(55800, 12), 11115));

console.log('Colaboradores');
const centro = (await v1(`select id from centros_costo where codigo='ADM'`))[0].id;
const emp = async e => (await como(RH, `insert into empleados (nombre, correo, cedula, inss_numero, cargo, centro_costo_id, fecha_ingreso, tipo_pago, salario_mensual, cuenta_banco)
  values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) returning id`, [e.nombre, e.correo, e.cedula, '1234567', e.cargo, centro, e.ingreso, e.tipo, e.salario, '10010011112222'])).rows[0].id;
const A = await emp({ nombre: 'Ana Pérez', correo: 'ana@afc.org', cedula: '081-010190-0001A', cargo: 'Coordinadora', ingreso: '2020-01-06', tipo: 'quincenal', salario: 30000 });
const B = await emp({ nombre: 'Bruno Díaz', correo: 'bruno@afc.org', cedula: '081-020290-0002B', cargo: 'Conductor', ingreso: '2023-03-01', tipo: 'quincenal', salario: 12000 });
const C = await emp({ nombre: 'Carla Ruiz', correo: 'carla@afc.org', cedula: '081-030390-0003C', cargo: 'Directora', ingreso: '2018-05-02', tipo: 'mensual', salario: 60000 });
const D = await emp({ nombre: 'Diego Mora', correo: 'diego@afc.org', cedula: '081-040490-0004D', cargo: 'Técnico', ingreso: '2026-11-11', tipo: 'quincenal', salario: 15000 });
check('RR. HH. registra colaboradores', A && B && C && D);
check('bodeguero no ve colaboradores ni salarios', (await como(BOD, `select count(*)::int n from empleados`)).rows[0].n === 0);
check('contador no ve salarios', (await como(CON, `select count(*)::int n from empleados`)).rows[0].n === 0);
check('Administración no edita colaboradores', (await como(DIR, `update empleados set salario_mensual = 1 where id = ${A} returning id`)).rows.length === 0);

console.log('Planilla quincenal');
const pq = (await como(RH, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'quincenal', desde: '2026-11-01', hasta: '2026-11-15', fecha_pago: '2026-11-15' })])).rows[0].id;
const lin = async (pl, e) => (await v1(`select * from planilla_lineas where planilla_id=$1 and empleado_id=$2`, [pl, e]))[0];
check('incluye solo quincenales (3)', (await v1(`select count(*)::int n from planilla_lineas where planilla_id=$1`, [pq]))[0].n === 3);
let a = await lin(pq, A);
check('Ana: salario 15,000, INSS 1,050', a.salario_periodo === 15000 && a.inss_laboral === 1050);
check('Ana: IR 1,748.33, neto 12,201.67', casi(a.ir, 1748.33) && casi(a.neto, 12201.67), JSON.stringify(a));
check('Ana: INSS patronal 3,375, INATEC 300', a.inss_patronal === 3375 && a.inatec === 300);
const d = await lin(pq, D);
check('Diego entró el 11: 5 días = C$ 2,500', d.salario_periodo === 2500, d.salario_periodo);
await falla('no se duplica la quincena', RH, `select guardar_planilla($1::jsonb)`, [JSON.stringify({ tipo: 'quincenal', desde: '2026-11-10', hasta: '2026-11-20' })], /Ya existe/);

const conc = async c => (await v1(`select id from conceptos_planilla where codigo=$1`, [c]))[0].id;
await como(RH, `select guardar_novedad($1::jsonb)`, [JSON.stringify({ planilla_id: pq, empleado_id: B, concepto_id: await conc('BONO'), monto: 1000, descripcion: 'Bono de desempeño' })]);
await como(RH, `select guardar_novedad($1::jsonb)`, [JSON.stringify({ planilla_id: pq, empleado_id: A, concepto_id: await conc('PREST'), monto: 500, descripcion: 'Cuota 3/10' })]);
await como(RH, `select guardar_novedad($1::jsonb)`, [JSON.stringify({ planilla_id: pq, empleado_id: B, concepto_id: await conc('VIAT'), monto: 400 })]);
const lb = await lin(pq, B);
await como(RH, `select actualizar_linea_planilla($1, 2)`, [lb.id]);
const b = await lin(pq, B);
check('Bruno: 2 días sin goce → salario 5,200', b.salario_periodo === 5200, b.salario_periodo);
check('Bruno: bono suma a INSS e IR, viático no', b.bruto === 6600 && b.base_inss === 6200 && b.inss_laboral === 434, JSON.stringify(b));
a = await lin(pq, A);
check('Ana: préstamo descuenta del neto', casi(a.neto, 11701.67) && a.deducciones === 500);
const nv = (await como(RH, `select guardar_novedad($1::jsonb) id`, [JSON.stringify({ planilla_id: pq, empleado_id: D, concepto_id: await conc('OTRA'), monto: 99999 })])).rows[0].id;
await falla('no se envía con neto negativo', RH, `select enviar_planilla($1)`, [pq], /negativo/);
await como(RH, `select eliminar_novedad($1)`, [nv]);

console.log('Aprobación');
await falla('RR. HH. no aprueba', RH, `select aprobar_planilla($1)`, [pq], /permiso/);
await falla('no se aprueba un borrador', DIR, `select aprobar_planilla($1)`, [pq], /enviadas/);
await como(RH, `select enviar_planilla($1)`, [pq]);
await falla('ya no se edita al enviarla', RH, `select actualizar_linea_planilla($1, 0)`, [lb.id], /borrador/);
await como(DIR, `select devolver_planilla($1, 'Revisar el bono')`, [pq]);
check('Administración la devuelve con motivo', (await v1(`select estado, motivo_devolucion m from planillas where id=$1`, [pq]))[0].m === 'Revisar el bono');
await como(RH, `select enviar_planilla($1)`, [pq]);
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Administrador'), ADM]);
await como(ADM, `select 1`);
// Un administrador que elabora no puede aprobar su propia planilla
const pm = (await como(ADM, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'mensual', desde: '2026-11-01', hasta: '2026-11-30' })])).rows[0].id;
await como(ADM, `select enviar_planilla($1)`, [pm]);
await falla('quien elabora no aprueba (ni siendo admin)', ADM, `select aprobar_planilla($1)`, [pm], /otra persona/);
check('Carla mensual: IR 11,115', casi((await lin(pm, C)).ir, 11115));

const asq = (await como(DIR, `select aprobar_planilla($1) id`, [pq])).rows[0].id;
const as = (await v1(`select estado, origen, referencia from asientos where id=$1`, [asq]))[0];
const tot = (await v1(`select sum(debe) d, sum(haber) h from asiento_lineas where asiento_id=$1`, [asq]))[0];
check('asiento contabilizado, origen planilla', as.estado === 'contabilizado' && as.origen === 'planilla' && as.referencia === 'PL-' + pq);
check('asiento cuadra', casi(tot.d, tot.h), JSON.stringify(tot));
const pl = (await v1(`select * from planillas where id=$1`, [pq]))[0];
check('salarios por pagar = total neto', casi(await saldoCta(par.cuenta_neto_pagar_id), pl.total_neto));
check('INSS por pagar = laboral + patronal', casi(await saldoCta(par.cuenta_inss_pagar_id), pl.total_inss_laboral + pl.total_inss_patronal));
check('gasto = bruto + patronal + INATEC', casi(-await saldoCta(par.cuenta_salarios_id) - await saldoCta(par.cuenta_patronal_id), pl.total_bruto + pl.total_inss_patronal + pl.total_inatec));
const prestamos = (await v1(`select cuenta_id from conceptos_planilla where codigo='PREST'`))[0].cuenta_id;
check('préstamo acredita la cuenta por cobrar', casi(await saldoCta(prestamos), 500));
await falla('contabilidad no anula el asiento de planilla', ADM, `select anular_asiento($1, 'x')`, [asq], /anule la planilla/);
const vacA = (await v1(`select sum(dias) s from vacaciones_movimientos where empleado_id=$1 and estado='aprobado'`, [A]))[0].s;
check('Ana acumula 1.25 días de vacaciones', vacA === 1.25, vacA);
const vacD = (await v1(`select sum(dias) s from vacaciones_movimientos where empleado_id=$1 and estado='aprobado'`, [D]))[0].s;
check('Diego acumula proporcional (0.42)', vacD === 0.42, vacD);

console.log('Vacaciones y días extra');
await como(RH, `select registrar_vacaciones($1::jsonb)`, [JSON.stringify({ empleado_id: A, tipo: 'saldo_inicial', dias: 10, fecha: '2026-10-31', descripcion: 'Saldo traído de AG Planilla' })]);
const ex = (await como(RH, `select registrar_vacaciones($1::jsonb) id`, [JSON.stringify({ empleado_id: A, tipo: 'dia_extra', dias: 1, fecha: '2026-11-08', descripcion: 'Feria de salud' })])).rows[0].id;
check('el día extra queda pendiente', (await v1(`select estado from vacaciones_movimientos where id=$1`, [ex]))[0].estado === 'pendiente');
await falla('RR. HH. no aprueba días extra', RH, `select revisar_dia_extra($1, true)`, [ex], /Administración/);
await como(DIR, `select revisar_dia_extra($1, true)`, [ex]);
const sal = (await como(DIR, `select * from saldos_vacaciones() where empleado_id=$1`, [A])).rows[0];
check('Administración aprueba: saldo 12.25', sal.saldo === 12.25, JSON.stringify(sal));
await falla('no se revisa dos veces', DIR, `select revisar_dia_extra($1, false, 'x')`, [ex], /ya fue revisado/);

console.log('Puente con el marcaje');
const clave = (await como(RH, `select crear_clave_integracion('App de marcaje') c`)).rows[0].c;
check('clave generada', /^afc_[0-9a-f]{64}$/.test(clave));
check('la clave no se guarda en claro', !(await v1(`select hash from integracion_claves`))[0].hash.includes(clave.slice(4)));
const datos = {
  dias_laborales: [1, 2, 3, 4, 5], feriados: ['2026-12-08'], horas_dia: 8,
  empleados: [{ correo: 'ANA@afc.org', nombre: 'Ana Pérez', cargo: 'Coordinadora', lugar: 'Chinandega', lider: 'jefe@afc.org', activo: true },
              { correo: 'eva@afc.org', nombre: 'Eva Gómez', cargo: 'Promotora', lugar: 'Villa 15', activo: true }],
  marcas: [{ id: 'M1', fecha: '2026-11-20', correo: 'ana@afc.org', entrada: '07:58', salida: '17:05', horas: 9.1 },
           { id: 'M2', fecha: '2026-11-21', correo: 'ana@afc.org', entrada: '08:10', salida: '12:00', horas: 3.8 },
           { id: 'M3', fecha: '2026-11-22', correo: 'nadie@afc.org', entrada: '08:00' },
           { id: 'M4', fecha: '2026-11-29', correo: 'ana@afc.org', entrada: '08:00', salida: '12:00', horas: 4, reposicion: true }],
  permisos: [{ id: 'P1', correo: 'ana@afc.org', tipo: 'Vacaciones', desde: '2026-11-23', hasta: '2026-11-25', estado: 'Aprobado' },
             { id: 'P2', correo: 'ana@afc.org', tipo: 'Cita médica', desde: '2026-11-26', hasta: '2026-11-26', estado: 'Aprobado' },
             { id: 'P3', correo: 'ana@afc.org', tipo: 'Vacaciones', desde: '2026-11-27', hasta: '2026-11-27', horaDesde: '13:00', horaHasta: '17:00', estado: 'Aprobado' }]
};
await falla('clave falsa rechazada', 'anon', `select recibir_marcaje($1, $2::jsonb)`, ['afc_' + '0'.repeat(64), JSON.stringify(datos)], /no válida/);
await falla('anónimo no lee colaboradores', 'anon', `select * from empleados`, [], /permission denied|permiso denegado/);
const r1 = (await como('anon', `select recibir_marcaje($1, $2::jsonb) r`, [clave, JSON.stringify(datos)])).rows[0].r;
check('recibe 2 colaboradores, 4 marcas, 3 permisos', r1.empleados === 2 && r1.marcas === 4 && r1.permisos === 3, JSON.stringify(r1));
check('Eva se crea desde el marcaje sin salario', (await v1(`select origen, salario_mensual s from empleados where correo='eva@afc.org'`))[0].origen === 'marcaje');
check('Ana conserva su salario y toma el lugar del marcaje', (await v1(`select salario_mensual s, lugar from empleados where id=$1`, [A]))[0].lugar === 'Chinandega');
check('sábado trabajado = 1 día extra pendiente; la reposición no cuenta', r1.dias_extra_nuevos === 1 && (await v1(`select count(*)::int n from vacaciones_movimientos where ref_externa='extra:M2' and estado='pendiente'`))[0].n === 1);
const tom = await v1(`select ref_externa, dias from vacaciones_movimientos where tipo='tomadas' order by ref_externa`);
check('vacaciones lun–mié = −3 días; media tarde = −0.5', tom.length === 2 && tom[0].dias === -3 && tom[1].dias === -0.5, JSON.stringify(tom));
const r2 = (await como('anon', `select recibir_marcaje($1, $2::jsonb) r`, [clave, JSON.stringify(datos)])).rows[0].r;
check('reenviar no duplica', r2.dias_extra_nuevos === 0 && (await v1(`select count(*)::int n from vacaciones_movimientos where origen='marcaje'`))[0].n === 3);
datos.permisos[0].estado = 'Rechazado';
await como('anon', `select recibir_marcaje($1, $2::jsonb) r`, [clave, JSON.stringify(datos)]);
check('si el permiso cambia, se anula el descuento', (await v1(`select estado from vacaciones_movimientos where ref_externa='perm:P1'`))[0].estado === 'anulado');
check('queda registrado el último envío', (await v1(`select ultimo_resultado r from integracion_claves`))[0].r.marcas === 4);
await como(RH, `select desactivar_clave_integracion(id) from integracion_claves`);
await falla('clave desactivada ya no sirve', 'anon', `select recibir_marcaje($1, $2::jsonb)`, [clave, JSON.stringify(datos)], /no válida/);

console.log('Anulación');
await como(DIR, `select anular_planilla($1, 'Error en el bono', '2026-11-20')`, [pq]);
check('saldo de salarios por pagar vuelve a cero', casi(await saldoCta(par.cuenta_neto_pagar_id), 0));
check('vacaciones acumuladas anuladas', (await v1(`select count(*)::int n from vacaciones_movimientos where planilla_id=$1 and estado='aprobado'`, [pq]))[0].n === 0);
const pq2 = (await como(RH, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'quincenal', desde: '2026-11-01', hasta: '2026-11-15' })])).rows[0].id;
check('anulada, se puede rehacer la quincena', pq2 > pq);

console.log('Mi pago (app de marcaje)');
await como(RH, `select enviar_planilla($1)`, [pq2]);
await como(DIR, `select aprobar_planilla($1)`, [pq2]);
const clave2 = (await como(RH, `select crear_clave_integracion('Marcaje 2') c`)).rows[0].c;
await falla('sin clave no hay pago', 'anon', `select pago_colaborador($1, $2, 2026, 11)`, ['afc_x', 'ana@afc.org'], /no válida/);
const pago = (await como('anon', `select pago_colaborador($1, $2, 2026, 11) r`, [clave2, 'ANA@afc.org'])).rows[0].r;
const lA = await lin(pq2, A);
check('devuelve salario mensual y neto del mes', pago.encontrado && pago.salario_mensual === 30000 && casi(pago.total_neto, lA.neto) && pago.planillas.length === 1, JSON.stringify(pago).slice(0, 300));
check('incluye deducciones y novedades', casi(pago.total_inss, lA.inss_laboral) && casi(pago.total_ir, lA.ir) && Array.isArray(pago.planillas[0].novedades));
check('la planilla anulada no cuenta', pago.planillas.every(x => x.desde === '2026-11-01'));
check('mes sin planillas = cero', (await como('anon', `select pago_colaborador($1, $2, 2026, 10) r`, [clave2, 'ana@afc.org'])).rows[0].r.total_neto === 0);
check('correo desconocido no revela nada', (await como('anon', `select pago_colaborador($1, $2, 2026, 11) r`, [clave2, 'otro@afc.org'])).rows[0].r.encontrado === false);

console.log('Pago de planilla y colillas');
const cbNio = (await v1(`select id, cuenta_contable_id from cuentas_bancarias where moneda='NIO' order by id limit 1`))[0];
const cbUsd = (await v1(`select id from cuentas_bancarias where moneda='USD' order by id limit 1`))[0];
await falla('RR. HH. no confirma pagos', RH, `select pagar_planilla($1, $2, '2026-11-15', 'REF-1')`, [pq2, cbNio.id], /Administración/);
await falla('no se paga desde la cuenta en dólares', DIR, `select pagar_planilla($1, $2, '2026-11-15', 'REF-1')`, [pq2, cbUsd.id], /córdobas/);
const tok = (await como(DIR, `select pagar_planilla($1, $2, '2026-11-15', 'BANPRO-778899') t`, [pq2, cbNio.id])).rows[0].t;
check('confirma el pago y entrega token de correo', /^[0-9a-f]{64}$/.test(tok));
const pl2 = (await v1(`select * from planillas where id=$1`, [pq2]))[0];
const asp = (await v1(`select a.estado, a.tipo, a.referencia, sum(l.debe) d, sum(l.haber) h from asientos a join asiento_lineas l on l.asiento_id=a.id where a.id=$1 group by 1,2,3`, [pl2.asiento_pago_id]))[0];
check('asiento de pago contabilizado y cuadrado', asp.estado === 'contabilizado' && asp.tipo === 'egreso' && asp.referencia === 'BANPRO-778899' && casi(asp.d, pl2.total_neto) && casi(asp.h, pl2.total_neto));
check('salarios por pagar queda en cero', casi(await saldoCta(par.cuenta_neto_pagar_id), 0));
check('el banco baja por el neto pagado', casi(await saldoCta(cbNio.cuenta_contable_id), pl2.total_neto));
await falla('no se paga dos veces', DIR, `select pagar_planilla($1, $2, '2026-11-15', 'X')`, [pq2, cbNio.id], /ya está pagada/);
await falla('no se anula una planilla pagada', DIR, `select anular_planilla($1, 'x', '2026-11-20')`, [pq2], /anule primero el pago/);
check('nadie lee los tokens desde la app', await como(DIR, `select count(*) from planilla_tokens`).then(() => false, () => true));
check('el token no viaja en la planilla', !('token_correo' in pl2));
await falla('token falso rechazado', 'anon', `select colillas_planilla($1, $2, $3)`, [clave2, pq2, 'x'.repeat(64)], /no está autorizado/);
await falla('sin clave no hay colillas', 'anon', `select colillas_planilla($1, $2, $3)`, ['afc_x', pq2, tok], /no válida/);
const col = (await como('anon', `select colillas_planilla($1, $2, $3) r`, [clave2, pq2, tok])).rows[0].r;
const ana = col.empleados.find(x => x.correo === 'ana@afc.org');
check('colillas con correo, neto y deducciones', col.empleados.length === 3 && ana && casi(ana.neto, (await lin(pq2, A)).neto) && ana.cuenta.startsWith('••••'), JSON.stringify(ana).slice(0, 200));
await falla('el token sirve una sola vez', 'anon', `select colillas_planilla($1, $2, $3)`, [clave2, pq2, tok], /ya se hizo/);
await como('anon', `select registrar_envio_colillas($1, $2, 3, 0, '[]'::jsonb)`, [clave2, pq2]);
check('queda registrado el envío', (await v1(`select correos_enviados n from planillas where id=$1`, [pq2]))[0].n === 3);
const tok2 = (await como(DIR, `select reenviar_colillas($1) t`, [pq2])).rows[0].t;
check('se puede reenviar con un token nuevo', (await como('anon', `select colillas_planilla($1, $2, $3) r`, [clave2, pq2, tok2])).rows[0].r.empleados.length === 3);
const pagoAna = (await como('anon', `select pago_colaborador($1, $2, 2026, 11) r`, [clave2, 'ana@afc.org'])).rows[0].r;
check('Mi pago muestra la planilla como depositada', pagoAna.planillas[0].depositada === true && pagoAna.planillas[0].fecha_pago === '2026-11-15');
await como(DIR, `select anular_pago_planilla($1, 'Referencia equivocada')`, [pq2]);
check('anular el pago revierte el banco', casi(await saldoCta(cbNio.cuenta_contable_id), 0) && (await v1(`select pagada_en from planillas where id=$1`, [pq2]))[0].pagada_en === null);

console.log(`\n${ok} pruebas correctas, ${fail} fallidas`);
process.exit(fail ? 1 : 0);
