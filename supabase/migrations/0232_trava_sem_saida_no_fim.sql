-- NIOGEN | supabase/migrations/0232_trava_sem_saida_no_fim.sql | 16/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11 ~12h40, "mas olha o q aconteceu com o cliente Wilson Santiago").
-- Achado (conversa 109): Saída "Recusou" às 12:26 → resolvida no Chatwoot → REABERTA às 12:28 pelo próprio NIOGEN (nota "Resolvida
-- sem destino de saída") → a cadência viu a conversa aberta e a Mari escreveu às 12:35 a quem tinha dito "não tenho interesse
-- agora" → a trava "refechar" (0199) resolveu de novo às 12:38.
-- Causa: backoffice_conversa_saida (saída de conversa sem venda) primeiro chama mari_cadencia_parar(p_resolvida => true) —
-- liga chatwoot_resolvida — e só no UPDATE seguinte grava o motivo da saída. A trava 1 da 0217 é BEFORE UPDATE: viu, no meio da
-- Saída, "resolvida + em andamento + sem dono" e pôs o reabrir na fila. A Tamires (conversa 55) escapou porque estava assumida.
-- Pega toda Saída sem venda de conversa sem dono desde 15/11 ~14h (no banco, só o Wilson até agora).
-- O quê: a trava 1 passa a olhar no FIM da transação (constraint trigger deferido): relê a conversa como ficou e só reabre se
-- continuar "resolvida sem saída". Resolvida por fora (gente no Chatwoot, automação) segue reabrindo como antes; a Saída inteira
-- (motivo + resolvida na mesma transação) não reabre mais, seja qual for a ordem das linhas.
-- Regra 20: (1) nenhum estado novo; (2) a saída automática do estado "resolvida sem saída" continua; (3) só gatilho/função do banco;
-- (4) fonte: mari_conversas; (5) a conferência diária (0228) já pega Saída com dono e mensagem automática com conversa assumida.
-- Nada no mari_principal (o portão não se aplica).
begin;

create or replace function public._conversa_resolvida_sem_saida_fim() returns trigger
language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = new.id;
  if c.id is not null and public._resolvida_sem_saida(c) then
    update public.mari_conversas set chatwoot_resolvida = false where id = c.id;
    perform public._reabrir_sem_saida(c);
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_conversa_resolvida_sem_saida_fim', new.id::text || ': ' || sqlerrm);
  return null;
end;
$$;
revoke all on function public._conversa_resolvida_sem_saida_fim() from public, anon, authenticated;

drop trigger if exists mari_conversas_resolvida_sem_saida on public.mari_conversas;   -- o BEFORE da 0217 (olhava no meio da Saída)
drop trigger if exists mari_conversas_resolvida_sem_saida_fim on public.mari_conversas;
create constraint trigger mari_conversas_resolvida_sem_saida_fim after update on public.mari_conversas
  deferrable initially deferred
  for each row when (coalesce(new.chatwoot_resolvida, false) and not coalesce(old.chatwoot_resolvida, false))
  execute function public._conversa_resolvida_sem_saida_fim();

commit;
