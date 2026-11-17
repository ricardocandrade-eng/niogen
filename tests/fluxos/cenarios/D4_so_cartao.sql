-- id: D4
-- titulo: Crédito aprovado só no cartão: a OS no boleto é recusada
-- tipo: regra_nova
select sim.lead_com_venda('Yan D4') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"so_cartao"}') as r \gset
select sim.confere('o botão avisa para trocar a forma de pagamento', :'r' like '%cartão%', :'r');
select public.backoffice_momento(sim.venda(:'c'), 'biometria', '{"resultado":"validada"}');
select coalesce(sim.recusa(format('select public.backoffice_momento(%L, %L, %L::jsonb)', sim.venda(:'c'), 'os_agendar',
  jsonb_build_object('os', '87' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto')::text)), '') as rec \gset
select sim.confere('OS no boleto com crédito só no cartão é recusada', :'rec' <> '', coalesce(nullif(:'rec', ''), 'aceitou'));
