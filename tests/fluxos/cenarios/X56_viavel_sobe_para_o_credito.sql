-- id: X56
-- titulo: Divergência 979 (19/11, Mony): lead "conferir os 200 m" (Com o time); o BKO grava viabilidade viável → sobe para qualificado (crédito) e a porta concorda
-- tipo: atual
select sim.lead_com_venda('Mona X56') as c \gset
select sim._servico();
update public.mari_conversas set cobertura_decisao = 'elegivel_200m', nio_viab_resultado = 'sem_viabilidade' where id = :'c';
update public.vendas set nio_viab_resultado = 'sem_viabilidade' where id = sim.venda(:'c');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('antes: Com o time, conferir os 200 m', :'s1' = 'time_agora', :'s1' || ' · ' || sim.lead_de(:'c')::text);
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'viabilidade', '{"resultado":"viavel"}');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s2 \gset
select sim.confere('viável: subiu para qualificado', :'s2' like 'qualificado_%', :'s2' || ' · ' || sim.lead_de(:'c')::text);
select coalesce((select concorda::text from public.porta_sombra where conversa_id = :'c' and evento = 'momento:viabilidade:viavel' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta concorda com o sistema', :'k' = 'true', :'k');
