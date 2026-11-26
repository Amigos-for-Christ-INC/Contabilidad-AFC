// Pruebas de la migración 008: plan de ahorro.
// Uso: node prueba-008.mjs  (desde la carpeta con los .sql)
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
for (const f of ['schema.sql', '002-roles-inventario.sql', '003-bancos-cheques.sql', '004-planilla-marcaje.sql', '005-pago-marcaje.sql', '006-pago-planilla.sql', '007-aguinaldo-liquidacion-activos.sql', '008-plan-ahorro.sql']) await db.exec(fs.readFileSync('./' + f, 'utf8'));

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
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Administrador'), ADM]);
const par = (await v1(`select * from planilla_parametros`))[0];
const centro = (await v1(`select id from centros_costo where codigo='ADM'`))[0].id;
const emp = async e => (await como(RH, `insert into empleados (nombre, correo, cargo, centro_costo_id, fecha_ingreso, tipo_pago, salario_mensual, cuenta_banco, ahorro_porcentaje, ahorro_inicio)
  values ($1,$2,'Cargo',$3,$4,$5,$6,'10010011112222',$7,$8) returning id`, [e.nombre, e.correo, centro, e.ingreso, e.tipo, e.salario, e.pct, e.inicio])).rows[0].id;
const A = await emp({ nombre: 'Ana Pérez', correo: 'ana@afc.org', ingreso: '2020-01-06', tipo: 'quincenal', salario: 30000, pct: 10, inicio: '2026-01-01' });
const B = await emp({ nombre: 'Bruno Díaz', correo: 'bruno@afc.org', ingreso: '2019-03-01', tipo: 'quincenal', salario: 12000, pct: 2, inicio: '2020-06-01' });
const C = await emp({ nombre: 'Carla Ruiz', correo: 'carla@afc.org', ingreso: '2018-05-02', tipo: 'mensual', salario: 60000, pct: 0, inicio: null });
const D = await emp({ nombre: 'Diego Mora', correo: 'diego@afc.org', ingreso: '2026-11-21', tipo: 'quincenal', salario: 15000, pct: 20, inicio: '2026-11-21' });
const lin = async (pl, e) => (await v1(`select * from planilla_lineas where planilla_id=$1 and empleado_id=$2`, [pl, e]))[0];
const conc = async c => (await v1(`select id from conceptos_planilla where codigo=$1`, [c]))[0].id;
const saldoAho = async e => Number((await v1(`select coalesce(sum(monto),0) s from ahorro_movimientos where empleado_id=$1 and estado='aplicado'`, [e]))[0].s);

console.log('Migración');
check('AFC aporta 5% y retiro cada 5 años', par.ahorro_afc_pct === 5 && par.ahorro_anios_retiro === 5);
check('cuentas: pasivo del plan y gasto del aporte', /^2\.1\./.test((await v1(`select codigo from cuentas where id=$1`, [par.cuenta_ahorro_pagar_id]))[0].codigo) && /^6\.1\./.test((await v1(`select codigo from cuentas where id=$1`, [par.cuenta_aporte_ahorro_id]))[0].codigo));
await falla('no se ahorra más del 50%', RH, `update empleados set ahorro_porcentaje = 60 where id = $1`, [A], /check|viola/);

console.log('Planilla quincenal');
const pq = (await como(RH, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'quincenal', desde: '2026-11-16', hasta: '2026-11-30' })])).rows[0].id;
let a = await lin(pq, A);
check('Ana 10%: ahorra 1,500; AFC 750', a.ahorro === 1500 && a.ahorro_afc === 750, JSON.stringify(a));
check('el ahorro baja el neto pero no el INSS ni el IR', a.inss_laboral === 1050 && casi(a.neto, 15000 - 1050 - a.ir - 1500));
const b = await lin(pq, B);
check('Bruno 2%: ahorra 120; AFC siempre 5% = 300', b.ahorro === 120 && b.ahorro_afc === 300, JSON.stringify(b));
const d = await lin(pq, D);
check('Diego entró el 21 (10 días), 20%: ahorra 1,000; AFC 250', d.ahorro === 1000 && d.ahorro_afc === 250, JSON.stringify(d));
await como(RH, `select actualizar_linea_planilla($1, 2)`, [a.id]);
a = await lin(pq, A);
check('días sin goce no cambian el ahorro (salario de la ficha)', a.ahorro === 1500 && a.salario_periodo === 13000);
const pl = (await v1(`select * from planillas where id=$1`, [pq]))[0];
const E = await emp({ nombre: 'Eva Soto', correo: 'eva@afc.org', ingreso: '2024-01-01', tipo: 'quincenal', salario: 9000, pct: 10, inicio: '2026-11-26' });
await como(RH, `select agregar_empleado_planilla($1, $2)`, [pq, E]);
check('Eva entró al plan el 26: solo 5 días (150 + AFC 75)', (await lin(pq, E)).ahorro === 150 && (await lin(pq, E)).ahorro_afc === 75, JSON.stringify(await lin(pq, E)));
await como(RH, `select quitar_empleado_planilla($1)`, [(await lin(pq, E)).id]);
check('totales del ahorro en la planilla', pl.total_ahorro === 2620 && pl.total_ahorro_afc === 1300, JSON.stringify([pl.total_ahorro, pl.total_ahorro_afc]));
const pm = (await como(RH, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'mensual', desde: '2026-11-01', hasta: '2026-11-30' })])).rows[0].id;
check('Carla no participa: sin ahorro ni aporte', (await lin(pm, C)).ahorro === 0 && (await lin(pm, C)).ahorro_afc === 0);
await como(RH, `select enviar_planilla($1)`, [pq]);
const asq = (await como(DIR, `select aprobar_planilla($1) id`, [pq])).rows[0].id;
const t = (await v1(`select sum(debe) d, sum(haber) h from asiento_lineas where asiento_id=$1`, [asq]))[0];
check('asiento cuadra con el ahorro', casi(t.d, t.h), JSON.stringify(t));
check('pasivo del plan = 2,620 + 1,300', casi(await saldoCta(par.cuenta_ahorro_pagar_id), 3920));
check('gasto del aporte de AFC = 1,300', casi(-await saldoCta(par.cuenta_aporte_ahorro_id), 1300));
check('salarios por pagar = neto', casi(await saldoCta(par.cuenta_neto_pagar_id), pl.total_neto));
check('Ana: saldo 2,250 (1,500 + 750)', casi(await saldoAho(A), 2250));

console.log('Aguinaldo');
const pa = (await como(RH, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'aguinaldo', hasta: '2026-11-30' })])).rows[0].id;
check('el aguinaldo no lleva ahorro', (await v1(`select total_ahorro, total_ahorro_afc from planillas where id=$1`, [pa]))[0].total_ahorro === 0);

console.log('Resumen y retiro');
await como(RH, `select saldo_inicial_ahorro($1, '2026-10-31', 50000, 30000, 'Traído de AG Planilla')`, [B]);
await falla('un solo saldo inicial', RH, `select saldo_inicial_ahorro($1, '2026-10-31', 1, 1)`, [B], /ya tiene saldo/);
const res = Object.fromEntries((await como(RH, `select * from resumen_ahorro()`)).rows.map(r => [r.empleado_id, r]));
check('Ana: próximo retiro 01/01/2031', res[A].proximo_retiro === '2031-01-01', res[A].proximo_retiro);
check('Ana: ahorro mensual 3,000 y aporte AFC 1,500', res[A].ahorro_mensual === 3000 && res[A].aporte_afc_mensual === 1500);
check('Bruno: saldo 80,420 (50,120 suyo + 30,300 AFC)', casi(res[B].saldo, 80420) && casi(res[B].saldo_colaborador, 50120) && casi(res[B].saldo_afc, 30300), JSON.stringify(res[B]));
check('Carla no aparece (no participa)', !res[C]);
const cta = (await v1(`select id from cuentas where codigo='1.1.02'`))[0].id;
const cb = (await como(ADM, `insert into cuentas_bancarias (nombre, numero_cuenta, cuenta_contable_id) values ('BANPRO córdobas', '1001', $1) returning id`, [cta])).rows[0].id;
await falla('Ana no retira antes de 5 años', DIR, `select retirar_ahorro($1, '2026-11-30', $2, 'T-1')`, [A, cb], /a partir del 01\/01\/2031/);
await falla('RR. HH. no registra retiros', RH, `select retirar_ahorro($1, '2026-11-30', $2, 'T-1')`, [B, cb], /aprueba/);
const ret = (await como(DIR, `select retirar_ahorro($1, '2026-11-30', $2, 'TRF-889') id`, [B, cb])).rows[0].id;
const mr = (await v1(`select * from ahorro_movimientos where id=$1`, [ret]))[0];
const tr = (await v1(`select sum(debe) d, sum(haber) h from asiento_lineas where asiento_id=$1`, [mr.asiento_id]))[0];
check('retiro de Bruno: 80,420 contra el banco', mr.monto === -80420 && casi(tr.d, 80420) && casi(tr.h, 80420));
check('Bruno queda en cero y vuelve a contar 5 años', casi(await saldoAho(B), 0) && (await como(RH, `select proximo_retiro from resumen_ahorro() where empleado_id=$1`, [B])).rows[0].proximo_retiro === '2031-11-30');
await como(DIR, `select anular_movimiento_ahorro($1, 'Transferencia rechazada')`, [ret]);
check('al anular el retiro vuelve el saldo', casi(await saldoAho(B), 80420));
const mov = (await v1(`select id from ahorro_movimientos where planilla_id=$1 limit 1`, [pq]))[0].id;
await falla('un aporte de planilla no se anula suelto', DIR, `select anular_movimiento_ahorro($1, 'x')`, [mov], /anule la planilla/);
check('Bodeguero no ve el ahorro', (await como(BOD, `select count(*)::int n from ahorro_movimientos`)).rows[0].n === 0);

console.log('Liquidación');
const sim = (await como(RH, `select simular_liquidacion($1, '2026-12-05', '2026-11-30', 'renuncia') s`, [A])).rows[0].s;
check('la simulación devuelve el ahorro (2,250)', sim.ahorro === 2250 && casi(sim.neto - sim.ahorro, sim.salario + sim.vacaciones + sim.aguinaldo + sim.indemnizacion - sim.inss - sim.ir));
const pliq = (await como(RH, `select crear_liquidacion($1::jsonb) id`, [JSON.stringify({ empleado_id: A, fecha_salida: '2026-12-05', ultimo_dia_pagado: '2026-11-30', motivo: 'renuncia' })])).rows[0].id;
const la = await lin(pliq, A);
check('liquidación: devuelve 2,250 sin INSS ni IR y sin descontar más ahorro', la.ahorro === 0 && casi(la.neto, sim.neto), JSON.stringify([la.neto, sim.neto]));
await como(RH, `select enviar_planilla($1)`, [pliq]);
await como(DIR, `select aprobar_planilla($1)`, [pliq]);
check('Ana queda con ahorro en cero', casi(await saldoAho(A), 0));
check('pasivo del plan baja en 2,250', casi(await saldoCta(par.cuenta_ahorro_pagar_id), 3920 - 2250), await saldoCta(par.cuenta_ahorro_pagar_id));
await como(DIR, `select anular_planilla($1, 'Se quedó')`, [pliq]);
check('al anular la liquidación vuelve su ahorro', casi(await saldoAho(A), 2250));
await como(DIR, `select anular_planilla($1, 'Error')`, [pq]);
check('al anular la quincena se anulan los aportes', casi(await saldoAho(A), 0) && casi(await saldoCta(par.cuenta_ahorro_pagar_id), 0));

console.log(`\n${ok} pruebas correctas, ${fail} fallidas`);
process.exit(fail ? 1 : 0);
