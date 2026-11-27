-- id: X156
-- titulo: 0434 (Ricardo, 27/11: "Pode seguir com a segunda etapa nas funções"): a live2_fila() calcula a conferência e o reforço antes da consulta principal, em vez de chamá-los de dentro dela (a memória das três empilhava: 105 MB por chamada; fica em 73 MB) — e a fila continua trazendo os avisos da conferência, o reforço e a tarefa do lead
-- tipo: atual

-- 1) a forma que segura a memória: as duas chamadas saíram de dentro da consulta (o pico em MB não dá para medir por SQL;
--    medido à mão em 27/11 — está na migration)
select sim.confere('a live2_fila calcula a conferência antes, em variável',
  (select prosrc ~ 'v_conf := coalesce\(public\.live_conferir\(\)' and prosrc !~ 'jsonb_to_recordset\(coalesce\(public\.live_conferir\(\)'
     from pg_proc where oid = 'public.live2_fila()'::regprocedure),
  'a live_conferir() ainda é chamada de dentro da consulta');
select sim.confere('e o reforço também',
  (select prosrc ~ 'v_ref := coalesce\(public\._live2_reforco\(\)' and prosrc ~ '''reforco'', v_ref,'
     from pg_proc where oid = 'public.live2_fila()'::regprocedure),
  'o _live2_reforco() ainda é chamado de dentro da consulta');
select sim.confere('a live2_fila continua só leitura, com dono e search_path próprios',
  (select provolatile = 's' and prosecdef and proconfig::text ~ 'search_path=public' from pg_proc where oid = 'public.live2_fila()'::regprocedure),
  (select row(provolatile, prosecdef, proconfig)::text from pg_proc where oid = 'public.live2_fila()'::regprocedure));

-- 2) a fila continua trazendo a tarefa do lead
select sim.lead_com_venda('Flávia X156') as r \gset
select sim.como('servico');
select sim.cliente_escreve(:'r', 'Oi, tem alguém aí?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('a venda com cliente esperando está na fila, como Responder',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'r')::text and x ->> 'tipo' = 'responder'),
  coalesce((select x ->> 'tipo' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'r')::text), 'fora da fila'));

-- 3) os avisos da conferência chegam à fila: todo aviso sem lead (de sistema) que a live_conferir() devolve está em "sistema"
select public.live_conferir()::text as c \gset
select sim.confere('todo aviso de sistema da conferência aparece na fila',
  not exists (select 1 from jsonb_array_elements((:'c')::jsonb) a
               where a ->> 'conversa_id' is null and a ->> 'venda_id' is null
                 and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'sistema') s
                                  where s ->> 'tipo' = a ->> 'tipo' and s ->> 'chave' is not distinct from a ->> 'chave')),
  (select string_agg(a ->> 'tipo', ', ') from jsonb_array_elements((:'c')::jsonb) a where a ->> 'conversa_id' is null and a ->> 'venda_id' is null));
select sim.confere('a fila tem as chaves "sistema" e "reforco" como listas',
  jsonb_typeof((:'f')::jsonb -> 'sistema') = 'array' and jsonb_typeof((:'f')::jsonb -> 'reforco') = 'array',
  coalesce(jsonb_typeof((:'f')::jsonb -> 'sistema'), 'sem') || ' · ' || coalesce(jsonb_typeof((:'f')::jsonb -> 'reforco'), 'sem'));
select sim.confere('e o reforço da fila é o mesmo que a função do reforço devolve',
  ((:'f')::jsonb -> 'reforco') = coalesce(public._live2_reforco(), '[]'::jsonb),
  left(((:'f')::jsonb -> 'reforco')::text, 200));
