-- id: X61
-- titulo: 0335 (20/11): o time escreve a um lead na Saída "Recusou" → o lead volta ("Com o time · esperando o cliente", conversa aberta com dono); 24 h sem resposta → volta à mesma Saída, conversa fechada e sem dono
-- tipo: atual
select sim.lead_novo('Raul X58') as c \gset
select sim.cliente_escreve(:'c', 'oi, quanto custa a internet?');
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'preco');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('começa na Saída', sim.lead_de(:'c') ->> 'destino' = 'saida', sim.lead_de(:'c')::text);
select sim.passa(:'c', '2 hours');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Raul! Saiu uma condição nova no plano de 500, quer ver?');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('o time escreveu: o lead voltou, esperando o cliente', :'s1' = 'time_esperando', :'s1' || ' · ' || sim.lead_de(:'c')::text);
select sim.confere('conversa aberta com dono', sim.cw_de(:'c') ->> 'status' = 'open' and sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select coalesce((select concorda::text from public.porta_sombra where conversa_id = :'c' and evento = 'time_respondeu' order by id desc limit 1), 'sem anotação') as k1 \gset
select sim.confere('a porta concorda com a volta', :'k1' = 'true', :'k1');
select sim.espera(:'c', '25 hours');
select sim.tique();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s2 \gset
select sim.confere('24 h sem resposta: de volta à Saída', :'s2' = 'saida_pode_voltar', :'s2' || ' · ' || sim.lead_de(:'c')::text);
select sim.confere('a mesma Saída: Recusou', (select saida_motivo = 'recusou' from public.mari_conversas where id = :'c'),
  (select coalesce(saida_motivo, '-') || ' / ' || coalesce(saida_sub, '-') from public.mari_conversas where id = :'c'));
select sim.confere('conversa fechada e sem dono', sim.cw_de(:'c') ->> 'status' in ('resolved', 'snoozed') and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
select sim.confere('a marca da volta saiu', (select volta_time_em is null from public.mari_conversas where id = :'c'), '');
select coalesce((select concorda::text from public.porta_sombra where conversa_id = :'c' and evento = 'prazo:volta_saida' order by id desc limit 1), 'sem anotação') as k2 \gset
select sim.confere('a porta anotou a volta à Saída e concorda', :'k2' = 'true', :'k2');
