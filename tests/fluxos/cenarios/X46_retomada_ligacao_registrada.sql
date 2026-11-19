-- id: X46
-- titulo: Live (0315): "Retomada · ligar" tem saída — Não atendeu tira a linha do Conferir, a porta anota e concorda, o D7 segue na data; Pular pede Retomada aberta; sem Retomada a porta recusa
-- tipo: atual
-- Ricardo, 19/11: "fico com a impressão que o trabalho nunca acaba e eles ficam ali parados há dias". A linha só saía escrevendo na conversa ou no D7.
select sim.lead_com_venda('Lia X45') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Consegue me mandar a foto do documento?');
select sim.fila_rodar();
select sim.passa(:'c', '2 days');
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'sem_resposta', null, null, null, false)::text as r \gset
select sim.como('servico');
select sim.fila_rodar();
select sim.passa(:'c', '2 days');
select sim.fila_rodar();
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('o D3 da Retomada saiu', (select retomada_passo = 'D3' from public.mari_conversas where id = :'c'),
  (select coalesce(retomada_passo, 'sem passo') from public.mari_conversas where id = :'c'));
select sim.passa(:'c', '1 day 13 hours');
select sim.como('backoffice');
select sim.confere('1 dia sem resposta ao D3: a Live pede para ligar', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'retomada_ligar' and e ->> 'conversa_id' = :'c'), 'sem item retomada_ligar');

-- antes da ligação: o D7 previsto
select sim.como('servico');
select public._retomada_quando(m, 'D7')::text as d7_antes from public.mari_conversas m where m.id = :'c' \gset

-- (1) resultado inválido é recusado
select sim.como('backoffice');
select sim.confere('resultado inválido é recusado', sim.recusa(format('select public.retomada_ligacao(%L, %L)', :'c', 'talvez')) like '%inválido%',
  sim.recusa(format('select public.retomada_ligacao(%L, %L)', :'c', 'talvez')));

-- (2) Não atendeu: a linha sai, a porta anota e concorda, a nota vai ao Chatwoot pela fila, o relógio não muda
select public.retomada_ligacao(:'c', 'nao_atendeu') ->> 'resumo' as r2 \gset
select sim.confere('Não atendeu responde com a data do D7', :'r2' like '%Não atendeu%D7%', :'r2');
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('Não atendeu: a linha "Retomada · ligar" sai do Conferir', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'retomada_ligar' and e ->> 'conversa_id' = :'c'), 'a linha continua');
select sim.como('servico');
select sim.confere('a ligação ficou gravada com autor',
  (select retomada_ligacao = 'nao_atendeu' and retomada_ligacao_por is not null and retomada_ligacao_em > retomada_passo_em from public.mari_conversas where id = :'c')
  and exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'sistema' and t.texto like '[📞 Retomada · não atendeu%'),
  (select row(retomada_ligacao, retomada_ligacao_por, retomada_ligacao_em)::text from public.mari_conversas where id = :'c'));
select sim.confere('a nota da ligação foi para o Chatwoot pela fila', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.momento = 'retomada' and a.tipo = 'nota' and a.payload ->> 'content' like '📞 Retomada:%não atendeu%'),
  (select coalesce(string_agg(a.tipo || ' ' || a.status, ' | '), 'nada') from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'retomada'));
select coalesce((select coalesce(concorda::text, 'null') || ' · ' || antes || ' → ' || depois from public.porta_sombra
  where evento = 'retomada_ligacao:nao_atendeu' and conversa_id = :'c' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta anota o evento e concorda (situação não muda)', :'k' like 'true%', :'k');
select sim.confere('o D7 segue na mesma data', (select public._retomada_quando(m, 'D7')::text from public.mari_conversas m where m.id = :'c') = :'d7_antes',
  (select public._retomada_quando(m, 'D7')::text from public.mari_conversas m where m.id = :'c') || ' × ' || :'d7_antes');

-- (3) o D7 sai normalmente e a Retomada continua
select sim.passa(:'c', '3 days');
select sim.fila_rodar();
select public._retomada_tick(sim.meio_dia());
select sim.fila_rodar();
select sim.confere('o D7 saiu mesmo com a ligação registrada', exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c'
  and a.payload ->> 'template' = 'nio_retomada_lead_d7' and a.status = 'feita'), 'sem D7');

-- (4) Retomada encerrada: a porta recusa a ligação
update public.mari_conversas set retomada_fim_em = now(), retomada_fim = 'teste X45' where id = :'c';
select sim.como('backoffice');
select sim.confere('sem Retomada aberta, a ligação é recusada', sim.recusa(format('select public.retomada_ligacao(%L, %L)', :'c', 'pular')) like '%não está mais na Retomada%',
  sim.recusa(format('select public.retomada_ligacao(%L, %L)', :'c', 'pular')));
select sim.como('servico');
