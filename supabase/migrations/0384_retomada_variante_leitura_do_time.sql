-- NIOGEN | supabase/migrations/0384_retomada_variante_leitura_do_time.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 24/11: "A linha que mostrava os dados coletados do cliente dentro da Ficha e das Conversas sumiu" (a linha estreita
-- abaixo da Jornada da venda, de 22/11).
-- Causa: a 0381 criou public._retomada_variante e tirou o EXECUTE de authenticated. Ela é chamada por mari_cadencia_avaliar
-- (security invoker), que entra na v_mari_cadencia e, por ela, na v_mari_quadro. Para quem está logado no NIOGEN, ler a
-- v_mari_quadro passou a dar "permission denied for function _retomada_variante" — a ficha recebia vazio e a linha sumia
-- (e o que mais lê a v_mari_quadro/v_mari_cadencia com a sessão do time também falhava).
-- O que muda: o EXECUTE volta para authenticated (como as demais funções que a cadência chama). A função só LÊ
-- (config_mari_textos e config_planos, pelas políticas de quem chama) e não grava nada; anon continua sem.
-- Regra 20: (1)–(3) nenhum estado novo nem gravação; (4) fonte de sempre (a conversa); (5) sem número novo — o cenário X107
-- prova a leitura como o time. Desempenho: sem impacto (só permissão).
begin;
grant execute on function public._retomada_variante(public.mari_conversas, text) to authenticated;
commit;
