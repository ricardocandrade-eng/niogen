-- id: X72
-- titulo: Fase 2, passo 4 (0346): a Mari pergunta à porta "pode falar?" e pede ao banco o que hoje faz direto no Chatwoot — a resposta vem da situação; o handoff vira ordem na fila sem apagar as outras etiquetas
-- tipo: atual
-- Lado do banco do passo 4 (Ricardo, 21/11: "Sim, prepara"). O n8n ainda não chama estas funções (rascunho n8n/rascunhos/passo4_191126/).
select sim.lead_novo('Lia X72') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.fila_rodar();
select sim.como('servico');
select sim._conv(:'c') as cw \gset

-- (1) Mari atendendo: pode responder e pode mandar o lembrete da escada
select public.mari_pode_falar(:'cw', 'resposta')::text as r1 \gset
select sim.confere('Mari atendendo: a Mari pode responder', (:'r1'::jsonb ->> 'pode')::boolean and :'r1'::jsonb ->> 'situacao' = 'mari_atendendo', :'r1');
select public.mari_pode_falar(:'cw', 'lembrete', 'D1')::text as r2 \gset
select sim.confere('Mari atendendo: o lembrete da escada sai', (:'r2'::jsonb ->> 'pode')::boolean and not (:'r2'::jsonb ->> 'parar')::boolean, :'r2');

-- (2) uma pessoa do time assume: a Mari cala e a escada para; o aviso da venda continua saindo
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('servico');
select public.mari_pode_falar(:'cw', 'resposta')::text as r3 \gset
select sim.confere('com uma pessoa do time na conversa a Mari não responde', not (:'r3'::jsonb ->> 'pode')::boolean and (:'r3'::jsonb ->> 'pessoa')::boolean, :'r3');
select public.mari_pode_falar(:'cw', 'lembrete', 'D1')::text as r4 \gset
select sim.confere('com o time, o lembrete da escada não sai e a escada para', not (:'r4'::jsonb ->> 'pode')::boolean and (:'r4'::jsonb ->> 'parar')::boolean, :'r4');
select public.mari_pode_falar(:'cw', 'lembrete', 'INSTALACAO')::text as r5 \gset
select sim.confere('aviso da venda sai mesmo com o time (regra de ouro 6) e nunca para a escada', (:'r5'::jsonb ->> 'pode')::boolean and not (:'r5'::jsonb ->> 'parar')::boolean, :'r5');

-- (3) handoff de venda pedido ao banco: vira ordem na fila pela porta (etiqueta por add/remove, nota, time) e não apaga outras etiquetas
select sim.lead_novo('Rui X72') as d \gset
select sim.mari_fala(:'d', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.fila_rodar();
select sim.como('servico');
select sim._conv(:'d') as cwd \gset
select sim.cw_mudar(:'cwd', '{"add": ["indicacao"]}'::jsonb);
select max(id) as base from public.chatwoot_acoes \gset
-- como no fluxo novo: o nó "9 · Handoff" (rpc mari_handoff) vem antes do pedido ao Chatwoot, e a Mari não mexe mais no Chatwoot
-- (o sim.mari_handoff imita a Mari de hoje, que põe etiqueta e time direto — por isso aqui a chamada é a do banco)
select public.mari_handoff(:'d', 'dados_completos', '{"plano": "500 mega"}'::jsonb);
select public.mari_chatwoot_pedir(:'cwd', 'handoff_venda', 'Briefing X72: cliente quer o plano de 500 mega')::text as h \gset
select sim.confere('o pedido de handoff responde ok e diz o que foi para a fila', (:'h'::jsonb ->> 'ok')::boolean
  and :'h'::jsonb -> 'feito' ?& array['etiquetas', 'nota', 'time'], :'h');
select sim.confere('as ordens entraram na fila pela porta, com origem mari_handoff, e a etiqueta é add/remove (nunca a lista inteira)',
  (select count(*) from public.chatwoot_acoes where id > :base and conversa_id = :'d' and momento = 'mari_handoff') = 3
  and not exists (select 1 from public.chatwoot_acoes where id > :base and conversa_id = :'d' and tipo = 'etiquetas' and payload ? 'labels'),
  (select string_agg(momento || ':' || tipo || ' ' || payload::text, ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'d'));
select sim.confere('o time vira dono no NIOGEN (situação com o time) e vai uma vez só ao Chatwoot, pelo pedido da Mari',
  (select count(*) from public.chatwoot_acoes where id > :base and conversa_id = :'d' and tipo = 'atribuir' and payload ? 'team_id') = 1,
  (select string_agg(momento || ':' || tipo || ' ' || payload::text, ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'d' and tipo = 'atribuir'));
select sim.fila_rodar();
select sim.confere('no Chatwoot: handoff e handoff-venda postas, a etiqueta que já existia ficou, e o time é o backoffice',
  (select etiquetas @> array['handoff', 'handoff-venda', 'indicacao'] and time_nome is not null from sim.cw where conv = :'cwd'),
  (select row_to_json(w)::text from sim.cw w where conv = :'cwd'));
select max(id) as base2 from public.chatwoot_acoes \gset
select public.mari_chatwoot_pedir(:'cwd', 'handoff_venda', null);
select sim.confere('o mesmo pedido de novo, com o time já na conversa, não manda o time outra vez',
  not exists (select 1 from public.chatwoot_acoes where id > :base2 and conversa_id = :'d' and tipo = 'atribuir'),
  (select string_agg(tipo, ' ') from public.chatwoot_acoes where id > :base2 and conversa_id = :'d'));
select sim.confere('na sombra do projetor, as ordens da Mari não vão contra a situação',
  not exists (select 1 from public.projetor_sombra where conversa_id = :'d' and acao_id > :base and veredito in ('contraria', 'erro')),
  (select string_agg(tipo || ':' || veredito || coalesce(' ' || motivo, ''), ' · ') from public.projetor_sombra
    where conversa_id = :'d' and acao_id > :base and veredito in ('contraria', 'erro')));

-- (4) "zerar" só em telefone de teste; pedido desconhecido é recusado; conversa que o banco não conhece: a Mari pode responder
select sim.confere('"zerar" é recusado fora de telefone de teste', not (public.mari_chatwoot_pedir(:'cwd', 'zerar') ->> 'ok')::boolean,
  public.mari_chatwoot_pedir(:'cwd', 'zerar')::text);
select sim.confere('pedido desconhecido é recusado', not (public.mari_chatwoot_pedir(:'cwd', 'apagar_tudo') ->> 'ok')::boolean,
  public.mari_chatwoot_pedir(:'cwd', 'apagar_tudo')::text);
select sim.confere('conversa que o banco ainda não conhece: a Mari pode responder (o mari_entrada cria)',
  (public.mari_pode_falar('999999-x72', 'resposta') ->> 'pode')::boolean, public.mari_pode_falar('999999-x72', 'resposta')::text);

-- (5) Saída: o aviso da venda não sai
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.como('servico');
select public.mari_pode_falar(:'cw', 'lembrete', 'INSTALACAO')::text as r6 \gset
select sim.confere('lead em Saída: nem o aviso da venda sai', not (:'r6'::jsonb ->> 'pode')::boolean, :'r6');

-- (6) quem é do backoffice ou vendedor não chama as funções da Mari (só o n8n, com a chave de serviço)
select sim.confere('as funções da Mari não estão abertas a quem está logado',
  not has_function_privilege('authenticated', 'public.mari_pode_falar(text, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.mari_chatwoot_pedir(text, text, text)', 'execute'), '');
