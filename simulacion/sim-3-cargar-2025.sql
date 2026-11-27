-- Simulación: cargar el año 2025
select sim_marcaje(2025);
select sim_planillas(2025, 1, 6);
select sim_planillas(2025, 7, 12);
select sim_contabilidad(2025, 1); select sim_cheques(2025, 1); select sim_inventario(2025, 1);
select sim_contabilidad(2025, 2); select sim_cheques(2025, 2); select sim_inventario(2025, 2);
select sim_contabilidad(2025, 3); select sim_cheques(2025, 3); select sim_inventario(2025, 3);
select sim_contabilidad(2025, 4); select sim_cheques(2025, 4); select sim_inventario(2025, 4);
select sim_contabilidad(2025, 5); select sim_cheques(2025, 5); select sim_inventario(2025, 5);
select sim_contabilidad(2025, 6); select sim_cheques(2025, 6); select sim_inventario(2025, 6);
select sim_contabilidad(2025, 7); select sim_cheques(2025, 7); select sim_inventario(2025, 7);
select sim_contabilidad(2025, 8); select sim_cheques(2025, 8); select sim_inventario(2025, 8);
select sim_contabilidad(2025, 9); select sim_cheques(2025, 9); select sim_inventario(2025, 9);
select sim_contabilidad(2025, 10); select sim_cheques(2025, 10); select sim_inventario(2025, 10);
select sim_contabilidad(2025, 11); select sim_cheques(2025, 11); select sim_inventario(2025, 11);
select sim_contabilidad(2025, 12); select sim_cheques(2025, 12); select sim_inventario(2025, 12);
select sim_activos(2025);
select * from sim_resumen() limit 15;
