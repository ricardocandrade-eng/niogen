-- id: X141
-- titulo: Área nacional (0417, Ricardo 26/11: "A Dharma está autorizada a vender em todos os estados"): config_area com as 345 cidades da GDP, 320 ativas (21 UFs de fuso −3) e 25 desligadas (AC, AM, RR, RO, MT, MS — fuso pendente). Venda no Rio e em Brasília passa; em Cuiabá é recusada; area_ativar liga e desliga com histórico; o nome sem acento casa; a conferência ganha o item do cluster da GDP
-- tipo: atual

-- 0418 ligou as 6 UFs de outro fuso: o cenário desliga MT antes, para testar a recusa (vale com ou sem a 0418)
select public._area_ativar('MT', null, false, 'X141 prepara: MT desligada para o teste', 'sim');

-- A) a área pelo nome que o ViaCEP devolve (e sem acento)
select sim.confere('Rio de Janeiro/RJ é Regular',      public.cluster_da_area('Rio de Janeiro', 'RJ', 'Centro') = 'regular', public.cluster_da_area('Rio de Janeiro', 'RJ', 'Centro'));
select sim.confere('Brasília/DF é Regular',            public.cluster_da_area('Brasília', 'DF', null) = 'regular', public.cluster_da_area('Brasília', 'DF', null));
select sim.confere('Maceió/AL é BTU',                  public.cluster_da_area('Maceió', 'AL', null) = 'btu', public.cluster_da_area('Maceió', 'AL', null));
select sim.confere('"Divinopolis" sem acento casa',    public.cluster_da_area('Divinopolis', 'MG', null) = 'regular', null);
select sim.confere('Juiz de Fora continua Regular',    public.cluster_da_area('Juiz de Fora', 'MG', 'Centro') = 'regular', null);
select sim.confere('Cuiabá/MT desligada não tem cluster',  public.cluster_da_area('Cuiabá', 'MT', null) is null, public.cluster_da_area('Cuiabá', 'MT', null));
select sim.confere('Palmas sem UF não vira a do Tocantins (cai em MG, que não tem)', public.cluster_da_area('Palmas', null, null) is null, null);
select sim.confere('345 na carteira, todas as 320 das 21 UFs de fuso −3 ativas, as 25 de outro fuso com o histórico fuso_pendente',
  (select count(*) from public.config_area) = 345
  and not exists (select 1 from public.config_area where not ativo and uf not in ('AC', 'AM', 'RR', 'RO', 'MT', 'MS'))
  and (select count(*) from public.area_ativa_hist where motivo like 'fuso_pendente%') = 25,
  (select count(*) || ' · ' || count(*) filter (where ativo) from public.config_area));

-- B) venda no Rio passa pela Mari e pelo trigger
select sim.lead_pronto('Rui X141') as a \gset
select sim._servico();
update public.mari_conversas set cep = '20040002', cidade = 'Rio de Janeiro', uf = 'RJ', cluster = 'regular', dentro_area = true,
       endereco_cep = jsonb_build_object('logradouro', 'Rua Simulada', 'bairro', 'Centro', 'localidade', 'Rio de Janeiro', 'uf', 'RJ')
 where id = :'a';
select sim.mari_handoff(:'a', 'dados_completos', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('venda no Rio de Janeiro é criada', sim.venda(:'a') is not null, null);

-- C) Cuiabá (desligada): a Mari não cria a venda e o trigger recusa a venda que tentar ir para lá
select sim.lead_pronto('Caio X141') as b \gset
select sim._servico();
update public.mari_conversas set cep = '78005000', cidade = 'Cuiabá', uf = 'MT', cluster = null, dentro_area = false,
       endereco_cep = jsonb_build_object('logradouro', 'Rua Simulada', 'bairro', 'Centro', 'localidade', 'Cuiabá', 'uf', 'MT')
 where id = :'b';
select sim.mari_handoff(:'b', 'dados_completos', '{}'::jsonb);
select sim.confere('Cuiabá desligada: a Mari não cria venda', sim.venda(:'b') is null, null);

-- o trigger da venda (vendas_checa_area, sem mudança na 0417) recusa venda vendida quando cluster_da_area é nulo — o que
-- Cuiabá desligada dá, acima. (Gravar a venda como vendida aqui esbarra antes no trigger da biometria.)
select sim.confere('o trigger da venda continua decidindo pela cluster_da_area',
  (select prosrc ~ 'public\.cluster_da_area\(new\.cidade, new\.uf, new\.bairro\)' and prosrc ~ 'Venda bloqueada'
     from pg_proc where proname = 'vendas_checa_area'), null);

-- D) liga MT → Cuiabá vende; desliga → volta a recusar; tudo no histórico
select public._area_ativar('MT', null, true, 'teste X141', 'sim');
select sim.confere('MT ligada: Cuiabá tem cluster', public.cluster_da_area('Cuiabá', 'MT', null) = 'regular', null);
select sim.lead_pronto('Cris X141') as c \gset
select sim._servico();
update public.mari_conversas set cep = '78005000', cidade = 'Cuiabá', uf = 'MT', cluster = 'regular', dentro_area = true,
       endereco_cep = jsonb_build_object('logradouro', 'Rua Simulada', 'bairro', 'Centro', 'localidade', 'Cuiabá', 'uf', 'MT')
 where id = :'c';
select sim.mari_handoff(:'c', 'dados_completos', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('MT ligada: a venda em Cuiabá é criada', sim.venda(:'c') is not null, null);
select public._area_ativar('MT', null, false, 'teste X141 desliga', 'sim');
select sim.confere('MT desligada de novo: Cuiabá sem cluster', public.cluster_da_area('Cuiabá', 'MT', null) is null, null);
select sim.confere('histórico: as 10 de MT ligadas e desligadas',
  (select count(*) from public.area_ativa_hist where uf = 'MT' and motivo like 'teste X141%') = 20, null);

-- E) a carga é repetível: rodar de novo não cria nem liga nada
create temp table _x141c as select count(*) n, count(*) filter (where ativo) a from public.config_area;
select public.area_carregar_gdp((select jsonb_agg(jsonb_build_object('uf', uf, 'municipio_gdp', municipio_gdp, 'cidade', cidade, 'origem', origem,
         'cidade_polo', cidade_polo, 'cod_ibge', cod_ibge, 'ddd', ddd, 'portfolio', portfolio_gdp)) from public.config_area), date '2026-10-28');
select sim.confere('recarga da GDP não cria nem liga cidade',
  (select count(*) from public.config_area) = (select n from _x141c) and (select count(*) from public.config_area where ativo) = (select a from _x141c), null);

-- F) conferência: item 41 no ar e verde
select sim.confere('conferência tem o item area_cluster_gdp e está ok',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_cluster_gdp' and i ->> 'nivel' = 'ok'),
  (select i::text from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_cluster_gdp'));
-- cluster trocado à mão → a conferência acusa
update public.config_area set cluster = 'btu' where uf = 'RJ' and cidade = 'Rio de Janeiro';
select sim.confere('cluster diferente da GDP → falha na conferência',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens('dharma')) i where i ->> 'codigo' = 'area_cluster_gdp' and i ->> 'nivel' = 'falha'), null);
