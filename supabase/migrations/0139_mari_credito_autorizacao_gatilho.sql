-- NIOGEN | supabase/migrations/0139_mari_credito_autorizacao_gatilho.sql | 12/11/2026 — Claude Code
-- A Mari grava a autorização do titular em dados (mari_salvar_turno só atualiza colunas de uma lista fechada; dados é mesclado):
-- dados.credito_autorizado_em / credito_autorizacao_frase / credito_recusado_em. Este gatilho copia para as colunas da 0138
-- (é delas que o n8n mari_credito lê) — só na primeira vez, nunca apaga.
create or replace function public._mari_credito_autorizacao() returns trigger language plpgsql as $$
begin
  if new.credito_autorizado_em is null and coalesce(new.dados->>'credito_autorizado_em', '') <> '' then
    new.credito_autorizado_em := (new.dados->>'credito_autorizado_em')::timestamptz;
    new.credito_autorizacao_frase := left(new.dados->>'credito_autorizacao_frase', 300);
  end if;
  if new.credito_recusado_em is null and coalesce(new.dados->>'credito_recusado_em', '') <> '' then
    new.credito_recusado_em := (new.dados->>'credito_recusado_em')::timestamptz;
  end if;
  return new;
end $$;
drop trigger if exists mari_credito_autorizacao on public.mari_conversas;
create trigger mari_credito_autorizacao before insert or update of dados on public.mari_conversas
  for each row execute function public._mari_credito_autorizacao();
