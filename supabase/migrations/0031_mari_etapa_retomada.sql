-- NIOGEN | supabase/migrations/0031_mari_etapa_retomada.sql | 05/11/2026 — Claude Code (prompt nº 18)
-- A 0030 põe etapa = 'retomada' quando o ciclo da Mari fecha (conversa resolvida no Chatwoot), mas o check
-- mari_conversas_etapa_check (0013) só aceitava as 7 etapas do fluxo — a bateria (cenário 31) pegou antes da
-- produção. Acrescenta 'retomada'; nada mais muda.

alter table public.mari_conversas drop constraint if exists mari_conversas_etapa_check;
alter table public.mari_conversas add constraint mari_conversas_etapa_check
  check (etapa in ('abertura', 'endereco', 'elegibilidade', 'planos', 'coleta', 'resumo', 'handoff', 'retomada'));
