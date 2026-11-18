-- id: X31
-- titulo: Fase 2, passo 6 (0296): o lead nasce com número (L-n); o post-it grava sem mexer no estado; handoff sem resposta em 2 h úteis vira aviso no celular do admin
-- tipo: atual
select coalesce(max(lead_numero), 0) as antes from public.mari_conversas \gset
select sim.lead_novo('Ana X31') as c \gset
select sim.confere('lead novo nasce com o número seguinte',
  (select lead_numero from public.mari_conversas where id = :'c') > :antes,
  (select coalesce(lead_numero::text, 'sem número') from public.mari_conversas where id = :'c'));

-- post-it: anotação livre, não é estado
select count(*) as mud0 from public.lead_estado_mudancas where conversa_id = :'c' \gset
select count(*) as cw0 from public.chatwoot_acoes where conversa_id = :'c' \gset
select situacao as sit0 from public.lead_estado where conversa_id = :'c' \gset
select sim.como('backoffice');
select public.lead_nota_gravar(:'c', null, 'Prefere que liguem depois das 18h')::text as rn \gset
select sim.fila_rodar();
select sim.confere('o post-it ficou gravado no lead',
  (select texto from public.lead_nota where conversa_id = :'c') = 'Prefere que liguem depois das 18h', :'rn');
select sim.confere('o post-it não mexeu no estado (situação, histórico, Chatwoot)',
  (select situacao from public.lead_estado where conversa_id = :'c') is not distinct from :'sit0'
  and (select count(*) from public.lead_estado_mudancas where conversa_id = :'c') = :mud0
  and (select count(*) from public.chatwoot_acoes where conversa_id = :'c') = :cw0,
  'mudanças ' || (select count(*) from public.lead_estado_mudancas where conversa_id = :'c') || ' · ordens ' || (select count(*) from public.chatwoot_acoes where conversa_id = :'c'));
select public.lead_nota_gravar(:'c', null, 'Ligar só à noite')::text as rn2 \gset
select sim.confere('o post-it se edita (um por lead)',
  (select count(*) from public.lead_nota where conversa_id = :'c') = 1 and (select texto from public.lead_nota where conversa_id = :'c') = 'Ligar só à noite', :'rn2');

-- C4: pediu uma pessoa e ninguém do time respondeu
select sim.como('servico');
select sim.cliente_escreve(:'c', 'quero falar com uma pessoa');
select sim.mari_handoff(:'c', 'pedido_humano', '{}'::jsonb);
select sim.fila_rodar();
insert into public.push_subscriptions (perfil, endpoint, keys)
select u.id, 'https://fcm.googleapis.com/fcm/send/teste-x31', '{"p256dh":"x","auth":"y"}'::jsonb
  from public.usuarios u where u.perfil = 'admin' and u.ativo order by u.id limit 1;
select sim.passa(:'c', '2 days');
select public.push_pendentes(null)::text as push \gset
select sim.confere('2 h úteis sem resposta: o admin recebe o aviso no celular',
  exists (select 1 from jsonb_array_elements(:'push'::jsonb) e
           where e -> 'payload' ->> 'gatilho' = 'handoff_sem_resposta' and e -> 'payload' ->> 'url' like '%' || :'c' || '%'),
  left(:'push', 300));
select public.push_pendentes(null)::text as push2 \gset
select sim.confere('o mesmo aviso não sai duas vezes no dia',
  not exists (select 1 from jsonb_array_elements(:'push2'::jsonb) e
               where e -> 'payload' ->> 'gatilho' = 'handoff_sem_resposta' and e -> 'payload' ->> 'url' like '%' || :'c' || '%'),
  left(:'push2', 300));
