-- NIOGEN | supabase/migrations/0316_assumir_com_o_time_esperando.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Divergência 935 (Chatwoot 137, 19/11 13h39): o Assumir num lead da Mari em que o time tinha falado por último foi para
-- "Com o time · esperando o cliente" (time_esperando) — certo desde a 0310 (vez do cliente quando o time falou por último) —, mas a
-- tabela da porta só previa "responder agora" (time_agora) para o Assumir. O Responder já aceitava as duas (C7).
-- O que muda: momento:assumir @ mari_atendendo e @ andamento aceitam também time_esperando; anotações antigas que a tabela de hoje
-- explica saem da lista (porta_divergencias_rever, 0276).
-- Ricardo, 19/11: "Sim, monte". Cenário X45.
-- Regra 20: (1) nenhuma tabela nova; (2) não muda o que o sistema faz — só o que a tabela prevê; (3) tela: o botão Assumir continua
-- aceito nas mesmas situações; (4) desempenho: sem impacto.
begin;

update public.config_transicao
   set para = array['time_agora', 'time_esperando'], nota = 'C5; 0316: com o time — esperando o cliente se o time falou por último (0310)'
 where evento = 'momento:assumir' and de = 'mari_atendendo';

update public.config_transicao
   set para = array['=', 'time_agora', 'time_esperando'], nota = 'C5; 0316: + esperando o cliente (0310)'
 where evento = 'momento:assumir' and de = 'andamento';

select public.porta_divergencias_rever();

commit;
