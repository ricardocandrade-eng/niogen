-- id: D5
-- titulo: Crédito pendente: vez do time com prazo curto
-- tipo: atual
select sim.lead_com_venda('Zeca D5') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"pendente"}');
select sim.fila_rodar();
select sim.confere('vez do time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('alerta em até 2 h', (sim.lead_de(:'c') ->> 'prazo')::timestamptz <= now() + interval '2 hours 5 minutes', sim.lead_de(:'c')::text);
