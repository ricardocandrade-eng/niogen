-- NIOGEN | supabase/migrations/0154_pulso_titulo_saude.sql | 12/11/2026 — Claude Code (Sonnet 5.5)
-- Prompt: docs/Prompt_pulso_titulo_121126_1920.md (Drive). O prompt chama esta migration de 0152, mas a 0152 (voz da Mari) e a 0153
--   já estavam no repo — número real: 0154.
-- Resultado buscado: nenhum direto em venda (cosmético, regra 18). Pedido do Ricardo, 12/11 19h18: o card geral da faixa de pulso da
--   Live deixa de dizer "Tudo respirando" e passa a dizer "Saúde do ecossistema".
-- O quê: pulso_operacao() (0144) devolve o título do card geral em geral.titulo; no estado 'ok' o texto era 'Tudo respirando'.
--   Troca SÓ esse literal. Os outros estados ("Mari parada", "X em atenção", "X sem leitura") não mudam.
-- Como: sem reescrever a função à mão — lê a definição viva do banco (pg_get_functiondef), troca o literal, confere que trocou
--   exatamente 1 ocorrência (senão aborta sem mudar nada) e recria. CREATE OR REPLACE mantém dono, ACL (grants), SECURITY DEFINER e
--   search_path da função, que vêm na própria definição.
-- Não toca: status_operacao(), selo do menu, texto do alerta, rótulos dos elos, a 0144.

do $$
declare
  v_def    text;
  v_velho  constant text := 'Tudo respirando';
  v_novo   constant text := 'Saúde do ecossistema';
  v_qtde   int;
begin
  v_def := pg_get_functiondef('public.pulso_operacao()'::regprocedure);

  v_qtde := (length(v_def) - length(replace(v_def, v_velho, ''))) / length(v_velho);
  if v_qtde <> 1 then
    raise exception '0154: esperava 1 ocorrência de "%" em pulso_operacao(), achei % — nada foi alterado', v_velho, v_qtde;
  end if;

  execute replace(v_def, v_velho, v_novo);
end
$$;
