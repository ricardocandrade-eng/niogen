-- id: H3
-- titulo: Alguém resolve direto no Chatwoot um lead em andamento com a Mari
-- tipo: atual
select sim.lead_novo('Tiago H3') as c \gset
select sim.time_no_chatwoot(:'c', '{"status":"resolved"}');
select sim.espera(:'c', '20 minutes');
select sim.confere('o NIOGEN avisou na Live (resolvida fora do NIOGEN)', (select funil_alerta = 'resolvida_fora_niogen' from public.mari_conversas where id = :'c'));
select sim.confere('o lead continua em andamento', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('em 20 minutos o NIOGEN desfez: a conversa voltou a ficar aberta', sim.cw_de(:'c') ->> 'status' = 'open', sim.cw_de(:'c')::text);
select sim.silencio(:'c', 4);
select sim.confere('o toque que estava marcado (D3) não se perdeu: em 4 dias a Mari tocou', exists (select 1 from sim.envios where conversa = :'c' and por like 'cadencia:%'),
  (select coalesce(string_agg(quem || ': ' || o_que, ' | ' order by n), '') from sim.trilha where quem = 'cadência'));
