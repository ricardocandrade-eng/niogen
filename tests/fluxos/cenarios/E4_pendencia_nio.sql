-- id: E4
-- titulo: Pendência da Nio na instalação (técnico não achou o cliente): vez do time, nada automático ao cliente
-- tipo: atual
select sim.venda_pronta('Duda E4') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '84' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.como('servico');
select count(*) from sim.cadencia(sim.meio_dia());
select sim.fila_rodar();   -- 0366: o alerta de golpe sai logo depois da confirmação da instalação (é do agendamento, não da pendência)
select count(*) as antes from sim.envios where conversa = :'c' \gset
select sim._servico();
update public.vendas set nio_pendencia_cod = 'CLIENTE_AUSENTE', nio_pendencia_desc = 'técnico não encontrou o cliente' where id = sim.venda(:'c');
select sim.espera(:'c', '20 minutes');
select sim.confere('a escada mostra a pendência da Nio, vez do time', sim.lead_de(:'c') ->> 'status' = 'pendencia_nio' and sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('nada automático foi ao cliente', (select count(*) from sim.envios where conversa = :'c') = :antes,
  (select string_agg(por, ' ' order by n) from sim.envios where conversa = :'c'));
