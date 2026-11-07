-- NIOGEN | supabase/migrations/0055_meta_ads_regras_campanha.sql | 07/11/2026 — Claude Code (bloco "Saúde da campanha")
-- Só dados de config: os limites de nível campanha que o bloco "Saúde da campanha" (tela Meta Ads › Desempenho) e o
-- futuro agente (doc da campanha 1 §7.1, regra R4) usam. Regra 15: nada fixo no código. Nenhuma tabela nova.
insert into public.config_meta_ads_regras (chave, valor, descricao) values
  ('conversa_custo_meta',         15,  'Custo por conversa (R$) que conta como bom — verde no semáforo'),
  ('campanha_gasto_avaliar',      250, 'Gasto da campanha (R$) a partir do qual dá para julgar (antes disso: "cedo para julgar")'),
  ('campanha_custo_conversa_max', 20,  'Depois do gasto de avaliação, custo por conversa (R$) acima disto → propor juntar num conjunto só')
on conflict (parceiro_id, chave) do nothing;
