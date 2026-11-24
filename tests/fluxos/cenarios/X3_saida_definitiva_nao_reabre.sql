-- id: X3
-- titulo: Saída definitiva (crédito negado): cliente escreve e não reabre — desde a 0383 a Mari não responde, a conversa abre para o time e fecha de novo em 24 h
-- tipo: atual
select sim.lead_com_venda('Rita X3') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'credito_negado');
select sim.fila_rodar();
select sim.cliente_escreve(:'c', 'e aí, deu certo?') as r \gset
select sim.espera(:'c', '10 minutes');
select sim.confere('continua em Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.confere('a venda continua em Saída', sim.foto(:'c') -> 'venda' ->> 'status' = 'saida', (sim.foto(:'c') -> 'venda')::text);
-- 0383 (L-82, Ricardo 24/11: "Sim, repasse direto"): antes a conversa voltava a fechar e a Mari dava a "resposta curta"
select sim.confere('a Mari não responde', :'r' like 'calada:%', :'r');
select sim.confere('a conversa abre para o time', sim.cw_de(:'c') ->> 'status' = 'open', sim.cw_de(:'c')::text);
select sim.passa(:'c', '25 hours');
select public.porta('prazo:fora_fechar', :'c', null::uuid);
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('ninguém pegou em 24 h: a conversa terminou resolvida', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
