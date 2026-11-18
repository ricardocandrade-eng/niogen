-- id: X17
-- titulo: Casos Felix e Greiciele (0274): lead em Saída sai do Conferir · Recusou por preço não liga a Retomada
-- tipo: atual
select sim.lead_pronto('Felix X17') as c \gset
update public.mari_conversas set rua_conferir = '{"motivo": "rua_divergente", "esperada": "Rua A", "portal": "Rua B"}'::jsonb, rua_conferir_em = now() where id = :'c';
select sim.como('backoffice');
select sim.confere('antes: a rua está no Conferir', exists (select 1 from jsonb_array_elements(public.live_conferir()) e where e ->> 'tipo' = 'conferir_rua' and e ->> 'conversa_id' = :'c'), 'não está');
select public.lead_sair(:'c', null, 'recusou', 'preco', null, null, false);
select sim.confere('em Saída: sai do Conferir', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e where e ->> 'conversa_id' = :'c' and e ->> 'tipo' like 'conferir_%'), 'continua');
select sim.confere('Recusou por preço: sem Retomada', (select retomada_desde is null from public.mari_conversas where id = :'c'), 'ligou a Retomada');
