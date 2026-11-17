-- id: X8
-- titulo: Botão da ficha que a tabela não aceita: Assumir um lead em Saída é recusado com a frase (porta, 0268)
-- tipo: atual
select sim.lead_com_venda('Bruno X8') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'recusou', 'preco');
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'assumir')$q$, sim.venda(:'c'))), '') as rec \gset
select sim.confere('Assumir em Saída é recusado: "reabra antes"', :'rec' like '%reabra antes%', coalesce(nullif(:'rec', ''), 'aceitou'));
select sim.confere('a conversa continua sem dono', sim.cw_de(:'c') ->> 'agente' is null, sim.cw_de(:'c')::text);
select public.lead_reabrir(:'c', null);
select sim.fila_rodar();
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.confere('depois de reabrir, Assumir vale', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
