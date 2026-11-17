-- id: C4
-- titulo: Handoff e o time não responde: em 24 h úteis volta para a Mari
-- tipo: regra_nova
select sim.lead_novo('Edu C4') as c \gset
select sim.cliente_escreve(:'c', 'quero falar com uma pessoa');
select sim.mari_handoff(:'c', 'pedido_humano', '{}'::jsonb);
select sim.fila_rodar();
select sim.confere('foi para o time', sim.cw_de(:'c') ->> 'time' is not null, sim.cw_de(:'c')::text);
select sim.espera(:'c', '4 days');
select sim.confere('ninguém respondeu: depois de 24 h úteis o time saiu da conversa', sim.cw_de(:'c') ->> 'time' is null and not (sim.foto(:'c') ->> 'time')::boolean,
  sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'oi, alguém aí?') as r \gset
select sim.confere('o cliente escreve e a Mari responde', :'r' = 'respondeu', :'r');
