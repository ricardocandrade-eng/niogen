-- id: X96
-- titulo: Conciliação (0371, Ricardo 23/11: "Já podemos iniciar a tela Conciliação"). O extrato quinzenal entra só por extrato_importar (admin/backoffice), casa a linha a linha pela OS, guarda o pedido de compra; reimportar o ciclo troca, não duplica; linha da Nio sem venda vira extra; a contestação só pela porta, com prazo de 120 dias; a conferência acusa extra e soma que não fecha
-- tipo: atual

-- A) venda instalada na 1ª quinzena com OS conhecida: o previsto nasce sozinho (350 + transição 30)
select sim.venda_pronta('Cliente X96') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', 'X96OS0001', 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.instalou(:'c');
select sim._servico();
update public.vendas set instalado_em = '2026-11-13 12:00-03', ativado_em = null, nio_os = 'X96OS0001', nio_pedido = 'X96OS0001',
       comissao_nominal = 350, comissao_adicionais = 0, bonus_transicao_previsto = 30, bonus_nmei_previsto = 0
 where id = sim.venda(:'c');
select sim.confere('previsto da venda X96 no ciclo 2026-11-1Q = 380',
  (select sum(valor) from public.comissao_lancamentos where venda_id = sim.venda(:'c') and origem = 'sistema' and ciclo = '2026-11-1Q') = 380,
  (select string_agg(tipo || ' ' || valor || ' ' || ciclo, ' · ') from public.comissao_lancamentos where venda_id = sim.venda(:'c')));

-- B) a porta: login sem perfil não importa
set role authenticated;
select sim.recusa($q$ select public.extrato_importar('x.xlsx', '{"LINHA_A_LINHA":[{"ANO":2026}]}') $q$) as recusa_login \gset
reset role;
select sim.confere('login sem perfil não chama extrato_importar', :'recusa_login' <> '', :'recusa_login');

-- C) o arquivo no formato real (colunas do 1Q de novembro), com a OS da venda X96
select sim.como('backoffice');
select public.extrato_importar('202611_1Q_X96.xlsx', $j${
  "PEDIDO": [{"CICLO": "1QNOV26", "DOCUMENTO DE COMPRAS": "4500000096", "ITEM": "10", "VALOR": 380, "STATUS": "Não Identificado",
              "STATUS_AJUSTADO": "-", "NF": "-", "PREVISAO_PG": null, "DT_COMPENSAÇÃO": "-", "COMPESAÇÃO": "N"}],
  "LINHA_A_LINHA": [
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "CICLO_COMPLEMENTAR": "NAO", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO",
     "PRODUTO": "Nio Fibra 600MB - Regular", "OFERTA": "BL_600MB", "METODO_PAGAMENTO": "Boleto", "CONTRATO": "9900096",
     "NUM_OS_PEDIDO_SIEBEL": "X96OS0001", "DATA_ATV": "46339", "COMISSAO": 350, "RECOMPRA": "-"},
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "CICLO_COMPLEMENTAR": "NAO", "EVENTO": "BONUS", "SUB_EVENTO": "TRANSICAO",
     "PRODUTO": "Nio Fibra 600MB - Regular", "OFERTA": "BL_600MB", "METODO_PAGAMENTO": "Boleto", "CONTRATO": "9900096",
     "NUM_OS_PEDIDO_SIEBEL": "X96OS0001", "DATA_ATV": "46339", "COMISSAO": 30, "RECOMPRA": "-"}]}$j$::jsonb) as r1 \gset
select sim.confere('1ª importação: 2 linhas casadas, 0 sem venda, soma = pedido',
  (:'r1'::jsonb ->> 'casadas')::int = 2 and (:'r1'::jsonb ->> 'sem_venda')::int = 0 and (:'r1'::jsonb ->> 'bate_pedido')::boolean
  and :'r1'::jsonb ->> 'ciclo' = '2026-11-1Q', :'r1');
select sim.confere('DATA_ATV do Excel (46339) vira 13/11/2026',
  (select bool_and(data_ref = date '2026-11-13') from public.comissao_lancamentos where venda_id = sim.venda(:'c') and origem = 'extrato'), null);
select sim.confere('a venda X96 bate: prevista 380, paga 380, com as 2 linhas da Nio',
  (select prevista = 380 and paga = 380 and jsonb_array_length(linhas) = 2 and nio_contrato = '9900096'
     from public.v_conciliacao where venda_id = sim.venda(:'c') and ciclo = '2026-11-1Q'),
  (select row_to_json(x)::text from public.v_conciliacao x where venda_id = sim.venda(:'c')));
select sim.confere('o pedido do ciclo: 4500000096, R$ 380, soma das linhas 380',
  (select documento_compras = '4500000096' and valor_pedido = 380 and soma_linhas = 380 and status_pedido = 'Não Identificado'
     from public.v_conciliacao_ciclos where ciclo = '2026-11-1Q'), null);
select sim.confere('a venda não foi tocada (contrato só na linha da Nio)',
  (select nio_contrato is null from public.vendas where id = sim.venda(:'c')), null);

-- D) reimportar o mesmo ciclo troca (versão nova da Nio), não duplica; linha sem venda vira extra
select public.extrato_importar('202611_1Q_X96_v1.xlsx', $j${
  "PEDIDO": [{"CICLO": "1QNOV26", "DOCUMENTO DE COMPRAS": "4500000096", "VALOR": 430}],
  "LINHA_A_LINHA": [
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO", "CONTRATO": "9900096",
     "NUM_OS_PEDIDO_SIEBEL": "X96OS0001", "DATA_ATV": "46339", "COMISSAO": 350},
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "BONUS", "SUB_EVENTO": "TRANSICAO", "CONTRATO": "9900096",
     "NUM_OS_PEDIDO_SIEBEL": "X96OS0001", "DATA_ATV": "46339", "COMISSAO": 30},
    {"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO", "CONTRATO": "9900097",
     "NUM_OS_PEDIDO_SIEBEL": "X96OS0002", "DATA_ATV": "46338", "COMISSAO": 50}]}$j$::jsonb) as r2 \gset
select sim.confere('reimportar: troca as 2 linhas antigas e grava 3 (1 sem venda)',
  (:'r2'::jsonb ->> 'substituiu')::int = 2 and (:'r2'::jsonb ->> 'sem_venda')::int = 1
  and (select count(*) from public.comissao_lancamentos where origem = 'extrato' and ciclo = '2026-11-1Q') = 3
  and (select count(*) from public.nio_extrato_pedidos where ciclo = '2026-11-1Q') = 1, :'r2');
select sim.confere('a linha sem venda aparece como extra (prevista vazia, paga 50)',
  (select prevista is null and paga = 50 and venda_id is null from public.v_conciliacao where ciclo = '2026-11-1Q' and nio_contrato = '9900097'), null);
select sim.confere('conferência: linha da Nio sem venda = atenção',
  (select x->>'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'conciliacao_extrato') = 'atencao',
  (select x::text from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'conciliacao_extrato'));

-- E) a contestação só pela porta, com prazo da ativação + 120 dias; estado só anda para a frente
select public.contestacao_registrar('2026-11-1Q', null, 'X96OS0002', '9900097', 'outro', 50, 'X96: contrato sem venda') as ct \gset
select sim.confere('contestação gravada com prazo de 120 dias da DATA_ATV (12/11 → 12/03/2027)',
  (select prazo_em = date '2026-11-12' + 120 and status = 'aberta' from public.nio_contestacoes where id = :'ct'), null);
select sim.confere('a extra contestada some da conferência e aparece como contestada na view',
  (select contestacao ->> 'status' = 'aberta' from public.v_conciliacao where ciclo = '2026-11-1Q' and nio_contrato = '9900097'), null);
select sim.confere('segunda contestação aberta para o mesmo contrato é recusada',
  sim.recusa($q$ select public.contestacao_registrar('2026-11-1Q', null, 'X96OS0002', '9900097', 'outro', 50, null) $q$) like '%Já existe%', null);
select sim.confere('aberta não vira aceita direto',
  sim.recusa(format($q$ select public.contestacao_mudar(%L, 'aceita') $q$, :'ct')) like '%não muda%', null);
select public.contestacao_mudar(:'ct', 'enviada', 'mandada ao Rogério');
select public.contestacao_mudar(:'ct', 'aceita', 'Nio paga no próximo ciclo');
select sim.confere('aberta → enviada → aceita',
  (select status = 'aceita' and resposta = 'Nio paga no próximo ciclo' from public.nio_contestacoes where id = :'ct'), null);
set role authenticated;
select sim.recusa($q$ insert into public.nio_contestacoes (ciclo, motivo, valor) values ('2026-11-1Q', 'outro', 1) $q$) as recusa_ins \gset
reset role;
select sim.confere('a tela não grava contestação direto na tabela', :'recusa_ins' <> '', :'recusa_ins');

-- F) soma que não fecha com o pedido = falha
select sim.como('backoffice');
select public.extrato_importar('202611_1Q_X96_v2.xlsx', $j${
  "PEDIDO": [{"CICLO": "1QNOV26", "DOCUMENTO DE COMPRAS": "4500000096", "VALOR": 999}],
  "LINHA_A_LINHA": [{"ANO": 2026, "MES": "NOV", "QUINZENA": "1Q", "EVENTO": "COMISSAO", "SUB_EVENTO": "COMISSAO_ATIVACAO",
     "NUM_OS_PEDIDO_SIEBEL": "X96OS0001", "DATA_ATV": "46339", "COMISSAO": 350}]}$j$::jsonb) as r3 \gset
select sim.confere('soma 350 × pedido 999: a importação avisa e a conferência acusa falha',
  not (:'r3'::jsonb ->> 'bate_pedido')::boolean
  and (select x->>'nivel' from jsonb_array_elements(public.conferencia_itens()) x where x->>'codigo' = 'conciliacao_extrato') = 'falha', :'r3');
select sim.confere('arquivo com dois ciclos é recusado',
  sim.recusa($q$ select public.extrato_importar('mistura.xlsx', '{"PEDIDO":[{"CICLO":"2QNOV26","VALOR":1}],"LINHA_A_LINHA":[{"ANO":2026,"MES":"NOV","QUINZENA":"1Q","COMISSAO":1}]}') $q$) like '%ciclo único%', null);
