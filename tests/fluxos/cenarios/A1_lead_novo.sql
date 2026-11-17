-- id: A1
-- titulo: Lead novo escreve e a Mari atende
-- tipo: atual
select sim.lead_novo('Ana A1') as c \gset
select sim.confere('a Mari respondeu a primeira mensagem', exists (select 1 from sim.envios where conversa = :'c' and por = 'mari'));
select sim.confere('a vez é da Mari', sim.lead_de(:'c') ->> 'vez' = 'mari', sim.lead_de(:'c')::text);
select sim.confere('conversa aberta, sem dono e sem time', sim.cw_de(:'c') ->> 'status' = 'open' and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
