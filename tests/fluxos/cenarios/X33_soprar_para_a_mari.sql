-- id: X33
-- titulo: Soprar para a Mari (0299): o time escreve, o cliente recebe como fala da Mari, a Mari segue dona e com o contexto; com o time, em Saída ou fora da janela, recusa
-- tipo: atual
-- Ricardo, ponderação 3 de 16/11 ("o dono não muda, ninguém precisa assumir e devolver"; "fora da janela de 24 h o botão fica desligado").
-- (1) com a Mari atendendo: o sopro sai na voz da Mari e ninguém assume
select sim.lead_novo('Lia X33') as c \gset
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '?') as s0 \gset
select sim.como('backoffice');
select public.mari_soprar(:'c', 'Oi Lia! Consegui ver aqui: o plano de 700 mega sai por R$ 99,90 no seu endereço.') ->> 'resumo' as r1 \gset
select sim.confere('o sopro é aceito com a Mari atendendo', :'r1' like '%soprado%', :'r1');
select sim.fila_rodar();
select sim.confere('saiu ao cliente na voz da Mari (token do bot, não de pessoa)',
  exists (select 1 from sim.envios where conversa = :'c' and por = 'fila' and texto like 'Oi Lia! Consegui ver aqui%')
  and not exists (select 1 from sim.envios where conversa = :'c' and por = 'time'));
select sim.confere('ficou gravado como fala da Mari, com quem soprou',
  exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'mari' and t.tags ->> 'backoffice' = 'sopro'
           and t.tags ->> 'por' is not null and t.texto like 'Oi Lia! Consegui ver aqui%'),
  (select string_agg(papel || ' · ' || coalesce(tags::text, ''), ' | ') from public.mari_turnos where conversa_id = :'c'));
select sim.confere('ninguém assumiu: sem dono no Chatwoot', sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
select sim.confere('a situação não mudou', coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '?') = :'s0',
  :'s0' || ' → ' || coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '?'));
select sim.confere('a porta anotou o sopro e concorda (situação "=")',
  exists (select 1 from public.porta_sombra s where s.conversa_id = :'c' and s.evento = 'soprar' and s.concorda),
  (select string_agg(evento || ' ' || coalesce(antes, '?') || '→' || coalesce(depois, '?') || ' ' || coalesce(concorda::text, 'null'), ' | ')
     from public.porta_sombra where conversa_id = :'c'));
select sim.cliente_escreve(:'c', 'nossa, que bom! como faço pra contratar?') as r2 \gset
select sim.confere('o cliente responde e a Mari continua a conversa (não ficou calada)', :'r2' = 'respondeu', :'r2');

-- (2) com o time (assumida): soprar é recusado — quem fala é o dono
select sim.lead_novo('Davi X33') as d \gset
select public.backoffice_responder(:'d', 'Oi Davi, aqui é do time da Dharma.');
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.mari_soprar(%L, 'teste de sopro com dono')$q$, :'d')), '') as e2 \gset
select sim.confere('com o time, o sopro é recusado (responda direto)', :'e2' like '%responda direto%', coalesce(nullif(:'e2', ''), 'aceitou'));

-- (3) fora da janela de 24 h: recusa e diz por quê
select sim.lead_novo('Bia X33') as b \gset
select sim.passa(:'b', '25 hours');
select coalesce(sim.recusa(format($q$select public.mari_soprar(%L, 'oi, ainda tem interesse?')$q$, :'b')), '') as e3 \gset
select sim.confere('fora da janela de 24 h, o sopro é recusado', :'e3' like '%janela de 24 h%', coalesce(nullif(:'e3', ''), 'aceitou'));

-- (4) em Saída: recusa (reabra antes)
select sim.lead_novo('Rui X33') as s \gset
select public.lead_sair(:'s', null, 'recusou', 'preco');
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.mari_soprar(%L, 'oi Rui')$q$, :'s')), '') as e4 \gset
select sim.confere('em Saída, o sopro é recusado', :'e4' like '%Saída%', coalesce(nullif(:'e4', ''), 'aceitou'));

-- (5) só admin/backoffice
select sim.como('vendedor');
select coalesce(sim.recusa(format($q$select public.mari_soprar(%L, 'oi Lia')$q$, :'c')), '') as e5 \gset
select sim.confere('vendedor não sopra', :'e5' <> '', coalesce(nullif(:'e5', ''), 'aceitou'));
select sim.como('servico');
