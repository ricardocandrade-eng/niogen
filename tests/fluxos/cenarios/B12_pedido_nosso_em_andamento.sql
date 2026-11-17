-- id: B12
-- titulo: Portal diz "pedido em andamento" de um pedido que é nosso (crédito gravado na ficha): não vira "já é cliente Nio"
-- tipo: atual
select sim.lead_com_venda('Xavi B12') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim._servico();
select public.mari_dup_gravar(:'c', '{"resultado":"pedido_em_andamento"}'::jsonb) as r \gset
select sim.confere('o portal leu o pedido como nosso', :'r'::jsonb ->> 'resultado' = 'pedido_nosso', :'r');
select sim.confere('o lead não virou "já é cliente Nio"', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
