-- id: X19
-- titulo: Reta final 3/C7 e 4 (0276): o time responde sem Assumir a um lead da Mari → "Com o time" (a Mari para); a lista de divergências mostra só o que a tabela de hoje ainda não explica
-- tipo: atual
-- (1) pelo NIOGEN (Responder)
select sim.lead_novo('Rui X19') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s0 \gset
select sim.confere('antes: a Mari atende', :'s0' = 'mari_atendendo', :'s0');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, aqui é do time da Dharma!');
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('Responder sem Assumir: a vez é do time (situação "Com o time")', :'s1' in ('time_agora', 'time_esperando'), :'s1');
select coalesce((select concorda::text from public.porta_sombra where conversa_id = :'c' and evento = 'time_respondeu' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta anota de acordo com a tabela', :'k' = 'true', :'k');
select sim.cliente_escreve(:'c', 'pode falar') as r \gset
select sim.confere('a Mari não responde por cima do time', :'r' like 'calada%', :'r');

-- (fora daqui) resposta digitada direto no Chatwoot sem atribuir: no simulador a Mari continua — o Chatwoot é só reserva
-- (regra de ouro 5); achado da reta final 18/11, a decidir com o Ricardo.

-- (2) a lista de divergências: o que foi consertado (0266, 0272) fica marcado e sai da lista
select sim._servico();
select count(*) as sup from public.porta_sombra where superada is not null and concorda is distinct from true \gset
select count(*) as vis from public.v_porta_divergencias d join public.porta_sombra s using (id) where s.superada is not null \gset
select count(*) as c7 from public.porta_sombra where superada like '0266%' and em >= (select min(em) from public.porta_sombra where 'time_esperando' in (antes, depois)) \gset
select sim.confere('divergência já consertada não aparece na lista', :'vis'::int = 0, 'superadas=' || :'sup' || ' visiveis=' || :'vis');
select sim.confere('a marca do C7 não pega nada depois da 0266', :'c7'::int = 0, :'c7');
