-- NIOGEN | supabase/migrations/0004_search_path_osab.sql | 03/11/2026
-- Advisor de segurança: search_path fixo nas funções de classificação do OSAB (só usam funções do pg_catalog).

alter function public.osab_cancelada(text) set search_path = '';
alter function public.osab_risco(boolean, text, text) set search_path = '';
