-- id: X50
-- titulo: 0322 (Ricardo, 19/11): lead sem venda que o time assumiu e o cliente parou de responder — quando a janela do CLIENTE fecha (24 h desde a última mensagem dele), volta sozinho para a Mari e a cadência dela segue; com crédito aprovado fica com o time
-- tipo: atual
-- Caso: 13 leads no nome do Ricardo parados no Radar da Live ("Com você · esperando o cliente"); a volta da 0227 só pegava conversa
-- resolvida e contava 24 h desde a fala do TIME.
select sim.lead_novo('Ana X50') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.lead_novo('Bia X50') as c2 \gset
select sim.mari_fala(:'c2', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c'));
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c2'));
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Conseguiu ver os planos que te mandei?');
select public.backoffice_responder(:'c2', 'Oi! Seu crédito foi aprovado, vamos seguir?');
select sim.fila_rodar();
select sim.como('servico');
update public.mari_conversas set credito_resultado = 'aprovado_todas' where id = :'c2';   -- premissa: a Bia é venda (crédito aprovado)
select sim.confere('o time assumiu e falou por último', (sim.foto(:'c') ->> 'humano')::boolean and sim.cw_de(:'c') ->> 'agente' is not null, sim.foto(:'c')::text);

-- 20 h: a janela do cliente ainda está aberta — fica com o time
select sim.passa(:'c', '20 hours');
select sim.passa(:'c2', '20 hours');
select public._conversas_volta_mari();
select sim.fila_rodar();
select sim.confere('janela aberta (20 h): segue com o time', (sim.foto(:'c') ->> 'humano')::boolean, sim.foto(:'c')::text);

-- 25 h: a janela fechou — volta para a Mari pela peça do Devolver
select sim.passa(:'c', '5 hours');
select sim.passa(:'c2', '5 hours');
select public._conversas_volta_mari();
select sim.fila_rodar();
select sim.confere('janela fechada: sem dono e sem time no NIOGEN e no Chatwoot',
  not (sim.foto(:'c') ->> 'humano')::boolean and not (sim.foto(:'c') ->> 'time')::boolean
  and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.foto(:'c')::text);
select sim.confere('ficou a nota da janela fechada no Chatwoot', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'nota' and a.payload ->> 'content' like '%janela do WhatsApp fechou%'), 'sem nota');
select coalesce((select coalesce(concorda::text, 'null') || ' · ' || coalesce(antes, '?') || ' → ' || coalesce(depois, '?') from public.porta_sombra
  where origem = 'janela_fechada' and conversa_id = :'c' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta anota a volta (origem janela_fechada) e concorda', :'k' like 'true%', :'k');
select sim.cadencia_ver(:'c')::text as cad \gset
select sim.confere('a cadência da Mari volta a ter próximo passo', (:'cad')::jsonb ->> 'proximo' is not null, :'cad');
select sim.confere('com crédito aprovado (é venda) fica com o time', (sim.foto(:'c2') ->> 'humano')::boolean, sim.foto(:'c2')::text);

-- não repete: rodar de novo não mexe
select count(*) as acoes_antes from public.chatwoot_acoes where conversa_id = :'c' \gset
select public._conversas_volta_mari();
select sim.fila_rodar();
select sim.confere('rodar de novo não faz nada', (select count(*) from public.chatwoot_acoes where conversa_id = :'c') = :acoes_antes,
  (select count(*)::text from public.chatwoot_acoes where conversa_id = :'c'));

-- o cliente escreve depois: a Mari atende
select sim.cliente_escreve(:'c', 'oi, voltei! ainda dá para ver?') as r \gset
select sim.fila_rodar();
select sim.confere('o cliente voltou: a Mari respondeu', :'r' = 'respondeu', :'r');

-- handoff sem resposta do time (a última fala é da Mari, quem espera é o cliente): NÃO volta para a Mari (casos C4/X31)
select sim.lead_novo('Cida X50') as c3 \gset
select sim.mari_handoff(:'c3', 'quer_humano');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c3', '25 hours');
select (sim.foto(:'c3') ->> 'time')::boolean as tinha_time \gset
select public._conversas_volta_mari();
select sim.fila_rodar();
select sim.confere('handoff esperando o time: a janela fechar não devolve para a Mari',
  (sim.foto(:'c3') ->> 'time')::boolean = :'tinha_time'::boolean
  and not exists (select 1 from public.porta_sombra where origem = 'janela_fechada' and conversa_id = :'c3'), sim.foto(:'c3')::text);
