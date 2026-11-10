-- NIOGEN | supabase/migrations/0098_comissao_ciclo_regra.sql | 10/11/2026 — Claude Code
-- Prompt docs/Prompt_pendencia_some_ao_responder_091126_2355.md (Parte 2, item 10): "Comissão de relance" na ficha mostra a
-- PREVISÃO do ciclo em que a comissão entra. A regra ainda não foi confirmada pela Nio → placeholder em config (regra 15:
-- nada fixo no código) e a ficha sempre rotula "previsão" até o Ricardo confirmar.
--   instalação no dia 1 a corte_dia → 2ª quinzena do mesmo mês · depois do corte → 1ª quinzena do mês seguinte.
insert into public.config_regras (chave, valor, descricao, parceiro_id)
values ('comissao_ciclo_regra',
        '{"corte_dia": 15, "rotulo_ate_corte": "2ª quinz.", "rotulo_depois": "1ª quinz.", "confirmada": false}'::jsonb,
        'Previsão do ciclo da comissão na ficha (placeholder até a Nio confirmar): instalação até o dia de corte → 2ª quinzena do mês; depois → 1ª quinzena do mês seguinte.',
        'dharma')
on conflict (chave) do nothing;
