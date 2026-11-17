-- id: B3
-- titulo: Fora da área vira Saída; cliente responde "ok" e a conversa volta a fechar
-- tipo: atual
select sim.lead_novo('Carlos B3') as c \gset
select sim.mari_handoff(:'c', 'fora_de_area');
select sim.fila_rodar();
select sim.confere('o lead está em Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.confere('a conversa foi resolvida', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'ok, obrigado');
select sim.espera(:'c', '10 minutes');
select sim.confere('depois do "ok" a conversa terminou resolvida de novo', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
