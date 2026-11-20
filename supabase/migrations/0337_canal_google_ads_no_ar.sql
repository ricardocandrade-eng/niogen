-- NIOGEN | supabase/migrations/0337_canal_google_ads_no_ar.sql | 20/11/2026 — Claude Code (Opus 5.5)
-- Prompt docs/Prompt_lp_nio_jf_201126_1910.md (dia 5 do plano de canais): a LP dharma-site /nio-internet/ está no ar e o nó
-- "2 · Entrada" da Mari grava origem 'google_ads' pela marca (GADS)/(GADS-PJ). Aqui o canal passa a aparecer no card
-- "Canais · 7 dias" (ativo) com a data em que subiu. Só dado de config; nenhuma função, tabela ou situação nova.
-- Regra 20: (1)(2)(3) não cria estado de lead — o lead nasce na Mari como qualquer outro · (4) origem = texto da conversa
-- (NIOGEN), gasto = à mão em Configurações › Canais · (5) já coberto pela conferência "origem desconhecida" da 0302.
begin;

update public.config_canais
   set ativo = true,
       subiu_em = date '2026-11-20',
       nota = 'LP dharmatelecom.com.br/nio-internet/ · botões terminam em (GADS)/(GADS-PJ) · custo à mão em Configurações › Canais'
 where canal = 'google_ads';

commit;
