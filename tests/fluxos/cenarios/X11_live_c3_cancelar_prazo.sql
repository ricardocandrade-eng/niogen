-- id: X11
-- titulo: Live (0271): "interesse caindo" fica com a Mari e vira 🔥 (O10); "Cancelar na Nio" tem prazo de 24 h úteis e acende quando vence
-- tipo: atual
-- (1) C3 → 🔥
select sim.lead_novo('Lia X11') as c \gset
select sim.mari_handoff(:'c', 'interesse_caindo');
select sim.fila_rodar();
select sim.mari_fala(:'c', 'Fico por aqui se precisar de algo 😊');
select sim.espera(:'c', '30 minutes');
select sim.como('backoffice');
select coalesce((select o.motivo from public.oportunidades_abertas() o where o.conversa_id = :'c' and 'O10' = any (o.regras)), '') as op \gset
select sim.confere('interesse caindo aparece como oportunidade 🔥 (O10)', :'op' <> '',
  coalesce((select string_agg(o.codigo || ':' || o.motivo, ' | ') from public.oportunidades_abertas() o where o.conversa_id = :'c'), 'não apareceu'));
select sim.confere('o motivo diz que a Mari segue', :'op' like '%a Mari segue%', :'op');
select sim.confere('o lead continua com a Mari', sim.lead_de(:'c') ->> 'vez' in ('mari', 'cliente'), sim.lead_de(:'c')::text);

-- (2) Saída com pedido aberto → "Cancelar na Nio" com prazo; vencido acende
select sim.lead_com_venda('Otto X11') as v \gset
select sim._servico();
update public.vendas set nio_pedido = '12' || lpad(sim._conv(:'v'), 6, '0') where id = sim.venda(:'v');
select sim.como('backoffice');
select public.lead_sair(:'v', sim.venda(:'v'), 'recusou', 'preco', null, null, false);
select sim.fila_rodar();
select coalesce((select x ->> 'texto' from jsonb_array_elements(public.live_conferir()) x
                  where x ->> 'tipo' = 'cancelar_nio' and x ->> 'venda_id' = sim.venda(:'v')::text), '') as t1 \gset
select sim.confere('Cancelar na Nio aparece com o prazo', :'t1' like 'prazo: faltam%', coalesce(nullif(:'t1', ''), 'não apareceu'));
select sim.passa(:'v', '4 days');
select sim.como('backoffice');
select coalesce((select x ->> 'texto' from jsonb_array_elements(public.live_conferir()) x
                  where x ->> 'tipo' = 'cancelar_nio' and x ->> 'venda_id' = sim.venda(:'v')::text), '') as t2 \gset
select sim.confere('passou de 24 h úteis: Cancelar na Nio está VENCIDO', :'t2' like 'VENCIDO%', coalesce(nullif(:'t2', ''), 'não apareceu'));
