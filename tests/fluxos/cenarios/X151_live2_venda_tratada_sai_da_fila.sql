-- id: X151
-- titulo: 0429 (Ricardo, 27/11, casos L-449, L-82 e L-70: "Os dois clientes foram tratados já e não tem saída da Live"): venda com "sem viabilidade" marcado pelo time vira Decidir com o botão "Registrar a Saída" (motivo Fachada não atendida) em vez de ficar como "Responder" para sempre; o Adiar dessa linha vale e aceita data além de 7 dias; o cliente escreveu → volta como Responder; a Saída tira da fila; e a 🔥 "Quase pronto" não conta lead com crédito negado
-- tipo: atual

-- ───────── 1) venda no time, o time fala com o cliente e marca "sem viabilidade" ─────────
select sim.lead_com_venda('Ana X151') as c \gset
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Ana! Vou conferir a cobertura da sua rua e já te falo.');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as l0 \gset
select sim.confere('antes do "sem viabilidade" a venda está na fila do time, sem o botão de Saída sugerido',
  (:'l0')::jsonb ->> 'k' is not null
  and not exists (select 1 from jsonb_array_elements((:'l0')::jsonb -> 'acoes') y where y ->> 'a' = 'saida'), left(:'l0', 400));

select public.backoffice_momento(sim.venda(:'c'), 'viabilidade', '{"resultado":"sem_viabilidade"}');
select sim.fila_rodar();
select sim.confere('a ficha gravou sem viabilidade, à mão, na venda (sem pedido na Nio)',
  (select nio_viab_resultado = 'sem_viabilidade' and nio_viab_origem = 'manual' and status = '0_qualificado' and coalesce(nio_pedido, '') = ''
     from public.vendas where id = sim.venda(:'c')),
  (select row(nio_viab_resultado, nio_viab_origem, status, nio_pedido)::text from public.vendas where id = sim.venda(:'c')));

select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as l1 \gset
select sim.confere('com "sem viabilidade" do time a linha vira Decidir (não fica como Responder)',
  (:'l1')::jsonb ->> 'tipo' = 'decidir', (:'l1')::jsonb ->> 'tipo' || ' · ' || coalesce((:'l1')::jsonb ->> 'oque', ''));
select sim.confere('o texto diz o que fazer: registrar a Saída ou adiar',
  (:'l1')::jsonb ->> 'oque' ~* 'sem viabilidade' and (:'l1')::jsonb ->> 'oque' ~* 'sa[ií]da', (:'l1')::jsonb ->> 'oque');
select sim.confere('botão principal "Registrar a Saída", já com o motivo Fachada não atendida',
  exists (select 1 from jsonb_array_elements((:'l1')::jsonb -> 'acoes') y
           where y ->> 'a' = 'saida' and (y ->> 'principal')::boolean and y ->> 'pre' = 'fachada_nao_atendida'),
  (:'l1')::jsonb ->> 'acoes');
select sim.confere('não conta como urgente (sem "cliente esperando" nem "agora")', ((:'l1')::jsonb ->> 'urg')::int <= 2, (:'l1')::jsonb ->> 'urg');
select sim.confere('a linha aceita Saída e Adiar', ((:'l1')::jsonb ->> 'pode_sair')::boolean and ((:'l1')::jsonb ->> 'pode_pausar')::boolean,
  (:'l1')::jsonb ->> 'pode_sair' || ' · ' || ((:'l1')::jsonb ->> 'pode_pausar'));

-- ───────── 2) Adiar com data: 20 dias (pediu o cadastro da fachada à Nio) ─────────
select (public.live2_baixa(sim.venda(:'c')::text, 'agora_nao', 20 * 24, 'pedi o cadastro da fachada à Nio') ->> 'ate')::timestamptz as ate \gset
select sim.confere('o Adiar aceita 20 dias (o teto era 7)', :'ate'::timestamptz > now() + interval '19 days', :'ate');
select sim.confere('e continua com teto: 60 dias viram no máximo 30',
  (public.live2_baixa(sim.venda(:'c')::text, 'agora_nao', 60 * 24, null) ->> 'ate')::timestamptz <= now() + interval '30 days 1 hour', null);
select public.live2_fila()::text as f \gset
select sim.confere('adiada, a venda sai da fila',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text),
  (select x ->> 'oque' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text));
select sim.confere('e fica no Radar "em pausa", com a hora de volta',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb #> '{radar,em_pausa}') x where x ->> 'k' = sim.venda(:'c')::text and x ->> 'volta_em' is not null),
  (:'f')::jsonb #>> '{radar,em_pausa}');

-- ───────── 3) o cliente escreve: volta na hora, como Responder ─────────
select sim.como('servico');
select sim.cliente_escreve(:'c', 'E aí, conseguiram ver a minha rua?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as l3 \gset
select sim.confere('o cliente escreveu → a venda volta à fila como Responder, mesmo adiada',
  (:'l3')::jsonb ->> 'tipo' = 'responder', coalesce((:'l3')::jsonb ->> 'tipo', 'fora da fila'));

-- ───────── 4) o time responde e registra a Saída: sai da fila ─────────
select public.backoffice_responder(:'c', 'Ana, infelizmente a Nio ainda não chega na sua rua.');
select sim.fila_rodar();
select sim.como('backoffice');
select public.lead_sair(null, sim.venda(:'c'), 'fachada_nao_atendida', null, null, 'X151', null);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('depois da Saída a venda não está mais na fila',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text),
  (select x ->> 'oque' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text));

-- ───────── 5) "sem viabilidade" do ROBÔ não vira Decidir: o time ainda vai conferir à mão ─────────
select sim.lead_com_venda('Bia X151') as b \gset
select sim._servico();
update public.vendas set nio_viab_resultado = 'sem_viabilidade', nio_viab_origem = 'mari', nio_viab_em = now() where id = sim.venda(:'b');
select sim.como('backoffice');
select public.backoffice_responder(:'b', 'Oi, Bia! Vou conferir a cobertura da sua rua.');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'b')::text), '{}') as l5 \gset
select sim.confere('sem viabilidade lida pelo robô: a linha não sugere a Saída sozinha',
  (:'l5')::jsonb ->> 'k' is not null
  and not exists (select 1 from jsonb_array_elements((:'l5')::jsonb -> 'acoes') y where y ->> 'a' = 'saida' and y ->> 'pre' = 'fachada_nao_atendida'),
  left(:'l5', 300));

-- ───────── 6) 🔥 "Quase pronto" e "Viabilidade ok" não contam lead com crédito negado ─────────
select sim.lead_pronto('Caio X151') as p \gset
select sim.lead_pronto('Duda X151') as q \gset
select sim._servico();
update public.mari_conversas set credito_resultado = 'negado', credito_em = now() where id = :'q';
select sim.passa(:'p', '30 hours');
select sim.passa(:'q', '30 hours');
select sim.como('backoffice');
select sim.confere('controle: lead com os dados prontos e parado aparece na 🔥 como Quase pronto ou Viabilidade ok',
  exists (select 1 from public.oportunidades_abertas() o where o.conversa_id = :'p' and (o.regras && array['O4', 'O5'])),
  coalesce((select string_agg(o.codigo || ':' || o.motivo, ' | ') from public.oportunidades_abertas() o where o.conversa_id = :'p'), 'não apareceu'));
select sim.confere('o mesmo lead com crédito NEGADO não entra como Quase pronto nem Viabilidade ok',
  not exists (select 1 from public.oportunidades_abertas() o where o.conversa_id = :'q' and (o.regras && array['O4', 'O5'])),
  coalesce((select string_agg(o.codigo || ':' || o.motivo, ' | ') from public.oportunidades_abertas() o where o.conversa_id = :'q'), 'não apareceu'));
