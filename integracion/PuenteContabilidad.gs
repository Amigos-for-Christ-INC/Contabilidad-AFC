/**
 * Puente: App de marcaje → Contabilidad AFC (planilla y vacaciones)
 *
 * Se agrega como archivo nuevo en el MISMO proyecto de Apps Script del
 * marcaje (usa sus funciones rows_, cfg_ y las hojas Empleados, Marcas y
 * Permisos). No modifica la hoja: solo lee y envía.
 *
 * Configuración del proyecto → Propiedades del script:
 *   AFC_URL    (opcional) si no está, usa la de Contabilidad AFC
 *   AFC_ANON   la clave pública (publishable) de Supabase que usa la app
 *   AFC_CLAVE  la clave creada en Contabilidad AFC → Configuración de planilla
 *
 * Luego: ejecutar enviarAContabilidad() una vez (autoriza) y
 * activarEnvioDiario() para que corra solo cada noche.
 */
const AFC_DIAS_ATRAS = 45;   // marcas y permisos de los últimos 45 días

function enviarAContabilidad() {
  const p = PropertiesService.getScriptProperties();
  const url = p.getProperty('AFC_URL') || 'https://qrjhpkicapbtnzagbnsx.supabase.co/rest/v1/rpc/recibir_marcaje', anon = p.getProperty('AFC_ANON'), clave = p.getProperty('AFC_CLAVE');
  if (!anon || !clave) throw new Error('Faltan las propiedades AFC_ANON o AFC_CLAVE');

  const tz = Session.getScriptTimeZone();
  const desde = Utilities.formatDate(new Date(Date.now() - AFC_DIAS_ATRAS * 86400000), tz, 'yyyy-MM-dd');
  const correo = c => String(c || '').trim().toLowerCase();

  const empleados = rows_('Empleados').filter(r => r[0]).map(r => ({
    correo: correo(r[0]), nombre: r[1], cargo: r[2], lugar: r[3],
    activo: String(r[4]).trim().toUpperCase() !== 'NO', lider: correo(r[9])
  }));

  // Permisos (columnas: ID, Solicitado, Correo, Nombre, Tipo, Desde, Hasta, HoraDesde, HoraHasta, Motivo, Estado, …, ReponerFecha)
  const permisosHoja = rows_('Permisos').filter(r => r[0]);
  const reposiciones = {};   // días de fin de semana acordados para reponer horas: no son días extra
  permisosHoja.forEach(r => { if (r[18] && r[10] === 'Aprobado') reposiciones[correo(r[2]) + '|' + r[18]] = true; });
  const permisos = permisosHoja.filter(r => String(r[6] || r[5]) >= desde).map(r => ({
    id: r[0], correo: correo(r[2]), tipo: r[4], desde: r[5], hasta: r[6] || r[5],
    horaDesde: r[7], horaHasta: r[8], motivo: r[9], estado: r[10]
  }));

  // Marcas (columnas: ID, Fecha, Correo, Nombre, Entrada, Salida, Horas, …, Lugar)
  const marcas = rows_('Marcas').filter(r => r[0] && String(r[1]) >= desde).map(r => ({
    id: r[0], fecha: r[1], correo: correo(r[2]), nombre: r[3], entrada: r[4], salida: r[5],
    horas: String(r[6] || '').replace(',', '.'), lugar: r[13], reposicion: !!reposiciones[correo(r[2]) + '|' + r[1]]
  }));

  const datos = {
    empleados, marcas, permisos,
    dias_laborales: (cfg_('DIAS_LABORALES') || '1,2,3,4,5').split(/[,;\s]+/).map(Number).filter(Boolean),
    feriados: (cfg_('FERIADOS') || '').split(/[,;\s]+/).filter(f => /^\d{4}-\d{2}-\d{2}$/.test(f)),
    horas_dia: Number(String(cfg_('HORAS_DIA') || '8').replace(',', '.')) || 8
  };

  const r = UrlFetchApp.fetch(url, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: anon, Authorization: 'Bearer ' + anon },
    payload: JSON.stringify({ p_clave: clave, p: datos })
  });
  const txt = r.getContentText();
  if (r.getResponseCode() >= 300) throw new Error('Contabilidad AFC respondió ' + r.getResponseCode() + ': ' + txt);
  console.log('Enviado a Contabilidad AFC: ' + txt);
  return JSON.parse(txt);
}

function activarEnvioDiario() {
  ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === 'enviarAContabilidad').forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('enviarAContabilidad').timeBased().everyDays(1).atHour(22).create();
  return 'Envío diario activado (10 p. m.)';
}

// "Mi pago" en la app: salario, deducciones y neto del mes del trabajador que
// inició sesión. Solo consulta su propio correo; nadie ve el pago de otro.
// (La pestaña "Mi pago" y la función cargarPago() están en Index.html del marcaje.)
function miPago(token, anio, mes) {
  const e = sesionEmp_(token);
  const p = PropertiesService.getScriptProperties();
  const anon = p.getProperty('AFC_ANON'), clave = p.getProperty('AFC_CLAVE');
  if (!anon || !clave) throw new Error('La consulta de pago todavía no está configurada.');
  const base = p.getProperty('AFC_URL') || 'https://qrjhpkicapbtnzagbnsx.supabase.co/rest/v1/rpc/recibir_marcaje';
  const r = UrlFetchApp.fetch(base.replace(/recibir_marcaje$/, 'pago_colaborador'), {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: anon, Authorization: 'Bearer ' + anon },
    payload: JSON.stringify({ p_clave: clave, p_correo: e.correo, p_anio: Number(anio), p_mes: Number(mes) })
  });
  if (r.getResponseCode() >= 300) throw new Error('No se pudo consultar tu pago. Intenta más tarde.');
  return JSON.parse(r.getContentText());
}

/**
 * Colillas de pago por correo. Contabilidad AFC llama esto al registrar el pago
 * de una planilla, con un permiso de un solo uso (token) que vence en 2 horas.
 * Se envían desde el mismo buzón de Microsoft 365 que usa el marcaje.
 */
function enviarColillas(planillaId, token) {
  const p = PropertiesService.getScriptProperties();
  const anon = p.getProperty('AFC_ANON'), clave = p.getProperty('AFC_CLAVE');
  if (!anon || !clave) throw new Error('Faltan las propiedades AFC_ANON o AFC_CLAVE');
  const base = (p.getProperty('AFC_URL') || 'https://qrjhpkicapbtnzagbnsx.supabase.co/rest/v1/rpc/recibir_marcaje').replace(/recibir_marcaje$/, '');
  const rpc = (fn, body) => {
    const r = UrlFetchApp.fetch(base + fn, {
      method: 'post', contentType: 'application/json', muteHttpExceptions: true,
      headers: { apikey: anon, Authorization: 'Bearer ' + anon }, payload: JSON.stringify(body)
    });
    const txt = r.getContentText();
    if (r.getResponseCode() >= 300) {
      let m = txt; try { m = JSON.parse(txt).message || txt; } catch (e) {}
      throw new Error(m);
    }
    return txt ? JSON.parse(txt) : null;
  };

  const pl = rpc('colillas_planilla', { p_clave: clave, p_planilla: Number(planillaId), p_token: String(token || '') });
  const c$ = n => 'C$ ' + Number(n || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const f = s => s ? String(s).slice(8, 10) + '/' + String(s).slice(5, 7) + '/' + String(s).slice(0, 4) : '';
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));

  let enviados = 0, errores = 0, sinCorreo = 0;
  const detalle = [];
  pl.empleados.forEach(e => {
    if (!e.correo) { sinCorreo++; detalle.push({ nombre: e.nombre, estado: 'sin correo' }); return; }
    const fila = (t, v, neg) => '<tr><td style="padding:4px 0">' + esc(t) + '</td><td style="padding:4px 0;text-align:right">' + (neg ? '− ' : '') + c$(v) + '</td></tr>';
    const ingresos = (e.novedades || []).filter(n => n.tipo === 'ingreso');
    const deducciones = (e.novedades || []).filter(n => n.tipo !== 'ingreso');
    const bloque = '<table style="width:100%;border-collapse:collapse;font-size:14px">'
      + '<tr><td colspan="2" style="padding:6px 0 2px;font-weight:bold;color:#1B365D">Ingresos</td></tr>'
      + fila((pl.tipo === 'aguinaldo' ? 'Aguinaldo' : pl.tipo === 'liquidacion' ? 'Salario pendiente' : 'Salario') + ' (' + e.dias_pagados + ' días)', e.salario)
      + ingresos.map(n => fila(n.concepto + (n.detalle ? ' · ' + n.detalle : ''), n.monto)).join('')
      + '<tr><td style="padding:4px 0;border-top:1px solid #ddd"><b>Total devengado</b></td><td style="padding:4px 0;border-top:1px solid #ddd;text-align:right"><b>' + c$(e.bruto) + '</b></td></tr>'
      + '<tr><td colspan="2" style="padding:10px 0 2px;font-weight:bold;color:#1B365D">Deducciones</td></tr>'
      + fila('INSS laboral', e.inss, true) + fila('IR', e.ir, true)
      + deducciones.map(n => fila(n.concepto + (n.detalle ? ' · ' + n.detalle : ''), n.monto, true)).join('')
      + '<tr><td style="padding:8px 0;border-top:2px solid #1B365D;font-size:16px"><b>Neto depositado</b></td><td style="padding:8px 0;border-top:2px solid #1B365D;text-align:right;font-size:16px"><b>' + c$(e.neto) + '</b></td></tr>'
      + '</table>';
    try {
      if (typeof cupoCorreo_ === 'function' && cupoCorreo_() <= 0) throw new Error('Se agotó el cupo diario de correos');
      enviarCorreo_({
        to: e.correo, name: e.nombre, subject: (pl.tipo === 'liquidacion' ? 'Liquidación: ' : pl.tipo === 'aguinaldo' ? 'Aguinaldo: ' : 'Colilla de pago: ') + pl.descripcion,
        htmlBody: plantillaCorreo_({
          titulo: pl.tipo === 'liquidacion' ? 'Liquidación final' : pl.tipo === 'aguinaldo' ? 'Aguinaldo' : 'Colilla de pago',
          intro: 'Hola ' + esc(String(e.nombre).split(' ')[0]) + ', este es el detalle de tu pago de la ' + esc(pl.descripcion).toLowerCase() + '.',
          estado: { texto: 'Pagado el ' + f(pl.fecha_pagado), color: '#1E7B45' },
          filas: [['Período', f(pl.desde) + ' al ' + f(pl.hasta)], ['Cargo', esc(e.cargo || '')], ['Cuenta BANPRO', esc(e.cuenta || '—')]],
          bloque: bloque,
          nota: 'Saldo de vacaciones: ' + Number(e.vacaciones || 0).toFixed(2) + ' días. También puedes ver tu pago del mes en la pestaña "Mi pago" de esta app. Si algo no coincide, escribe a Recursos Humanos.'
        })
      });
      enviados++; detalle.push({ nombre: e.nombre, estado: 'enviado' });
    } catch (err) {
      errores++; detalle.push({ nombre: e.nombre, estado: 'error', error: String(err.message || err).slice(0, 200) });
    }
  });

  try { rpc('registrar_envio_colillas', { p_clave: clave, p_planilla: Number(planillaId), p_enviados: enviados, p_errores: errores, p_detalle: detalle }); }
  catch (err) { console.log('No se pudo registrar el envío: ' + err.message); }
  return { enviados: enviados, errores: errores, sin_correo: sinCorreo };
}
