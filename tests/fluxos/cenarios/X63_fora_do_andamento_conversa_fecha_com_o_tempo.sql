-- id: X63
-- titulo: 0335 (20/11, Chatwoot 189 e 138): o time escreve a um lead na Saída sem cobertura (não reabre: pede nova viabilidade) e a um cliente instalado → ficam onde estão, a conversa fica aberta com dono sem o projetor reclamar; 25 h parada → fechada e sem dono
-- tipo: atual
-- (a) Saída sem cobertura
select sim.lead_com_venda('Feli X60') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'viabilidade', '{"resultado":"sem_viabilidade"}');
select public.lead_sair(:'c', null, 'fachada_nao_atendida');
select sim.fila_rodar();
select sim.passa(:'c', '2 hours');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Tem outro endereço onde a gente possa ver a cobertura?');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('sem cobertura: continua na Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.confere('a conversa fica com dono', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select sim.confere('o projetor não vê contradição enquanto há conversa',
  not exists (select 1 from public.projetor_sombra p where p.conversa_id = :'c' and p.veredito in ('contraria', 'falta')
               and p.em > now() - interval '1 hour'),
  (select string_agg(veredito || ': ' || coalesce(motivo, ''), ' | ') from public.projetor_sombra p where p.conversa_id = :'c' and p.veredito in ('contraria', 'falta') and p.em > now() - interval '1 hour'));
select sim.espera(:'c', '25 hours');
select sim.tique();
select sim.confere('25 h parada: fechada e sem dono', sim.cw_de(:'c') ->> 'status' in ('resolved', 'snoozed') and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
select sim.confere('continua na Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);

-- (b) cliente instalado escreve e o time responde
select sim.venda_pronta('Pia X60') as i \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'i'), 'os_agendar', jsonb_build_object('os', '89' || sim._conv(:'i'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.passa(:'i', '2 days');
select sim.instalou(:'i');
select sim.espera(:'i', '3 hours');
select sim.confere('o lead está em Instalada', sim.lead_de(:'i') ->> 'destino' = 'instalada', sim.lead_de(:'i')::text);
select sim.cliente_escreve(:'i', 'a internet caiu agora de manhã');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'i', 'Vamos ver isso! Já reiniciou o roteador?');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('instalado: continua Instalada', sim.lead_de(:'i') ->> 'destino' = 'instalada', sim.lead_de(:'i')::text);
select sim.confere('instalado: conversa aberta com dono', sim.cw_de(:'i') ->> 'status' = 'open' and sim.cw_de(:'i') ->> 'agente' is not null, sim.cw_de(:'i')::text);
select sim.espera(:'i', '25 hours');
select sim.tique();
select sim.confere('instalado, 25 h parada: fechada e sem dono', sim.cw_de(:'i') ->> 'status' = 'resolved' and sim.cw_de(:'i') ->> 'agente' is null and sim.cw_de(:'i') ->> 'time' is null, sim.cw_de(:'i')::text);
