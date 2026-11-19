-- id: X39
-- titulo: Retomada (0305): lead da Fila Vero que só clicou na oferta → Saída "Sem resposta" manual → o D3 espera 3 dias da última fala e sai com o texto do clique (nunca "parou no meio"); sem o template aprovado, o D3 não sai e segue o D7
-- tipo: atual
-- Caso L-181 (conversa 167), 18/11. Ricardo: "quem clicou mostrou interesse e DEVE entrar na Retomada"; D3 3 dias depois da última fala.
select sim.como('servico');
insert into sim.cw (conv, telefone, nome) values ('993901', '5531999390001', 'Ana X39'), ('993902', '5531999390002', 'Bia X39');
insert into public.fila_vero (nome, telefone, segmento, status, template, wamid, codigo)
values ('Ana X39', '5531999390001', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X39A', 'x39a0001'),
       ('Bia X39', '5531999390002', 'instalado', 'enviado', 'nio_fv_a1', 'wamid.X39B', 'x39b0002');
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x39a0001'), true, '993901') ->> 'conversa_id') as c \gset
select (public.fila_vero_clique_resultado((select id from public.fila_vero where codigo = 'x39b0002'), true, '993902') ->> 'conversa_id') as c2 \gset
select sim.fila_rodar();
select sim.confere('o clique abriu o lead da Fila Vero, sem mensagem do cliente',
  (select origem = 'fila_vero' from public.mari_conversas where id = :'c')
  and not exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'lead'),
  (select row(origem, ultima_msg_lead_at)::text from public.mari_conversas where id = :'c'));

-- (1) o time dá Saída "Sem resposta" no mesmo dia: a Retomada abre, mas o D3 não sai na hora
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'sem_resposta', null, null, null, false)::text as r \gset
select sim.como('servico');
select sim.confere('a Saída abriu a Retomada com a base na última fala (o toque da Mari)',
  (select retomada_origem = 'saida_sem_resposta' and retomada_fim_em is null and retomada_base is not null
     and retomada_base <= retomada_desde and retomada_base > retomada_desde - interval '1 hour' from public.mari_conversas where id = :'c'),
  (select row(retomada_desde, retomada_origem, retomada_base)::text from public.mari_conversas where id = :'c'));
select sim.fila_rodar();
select sim.passa(:'c', '1 day');
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('1 dia depois da Saída: o D3 ainda não saiu (espera 3 dias da última fala)',
  (select retomada_passo is null from public.mari_conversas where id = :'c')
  and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada' and a.tipo = 'mensagem'),
  (select coalesce(retomada_passo, 'sem passo') from public.mari_conversas where id = :'c'));

-- (2) 3 dias depois da última fala, com o template do clique aprovado: o D3 sai falando do clique
update public.config_templates_waba set status = 'APPROVED' where nome = 'nio_retomada_clique_d3';
select sim.passa(:'c', '3 days');
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('o D3 saiu com o template do clique',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada'
           and a.payload ->> 'template' = 'nio_retomada_clique_d3' and a.status = 'feita'),
  (select coalesce(string_agg(a.status || ' ' || coalesce(a.payload ->> 'template', a.tipo), ' | '), 'nada') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada'));
select sim.confere('o texto fala do clique e nunca de "parou no meio"',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada' and a.payload ->> 'content' like '%abriu a oferta%')
  and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'content' like '%parou no meio%'),
  (select string_agg(a.payload ->> 'content', ' | ') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada' and a.tipo = 'mensagem'));
select sim.confere('o D7 fica para a base + 7 dias (pelo menos 4 dias depois do D3)',
  (select public._retomada_quando(m, 'D7') >= m.retomada_base + interval '7 days' and public._retomada_quando(m, 'D7') >= m.retomada_passo_em + interval '4 days'
     from public.mari_conversas m where m.id = :'c'),
  (select row(retomada_base, retomada_passo_em, public._retomada_quando(m, 'D7'))::text from public.mari_conversas m where m.id = :'c'));

-- (3) sem o template do clique aprovado: o D3 dessa pessoa não sai (nota no histórico) e a Retomada segue para o D7
update public.config_templates_waba set status = 'PENDING' where nome = 'nio_retomada_clique_d3';
select sim.como('backoffice');
select public.lead_sair(:'c2', null, 'sem_resposta', null, null, null, false)::text as r2 \gset
select sim.como('servico');
select sim.fila_rodar();
select sim.passa(:'c2', '4 days');
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('template do clique pendente: nada sai, nunca o D3 "parou no meio", e a Retomada segue para o D7',
  (select retomada_passo = 'D3' and retomada_fim_em is null from public.mari_conversas where id = :'c2')
  and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c2' and a.momento = 'retomada' and a.tipo = 'mensagem')
  and exists (select 1 from public.mari_turnos t where t.conversa_id = :'c2' and t.papel = 'sistema' and t.texto like '%nio_retomada_clique_d3%'),
  (select row(retomada_passo, retomada_fim)::text from public.mari_conversas where id = :'c2'));
