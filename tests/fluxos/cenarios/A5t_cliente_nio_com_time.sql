-- id: A5t
-- titulo: Pediu uma pessoa e era cliente Nio: a Saída "já é cliente Nio" tira o time da conversa
-- tipo: atual
select sim.lead_novo('Ruth A5t') as c \gset
select sim.cliente_escreve(:'c', 'quero falar com um atendente');
select sim.mari_handoff(:'c', 'pedido_humano', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('foi para o time', sim.cw_de(:'c') ->> 'time' is not null, sim.cw_de(:'c')::text);
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'ja_cliente_nio');
select sim.fila_rodar();
select sim.como('servico');
select sim.espera(:'c', '10 minutes');
select sim.confere('Cliente Nio: ninguém fica com a conversa', sim.cw_de(:'c') ->> 'time' is null and sim.cw_de(:'c') ->> 'agente' is null
  and sim.cw_de(:'c') ->> 'status' in ('resolved', 'snoozed'), sim.cw_de(:'c')::text);
