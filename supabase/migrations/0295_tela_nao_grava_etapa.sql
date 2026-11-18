-- NIOGEN | supabase/migrations/0295_tela_nao_grava_etapa.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "Faça o push e siga para o passo 3" (fase 2 do diagnóstico de fechamento: a tela sem gravação direta de estado).
-- Levantamento: o Quadro de vendas não arrasta desde a 0089 (NG.moverStatus sem uso) e o formulário antigo "pedido" não abre mais; o que
-- ainda gravava vendas.status direto era o "Mover para" do admin no caminho natural (ficha: gravar({status}) e mover_aguardando).
-- O front (mesmo commit) manda esses caminhos para a porta (venda_mover_admin com motivo; Agendar pelo passo da porta).
-- Esta migration põe a trava no banco: vendas_transicao recusa a mudança de etapa feita por pessoa logada com UPDATE direto na
-- tabela (comando de topo = UPDATE em vendas). Funções (porta, Mover do admin, robôs) seguem valendo: o comando de topo delas é a
-- chamada da função. Robôs com a chave de serviço e o CLI não são "authenticated" e não mudam.
-- Ficam de fora, de propósito: Nova venda já em Saída (é criação, não mudança de etapa) e a conferência reprovada do parceiro
-- (vendas_antes_conferencia, D17 — a Saída nasce no banco e passa pelo vendas_porta; vira evento próprio depois).
-- Recriada a partir da versão no ar (md5 0bb830b1… = produção).
-- Regra 20: (1)–(2) sem estado novo; (3) é exatamente a regra 3 (a tela nunca grava status direto); (4) sem fonte nova; (5) cenário X30.
-- Tela: ficha (Mover para do admin) e app.js; guia do backoffice: Mover para é do admin — sem impacto no que o backoffice faz.
-- Desempenho: sem impacto (nenhuma chamada nova; o gatilho só olha current_query() quando a etapa muda).
begin;

CREATE OR REPLACE FUNCTION public.vendas_transicao()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  de   text := old.status;
  para text := new.status;
  ok   boolean;
begin
  if de is not distinct from para then return new; end if;
  -- 0295 (fase 2, passo 3 — regra de ouro 2: "tela nunca grava estado"): pessoa logada mudando a etapa com um UPDATE direto na tabela
  -- (o PATCH do PostgREST: o comando de topo é o próprio UPDATE em vendas) é recusada. Os caminhos que valem são funções do banco
  -- (botões da ficha e da extensão → porta, Mover do admin, robôs da Nio): o comando de topo delas é a chamada da função, não o UPDATE.
  if coalesce(auth.role(), '') = 'authenticated'
     and current_query() ~* 'update\s+("?public"?\s*\.\s*)?"?vendas"?\s+(as\s+\w+\s+)?set\s' then
    raise exception 'A etapa da venda só muda pelos botões da ficha (ou, para o admin, ⋯ › Mover para, com o motivo).'
      using errcode = 'P0001';
  end if;
  -- função do banco que assumiu a mudança (venda_mover_admin, _portal_aplicar): vale para esta transação só
  if coalesce(current_setting('niogen.transicao_ok', true), '') <> '' then return new; end if;
  ok := case de
    when '0_qualificado'           then para in ('1_vendido', '2_aguardando_instalacao', 'saida')
    when '1_vendido'               then para in ('2_aguardando_instalacao', '3_instalado', 'saida')
    when '2_aguardando_instalacao' then para in ('3_instalado', 'saida')
    when '3_instalado'             then para in ('4_ativo_provisorio')
    when '4_ativo_provisorio'      then para in ('5_comissao_firme')
    when 'saida'                   then para in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
    else false end;
  -- 0256 (D11, Ricardo 17/11): OS (venda contada) só com a biometria aprovada — vale para a ficha, a extensão e qualquer caminho.
  -- Só o admin libera, pelo menu ⋯ › Mover para, com o motivo (essa função marca niogen.transicao_ok e passa acima).
  if ok and de = '0_qualificado' and para in ('1_vendido', '2_aguardando_instalacao')
     and coalesce(new.biometria_status, '') not in ('validada', 'dispensada') then
    raise exception 'A OS só pode ser gravada com a biometria aprovada (hoje: %). Grave a biometria antes; exceção só pelo admin (⋯ › Mover para, com o motivo).',
      coalesce(new.biometria_status, 'não enviada') using errcode = 'P0001';
  end if;
  -- 0256 (D4/D15): crédito aprovado só no cartão → a OS tem de ser no cartão
  if ok and de = '0_qualificado' and para in ('1_vendido', '2_aguardando_instalacao')
     and new.credito_resultado = 'so_cartao' and coalesce(new.forma_pagamento, '') <> 'cartao' then
    raise exception 'O crédito foi aprovado só no cartão: a forma de pagamento da OS tem de ser cartão (hoje: %).',
      coalesce(new.forma_pagamento, 'não informada') using errcode = 'P0001';
  end if;
  if not ok then
    raise exception 'Essa mudança de etapa não pode ser feita direto (de % para %). Voltar ou pular degrau é só do admin, pelo menu ⋯ › Mover para, com o motivo.',
      public._status_nome(de), public._status_nome(para) using errcode = 'P0001';
  end if;
  return new;
end;
$function$;

commit;
