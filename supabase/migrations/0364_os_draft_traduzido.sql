-- NIOGEN | supabase/migrations/0364_os_draft_traduzido.sql | 23/11/2026 — Claude Code (Opus 5.5)
-- A OS 12078250 (Mirian) apareceu com status "Draft" e o NIOGEN dizia "texto novo da Nio, avisar o Ricardo para traduzir".
-- A tradução existia desde a 0277 (18/11), mas não pegou: a linha "Draft" já tinha entrado sozinha como 'visto' (estado nulo) e o
-- "on conflict" da 0277 só atualizou a ação e a observação — estado, vez e exceção ficaram vazios.
-- O que é o Draft (Rogério Pacheco, Nio, 23/11 12h): rascunho, pedido que não foi pra frente. Quase sempre é cartão de crédito
-- que o cliente não pagou em até 48h — o pedido sai de "Aguardando Pagamento" para "Draft". Fica assim: a Nio não cancela,
-- porque o pedido de fato nunca foi gerado. Também é o que sobra quando o time cancela a OS para reemitir (caso de 18/11, 0277).
-- Agora: "Draft" e "Draft-…" = rascunho, vez do time, exceção (vai para a Live enquanto a venda está em andamento), com a ação que
-- serve aos dois casos. Venda já em Saída ou Instalada não acende (regra de sempre do os_registrar_leitura).
-- Regra 20: (1) nenhuma situação nova — o estado 'rascunho' já existe e já segura o aviso do cartão (0278); (2) quem age é o time,
-- pela Live (item da OS); (3) a mudança é só de tradução, gravada como admin; (4) o status continua vindo da Nio; (5) cenário X90
-- no portão. Tela Live: sem mudança de tela, só o texto da ação.
begin;

update public.config_os_estados
   set estado = 'rascunho', vez = 'time', excecao = true, origem = 'admin',
       acao = 'Pedido não foi pra frente (em geral cartão não pago em 48h; a Nio não cancela, fica em Draft) → falar com o cliente: refazer o pedido e gravar a OS nova, ou dar Saída',
       observacao = coalesce(observacao, '') || ' · 0364: traduzido (Rogério/Nio, 23/11: rascunho, cartão não pago em 48h; não vira cancelado)'
 where campo = 'status_ordem' and texto in ('Draft', 'Draft-');

do $$
begin
  if exists (select 1 from public.config_os_estados where campo = 'status_ordem' and texto in ('Draft', 'Draft-') and estado is distinct from 'rascunho') then
    raise exception '0364: Draft continua sem tradução';
  end if;
  if not exists (select 1 from public.config_os_estados where campo = 'status_ordem' and texto = 'Draft') then
    insert into public.config_os_estados (campo, texto, prefixo, estado, vez, acao, excecao, origem, observacao)
    select campo, 'Draft', false, estado, vez, acao, excecao, 'admin', '0364: Rogério/Nio, 23/11'
      from public.config_os_estados where campo = 'status_ordem' and texto = 'Draft-';
  end if;
end $$;

commit;
