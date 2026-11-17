-- id: B6
-- titulo: Cliente some: a cadência toca e termina em Saída sem resposta
-- tipo: atual
select sim.lead_novo('Davi B6') as c \gset
select sim.silencio(:'c', 24);
select sim.confere('a cadência mandou ao menos 3 toques', (select count(*) from sim.envios where conversa = :'c' and por like 'cadencia:%') >= 3,
  (select coalesce(string_agg(por, ' ' order by n), 'nenhum') from sim.envios where conversa = :'c' and por like 'cadencia:%'));
select sim.confere('terminou em Saída sem resposta', sim.lead_de(:'c') ->> 'destino' = 'saida' and sim.lead_de(:'c') ->> 'saida' = 'sem_resposta', sim.lead_de(:'c')::text);
select sim.confere('a conversa terminou resolvida', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
