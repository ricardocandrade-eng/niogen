-- id: H1
-- titulo: Não contatar no meio da venda: a venda segue e nada mais sai, nem aviso da venda
-- tipo: atual
-- Decisão do Ricardo (17/11): "Venda segue, sem mensagens". Desistir da compra é outro evento (Saída ▾).
select sim.lead_com_venda('Flor H1') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select public.backoffice_momento(sim.venda(:'c'), 'biometria', '{"resultado":"validada"}');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '93' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select public.backoffice_momento(sim.venda(:'c'), 'parar');
select sim.fila_rodar();
select sim.confere('a venda segue aguardando a instalação', sim.foto(:'c') -> 'venda' ->> 'status' = '2_aguardando_instalacao', (sim.foto(:'c') -> 'venda')::text);
select sim.confere('o lead segue em andamento (não virou Saída)', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('o botão parar não resolveu a conversa',
  not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'parar' and a.tipo = 'resolver'), null);
select count(*) as antes from sim.envios where conversa = :'c' \gset
select public.backoffice_momento(sim.venda(:'c'), 'reagendar', jsonb_build_object('dia', (current_date + 5)::text, 'periodo', '13:00'));
select sim.fila_rodar();
select sim.confere('reagendar não manda nada ao cliente', (select count(*) from sim.envios where conversa = :'c') = :antes,
  (select string_agg(por, ' ' order by n) from sim.envios where conversa = :'c'));
select sim.como('servico');
select sim.passa(:'c', '4 days');
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('véspera e lembretes da venda não saem', :n = 0, 'envios da cadência: ' || :n);
select sim.cliente_escreve(:'c', 'oi') as r \gset
select sim.confere('a Mari fica calada', :'r' like 'calada%', :'r');
