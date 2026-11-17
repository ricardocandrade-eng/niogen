-- id: X2
-- titulo: Saída de venda com a conversa assumida: os seis efeitos
-- tipo: atual
select sim.lead_com_venda('Paulo X2') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select public.lead_sair(:'c', sim.venda(:'c'), 'recusou', 'concorrente');
select sim.fila_rodar();
select sim.confere('a venda está em Saída', sim.foto(:'c') -> 'venda' ->> 'status' = 'saida', (sim.foto(:'c') -> 'venda')::text);
select sim.confere('a conversa está em Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.confere('resolvida, sem dono e sem time', sim.cw_de(:'c') ->> 'status' = 'resolved' and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
select sim.passa(:'c', '2 days');
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('nenhum lembrete sai', :n = 0, 'envios: ' || :n);
