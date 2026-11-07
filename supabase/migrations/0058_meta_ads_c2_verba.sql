-- NIOGEN | supabase/migrations/0058_meta_ads_c2_verba.sql | 07/11/2026 — Claude Code, prompt 29 (campanha 2 MG)
-- Só dados de config (regra 15: nada fixo no código). Nenhuma tabela nova.
--   c2_orcamento_diario    → CBO da campanha 2 (meta/campanha2_mg.py lê daqui; teto deste prompt R$ 200)
--   c2_cj_jf_gasto_min     → gasto mínimo do conjunto Juiz de Fora (daily_min_spend_target)
--   verba_mes              → verba de Meta Ads do mês na tela Meta Ads (antes fixa em R$ 2.000 no front)
insert into public.config_meta_ads_regras (chave, valor, descricao) values
  ('c2_orcamento_diario', 200,  'Campanha 2 MG: orçamento diário da campanha (CBO, R$). Ricardo autorizou até ~R$ 250; acima de 200 só depois de 72 h'),
  ('c2_cj_jf_gasto_min',  40,   'Campanha 2 MG: gasto mínimo diário do conjunto CJ_JF (R$, daily_min_spend_target)'),
  ('verba_mes',           2000, 'Verba de Meta Ads do mês (R$) exibida na tela Meta Ads › Desempenho')
on conflict (parceiro_id, chave) do nothing;
