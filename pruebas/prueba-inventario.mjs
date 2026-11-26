// Pruebas de la migración 002 (roles + inventario) sobre una base v1 con datos.
// Uso: node prueba-inventario.mjs  (desde la carpeta con schema.sql y 002-roles-inventario.sql)
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
await db.exec(fs.readFileSync('./schema.sql', 'utf8'));

const ADM = '11111111-1111-1111-1111-111111111111', CON = '22222222-2222-2222-2222-222222222222',
      BOD = '33333333-3333-3333-3333-333333333333', JEF = '44444444-4444-4444-4444-444444444444';
await db.exec(`insert into auth.users (id, email) values ('${ADM}','admin@x.org'), ('${CON}','conta@x.org')`);
await db.exec(`update perfiles set rol = 'contador' where id = '${CON}'`);

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
const id = async (t, col, val) => (await v1(`select id from ${t} where ${col} = $1`, [val]))[0]?.id;

// Datos v1 antes de migrar
const caja = await id('cuentas', 'codigo', '1.1.01'), patr = await id('cuentas', 'codigo', '3.1');
await como(ADM, `select guardar_asiento($1::jsonb, true)`, [JSON.stringify({ fecha: '2026-11-02', concepto: 'Aporte', lineas: [{ cuenta_id: caja, debe: 100000 }, { cuenta_id: patr, haber: 100000 }] })]);

console.log('Migración');
await db.exec(fs.readFileSync('./002-roles-inventario.sql', 'utf8'));
const roles = await v1(`select p.correo, r.nombre from perfiles p left join roles r on r.id = p.rol_id order by correo`);
check('admin v1 → Administrador', roles.find(r => r.correo === 'admin@x.org').nombre === 'Administrador');
check('contador v1 → Contador', roles.find(r => r.correo === 'conta@x.org').nombre === 'Contador');
check('asientos v1 conservados', (await v1(`select count(*)::int n from asientos`))[0].n === 1);
check('3 bodegas, unidades y cuenta de ajustes creadas',
  (await v1(`select count(*)::int n from bodegas`))[0].n === 3 && (await v1(`select count(*)::int n from unidades`))[0].n > 10 &&
  (await v1(`select cuenta_ajuste_id from inv_parametros`))[0].cuenta_ajuste_id != null);

await db.exec(`insert into auth.users (id, email) values ('${BOD}','bodega@x.org'), ('${JEF}','jefe@x.org')`);
check('usuario nuevo entra sin rol', (await v1(`select rol_id from perfiles where id='${BOD}'`))[0].rol_id === null);
check('sin rol no ve el catálogo', (await como(BOD, 'select count(*)::int n from cuentas')).rows[0].n === 0);

console.log('Roles');
const rBod = await id('roles', 'nombre', 'Bodeguero'), rJef = await id('roles', 'nombre', 'Jefe de bodega'), rAdm = await id('roles', 'nombre', 'Administrador');
const b1 = await id('bodegas', 'codigo', 'B01'), b2 = await id('bodegas', 'codigo', 'B02'), b3 = await id('bodegas', 'codigo', 'B03');
await falla('contador no asigna roles', CON, `select cambiar_rol($1, $2)`, [BOD, rBod], /administrador/);
await como(ADM, `select cambiar_rol($1, $2)`, [BOD, rBod]);
await como(ADM, `select cambiar_rol($1, $2)`, [JEF, rJef]);
await como(ADM, `select asignar_bodegas($1, $2)`, [BOD, [b2]]);
check('bodeguero tiene sus permisos', JSON.stringify((await como(BOD, 'select mis_permisos() p')).rows[0].p) === '["inventario.ver","inventario.editar"]');
check('admin ve todos los permisos', (await como(ADM, 'select mis_permisos() p')).rows[0].p.length === 9);
await falla('el último administrador no puede quitarse', ADM, `select cambiar_rol($1, $2)`, [ADM, rBod], /al menos un usuario/);
await falla('rol Administrador protegido', ADM, `update roles set permisos = '{}' where id = $1`, [rAdm], /sistema/);
await como(ADM, `insert into roles (nombre, permisos) values ('Compras', array['inventario.ver','inventario.editar','inventario.todas_bodegas'])`);
check('admin crea un rol nuevo', !!(await id('roles', 'nombre', 'Compras')));
await falla('permiso inexistente se rechaza', ADM, `insert into roles (nombre, permisos) values ('X', array['volar'])`, [], /check constraint|violates/);
await falla('bodeguero no crea roles', BOD, `insert into roles (nombre) values ('Y')`, [], /row-level|permission/);
await falla('bodeguero no ve contabilidad', BOD, `select guardar_asiento('{}'::jsonb)`, [], /permiso/);
check('bodeguero no ve asientos', (await como(BOD, 'select count(*)::int n from asientos')).rows[0].n === 0);

console.log('Catálogo de inventario');
const und = await id('unidades', 'codigo', 'UND'), cajaU = await id('unidades', 'codigo', 'CAJA'), lb = await id('unidades', 'codigo', 'LB'), qq = await id('unidades', 'codigo', 'QQ');
await falla('bodeguero no crea productos', BOD, `insert into productos (codigo, nombre, unidad_id) values ('X','X',$1)`, [und], /row-level|permission/);
const p1 = (await como(JEF, `insert into productos (codigo, nombre, unidad_id) values ('TUB-05','Tubo PVC 1/2"', $1) returning id`, [und])).rows[0].id;
const p2 = (await como(JEF, `insert into productos (codigo, nombre, unidad_id, stock_minimo) values ('CEM-01','Cemento', $1, 200) returning id`, [lb])).rows[0].id;
await como(JEF, `insert into producto_presentaciones (producto_id, unidad_id, factor) values ($1, $2, 24)`, [p1, cajaU]);
await como(JEF, `insert into producto_presentaciones (producto_id, unidad_id, factor) values ($1, $2, 94)`, [p2, qq]);
await falla('nadie edita el costo promedio a mano', JEF, `update productos set costo_promedio = 1 where id = $1`, [p1], /permission/);

const prov = await id('cuentas', 'codigo', '2.1.01'), invC = await id('cuentas', 'codigo', '1.1.07'), costoProg = await id('cuentas', 'codigo', '5.1');
const ajusteC = (await v1(`select cuenta_ajuste_id c from inv_parametros`))[0].c;
const mov = (uid, p, aplicar = true) => como(uid, `select guardar_movimiento($1::jsonb, $2) id`, [JSON.stringify(p), aplicar]).then(r => r.rows[0].id);
const prod = async pid => (await v1(`select valor_total::numeric v, costo_promedio::numeric p, (select coalesce(sum(cantidad),0) from existencias where producto_id=$1)::numeric q from productos where id=$1`, [pid]))[0];
const ex = async (pid, bid) => Number((await v1(`select coalesce((select cantidad from existencias where producto_id=$1 and bodega_id=$2),0) c`, [pid, bid]))[0].c);
const saldo = async cid => Number((await v1(`select coalesce(sum(l.debe-l.haber),0) s from asiento_lineas l join asientos a on a.id=l.asiento_id where a.estado='contabilizado' and l.cuenta_id=$1`, [cid]))[0].s);
async function cuadre(n) {
  const valor = Number((await v1(`select sum(valor_total) v from productos`))[0].v);
  const s = await saldo(invC);
  check(`${n}: valor del inventario = saldo contable de Inventario (${valor.toFixed(2)})`, Math.abs(valor - s) < 0.005, `${valor} vs ${s}`);
}

console.log('Entradas');
const e1 = await mov(JEF, { tipo: 'entrada', fecha: '2026-11-05', bodega_id: b1, concepto: 'Compra a ferretería', referencia: 'FAC-881',
  lineas: [{ producto_id: p1, unidad_id: cajaU, cantidad: 10, costo: 240 }, { producto_id: p2, unidad_id: qq, cantidad: 5, costo: 470 }] });
let x = await prod(p1);
check('10 cajas × 24 = 240 tubos a C$ 10.00', Number(x.q) === 240 && Number(x.p) === 10 && Number(x.v) === 2400, JSON.stringify(x));
x = await prod(p2);
check('5 quintales = 470 lb a C$ 5.00', Number(x.q) === 470 && Number(x.p) === 5, JSON.stringify(x));
const m1 = (await v1(`select numero, asiento_id from inv_movimientos where id=$1`, [e1]))[0];
check('numerada E-2026-0001 con asiento', m1.numero === 1 && m1.asiento_id);
const a1 = await v1(`select c.codigo, l.debe::numeric d, l.haber::numeric h from asiento_lineas l join cuentas c on c.id=l.cuenta_id where asiento_id=$1 order by l.orden`, [m1.asiento_id]);
check('asiento: Dr Inventario 4,750 / Cr Proveedores 4,750', a1.length === 2 && a1[0].codigo === '1.1.07' && Number(a1[0].d) === 4750 && a1[1].codigo === '2.1.01' && Number(a1[1].h) === 4750, JSON.stringify(a1));
await mov(JEF, { tipo: 'entrada', fecha: '2026-11-06', bodega_id: b2, concepto: 'Compra 2', lineas: [{ producto_id: p1, cantidad: 100, costo: 13 }] });
x = await prod(p1);
check('costo promedio: (2,400 + 1,300) / 340 = 10.882353', Number(x.q) === 340 && Number(x.p) === 10.882353 && Number(x.v) === 3700, JSON.stringify(x));
await cuadre('tras entradas');
await falla('entrada sin costo se rechaza', JEF, `select guardar_movimiento($1::jsonb)`, [JSON.stringify({ tipo: 'entrada', fecha: '2026-11-06', bodega_id: b1, concepto: 'x', lineas: [{ producto_id: p1, cantidad: 1 }] })], /costo/);
await falla('unidad que no es del producto se rechaza', JEF, `select guardar_movimiento($1::jsonb)`, [JSON.stringify({ tipo: 'entrada', fecha: '2026-11-06', bodega_id: b1, concepto: 'x', lineas: [{ producto_id: p1, unidad_id: qq, cantidad: 1, costo: 1 }] })], /unidad/);

console.log('Bodegas por usuario');
await falla('bodeguero no registra en una bodega ajena', BOD, `select guardar_movimiento($1::jsonb)`, [JSON.stringify({ tipo: 'salida', fecha: '2026-11-07', bodega_id: b1, concepto: 'x', lineas: [{ producto_id: p1, cantidad: 1 }] })], /acceso a la bodega/);
check('bodeguero solo ve existencias de su bodega', (await como(BOD, `select count(distinct bodega_id)::int n, min(bodega_id) b from existencias`)).rows[0].b === b2);
check('jefe de bodega ve todas', (await como(JEF, `select count(distinct bodega_id)::int n from existencias`)).rows[0].n === 2);

console.log('Salidas');
const s1 = await mov(BOD, { tipo: 'salida', fecha: '2026-11-07', bodega_id: b2, concepto: 'Proyecto de agua El Viejo', lineas: [{ producto_id: p1, cantidad: 40 }] });
check('salida de 40 al promedio = C$ 435.29', Number((await v1(`select costo_total from inv_movimiento_lineas where movimiento_id=$1`, [s1]))[0].costo_total) === 435.29);
const as1 = (await v1(`select c.codigo, l.debe::numeric d from asiento_lineas l join cuentas c on c.id=l.cuenta_id join inv_movimientos m on m.asiento_id=l.asiento_id where m.id=$1 and l.debe>0`, [s1]))[0];
check('salida carga a Costo de programas (5.1)', as1.codigo === '5.1' && Number(as1.d) === 435.29);
check('el promedio se mantiene con salidas (±0.0001)', Math.abs(Number((await prod(p1)).p) - 10.882353) < 0.0001);
await falla('no permite dejar existencia negativa', BOD, `select guardar_movimiento($1::jsonb, true)`, [JSON.stringify({ tipo: 'salida', fecha: '2026-11-07', bodega_id: b2, concepto: 'x', lineas: [{ producto_id: p1, cantidad: 61 }] })], /Existencia insuficiente.*hay 60/);
check('el intento fallido no dejó borrador', (await v1(`select count(*)::int n from inv_movimientos where concepto='x'`))[0].n === 0);
await cuadre('tras salidas');

console.log('Traslados');
await mov(JEF, { tipo: 'traslado', fecha: '2026-11-08', bodega_id: b1, bodega_destino_id: b3, concepto: 'Envío a Bodega 3', lineas: [{ producto_id: p1, unidad_id: cajaU, cantidad: 5 }] });
check('traslado 5 cajas: B01 = 120, B03 = 120', await ex(p1, b1) === 120 && await ex(p1, b3) === 120);
check('traslado entre bodegas con la misma cuenta no genera asiento', (await v1(`select asiento_id from inv_movimientos where tipo='traslado'`))[0].asiento_id === null);
check('total del producto no cambia', Number((await prod(p1)).q) === 300);
await falla('traslado a la misma bodega se rechaza', JEF, `select guardar_movimiento($1::jsonb)`, [JSON.stringify({ tipo: 'traslado', fecha: '2026-11-08', bodega_id: b1, bodega_destino_id: b1, concepto: 'x', lineas: [] })], /distinta/);

console.log('Ajustes');
await mov(JEF, { tipo: 'ajuste', fecha: '2026-11-09', bodega_id: b3, concepto: 'Conteo físico', lineas: [{ producto_id: p1, cantidad: -3 }] });
await mov(JEF, { tipo: 'ajuste', fecha: '2026-11-09', bodega_id: b1, concepto: 'Conteo físico B01', lineas: [{ producto_id: p2, cantidad: 0.5 }] });
check('ajuste: −3 en B03 y +0.5 lb', await ex(p1, b3) === 117 && Number((await prod(p2)).q) === 470.5);
await cuadre('tras ajustes');

console.log('Salida total y anulaciones');
const sAll = await mov(JEF, { tipo: 'salida', fecha: '2026-11-10', bodega_id: b1, concepto: 'Todo el cemento', lineas: [{ producto_id: p2, cantidad: 470.5 }] });
x = await prod(p2);
check('al sacar todo, existencia y valor quedan en cero', Number(x.q) === 0 && Number(x.v) === 0, JSON.stringify(x));
await falla('bodeguero no puede anular', BOD, `select anular_movimiento($1, 'x', '2026-11-10')`, [s1], /permiso/);
await como(CON, `select anular_movimiento($1, 'Error', '2026-11-10')`, [sAll]);
x = await prod(p2);
check('anular la salida devuelve 470.5 lb con su valor', Number(x.q) === 470.5 && Number(x.v) === 2352.5, JSON.stringify(x));
await cuadre('tras anular salida');
await como(CON, `select anular_movimiento($1, 'Factura duplicada', '2026-11-10')`, [e1]).catch(e => check('anular entrada (B01 tiene 120 tubos de 240): falla por existencia', /insuficiente/.test(e.message), e.message));
const e3 = await mov(JEF, { tipo: 'entrada', fecha: '2026-11-11', bodega_id: b1, concepto: 'Compra cara', lineas: [{ producto_id: p1, cantidad: 10, costo: 50 }] });
await como(CON, `select anular_movimiento($1, 'Precio equivocado', '2026-11-11')`, [e3]);
check('anular entrada con otro promedio manda la diferencia a ajustes', (await v1(`select count(*)::int n from asiento_lineas l join inv_movimientos m on m.asiento_anulacion_id = l.asiento_id where m.id=$1 and l.cuenta_id=$2`, [e3, ajusteC]))[0].n === 1);
await cuadre('tras anular entrada');
await falla('no se anula dos veces', CON, `select anular_movimiento($1, 'x', '2026-11-11')`, [e3], /Solo se anulan/);
await falla('asiento de inventario no se anula desde contabilidad', CON, `select anular_asiento((select asiento_id from inv_movimientos where id=$1), 'x')`, [s1], /inventario/);

console.log('Kardex y períodos');
const k = (await como(JEF, `select * from kardex($1, null, '2026-11-01', '2026-11-30')`, [p1])).rows;
check('kardex: saldo inicial 0 y saldo final = existencia', Number(k[0].saldo) === 0 && Number(k.at(-1).saldo) === Number((await prod(p1)).q), JSON.stringify(k.at(-1)));
check('kardex del bodeguero solo trae su bodega', (await como(BOD, `select count(distinct bodega) n from kardex($1, null, '2026-11-01','2026-11-30') where bodega is not null`, [p1])).rows[0].n == 1);
await como(JEF, `select guardar_movimiento($1::jsonb)`, [JSON.stringify({ tipo: 'salida', fecha: '2026-11-12', bodega_id: b1, concepto: 'Pendiente', lineas: [{ producto_id: p1, cantidad: 1 }] })]);
await falla('no se cierra el mes con movimientos en borrador', ADM, `select cerrar_periodo(2026, 11)`, [], /inventario en borrador/);
await como(JEF, `select eliminar_movimiento(id) from inv_movimientos where concepto='Pendiente'`);
await como(CON, `select cerrar_periodo(2026, 11)`);
await falla('mes cerrado no acepta movimientos', JEF, `select guardar_movimiento($1::jsonb, true)`, [JSON.stringify({ tipo: 'salida', fecha: '2026-11-20', bodega_id: b1, concepto: 'y', lineas: [{ producto_id: p1, cantidad: 1 }] })], /cerrado/);
await como(CON, `select abrir_periodo(2026, 11)`);

console.log('Contabilidad v1 sigue funcionando');
const bal = (await como(CON, `select * from balanza('2026-11-01','2026-11-30')`)).rows;
const hojas = bal.filter(r => r.acepta_movimientos);
check('balanza cuadra con los asientos de inventario', Math.abs(hojas.reduce((s, r) => s + Number(r.debe), 0) - hojas.reduce((s, r) => s + Number(r.haber), 0)) < 0.005);
const g = c => Number(bal.find(r => r.codigo === c).saldo_final);
const res = g('4') - g('5') - g('6');
check('activo = pasivo + patrimonio + resultado', Math.abs(g('1') - g('2') - g('3') - res) < 0.005, `${g('1')} ${g('2')} ${g('3')} ${res}`);
check('consulta (rol v1) sigue viendo asientos', (await como(CON, 'select count(*)::int n from asientos')).rows[0].n > 1);

console.log(`\n${ok} pruebas correctas, ${fail} fallidas`);
process.exit(fail ? 1 : 0);
