-- id: E3
-- titulo: Cliente pede para remarcar: vez do time, 4 h, e a Mari não promete data
-- tipo: regra_nova
select sim.venda_pronta('Caco E3') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '85' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.como('servico');
select count(*) from sim.cadencia(sim.meio_dia());
select sim.cliente_escreve(:'c', 'Preciso remarcar');
select sim.fila_rodar();
select sim.confere('vez do time para remarcar', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('com prazo de até 4 h', (sim.lead_de(:'c') ->> 'prazo')::timestamptz <= now() + interval '4 hours 5 minutes', sim.lead_de(:'c')::text);
