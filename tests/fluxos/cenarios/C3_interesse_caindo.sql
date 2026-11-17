-- id: C3
-- titulo: Handoff "interesse caindo" não passa para o time: fica com a Mari
-- tipo: regra_nova
select sim.lead_novo('Hugo C3') as c \gset
select sim.mari_handoff(:'c', 'interesse_caindo');
select sim.fila_rodar();
select sim.confere('o lead continua em andamento', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('a vez continua da Mari', sim.lead_de(:'c') ->> 'vez' = 'mari', sim.lead_de(:'c')::text);
select sim.cliente_escreve(:'c', 'me explica melhor o plano') as r \gset
select sim.confere('a Mari responde quando o cliente escreve', :'r' = 'respondeu', :'r');
