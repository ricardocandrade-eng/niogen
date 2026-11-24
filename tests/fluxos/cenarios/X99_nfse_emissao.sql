-- id: X99
-- titulo: Botão "Emitir NF" (0374, Ricardo 23/11: "Sim, fazer o botão" — um clique, teste primeiro). Só admin pede; o nº da DPS é reservado e nunca se repete; duas emissões do mesmo pedido ao mesmo tempo são recusadas; o resultado só pela chave de serviço; nota de teste (restrita) não vira NF do pedido, a de produção vira (com o envio à Nio); pedido com NF de produção não emite de novo; emissão sem resposta vira falha na conferência
-- tipo: atual

-- A) um pedido de compra importado (extrato sem venda ligada basta)
select sim.como('admin');
select public.extrato_importar('202611_1Q_X99.xlsx', $j${
  "PEDIDO": [{"CICLO": "1QNOV26", "DOCUMENTO DE COMPRAS": "4500000099", "ITEM": "10", "VALOR": 380}],
  "LINHA_A_LINHA": [{"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO",
                     "NUM_OS_PEDIDO_SIEBEL": "X99OS0001", "DATA_ATV": "46339", "COMISSAO": 380}]}$j$::jsonb);
update public.config_regras set valor = '{"ambiente": "restrita", "serie": 1, "proximo": {"restrita": 2, "producao": 1}}' where chave = 'nfse';

-- B) a porta: backoffice não emite; admin pede e o nº começa no "proximo" da restrita (2)
select sim.como('backoffice');
select coalesce(sim.recusa($q$ select public.nfse_emissao_pedir('4500000099', '10') $q$), '') as recusa_bo \gset
select sim.confere('backoffice não emite NF', :'recusa_bo' like '%Só admin%', :'recusa_bo');
select sim.como('admin');
select public.nfse_emissao_pedir('4500000099', '10') as p1 \gset
select sim.confere('1ª emissão de teste: restrita, série 1, nº 2, valor do pedido',
  :'p1'::jsonb ->> 'ambiente' = 'restrita' and (:'p1'::jsonb ->> 'numero')::int = 2 and (:'p1'::jsonb ->> 'valor')::numeric = 380, :'p1');
select sim.confere('outra emissão do mesmo pedido enquanto a 1ª não respondeu é recusada',
  sim.recusa($q$ select public.nfse_emissao_pedir('4500000099', '10') $q$) like '%em andamento%', null);

-- C) o resultado só pela chave de serviço
set role authenticated;
select coalesce(sim.recusa(format($q$ select public.nfse_emissao_resultado(%L, '{"situacao":"emitida"}') $q$, :'p1'::jsonb ->> 'id')), '') as recusa_res \gset
reset role;
select sim.confere('login comum não grava o resultado', :'recusa_res' <> '', :'recusa_res');
select sim.como('servico');
select public.nfse_emissao_resultado((:'p1'::jsonb ->> 'id')::uuid, jsonb_build_object('situacao', 'enviada', 'chave', '3136702X99', 'n_nfse', '2',
  'emitida_em', now(), 'email_para', 'remetente@teste', 'email_enviado_em', now()));
select sim.confere('nota de TESTE não vira a NF do pedido',
  not exists (select 1 from public.nio_ciclo_nf where documento_compras = '4500000099'), null);

-- D) o próximo nº continua (3), sem repetir
select sim.como('admin');
select public.nfse_emissao_pedir('4500000099', '10') as p2 \gset
select sim.confere('nº seguinte na restrita = 3', (:'p2'::jsonb ->> 'numero')::int = 3, :'p2');
select sim.como('servico');
select public.nfse_emissao_resultado((:'p2'::jsonb ->> 'id')::uuid, '{"situacao": "erro_emissao", "erro": "E0000 teste"}');

-- E) produção: nº 1; emitida e enviada vira a NF do pedido com o envio; pedido com NF não emite de novo
update public.config_regras set valor = jsonb_set(valor, '{ambiente}', '"producao"') where chave = 'nfse';
select sim.como('admin');
select public.nfse_emissao_pedir('4500000099', '10') as p3 \gset
select sim.confere('produção começa no nº 1', :'p3'::jsonb ->> 'ambiente' = 'producao' and (:'p3'::jsonb ->> 'numero')::int = 1, :'p3');
select sim.como('servico');
select public.nfse_emissao_resultado((:'p3'::jsonb ->> 'id')::uuid, jsonb_build_object('situacao', 'enviada', 'chave', '3136702X99P', 'n_nfse', '5',
  'emitida_em', now(), 'email_para', 'nio@teste', 'email_enviado_em', now()));
select sim.confere('NF de produção vira a NF do pedido, com emissão e envio de hoje',
  (select nf_numero = '5' and nf_emitida_em = (now() at time zone 'America/Sao_Paulo')::date
          and nf_enviada_em = (now() at time zone 'America/Sao_Paulo')::date
     from public.nio_ciclo_nf where documento_compras = '4500000099'),
  (select row_to_json(f)::text from public.nio_ciclo_nf f where documento_compras = '4500000099'));
select sim.como('admin');
select sim.confere('pedido com NF de produção não emite de novo',
  sim.recusa($q$ select public.nfse_emissao_pedir('4500000099', '10') $q$) like '%já tem NF%', null);

-- F) emissão sem resposta há mais de 10 min = falha na conferência
update public.config_regras set valor = jsonb_set(valor, '{ambiente}', '"restrita"') where chave = 'nfse';
select public.nfse_emissao_pedir('4500000099', '10') as p4 \gset
select sim.confere('nova tentativa depois de uma recusada REUSA o mesmo nº da DPS (3), na mesma linha',
  (:'p4'::jsonb ->> 'numero')::int = 3 and :'p4'::jsonb ->> 'id' = :'p2'::jsonb ->> 'id', :'p4');
update public.nfse_emissoes set pedida_em = now() - interval '15 minutes' where id = (:'p4'::jsonb ->> 'id')::uuid;
select sim.confere('emissão parada sem resposta = falha na conferência',
  (select x->>'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'nfse_emissao') = 'falha',
  (select x::text from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'nfse_emissao'));
select public.nfse_emissao_pedir('4500000099', '10') as p5 \gset
select sim.confere('sem resposta há 15 min: o novo clique também reusa o nº 3 (o serviço vê se a DPS já virou nota e não duplica)',
  (:'p5'::jsonb ->> 'numero')::int = 3 and (select count(*) from public.nfse_emissoes where ambiente = 'restrita' and numero = 3) = 1, :'p5');
