-- id: X42
-- titulo: Divergência 885 (19/11, Chatwoot 185): a Mari passa um lead com dados completos que só é viável pelos 200 m → a venda nasce "conferir os 200 m" (Com o time) e a porta concorda
-- tipo: atual
select sim.lead_pronto('Lia X42') as c \gset
select sim._servico();
update public.mari_conversas set cobertura_decisao = 'elegivel_200m', nio_viab_resultado = 'sem_viabilidade' where id = :'c';
select sim.mari_handoff(:'c', 'dados_completos');
select sim.fila_rodar();
select sim.confere('a venda nasceu', sim.venda(:'c') is not null, 'sem venda');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s \gset
select sim.confere('só 200 m: Com o time, conferir antes do crédito', :'s' = 'time_agora', :'s' || ' · ' || sim.lead_de(:'c')::text);
select coalesce((select concorda::text from public.porta_sombra where conversa_id = :'c' and evento = 'mari_passou:dados_completos' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta concorda com o sistema', :'k' = 'true', :'k');
