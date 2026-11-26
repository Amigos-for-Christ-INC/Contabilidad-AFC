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
