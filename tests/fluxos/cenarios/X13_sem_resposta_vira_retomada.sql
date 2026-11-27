-- id: X13
-- titulo: Casos Janaina e Greiciele (0274 · 0305): "Sem resposta" dado pelo time liga a Retomada da Mari (D3 → Ligar → D7 → D15); só no fim a Saída fica
-- tipo: atual
-- 27/11: o cenário monta o próprio estado — na produção as variantes do D3 (v1 e v2) já foram aprovadas pela Meta e vêm assim no backup;
-- aqui todas começam PENDING, e cada parte aprova a que vai testar.
update public.config_templates_waba set status = 'PENDING' where nome like 'nio_retomada_d3_%';
select sim.lead_com_venda('Jana X13') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Consegue me mandar a foto do documento?');
select sim.fila_rodar();
select sim.passa(:'c', '2 days');
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'sem_resposta', null, null, null, false)::text as r \gset
select sim.confere('a Saída avisa que a Mari faz a Retomada', :'r' like '%Retomada%', :'r');
select sim.confere('a Retomada começou', (select retomada_desde is not null and retomada_fim_em is null from public.mari_conversas where id = :'c'),
  (select row(retomada_desde, retomada_origem, retomada_fim)::text from public.mari_conversas where id = :'c'));

-- D3 (0305): na Saída manual ele conta 3 dias da última fala do cliente (aqui, 2 dias antes da Saída), não sai na hora.
select sim.como('servico');
select sim.fila_rodar();
select public._retomada_tick(now());
select sim.fila_rodar();
select sim.confere('logo depois da Saída o D3 ainda não saiu', not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.momento = 'retomada' and a.tipo = 'mensagem'), 'saiu na hora');
-- sai pela fila do NIOGEN, em template (a janela de 24 h fechou). O relógio anda 2 dias: já passaram 3 dias da última fala.
select sim.passa(:'c', '2 days');
select sim.fila_rodar();
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('o D3 da Retomada saiu (template)', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada'
  and a.payload ->> 'template' = 'nio_retomada_lead_d3' and a.status = 'feita'),
  (select coalesce(string_agg(a.status || ' ' || coalesce(a.payload ->> 'template', a.tipo), ' | '), 'nada') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada'));
select sim.confere('a cadência do n8n não manda nada junto', not exists (select 1 from sim.cadencia(sim.meio_dia()) x where x like '%enviado'), 'n8n');

-- 1 dia depois: a Live pede para ligar
select sim.passa(:'c', '1 day 13 hours');
select sim.como('backoffice');
select sim.confere('D3 sem resposta há 1 dia: a Live pede para ligar', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'retomada_ligar' and e ->> 'conversa_id' = :'c'), 'sem item retomada_ligar');

-- D7 e D15
select sim.como('servico');
select sim.passa(:'c', '3 days');
select sim.fila_rodar();
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('o D7 saiu', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'template' = 'nio_retomada_lead_d7' and a.status = 'feita'), 'sem D7');
select sim.passa(:'c', '8 days');
select sim.fila_rodar();
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('o D15 saiu', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.payload ->> 'template' = 'nio_retomada_lead_d15' and a.status = 'feita'), 'sem D15');
select sim.passa(:'c', '2 days 1 hour');
select sim.fila_rodar();
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('fim da Retomada sem resposta: a Saída "Sem resposta" fica', (select retomada_fim = 'sem resposta' from public.mari_conversas where id = :'c')
  and sim.lead_de(:'c') ->> 'saida' = 'sem_resposta',
  (select row(retomada_passo, retomada_fim)::text from public.mari_conversas where id = :'c') || ' ' || sim.lead_de(:'c')::text);
select sim.confere('nenhuma mensagem a mais depois do fim', (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada' and a.tipo = 'mensagem') = 3,
  (select count(*)::text from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada' and a.tipo = 'mensagem'));
