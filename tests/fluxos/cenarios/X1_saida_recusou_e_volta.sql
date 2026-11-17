-- id: X1
-- titulo: Saída "Recusou" de lead sem venda, e o cliente volta
-- tipo: atual
select sim.lead_novo('Olga X1') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.confere('lead em Saída Recusou', sim.lead_de(:'c') ->> 'destino' = 'saida' and sim.lead_de(:'c') ->> 'saida' = 'recusou', sim.lead_de(:'c')::text);
select sim.confere('conversa resolvida, sem dono e sem time', sim.cw_de(:'c') ->> 'status' = 'resolved' and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
select sim.confere('etiqueta saida-recusou', (sim.cw_de(:'c') -> 'etiquetas') ? 'saida-recusou', (sim.cw_de(:'c') -> 'etiquetas')::text);
select sim.passa(:'c', '2 days');
select count(*) as n from sim.cadencia(sim.meio_dia()) x where x like '%enviado' \gset
select sim.confere('a cadência não manda nada para quem saiu', :n = 0, 'envios: ' || :n);
select sim.cliente_escreve(:'c', 'pensei melhor, quero sim') as r \gset
select sim.fila_rodar();
select sim.confere('a Mari respondeu', :'r' = 'respondeu', :'r');
select sim.confere('voltou para em andamento', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('conversa aberta', sim.cw_de(:'c') ->> 'status' = 'open', sim.cw_de(:'c')::text);
