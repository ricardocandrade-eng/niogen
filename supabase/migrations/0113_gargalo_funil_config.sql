-- NIOGEN | supabase/migrations/0113_gargalo_funil_config.sql | 10/11/2026 ~20h30 — Claude Code (Opus)
-- Prompt: docs/Prompt_funil_instalacoes_resultado_101126_1645.md, Parte 2 item 9 — faixa do gargalo no Funil.
-- O limiar de conversão entre os passos do funil do dia da Mari (mari_ao_vivo: conversas › viram os planos › qualificadas)
-- fica em config (regra 15), nunca no código.
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('gargalo_conversao_min_pct', '10'::jsonb,
   'Funil › faixa do gargalo: aparece quando um passo do funil do dia da Mari (conversas › viram os planos › qualificadas) é 0 ou converte menos que este % do passo anterior, ou quando não há lead qualificado no funil.', 'dharma')
on conflict (chave) do nothing;
