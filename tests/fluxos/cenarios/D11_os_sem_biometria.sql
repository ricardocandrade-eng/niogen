-- id: D11
-- titulo: Gravar OS sem biometria aprovada é recusado
-- tipo: atual
select sim.lead_com_venda('Vera D11') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select coalesce(sim.recusa(format('select public.backoffice_momento(%L, %L, %L)', sim.venda(:'c'), 'os_agendar',
  jsonb_build_object('os', '98' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'))), '') as rec \gset
select sim.confere('o banco recusou gravar a OS sem biometria', :'rec' <> '', coalesce(nullif(:'rec', ''), 'aceitou: a OS foi gravada sem biometria aprovada'));
select sim.fila_rodar();
