-- id: X43
-- titulo: Divergências de 18/11 (Chatwoot 171 e 165): Assumir e Devolver para a Mari num lead SEM venda — a porta anota a conversa e concorda (antes: "(novo)", "sem regra")
-- tipo: atual
select sim.lead_novo('Ivo X43') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c')) ->> 'ok' as a \gset
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select coalesce(conversa_id::text, 'sem conversa') || ' · ' || coalesce(concorda::text, 'null') from public.porta_sombra
  where evento = 'momento:assumir' order by id desc limit 1), 'sem anotação') as k1 \gset
select sim.confere('Assumir sem venda: a porta anota a conversa e concorda', :'k1' = :'c' || ' · true', :'k1');
select sim.como('backoffice');
select public.backoffice_momento(null, 'devolver_mari', jsonb_build_object('conversa_id', :'c')) ->> 'ok' as d \gset
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select coalesce(conversa_id::text, 'sem conversa') || ' · ' || coalesce(concorda::text, 'null') from public.porta_sombra
  where evento = 'momento:devolver_mari' order by id desc limit 1), 'sem anotação') as k2 \gset
select sim.confere('Devolver sem venda: a porta anota a conversa e concorda', :'k2' = :'c' || ' · true', :'k2');
select sim.confere('nenhuma divergência nova desta conversa',
  not exists (select 1 from public.v_porta_divergencias where evento like 'momento:%' and conversa_id is null), 'há momento sem conversa na lista');
