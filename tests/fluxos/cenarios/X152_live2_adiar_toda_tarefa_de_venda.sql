-- id: X152
-- titulo: 0430 (Ricardo, 27/11, caso L-199: "só preciso retirar ele da Live, com um lembrete para voltar no dia 04"): toda tarefa de venda que não é "Responder" tem Adiar com data na Live 2.0 — o cliente pediu para remarcar a instalação e o time combina a volta; adiada, sai da fila e fica no Radar "em pausa"; volta sozinha na data e volta na hora se o cliente escrever
-- tipo: atual

-- venda agendada; o cliente toca em "Preciso remarcar"
select sim.venda_pronta('Bruno X152') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar',
  jsonb_build_object('os', '52' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.confere('a venda está agendada (aguardando instalação)',
  (select status = '2_aguardando_instalacao' and instalacao_agendada_para is not null from public.vendas where id = sim.venda(:'c')),
  (select row(status, instalacao_agendada_para)::text from public.vendas where id = sim.venda(:'c')));
select sim._servico();
insert into public.eventos_venda (venda_id, tipo, detalhe) values (sim.venda(:'c'), 'instalacao_remarcar', jsonb_build_object('texto', 'Preciso remarcar'));
select sim.fila_rodar();

-- 1) o cartão "pediu para remarcar" está na fila e aceita Adiar
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as l1 \gset
select sim.confere('o pedido de remarcar vira tarefa Agendar, com o botão Reagendar',
  (:'l1')::jsonb ->> 'tipo' = 'agenda' and (:'l1')::jsonb ->> 'oque' ~* 'pediu para remarcar', left(:'l1', 400));
select sim.confere('a tarefa de venda que não é Responder aceita Adiar',
  ((:'l1')::jsonb ->> 'pode_pausar')::boolean, (:'l1')::jsonb ->> 'pode_pausar');

-- 2) Adiar por 7 dias: sai da fila, fica em pausa com a hora de volta
select (public.live2_baixa(sim.venda(:'c')::text, 'agora_nao', 7 * 24, 'a agenda da Nio só abre até o dia 04; reagendar na data') ->> 'ok') as ok \gset
select public.live2_fila()::text as f \gset
select sim.confere('adiada, a tarefa sai da fila',
  :'ok' = 'true' and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text),
  (select x ->> 'oque' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text));
select sim.confere('e aparece no Radar "em pausa", com a hora de volta',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb #> '{radar,em_pausa}') x where x ->> 'k' = sim.venda(:'c')::text and (x ->> 'volta_em')::timestamptz > now() + interval '6 days'),
  (:'f')::jsonb #>> '{radar,em_pausa}');

-- 3) na data, volta sozinha
select sim._servico();
update public.live2_baixas set ate = now() - interval '1 minute' where venda_id = sim.venda(:'c');
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('vencida a data do Adiar, a tarefa volta à fila',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text and x ->> 'tipo' = 'agenda'),
  coalesce((select x ->> 'tipo' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), 'fora da fila'));

-- 4) "Responder" continua sem Adiar: cliente esperando resposta nunca é adiado
select sim.lead_com_venda('Clara X152') as r \gset
select sim.como('servico');
select sim.cliente_escreve(:'r', 'Oi, tem alguém aí?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'r')::text), '{}') as l4 \gset
select sim.confere('venda com cliente esperando é Responder e não oferece Adiar',
  (:'l4')::jsonb ->> 'tipo' = 'responder' and not ((:'l4')::jsonb ->> 'pode_pausar')::boolean,
  coalesce((:'l4')::jsonb ->> 'tipo', 'fora') || ' · ' || coalesce((:'l4')::jsonb ->> 'pode_pausar', '?'));
