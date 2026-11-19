-- NIOGEN | supabase/migrations/0311_dados_completos_200m.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Divergência 885 da porta (Chatwoot 185, 19/11 10h49): a Mari passou o lead com dados completos (C1) e a venda nasceu "conferir os
-- 200 m" — viável só pelos 200 m (B5) —, que é "Com o time · responder agora" (time_agora). A tabela só previa qualificado
-- (crédito, biometria ou OS) e a porta acusou divergência. O sistema fez o certo: o time confere os 200 m antes do crédito.
-- O mesmo vale para o antifraude a conferir na hora do handoff (também time_agora).
-- O que muda: só a linha mari_passou:dados_completos @ andamento ganha time_agora entre os destinos; e as anotações antigas que a
-- tabela de hoje explica saem da lista (porta_divergencias_rever, 0276).
-- Ricardo, 19/11: "Conserte a divergência da conversa 185". Cenário X42.
-- Regra 20: (1) nenhuma tabela nova; (2) não muda o que o sistema faz — só o que a tabela prevê; (3) tela: porta_botoes não usa
-- eventos da Mari; (4) desempenho: sem impacto.
begin;

update public.config_transicao
   set para = array['qualificado_credito', 'qualificado_biometria', 'qualificado_os', 'time_agora'],
       nota = 'C1; 0311: só 200 m (B5) ou antifraude a conferir → Com o time'
 where evento = 'mari_passou:dados_completos' and de = 'andamento';

select public.porta_divergencias_rever();

commit;
