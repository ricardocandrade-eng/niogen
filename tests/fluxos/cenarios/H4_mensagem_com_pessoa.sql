-- id: H4
-- titulo: Com uma pessoa conduzindo, nada automático sai na voz da Mari
-- tipo: atual
select sim.lead_com_venda('Gui H4') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.como('servico');
select sim.time_fala_no_chatwoot(:'c', 'Oi! Sou do time, vou cuidar do seu pedido.');
select sim.passa(:'c', '20 hours');
select sim.confere('com dono no Chatwoot', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('a cadência da Mari não toca por cima da pessoa', :n = 0, 'toques: ' || :n);
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}');
select public.backoffice_momento(sim.venda(:'c'), 'biometria', '{"resultado":"validada"}');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '94' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.confere('o aviso do botão sai em nome da pessoa, não da Mari',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem')
  and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem' and coalesce(a.payload ->> 'como', '') <> 'humano'),
  (select coalesce(string_agg(coalesce(a.payload ->> 'rotulo', '?') || '=' || coalesce(a.payload ->> 'como', 'mari'), ', '), 'nenhuma mensagem') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'mensagem'));
select sim.fila_rodar();
