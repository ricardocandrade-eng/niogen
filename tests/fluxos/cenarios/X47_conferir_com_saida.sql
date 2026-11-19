-- id: X47
-- titulo: Live (0318): cada tipo do Conferir tem saída — Hora de voltar → Mais 7 dias (pela porta, situação "="); OS na Nio → Visto até a OS mudar; Conta não fecha → Visto hoje; Documentos → Entregues
-- tipo: atual
-- Ricardo, 19/11: "Sim, todos assim" (continuação da 0315: "nem sempre vejo uma forma de limpar a tela").

-- (1) Hora de voltar → Mais 7 dias
select sim.lead_novo('Vera X47') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'recusou', 'momento', ((now() at time zone 'America/Sao_Paulo')::date + 5), null, false)::text as r \gset
select sim.fila_rodar();
select sim.como('servico');
-- premissa: a data combinada chegou hoje
update public.mari_conversas set saida_volta_em = (now() at time zone 'America/Sao_Paulo')::date where id = :'c';
select sim.como('backoffice');
select sim.confere('a data de volta chegou: o Conferir mostra "Hora de voltar"', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'volta_hoje' and e ->> 'conversa_id' = :'c'),
  (select coalesce(string_agg(e ->> 'tipo', ', '), 'nada') from jsonb_array_elements(public.live_conferir()) e where e ->> 'conversa_id' = :'c') || ' · saída: ' || :'r');
select public.lead_volta_adiar(:'c', null, 7) ->> 'resumo' as r1 \gset
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('Mais 7 dias: a linha sai do Conferir', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'volta_hoje' and e ->> 'conversa_id' = :'c'), :'r1');
select sim.como('servico');
select sim.confere('a data de volta foi para hoje + 7 e ficou nota com o autor',
  (select saida_volta_em = (now() at time zone 'America/Sao_Paulo')::date + 7 from public.mari_conversas where id = :'c')
  and exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'sistema' and t.texto like '[📅 volta adiada para%'),
  (select saida_volta_em::text from public.mari_conversas where id = :'c'));
select coalesce((select coalesce(concorda::text, 'null') || ' · ' || antes || ' → ' || depois from public.porta_sombra
  where evento = 'volta_adiar' and conversa_id = :'c' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta anota o volta_adiar e concorda (segue em Saída)', :'k' like 'true%', :'k');

-- lead em andamento: a porta recusa adiar
select sim.lead_novo('Gil X47') as c2 \gset
select sim.como('backoffice');
select sim.confere('lead em andamento: adiar a volta é recusado', sim.recusa(format('select public.lead_volta_adiar(%L, null, 7)', :'c2')) like '%não está em Saída%',
  sim.recusa(format('select public.lead_volta_adiar(%L, null, 7)', :'c2')));

-- (2) OS na Nio → Visto até a OS mudar
select sim.como('servico');
insert into public.os_andamento (pedido, estado, acao, excecao, excecao_desde, status_ordem)
values ('47000001', 'cancelada', 'conferir na Consulta OS', true, now(), 'Draft');
select sim.como('backoffice');
select sim.confere('OS em exceção aparece no Conferir', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'os_excecao' and e ->> 'chave' = '47000001'), 'sem os_excecao');
select public.os_excecao_visto('47000001') ->> 'resumo' as r2 \gset
select sim.confere('Visto: a OS sai do Conferir', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'os_excecao' and e ->> 'chave' = '47000001'), :'r2');
select sim.como('servico');
update public.os_andamento set status_ordem = 'Cancelled' where pedido = '47000001';
select sim.como('backoffice');
select sim.confere('a OS mudou na Nio: volta para o Conferir', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'os_excecao' and e ->> 'chave' = '47000001'), 'não voltou');

-- (3) Conta não fecha → Visto hoje
select sim.como('servico');
insert into public.conferencias_diarias (dia, verde, falhas, itens)
values ((now() at time zone 'America/Sao_Paulo')::date, false, 1, '[{"codigo": "X47", "nivel": "falha", "nome": "Teste X47", "texto": "falha de teste"}]'::jsonb)
on conflict (parceiro_id, dia) do update set itens = public.conferencias_diarias.itens || excluded.itens;
select sim.como('backoffice');
select sim.confere('falha da conferência aparece no Conferir', exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'conta_nao_fecha' and e ->> 'chave' = 'X47'), 'sem conta_nao_fecha');
select public.conferencia_visto('X47') ->> 'resumo' as r3 \gset
select sim.confere('Visto hoje: a falha sai do Conferir', not exists (select 1 from jsonb_array_elements(public.live_conferir()) e
  where e ->> 'tipo' = 'conta_nao_fecha' and e ->> 'chave' = 'X47'), :'r3');

-- (4) Documentos → Entregues
select sim.lead_com_venda('Dora X47') as c4 \gset
select sim.como('backoffice');
select public.venda_docs_entregues(sim.venda(:'c4')) ->> 'resumo' as r4 \gset
select sim.como('servico');
select sim.confere('Entregues: grava a data e o evento com autor',
  (select docs_entregues_em is not null from public.vendas where id = sim.venda(:'c4'))
  and exists (select 1 from public.eventos_venda e where e.venda_id = sim.venda(:'c4') and e.tipo = 'docs_entregues' and e.criado_por is not null), :'r4');
