-- id: X21
-- titulo: OS cancelada no portal (Draft) para trocar o pagamento: o aviso do cartão espera; volta com a OS valendo
-- tipo: atual
select sim.venda_pronta('Lia X21') as c \gset
-- a Consulta OS já leu a OS como rascunho (cancelada para reemitir o pedido)
select sim.como('servico');
insert into public.os_andamento (pedido, venda_id, estado, status_ordem, origem_ultima)
values ('88' || sim._conv(:'c'), sim.venda(:'c'), 'rascunho', 'Draft', 'operador');
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '88' || sim._conv(:'c'), 'dia', (current_date + 5)::text, 'periodo', '13:00', 'forma', 'cartao'));
select sim.fila_rodar();
select sim.como('servico');
select count(*) from sim.cadencia(sim.meio_dia());
select sim.confere('com a OS em rascunho, o aviso do cartão não sai', sim.envios_de(:'c', 'cadencia:CARTAO') = 0, 'CARTAO: ' || sim.envios_de(:'c', 'cadencia:CARTAO'));
select sim.confere('a OS em rascunho não conta como cartão cadastrado', (select cartao_pago_em is null from public.vendas where id = sim.venda(:'c')), '');
-- a OS volta a valer (aguardando o pagamento) → o aviso sai
update public.os_andamento set estado = 'aguardando_pagamento', status_ordem = 'Aguardando Pagamento', mudou_em = now() where pedido = '88' || sim._conv(:'c');
select count(*) from sim.cadencia(sim.meio_dia() + interval '1 hour');
select sim.confere('com a OS valendo, o aviso do cartão sai uma vez', sim.envios_de(:'c', 'cadencia:CARTAO') = 1, 'CARTAO: ' || sim.envios_de(:'c', 'cadencia:CARTAO'));
