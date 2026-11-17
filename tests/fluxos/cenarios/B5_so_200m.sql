-- id: B5
-- titulo: Viável só pelos 200 m (portal diz sem viabilidade): a escada pede conferir, vez do time, 4 h
-- tipo: atual
select sim.lead_com_venda('Tom B5') as c \gset
select sim._servico();
update public.mari_conversas set cobertura_decisao = 'elegivel_200m', nio_viab_resultado = 'sem_viabilidade' where id = :'c';
update public.vendas set nio_viab_resultado = 'sem_viabilidade' where id = sim.venda(:'c');
select sim.confere('não virou Saída', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('a escada pede conferir os 200 m, vez do time', sim.lead_de(:'c') ->> 'status' = 'conferir_200m' and sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('com prazo', sim.lead_de(:'c') ->> 'prazo' is not null, sim.lead_de(:'c')::text);
