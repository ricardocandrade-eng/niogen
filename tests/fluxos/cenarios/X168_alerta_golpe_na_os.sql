-- id: X168
-- titulo: 0446 (Ricardo 28/11, golpe "sem portas, 35 dias, instale por outra operadora", DDD 62): o alerta de golpe sai quando a OS é gravada (não espera a instalação), em mensagem própria, DEPOIS do aviso do pedido, uma vez por conversa, com texto curto que cita o DDD 62; agendar depois não repete; Não contatar não recebe
-- tipo: atual

-- A) OS gravada (boleto; a OS só existe com a biometria aprovada, 0256): aviso do pedido e, depois dele, o alerta de golpe
select sim.venda_pronta('Ana X168', true) as a \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'a'), 'os', jsonb_build_object('os', '168' || sim._conv(:'a'), 'forma', 'boleto'));
select sim.fila_rodar();
select sim.confere('OS gravada: o alerta de golpe saiu, sem esperar a instalação',
  (select count(*) from sim.envios where conversa = :'a' and texto ilike '%golpe%') = 1,
  (select string_agg(n || ': ' || left(texto, 50), ' | ' order by n) from sim.envios where conversa = :'a'));
select sim.confere('o alerta cita o DDD 62, manda bloquear e avisar',
  exists (select 1 from sim.envios where conversa = :'a' and texto ilike '%golpe%' and texto like '%DDD 62%'
           and texto ilike '%bloqueie%' and texto ilike '%me avise%'), null);
select sim.confere('o alerta entra na fila depois das outras mensagens do pedido',
  (select min(id) from public.chatwoot_acoes where conversa_id = :'a' and payload ->> 'texto_chave' = 'bo_alerta_golpe')
  > coalesce((select max(id) from public.chatwoot_acoes where conversa_id = :'a' and momento = 'os' and tipo = 'mensagem'
               and payload ->> 'texto_chave' is distinct from 'bo_alerta_golpe'), 0),
  (select string_agg(id || ':' || coalesce(payload ->> 'texto_chave', tipo), ' | ' order by id) from public.chatwoot_acoes
    where conversa_id = :'a' and momento = 'os'));
select sim.confere('o alerta é curto (até 320 caracteres)',
  (select char_length(texto) from public.config_mari_textos where chave = 'bo_alerta_golpe') <= 320,
  (select char_length(texto)::text from public.config_mari_textos where chave = 'bo_alerta_golpe'));

-- B) Agendar a instalação depois: o alerta não se repete
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'a'), 'agendar', jsonb_build_object('dia', (current_date + 4)::text, 'periodo', '08:00'));
select sim.fila_rodar();
select count(*) as ng from sim.envios where conversa = :'a' and texto ilike '%golpe%' \gset
select sim.confere('agendar depois não repete o alerta de golpe', :ng = 1, :'ng');

-- C) Não contatar: OS gravada não gera o alerta
select sim.venda_pronta('Bia X168', true) as b \gset
select sim._servico();
update public.mari_conversas set nao_contatar = true where id = :'b';
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'b'), 'os', jsonb_build_object('os', '169' || sim._conv(:'b'), 'forma', 'boleto'));
select sim.fila_rodar();
select sim.confere('Não contatar: nenhum alerta de golpe na fila',
  not exists (select 1 from public.chatwoot_acoes where conversa_id = :'b' and payload ->> 'texto_chave' = 'bo_alerta_golpe'), null);
