-- NIOGEN | supabase/migrations/0200_volta_para_a_mari.sql | 15/11/2026 00:20 — Claude Code (Opus 5.5)
-- Ricardo (14/11): "leads como Andriene … estão como Resolvidos e atribuídos ao Backoffice, todos com janela de 24 h fechada.
-- Se um dia eles retornarem, não deveriam ser atendidos pela Mari? Não deveria ter uma regra de voltar para a Mari automaticamente?"
-- Causa: resolver no Chatwoot já fecha o ciclo da Mari no banco (mari_encerrar_ciclo), mas o time continua atribuído no
-- Chatwoot. Quando o cliente volta, o Chatwoot reabre e o guard da Mari (nó 2h) vê o time atribuído → Mari calada, e a
-- conversa (em Saída) não aparece na Live. Ninguém responde.
-- Regra nova: conversa RESOLVIDA, com time ou pessoa atribuída, sem fala de ninguém há 24 h (janela fechada) → volta para a
-- Mari, igual ao botão "Devolver para a Mari": tira etiquetas handoff-venda/handoff-humano, tira pessoa e time, nota no
-- Chatwoot; no banco humano/time_atribuido = false e, se ainda em handoff, fecha o ciclo (retomada). A conversa continua
-- resolvida: só se o cliente escrever a Mari responde (nada é enviado por esta regra).
-- Ficam com o time: não contatar / suporte-nio (silenciada), já é cliente Nio, instalada (pós-venda) e venda viva.
-- Roda dentro de backoffice_acoes_proximas (executor da fila, a cada 1 min) — não existe pg_cron neste projeto.
-- Sistema fechado (regra 20): estado muda por função do banco, com autor ("NIOGEN · janela fechada") no turno de sistema e
-- na nota; nenhuma tabela nova; a fila do Chatwoot registra cada ação (momento volta_mari). Nada no mari_principal.

create or replace function public._conversas_volta_mari() returns int
language plpgsql security definer set search_path = public as $$
declare
  c   public.mari_conversas;
  g   uuid;
  n   int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null and m.chatwoot_status = 'resolved'
       and (m.chatwoot_time is not null or m.chatwoot_agente is not null or coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false))
       and not coalesce(m.nao_contatar, false)
       and not (coalesce(m.chatwoot_etiquetas, '{}') && array['nao-contatar', 'suporte-nio'])
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and coalesce(m.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente', 'instalada')
       and (m.venda_id is null or exists (select 1 from public.vendas v where v.id = m.venda_id and v.status = 'saida'))
       and greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at) < now() - interval '24 hours'
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano'
                        and t.created_at > now() - interval '24 hours')
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.momento = 'volta_mari'
                        and a.criada_em > greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at))
     limit 20
     for update skip locked
  loop
    g := gen_random_uuid();
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_agente = null, chatwoot_time = null
     where id = c.id;
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'janela de 24 h fechada com o time — volta para a Mari');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[janela de 24 h fechada com o time e sem venda viva — a conversa volta para a Mari; se o cliente escrever, ela atende]', false);
    perform public._bo_enfileirar(g, 1, 'volta_mari', c.venda_id, c, 'etiquetas',
      jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
    perform public._bo_enfileirar(g, 2, 'volta_mari', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    perform public._bo_enfileirar(g, 3, 'volta_mari', c.venda_id, c, 'desatribuir', jsonb_build_object('team_id', null));
    perform public._bo_enfileirar(g, 4, 'volta_mari', c.venda_id, c, 'nota',
      jsonb_build_object('content', '↩ NIOGEN · janela de 24 h fechada sem venda viva: a conversa volta para a Mari. Se o cliente voltar a escrever, ela atende. Para seguir com o time, assuma de novo.'));
    -- o enfileirar toca a conversa; a marca de "já devolvida" é a própria ação volta_mari (não repete até alguém falar de novo)
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public._conversas_volta_mari() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.backoffice_acoes_proximas(p_limite integer DEFAULT 20)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  a      public.chatwoot_acoes;
  c      public.mari_conversas;
  conta  text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
  usr    jsonb := public._bo_cfg('backoffice_cred_usuario', '[]'::jsonb);
  base   text;
  n      int := 0;
begin
  if not coalesce((public._bo_cfg('backoffice_chatwoot_ligado', 'true') #>> '{}')::boolean, true) then return; end if;
  -- 0200: resolvida com o time e janela de 24 h fechada → volta para a Mari (varredura barata, a cada rodada de 1 min).
  begin perform public._conversas_volta_mari(); exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_conversas_volta_mari', sqlerrm); end;
  -- 'executando' preso há mais de 10 min (execução caiu no meio) volta para a fila.
  update public.chatwoot_acoes set status = case when tentativas < 3 then 'pendente' else 'erro' end,
         erro = coalesce(erro, 'execução interrompida')
   where status = 'executando' and pega_em < now() - interval '10 minutes';
  for a in
    select x.* from public.chatwoot_acoes x
     where x.status = 'pendente' and x.executar_apos <= now()
       -- 0083: o clique inteiro sai na mesma rodada (o n8n executa etiquetas primeiro e o resto na ordem do id). Só espera
       -- quando uma ação anterior do grupo ainda vai sair mais tarde (mensagem fora do horário) ou está numa rodada anterior.
       and not exists (select 1 from public.chatwoot_acoes y
                        where y.grupo = x.grupo and y.ordem < x.ordem
                          and (y.status = 'executando' or (y.status = 'pendente' and y.executar_apos > now())))
     order by x.executar_apos, x.grupo, x.ordem
     limit greatest(1, least(coalesce(p_limite, 20), 50))
     for update skip locked
  loop
    select * into c from public.mari_conversas where id = a.conversa_id;
    if a.tipo = 'mensagem' and coalesce(c.nao_contatar, false) then
      update public.chatwoot_acoes set status = 'cancelada', erro = 'cliente pediu para não ser contatado', feita_em = now() where id = a.id;
      continue;
    end if;
    update public.chatwoot_acoes set status = 'executando', tentativas = tentativas + 1, pega_em = now() where id = a.id;
    base := 'https://app.chatwoot.com/api/v1/accounts/' || conta || '/conversations/' || a.chatwoot_conversation_id;
    n := n + 1;
    return next jsonb_build_object(
      'id', a.id, 'tipo', a.tipo, 'momento', a.momento,
      'usuario', (usr ? a.tipo) or coalesce(a.payload ->> 'como', '') = 'humano',   -- 0090: resposta do time sai como pessoa
      'url_base', base,
      'url', base || case a.tipo when 'atribuir' then '/assignments' when 'desatribuir' then '/assignments'
                                 when 'etiquetas' then '/labels' when 'resolver' then '/toggle_status' else '/messages' end,
      'corpo', case a.tipo
                 when 'nota' then jsonb_build_object('content', a.payload ->> 'content', 'message_type', 'outgoing', 'private', true)
                 when 'mensagem' then (a.payload - 'texto_chave' - 'rotulo' - 'template' - 'motivo' - 'como' - 'conta')
                 when 'etiquetas' then '{}'::jsonb
                 else a.payload end,
      'add', coalesce(a.payload -> 'add', '[]'::jsonb), 'remove', coalesce(a.payload -> 'remove', '[]'::jsonb));
  end loop;
  return;
end;
$function$;

-- a primeira rodada sai já na aplicação
select public._conversas_volta_mari();
