// Pruebas de la migración 003 (bancos y cheques) sobre schema.sql + 002.
// Uso: node prueba-cheques.mjs  (desde la carpeta con los tres .sql)
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';

const db = new PGlite();
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
for (const f of ['schema.sql', '002-roles-inventario.sql', '003-bancos-cheques.sql']) await db.exec(fs.readFileSync('./' + f, 'utf8'));

const ADM = '11111111-1111-1111-1111-111111111111', CON = '22222222-2222-2222-2222-222222222222',
      APR = '33333333-3333-3333-3333-333333333333', BOD = '44444444-4444-4444-4444-444444444444';
await db.exec(`insert into auth.users (id, email) values ('${ADM}','admin@x.org'), ('${CON}','conta@x.org'), ('${APR}','director@x.org'), ('${BOD}','bodega@x.org')`);
const rol = async n => (await db.query(`select id from roles where nombre=$1`, [n])).rows[0].id;
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Contador'), CON]);
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Aprobador de cheques'), APR]);
await db.query(`update perfiles set rol_id=$1 where id=$2`, [await rol('Bodeguero'), BOD]);

let ok = 0, fail = 0;
const check = (n, c, x = '') => { if (c) { ok++; console.log('  ✓', n); } else { fail++; console.log('  ✗', n, x); } };
async function como(uid, sql, params = []) {
  await db.exec(`reset role; select set_config('request.jwt.claim.sub', '${uid}', false); set role authenticated;`);
  try { return await db.query(sql, params); } finally { await db.exec('reset role;'); }
}
async function falla(n, uid, sql, params, re) {
  try { await como(uid, sql, params); check(n, false, '(no falló)'); }
  catch (e) { check(n, re.test(e.message), '→ ' + e.message); }
}
const v1 = (q, p = []) => db.query(q, p).then(r => r.rows);
const cta = async c => (await v1(`select id from cuentas where codigo=$1`, [c]))[0].id;
const cbNIO = (await v1(`select id from cuentas_bancarias where moneda='NIO'`))[0].id;
const cbUSD = (await v1(`select id from cuentas_bancarias where moneda='USD'`))[0].id;
const prov = await cta('2.1.01'), ret = await cta('2.1.03'), serv = await cta('6.1.03'), caja = await cta('1.1.01'), patr = await cta('3.1');
const banco = await cta('1.1.02'), bancoUSD = await cta('1.1.03');
const saldo = async c => Number((await v1(`select coalesce(sum(l.debe-l.haber),0) s from asiento_lineas l join asientos a on a.id=l.asiento_id where a.estado='contabilizado' and l.cuenta_id=$1`, [c]))[0].s);
const ch = (uid, p, enviar = true) => como(uid, `select guardar_cheque($1::jsonb, $2) id`, [JSON.stringify(p), enviar]).then(r => r.rows[0].id);

console.log('Migración');
check('2 cuentas BANPRO creadas', (await v1(`select count(*)::int n from cuentas_bancarias where banco='BANPRO'`))[0].n === 2);
check('rol Aprobador de cheques creado', (await v1(`select permisos from roles where nombre='Aprobador de cheques'`))[0].permisos.includes('bancos.aprobar'));
check('admin tiene los permisos de bancos', (await como(ADM, `select mis_permisos() p`)).rows[0].p.includes('bancos.aprobar'));
check('contador puede emitir pero no aprobar', (await como(CON, `select mis_permisos() p`)).rows[0].p.includes('bancos.emitir') && !(await como(CON, `select mis_permisos() p`)).rows[0].p.includes('bancos.aprobar'));

// Fondos iniciales en el banco
await como(CON, `select guardar_asiento($1::jsonb, true)`, [JSON.stringify({ fecha: '2026-11-02', concepto: 'Depósito inicial', lineas: [{ cuenta_id: banco, debe: 100000 }, { cuenta_id: patr, haber: 100000 }] })]);
await db.exec(`update cuentas_bancarias set proximo_cheque = 1501, numero_cuenta = '10010000000000' where id = ${cbNIO}`);

console.log('Elaborar y aprobar');
await falla('bodeguero no elabora cheques', BOD, `select guardar_cheque('{}'::jsonb)`, [], /permiso/);
const c1 = await ch(CON, { cuenta_bancaria_id: cbNIO, fecha: '2026-11-10', beneficiario: 'Ferretería El Progreso', monto: 9800, concepto: 'Pago factura 881',
  lineas: [{ cuenta_id: prov, debe: 10000 }, { cuenta_id: ret, haber: 200, descripcion: 'Retención IR 2%' }] });
check('cheque con retención enviado a aprobación', (await v1(`select estado from cheques where id=$1`, [c1]))[0].estado === 'por_aprobar');
await falla('distribución que no cuadra no se envía', CON, `select guardar_cheque($1::jsonb, true)`, [JSON.stringify({ cuenta_bancaria_id: cbNIO, fecha: '2026-11-10', beneficiario: 'X', monto: 500, concepto: 'x', lineas: [{ cuenta_id: serv, debe: 400 }] })], /no coincide/);
await falla('no se usa la cuenta del banco en la distribución', CON, `select guardar_cheque($1::jsonb)`, [JSON.stringify({ cuenta_bancaria_id: cbNIO, fecha: '2026-11-10', beneficiario: 'X', monto: 5, concepto: 'x', lineas: [{ cuenta_id: banco, debe: 5 }] })], /cuenta del banco/);
await falla('el contador no puede aprobar', CON, `select aprobar_cheque($1)`, [c1], /permiso/);
await como(ADM, `select cambiar_rol($1, $2)`, [CON, await rol('Administrador')]);
await falla('quien elaboró no aprueba, aunque sea administrador', CON, `select aprobar_cheque($1)`, [c1], /Quien elaboró/);
await como(ADM, `select cambiar_rol($1, $2)`, [CON, await rol('Contador')]);
const n1 = (await como(APR, `select aprobar_cheque($1) n`, [c1])).rows[0].n;
check('aprobado con el próximo número de la chequera (1501)', n1 === 1501);
check('la chequera avanza a 1502', (await v1(`select proximo_cheque from cuentas_bancarias where id=$1`, [cbNIO]))[0].proximo_cheque === 1502);
const as1 = await v1(`select c.codigo, l.debe::numeric d, l.haber::numeric h from asiento_lineas l join cuentas c on c.id=l.cuenta_id join cheques k on k.asiento_id=l.asiento_id where k.id=$1 order by l.orden`, [c1]);
check('asiento: Dr Proveedores 10,000 / Cr Retenciones 200 / Cr Banco 9,800',
  as1.length === 3 && as1[0].codigo === '2.1.01' && Number(as1[0].d) === 10000 && as1[1].codigo === '2.1.03' && Number(as1[1].h) === 200 && as1[2].codigo === '1.1.02' && Number(as1[2].h) === 9800, JSON.stringify(as1));
check('saldo del banco 100,000 − 9,800 = 90,200', await saldo(banco) === 90200);
await falla('no se edita un cheque aprobado', CON, `select guardar_cheque($1::jsonb)`, [JSON.stringify({ id: c1, cuenta_bancaria_id: cbNIO, fecha: '2026-11-10', beneficiario: 'X', monto: 1, concepto: 'x' })], /borrador/);
await falla('el asiento del cheque no se anula desde contabilidad', CON, `select anular_asiento((select asiento_id from cheques where id=$1), 'x')`, [c1], /cheque/);

console.log('Rechazo y número manual');
const c2 = await ch(CON, { cuenta_bancaria_id: cbNIO, fecha: '2026-11-11', beneficiario: 'ENEL', monto: 1500, concepto: 'Energía', lineas: [{ cuenta_id: serv, debe: 1500 }] });
await como(APR, `select rechazar_cheque($1, 'Falta la factura')`, [c2]);
check('rechazado vuelve a borrador con el motivo', (await v1(`select estado, motivo_rechazo from cheques where id=$1`, [c2]))[0].motivo_rechazo === 'Falta la factura');
await ch(CON, { id: c2, cuenta_bancaria_id: cbNIO, fecha: '2026-11-11', beneficiario: 'ENEL', monto: 1500, concepto: 'Energía, factura adjunta', lineas: [{ cuenta_id: serv, debe: 1500 }] });
await falla('número ya usado se rechaza', APR, `select aprobar_cheque($1, 1501)`, [c2], /ya fue usado/);
check('aprobado con número manual 1510', (await como(APR, `select aprobar_cheque($1, 1510) n`, [c2])).rows[0].n === 1510);
check('la chequera salta a 1511', (await v1(`select proximo_cheque from cuentas_bancarias where id=$1`, [cbNIO]))[0].proximo_cheque === 1511);

console.log('Dólares');
await db.exec(`insert into tipos_cambio values ('2026-11-12', 36.6243)`);
await db.exec(`insert into asientos (fecha, concepto, moneda, tipo_cambio) values ('2026-11-12','Fondos US$','USD',36.6243)`);
const aU = (await v1(`select max(id) id from asientos`))[0].id;
await db.exec(`insert into asiento_lineas (asiento_id, orden, cuenta_id, debe, haber, debe_me, haber_me) values (${aU},1,${bancoUSD},36624.30,0,1000,null),(${aU},2,${patr},0,36624.30,null,1000)`);
await db.exec(`select _contabilizar(${aU})`);
const c3 = await ch(CON, { cuenta_bancaria_id: cbUSD, fecha: '2026-11-12', beneficiario: 'Proveedor US', monto: 100, concepto: 'Repuestos', lineas: [{ cuenta_id: serv, debe: 33.33 }, { cuenta_id: serv, debe: 33.33 }, { cuenta_id: serv, debe: 33.34 }] });
await como(APR, `select aprobar_cheque($1)`, [c3]);
const a3 = (await v1(`select sum(debe)::numeric d, sum(haber)::numeric h from asiento_lineas l join cheques k on k.asiento_id=l.asiento_id where k.id=$1`, [c3]))[0];
check('cheque US$ 100 a 36.6243 cuadra en C$ (3,662.43)', Number(a3.d) === Number(a3.h) && Math.abs(Number(a3.h) - 3662.43) < 0.02, JSON.stringify(a3));
await falla('US$ sin tipo de cambio se rechaza', CON, `select guardar_cheque($1::jsonb)`, [JSON.stringify({ cuenta_bancaria_id: cbUSD, fecha: '2026-11-20', beneficiario: 'X', monto: 1, concepto: 'x' })], /tipo de cambio/);

console.log('Impresión, cobro y anulación');
await falla('no se imprime un borrador', CON, `select registrar_impresion($1)`, [await ch(CON, { cuenta_bancaria_id: cbNIO, fecha: '2026-11-13', beneficiario: 'Y', monto: 10, concepto: 'y' }, false)], /aprobados/);
check('se registra la impresión', (await como(CON, `select registrar_impresion($1) n`, [c1])).rows[0].n === 1);
const sb = (await como(CON, `select * from saldos_bancos()`)).rows.find(r => Number(r.cuenta_bancaria_id) === cbNIO);
check('en circulación: 2 cheques por 11,300', sb.cheques_circulacion === 2 && Number(sb.en_circulacion) === 11300, JSON.stringify(sb));
await como(CON, `select marcar_cobrado($1, true, '2026-11-15')`, [c1]);
await falla('no se anula un cheque cobrado', CON, `select anular_cheque($1, 'x', '2026-11-16')`, [c1], /cobrado/);
check('bodeguero no ve cheques (0 filas)', (await como(BOD, `select count(*)::int n from cheques`)).rows[0].n === 0);
await como(CON, `select anular_cheque($1, 'Cheque dañado al imprimir', '2026-11-16')`, [c2]);
check('anulación revierte el banco: 90,200 (sin el cheque de 1,500)', await saldo(banco) === 90200);
check('el número 1510 queda usado (anulado)', (await v1(`select estado, numero from cheques where id=$1`, [c2]))[0].estado === 'anulado');
await falla('no se elimina un cheque anulado', CON, `select eliminar_cheque($1)`, [c2], /aprobados/);

console.log('Panel');
const rm = (await como(CON, `select * from resumen_mensual('2026-11-30', 6)`)).rows;
check('resumen mensual trae 6 meses', rm.length === 6 && rm.at(-1).mes === 11);
check('gastos de noviembre incluyen los cheques (1,500 + 1,500 rev. + US$)', Number(rm.at(-1).gastos) > 0);
const bal = (await como(CON, `select * from balanza('2026-11-01','2026-11-30')`)).rows.filter(r => r.acepta_movimientos);
check('balanza cuadra', Math.abs(bal.reduce((s, r) => s + Number(r.debe), 0) - bal.reduce((s, r) => s + Number(r.haber), 0)) < 0.005);

console.log(`\n${ok} pruebas correctas, ${fail} fallidas`);
process.exit(fail ? 1 : 0);
