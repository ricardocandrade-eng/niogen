-- id: X90
-- titulo: 0364 (23/11): OS em "Draft" (cartão não pago em 48h) é rascunho — vai para a Live com a ação do time; venda em Saída não acende
-- tipo: atual
select sim.venda_pronta('Mirian X90') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '89' || sim._conv(:'c'), 'dia', (current_date + 5)::text, 'periodo', '13:00', 'forma', 'cartao'));
select sim.fila_rodar();
select sim.como('servico');
select public.os_registrar_leitura('89' || sim._conv(:'c'), 'operador', '{"status_ordem": "Draft"}'::jsonb);
select estado, excecao, coalesce(acao, '') as acao from public.os_andamento where pedido = '89' || sim._conv(:'c') \gset
select sim.confere('Draft é rascunho, não "texto novo"', :'estado' = 'rascunho' and :'acao' not like '%traduzir%', :'estado' || ' · ' || :'acao');
select sim.confere('venda em andamento com a OS em Draft: exceção com a ação do time', :'excecao'::boolean and :'acao' like '%48h%', :'acao');
select sim.confere('Draft não fica na lista do que falta traduzir',
  not exists (select 1 from public.config_os_estados where campo = 'status_ordem' and texto in ('Draft', 'Draft-') and estado is null), '');

-- a mesma leitura numa venda já em Saída não acende nada
select sim.venda_pronta('Saida X90') as s \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'s'), 'os_agendar', jsonb_build_object('os', '90' || sim._conv(:'s'), 'dia', (current_date + 5)::text, 'periodo', '13:00', 'forma', 'cartao'));
select sim.fila_rodar();
select sim.como('servico');
select sim.como('backoffice');
select public.lead_sair(:'s', null, 'teste_duplicada', null, null, null, true);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('a venda está em Saída', (select status = 'saida' from public.vendas where id = sim.venda(:'s')), '');
select public.os_registrar_leitura('90' || sim._conv(:'s'), 'operador', '{"status_ordem": "Draft"}'::jsonb);
select sim.confere('venda fora do andamento: OS em Draft não vai para a Live',
  (select not excecao from public.os_andamento where pedido = '90' || sim._conv(:'s')), '');
