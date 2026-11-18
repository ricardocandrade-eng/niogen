-- id: X18
-- titulo: Mapa situação × botão (0275): cada botão só vale onde é o passo — a porta recusa com a frase da tela, e o "só admin" vale também fora da tela
-- tipo: atual
-- Decisão 3 do Ricardo (18/11): "Pode seguir com o mapa e suas recomendações" — artifact GqWi6YHhidQXw4Ta9gG4JK.

-- toda linha nova da 0275 é exata (evento × situação) e é a que a porta lê
select sim.confere('0275: cada linha nova é a regra que a porta usa naquela situação',
  not exists (select 1 from public.config_transicao t cross join lateral public.porta_prever(t.de, t.evento) p
               where t.nota like '0275 mapa%' and (p.regra <> t.evento || ' @ ' || t.de or p.aceito is distinct from t.aceito
                     or p.exige is distinct from t.exige or p.frase is distinct from t.frase)),
  (select string_agg(t.evento || ' @ ' || t.de, ', ') from public.config_transicao t cross join lateral public.porta_prever(t.de, t.evento) p
    where t.nota like '0275 mapa%' and p.regra <> t.evento || ' @ ' || t.de));
select sim.confere('0275: toda recusa nova tem frase para a tela', not exists (
  select 1 from public.config_transicao where nota like '0275 mapa%' and not aceito and coalesce(frase, '') = ''), null);

-- venda em "rodar crédito": já é venda, a agenda ainda não é o passo
select sim.lead_com_venda('Rui X18') as c \gset
select sim.como('backoffice');
select coalesce((select situacao from public.v_lead_situacao where venda_id = sim.venda(:'c')), '?') as s1 \gset
select sim.confere('venda nova está em "rodar crédito"', :'s1' = 'qualificado_credito', :'s1');
select coalesce(sim.recusa(format($q$select public.lead_virar_venda(%L)$q$, :'c')), '') as r1 \gset
select sim.confere('Virar venda recusado: "já é venda"', :'r1' like '%já é venda%', coalesce(nullif(:'r1', ''), 'aceitou'));
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'agendar', '{"dia":"2026-12-01","periodo":"08:00"}')$q$, sim.venda(:'c'))), '') as r2 \gset
select sim.confere('Agendar antes da OS recusado com a frase', :'r2' like 'A agenda vem junto com a OS%', coalesce(nullif(:'r2', ''), 'aceitou'));
select public.porta_botoes(:'c', sim.venda(:'c')) as b1 \gset
select sim.confere('a tela esconde Agendar com a mesma frase', not (:'b1'::jsonb #>> '{eventos,momento:agendar,ok}')::boolean
  and :'r2' like '%' || (:'b1'::jsonb #>> '{eventos,momento:agendar,frase}') || '%', :'b1'::jsonb #>> '{eventos,momento:agendar}');
select sim.confere('"Nio dispensou" é só do admin: o backoffice não vê',
  not (:'b1'::jsonb #>> '{eventos,momento:biometria:dispensada,ok}')::boolean and (:'b1'::jsonb #>> '{eventos,momento:biometria:dispensada,exige}') = 'admin',
  :'b1'::jsonb #>> '{eventos,momento:biometria:dispensada}');
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'biometria', '{"resultado":"dispensada"}')$q$, sim.venda(:'c'))), '') as r3 \gset
select sim.confere('"Nio dispensou" chamado por fora da tela também é recusado ao backoffice', :'r3' like 'Só o admin dispensa%', coalesce(nullif(:'r3', ''), 'aceitou'));
select sim.como('admin');
select public.porta_botoes(:'c', sim.venda(:'c')) as b2 \gset
select sim.confere('o admin vê "Nio dispensou"', (:'b2'::jsonb #>> '{eventos,momento:biometria:dispensada,ok}')::boolean, :'b2'::jsonb #>> '{eventos,momento:biometria:dispensada}');
select sim.confere('Mover é só do admin na tabela (não só na tela)', (select exige from public.porta_prever('qualificado_credito', 'mover_admin:*')) = 'admin', null);

-- em Saída "pode voltar": nenhum passo da venda antes de Reabrir
select sim.como('backoffice');
select public.lead_sair(:'c', sim.venda(:'c'), 'recusou', 'preco');
select sim.fila_rodar();
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'credito', '{"resultado":"aprovado"}')$q$, sim.venda(:'c'))), '') as r4 \gset
select sim.confere('em Saída, Crédito recusado: "Use Reabrir primeiro"', :'r4' like '%Use Reabrir primeiro%', coalesce(nullif(:'r4', ''), 'aceitou'));
select public.porta_botoes(:'c', sim.venda(:'c')) as b3 \gset
select sim.confere('em Saída, Reabrir continua aparecendo', (:'b3'::jsonb #>> '{eventos,reabrir,ok}')::boolean, :'b3'::jsonb #>> '{eventos,reabrir}');

-- conversa sem venda, com a Mari: Reativar e Devolver não são botões dela
select sim.lead_novo('Bia X18', 'Oi, quero saber dos planos') as m \gset
select sim.fila_rodar();
select public.porta_botoes(:'m', null) as b4 \gset
select sim.confere('com a Mari, "Devolver para a Mari" some', not (:'b4'::jsonb #>> '{eventos,momento:devolver_mari,ok}')::boolean, :'b4'::jsonb #>> '{eventos,momento:devolver_mari}');
select coalesce(sim.recusa(format($q$select public.backoffice_conversa_saida(%L, 'reativar')$q$, :'m')), '') as r5 \gset
select sim.confere('Reativar fora do Cliente Nio é recusado', :'r5' like 'Só conversa silenciada%', coalesce(nullif(:'r5', ''), 'aceitou'));

-- Cliente Nio silenciado: o time não responde (só o admin); a nota interna continua
select sim.lead_novo('Lia X18', 'Oi, sou cliente Nio e minha internet caiu') as n \gset
select sim.mari_handoff(:'n', 'ja_cliente_nio', '{}'::jsonb);
select sim.fila_rodar();
select sim.cliente_escreve(:'n', 'mas eu preciso de ajuda!', true, '5 minutes');
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'n'), '?') as s2 \gset
select sim.confere('insistiu: Cliente Nio', :'s2' = 'cliente_nio', :'s2');
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.backoffice_responder(%L, 'Oi! Posso ajudar?')$q$, :'n')), '') as r6 \gset
select sim.confere('Cliente Nio: o backoffice não responde', :'r6' like 'Cliente Nio: só o admin responde%', coalesce(nullif(:'r6', ''), 'aceitou'));
select coalesce(sim.recusa(format($q$select public.backoffice_responder(%L, 'cliente Nio, orientado', true)$q$, :'n')), '') as r7 \gset
select sim.confere('Cliente Nio: a nota interna continua valendo', :'r7' = '', :'r7');
select sim.como('admin');
select public.porta_botoes(:'n', null) as b5 \gset
select sim.confere('Cliente Nio: o admin vê Responder', (:'b5'::jsonb #>> '{eventos,time_respondeu,ok}')::boolean, :'b5'::jsonb #>> '{eventos,time_respondeu}');
