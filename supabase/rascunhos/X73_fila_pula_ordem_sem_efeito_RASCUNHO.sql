-- id: X73
-- titulo: Fase 2, passo 4 B1 (0347): a ordem que não muda nada no Chatwoot não sai — fica na fila como cancelada "sem efeito"; na dúvida, sai
-- tipo: atual
-- DEIXADO DE LADO 21/11 com a 0347 (ver o topo dela). Não roda no portão: está em rascunhos.
select sim.lead_novo('Ana X73') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.fila_rodar();
select sim.como('servico');
select sim._conv(:'c') as cw \gset
select sim.cw_mudar(:'cw', '{"add": ["indicacao"]}'::jsonb);

-- (1) etiqueta que já está e "tirar dono" de quem não tem dono: não saem
select max(id) as base from public.chatwoot_acoes \gset
select public._porta_ordem(gen_random_uuid(), 1, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'etiquetas',
  '{"add": ["indicacao"], "remove": ["handoff-humano"]}'::jsonb);
select public._porta_ordem(gen_random_uuid(), 1, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'desatribuir',
  '{"assignee_id": null, "team_id": null}'::jsonb);
select sim.fila_rodar();
select sim.confere('etiqueta que já estava e dono que já não havia: as duas ordens ficam canceladas "sem efeito" e não vão ao Chatwoot',
  (select count(*) from public.chatwoot_acoes where id > :base and conversa_id = :'c' and momento = 'teste_x73'
     and status = 'cancelada' and erro like 'sem efeito:%') = 2,
  (select string_agg(tipo || ':' || status || coalesce(' ' || erro, ''), ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'c'));

-- (2) etiqueta que muda algo sai
select max(id) as base from public.chatwoot_acoes \gset
select public._porta_ordem(gen_random_uuid(), 1, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'etiquetas',
  '{"add": [], "remove": ["indicacao"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('tirar uma etiqueta que está lá: a ordem sai',
  (select status from public.chatwoot_acoes where id > :base and conversa_id = :'c' and momento = 'teste_x73') = 'feita'
  and not (select 'indicacao' = any (etiquetas) from sim.cw where conv = :'cw'),
  (select row_to_json(w)::text from sim.cw w where conv = :'cw'));

-- (3) no mesmo clique, pôr o time e depois tirar: o "tirar" sai (o espelho ainda não conta com o "pôr")
select max(id) as base from public.chatwoot_acoes \gset
select gen_random_uuid() as g \gset
select public._porta_ordem(:'g', 1, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'atribuir', '{"team_id": 15102}'::jsonb);
select public._porta_ordem(:'g', 2, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'desatribuir', '{"team_id": null}'::jsonb);
select sim.fila_rodar();
select sim.confere('pôr e tirar o time no mesmo clique: as duas ordens saem e o Chatwoot fica sem time',
  (select count(*) from public.chatwoot_acoes where id > :base and conversa_id = :'c' and momento = 'teste_x73' and status = 'feita') = 2
  and (select time_nome is null from sim.cw where conv = :'cw'),
  (select string_agg(tipo || ':' || status || coalesce(' ' || erro, ''), ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'c'));

-- (4) o Chatwoot sem time, mas o NIOGEN ainda marca o time como dono: o "tirar o time" sai (é ele que limpa a marca)
select set_config('porta.aplicando', '1', false);
update public.mari_conversas set time_atribuido = true where id = :'c';
select set_config('porta.aplicando', '', false);
select max(id) as base from public.chatwoot_acoes \gset
select public._porta_ordem(gen_random_uuid(), 1, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'desatribuir', '{"team_id": null}'::jsonb);
select sim.fila_rodar();
select sim.confere('Chatwoot sem time e NIOGEN com o time: a ordem sai e a marca do time some',
  (select status from public.chatwoot_acoes where id > :base and conversa_id = :'c' and momento = 'teste_x73') = 'feita'
  and not (select coalesce(time_atribuido, false) from public.mari_conversas where id = :'c'),
  (select string_agg(tipo || ':' || status || coalesce(' ' || erro, ''), ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'c'));

-- (5) o espelho é mais velho que a última etiqueta feita (o aviso do Chatwoot ainda não chegou): na dúvida, a ordem sai
select set_config('porta.aplicando', '1', false);
update public.mari_conversas set chatwoot_sync_em = (select max(feita_em) from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'etiquetas') - interval '1 second'
 where id = :'c';
select set_config('porta.aplicando', '', false);
select max(id) as base from public.chatwoot_acoes \gset
select public._porta_ordem(gen_random_uuid(), 1, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'etiquetas',
  '{"add": [], "remove": ["indicacao"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('espelho mais velho que a última etiqueta feita: a ordem sai mesmo parecendo sem efeito',
  (select status from public.chatwoot_acoes where id > :base and conversa_id = :'c' and momento = 'teste_x73') = 'feita',
  (select string_agg(tipo || ':' || status || coalesce(' ' || erro, ''), ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'c'));

-- (6) a chave desliga: com fila_pula_sem_efeito = false, a ordem sem efeito sai como hoje
insert into public.config_regras (chave, valor, descricao) values ('fila_pula_sem_efeito', 'false'::jsonb, 'X73')
  on conflict (chave) do update set valor = excluded.valor;
select max(id) as base from public.chatwoot_acoes \gset
select public._porta_ordem(gen_random_uuid(), 1, 'teste_x73', (select m from public.mari_conversas m where m.id = :'c'), 'desatribuir',
  '{"assignee_id": null}'::jsonb);
select sim.fila_rodar();
select sim.confere('com a chave desligada, a ordem sem efeito sai como hoje',
  (select status from public.chatwoot_acoes where id > :base and conversa_id = :'c' and momento = 'teste_x73') = 'feita',
  (select string_agg(tipo || ':' || status || coalesce(' ' || erro, ''), ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'c'));
delete from public.config_regras where chave = 'fila_pula_sem_efeito';

-- (7) a Saída de verdade de um lead sem dono: o "tirar dono" não sai, o resto sai, e o Chatwoot fica como a Saída pede
-- (na produção o aviso do Chatwoot chega segundos DEPOIS de a ordem ser marcada feita; o simulador avisa antes — aqui o aviso chega depois)
select sim._webhook(:'cw', 'atualizada');
select max(id) as base from public.chatwoot_acoes \gset
select clock_timestamp() as t0 \gset
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('Saída de lead sem dono: o "tirar dono" fica cancelado "sem efeito" e a conversa é resolvida',
  exists (select 1 from public.chatwoot_acoes where id > :base and conversa_id = :'c' and tipo = 'desatribuir' and status = 'cancelada' and erro like 'sem efeito:%')
  and not exists (select 1 from public.chatwoot_acoes where id > :base and conversa_id = :'c' and tipo = 'desatribuir' and status = 'feita')
  and (select status = 'resolved' and agente is null and time_nome is null from sim.cw where conv = :'cw'),
  (select string_agg(tipo || ':' || status || coalesce(' ' || erro, ''), ' · ' order by id) from public.chatwoot_acoes where id > :base and conversa_id = :'c')
  || ' | ' || (select row_to_json(w)::text from sim.cw w where conv = :'cw'));
select sim.confere('nenhuma ordem pulada era necessária: a sombra não acusa falta nem contrária na Saída',
  not exists (select 1 from public.projetor_sombra where conversa_id = :'c' and em >= :'t0'
              and veredito in ('falta', 'contraria', 'erro')),
  (select string_agg(tipo || ':' || veredito || coalesce(' ' || motivo, ''), ' · ') from public.projetor_sombra
    where conversa_id = :'c' and em >= :'t0' and veredito in ('falta', 'contraria', 'erro')));
