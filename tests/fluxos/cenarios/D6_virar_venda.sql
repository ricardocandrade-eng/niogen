-- id: D6
-- titulo: Lead conduzido pelo time vira venda: uma linha só na escada, com a vez do time
-- tipo: atual
select sim.lead_pronto('Abel D6') as c \gset
select sim.time_no_chatwoot(:'c', '{"agente":"Atendente"}');
select sim.time_fala_no_chatwoot(:'c', 'Oi, sou do time. Vou rodar seu crédito.');
select sim.como('backoffice');
select public.lead_virar_venda(:'c');
select sim.fila_rodar();
select sim.confere('a venda nasceu', sim.venda(:'c') is not null, null);
select sim.confere('o lead tem a vez do time', sim.lead_de(:'c') ->> 'vez' = 'time' and sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('a pessoa continua dona da conversa', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
