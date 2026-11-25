-- id: X132
-- titulo: 0402 (casos L-377 e Miriam): Saída de venda com a OS em Aguardando Pagamento ou Draft (cartão que o cliente não vai cadastrar) não cria a linha "Cancelar na Nio"; se a OS voltar a andar na Nio, a linha aparece
-- tipo: atual
select sim.venda_pronta('Cleo X132') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '77' || sim._conv(:'c'), 'dia', (current_date + 5)::text, 'periodo', '13:00', 'forma', 'cartao'));
select sim.fila_rodar();
select sim.como('servico');
select public.os_registrar_leitura('77' || sim._conv(:'c'), 'operador', '{"status_ordem": "Aguardando Pagamento"}'::jsonb);
select sim.confere('a OS está em Aguardando Pagamento', (select estado = 'aguardando_pagamento' from public.os_andamento where pedido = '77' || sim._conv(:'c')), '');

-- 1) Saída "só cartão, sem cartão": a tela não pergunta e manda "não cancelei" (a porta exige a resposta): não nasce "Cancelar na Nio"
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'credito_negado', 'só cartão, sem cartão', null, null, false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('a venda está em Saída', (select status = 'saida' from public.vendas where id = sim.venda(:'c')), '');
select sim.confere('Aguardando Pagamento: sem a linha Cancelar na Nio',
  not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'cancelar_nio' and x ->> 'venda_id' = sim.venda(:'c')::text), 'apareceu');

-- 2) a OS vira Draft: continua sem a linha
select sim.como('servico');
select public.os_registrar_leitura('77' || sim._conv(:'c'), 'operador', '{"status_ordem": "Draft"}'::jsonb);
select sim.como('backoffice');
select sim.confere('Draft: sem a linha Cancelar na Nio',
  not exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'cancelar_nio' and x ->> 'venda_id' = sim.venda(:'c')::text), 'apareceu');

-- 3) o cliente cadastrou o cartão depois da Saída e a OS andou: aí sim o time precisa agir
select sim.como('servico');
select public.os_registrar_leitura('77' || sim._conv(:'c'), 'operador', '{"status_ordem": "Em Aprovisionamento"}'::jsonb);
select sim.como('backoffice');
select sim.confere('a OS voltou a andar: a linha Cancelar na Nio aparece',
  exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'cancelar_nio' and x ->> 'venda_id' = sim.venda(:'c')::text), 'não apareceu');

-- 4) controle: Saída com pedido sem leitura de OS continua cobrando o cancelamento (regra de sempre, X11)
select sim.lead_com_venda('Otto X132') as v \gset
select sim._servico();
update public.vendas set nio_pedido = '13' || lpad(sim._conv(:'v'), 6, '0') where id = sim.venda(:'v');
select sim.como('backoffice');
select public.lead_sair(:'v', sim.venda(:'v'), 'recusou', 'preco', null, null, false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('sem leitura da OS, a linha Cancelar na Nio continua aparecendo',
  exists (select 1 from jsonb_array_elements(public.live_conferir()) x where x ->> 'tipo' = 'cancelar_nio' and x ->> 'venda_id' = sim.venda(:'v')::text), 'não apareceu');
