-- id: X52
-- titulo: Live (0324): venda com o time, o time falou por último e a janela de 24 h do cliente fechou — a linha "Janela fechada" sobe no Conferir (no lugar do Parada com dono); Não atendeu e Template tiram a linha por 24 h, a porta anota e concorda; template sai pela fila; com a janela aberta o template é recusado
-- tipo: atual
-- Caso Gabriel L-154 (19/11): crédito aprovado, o Ricardo falou por último e a janela fechou; a Live dizia "esperando o cliente".
select sim.lead_com_venda('Gil X52') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Vamos seguir com o seu pedido?');
select sim.fila_rodar();

-- 20 h: janela aberta — nada sobe
select sim.passa(:'c', '20 hours');
select sim.como('backoffice');
select sim.confere('janela aberta (20 h): sem linha de janela fechada', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'janela_fechada' and e ->> 'conversa_id' = :'c'), 'subiu cedo');
select sim.confere('janela aberta: o template é recusado', sim.recusa(format('select public.venda_janela(%L, %L)', :'c', 'template')) like '%ainda está aberta%',
  sim.recusa(format('select public.venda_janela(%L, %L)', :'c', 'template')));

-- 30 h: janela fechada — sobe como Janela fechada, e não como Parada com dono
select sim.passa(:'c', '10 hours');
select sim.como('backoffice');
select sim.confere('janela fechada: a Live pede ligar ou template', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'janela_fechada' and e ->> 'conversa_id' = :'c' and e ->> 'texto' like 'Janela fechada há%ligue para%template%'),
  (select coalesce(string_agg(e ->> 'tipo', ', '), 'nada') from jsonb_array_elements(public.live_conferir()) e where e ->> 'conversa_id' = :'c'));
select sim.confere('o Parada com dono não repete a mesma conversa', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'dono_parado' and e ->> 'conversa_id' = :'c'), 'dono_parado também');

-- ação inválida
select sim.confere('ação inválida é recusada', sim.recusa(format('select public.venda_janela(%L, %L)', :'c', 'talvez')) like '%inválida%',
  sim.recusa(format('select public.venda_janela(%L, %L)', :'c', 'talvez')));

-- Não atendeu: a linha sai, autor gravado, nota pela fila, a porta anota e concorda
select public.venda_janela(:'c', 'nao_atendeu') ->> 'resumo' as r1 \gset
select sim.confere('Não atendeu responde', :'r1' like '%Não atendeu%', :'r1');
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('Não atendeu: a linha sai e o Parada com dono não entra no lugar', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' in ('janela_fechada', 'dono_parado') and e ->> 'conversa_id' = :'c'),
  (select coalesce(string_agg(e ->> 'tipo', ', '), 'nada') from jsonb_array_elements(public.live_conferir()) e where e ->> 'conversa_id' = :'c'));
select sim.como('servico');
select sim.confere('a tentativa ficou gravada com autor', (select janela_acao = 'nao_atendeu' and janela_acao_por is not null from public.mari_conversas where id = :'c')
  and exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'sistema' and t.texto like '[janela fechada · 📞%não atendeu%'),
  (select row(janela_acao, janela_acao_por)::text from public.mari_conversas where id = :'c'));
select sim.confere('a nota foi para o Chatwoot pela fila', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.momento = 'janela' and a.tipo = 'nota' and a.payload ->> 'content' like 'Janela fechada · 📞%'), 'sem nota');
select coalesce((select coalesce(concorda::text, 'null') || ' · ' || antes || ' → ' || depois from public.porta_sombra
  where evento = 'janela_acao:nao_atendeu' and conversa_id = :'c' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta anota o evento e concorda (situação não muda)', :'k' like 'true%', :'k');

-- 25 h depois, ainda calado: volta, com a última tentativa no texto
select sim.passa(:'c', '25 hours');
select sim.como('backoffice');
select sim.confere('seguiu calado: a linha volta no dia seguinte com a última tentativa', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'janela_fechada' and e ->> 'conversa_id' = :'c' and e ->> 'texto' like '%última tentativa%não atendeu%'),
  (select coalesce(string_agg(e ->> 'texto', ' | '), 'nada') from jsonb_array_elements(public.live_conferir()) e where e ->> 'conversa_id' = :'c'));

-- Template: sai pela fila com o template do degrau, a conversa segue com o time
select public.venda_janela(:'c', 'template') ->> 'resumo' as r2 \gset
select sim.confere('Template responde', :'r2' like '%Template mandado%', :'r2');
select sim.como('servico');
select sim.confere('o template foi para a fila do Chatwoot', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.momento = 'janela' and a.tipo = 'mensagem' and a.payload ->> 'template' in ('nio_oportunidade_retomada', 'nio_lembrete_biometria_v2')),
  (select coalesce(string_agg(a.tipo || ' ' || coalesce(a.payload ->> 'template', '-'), ' | '), 'nada') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'janela'));
select sim.fila_rodar();
select sim.confere('a conversa segue com o time', (sim.foto(:'c') ->> 'humano')::boolean, sim.foto(:'c')::text);

-- o cliente responde: a linha não volta (a vez é do time pelo Para fazer)
select sim.cliente_escreve(:'c', 'oi, pode seguir sim', false) as r3 \gset
select sim.fila_rodar();
select sim.passa(:'c', '25 hours');
select sim.como('backoffice');
select sim.confere('o cliente respondeu: sem linha de janela fechada', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'janela_fechada' and e ->> 'conversa_id' = :'c'), 'a linha voltou');
