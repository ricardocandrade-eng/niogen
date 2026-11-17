-- id: D1
-- titulo: Venda completa: crédito, biometria, OS e agenda
-- tipo: atual
select sim.lead_com_venda('Ugo D1') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select sim.fila_rodar();
select sim.confere('depois do crédito: lead em Qualificado', sim.lead_de(:'c') ->> 'etapa' = 'qualificado', sim.lead_de(:'c')::text);
select public.backoffice_momento(sim.venda(:'c'), 'biometria', '{"resultado":"validada"}');
select sim.fila_rodar();
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '99' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.confere('a venda saiu de Qualificado', sim.foto(:'c') -> 'venda' ->> 'status' in ('1_vendido', '2_aguardando_instalacao'), (sim.foto(:'c') -> 'venda')::text);
select sim.confere('o lead está no degrau Instalação', sim.lead_de(:'c') ->> 'etapa' = 'instalacao', sim.lead_de(:'c')::text);
select sim.confere('o cliente recebeu o aviso do agendamento', exists (select 1 from sim.envios where conversa = :'c' and por <> 'mari'),
  (select coalesce(string_agg(por, ' ' order by n), 'nenhum envio') from sim.envios where conversa = :'c'));
