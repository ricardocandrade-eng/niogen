-- id: X108
-- titulo: 0385 (Ricardo, 24/11: "Para a cadência para quem estiver com provável bloqueio"): 2+ mensagens nossas paradas em ✓ há +24 h (ou 2 recusadas) depois da última fala do cliente bloqueiam o toque automático; entregue ou fala nova do cliente libera; sem tique gravado não bloqueia; o time logado lê a v_mari_cadencia
-- tipo: atual
select sim.como('servico');
grant authenticated, anon, service_role to authenticator;

-- A) D3 devido, sem tiques gravados: sai normal
select sim.lead_novo('Ana X108') as a \gset
select sim.passa(:'a', interval '3 days 2 hours');
select coalesce((select proximo_passo || ':' || coalesce(bloqueio, '-') from public.mari_cadencia_avaliar(now(), :'a') limit 1), '?') as a0 \gset
select sim.confere('sem tiques: o D3 sai como sempre', :'a0' = 'D3:-', :'a0');

-- B) Cliente falou, depois duas nossas paradas em ✓ há +24 h: bloqueia com o motivo
insert into public.mari_msg_cw (cw_msg_id, conversa_id, chatwoot_conversation_id, direcao, status, texto, criado_em) values
  (910801, :'a', 'x108', 'in', 'enviada', 'oi', now() - interval '70 hours'),
  (910802, :'a', 'x108', 'out', 'enviada', 'Oi! Me passa o CEP?', now() - interval '69 hours'),
  (910803, :'a', 'x108', 'out', 'enviada', 'Conseguiu ver?', now() - interval '30 hours');
select coalesce((select coalesce(bloqueio, '-') || ' | ' || pode_enviar from public.mari_cadencia_avaliar(now(), :'a') limit 1), '?') as b1 \gset
select sim.confere('2 paradas em ✓ há +24 h: o toque não sai, motivo provável bloqueio', :'b1' like 'provável bloqueio: 2 mensagens paradas em ✓ desde % — ligue (📵 na conversa) | false', :'b1');

-- C) Uma delas entregue: libera
update public.mari_msg_cw set status = 'entregue' where cw_msg_id = 910802;
select coalesce((select coalesce(bloqueio, '-') || ' | ' || pode_enviar from public.mari_cadencia_avaliar(now(), :'a') limit 1), '?') as c1 \gset
select sim.confere('uma entregue: volta a tocar', :'c1' = '- | true', :'c1');

-- D) Só uma parada há +24 h (a outra recente): não bloqueia
update public.mari_msg_cw set status = 'enviada', criado_em = now() - interval '5 hours' where cw_msg_id = 910802;
select coalesce((select coalesce(bloqueio, '-') from public.mari_cadencia_avaliar(now(), :'a') limit 1), '?') as d1 \gset
select sim.confere('só uma há +24 h: não bloqueia', :'d1' = '-', :'d1');

-- E) Duas recusadas pelo WhatsApp: bloqueia
update public.mari_msg_cw set status = 'falhou' where cw_msg_id in (910802, 910803);
select coalesce((select coalesce(bloqueio, '-') from public.mari_cadencia_avaliar(now(), :'a') limit 1), '?') as e1 \gset
select sim.confere('2 recusadas: bloqueia', :'e1' like 'provável bloqueio: 2 mensagens recusadas pelo WhatsApp%', :'e1');

-- F) O cliente falou depois: libera
insert into public.mari_msg_cw (cw_msg_id, conversa_id, chatwoot_conversation_id, direcao, status, texto, criado_em) values
  (910804, :'a', 'x108', 'in', 'enviada', 'voltei', now() - interval '1 hour');
select coalesce((select coalesce(bloqueio, '-') from public.mari_cadencia_avaliar(now(), :'a') limit 1), '?') as f1 \gset
select sim.confere('fala nova do cliente: não bloqueia', :'f1' not like 'provável bloqueio%', :'f1');

-- G) Mensagem sem status (antes dos tiques) no meio interrompe a contagem
delete from public.mari_msg_cw where cw_msg_id = 910804;
update public.mari_msg_cw set status = null where cw_msg_id = 910802;
update public.mari_msg_cw set status = 'enviada' where cw_msg_id = 910803;
select coalesce(public._provavel_bloqueio(:'a'::uuid), '-') as g1 \gset
select sim.confere('sem status no meio: sem dado, sem bloqueio', :'g1' = '-', :'g1');

-- H) O time logado lê a v_mari_cadencia (a função nova tem EXECUTE para authenticated)
create temp table _x108 (r text);
grant all on _x108 to authenticated;
create or replace function pg_temp.tenta(p_sql text) returns text language plpgsql as $$
declare n int;
begin
  execute p_sql into n; return 'ok ' || n;
exception when others then return sqlstate || ' ' || sqlerrm;
end $$;
select sim.como('backoffice');
set session authorization authenticator;
set role authenticated;
insert into _x108 values (pg_temp.tenta($$select count(*)::int from public.v_mari_cadencia$$));
reset role;
reset session authorization;
select sim.como('servico');
select sim.confere('o time logado lê a v_mari_cadencia', (select r from _x108) like 'ok %', (select r from _x108));
