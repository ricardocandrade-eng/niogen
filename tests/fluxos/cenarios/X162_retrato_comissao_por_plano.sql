-- id: X162
-- titulo: 0440 (auditoria de 25/11): o retrato do agente de tráfego traz a comissão de tabela por plano e a comissão média das vendas com OS e das instaladas da Meta, sem dado de cliente
-- tipo: atual
select sim.como('servico');
select public.agente_trafego_retrato(14)::text as r \gset

select sim.confere('o retrato tem a chave comissao com os planos ativos e o valor da config',
  ((:'r')::jsonb -> 'comissao' -> 'por_plano' -> 'V-REG-FIBRA' ->> 'comissao')::numeric
     = (select comissao from public.config_planos where codigo = 'V-REG-FIBRA' and ativo)
  and (select count(*) from jsonb_object_keys((:'r')::jsonb -> 'comissao' -> 'por_plano'))
     = (select count(*) from public.config_planos where ativo and codigo is not null),
  left(((:'r')::jsonb -> 'comissao' -> 'por_plano')::text, 300));

select sim.confere('vendas com OS e instaladas da Meta: contagem igual à do funil do retrato e soma coerente com a média',
  ((:'r')::jsonb -> 'comissao' -> 'meta_vendas_os' ->> 'vendas')::int >= ((:'r')::jsonb -> 'comissao' -> 'meta_instaladas' ->> 'vendas')::int
  and ((:'r')::jsonb -> 'comissao' -> 'meta_vendas_os' ->> 'com_plano')::int <= ((:'r')::jsonb -> 'comissao' -> 'meta_vendas_os' ->> 'vendas')::int
  and ((:'r')::jsonb -> 'comissao' -> 'meta_instaladas' ->> 'com_plano')::int <= ((:'r')::jsonb -> 'comissao' -> 'meta_instaladas' ->> 'vendas')::int,
  ((((:'r')::jsonb -> 'comissao') - 'por_plano'::text) - 'nota'::text)::text);

select sim.confere('as chaves antigas continuam lá (custo_por, totais, escada) e a comissão não traz dado de cliente',
  (:'r')::jsonb ? 'custo_por' and (:'r')::jsonb ? 'totais' and (:'r')::jsonb ? 'escada'
  and ((:'r')::jsonb -> 'comissao')::text !~ '\d{11}|@',
  (select string_agg(k, ',') from jsonb_object_keys((:'r')::jsonb) k));
