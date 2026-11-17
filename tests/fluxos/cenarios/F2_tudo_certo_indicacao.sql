-- id: F2
-- titulo: Instalado responde "deu tudo certo": sai o pedido de indicação e a conversa fecha sozinha (F2 + F4)
-- tipo: atual
select sim.venda_pronta('Rui F2') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '88' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.passa(:'c', '2 days');   -- a instalação é dias depois do agendamento (a pós-instalação espera 2 h de qualquer fala do time)
select sim.instalou(:'c');
select sim.espera(:'c', '90 minutes');
select count(*) as antes from sim.envios where conversa = :'c' \gset
select sim.cliente_escreve(:'c', 'Deu tudo certo sim, obrigado!') as r \gset
select sim.fila_rodar();
select sim.espera(:'c', '20 minutes');
select sim.confere('saiu o pedido de indicação', (select estado from public.pos_instalacao where venda_id = sim.venda(:'c')) = 'pediu',
  'pós-instalação: ' || coalesce((select estado from public.pos_instalacao where venda_id = sim.venda(:'c')), 'nenhuma'));
select sim.confere('uma mensagem ao cliente depois do "tudo certo"', (select count(*) from sim.envios where conversa = :'c') = :antes + 1,
  (select count(*) - :antes || ' mensagens' from sim.envios where conversa = :'c'));
select sim.espera(:'c', '1 day');
select sim.confere('a conversa fechou sozinha (vez do cliente)', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
