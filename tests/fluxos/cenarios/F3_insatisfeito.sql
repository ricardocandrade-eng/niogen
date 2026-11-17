-- id: F3
-- titulo: Instalado insatisfeito: vai para o time e não sai pedido de indicação
-- tipo: atual
select sim.venda_pronta('Fabi F3') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '82' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.passa(:'c', '2 days');
select sim.instalou(:'c');
select sim.espera(:'c', '90 minutes');
select count(*) as antes from sim.envios where conversa = :'c' \gset
select sim.cliente_escreve(:'c', 'Não deu certo não, a internet não funciona e o técnico deixou tudo bagunçado');
select sim.fila_rodar();
select sim.espera(:'c', '20 minutes');
select sim.confere('não saiu pedido de indicação', coalesce((select estado from public.pos_instalacao where venda_id = sim.venda(:'c')), '') <> 'pediu',
  'pós-instalação: ' || coalesce((select estado from public.pos_instalacao where venda_id = sim.venda(:'c')), 'nenhuma'));
select sim.confere('o time ficou sabendo (pós-venda ou time na conversa)', (sim.cw_de(:'c') -> 'etiquetas') ? 'pos-venda' or sim.cw_de(:'c') ->> 'time' is not null,
  sim.cw_de(:'c')::text);
select sim.confere('a conversa ficou aberta para o time', sim.cw_de(:'c') ->> 'status' = 'open', sim.cw_de(:'c')::text);
