-- id: X92
-- titulo: 0366 (L-248, Ricardo 23/11): o aviso do crédito só fala de biometria com plano e forma combinados (sem eles, pede o que falta); o alerta de golpe sai uma vez, sozinho, depois da confirmação da instalação (fora dos avisos da biometria e da instalação); OS gravada no cartão com a biometria aprovada → o cliente recebe na hora a instrução do cadastro do cartão (pré-reserva, nada cobrado hoje)
-- tipo: atual

-- A) Crédito aprovado com a forma de pagamento ainda NÃO combinada: não fala de biometria, pede a forma
select sim.lead_pronto('Rui X92') as a \gset
select sim._servico();
update public.mari_conversas set forma_pagamento = null where id = :'a';
select public.mari_credito_gravar(:'a', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('sem forma combinada: o aviso do crédito não fala de biometria',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_aprovado%')
  and not exists (select 1 from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_aprovado%'
                   and payload ->> 'content' ilike '%biometria%'),
  (select string_agg(payload ->> 'content', ' | ') from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem'));
select sim.confere('sem forma combinada: o aviso pede a forma de pagamento (boleto, cartão ou débito)',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_aprovado_falta'
           and payload ->> 'content' like '%forma de pagamento%' and payload ->> 'content' like '%cartão de crédito%'), null);

-- B) Crédito aprovado com plano e forma combinados (boleto): diz a forma e que a Nio manda a biometria no pedido
select sim.lead_pronto('Sol X92') as b \gset
select sim._servico();
select public.mari_credito_gravar(:'b', '{"resultado": "aprovado_todas", "formas_liberadas": ["BOLETO","CREDITO","DACC"]}'::jsonb);
select sim.fila_rodar();
select sim.confere('com plano e forma: aviso de aprovado no boleto, com o pedido e a biometria em seguida',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'b' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_aprovado'
           and payload ->> 'content' like '%boleto%' and payload ->> 'content' like '%pedido%'), null);

-- C) Os avisos da biometria e da instalação não trazem mais o alerta de golpe
select sim.confere('nenhum aviso da biometria/instalação traz o alerta de golpe',
  not exists (select 1 from public.config_mari_textos where chave in ('bo_instalacao_confirmada', 'bo_ged_biometria', 'bo_pedido_biometria', 'bo_os_biometria')
               and (texto ilike '%golpe%' or texto ilike '%migra%')), null);

-- D) Agendar a instalação (boleto): confirmação + alerta de golpe à parte, depois dela; reagendar não repete o alerta
select sim.venda_pronta('Teo X92', true) as d \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'d'), 'os', jsonb_build_object('os', '92' || sim._conv(:'d'), 'forma', 'boleto'));
select public.backoffice_momento(sim.venda(:'d'), 'agendar', jsonb_build_object('dia', (current_date + 4)::text, 'periodo', '08:00'));
select sim.fila_rodar();
select (select min(n) from sim.envios where conversa = :'d' and texto like 'Instalação agendada%') as n_inst,
       (select min(n) from sim.envios where conversa = :'d' and texto ilike '%golpe%') as n_golpe \gset
-- 0446 (28/11): o alerta passou a sair quando a OS é gravada (antes da instalação) — a ordem em relação à confirmação é do X168.
select sim.confere('agendou: o alerta de golpe saiu numa mensagem própria (0446: já na OS; a confirmação da instalação vem à parte)',
  :'n_inst' <> '' and :'n_golpe' <> '' and :'n_golpe'::int <> :'n_inst'::int,
  (select string_agg(n || ': ' || left(texto, 50), ' | ' order by n) from sim.envios where conversa = :'d'));
select sim.confere('a confirmação da instalação não traz o golpe',
  not exists (select 1 from sim.envios where conversa = :'d' and texto like 'Instalação agendada%' and texto ilike '%golpe%'), null);
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'d'), 'agendar', jsonb_build_object('dia', (current_date + 5)::text, 'periodo', '13:00'));
select sim.fila_rodar();
select count(*) as ng from sim.envios where conversa = :'d' and texto ilike '%golpe%' \gset
select sim.confere('reagendar não repete o alerta de golpe', :ng = 1, :'ng');

-- E) OS gravada no CARTÃO com a biometria aprovada: a instrução do cartão sai na hora (pré-reserva, nada cobrado hoje), uma vez
select sim.venda_pronta('Uma X92', true) as e \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'e'), 'os', jsonb_build_object('os', '93' || sim._conv(:'e'), 'forma', 'cartao'));
select sim.fila_rodar();
select sim.confere('OS no cartão: saiu a instrução do cadastro do cartão',
  exists (select 1 from sim.envios where conversa = :'e' and texto ilike '%cadastrar o cartão%' and texto ilike '%nada é cobrado hoje%'),
  (select string_agg(left(texto, 60), ' | ' order by n) from sim.envios where conversa = :'e'));
select sim.confere('OS no cartão: a conversa guarda que o cartão foi avisado (a cadência não repete)',
  (select cartao_avisado_em from public.mari_conversas where id = :'e') is not null, null);
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'e'), 'agendar', jsonb_build_object('dia', (current_date + 4)::text, 'periodo', '08:00'));
select sim.fila_rodar();
select count(*) as nc from sim.envios where conversa = :'e' and texto ilike '%cadastrar o cartão%' \gset
select sim.confere('agendar depois não repete a instrução do cartão', :nc = 1, :'nc');

-- F) OS no BOLETO: nenhuma instrução de cartão
select sim.confere('OS no boleto: nenhuma instrução de cartão',
  not exists (select 1 from sim.envios where conversa = :'d' and texto ilike '%cadastrar o cartão%'), null);
