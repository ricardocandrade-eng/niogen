-- id: X74
-- titulo: Caso L-199 (0348): o cliente dá uma data ("decido até 18/12") e a Mari marca a espera sozinha — volta ao Live 7 dias antes, a escada para, um "😉" não derruba a espera e uma fala de verdade derruba
-- tipo: atual
select (now() at time zone 'America/Sao_Paulo')::date as hoje \gset

-- (1) C3 com data: a espera nasce, marcada pela Mari, 7 dias antes da data do cliente, às 9h
select sim.lead_novo('Bruno X74') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.fila_rodar();
select sim.cliente_escreve(:'c', 'Vou decidir com calma, temos até dia 18/12 para tomar decisões, pq nossa mudança será dia 17/12', false);
select sim.mari_handoff(:'c', 'multiplos_decisores',
  jsonb_build_object('agendamento_retorno', to_char(:'hoje'::date + 27, 'YYYY-MM-DD') || 'T09:00:00-03:00'))::text as h \gset
select sim.fila_rodar();
select sim.confere('o C3 devolve a espera marcada', (:'h'::jsonb -> 'espera' ->> 'ok')::boolean, :'h');
select sim.confere('em espera até 7 dias antes da data do cliente, às 9h, marcada pela Mari (espera_por nulo)',
  (select (espera_ate at time zone 'America/Sao_Paulo') = (:'hoje'::date + 20)::timestamp + time '09:00'
          and espera_por is null and espera_motivo = 'cliente decide até ' || to_char(:'hoje'::date + 27, 'DD/MM')
     from public.mari_conversas where id = :'c'),
  (select espera_ate::text || ' · ' || coalesce(espera_motivo, '-') || ' · por ' || coalesce(espera_por::text, 'Mari') from public.mari_conversas where id = :'c'));
select sim.confere('a conversa segue com a Mari (C3 não passa para o time)',
  (select status = 'ativo' from public.mari_conversas where id = :'c'), (select status from public.mari_conversas where id = :'c'));
select sim.confere('a escada não manda nada enquanto espera', not coalesce((sim.cadencia_ver(:'c') ->> 'pode')::boolean, false)
  or sim.cadencia_ver(:'c') ->> 'proximo' is null, sim.cadencia_ver(:'c')::text);
select sim.confere('nota e adiamento no Chatwoot', sim.cw_de(:'c') ->> 'status' = 'snoozed'
  and exists (select 1 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'nota' and payload ->> 'content' like '⏸ Em espera até%marcado pela Mari%'),
  sim.cw_de(:'c')::text);
select sim.confere('o evento aguardar ficou anotado na porta', exists (select 1 from public.porta_sombra where conversa_id = :'c' and evento = 'aguardar'),
  (select string_agg(evento, ', ') from public.porta_sombra where conversa_id = :'c'));

-- (2) o "😉" logo depois da despedida não derruba a espera; a Mari repete o C3 e nada se duplica
select sim.cliente_escreve(:'c', '😉', false, '1 minute');
select sim.confere('um emoji logo depois não encerra a espera da Mari',
  (select espera_ate is not null from public.mari_conversas where id = :'c'), (select coalesce(espera_ate::text, 'sem espera') from public.mari_conversas where id = :'c'));
select sim.mari_handoff(:'c', 'multiplos_decisores',
  jsonb_build_object('agendamento_retorno', to_char(:'hoje'::date + 27, 'YYYY-MM-DD') || ' 10:00'));
select sim.fila_rodar();
select sim.confere('o C3 repetido com a mesma data não manda outra nota',
  (select count(*) from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'nota' and payload ->> 'content' like '⏸ Em espera até%') = 1,
  (select count(*)::text from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'nota' and payload ->> 'content' like '⏸ Em espera até%'));

-- (3) uma fala de verdade encerra a espera (C11), como na espera do time
select sim.cliente_escreve(:'c', 'Pensando melhor, quero fechar o Super agora', false, '10 minutes');
select sim.fila_rodar();
select sim.confere('fala de verdade encerra a espera', (select espera_ate is null from public.mari_conversas where id = :'c'),
  (select coalesce(espera_ate::text, 'sem espera') from public.mari_conversas where id = :'c'));

-- (4) data perto demais vira amanhã; data longe demais para em 60 dias; data passada ou sem data não marca nada
select sim.lead_novo('Lia X74') as d \gset
select sim.mari_fala(:'d', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.mari_handoff(:'d', 'interesse_caindo', jsonb_build_object('agendamento_retorno', to_char(:'hoje'::date + 3, 'YYYY-MM-DD') || ' 09:00'));
-- 0379 (Ricardo 24/11: "Mari retoma"): data perto (até 7 dias) é retorno com hora — a Mari chama no dia combinado, às 9h; a espera
-- vai até 2 h depois (sem resposta, volta para o time). Antes: voltava amanhã para o time.
select sim.confere('data a 3 dias: a Mari chama no dia (retorno com hora, espera até 11h)',
  (select (espera_ate at time zone 'America/Sao_Paulo') = (:'hoje'::date + 3) + time '11:00' from public.mari_conversas where id = :'d')
  and exists (select 1 from public.retornos r where r.conversa_id = :'d' and r.estado = 'marcado' and r.quem = 'mari'),
  (select coalesce(espera_ate::text, 'sem espera') from public.mari_conversas where id = :'d'));
select sim.lead_novo('Rui X74') as e \gset
select sim.mari_fala(:'e', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.mari_handoff(:'e', 'multiplos_decisores', jsonb_build_object('agendamento_retorno', to_char(:'hoje'::date + 120, 'YYYY-MM-DD') || ' 09:00'));
select sim.confere('data a 120 dias: no máximo 60', (select (espera_ate at time zone 'America/Sao_Paulo')::date = :'hoje'::date + 60 from public.mari_conversas where id = :'e'),
  (select coalesce(espera_ate::text, 'sem espera') from public.mari_conversas where id = :'e'));
select sim.lead_novo('Ana X74') as f \gset
select sim.mari_fala(:'f', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.mari_handoff(:'f', 'multiplos_decisores', jsonb_build_object('agendamento_retorno', to_char(:'hoje'::date - 2, 'YYYY-MM-DD') || ' 09:00'));
select sim.mari_handoff(:'f', 'multiplos_decisores');
select sim.confere('data passada ou sem data: sem espera (o C3 de sempre)', (select espera_ate is null from public.mari_conversas where id = :'f'),
  (select coalesce(espera_ate::text, 'sem espera') from public.mari_conversas where id = :'f'));
