-- id: X104
-- titulo: 0380 (L-70): crédito "CPF/CNPJ com débito na Nio" vira negado_debito — o cliente NÃO recebe o negado nem a oferta do parente; o time recebe a nota com o que fazer (quitar e consultar de novo); a venda guarda 'negado' sem aviso; a ficha grava o débito
-- tipo: atual

-- A) Mari atendendo: o robô lê o popup do débito
select sim.lead_pronto('Ana X104') as a \gset
select sim._servico();
select public.mari_credito_gravar(:'a', '{"resultado": "negado_debito", "popup": {"titulo": "Resultado da análise de crédito", "texto": "Crédito negado CPF/CNPJ com débito na Nio."}}'::jsonb);
select sim.fila_rodar();
select sim.confere('débito: gravado como negado_debito',
  (select credito_resultado from public.mari_conversas where id = :'a') = 'negado_debito', (select credito_resultado from public.mari_conversas where id = :'a'));
select count(*) as msg from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'mensagem' and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('débito: nenhuma mensagem ao cliente (nem negado, nem parente)', :msg = 0, :'msg');
select sim.confere('débito: nota ao time com quitar e consultar de novo',
  exists (select 1 from public.chatwoot_acoes where conversa_id = :'a' and tipo = 'nota'
           and payload ->> 'content' like '%DÉBITO NA NIO%' and payload ->> 'content' like '%consultar o crédito de novo%'), null);
select sim.confere('débito: o texto do popup fica na consulta',
  exists (select 1 from public.operador_consultas where conversa_id = :'a' and resultado = 'negado_debito' and detalhe ->> 'popup' like '%débito na Nio%'), null);
select sim.confere('débito: sem marca de negado avisado (a Mari não passa "pro CPF do novo titular")',
  coalesce((select dados ->> 'credito_negado_sistema' from public.mari_conversas where id = :'a'), '') = '', null);

-- B) Lead com venda: a venda fica 'negado' pelo espelho, sem aviso ao cliente; a conversa continua negado_debito
select sim.lead_com_venda('Pedro X104') as b \gset
select sim._servico();
select public.mari_credito_gravar(:'b', '{"resultado": "negado_debito"}'::jsonb);
select sim.fila_rodar();
select sim.confere('venda: crédito negado', (select credito_resultado from public.vendas where id = sim.venda(:'b')) = 'negado',
  (select credito_resultado from public.vendas where id = sim.venda(:'b')));
select sim.confere('venda: a conversa segue negado_debito', (select credito_resultado from public.mari_conversas where id = :'b') = 'negado_debito', null);
select sim.confere('venda: nenhum aviso de negado ao cliente',
  not exists (select 1 from public.chatwoot_acoes where conversa_id = :'b' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_%'), null);

-- C) Ficha: o backoffice grava o débito no lead
select sim.lead_pronto('Lia X104') as c \gset
select sim.como('backoffice');
select public.lead_registrar_consulta(:'c', 'credito', 'negado_debito') ->> 'resumo' as rc \gset
select sim.confere('ficha: grava o débito', :'rc' like '%débito na Nio%', :'rc');
select sim.como('servico');
select sim.confere('ficha: nenhuma mensagem ao cliente',
  not exists (select 1 from public.chatwoot_acoes where conversa_id = :'c' and tipo = 'mensagem' and payload ->> 'texto_chave' like 'bo_credito_%'), null);
