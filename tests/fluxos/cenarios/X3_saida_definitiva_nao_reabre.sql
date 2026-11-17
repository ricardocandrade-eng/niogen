-- id: X3
-- titulo: Saída definitiva (crédito negado): cliente escreve e não reabre
-- tipo: regra_nova
select sim.lead_com_venda('Rita X3') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'credito_negado');
select sim.fila_rodar();
select sim.cliente_escreve(:'c', 'e aí, deu certo?');
select sim.espera(:'c', '10 minutes');
select sim.confere('continua em Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.confere('a venda continua em Saída', sim.foto(:'c') -> 'venda' ->> 'status' = 'saida', (sim.foto(:'c') -> 'venda')::text);
select sim.confere('a conversa terminou resolvida', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
