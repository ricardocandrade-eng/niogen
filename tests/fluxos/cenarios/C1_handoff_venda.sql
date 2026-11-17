-- id: C1
-- titulo: Dados completos: a Mari cria a venda e passa para o time
-- tipo: atual
select sim.lead_com_venda('Fabio C1') as c \gset
select sim.confere('a venda nasceu em Qualificado', sim.foto(:'c') -> 'venda' ->> 'status' = '0_qualificado', (sim.foto(:'c') -> 'venda')::text);
select sim.confere('a conversa está com o time', sim.cw_de(:'c') ->> 'time' is not null, sim.cw_de(:'c')::text);
select sim.confere('a vez é do time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('o time tem prazo para agir', sim.lead_de(:'c') ->> 'prazo' is not null, sim.lead_de(:'c')::text);
