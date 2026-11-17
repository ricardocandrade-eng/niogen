-- id: C11
-- titulo: Em espera com data e o cliente escreve antes
-- tipo: atual
select sim.lead_novo('Nina C11') as c \gset
select sim.mari_handoff(:'c', 'pedido_humano');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select public.backoffice_conversa_espera(:'c', (current_date + 5), 'cliente viaja e volta semana que vem');
select sim.fila_rodar();
select sim.confere('em espera: conversa adiada', sim.cw_de(:'c') ->> 'status' in ('snoozed', 'resolved'), sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'voltei antes, podemos seguir?') as r \gset
select sim.fila_rodar();
select sim.confere('a espera acabou', (select espera_ate is null from public.mari_conversas where id = :'c'), (select 'espera até ' || espera_ate from public.mari_conversas where id = :'c'));
select sim.confere('a conversa abriu', sim.cw_de(:'c') ->> 'status' = 'open', sim.cw_de(:'c')::text);
select sim.confere('a Mari não respondeu no lugar do time', :'r' like 'calada%', :'r');
select sim.confere('a vez é do time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
