-- id: X40
-- titulo: Fase 2, passo 4 (0307): o projetor único em SOMBRA — anota toda ordem, não manda nada a mais, acusa divergência e ordem repetida
-- tipo: atual
-- Cada ordem que entra em chatwoot_acoes ganha, em projetor_sombra, o que o projetor único (pela situação do lead) faria com ela.
-- Prova: (1) toda ordem é anotada e julgada no fim da transação; (2) com a sombra ligada saem EXATAMENTE as mesmas ordens que com ela
-- desligada (dois leads iguais, um com o gatilho desligado); (3) ordem contra a situação é acusada; (4) a mesma ordem duas vezes na
-- mesma transação é acusada como repetida, e o projetor chamado duas vezes na mesma transação não duplica nada; (5) a sombra não
-- escreve na fila. As ordens de teste entram com status 'cancelada' (não saem para o Chatwoot de mentira).
select max(id) as base from public.chatwoot_acoes \gset

-- (2) dois leads com a mesma história: A com a sombra desligada, B com ela ligada
alter table public.chatwoot_acoes disable trigger zz_projetor_sombra;
select sim.lead_novo('Dora X40') as a \gset
select sim.mari_handoff(:'a', 'pedido_humano');
select sim.fila_rodar();
select sim.como('backoffice');
select public.lead_sair(:'a', null, 'recusou', 'preco');
select sim.como('servico');
select sim.fila_rodar();
alter table public.chatwoot_acoes enable trigger zz_projetor_sombra;
select sim.lead_novo('Dora X40') as b \gset
select sim.mari_handoff(:'b', 'pedido_humano');
select sim.fila_rodar();
select sim.como('backoffice');
select public.lead_sair(:'b', null, 'recusou', 'preco');
select sim.como('servico');
select sim.fila_rodar();

select sim.confere('com a sombra ligada saem as mesmas ordens que com ela desligada (tipo, origem e conteúdo de estado)',
  (select array_agg(momento || ':' || tipo || ':' || case when tipo in ('nota', 'mensagem') then '' else payload::text end order by momento, tipo, payload::text)
     from public.chatwoot_acoes where conversa_id = :'a')
  = (select array_agg(momento || ':' || tipo || ':' || case when tipo in ('nota', 'mensagem') then '' else payload::text end order by momento, tipo, payload::text)
     from public.chatwoot_acoes where conversa_id = :'b'),
  'A: ' || coalesce((select string_agg(momento || ':' || tipo, ' ' order by id) from public.chatwoot_acoes where conversa_id = :'a'), '-')
  || ' | B: ' || coalesce((select string_agg(momento || ':' || tipo, ' ' order by id) from public.chatwoot_acoes where conversa_id = :'b'), '-'));
select sim.confere('o lead A (sombra desligada) não tem nada na sombra',
  not exists (select 1 from public.projetor_sombra where conversa_id = :'a'),
  (select count(*)::text || ' linhas' from public.projetor_sombra where conversa_id = :'a'));

-- (1) toda ordem do lead B anotada uma vez e julgada; nenhuma pendente nem com erro
select sim.confere('toda ordem do lead B está na sombra, uma linha por ordem',
  (select count(*) from public.chatwoot_acoes where conversa_id = :'b') > 0
  and (select count(*) from public.chatwoot_acoes where conversa_id = :'b')
    = (select count(distinct acao_id) from public.projetor_sombra where conversa_id = :'b' and acao_id is not null)
  and (select count(*) from public.projetor_sombra where conversa_id = :'b' and acao_id is not null)
    = (select count(distinct acao_id) from public.projetor_sombra where conversa_id = :'b' and acao_id is not null),
  (select count(*) from public.chatwoot_acoes where conversa_id = :'b')::text || ' ordens · '
  || (select count(*) from public.projetor_sombra where conversa_id = :'b' and acao_id is not null)::text || ' na sombra');
select sim.confere('tudo julgado no fim da transação (nenhuma linha pendente ou com erro)',
  not exists (select 1 from public.projetor_sombra where conversa_id = :'b' and veredito in ('pendente', 'erro')),
  (select string_agg(tipo || ':' || veredito || coalesce(' ' || motivo, ''), ' · ') from public.projetor_sombra
    where conversa_id = :'b' and veredito in ('pendente', 'erro')));
select sim.confere('a Saída pela porta não vai contra a situação (nenhuma ordem "contraria")',
  not exists (select 1 from public.projetor_sombra where conversa_id = :'b' and veredito = 'contraria'),
  (select string_agg(momento || ':' || tipo || ' ' || coalesce(motivo, ''), ' · ') from public.projetor_sombra
    where conversa_id = :'b' and veredito = 'contraria'));
select sim.confere('depois da Saída o Chatwoot está como a situação pede: o projetor não sente falta de nada',
  not exists (select 1 from public.projetor_sombra s where s.conversa_id = :'b' and s.veredito = 'falta'
                and s.tx = (select max(tx) from public.projetor_sombra where conversa_id = :'b')),
  (select string_agg(tipo || ' ' || coalesce(motivo, ''), ' · ') from public.projetor_sombra where conversa_id = :'b' and veredito = 'falta'));

-- (3) uma ordem contra a situação: abrir a conversa de quem está em Saída
select max(id) as base2 from public.chatwoot_acoes \gset
select public._bo_enfileirar(gen_random_uuid(), 1, 'teste_x40', null, m, 'resolver', '{"status":"open"}'::jsonb, now(), 'cancelada')
  from public.mari_conversas m where m.id = :'b';
select sim.confere('ordem de abrir a conversa em Saída: a sombra acusa "contraria"',
  (select veredito from public.projetor_sombra where momento = 'teste_x40' and conversa_id = :'b' and tipo = 'resolver') = 'contraria'
  and exists (select 1 from public.v_projetor_sombra_divergencias where conversa_id = :'b' and veredito = 'contraria' and momento = 'teste_x40'),
  (select veredito || ' · ' || coalesce(situacao, '-') || ' · ' || coalesce(motivo, '-') from public.projetor_sombra
    where momento = 'teste_x40' and conversa_id = :'b' and tipo = 'resolver'));
select public._bo_enfileirar(gen_random_uuid(), 1, 'teste_x40b', null, m, 'resolver', '{"status":"resolved"}'::jsonb, now(), 'cancelada')
  from public.mari_conversas m where m.id = :'b';
select sim.confere('resolver quem já está resolvido: a sombra acusa "a_mais" (não muda nada)',
  (select veredito from public.projetor_sombra where momento = 'teste_x40b' and conversa_id = :'b') = 'a_mais',
  (select veredito || ' · ' || coalesce(motivo, '-') from public.projetor_sombra where momento = 'teste_x40b' and conversa_id = :'b'));

-- (4) a mesma ordem duas vezes na mesma transação (um só comando = uma transação)
select public._bo_enfileirar(g, 1, 'teste_x40r', null, m, 'nota', '{"content":"nota repetida X40"}'::jsonb, now(), 'cancelada'),
       public._bo_enfileirar(g, 2, 'teste_x40r', null, m, 'nota', '{"content":"nota repetida X40"}'::jsonb, now(), 'cancelada')
  from public.mari_conversas m, (select gen_random_uuid() g) x where m.id = :'b';
select sim.confere('a mesma ordem duas vezes na mesma transação: a primeira "igual", a segunda "repetida"',
  (select array_agg(veredito order by id) from public.projetor_sombra where momento = 'teste_x40r' and conversa_id = :'b') = array['igual', 'repetida'],
  (select string_agg(veredito, ', ' order by id) from public.projetor_sombra where momento = 'teste_x40r' and conversa_id = :'b'));
-- o projetor chamado duas vezes na mesma transação (em Saída ele sempre manda etiquetas e tira dono): _porta_ordem não duplica
select max(id) as base3 from public.chatwoot_acoes \gset
select public._porta_projetar(:'b', 'teste_x40p'), public._porta_projetar(:'b', 'teste_x40p');
select sim.confere('o projetor duas vezes na mesma transação não manda a mesma ordem duas vezes',
  not exists (select 1 from public.chatwoot_acoes where id > :base3 and conversa_id = :'b'
               group by tipo, payload having count(*) > 1)
  and not exists (select 1 from public.projetor_sombra where conversa_id = :'b' and momento = 'teste_x40p' and veredito = 'repetida'),
  (select string_agg(tipo || ' ' || payload::text, ' · ' order by id) from public.chatwoot_acoes where id > :base3 and conversa_id = :'b'));
select sim.confere('… e as ordens que o projetor repetiu sem mudar nada aparecem como "a_mais" (o Chatwoot já estava assim)',
  exists (select 1 from public.chatwoot_acoes where id > :base3 and conversa_id = :'b')
  and not exists (select 1 from public.projetor_sombra s join public.chatwoot_acoes a on a.id = s.acao_id
                   where a.id > :base3 and a.conversa_id = :'b' and s.veredito not in ('a_mais')),
  (select string_agg(s.tipo || ':' || s.veredito, ' · ' order by s.id) from public.projetor_sombra s
    where s.acao_id > :base3 and s.conversa_id = :'b'));
select sim.fila_rodar();

-- (5) a sombra não escreve na fila: toda ordem nova veio de uma função de verdade, nenhuma com a origem do projetor em sombra
select sim.confere('nenhuma ordem nasceu da sombra (a fila só tem o que as funções pediram)',
  not exists (select 1 from public.chatwoot_acoes where id > :base and momento = 'projetor')
  and (select count(*) from public.chatwoot_acoes where id > :base and conversa_id = :'b')
    = (select count(*) from public.projetor_sombra where conversa_id = :'b' and acao_id is not null),
  (select count(*)::text from public.chatwoot_acoes where id > :base and conversa_id = :'b') || ' ordens × '
  || (select count(*)::text from public.projetor_sombra where conversa_id = :'b' and acao_id is not null) || ' anotadas');
select sim.confere('a view de divergência e o resumo respondem',
  (select count(*) from public.v_projetor_sombra_resumo where conversas > 0) > 0, null);
