-- id: X71
-- titulo: Caso L-217 (19/11): a venda criada pela Mari ganhava um número novo da sequência (L-218) em vez do número da conversa — 3 de 3 vendas desde a 0296. A venda da conversa nasce com o número dela; venda sem conversa continua com número próprio
-- tipo: atual
select sim.lead_com_venda('Jussara X71') as c \gset
select sim.como('servico');
select sim.confere('a venda da Mari nasce com o número da conversa',
  (select v.lead_numero from public.vendas v where v.id = sim.venda(:'c')) = (select lead_numero from public.mari_conversas where id = :'c'),
  (select 'venda L-' || coalesce(v.lead_numero::text, '—') || ' · conversa L-' || (select lead_numero from public.mari_conversas where id = :'c')
     from public.vendas v where v.id = sim.venda(:'c')));

-- venda sem conversa (Nova venda na ficha): número próprio, que não repete o de nenhuma conversa
select sim._servico();
insert into public.vendas (cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cep, numero, cidade, uf, origem, status, segmento)
values ('Sem Conversa X71', sim.cpf(97101), '32999990000', '36010000', '10', 'Juiz de Fora', 'MG', 'indicacao', '0_qualificado', 'PF')
returning id as v2 \gset
select sim.confere('venda sem conversa tem número, sem repetir o de uma conversa',
  (select lead_numero from public.vendas where id = :'v2') is not null
  and not exists (select 1 from public.mari_conversas where lead_numero = (select lead_numero from public.vendas where id = :'v2')),
  (select coalesce(lead_numero::text, '—') from public.vendas where id = :'v2'));
