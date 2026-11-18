-- id: X28
-- titulo: Saída "Teste ou duplicada" dada pela porta fica — o gatilho do funil não a desfaz quando o telefone não está na lista de teste (0291)
-- tipo: atual
-- Caso da conversa nº 91 (18/11): a porta aceitava a Saída e, na gravação seguinte, o _funil_antes devolvia o lead a "em andamento"
-- ("saída dura não vale mais"), porque "teste" só valia com o telefone em telefones_teste. A conversa reabria e a varredura voltava.
select sim.lead_novo('Teo X28') as c \gset
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'teste_duplicada');
select sim.fila_rodar();
select sim.confere('lead em Saída Teste ou duplicada',
  (select funil_destino from public.mari_conversas where id = :'c') = 'teste_duplicada',
  (select funil_destino || ' · ' || coalesce(saida_motivo, '-') from public.mari_conversas where id = :'c'));
select sim.confere('conversa resolvida', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
-- qualquer gravação na linha do lead (espelho, cadência, Mari) passava pelo gatilho e desfazia a Saída
update public.mari_conversas set updated_at = now() where id = :'c';
select sim.espera(:'c', '30 minutes');
select sim.confere('continua em Teste ou duplicada depois de outra gravação',
  (select funil_destino from public.mari_conversas where id = :'c') = 'teste_duplicada',
  (select funil_destino || ' · ' || coalesce(funil_detalhe, '-') from public.mari_conversas where id = :'c'));
select sim.confere('a conversa continua resolvida (nada reabre)', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
select sim.confere('situação Saída definitiva',
  (select situacao from public.v_lead_situacao where conversa_id = :'c') = 'saida_definitiva',
  (select situacao from public.v_lead_situacao where conversa_id = :'c'));
