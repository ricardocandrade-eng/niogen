-- NIOGEN | supabase/migrations/0002_revoga_execute_triggers.sql | 03/11/2026
-- Advisor de segurança: funções de trigger ficavam expostas em /rest/v1/rpc. Só o trigger as chama.
-- meu_perfil() e checar_duplicidade() continuam liberadas para authenticated (são usadas pelo RLS e pelo front).

revoke execute on function public.vendas_antes_status()      from public, anon, authenticated;
revoke execute on function public.vendas_registra_evento()   from public, anon, authenticated;
revoke execute on function public.contatos_registra_evento() from public, anon, authenticated;
