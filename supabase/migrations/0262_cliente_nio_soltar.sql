-- NIOGEN | supabase/migrations/0262_cliente_nio_soltar.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 17/11 ("Pode soltar!"): os clientes Nio que entraram em "já é cliente Nio" ANTES da 0261 continuavam com o time, com uma
-- pessoa ou com a etiqueta handoff-* (a regra antiga: "fica com o time enquanto há conversa"). Na produção em 17/11: 9 conversas
-- (7 com time/pessoa — 2 com o Ricardo —, 2 só com handoff-humano). Uma vez, pela fila do backoffice (o Chatwoot muda pelo n8n):
-- tira handoff-venda/humano, a pessoa e o time; silenciada (suporte_nio) continua adiada, as outras ficam resolvidas; nota.
-- Situação 15 (Ricardo, 17/11): cliente Nio é de ninguém — somos revenda. Não mexe em conversa de teste.
begin;

do $$
declare
  c public.mari_conversas;
  g uuid;
  o int;
  n int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
      join public.v_lead_situacao s on s.conversa_id = m.id
     where s.situacao = 'cliente_nio' and m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> ''
       and coalesce(m.telefone, '') not like '5500000000%'
       and (m.chatwoot_agente is not null or m.chatwoot_time is not null or coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false)
            or coalesce(m.chatwoot_etiquetas, '{}') && array['handoff-venda', 'handoff-humano'])
  loop
    g := gen_random_uuid(); o := 0;
    o := o + 1; perform public._bo_enfileirar(g, o, 'cliente_nio', c.venda_id, c, 'etiquetas',
      jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
    if c.chatwoot_agente is not null or coalesce(c.humano_atribuido, false) then
      o := o + 1; perform public._bo_enfileirar(g, o, 'cliente_nio', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    end if;
    if c.chatwoot_time is not null or coalesce(c.time_atribuido, false) then
      o := o + 1; perform public._bo_enfileirar(g, o, 'cliente_nio', c.venda_id, c, 'desatribuir', jsonb_build_object('team_id', null));
    end if;
    o := o + 1; perform public._bo_enfileirar(g, o, 'cliente_nio', c.venda_id, c, 'nota', jsonb_build_object('content',
      '🏠 NIOGEN · cliente que já é Nio: a conversa sai do time (regra de 17/11 — somos revenda, sem alçada para atender cliente Nio). '
      || 'Canais oficiais: App Nio ou 0800 001 1000. Se ele insistir, a conversa é silenciada sozinha.'));
    if coalesce(c.quadro_encerrada_motivo, '') = 'suporte_nio' then
      if coalesce(c.chatwoot_status, 'open') <> 'snoozed' then
        o := o + 1; perform public._bo_enfileirar(g, o, 'cliente_nio', c.venda_id, c, 'resolver', jsonb_build_object('status', 'snoozed'));
      end if;
    elsif coalesce(c.chatwoot_status, 'open') <> 'resolved' then
      o := o + 1; perform public._bo_enfileirar(g, o, 'cliente_nio', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'));
    end if;
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente Nio solto do time (0262): ninguém atende — canais oficiais da Nio]', false);
    n := n + 1;
  end loop;
  raise notice 'clientes Nio soltos: %', n;
end $$;

commit;
