-- id: X58
-- titulo: 0336 (Ricardo 20/11, L-207: "foi a ficha, não a Mari"): a conversa guarda quem gravou o crédito — a Mari ('mari'), a ficha do lead ('ficha'), o espelho da venda (a origem dele) — e o aviso ao cliente segue saindo uma vez
-- tipo: atual

-- A) a Mari consulta: origem mari
select sim.lead_pronto('Ana X58') as a \gset
select sim._servico();
select public.mari_credito_gravar(:'a', '{"resultado": "negado", "formas_liberadas": []}'::jsonb);
select sim.confere('crédito da Mari: origem mari', (select credito_origem from public.mari_conversas where id = :'a') = 'mari',
  (select coalesce(credito_origem, 'null') from public.mari_conversas where id = :'a'));

-- B) lead sem venda, a ficha grava (lead_registrar_consulta): origem ficha; aviso ao cliente um só
select sim.lead_pronto('Bia X58') as b \gset
select sim.como('backoffice');
select public.lead_registrar_consulta(:'b', 'credito', 'negado');
select sim.fila_rodar();
select sim.confere('crédito gravado na ficha do lead: origem ficha', (select credito_origem from public.mari_conversas where id = :'b') = 'ficha',
  (select coalesce(credito_origem, 'null') from public.mari_conversas where id = :'b'));
select count(*) as nb from public.chatwoot_acoes where conversa_id = :'b' and tipo = 'mensagem' and payload ->> 'texto_chave' = 'bo_credito_negado'
   and status in ('pendente', 'executando', 'feita') \gset
select sim.confere('ficha do lead: um aviso ao cliente', :nb = 1, :'nb');

-- C) a ficha corrige depois da Mari: a origem passa a ficha
select sim.como('backoffice');
select public.lead_registrar_consulta(:'a', 'credito', 'aprovado_cartao');
select sim.confere('a ficha regravou por cima da Mari: origem ficha', (select credito_origem from public.mari_conversas where id = :'a') = 'ficha', null);

-- D) com venda: o botão da venda grava; o espelho leva à conversa com a origem dele (humano), não 'ficha'
select sim.lead_com_venda('Caio X58') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"negado"}');
select sim.fila_rodar();
select sim.confere('espelho da venda: a conversa diz humano', (select credito_origem from public.mari_conversas where id = :'c') = 'humano',
  (select coalesce(credito_origem, 'null') from public.mari_conversas where id = :'c'));
