-- id: X120
-- titulo: 0390 (Live 2.0, passo 1): a fila única no banco — uma linha por lead, sempre num dos seis tipos, na ordem dos pontos; a tarefa entra e sai sozinha pelo fato (cliente escreveu → Responder; o time respondeu → sai; qualificou → Fechar venda; OS e data gravadas → sai); nada do "Para fazer" e do Conferir de hoje fica de fora; quem não é do backoffice recebe null
-- tipo: atual
select sim.como('servico');
-- 1) conversa com a Mari, vez dela (o cliente acabou de escrever): não é tarefa de ninguém do time
select sim.lead_novo('Ana X120') as a \gset
select sim.cliente_escreve(:'a', 'Meu CEP é 36010-000', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('conversa com a Mari não entra na fila',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a'),
  (select x ->> 'tipo' || ' · ' || (x ->> 'fonte') || ':' || coalesce(x ->> 'sub', '') || ' · ' || (x ->> 'oque') from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'a'));
select sim.confere('ela aparece no radar "com a Mari"',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb #> '{radar,com_mari}') x where x ->> 'k' = 'c:' || :'a'), (:'f')::jsonb #>> '{conta}');

-- 2) conversa com o time: o cliente escreve → Responder; o time responde → sai sozinha (o banco confere a baixa)
select sim.como('servico');
select sim.lead_novo('Bia X120') as b \gset
select sim.como('backoffice');
select public.backoffice_conversa(:'b', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'b', 'Oi, Bia! Me passa o seu CEP?');
select sim.fila_rodar();
select sim.como('servico');
select sim.cliente_escreve(:'b', 'Meu CEP é 36010-000, e quanto fica?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'b'), '{}') as lb \gset
select sim.confere('cliente escreveu para o time → tarefa Responder', (:'lb')::jsonb ->> 'tipo' = 'responder', left(:'lb', 300));
select sim.confere('urgência de cliente esperando (4) e a última fala dele na linha',
  ((:'lb')::jsonb ->> 'urg')::int = 4 and (:'lb')::jsonb ->> 'ultima_fala' like 'Meu CEP%', (:'lb')::jsonb ->> 'urg');
select sim.confere('a linha traz um botão principal que abre o cliente',
  exists (select 1 from jsonb_array_elements((:'lb')::jsonb -> 'acoes') y where y ->> 'a' in ('abrir', 'assumir') and (y ->> 'principal')::boolean), (:'lb')::jsonb ->> 'acoes');
select public.backoffice_responder(:'b', 'Fica R$ 110 por mês, Bia. Posso seguir com o pedido?');
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('o time respondeu → a tarefa Responder sai sozinha',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'b' and x ->> 'tipo' = 'responder'),
  coalesce((select x ->> 'tipo' || ' · ' || (x ->> 'oque') from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'conversa_id' = :'b'), 'fora'));

-- 3) venda: qualificou → Fechar venda (vale a comissão do plano); crédito, biometria, OS e data → sai (a vez é da Nio)
select sim.como('servico');
select sim.lead_com_venda('Caio X120') as c \gset
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select coalesce((select x::text from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), '{}') as lc \gset
select sim.confere('lead qualificado com venda → tarefa Fechar venda', (:'lc')::jsonb ->> 'tipo' = 'venda', left(:'lc', 300));
select sim.confere('vale = comissão (não o padrão) e pontos = vale × etapa × urgência',
  not ((:'lc')::jsonb ->> 'vale_estimado')::boolean
  and ((:'lc')::jsonb ->> 'pontos')::numeric = round(((:'lc')::jsonb ->> 'vale')::numeric * ((:'lc')::jsonb ->> 'pe')::numeric * ((:'lc')::jsonb ->> 'pu')::numeric),
  (:'lc')::jsonb ->> 'vale' || ' × ' || ((:'lc')::jsonb ->> 'pe') || ' × ' || ((:'lc')::jsonb ->> 'pu') || ' = ' || ((:'lc')::jsonb ->> 'pontos'));
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select public.backoffice_momento(sim.venda(:'c'), 'biometria', '{"resultado":"validada"}');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '98' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.como('backoffice');
select public.live2_fila()::text as f \gset
select sim.confere('OS e data gravadas → sai da fila (esperando a Nio)',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text and x ->> 'tipo' in ('venda', 'agenda')),
  coalesce((select x ->> 'tipo' || ' · ' || (x ->> 'oque') from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'c')::text), 'fora'));

-- 4) regras gerais da fila
select sim.confere('um lead, uma linha',
  (select count(*) from jsonb_array_elements((:'f')::jsonb -> 'fila')) = (select count(distinct x ->> 'k') from jsonb_array_elements((:'f')::jsonb -> 'fila') x),
  (select count(*)::text from jsonb_array_elements((:'f')::jsonb -> 'fila')));
select sim.confere('só os seis tipos',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'tipo' not in ('responder', 'venda', 'agenda', 'ligar', 'nio', 'decidir')),
  (select string_agg(distinct x ->> 'tipo', ', ') from jsonb_array_elements((:'f')::jsonb -> 'fila') x));
select sim.confere('na ordem dos pontos (o de mais pontos em cima)',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') with ordinality a(x, n)
                join jsonb_array_elements((:'f')::jsonb -> 'fila') with ordinality b(y, m) on m = n + 1
               where (x ->> 'pontos')::numeric < (y ->> 'pontos')::numeric), 'fora de ordem');
select sim.confere('toda linha tem o que fazer e pelo menos um botão',
  not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where coalesce(x ->> 'oque', '') = '' or jsonb_array_length(x -> 'acoes') = 0),
  (select string_agg(x ->> 'k', ', ') from jsonb_array_elements((:'f')::jsonb -> 'fila') x where coalesce(x ->> 'oque', '') = '' or jsonb_array_length(x -> 'acoes') = 0));
-- nada do "Para fazer" de hoje fica de fora: todo alarme da jornada e todo aviso do Conferir sobre cliente está na fila
select sim.confere('todo "precisa de ação" da jornada está na fila',
  not exists (select 1 from public.v_jornada j where j.precisa_acao
                 and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'k' = coalesce(j.venda_id::text, 'c:' || j.conversa_id::text))),
  (select string_agg(j.nome, ', ') from public.v_jornada j where j.precisa_acao
      and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'k' = coalesce(j.venda_id::text, 'c:' || j.conversa_id::text))));
select sim.confere('todo aviso do Conferir sobre um cliente está na fila; os de sistema, fora dela',
  not exists (select 1 from jsonb_array_elements(public.live_conferir()) c
               where public._live2_tipo_conferir(c ->> 'tipo') <> 'sistema' and coalesce(c ->> 'venda_id', c ->> 'conversa_id') is not null
                 and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'k' = coalesce(c ->> 'venda_id', 'c:' || (c ->> 'conversa_id'))))
  and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'sub' in ('acao_falhou', 'fora_niogen', 'conta_nao_fecha')),
  'aviso do Conferir fora da fila, ou aviso de sistema dentro');
select sim.confere('toda vez do time na situação gravada está na fila',
  not exists (select 1 from public.lead_estado e where e.vez = 'time'
                 and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'k' = coalesce(e.venda_id::text, 'c:' || e.conversa_id::text))),
  (select string_agg(e.situacao, ', ') from public.lead_estado e where e.vez = 'time'
      and not exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'k' = coalesce(e.venda_id::text, 'c:' || e.conversa_id::text))));

-- 5) fora do backoffice/admin
select sim.como('servico');
select sim.confere('fora do backoffice/admin a fila é null', public.live2_fila() is null, 'veio fila');
