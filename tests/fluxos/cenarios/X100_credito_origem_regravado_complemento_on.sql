-- id: X100
-- titulo: 0375 (Ricardo 23/11, L-259): a ficha que regrava o MESMO resultado de crédito passa a assinar ('ficha'), sem segundo aviso ao cliente; "on" lido do portal não vira complemento (lead e venda)
-- tipo: atual

-- A) a Mari grava o crédito; a ficha registra o MESMO resultado logo depois → quem consultou = ficha
select sim.lead_pronto('Ana X100') as a \gset
select sim._servico();
select public.mari_credito_gravar(:'a', '{"resultado": "negado", "formas_liberadas": []}'::jsonb);
select sim.fila_rodar();
select sim.confere('a Mari gravou: origem mari', (select credito_origem from public.mari_conversas where id = :'a') = 'mari',
  (select coalesce(credito_origem, 'null') from public.mari_conversas where id = :'a'));
select count(*) as n1 from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_negado' \gset
select pg_sleep(0.05);
select sim.como('backoffice');
select public.lead_registrar_consulta(:'a', 'credito', 'negado');
select sim.fila_rodar();
select sim.confere('a ficha regravou o mesmo resultado: origem ficha', (select credito_origem from public.mari_conversas where id = :'a') = 'ficha',
  (select coalesce(credito_origem, 'null') from public.mari_conversas where id = :'a'));
select count(*) as n2 from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_negado' \gset
select sim.confere('o mesmo resultado regravado não manda outro aviso ao cliente', :n2 = :n1, :'n1' || ' → ' || :'n2');

-- B) hora do crédito apagada pelo sistema (libera nova consulta): o rótulo não troca
select sim._servico();
update public.mari_conversas set credito_em = null where id = :'a';
select sim.confere('hora apagada pelo sistema: a origem continua ficha', (select credito_origem from public.mari_conversas where id = :'a') = 'ficha',
  (select coalesce(credito_origem, 'null') from public.mari_conversas where id = :'a'));

-- C) lead sem venda: "on" lido do portal (caixa "Sem complemento") não vira complemento; um complemento de verdade vira
select sim.lead_pronto('Bia X100') as b \gset
select public._so_digitos(dados ->> 'cpf') as cpfb from public.mari_conversas where id = :'b' \gset
select sim.como('backoffice');
select public.lead_dados_do_portal(:'b', jsonb_build_object('cpf', :'cpfb', 'complemento', 'on')) as l1 \gset
select sim.confere('lead: "on" não é gravado como complemento', (select complemento is null from public.mari_conversas where id = :'b'), :'l1');
select public.lead_dados_do_portal(:'b', jsonb_build_object('cpf', :'cpfb', 'complemento', 'AP 302')) as l2 \gset
select sim.confere('lead: complemento de verdade é gravado', (select complemento from public.mari_conversas where id = :'b') = 'AP 302', :'l2');

-- D) venda antes da OS: a mesma regra
select sim.lead_com_venda('Caio X100') as c \gset
select public._so_digitos(cliente_cpf_cnpj) as cpfc from public.vendas where id = sim.venda(:'c') \gset
select sim._servico();
update public.vendas set complemento = null where id = sim.venda(:'c');
select sim.como('backoffice');
select public.venda_dados_do_portal(sim.venda(:'c'), jsonb_build_object('cpf', :'cpfc', 'complemento', 'ON')) as v1 \gset
select sim.confere('venda: "on" não é gravado como complemento', (select complemento is null from public.vendas where id = sim.venda(:'c')), :'v1');
select public.venda_dados_do_portal(sim.venda(:'c'), jsonb_build_object('cpf', :'cpfc', 'complemento', 'CASA 2')) as v2 \gset
select sim.confere('venda: complemento de verdade é gravado', (select complemento from public.vendas where id = sim.venda(:'c')) = 'CASA 2', :'v2');
