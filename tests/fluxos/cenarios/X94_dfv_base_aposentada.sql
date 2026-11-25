-- id: X94
-- titulo: Caso L-248 (23/11): a venda nascia com o DFV da base antiga (nio_hp, foto de 03/11) — "não encontrado" num endereço que a API do Power BI dava viável, exato. Ricardo: "Aposente essa base antiga". Agora a base não é lida por ninguém da venda/ficha/Mari (dfv_consultar não devolve nada) e a venda nova leva o DFV da API que a conversa já consultou
-- tipo: regra_nova

-- A) a base antiga não responde mais
select sim.confere('dfv_consultar não lê mais a base antiga (nenhuma linha)',
  (select count(*) from public.dfv_consultar('36010000', '100', null)) = 0, null);

-- B) conversa com o DFV da API (viável, exato) → a venda nasce viável no DFV
select sim.lead_pronto('Gael X94') as a \gset
select sim._servico();
update public.mari_conversas set dfv_resultado = null, dfv_detalhe = null, cobertura_em = now(),
       cobertura_detalhe = jsonb_build_object('dfv', 'viavel', 'dfv_fonte', 'api', 'dfv_match', 'exato', 'portal', 'viavel')
 where id = :'a';
select sim.mari_handoff(:'a', 'dados_completos', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('a venda leva o DFV da API: viável',
  (select dfv_viabilidade from public.vendas where id = sim.venda(:'a')) = 'viavel',
  (select dfv_viabilidade || ' · ' || coalesce(dfv_resultado, '-') from public.vendas where id = sim.venda(:'a')));

-- C) conversa sem DFV da API → a venda fica "não consultado" (nunca o resultado da base antiga)
select sim.lead_pronto('Hana X94') as b \gset
select sim._servico();
update public.mari_conversas set dfv_resultado = null, dfv_detalhe = null, cobertura_detalhe = null where id = :'b';
select sim.mari_handoff(:'b', 'dados_completos', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('sem DFV da API: a venda fica não consultado (a base antiga não decide)',
  (select dfv_viabilidade from public.vendas where id = sim.venda(:'b')) = 'nao_consultado'
  and (select dfv_particao from public.vendas where id = sim.venda(:'b')) is null,
  (select dfv_viabilidade || ' · partição ' || coalesce(dfv_particao::text, '-') from public.vendas where id = sim.venda(:'b')));
