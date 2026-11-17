-- id: D12
-- titulo: OS gravada sem data: a escada pede agendar, vez do time, prazo de 4 h
-- tipo: atual
select sim.venda_pronta('Lena D12') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os', jsonb_build_object('os', '95' || sim._conv(:'c'), 'forma', 'boleto'));
select sim.fila_rodar();
select sim.confere('a venda foi contada (OS aberta)', sim.foto(:'c') -> 'venda' ->> 'status' = '1_vendido', (sim.foto(:'c') -> 'venda')::text);
select sim.confere('a escada pede agendar, vez do time', sim.lead_de(:'c') ->> 'status' = 'agendar' and sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('com prazo de cerca de 4 h', (sim.lead_de(:'c') ->> 'prazo')::timestamptz between now() + interval '3 hours' and now() + interval '5 hours',
  'prazo: ' || coalesce(sim.lead_de(:'c') ->> 'prazo', 'nenhum'));
