-- id: X4
-- titulo: Saída definitiva (crédito negado): o backoffice não reabre, o admin reabre (decisão a, 17/11)
-- tipo: atual
select sim.lead_com_venda('Vera X4') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'credito_negado');
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.lead_reabrir(%L, null)$q$, :'c')), '') as rec \gset
select sim.confere('o backoffice recebe a recusa com a frase', :'rec' like '%admin%', coalesce(nullif(:'rec', ''), 'aceitou'));
select sim.confere('continua em Saída definitiva', sim.lead_de(:'c') ->> 'destino' = 'saida' and sim.foto(:'c') -> 'venda' ->> 'status' = 'saida', sim.lead_de(:'c')::text);
select sim.como('admin');
select public.porta_motivo_preparar('teste do X4: nova consulta de crédito aprovada');   -- 0298: ação de admin pede o motivo
select public.lead_reabrir(:'c', null);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o admin reabriu: em andamento', sim.lead_de(:'c') ->> 'destino' = 'em_andamento' and sim.foto(:'c') -> 'venda' ->> 'status' <> 'saida', sim.lead_de(:'c')::text);
select sim.confere('conversa aberta e sem etiqueta de saída', sim.cw_de(:'c') ->> 'status' = 'open' and not ((sim.cw_de(:'c') -> 'etiquetas') ?| array['saida-credito']), sim.cw_de(:'c')::text);
