-- id: X68
-- titulo: Unidade do cliente que está na lista do portal não abre "unidade a confirmar"; fora da lista, abre como antes (0343, caso L-222)
-- tipo: atual
-- Conversa L-222 (#202, 20/11 23h): o portal consultou sem o complemento (chegou 1 min depois), devolveu Casa A · Casa B · Casa C
-- e a conferência abriu mesmo com o "Casa a" da cliente na lista — a Mari perguntou a unidade duas vezes.
select sim.lead_novo('Gizele X68') as a \gset
update public.mari_conversas set cep = '32050080', numero = '861', complemento = 'Casa a' where id = :'a';
select public.mari_viab_gravar(:'a', jsonb_build_object('resultado', 'viavel', 'velocidade', '1GB',
  'unidade_a_confirmar', jsonb_build_object('informada', null, 'usada', 'Casa A'),
  'opcoes', jsonb_build_object('tipo', 'complemento', 'lista', jsonb_build_array('Casa A', 'Casa B', 'Casa C'), 'situacao', 'escolher'))) as r \gset
select sim.confere('unidade do cliente na lista: a conferência não abre',
  (select unidade_conferir_em is null from public.mari_conversas where id = :'a'),
  (select coalesce(unidade_conferir::text, '(nada)') from public.mari_conversas where id = :'a'));
select sim.confere('unidade do cliente na lista: cobertura viável, sem unidade_a_confirmar, com a unidade que bateu',
  (select cobertura_decisao = 'viavel' and not (cobertura_detalhe ? 'unidade_a_confirmar') and cobertura_detalhe->>'unidade_cliente' = 'Casa A'
     from public.mari_conversas where id = :'a'),
  (select cobertura_decisao || ' ' || cobertura_detalhe::text from public.mari_conversas where id = :'a'));
select sim.confere('a função devolve a unidade que bateu', (:'r'::jsonb ->> 'unidade_cliente') = 'Casa A', :'r');

-- Unidade fora da lista ("Casa 1" com a lista Casa A/B/C): abre "escolher", como na 0233
select sim.lead_novo('Helton X68') as b \gset
update public.mari_conversas set cep = '32050080', numero = '861', complemento = 'Casa 1' where id = :'b';
select public.mari_viab_gravar(:'b', jsonb_build_object('resultado', 'viavel', 'velocidade', '1GB',
  'unidade_a_confirmar', jsonb_build_object('informada', 'Casa 1', 'usada', 'Casa A'),
  'opcoes', jsonb_build_object('tipo', 'complemento', 'lista', jsonb_build_array('Casa A', 'Casa B', 'Casa C'), 'situacao', 'nao_encontrado')));
select sim.confere('unidade fora da lista: a conferência abre (escolher) e a Mari mostra as unidades',
  (select unidade_conferir_em is not null and unidade_conferir->>'motivo' = 'escolher' and (cobertura_detalhe->>'unidade_a_confirmar')::boolean
     from public.mari_conversas where id = :'b'),
  (select coalesce(unidade_conferir::text, '(nada)') from public.mari_conversas where id = :'b'));

-- Sem complemento nenhum: abre "escolher", como na 0233 (o cliente escolhe na lista)
select sim.lead_novo('Ana X68') as d \gset
update public.mari_conversas set cep = '32050080', numero = '861', complemento = null where id = :'d';
select public.mari_viab_gravar(:'d', jsonb_build_object('resultado', 'viavel',
  'unidade_a_confirmar', jsonb_build_object('informada', null, 'usada', 'Casa A'),
  'opcoes', jsonb_build_object('tipo', 'complemento', 'lista', jsonb_build_array('Casa A', 'Casa B'), 'situacao', 'escolher')));
select sim.confere('sem complemento: a conferência abre (escolher)',
  (select unidade_conferir_em is not null from public.mari_conversas where id = :'d'), null);
