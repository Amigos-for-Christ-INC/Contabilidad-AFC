import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';

const db = new PGlite();
const schema = fs.readFileSync('./schema.sql', 'utf8');

// Stubs mínimos de lo que Supabase ya trae (auth y roles)
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
await db.exec(schema);

const U1 = '11111111-1111-1111-1111-111111111111';
const U2 = '22222222-2222-2222-2222-222222222222';
await db.exec(`insert into auth.users (id, email) values ('${U1}','moises@amigosforchrist.org'), ('${U2}','ana@amigosforchrist.org')`);

let ok = 0, fail = 0;
const check = (name, cond, extra = '') => { if (cond) { ok++; console.log('  ✓', name); } else { fail++; console.log('  ✗', name, extra); } };

async function como(uid, sql, params = []) {
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '${uid}', false); set role authenticated;`);
  try { return await db.query(sql, params); }
  finally { await db.exec('reset role;'); }
}
async function debeFallar(name, uid, sql, params, pattern) {
  try { await como(uid, sql, params); check(name, false, '(no falló)'); }
  catch (e) { check(name, pattern.test(e.message), `→ ${e.message}`); }
}
const id = async (cod) => (await db.query('select id from cuentas where codigo=$1', [cod])).rows[0].id;

console.log('Usuarios y roles');
const roles = (await db.query('select correo, rol from perfiles order by correo')).rows;
check('primer usuario es admin', roles.find(r => r.correo.startsWith('moises')).rol === 'admin');
check('segundo usuario es consulta', roles.find(r => r.correo.startsWith('ana')).rol === 'consulta');

const caja = await id('1.1.01'), bancoUSD = await id('1.1.03'), don = await id('4.1'),
      sueldos = await id('6.1.02'), serv = await id('6.1.03'), activo = await id('1'),
      resAcum = await id('3.2'), patr = await id('3.1');

console.log('Asientos');
const a1 = (await como(U1, `select guardar_asiento($1::jsonb, true) id`, [JSON.stringify({
  fecha: '2026-10-05', concepto: 'Aporte inicial', lineas: [
    { cuenta_id: caja, debe: 50000 }, { cuenta_id: patr, haber: 50000 }, {} ]})])).rows[0].id;
let r = (await db.query('select numero, estado from asientos where id=$1', [a1])).rows[0];
check('asiento cuadrado se contabiliza con número 1', r.numero === 1 && r.estado === 'contabilizado');

await debeFallar('asiento descuadrado no se contabiliza', U1, `select guardar_asiento($1::jsonb, true)`,
  [JSON.stringify({ fecha: '2026-10-06', concepto: 'Malo', lineas: [{ cuenta_id: caja, debe: 100 }, { cuenta_id: don, haber: 90 }]})],
  /no cuadra/);
check('el descuadrado no dejó rastro (transacción completa)',
  (await db.query(`select count(*)::int n from asientos where concepto='Malo'`)).rows[0].n === 0);

await debeFallar('no se puede usar una cuenta de agrupación', U1, `select guardar_asiento($1::jsonb, true)`,
  [JSON.stringify({ fecha: '2026-10-06', concepto: 'Agrupadora', lineas: [{ cuenta_id: activo, debe: 10 }, { cuenta_id: don, haber: 10 }]})],
  /agrupación/);
await debeFallar('debe y haber en la misma línea se rechaza', U1, `select guardar_asiento($1::jsonb)`,
  [JSON.stringify({ fecha: '2026-10-06', concepto: 'X', lineas: [{ cuenta_id: caja, debe: 10, haber: 10 }]})],
  /no en ambos/);

const borr = (await como(U1, `select guardar_asiento($1::jsonb) id`, [JSON.stringify({
  fecha: '2026-10-10', concepto: 'Donación', lineas: [{ cuenta_id: caja, debe: 8000 }, { cuenta_id: don, haber: 8000 }]})])).rows[0].id;
check('se guarda en borrador', (await db.query('select estado from asientos where id=$1', [borr])).rows[0].estado === 'borrador');
await como(U1, `select guardar_asiento($1::jsonb, true)`, [JSON.stringify({
  id: borr, fecha: '2026-10-10', concepto: 'Donación', lineas: [{ cuenta_id: caja, debe: 9000 }, { cuenta_id: don, haber: 9000 }]})]);
r = (await db.query('select numero, (select sum(debe) from asiento_lineas where asiento_id=$1) d from asientos where id=$1', [borr])).rows[0];
check('editar borrador y contabilizar → número 2, monto actualizado', r.numero === 2 && Number(r.d) === 9000);

await como(U1, `select guardar_asiento($1::jsonb, true)`, [JSON.stringify({
  fecha: '2026-10-20', concepto: 'Pago de servicios', lineas: [{ cuenta_id: serv, debe: 1500 }, { cuenta_id: caja, haber: 1500 }]})]);

console.log('Dólares');
await db.exec(`insert into tipos_cambio values ('2026-10-15', 36.6243)`);
const usd = (await como(U1, `select guardar_asiento($1::jsonb, true) id`, [JSON.stringify({
  fecha: '2026-10-15', concepto: 'Donación en US$', moneda: 'USD', lineas: [
    { cuenta_id: bancoUSD, debe: 100 },
    { cuenta_id: don, haber: 33.33 }, { cuenta_id: don, haber: 33.33 }, { cuenta_id: don, haber: 33.34 }]})])).rows[0].id;
r = (await db.query('select sum(debe) d, sum(haber) h, sum(debe_me) dme from asiento_lineas where asiento_id=$1', [usd])).rows[0];
check('US$ 100 a 36.6243 → C$ 3,662.43 y cuadra tras el redondeo', Number(r.d) === 3662.43 && Number(r.h) === 3662.43 && Number(r.dme) === 100, JSON.stringify(r));
await debeFallar('US$ sin tipo de cambio del día se rechaza', U1, `select guardar_asiento($1::jsonb)`,
  [JSON.stringify({ fecha: '2026-10-16', concepto: 'Sin TC', moneda: 'USD', lineas: [{ cuenta_id: bancoUSD, debe: 1 }, { cuenta_id: don, haber: 1 }]})],
  /tipo de cambio/);

console.log('Permisos');
await debeFallar('usuario de consulta no registra asientos', U2, `select guardar_asiento($1::jsonb)`,
  [JSON.stringify({ fecha: '2026-10-06', concepto: 'X', lineas: [] })], /permiso/);
await debeFallar('consulta no edita el catálogo', U2, `insert into cuentas (codigo,nombre,tipo,naturaleza) values ('4.9','X','ingreso','acreedora')`, [], /row-level security|permission/);
await debeFallar('ni el admin escribe asientos directo en la tabla', U1, `update asientos set concepto='hack' where id=${a1}`, [], /row-level security|permission|contabilizado/);
check('consulta sí puede leer', (await como(U2, 'select count(*)::int n from asientos')).rows[0].n === 4);
check('sesión sin perfil no ve asientos', (await como('', 'select count(*)::int n from asientos')).rows[0].n === 0);
try { await db.exec("set role anon"); await db.query('select count(*) from asientos'); check('anónimo no lee nada', false); }
catch (e) { check('anónimo no lee nada', /permission denied/.test(e.message), e.message); } finally { await db.exec('reset role'); }

console.log('Reportes');
const bal = (await como(U1, `select * from balanza('2026-10-01','2026-10-31')`)).rows;
const g = c => bal.find(x => x.codigo === c);
const hojas = bal.filter(x => x.acepta_movimientos);
const td = hojas.reduce((s, x) => s + Number(x.debe), 0), th = hojas.reduce((s, x) => s + Number(x.haber), 0);
check('balanza: total debe = total haber', Math.abs(td - th) < 0.005, `${td} vs ${th}`);
check('caja = 50,000 + 9,000 − 1,500 = 57,500', Number(g('1.1.01').saldo_final) === 57500);
check('activo agrupa: 57,500 + 3,662.43', Number(g('1').saldo_final) === 61162.43);
check('ingresos 4 = 9,000 + 3,662.43', Number(g('4').saldo_final) === 12662.43);
const res = Number(g('4').saldo_final) - Number(g('6').saldo_final) - Number(g('5').saldo_final);
check('ecuación: activo = pasivo + patrimonio + resultado',
  Math.abs(Number(g('1').saldo_final) - (Number(g('2').saldo_final) + Number(g('3').saldo_final) + res)) < 0.005);

const mayor = (await como(U1, `select * from libro_mayor($1,'2026-10-06','2026-10-31')`, [caja])).rows;
check('mayor: saldo inicial 50,000', Number(mayor[0].saldo) === 50000 && mayor[0].concepto === 'Saldo inicial');
check('mayor: saldo final 57,500', Number(mayor.at(-1).saldo) === 57500);

console.log('Anulación y períodos');
await como(U1, `select anular_asiento($1,'Error de digitación')`, [borr]);
check('asiento anulado sale de la balanza',
  Number((await como(U1, `select saldo_final from balanza('2026-10-01','2026-10-31') where codigo='1.1.01'`)).rows[0].saldo_final) === 48500);
await debeFallar('lo anulado no se puede volver a tocar', U1, `select anular_asiento($1,'otra vez')`, [borr], /Solo se anulan/);

await debeFallar('contador/consulta no cierra períodos', U2, `select cerrar_periodo(2026,10)`, [], /administrador/);
await como(U1, `select guardar_asiento($1::jsonb)`, [JSON.stringify({ fecha: '2026-10-28', concepto: 'Pendiente', lineas: [] })]);
await debeFallar('no se cierra con borradores', U1, `select cerrar_periodo(2026,10)`, [], /borrador/);
await como(U1, `select eliminar_borrador(id) from asientos where concepto='Pendiente'`);
await como(U1, `select cerrar_periodo(2026,10)`);
await debeFallar('período cerrado no acepta asientos', U1, `select guardar_asiento($1::jsonb)`,
  [JSON.stringify({ fecha: '2026-10-30', concepto: 'Tarde', lineas: [] })], /cerrado/);
await debeFallar('período cerrado no permite anular', U1, `select anular_asiento($1,'x')`, [a1], /cerrado/);
await como(U1, `select abrir_periodo(2026,10)`);
check('admin reabre el período', (await db.query(`select estado from periodos where anio=2026 and mes=10`)).rows[0].estado === 'abierto');

console.log('Catálogo');
await como(U1, `insert into cuentas (codigo,nombre,tipo,naturaleza) values ('6.1.03.01','Energía','gasto','deudora')`).catch(e => check('subcuenta de cuenta con movimientos se rechaza', /movimientos/.test(e.message), e.message));
await como(U1, `insert into cuentas (codigo,nombre,tipo,naturaleza) values ('6.1.06','Viáticos','gasto','deudora')`);
check('subcuenta nueva toma su padre', (await db.query(`select p.codigo from cuentas c join cuentas p on p.id=c.padre_id where c.codigo='6.1.06'`)).rows[0].codigo === '6.1');
await debeFallar('tipo distinto al del padre se rechaza', U1, `insert into cuentas (codigo,nombre,tipo,naturaleza) values ('6.1.07','X','ingreso','acreedora')`, [], /mismo tipo/);
await debeFallar('padre inexistente se rechaza', U1, `insert into cuentas (codigo,nombre,tipo,naturaleza) values ('7.1','X','gasto','deudora')`, [], /cuenta padre 7/);

console.log('Cierre anual');
await db.exec(`insert into tipos_cambio values ('2026-12-31', 36.7)`);
const cierre = (await como(U1, `select generar_asiento_cierre(2026,$1) id`, [resAcum])).rows[0].id;
await como(U1, `select contabilizar_asiento($1)`, [cierre]);
const balA = (await como(U1, `select * from balanza('2026-01-01','2026-12-31')`)).rows;
const ga = c => Number(balA.find(x => x.codigo === c).saldo_final);
check('después del cierre, ingresos y gastos quedan en cero', ga('4') === 0 && ga('6') === 0 && ga('5') === 0);
check('la utilidad (3,662.43 − 1,500 = 2,162.43) pasa a resultados acumulados', ga('3.2') === 2162.43, ga('3.2'));
check('activo = pasivo + patrimonio', Math.abs(ga('1') - ga('2') - ga('3')) < 0.005);

console.log('Bitácora');
check('la bitácora registró cambios', (await db.query('select count(*)::int n from bitacora')).rows[0].n > 5);
check('consulta no ve la bitácora', (await como(U2, 'select count(*)::int n from bitacora')).rows[0].n === 0);

console.log(`\n${ok} pruebas correctas, ${fail} fallidas`);
process.exit(fail ? 1 : 0);
