-- id: X140
-- titulo: 0413 (Ricardo 26/11: "uma tela só, com dados bem organizados e a qualidade no topo" · "Tudo com filtro de datas"): o Radar Nio guarda um retrato por gráfico por dia (dados resumidos ou o texto da tela), a rodada das 05h30 pede só as abas do radar e a das 15h continua com OSAB e Faturas, radar_resumo devolve a régua do BKO com o número da Nio no período escolhido, só admin e backoffice abrem, e a conferência acende quando VI/VE/recompra passa de zero
-- tipo: atual
-- 0414 (26/11): título com número só casa se o resto for número — "VB - Mensal" não pega "VB - Mensal DU"
select sim.como('servico');

-- as duas rotinas: 15h com as 9 abas (as do radar só listadas) · 05h30 só as 6 do radar
select sim.confere('rotina das 15h continua com as 9 abas e nenhuma em modo radar',
  jsonb_array_length(public.dashboard_config() -> 'abas') = 9
  and not exists (select 1 from jsonb_array_elements(public.dashboard_config() -> 'abas') a where a ->> 'modo' = 'radar'),
  left((public.dashboard_config())::text, 300));
select sim.confere('rotina do radar pede só as 6 abas do radar, com a regra das 05h30',
  jsonb_array_length(public.dashboard_config('radar') -> 'abas') = 6
  and (public.dashboard_config('radar') -> 'regra' ->> 'hora') = '05:30',
  left((public.dashboard_config('radar'))::text, 300));

-- dia 1 (ontem): FPD 0 % em nov · funil pelo texto · eficácia pelo texto
select public.radar_importar(jsonb_build_object('dia', ((now() at time zone 'America/Sao_Paulo')::date - 1)::text, 'radar', jsonb_build_array(
  jsonb_build_object('aba', 'Indicadores Qualidade', 'visuais', jsonb_build_array(
    jsonb_build_object('visual', 'FPD VENCIMENTO', 'tipo', 'Gráfico de colunas', 'ordem', 1,
                       'colunas', '["ANOMES", "% FPD"]'::jsonb, 'linhas', '[["202610", 0.1], ["202611", 0.0]]'::jsonb),
    jsonb_build_object('visual', 'Venda Não Reconhecida Cliente', 'ordem', 8, 'colunas', '["ANOMES", "VI", "% VI"]'::jsonb, 'linhas', '[]'::jsonb))),
  jsonb_build_object('aba', 'Geral', 'visuais', jsonb_build_array(
    jsonb_build_object('visual', 'Funil de Vendas', 'tipo', 'Funil', 'ordem', 4, 'sem_exportar', true,
      'texto', 'Funil de Vendas 100% 1,2% Consulta Viabilidade Consulta Viavel Consulta Crédito Consuta Plano - Aprovados Pedido Gerado Venda Bruta Instalação 594 487 (82%) 121 (20%) 55 (9%) 11 (2%) 7 (1%) 7 (1%)'))),
  jsonb_build_object('aba', 'Eficácia', 'visuais', jsonb_build_array(
    jsonb_build_object('visual', '% Eficácia 100,0%', 'tipo', 'Cartão', 'ordem', 1, 'texto', '% Eficácia 100,0%'),
    jsonb_build_object('visual', 'Eficácia diária', 'ordem', 5, 'erro', 'TimeoutError: x'))),
  jsonb_build_object('aba', 'Operacional Vendas', 'visuais', jsonb_build_array(
    jsonb_build_object('visual', 'VB - Mensal', 'ordem', 3, 'texto', 'VB - Mensal 202611 7'),
    jsonb_build_object('visual', 'VB - Mensal DU', 'ordem', 8, 'texto', 'VB - Mensal DU 202611 1')))))) as r1 \gset
select sim.confere('radar_importar conta exportados, texto e erro',
  (:'r1'::jsonb ->> 'exportados')::int = 2 and (:'r1'::jsonb ->> 'texto')::int = 4 and (:'r1'::jsonb ->> 'erros')::int = 1, :'r1');

-- dia 2 (hoje): VI = 1 em nov (estorno!) e o funil cresce; a mesma leitura repetida no dia não duplica
select public.radar_importar(jsonb_build_object('radar', jsonb_build_array(
  jsonb_build_object('aba', 'Indicadores Qualidade', 'visuais', jsonb_build_array(
    jsonb_build_object('visual', 'Venda Não Reconhecida Cliente', 'ordem', 8, 'colunas', '["ANOMES", "VI", "% VI"]'::jsonb,
                       'linhas', '[["202611", 1.0, 0.142857]]'::jsonb))),
  jsonb_build_object('aba', 'Geral', 'visuais', jsonb_build_array(
    jsonb_build_object('visual', 'Funil de Vendas', 'ordem', 4,
      'texto', 'Funil de Vendas Instalação 1.210 600 (50%) 130 (11%) 60 (5%) 12 (1%) 8 (1%) 8 (1%)')))))) as r2 \gset
select public.radar_importar(jsonb_build_object('radar', jsonb_build_array(
  jsonb_build_object('aba', 'Geral', 'visuais', jsonb_build_array(
    jsonb_build_object('visual', 'Funil de Vendas', 'ordem', 4,
      'texto', 'Funil de Vendas Instalação 1.210 600 (50%) 130 (11%) 60 (5%) 12 (1%) 8 (1%) 8 (1%)')))))) as r3 \gset
select sim.confere('a mesma leitura no mesmo dia não duplica',
  (select count(*) from public.nio_radar_leituras where visual = 'Funil de Vendas' and dia = (now() at time zone 'America/Sao_Paulo')::date) = 1, '');

-- a tela: admin abre, período do mês corrente
select sim.como('admin');
select public.radar_resumo((date_trunc('month', now() at time zone 'America/Sao_Paulo'))::date, (now() at time zone 'America/Sao_Paulo')::date) as rr \gset
select sim.confere('o funil traz a última leitura do período (1.210 consultas, 8 instalações) e a série dos dias',
  (select (i ->> 'valor')::numeric = 1210 and jsonb_array_length(i -> 'serie') >= 1 from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i where i ->> 'chave' = 'funil_viab')
  and (select (i ->> 'valor')::numeric = 8 from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i where i ->> 'chave' = 'funil_inst'),
  left((select string_agg((i ->> 'chave') || '=' || coalesce(i ->> 'valor', 'null'), ' ') from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i), 400));
select sim.confere('eficácia vem do texto "100,0%" como fração 1 (o título do cartão traz o número: casa pelo começo)',
  (select (i ->> 'valor')::numeric = 1 from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i where i ->> 'chave' = 'eficacia')
  or to_char(now() at time zone 'America/Sao_Paulo', 'DD') = '01',   -- dia 1: a leitura de ontem é do mês passado
  '');
select sim.confere('0414: o VB do mês é 7 — o gráfico "VB - Mensal DU" (por dia útil) não entra no "VB - Mensal"',
  (select (i ->> 'valor')::numeric = 7 and jsonb_array_length(i -> 'serie') <= 1 from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i where i ->> 'chave' = 'vb')
  or to_char(now() at time zone 'America/Sao_Paulo', 'DD') = '01',
  (select i::text from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i where i ->> 'chave' = 'vb'));
select sim.confere('FPD do BKO só com os meses do período (out/26 fora quando o período é nov)',
  (select not exists (select 1 from jsonb_array_elements(i -> 'serie') s where s ->> 'x' < to_char(now() at time zone 'America/Sao_Paulo', 'YYYYMM'))
     from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i where i ->> 'chave' = 'fpd'),
  '');
select sim.confere('a régua do BKO vem com os 5 pesos (35+20+20+15+10)',
  (select sum((i ->> 'peso_bko')::int) from jsonb_array_elements(:'rr'::jsonb -> 'indicadores') i where i ->> 'grupo' = 'bko') = 100, '');
select sim.confere('o gráfico com erro não aparece como leitura válida',
  not exists (select 1 from jsonb_array_elements(:'rr'::jsonb -> 'visuais') v where v ->> 'visual' = 'Eficácia diária'), '');
select sim.confere('o nosso número vem junto (OS geradas, instaladas, faturas)',
  (:'rr'::jsonb -> 'nosso') ? 'os_geradas' and (:'rr'::jsonb -> 'nosso') ? 'faturas_vencidas', left((:'rr'::jsonb -> 'nosso')::text, 200));

-- vendedor não abre
select sim.como('vendedor');
select sim.confere('vendedor não abre o Radar', sim.recusa($q$select public.radar_resumo(null, null)$q$) is not null, '');

-- conferência: VI = 1 no mês acende o item do radar
select sim.como('admin');
select sim.confere('conferência acende o Radar com o VI acima de zero',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens()) i where i ->> 'codigo' = 'radar_rotina' and i ->> 'nivel' = 'atencao'),
  left((select i::text from jsonb_array_elements(public.conferencia_itens()) i where i ->> 'codigo' = 'radar_rotina'), 300));
