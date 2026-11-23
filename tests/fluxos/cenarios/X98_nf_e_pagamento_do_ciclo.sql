-- id: X98
-- titulo: NF e pagamento do ciclo (0373, Ricardo 23/11: "Não vem mais um novo extrato" — a Nio só manda o extrato; NF e pagamento o NIOGEN registra). A NF só entra para pedido de extrato importado, pela porta, com autor; NF enviada ganha previsão de 10 dias úteis; pago o pedido inteiro, a venda vira "paga" na trilha do dinheiro; reimportar o extrato não apaga a NF; a conferência cobra pedido sem NF e pagamento atrasado ou diferente
-- tipo: atual

-- A) venda instalada na 1ª quinzena e o extrato do ciclo importado (mesmo formato do X96)
select sim.venda_pronta('Cliente X97') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', 'X97OS0001', 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.instalou(:'c');
select sim._servico();
update public.vendas set instalado_em = '2026-11-13 12:00-03', ativado_em = null, nio_os = 'X97OS0001', nio_pedido = 'X97OS0001',
       comissao_nominal = 350, comissao_adicionais = 0, bonus_transicao_previsto = 30, bonus_nmei_previsto = 0
 where id = sim.venda(:'c');
select sim.como('backoffice');
select public.extrato_importar('202611_1Q_X97.xlsx', $j${
  "PEDIDO": [{"CICLO": "1QNOV26", "DOCUMENTO DE COMPRAS": "4500000097", "ITEM": "10", "VALOR": 380, "STATUS": "Não Identificado"}],
  "LINHA_A_LINHA": [
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO", "NUM_OS_PEDIDO_SIEBEL": "X97OS0001", "DATA_ATV": "46339", "COMISSAO": 350},
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "BONUS", "SUB_EVENTO": "TRANSICAO", "NUM_OS_PEDIDO_SIEBEL": "X97OS0001", "DATA_ATV": "46339", "COMISSAO": 30}]}$j$::jsonb);

-- B) a porta: sem perfil não registra; pedido fora de extrato é recusado; pagamento antes da NF é recusado
select sim.como('vendedor');
select coalesce(sim.recusa($q$ select public.ciclo_nf_registrar('4500000097', '10', '123', current_date) $q$), '') as recusa_login \gset
select sim.confere('vendedor não registra NF', :'recusa_login' <> '', :'recusa_login');
select sim.como('backoffice');
select sim.confere('NF de pedido que não veio em extrato é recusada',
  sim.recusa($q$ select public.ciclo_nf_registrar('4599999999', '10', '1', current_date) $q$) like '%não está em nenhum extrato%', null);
select sim.confere('pagamento antes da NF é recusado',
  sim.recusa($q$ select public.ciclo_pagamento_registrar('4500000097', '10', current_date, 380) $q$) like '%Registre a NF%', null);

-- C) NF emitida e enviada: a previsão é o envio + 10 dias úteis; a tela vê o número
select public.ciclo_nf_registrar('4500000097', '10', '97', current_date - 1, current_date);
select sim.confere('o ciclo mostra a NF 97 e a previsão de pagamento em 10 dias úteis',
  (select numero_nf = '97' and nf_enviada_em = current_date and previsao_pg = public._dias_uteis_somar(current_date, 10)
          and previsao_pg >= current_date + 14 and jsonb_array_length(pedidos) = 1
     from public.v_conciliacao_ciclos where ciclo = '2026-11-1Q'),
  (select row_to_json(x)::text from public.v_conciliacao_ciclos x where ciclo = '2026-11-1Q'));

-- D) reimportar o extrato não apaga a NF
select public.extrato_importar('202611_1Q_X97_v1.xlsx', $j${
  "PEDIDO": [{"CICLO": "1QNOV26", "DOCUMENTO DE COMPRAS": "4500000097", "ITEM": "10", "VALOR": 380}],
  "LINHA_A_LINHA": [
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO", "NUM_OS_PEDIDO_SIEBEL": "X97OS0001", "DATA_ATV": "46339", "COMISSAO": 350},
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "BONUS", "SUB_EVENTO": "TRANSICAO", "NUM_OS_PEDIDO_SIEBEL": "X97OS0001", "DATA_ATV": "46339", "COMISSAO": 30}]}$j$::jsonb);
select sim.confere('depois de reimportar, a NF 97 continua no ciclo',
  (select numero_nf from public.v_conciliacao_ciclos where ciclo = '2026-11-1Q') = '97', null);

-- E) pagamento recebido: a venda chega a "paga"; diferença do pedido vira falha na conferência
select public.ciclo_pagamento_registrar('4500000097', '10', current_date, 380) as pg \gset
select sim.confere('pagamento de 380 bate com o pedido e lança 2 pagamentos na razão',
  (:'pg'::jsonb ->> 'bate')::boolean and (:'pg'::jsonb ->> 'lancamentos')::int = 2, :'pg');
select sim.confere('a trilha do dinheiro da venda X97 fica "paga" com 380',
  (select estado = 'paga' and pago = 380 from public.v_dinheiro where venda_id = sim.venda(:'c')),
  (select estado || ' ' || pago from public.v_dinheiro where venda_id = sim.venda(:'c')));
select sim.confere('NF não muda depois do pagamento',
  sim.recusa($q$ select public.ciclo_nf_registrar('4500000097', '10', '98', current_date) $q$) like '%já tem pagamento%', null);
select public.ciclo_pagamento_registrar('4500000097', '10', current_date, 300);
select sim.confere('pagamento de 300 num pedido de 380: conferência acusa falha e a razão não duplica',
  (select x->>'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'ciclo_nf_pagamento') = 'falha'
  and (select count(*) from public.comissao_lancamentos where tipo = 'pagamento' and venda_id = sim.venda(:'c')) = 2,
  (select x::text from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'ciclo_nf_pagamento'));
