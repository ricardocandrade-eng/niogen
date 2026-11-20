-- id: X53
-- titulo: 0325 (caso Kell L-208): a Mari mostrou os planos e a viabilidade deu sem cobertura depois — 2 min sem ninguém avisar, o NIOGEN manda ao cliente a mensagem da Saída por cobertura (uma vez, pela porta, com nota); com o time na conversa, com Não contatar ou com a janela fechada, não manda
-- tipo: atual
-- 1) Ana: ninguém com a conversa → avisa
select sim.lead_novo('Ana X53') as c \gset
select sim.mari_fala(:'c', 'A Nio atende a sua cidade 🎯 A disponibilidade exata na sua rua o nosso time confirma. Olha as opções:');
select sim.fila_rodar();
select sim.como('servico');
update public.mari_conversas set cobertura_decisao = 'sem_cobertura', nio_viab_resultado = 'sem_viabilidade', cobertura_em = now() where id = :'c';
select sim.confere('o lead foi para Saída por cobertura', (select funil_destino from public.mari_conversas where id = :'c') = 'sem_cobertura',
  (select funil_destino from public.mari_conversas where id = :'c'));
select public._cobertura_avisa_veredito();
select sim.confere('antes de 2 min, nada (a Mari pode estar dizendo)', not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' like 'saida_sem_cobertura%'), 'saiu cedo');
select sim.passa(:'c', '3 minutes');
select public._cobertura_avisa_veredito();
select sim.confere('3 min depois: o cliente recebe o aviso de sem cobertura', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' like 'saida_sem_cobertura%' and a.status in ('pendente', 'executando', 'feita')),
  (select coalesce(string_agg(a.tipo || ' ' || a.status || ' ' || coalesce(a.payload ->> 'texto_chave', '-'), ' | '), 'nada') from public.chatwoot_acoes a where a.conversa_id = :'c'));
select sim.confere('ficou a nota no Chatwoot', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.tipo = 'nota' and a.payload ->> 'content' like '⛔ NIOGEN (viabilidade)%avisado%'), 'sem nota');
select sim.confere('marcou o veredito como avisado (a Mari sabe se ele voltar)',
  (select dados ->> 'sem_cobertura_avisado' = floor(extract(epoch from cobertura_em))::bigint::text and dados ? 'cobertura_avisada_em' from public.mari_conversas where id = :'c'),
  (select dados::text from public.mari_conversas where id = :'c'));
select coalesce((select coalesce(concorda::text, 'null') || ' · ' || antes || ' → ' || depois from public.porta_sombra
  where evento = 'aviso_sem_cobertura' and conversa_id = :'c' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta anota o aviso e concorda (situação não muda)', :'k' like 'true%', :'k');
select count(*) as n1 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem' \gset
select sim.fila_rodar();
select sim.passa(:'c', '5 minutes');
select public._cobertura_avisa_veredito();
select sim.confere('não repete', (select count(*) from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem') = :n1,
  (select count(*)::text from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem'));

-- 2) Bia: o time está com a conversa → não manda (o time avisa; a Live mostra ⛔)
select sim.lead_novo('Bia X53') as c2 \gset
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c2'));
select sim.fila_rodar();
select sim.como('servico');
update public.mari_conversas set cobertura_decisao = 'sem_cobertura', nio_viab_resultado = 'sem_viabilidade', cobertura_em = now() where id = :'c2';
select sim.passa(:'c2', '3 minutes');
select public._cobertura_avisa_veredito();
select sim.confere('com o time na conversa: não manda', not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c2'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' like 'saida_sem_cobertura%'), 'mandou com o time');

-- 3) Cida: janela fechada → não manda (texto livre não sai)
select sim.lead_novo('Cida X53') as c3 \gset
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c3', '25 hours');
update public.mari_conversas set cobertura_decisao = 'sem_cobertura', nio_viab_resultado = 'sem_viabilidade', cobertura_em = now() - interval '5 minutes' where id = :'c3';
select public._cobertura_avisa_veredito();
select sim.confere('janela fechada: não manda', not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c3'
  and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' like 'saida_sem_cobertura%'), 'mandou com a janela fechada');
-- 3b) a Meta aprova o template: a Cida (janela fechada, ninguém falou depois) recebe pelo template, uma vez
update public.config_templates_waba set status = 'APPROVED' where nome = 'nio_sem_cobertura';   -- premissa: aprovado na Meta
select public._cobertura_avisa_veredito();
select sim.confere('template aprovado: o aviso sai pelo template', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c3'
  and a.tipo = 'mensagem' and a.payload ->> 'template' = 'nio_sem_cobertura' and a.status in ('pendente', 'executando', 'feita')),
  (select coalesce(string_agg(a.tipo || ' ' || a.status || ' ' || coalesce(a.payload ->> 'template', '-') || ' ' || coalesce(a.payload ->> 'motivo', ''), ' | '), 'nada') from public.chatwoot_acoes a where a.conversa_id = :'c3'));
select public._cobertura_avisa_veredito();
select sim.confere('e não repete', (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c3' and a.tipo = 'mensagem' and a.payload ->> 'template' = 'nio_sem_cobertura') = 1,
  (select count(*)::text from public.chatwoot_acoes a where a.conversa_id = :'c3' and a.tipo = 'mensagem'));
