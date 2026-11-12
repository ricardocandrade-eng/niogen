-- NIOGEN | supabase/migrations/0148_espelho_status_resolve.sql | 12/11/2026 — Claude Code (Opus 5.5)
-- Por quê: depois da 0147, as 23 saídas foram resolvidas no Chatwoot (conferido pela API), mas mari_conversas.chatwoot_status
-- seguiu "open" em 19 delas: o evento "resolvida" do Chatwoot vai para o 2v da Mari (fecha o ciclo) e não atualiza o espelho.
-- Resultado na tela: conversa com destino de saída aparecendo "Aberta · Mari atendendo".
-- O quê: quando a fila do NIOGEN confirma um resolve/reabrir/adiar (chatwoot_acoes tipo 'resolver' vira 'feita'), o espelho
-- da conversa recebe o status na hora. A carga completa (scripts/chatwoot_status_carga.py --aplicar) continua sendo a rede.

create or replace function public._cw_espelho_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  st text := new.payload ->> 'status';
begin
  if new.tipo <> 'resolver' or new.status <> 'feita' or old.status = 'feita' or st not in ('open', 'resolved', 'snoozed', 'pending') then
    return null;
  end if;
  update public.mari_conversas
     set chatwoot_status = st,
         chatwoot_resolvida = (st = 'resolved') or chatwoot_resolvida,
         chatwoot_sync_em = now()
   where canal = 'whatsapp' and chatwoot_conversation_id = new.chatwoot_conversation_id;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_cw_espelho_status', sqlerrm);
  return null;
end;
$$;
revoke all on function public._cw_espelho_status() from public, anon, authenticated;
drop trigger if exists chatwoot_acoes_espelho_status on public.chatwoot_acoes;
create trigger chatwoot_acoes_espelho_status after update of status on public.chatwoot_acoes
  for each row execute function public._cw_espelho_status();
