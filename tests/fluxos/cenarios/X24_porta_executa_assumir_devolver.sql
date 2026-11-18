-- id: X24
-- titulo: Reta final 5 (0282): a porta EXECUTA Assumir, Devolver para a Mari e o "assumir antes" do Responder — o mesmo efeito de antes, agora pela porta()
-- tipo: atual
-- (1) Assumir pela porta
select sim.lead_com_venda('Otto X24') as c \gset
select coalesce((select funil_destino from public.mari_conversas where id = :'c'), 'em_andamento') as d0 \gset
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.porta('momento:assumir', %L, %L)$q$, :'c', sim.venda(:'c'))), '') as e1 \gset
select sim.confere('porta(momento:assumir) executa (não diz "ainda não passa pela porta")', :'e1' = '', coalesce(nullif(:'e1', ''), 'ok'));
select sim.fila_rodar();
select sim.confere('assumida: a conversa tem dono no Chatwoot', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select sim.confere('assumida: nota "Assumida no NIOGEN" e turno do sistema',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'nota' and a.payload ->> 'content' like '👤 Assumida no NIOGEN%')
  and exists (select 1 from public.mari_turnos t where t.conversa_id = :'c' and t.papel = 'sistema' and t.texto like '[assumida no NIOGEN por %'));
select sim.cliente_escreve(:'c', 'oi, tem alguém?') as r1 \gset
select sim.confere('assumida: a Mari fica calada', :'r1' like 'calada%', :'r1');
select sim.confere('assumida: a vez é do time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);

-- (2) clique duplo pelo botão de sempre: nada repetido
select public.backoffice_momento(sim.venda(:'c'), 'assumir') ->> 'resumo' as rr \gset
select sim.confere('Assumir de novo em 10 min não repete', :'rr' like '%já foi assumida há instantes%', :'rr');
select count(*) as natr from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'atribuir' \gset
select sim.confere('uma atribuição só', :'natr'::int = 1, :'natr');

-- (3) Devolver para a Mari pela porta
select coalesce(sim.recusa(format($q$select public.porta('momento:devolver_mari', %L, %L)$q$, :'c', sim.venda(:'c'))), '') as e3 \gset
select sim.confere('porta(momento:devolver_mari) executa', :'e3' = '', coalesce(nullif(:'e3', ''), 'ok'));
select sim.fila_rodar();
select sim.confere('devolvida: sem dono e sem time no Chatwoot', sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
select sim.confere('devolvida: nota "Devolvida para a Mari"',
  exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c' and a.tipo = 'nota' and a.payload ->> 'content' like '↩ Devolvida para a Mari%'));
select sim.cliente_escreve(:'c', 'e agora?') as r3 \gset
select sim.fila_rodar();
select sim.confere('devolvida: a Mari responde', :'r3' = 'respondeu', :'r3');
select coalesce((select funil_destino from public.mari_conversas where id = :'c'), 'em_andamento') as d1 \gset
select sim.confere('assumir e devolver não mexem no destino do lead', :'d1' = :'d0', :'d0' || ' → ' || :'d1');

-- (4) a porta recusa com a frase da tabela: devolver o que já está com a Mari (lead sem venda; com venda a situação é o passo
--     da venda, e ali Devolver vale — decisão do C8)
select sim.lead_novo('Ilda X24') as c4 \gset
select sim.mari_fala(:'c4', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.porta('momento:devolver_mari', %L, null)$q$, :'c4')), '') as e4 \gset
select sim.confere('devolver de novo: recusa "já está com a Mari"', :'e4' like '%já está com a Mari%', coalesce(nullif(:'e4', ''), 'aceitou'));

-- (5) Responder sem dono: o "assumir antes" é da porta; com dono, a porta não atribui de novo
select sim.lead_novo('Vera X24') as c2 \gset
select sim.mari_fala(:'c2', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.porta('time_respondeu', :'c2', null) ->> 'assumiu' as a1 \gset
select sim.confere('porta(time_respondeu) sem dono: assume (cadência parada, atribuição na fila)', :'a1' = 'true'
  and exists (select 1 from public.chatwoot_acoes a where a.conversa_id = :'c2' and a.tipo = 'atribuir'), coalesce(:'a1', 'null'));
select sim.fila_rodar();
select public.porta('time_respondeu', :'c2', null) ->> 'assumiu' as a2 \gset
select count(*) as natr2 from public.chatwoot_acoes a where a.conversa_id = :'c2' and a.tipo = 'atribuir' \gset
select sim.confere('com dono: a porta não atribui de novo', :'a2' = 'false' and :'natr2'::int = 1, :'a2' || ' / ' || :'natr2');
select public.backoffice_responder(:'c2', 'Oi, aqui é do time da Dharma!') ->> 'resumo' as rs \gset
select sim.fila_rodar();
select sim.confere('Responder segue mandando a mensagem', :'rs' like '✓ mensagem enviada%', :'rs');

-- (6) a casca anota de acordo com a tabela
select count(*) filter (where concorda is distinct from true) as disc from public.porta_sombra
 where conversa_id in (:'c', :'c2') or venda_id = sim.venda(:'c') \gset
select sim.confere('a sombra anota tudo de acordo', :'disc'::int = 0, :'disc');
