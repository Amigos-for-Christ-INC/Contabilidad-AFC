// Pruebas de la migración 007: aguinaldo, liquidaciones y activos fijos.
// Uso: node prueba-007.mjs  (desde la carpeta con los .sql)
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
for (const f of ['schema.sql', '002-roles-inventario.sql', '003-bancos-cheques.sql', '004-planilla-marcaje.sql', '005-pago-marcaje.sql', '006-pago-planilla.sql', '007-aguinaldo-liquidacion-activos.sql']) await db.exec(fs.readFileSync('./' + f, 'utf8'));

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
const par = (await v1(`select * from planilla_parametros`))[0];
const centro = (await v1(`select id from centros_costo where codigo='ADM'`))[0].id;
const emp = async e => (await como(RH, `insert into empleados (nombre, correo, cargo, centro_costo_id, fecha_ingreso, tipo_pago, salario_mensual, cuenta_banco)
  values ($1,$2,$3,$4,$5,$6,$7,'10010011112222') returning id`, [e.nombre, e.correo, e.cargo, centro, e.ingreso, e.tipo, e.salario])).rows[0].id;
const A = await emp({ nombre: 'Ana Pérez', correo: 'ana@afc.org', cargo: 'Coordinadora', ingreso: '2020-01-06', tipo: 'quincenal', salario: 30000 });
const B = await emp({ nombre: 'Bruno Díaz', correo: 'bruno@afc.org', cargo: 'Conductor', ingreso: '2023-03-01', tipo: 'quincenal', salario: 12000 });
const C = await emp({ nombre: 'Carla Ruiz', correo: 'carla@afc.org', cargo: 'Directora', ingreso: '2018-05-02', tipo: 'mensual', salario: 60000 });
const D = await emp({ nombre: 'Diego Mora', correo: 'diego@afc.org', cargo: 'Técnico', ingreso: '2026-11-11', tipo: 'quincenal', salario: 15000 });
const E = await emp({ nombre: 'Eva Soto', correo: 'eva@afc.org', cargo: 'Cocinera', ingreso: '2026-06-15', tipo: 'quincenal', salario: 9000 });
const lin = async (pl, e) => (await v1(`select * from planilla_lineas where planilla_id=$1 and empleado_id=$2`, [pl, e]))[0];
const conc = async c => (await v1(`select id from conceptos_planilla where codigo=$1`, [c]))[0].id;

console.log('Días comerciales');
const d360 = async (a, b) => (await v1(`select dias360($1::date, $2::date) n`, [a, b]))[0].n;
check('1 dic → 30 nov = 360', await d360('2025-12-01', '2026-11-30') === 360);
check('15 jun → 30 nov = 166', await d360('2026-06-15', '2026-11-30') === 166);
check('febrero completo = 30', await d360('2026-02-01', '2026-02-28') === 30);
check('16 → 31 dic = 15', await d360('2026-12-16', '2026-12-31') === 15);
const di = async (a, b, m) => (await v1(`select dias_indemnizacion($1::date, $2::date, $3) n`, [a, b, m]))[0].n;
check('indemnización 2 años = 60 días', await di('2024-01-01', '2025-12-30', false) === 60);
check('indemnización 6 años = 150 días', await di('2020-01-01', '2025-12-30', false) === 150);
check('tope de 5 meses (10 años = 150)', await di('2015-01-01', '2024-12-30', false) === 150);
check('despido sin causa: mínimo un mes', await di('2026-11-01', '2026-11-30', true) === 30);
check('renuncia de un mes: proporcional (2.5 días)', await di('2026-11-01', '2026-11-30', false) === 2.5);

console.log('Aguinaldo');
const pa = (await como(RH, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'aguinaldo', hasta: '2026-11-30' })])).rows[0].id;
const pla = (await v1(`select * from planillas where id=$1`, [pa]))[0];
check('período 01/12/2025 al 30/11/2026, pago el 10/12', pla.desde === '2025-12-01' && pla.hasta === '2026-11-30' && pla.fecha_pago === '2026-12-10', JSON.stringify(pla));
check('incluye quincenales y mensuales (5)', pla.empleados === 5, pla.empleados);
check('Ana año completo: 30,000', (await lin(pa, A)).salario_periodo === 30000);
check('Carla mensual: 60,000', (await lin(pa, C)).salario_periodo === 60000);
check('Eva desde 15/06: 166 días = 4,150.00', casi((await lin(pa, E)).salario_periodo, 4150), (await lin(pa, E)).salario_periodo);
check('Diego desde 11/11: 20 días = 833.33', casi((await lin(pa, D)).salario_periodo, 833.33));
const la = await lin(pa, A);
check('sin INSS, IR, patronal ni INATEC', la.inss_laboral === 0 && la.ir === 0 && la.inss_patronal === 0 && la.inatec === 0 && la.neto === 30000);
const le = await lin(pa, E);
await como(RH, `select actualizar_linea_planilla($1, 10)`, [le.id]);
check('días sin goce reducen el aguinaldo (156 días = 3,900)', casi((await lin(pa, E)).salario_periodo, 3900));
await como(RH, `select guardar_novedad($1::jsonb)`, [JSON.stringify({ planilla_id: pa, empleado_id: A, concepto_id: await conc('PREST'), monto: 1000 })]);
check('se pueden descontar préstamos', casi((await lin(pa, A)).neto, 29000));
await falla('un aguinaldo por año', RH, `select guardar_planilla($1::jsonb)`, [JSON.stringify({ tipo: 'aguinaldo', hasta: '2026-11-30' })], /Ya existe/);
await como(RH, `select enviar_planilla($1)`, [pa]);
const asa = (await como(DIR, `select aprobar_planilla($1) id`, [pa])).rows[0].id;
const tA = (await v1(`select sum(debe) d, sum(haber) h from asiento_lineas where asiento_id=$1`, [asa]))[0];
check('asiento de aguinaldo cuadra', casi(tA.d, tA.h));
const tot = (await v1(`select total_bruto, total_neto from planillas where id=$1`, [pa]))[0];
check('gasto en Prestaciones sociales = total', casi(-await saldoCta(par.cuenta_prestaciones_id), tot.total_bruto));
check('salarios por pagar = neto', casi(await saldoCta(par.cuenta_neto_pagar_id), tot.total_neto));
check('el aguinaldo no acumula vacaciones', (await v1(`select count(*)::int n from vacaciones_movimientos where planilla_id=$1`, [pa]))[0].n === 0);

console.log('Liquidación');
await como(RH, `select registrar_vacaciones($1::jsonb)`, [JSON.stringify({ empleado_id: B, tipo: 'saldo_inicial', dias: 8, fecha: '2026-11-30' })]);
const sim = (await como(RH, `select simular_liquidacion($1, '2026-12-20', '2026-12-15', 'renuncia') s`, [B])).rows[0].s;
check('simulación: 5 días de salario = 2,000', sim.dias_salario === 5 && sim.salario === 2000, JSON.stringify(sim));
check('simulación: 8.42 días de vacaciones = 3,368', sim.dias_vacaciones === 8.42 && sim.vacaciones === 3368);
check('simulación: aguinaldo 20 días = 666.67', sim.dias_aguinaldo === 20 && casi(sim.aguinaldo, 666.67));
check('simulación: renuncia indemniza 106.11 días = 42,444', sim.indemniza && sim.dias_indemnizacion === 106.11 && casi(sim.indemnizacion, 42444));
check('simulación: INSS solo sobre salario y vacaciones (375.76)', casi(sim.inss, 375.76));
check('simulación: neto 48,102.91', casi(sim.neto, 48102.91), sim.neto);
const sj = (await como(RH, `select simular_liquidacion($1, '2026-12-20', '2026-12-15', 'despido_causa_justa') s`, [B])).rows[0].s;
check('despido con causa justa: sin indemnización', !sj.indemniza && sj.indemnizacion === 0);

const pliq = (await como(RH, `select crear_liquidacion($1::jsonb) id`, [JSON.stringify({ empleado_id: B, fecha_salida: '2026-12-20', ultimo_dia_pagado: '2026-12-15', motivo: 'renuncia' })])).rows[0].id;
let lb = await lin(pliq, B);
const nov = await v1(`select c.codigo, n.monto from planilla_novedades n join conceptos_planilla c on c.id=n.concepto_id where planilla_id=$1 order by 1`, [pliq]);
check('genera aguinaldo, indemnización y vacaciones', nov.map(x => x.codigo).join() === 'AGULIQ,INDEM,VACLIQ', JSON.stringify(nov));
check('liquidación igual a la simulación', casi(lb.neto, sim.neto) && casi(lb.inss_laboral, sim.inss), JSON.stringify(lb));
await falla('no se agrega indemnización a mano', RH, `select guardar_novedad($1::jsonb)`, [JSON.stringify({ planilla_id: pliq, empleado_id: B, concepto_id: await conc('INDEM'), monto: 5 })], /calcula la app/);
const nid = (await v1(`select id from planilla_novedades where planilla_id=$1 and automatica limit 1`, [pliq]))[0].id;
await falla('no se borra un monto calculado', RH, `select eliminar_novedad($1)`, [nid], /calcula la app/);
await como(RH, `select editar_liquidacion($1, 'despido_causa_justa', false)`, [pliq]);
check('al cambiar a causa justa se quita la indemnización', casi((await lin(pliq, B)).neto, sj.neto));
await como(RH, `select editar_liquidacion($1, 'renuncia', true)`, [pliq]);
await como(RH, `select guardar_novedad($1::jsonb)`, [JSON.stringify({ planilla_id: pliq, empleado_id: B, concepto_id: await conc('PREST'), monto: 2102.91, descripcion: 'Saldo del préstamo' })]);
check('descuenta el saldo del préstamo', casi((await lin(pliq, B)).neto, 46000));
await falla('una liquidación por persona', RH, `select crear_liquidacion($1::jsonb)`, [JSON.stringify({ empleado_id: B, fecha_salida: '2026-12-21', motivo: 'renuncia' })], /ya tiene/);
await como(RH, `select enviar_planilla($1)`, [pliq]);
const asl = (await como(DIR, `select aprobar_planilla($1) id`, [pliq])).rows[0].id;
const tL = (await v1(`select sum(debe) d, sum(haber) h from asiento_lineas where asiento_id=$1`, [asl]))[0];
check('asiento de liquidación cuadra', casi(tL.d, tL.h), JSON.stringify(tL));
const eb = (await v1(`select activo, fecha_baja from empleados where id=$1`, [B]))[0];
check('Bruno queda inactivo con fecha de baja', !eb.activo && eb.fecha_baja === '2026-12-20');
const vb = (await v1(`select coalesce(sum(dias),0) s from vacaciones_movimientos where empleado_id=$1 and estado='aprobado'`, [B]))[0].s;
check('vacaciones de Bruno quedan en cero', casi(vb, 0), vb);
const pq = (await como(RH, `select guardar_planilla($1::jsonb) id`, [JSON.stringify({ tipo: 'quincenal', desde: '2026-12-16', hasta: '2026-12-31' })])).rows[0].id;
check('la siguiente quincena ya no lo incluye', !(await lin(pq, B)));
await como(DIR, `select anular_planilla($1, 'Se retractó')`, [pliq]);
const eb2 = (await v1(`select activo, fecha_baja from empleados where id=$1`, [B]))[0];
const vb2 = (await v1(`select coalesce(sum(dias),0) s from vacaciones_movimientos where empleado_id=$1 and estado='aprobado'`, [B]))[0].s;
check('al anular vuelve a estar activo con sus 8 días', eb2.activo && eb2.fecha_baja === null && casi(vb2, 8), JSON.stringify(eb2) + vb2);
const pd = (await como(RH, `select crear_liquidacion($1::jsonb) id`, [JSON.stringify({ empleado_id: D, fecha_salida: '2026-12-05', ultimo_dia_pagado: '2026-11-30', motivo: 'despido_sin_causa' })])).rows[0].id;
const indD = (await v1(`select n.monto from planilla_novedades n join conceptos_planilla c on c.id=n.concepto_id and c.codigo='INDEM' where planilla_id=$1`, [pd]))[0]?.monto;
check('despido sin causa con menos de un año: un mes (15,000)', indD === 15000, indD);
await falla('Bodeguero no simula liquidaciones', BOD, `select simular_liquidacion($1, '2026-12-20', null, 'renuncia')`, [A], /permiso/);

console.log('Activos fijos');
const cat = async n => (await v1(`select * from activos_categorias where nombre=$1`, [n]))[0];
const cc = await cat('Equipo de cómputo'), cv = await cat('Vehículos');
check('vida útil Ley 822: cómputo 2 años, vehículos 5', cc.vida_util_meses === 24 && cv.vida_util_meses === 60);
check('Contador tiene permiso de activos', (await v1(`select permisos from roles where nombre='Contador'`))[0].permisos.includes('activos.editar'));
const act = async a => (await como(CON, `insert into activos_fijos (codigo, nombre, categoria_id, centro_costo_id, fecha_adquisicion, inicio_depreciacion, costo, valor_residual, vida_util_meses, dep_inicial)
  values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) returning id`, [a.codigo, a.nombre, a.cat, centro, a.fecha, a.inicio, a.costo, a.residual || 0, a.vida, a.inicial || 0])).rows[0].id;
const L1 = await act({ codigo: 'AF-001', nombre: 'Laptop Dell', cat: cc.id, fecha: '2026-09-20', inicio: '2026-10-01', costo: 24000, vida: 24 });
const V1 = await act({ codigo: 'AF-002', nombre: 'Camioneta Hilux', cat: cv.id, fecha: '2026-10-25', inicio: '2026-11-01', costo: 600000, residual: 60000, vida: 60 });
const S1 = await act({ codigo: 'AF-003', nombre: 'Silla vieja', cat: (await cat('Mobiliario y equipo de oficina')).id, fecha: '2025-01-05', inicio: '2025-02-01', costo: 1000, vida: 12, inicial: 950 });
check('Bodeguero no ve activos', (await como(BOD, `select count(*)::int n from activos_fijos`)).rows[0].n === 0);
const calc = async (y, m) => Object.fromEntries((await como(CON, `select * from calcular_depreciacion($1, $2)`, [y, m])).rows.map(r => [r.activo_id, r.monto]));
let c10 = await calc(2026, 10);
check('octubre: laptop 1,000 y silla solo 50 (lo que le falta)', c10[L1] === 1000 && c10[S1] === 50 && !c10[V1], JSON.stringify(c10));
const dep10 = (await como(CON, `select registrar_depreciacion(2026, 10) id`)).rows[0].id;
const c11 = await calc(2026, 11);
check('noviembre: laptop 1,000 + camioneta 9,000; silla ya depreciada', c11[L1] === 1000 && c11[V1] === 9000 && !c11[S1], JSON.stringify(c11));
const dep11 = (await como(CON, `select registrar_depreciacion(2026, 11) id`)).rows[0].id;
await falla('no se registra dos veces el mismo mes', CON, `select registrar_depreciacion(2026, 11)`, [], /ya está registrada/);
const asd = (await v1(`select asiento_id, total from depreciaciones where id=$1`, [dep11]))[0];
const tD = (await v1(`select sum(debe) d, sum(haber) h from asiento_lineas where asiento_id=$1`, [asd.asiento_id]))[0];
check('asiento de depreciación cuadra (10,000)', casi(tD.d, 10000) && casi(tD.h, 10000) && asd.total === 10000);
check('depreciación acumulada en 1.2.02 = 11,050', casi(await saldoCta(cc.cuenta_dep_acum_id), 11050));
const res = Object.fromEntries((await como(CON, `select * from resumen_activos()`)).rows.map(r => [r.activo_id, r]));
check('laptop: acumulada 2,000, libros 22,000, faltan 22 meses', res[L1].dep_acumulada === 2000 && res[L1].valor_libros === 22000 && res[L1].meses_restantes === 22, JSON.stringify(res[L1]));
await falla('no se cambia el costo con depreciación registrada', CON, `update activos_fijos set costo = 1 where id = $1`, [L1], /no se cambian/);
await falla('no se anula octubre si noviembre sigue', CON, `select anular_depreciacion($1, 'x')`, [dep10], /posteriores/);
await falla('contabilidad no anula el asiento de depreciación', ADM, `select anular_asiento($1, 'x')`, [asd.asiento_id], /activos fijos|permiso/);
const caja = (await v1(`select id from cuentas where codigo='1.1.01'`))[0].id;
await falla('no se da de baja antes de una depreciación ya registrada', CON, `select dar_baja_activo($1, $2::jsonb)`, [L1, JSON.stringify({ fecha: '2026-10-15', tipo: 'venta', valor_venta: 1, cuenta_cobro_id: caja, motivo: 'x' })], /anúlela/);
const asb = (await como(CON, `select dar_baja_activo($1, $2::jsonb) id`, [L1, JSON.stringify({ fecha: '2026-11-30', tipo: 'venta', valor_venta: 25000, cuenta_cobro_id: caja, motivo: 'Venta a colaborador' })])).rows[0].id;
const lbj = await v1(`select c.codigo, l.debe, l.haber from asiento_lineas l join cuentas c on c.id=l.cuenta_id where asiento_id=$1 order by orden`, [asb]);
const sum = k => lbj.reduce((s, x) => s + x[k], 0);
check('baja: sale costo 24,000 y acumulada 2,000; ganancia 3,000', casi(sum('debe'), sum('haber')) && lbj.some(x => x.codigo === '4.4' && x.haber === 3000) && lbj.some(x => x.codigo === '1.2.01' && x.haber === 24000), JSON.stringify(lbj));
const asb2 = (await como(CON, `select dar_baja_activo($1, $2::jsonb) id`, [S1, JSON.stringify({ fecha: '2026-11-30', tipo: 'descarte', motivo: 'Rota' })])).rows[0].id;
const lbj2 = await v1(`select c.nombre, l.debe, l.haber from asiento_lineas l join cuentas c on c.id=l.cuenta_id where asiento_id=$1 order by orden`, [asb2]);
check('descarte: valor residual en libros (0) sin pérdida', lbj2.length === 2, JSON.stringify(lbj2));
check('no se edita un activo dado de baja', (await como(CON, `update activos_fijos set nombre='x' where id=$1 returning id`, [L1])).rows.length === 0);
const c12 = await calc(2026, 12);
check('diciembre: la laptop vendida ya no se deprecia', !c12[L1] && c12[V1] === 9000, JSON.stringify(c12));
await falla('Bodeguero no registra depreciación', BOD, `select registrar_depreciacion(2026, 12)`, [], /permiso/);
await como(CON, `select anular_baja_activo($1, 'Error')`, [L1]);
check('al anular la baja vuelve a depreciarse', (await calc(2026, 12))[L1] === 1000);
await como(CON, `select anular_depreciacion($1, 'Prueba')`, [dep11]);
check('al anular noviembre se puede volver a registrar', (await calc(2026, 11))[V1] === 9000);
check('acumulada: 1,050 de octubre − 1,000 de la silla descartada = 50', casi(await saldoCta(cc.cuenta_dep_acum_id), 50), await saldoCta(cc.cuenta_dep_acum_id));

console.log(`\n${ok} pruebas correctas, ${fail} fallidas`);
process.exit(fail ? 1 : 0);
