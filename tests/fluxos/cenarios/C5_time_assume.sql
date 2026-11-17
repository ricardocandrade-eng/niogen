-- id: C5
-- titulo: Time assume pelo NIOGEN
-- tipo: atual
select sim.lead_com_venda('Iara C5') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.confere('a conversa tem dono no Chatwoot', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'oi') as r \gset
select sim.confere('a Mari fica calada', :'r' like 'calada%', :'r');
select sim.confere('a vez é do time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
