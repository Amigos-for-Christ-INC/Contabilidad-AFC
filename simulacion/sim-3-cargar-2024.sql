-- Simulación: cargar el año 2024
select sim_maestros();
select sim_marcaje(2024);
select sim_planillas(2024, 1, 6);
select sim_planillas(2024, 7, 12);
select sim_contabilidad(2024, 1); select sim_cheques(2024, 1); select sim_inventario(2024, 1);
select sim_contabilidad(2024, 2); select sim_cheques(2024, 2); select sim_inventario(2024, 2);
select sim_contabilidad(2024, 3); select sim_cheques(2024, 3); select sim_inventario(2024, 3);
select sim_contabilidad(2024, 4); select sim_cheques(2024, 4); select sim_inventario(2024, 4);
select sim_contabilidad(2024, 5); select sim_cheques(2024, 5); select sim_inventario(2024, 5);
select sim_contabilidad(2024, 6); select sim_cheques(2024, 6); select sim_inventario(2024, 6);
select sim_contabilidad(2024, 7); select sim_cheques(2024, 7); select sim_inventario(2024, 7);
select sim_contabilidad(2024, 8); select sim_cheques(2024, 8); select sim_inventario(2024, 8);
select sim_contabilidad(2024, 9); select sim_cheques(2024, 9); select sim_inventario(2024, 9);
select sim_contabilidad(2024, 10); select sim_cheques(2024, 10); select sim_inventario(2024, 10);
select sim_contabilidad(2024, 11); select sim_cheques(2024, 11); select sim_inventario(2024, 11);
select sim_contabilidad(2024, 12); select sim_cheques(2024, 12); select sim_inventario(2024, 12);
select sim_activos(2024);
select * from sim_resumen() limit 15;
