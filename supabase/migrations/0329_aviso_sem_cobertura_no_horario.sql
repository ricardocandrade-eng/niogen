-- NIOGEN | supabase/migrations/0329_aviso_sem_cobertura_no_horario.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Correção da 0325. Medido no ar (19/11 23:30): a Meta aprovou o nio_sem_cobertura às 23:29 e os 11 avisos represados saíram às
-- 23:30. Causa: a varredura usa _bo_mensagem, que desde a 0095 manda NA HORA, sem horário de contato e sem o teto de 2/dia — é a
-- peça dos botões do time ("o operador apertou → sai agora"). Numa varredura automática, isso vale como cadência: a regra é a dela.
-- O que muda: _cobertura_avisa_veredito só pega quem está dentro do horário dos toques (mari_proximo_horario = agora, config
-- mari_horario_toques, hoje 9h–21h, pela cidade) e com menos de 2 contatos no dia (mari_toques). Fora disso, a conversa NÃO é
-- marcada e sai na rodada seguinte que caber. _bo_mensagem não muda (os botões seguem saindo na hora).
-- Regra 20: nenhuma situação nova; mesma porta e evento da 0325. Cenário X53 ganha o caso da noite.
begin;

create or replace function public._cobertura_avisa_veredito() returns int
language plpgsql security definer set search_path = public as $$
declare
  c   public.mari_conversas;
  v_a text;
  r   jsonb;
  n   int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
       and m.cobertura_decisao = 'sem_cobertura' and m.funil_destino = 'sem_cobertura'
       and m.cobertura_em between now() - interval '30 days' and now() - interval '2 minutes'    -- 2 min: a Mari pode estar dizendo
       and not coalesce(m.nao_contatar, false)
       and public.mari_proximo_horario(now(), m.cidade) <= now()                                  -- 0329: só no horário dos toques (9h–21h)
       and coalesce((public.mari_toques(m.telefone, now())).hoje, 0) < 2                          -- 0329: teto de 2 contatos no dia
       and (m.ultima_msg_lead_at > now() - interval '23 hours'                                  -- janela aberta: texto livre
            or exists (select 1 from public.config_templates_waba w where w.nome = 'nio_sem_cobertura' and w.status = 'APPROVED'))   -- fechada: só com o template
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'mari' and t.created_at > m.cobertura_em)   -- a Mari falou depois: ela soube
       and not (m.humano_atribuido or m.time_atribuido or m.chatwoot_agente is not null)        -- com o time, avisa o time (⛔ na Live)
       and not (m.status = 'handoff_realizado' and m.handoff_motivo = 'sem_cobertura')          -- a Mari já passou dizendo
       and coalesce(m.dados ->> 'sem_cobertura_avisado', '') <> floor(extract(epoch from m.cobertura_em))::bigint::text
       and coalesce(m.dados ->> 'cobertura_aviso_tentado', '') <> floor(extract(epoch from m.cobertura_em))::bigint::text
       and (m.dados ->> 'cobertura_avisada_em' is null or (m.dados ->> 'cobertura_avisada_em')::timestamptz < m.cobertura_em)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.pendente)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano' and t.created_at > m.cobertura_em)
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'mensagem' and a.status in ('pendente', 'executando'))
     order by m.cobertura_em
     limit 20
     for update skip locked
  loop
    v_a := public._porta_situacao(c.id, null::uuid);
    perform set_config('porta.dentro', 'aviso_sem_cobertura', true);
    r := public.porta('aviso_sem_cobertura', c.id, null::uuid, '{}'::jsonb);
    perform set_config('porta.dentro', '', true);
    perform public._porta_anotar('aviso_sem_cobertura', 'sem_cobertura_auto', c.id, null::uuid, v_a, r);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public._cobertura_avisa_veredito() from public, anon, authenticated;

commit;
