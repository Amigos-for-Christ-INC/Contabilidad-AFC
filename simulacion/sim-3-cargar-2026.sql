-- Simulación: cargar el año 2026
select sim_marcaje(2026);
select sim_planillas(2026, 1, 6);
select sim_planillas(2026, 7, 12);
select sim_contabilidad(2026, 1); select sim_cheques(2026, 1); select sim_inventario(2026, 1);
select sim_contabilidad(2026, 2); select sim_cheques(2026, 2); select sim_inventario(2026, 2);
select sim_contabilidad(2026, 3); select sim_cheques(2026, 3); select sim_inventario(2026, 3);
select sim_contabilidad(2026, 4); select sim_cheques(2026, 4); select sim_inventario(2026, 4);
select sim_contabilidad(2026, 5); select sim_cheques(2026, 5); select sim_inventario(2026, 5);
select sim_contabilidad(2026, 6); select sim_cheques(2026, 6); select sim_inventario(2026, 6);
select sim_contabilidad(2026, 7); select sim_cheques(2026, 7); select sim_inventario(2026, 7);
select sim_contabilidad(2026, 8); select sim_cheques(2026, 8); select sim_inventario(2026, 8);
select sim_contabilidad(2026, 9); select sim_cheques(2026, 9); select sim_inventario(2026, 9);
select sim_contabilidad(2026, 10); select sim_cheques(2026, 10); select sim_inventario(2026, 10);
select sim_activos(2026);
select * from sim_resumen() limit 15;
