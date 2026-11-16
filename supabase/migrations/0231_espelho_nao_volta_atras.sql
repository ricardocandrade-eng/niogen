-- NIOGEN | supabase/migrations/0231_espelho_nao_volta_atras.sql | 16/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11, caso Tamires — conversa 55: "Ao marcar uma Saída… a conversa não precisa ficar como Resolvida?" →
-- "Sim, corrija").
-- Achado: a Saída de 12:24 resolveu a conversa no Chatwoot (ação 1782 feita 12:24:14, conferido pela API: "resolved"), mas 3 s
-- depois o espelho voltou para "open". A Saída manda resolver, tirar o dono e tirar o time no mesmo segundo; o evento do Chatwoot
-- de "tirar o dono", montado com o status de antes, chegou ao mari_chatwoot_sync DEPOIS do resolve e escreveu por cima.
-- Na tela do NIOGEN: lead em Saída aparecendo com a conversa aberta.
-- O quê: mari_chatwoot_sync não volta atrás no que a fila do NIOGEN acabou de fazer no Chatwoot (30 s):
--   · status: "open"/"pending" logo depois de um resolver/adiar feito pela fila é ignorado — salvo se o cliente escreveu depois
--     (mensagem nova reabre de verdade);
--   · pessoa/time: o mesmo para pessoa ou time que a fila acabou de tirar (sem atribuição feita depois), para o evento atrasado
--     não religar "humano/time atribuído" e travar a cadência.
-- Acerto: a conversa 55 (Tamires) volta para "resolved". As outras 2 em Saída com "open" (76, 118) estão abertas de verdade no
-- Chatwoot (devolvidas para a Mari / cliente escreveu) — não mudam.
-- Regra 20: (1) nenhum estado novo; (2) não se aplica; (3) o espelho continua mudando só por função do banco; (4) a fonte do status
-- é o Chatwoot — a trava só descarta o evento que chega fora de ordem; (5) a conferência diária (0228) já compara Saída × dono;
-- a carga completa (scripts/chatwoot_status_carga.py) segue como rede. Nada no mari_principal (o portão não se aplica).
begin;

create or replace function public.mari_chatwoot_sync(
  p_chatwoot_conversation_id text,
  p_status    text,
  p_agente    text,
  p_time      text,
  p_etiquetas text[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n       integer := 0;
  m       public.mari_conversas;
  v_st    text;
  v_ag    text := nullif(btrim(coalesce(p_agente, '')), '');
  v_tm    text := nullif(btrim(coalesce(p_time, '')), '');
  ag      text;
  tm      text;
  st      text;
  r_res   record;
  t_ag    timestamptz;
  t_tm    timestamptz;
begin
  if coalesce(btrim(p_chatwoot_conversation_id), '') = '' then
    return 0;
  end if;
  v_st := case when p_status in ('open', 'pending', 'resolved', 'snoozed') then p_status end;

  for m in select * from public.mari_conversas
            where chatwoot_conversation_id = btrim(p_chatwoot_conversation_id) and canal = 'whatsapp'
  loop
    st := coalesce(v_st, m.chatwoot_status);
    ag := v_ag;
    tm := v_tm;

    -- 0231: "aberta" atrasada logo depois de um resolver/adiar da fila → mantém o que a fila fez (salvo cliente escreveu depois)
    if v_st in ('open', 'pending') then
      select a.payload ->> 'status' as status, a.feita_em into r_res
        from public.chatwoot_acoes a
       where a.conversa_id = m.id and a.tipo = 'resolver' and a.status = 'feita' and a.feita_em is not null
       order by a.feita_em desc limit 1;
      if r_res.status in ('resolved', 'snoozed') and r_res.feita_em > now() - interval '30 seconds'
         and coalesce(m.ultima_msg_lead_at, '-infinity'::timestamptz) <= r_res.feita_em then
        st := m.chatwoot_status;
      end if;
    end if;

    -- 0231: pessoa/time que a fila acabou de tirar não volta por evento atrasado
    if v_ag is not null and m.chatwoot_agente is null then
      select max(a.feita_em) into t_ag from public.chatwoot_acoes a
       where a.conversa_id = m.id and a.tipo = 'desatribuir' and a.status = 'feita'
         and a.payload ? 'assignee_id' and a.payload ->> 'assignee_id' is null;
      if t_ag > now() - interval '30 seconds'
         and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'atribuir'
                          and a.payload ? 'assignee_id' and a.status in ('pendente', 'executando', 'feita')
                          and coalesce(a.feita_em, now()) > t_ag) then
        ag := null;
      end if;
    end if;
    if v_tm is not null and m.chatwoot_time is null then
      select max(a.feita_em) into t_tm from public.chatwoot_acoes a
       where a.conversa_id = m.id and a.tipo = 'desatribuir' and a.status = 'feita'
         and a.payload ? 'team_id' and a.payload ->> 'team_id' is null;
      if t_tm > now() - interval '30 seconds'
         and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'atribuir'
                          and a.status in ('pendente', 'executando', 'feita')
                          and coalesce(a.feita_em, now()) > t_tm) then
        tm := null;
      end if;
    end if;

    update public.mari_conversas
       set chatwoot_status    = st,
           chatwoot_agente    = ag,
           chatwoot_time      = tm,
           chatwoot_etiquetas = coalesce(p_etiquetas, '{}'),
           -- 0227 (D3): sem pessoa/time no Chatwoot → desmarca (salvo atribuição do NIOGEN ainda na fila)
           humano_atribuido = case when ag is not null then true
                                   when exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'atribuir'
                                                 and a.status in ('pendente', 'executando') and a.payload ? 'assignee_id') then humano_atribuido
                                   else false end,
           time_atribuido = case when tm is not null then true
                                 when exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'atribuir'
                                               and a.status in ('pendente', 'executando')) then time_atribuido
                                 else false end,
           chatwoot_sync_em   = now()
     where id = m.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.mari_chatwoot_sync(text, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.mari_chatwoot_sync(text, text, text, text, text[]) to service_role;

-- ── Acerto: Tamires (conversa 55) — resolvida no Chatwoot (API, 16/11), espelho "open" pelo evento atrasado ──
update public.mari_conversas
   set chatwoot_status = 'resolved', chatwoot_sync_em = now()
 where canal = 'whatsapp' and chatwoot_conversation_id = '55' and chatwoot_status = 'open'
   and funil_destino = 'sem_resposta';

commit;
