-- NIOGEN | supabase/migrations/0008_varejo_btu_oferta50.sql | 03/11/2026
-- Pergunta 1 respondida (Ricardo, 03/11 14h46/14h50 · TABELA_VIGENTE §1, §5 e §9): BTU = cidades com a Oferta 50%.
-- Varejo nas 15 cidades BTU = R$ 55 / 70 / 85 / 100, mesmo preço em todos os meios, comissão Especial/BTU 263 / 338 / 375 / 413
-- (a conferir na 1ª conciliação). Liga os V-O50-* e cria a versão sem fidelidade (V-O50N-*, taxa à vista).
-- Nome na tela vira "(BTU)": a Mari e o vendedor não falam "50%" ao cliente sem peça aprovada pela Nio (base da Mari §3b).
-- Com um plano Varejo BTU ativo, a trava vendas_checa_area deixa de bloquear Varejo em cidade BTU (continua barrando cluster errado).
-- Idempotente.

update public.config_planos set
  ativo      = true,
  nome       = replace(nome, ' (Oferta 50%)', ' (BTU)'),
  inclusos   = case familia
                 when 'Super' then array['Globoplay 12 meses']
                 when 'Ultra' then array['1 ponto extra Mesh', 'Globoplay 12 meses']
                 else inclusos
               end,
  observacao = 'Varejo das cidades BTU (Oferta 50% do book, seção 04). Mesmo preço em todos os meios. Serviços digitais inclusos reduzidos. '
               || 'Não dizer "50%" ao cliente sem peça aprovada. Comissão Especial a conferir na 1ª conciliação.'
where codigo like 'V-O50-%';

insert into public.config_planos
  (codigo, portfolio, variante, cluster, segmentos, nome, familia, velocidade, velocidade_mb, wifi, internet_5g, inclusos,
   preco, preco_cartao, comissao, taxa_habilitacao, isencao_meses, taxa_a_vista, forma_pagamento_permitida,
   vigencia_inicio, vigencia_fim, ativo, observacao)
select replace(p.codigo, 'V-O50-', 'V-O50N-'), p.portfolio, 'oferta50_nfid', p.cluster, p.segmentos,
       replace(p.nome, ' (BTU)', ' (BTU, sem fidelidade)'), p.familia, p.velocidade, p.velocidade_mb, p.wifi, p.internet_5g, p.inclusos,
       p.preco, null, p.comissao, p.taxa_habilitacao, null, true, p.forma_pagamento_permitida,
       p.vigencia_inicio, null, true,
       'Sem fidelidade (cidades BTU): taxa de R$ 540 à vista na 1ª fatura. Só se o cliente pedir. Comissão a confirmar na 1ª conciliação.'
from public.config_planos p
where p.codigo like 'V-O50-%'
on conflict (codigo) do nothing;
