-- id: X25
-- titulo: Porta, passo seguinte (0287): a porta EXECUTA os botões da venda (crédito, biometria, OS e agenda, parar) — mesmo efeito, mesmas recusas da tabela
-- tipo: atual
-- (1) a venda inteira pela porta
select sim.lead_com_venda('Nina X25') as c \gset
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.porta('momento:credito:aprovado', null, %L, '{"resultado":"aprovado"}')$q$, sim.venda(:'c'))), '') as e1 \gset
select sim.confere('porta(momento:credito) executa', :'e1' = '', coalesce(nullif(:'e1', ''), 'ok'));
select sim.fila_rodar();
select sim.confere('depois do crédito: lead em Qualificado', sim.lead_de(:'c') ->> 'etapa' = 'qualificado', sim.lead_de(:'c')::text);
select sim.confere('o crédito ficou no histórico da venda',
  exists (select 1 from public.eventos_venda e where e.venda_id = sim.venda(:'c') and e.tipo = 'credito_aprovado_portal'));

-- (2) a tabela recusa pela porta, com a frase: OS antes da biometria (D11)
select coalesce(sim.recusa(format($q$select public.porta('momento:os_agendar', null, %L, %L)$q$, sim.venda(:'c'),
  jsonb_build_object('os', '98' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'))), '') as e2 \gset
select sim.confere('OS antes da biometria: recusada com a frase', :'e2' <> '' and :'e2' not like '%ainda não passa%', coalesce(nullif(:'e2', ''), 'aceitou'));

select coalesce(sim.recusa(format($q$select public.porta('momento:biometria:validada', null, %L, '{"resultado":"validada"}')$q$, sim.venda(:'c'))), '') as e3 \gset
select sim.confere('porta(momento:biometria) executa', :'e3' = '', coalesce(nullif(:'e3', ''), 'ok'));
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.porta('momento:os_agendar', null, %L, %L)$q$, sim.venda(:'c'),
  jsonb_build_object('os', '99' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto'))), '') as e4 \gset
select sim.confere('porta(momento:os_agendar) executa', :'e4' = '', coalesce(nullif(:'e4', ''), 'ok'));
select sim.fila_rodar();
select sim.confere('a venda saiu de Qualificado', sim.foto(:'c') -> 'venda' ->> 'status' in ('1_vendido', '2_aguardando_instalacao'), (sim.foto(:'c') -> 'venda')::text);
select sim.confere('o lead está no degrau Instalação', sim.lead_de(:'c') ->> 'etapa' = 'instalacao', sim.lead_de(:'c')::text);

-- (3) pelo botão de sempre (casca → núcleo → porta): o resumo é o mesmo e a sombra anota de acordo
select public.backoffice_momento(sim.venda(:'c'), 'agendar', jsonb_build_object('dia', (current_date + 5)::text, 'periodo', '13:00')) ->> 'resumo' as rs \gset
select sim.fila_rodar();
select sim.confere('Reagendar pelo botão responde como antes', :'rs' like '✓ %', coalesce(:'rs', 'null'));
select count(*) filter (where concorda is distinct from true) as disc from public.porta_sombra where venda_id = sim.venda(:'c') \gset
select sim.confere('a sombra anota tudo de acordo', :'disc'::int = 0, :'disc');

-- (4) parar pela porta, num lead da Mari (sem venda)
select sim.lead_novo('Ari X25') as c2 \gset
select sim.mari_fala(:'c2', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.porta('momento:parar', %L, null)$q$, :'c2')), '') as e5 \gset
select sim.confere('porta(momento:parar) executa', :'e5' = '', coalesce(nullif(:'e5', ''), 'ok'));
select sim.fila_rodar();
select sim.confere('parar: Não contatar marcado', (sim.foto(:'c2') ->> 'nao_contatar')::boolean, sim.foto(:'c2')::text);
select sim.cliente_escreve(:'c2', 'oi') as r5 \gset
select sim.confere('parar: a Mari não responde', :'r5' like 'calada%', :'r5');
