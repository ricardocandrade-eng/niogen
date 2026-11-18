-- id: X15
-- titulo: Caso Kika (0274): cliente diz "vou ver com minha tia" — 24 h sem cutucada da Mari
-- tipo: atual
select sim.lead_novo('Kika X15') as c \gset
select sim.cliente_escreve(:'c', 'vou ver com minha tia e te falo');
select sim.confere('logo depois do "vou ver": nada de F1', coalesce(sim.cadencia_ver(:'c') ->> 'proximo', '') not like 'F%', sim.cadencia_ver(:'c')::text);
select sim.espera(:'c', '6 hours');
select sim.cadencia(sim.meio_dia());
select sim.confere('6 h depois: nenhuma cutucada saiu', (select count(*) from sim.envios where conversa = :'c' and por like 'cadencia:F%') = 0,
  (select coalesce(string_agg(por, ' '), 'nenhuma') from sim.envios where conversa = :'c' and por like 'cadencia:%'));
