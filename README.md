# Contabilidad AFC — prototipo del núcleo contable

App web de contabilidad para Amigos for Christ sobre **Supabase** (PostgreSQL). La base de datos hace cumplir las reglas contables y la app web es una sola página que se publica en GitHub Pages.

## Archivos

| Archivo | Qué es |
|---|---|
| `schema.sql` | Toda la base de datos: tablas, reglas de partida doble, períodos, roles, seguridad, reportes y un catálogo de ejemplo. |
| `index.html` | La app web completa (no necesita compilar nada). |
| `logo.png`, `logo-blanco.png` | Logos oficiales de Amigos for Christ. |
| `pruebas/prueba-esquema.mjs` | 40 pruebas automáticas de las reglas contables (opcional). |

## Qué hace

- **Catálogo de cuentas** jerárquico por código (`6.1.03` vive dentro de `6.1`). Las cuentas de agrupación suman a sus subcuentas.
- **Asientos de partida doble.** Se guardan en borrador y luego se contabilizan. Al contabilizar, la base de datos verifica que Debe = Haber, que haya al menos dos líneas y que no se use una cuenta de agrupación. Asigna el número correlativo del año.
- **Asientos en dólares.** Se registra el monto en US$ y se convierte a C$ con el tipo de cambio del día. Si el redondeo deja centavos de diferencia, se ajustan solos.
- **Nada contabilizado se edita.** Para corregir un asiento se anula, con motivo obligatorio, y se registra uno nuevo. Los asientos se pueden duplicar.
- **Períodos mensuales.** Un mes cerrado no acepta asientos, cambios ni anulaciones. Solo el administrador cierra y reabre.
- **Cierre del ejercicio.** Genera el asiento que lleva ingresos, costos y gastos a cero contra resultados acumulados.
- **Reportes:** libro diario, libro mayor con saldo acumulado, balanza de comprobación, estado de resultados (filtrable por centro de costo) y balance general. Todos se imprimen y exportan a CSV.
- **Centros de costo** por programa o área, y **tipos de cambio** (se pueden pegar varios días desde Excel).
- **Usuarios y roles:** Administrador, Contador y Consulta. El primer usuario que se registra queda como administrador.
- **Bitácora** de quién cambió qué y cuándo.

La seguridad vive en la base de datos (RLS), no en la página. Aunque alguien manipule la app, un usuario de consulta no puede escribir. Nadie puede modificar un asiento directamente en las tablas.

## Puesta en marcha

### 1. Crear el proyecto en Supabase
1. Entre a [supabase.com](https://supabase.com) y cree un proyecto nuevo. Elija la región más cercana, por ejemplo US East, y guarde la contraseña de la base de datos.
2. Vaya a **SQL Editor → New query**, pegue todo el contenido de `schema.sql` y presione **Run**. Debe terminar sin errores.
3. En **Project Settings → API** copie la **Project URL** y la clave **anon public**.

### 2. Publicar la app
1. Cree un repositorio en la organización `Amigos-for-Christ-INC`, por ejemplo `Contabilidad-AFC`. Suba `index.html`, `logo.png` y `logo-blanco.png`.
2. Active **Settings → Pages** con la rama `main`.
3. La URL del proyecto y la clave pública ya están puestas en `index.html` (`const CONFIG`). Esa clave es pública por diseño; la protección la da RLS.
4. En Supabase, en **Authentication → URL Configuration**, ponga la dirección de GitHub Pages como **Site URL** y agréguela a **Redirect URLs**.

### 3. Primer ingreso
1. Abra la app y **regístrese usted primero**: quedará como Administrador. Si Supabase pide confirmar el correo, confírmelo antes de entrar.
2. Los demás usuarios entran como **Consulta**. Asígneles su rol en **Usuarios**.
3. Revise el **catálogo de ejemplo** con el contador. Ajuste los códigos y nombres antes de registrar movimientos, porque una cuenta con movimientos ya no puede cambiar de código.
4. Registre los saldos iniciales con un asiento de tipo **Apertura**.

### 4. Entrar con Microsoft 365 (opcional, recomendado)
1. En **Microsoft Entra ID → App registrations → New registration**, use como redirect URI (Web) `https://<su-proyecto>.supabase.co/auth/v1/callback`.
2. Cree un **client secret** y copie el **Application (client) ID** y el **Directory (tenant) ID**.
3. En Supabase, en **Authentication → Providers → Azure**, actívelo y pegue el ID y el secreto. En **Azure Tenant URL** ponga `https://login.microsoftonline.com/<tenant-id>`, para que solo entren cuentas de la organización.
4. El botón **Entrar con Microsoft** funcionará desde ese momento.

## Pruebas
Las reglas contables se probaron contra PostgreSQL. Las pruebas cubren cuadre, conversión de dólares, permisos, períodos cerrados, anulación, cierre anual y que se cumpla Activo = Pasivo + Patrimonio.

La app también se recorrió completa en un navegador: login, asientos en C$ y US$, borradores, anulación, reportes, catálogo, períodos, vista móvil y usuario de consulta.

Para correr las pruebas del esquema:
```
npm install @electric-sql/pglite
node pruebas/prueba-esquema.mjs
```
Ejecútelo desde la carpeta donde está `schema.sql`.

## Pendiente para siguientes fases
- Inventario, compras/CxP, ventas/CxC y bancos, que generarían sus asientos automáticamente.
- Informes en formato VET (crédito fiscal, retenciones, detalle de ingresos), validados con el contador.
- Comparativo mensual en el estado de resultados y presupuesto contra lo real.
- Activos fijos con depreciación automática.
- Respaldos: verifique qué respaldos incluye su plan de Supabase y programe una copia periódica propia (por ejemplo, `pg_dump`). Pruebe restaurarla.

## Notas
- El catálogo incluido es solo un ejemplo; debe adaptarlo el contador.
- Moneda funcional: córdobas. Los reportes salen en C$.
- El rojo de errores y alertas está fuera de la paleta de la marca; se usa solo para avisos.
