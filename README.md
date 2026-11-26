# Contabilidad AFC — contabilidad, bancos e inventario

App web de contabilidad, cheques e inventario para Amigos for Christ sobre **Supabase** (PostgreSQL). La base de datos hace cumplir las reglas contables y la app web es una sola página que se publica en GitHub Pages.

- App: https://amigos-for-christ-inc.github.io/Contabilidad-AFC/
- Proyecto Supabase: `contabilidad-afc` (organización Amigos for Christ, Org.)

## Archivos

| Archivo | Qué es |
|---|---|
| `schema.sql` | Base de datos 1: contabilidad (cuentas, asientos de partida doble, períodos, reportes, seguridad y catálogo de ejemplo). |
| `002-roles-inventario.sql` | Migración 2: roles configurables, bodegas e inventario. Se ejecuta después de `schema.sql`. |
| `003-bancos-cheques.sql` | Migración 3: cuentas bancarias BANPRO, cheques con aprobación, impresión y conciliación básica. Se ejecuta después de `002`. |
| `index.html` | La app web completa (no necesita compilar nada). |
| `logo.png`, `logo-blanco.png` | Logos oficiales de Amigos for Christ. |
| `pruebas/` | Pruebas automáticas: 40 de contabilidad, 57 de roles e inventario y 33 de cheques. |

## Qué hace

### Contabilidad
- **Catálogo de cuentas** jerárquico por código (`6.1.03` vive dentro de `6.1`). Las cuentas de agrupación suman a sus subcuentas.
- **Asientos de partida doble.** Se guardan en borrador y luego se contabilizan. La base de datos verifica que Debe = Haber, que haya al menos dos líneas y que no se use una cuenta de agrupación. Asigna el número correlativo del año.
- **Asientos en dólares**, convertidos a C$ con el tipo de cambio del día. Si el redondeo deja centavos de diferencia, se ajustan solos.
- **Nada contabilizado se edita.** Para corregir un asiento se anula, con motivo obligatorio, y se registra uno nuevo.
- **Períodos mensuales** que se cierran, y **cierre del ejercicio** contra resultados acumulados.
- **Reportes:** libro diario, libro mayor, balanza de comprobación, estado de resultados por centro de costo y balance general, con impresión y CSV.

### Inventario
- **Bodegas ilimitadas** (vienen 3 de ejemplo). Cada una puede tener su propia cuenta contable de inventario.
- **Productos** con unidad base y **presentaciones propias**, por ejemplo Caja = 24 unidades o Quintal = 100 libras. Se registra en cualquier presentación y la existencia se lleva en la unidad base.
- **Movimientos:**
  - **Entradas**: compras y donaciones, con costo.
  - **Salidas**: a proyectos y programas, con centro de costo.
  - **Traslados** entre bodegas.
  - **Ajustes** por conteo físico. La columna "Contado" calcula la diferencia.
- Los movimientos se guardan en borrador y luego se aplican. No se permite dejar existencia negativa.
- **Costo promedio ponderado.** Al sacar todo un producto, su valor queda exactamente en cero.
- **Asiento contable automático** al aplicar o anular cada movimiento. El valor del inventario siempre coincide con el saldo contable de la cuenta de inventario.
- **Anulación** con motivo y fecha. Revierte las existencias y registra el asiento de reversión.
- **Reportes:** existencias por bodega (una columna por bodega), kardex por producto y bodega, productos bajo el mínimo, comprobante imprimible con firmas.

### Bancos y cheques
- **Cuentas bancarias** (vienen BANPRO córdobas y BANPRO dólares), cada una con su cuenta contable, número de cuenta y **próximo número de chequera**.
- **Elaborar un cheque:** beneficiario, monto, concepto y distribución contable (a qué se carga). Las **retenciones** van al Haber; el botón "Retención IR 2%" la calcula. La cuenta del banco se acredita sola. La vista previa muestra el cheque con el **monto en letras**.
- **Aprobación por otra persona:** quien elabora el cheque lo envía a aprobación y **no puede aprobarlo él mismo**, aunque sea administrador. El aprobador puede aprobarlo o devolverlo con motivo.
- **Al aprobar** se asigna el número de la chequera y se registra el asiento contable automáticamente.
- **Impresión:** el cheque sobre la chequera de BANPRO (posiciones configurables en milímetros, con impresión de prueba) y el **comprobante** en hoja carta con distribución contable y firmas (Elaborado, Revisado, Aprobado, Recibí conforme). Avisa si un cheque se reimprime.
- **Cobrado / en circulación:** se marca la fecha de cobro según el estado de cuenta; el inicio muestra los cheques en circulación.
- **Anulación** con motivo y asiento de reversión (no se puede anular un cheque cobrado).

### Interfaz
- Panel de inicio con gráficos de ingresos y gastos, inventario por bodega y saldos bancarios; cheques esperando su aprobación.
- **Búsqueda rápida con Ctrl + K** (⌘K en Mac): pantallas, acciones, cheques, asientos, movimientos, productos y cuentas.
- **Modo oscuro**, transiciones y animaciones (se reducen si el equipo lo pide).

### Usuarios, roles y permisos
- **Roles configurables** con permisos por módulo: ver o editar contabilidad, cerrar meses, ver inventario, registrar o anular movimientos, administrar productos y bodegas, trabajar en todas las bodegas, y administrar usuarios.
- **Roles de base:** Administrador, Contador, Jefe de bodega, Bodeguero, Consulta y Aprobador de cheques. El administrador puede crear otros, como "Compras".
- **Bodegas por usuario:** un Bodeguero solo ve y registra en las bodegas que se le asignen.
- **Usuarios nuevos entran sin acceso** hasta que un administrador les asigne un rol. El primero en registrarse queda como Administrador.
- **Bitácora** de quién cambió qué y cuándo.

La seguridad vive en la base de datos (RLS), no en la página. Aunque alguien manipule la app, no puede ver ni hacer lo que su rol no permite.

## Puesta en marcha (instalación nueva)
1. En Supabase, en **SQL Editor**, ejecute `schema.sql`, después `002-roles-inventario.sql` y por último `003-bancos-cheques.sql`.
2. Suba `index.html`, `logo.png` y `logo-blanco.png` a un repositorio con GitHub Pages. En `index.html`, en `const CONFIG`, ponga la URL del proyecto y la clave pública (publishable).
3. En Supabase, en **Authentication → URL Configuration**, ponga la dirección de GitHub Pages como **Site URL** y en **Redirect URLs**.
4. **Regístrese usted primero** para quedar como Administrador. Asigne los roles y las bodegas a los demás en **Usuarios**.
5. Con el contador, revise el catálogo de cuentas de ejemplo y las cuentas contables del inventario (en **Bodegas**). Después registre los saldos iniciales: un asiento de **Apertura** para la contabilidad y **entradas** para las existencias iniciales.

### Entrar con Microsoft 365 (opcional)
1. En **Microsoft Entra ID → App registrations → New registration**, use como redirect URI (Web) `https://<su-proyecto>.supabase.co/auth/v1/callback`.
2. Cree un **client secret** y copie el **Application (client) ID** y el **Directory (tenant) ID**.
3. En Supabase, en **Authentication → Providers → Azure**, actívelo y pegue el ID y el secreto. En **Azure Tenant URL** ponga `https://login.microsoftonline.com/<tenant-id>`.

## Pruebas
```
npm install @electric-sql/pglite
node pruebas/prueba-esquema.mjs        # contabilidad
node pruebas/prueba-inventario.mjs     # roles e inventario (usa schema.sql y 002)
node pruebas/prueba-cheques.mjs        # bancos y cheques (usa los tres .sql)
```
Ejecútelas desde la carpeta donde están los `.sql`.

## Pendiente para siguientes fases
- Compras y cuentas por pagar (órdenes de compra con aprobación), ventas y cuentas por cobrar, conciliación bancaria completa con estado de cuenta.
- Informes en formato VET, validados con el contador.
- Activos fijos con depreciación, presupuesto contra lo real.
- Respaldos: el plan gratuito de Supabase no incluye respaldos diarios descargables. Para uso real, conviene el plan Pro o una copia periódica propia (`pg_dump`).

## Notas
- **Calibrar la impresión del cheque:** en Cuentas bancarias, abra la cuenta, use "Imprimir prueba" en papel común, sobrepóngala a un cheque de BANPRO a contraluz y ajuste los milímetros.
- Moneda funcional: córdobas.
- El costo promedio es perpetuo. Los movimientos se valoran en el orden en que se aplican, así que conviene registrarlos al día.
- El rojo de errores y alertas está fuera de la paleta de la marca; se usa solo para avisos.
