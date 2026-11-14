-- NIOGEN | supabase/migrations/0193_jornada_nome_pedido_os.sql | 14/11/2026 — Claude Code (Opus 5.5)
-- 0194: a etapa 3 da jornada (crédito aprovado, sem OS) deixou de ser "Biometria" — a biometria vem depois da OS. Nome novo:
-- "Pedido (OS)", igual ao app.js (JORNADA/ETAPAS). Mesmo nome em toda tela (0089).
create or replace function public.jornada_nome(p_etapa integer)
 returns text
 language sql
 immutable
 set search_path to 'public'
as $function$
  select case p_etapa when 1 then 'Conversa' when 2 then 'Lead qualificado' when 3 then 'Pedido (OS)'
                      when 4 then 'Ativação/Agenda' when 5 then 'Instalada' else 'Saída' end
$function$;
