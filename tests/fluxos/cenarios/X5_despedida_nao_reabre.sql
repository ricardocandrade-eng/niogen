-- id: X5
-- titulo: Saída "Recusou": dias depois o cliente só agradece ("ok, obrigado") e a conversa não reabre
-- tipo: atual
select sim.lead_novo('Lia X5') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.como('servico');
select sim.passa(:'c', '2 days');
select sim.cliente_escreve(:'c', 'ok, obrigado', false);
select sim.fila_rodar();
select sim.espera(:'c', '20 minutes');
select sim.confere('continua em Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.confere('a conversa voltou a ficar resolvida', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
