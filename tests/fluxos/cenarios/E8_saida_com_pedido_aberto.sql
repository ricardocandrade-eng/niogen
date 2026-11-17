-- id: E8
-- titulo: Saída de venda com OS aberta: o NIOGEN pergunta se cancelou no portal e cobra o cancelamento
-- tipo: atual
select sim.venda_pronta('Elis E8') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '83' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.recusa(format($q$select public.lead_sair(%L, %L, 'recusou', 'desistiu')$q$, :'c', sim.venda(:'c'))) as rec \gset
select sim.confere('sem dizer se cancelou no portal, a Saída é recusada', :'rec' like '%cancelado no portal%', coalesce(nullif(:'rec', ''), 'aceitou'));
select public.lead_sair(:'c', sim.venda(:'c'), 'recusou', 'desistiu', null, null, false) as r \gset
select sim.fila_rodar();
select sim.confere('a Saída ficou com "falta cancelar na Nio"', (:'r'::jsonb ->> 'pedido_aberto')::boolean, :'r');
select sim.confere('a venda está em Saída', sim.foto(:'c') -> 'venda' ->> 'status' = 'saida', (sim.foto(:'c') -> 'venda')::text);
