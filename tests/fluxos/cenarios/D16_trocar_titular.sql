-- id: D16
-- titulo: Trocar o titular depois da OS é recusado (é Saída e venda nova)
-- tipo: atual
select sim.venda_pronta('Bia D16') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '86' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.como('backoffice');
select coalesce(sim.recusa(format('select public.venda_trocar_titular(%L, %L, %L, %L, %L)', sim.venda(:'c'), 'Outro Titular Simulado',
  sim.cpf(555000 + sim._conv(:'c')::int % 1000), 'pai', 'teste')), '') as rec \gset
select sim.confere('depois da OS a troca de titular é recusada', :'rec' <> '', coalesce(nullif(:'rec', ''), 'aceitou'));
