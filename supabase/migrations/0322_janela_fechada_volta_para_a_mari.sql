-- NIOGEN | supabase/migrations/0322_janela_fechada_volta_para_a_mari.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 19/11: "foram clientes que eu assumi na tentativa de fechar a venda. Os clientes não responderam mais e a janela de 24 h
-- fechou… Eles precisam voltar para a Mari e para a cadência" → "Sim, faz assim".
-- Medido no ar (19/11): 13 leads sem venda no nome do Ricardo, parados no Radar da Live ("Com você · esperando o cliente"), 4 com a
-- janela do cliente já fechada. A volta automática da 0227 (_conversas_volta_mari) não os pegava por duas travas: (a) só conversa
-- RESOLVIDA no Chatwoot; (b) o relógio contava 24 h desde a última fala do TIME (cada "oi, conseguiu ver?" reiniciava).
-- O que muda:
--  (1) _conversas_volta_mari ganha a 2ª parte: lead SEM venda, em andamento, com dono (pessoa ou time), o TIME falou por
--      último (handoff sem resposta do time não entra) e a JANELA DO CLIENTE fechou (24 h desde a última mensagem dele) → volta para a Mari pela mesma peça do botão
--      "Devolver para a Mari" (_porta_devolver: tira dono e time, fecha o ciclo do handoff, etiquetas e nota), anotada na porta
--      (porta_sombra, origem "janela_fechada"). A cadência da Mari volta a valer (conversa aberta e sem dono).
--      Não volta: lead com crédito aprovado ou etapa qualificada/pedido/biometria (é venda: fica com o time e o "Parada com dono"
--      cobra), Não contatar, suporte Nio, em espera com data, ou com ordem ao Chatwoot pendente. A 1ª parte (resolvida) fica igual.
--  (2) _porta_devolver aceita p_dados.por e p_dados.nota (quem e o texto da nota); sem eles, igual ao botão. Recriada da versão no ar.
-- Regra 20: (1) nenhuma situação nova; (2) o dono muda pela peça da porta, anotada; (3) autor "NIOGEN (janela de 24 h fechada)" no
-- turno de sistema e na nota; (4) dono do Chatwoot sai pela fila, como antes; (5) a própria Live: o Radar não guarda mais lead
-- assumido e esquecido. Cenário X50. Tela: sem mudança (a linha some do Radar). Desempenho: o robô já rodava; a 2ª parte usa o índice
-- de mari_turnos por conversa, limite 20.
begin;

-- _porta_devolver (= versão no ar) + por/nota opcionais
CREATE OR REPLACE FUNCTION public._porta_devolver(c mari_conversas, v vendas, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  g       uuid := coalesce(nullif(p_dados ->> 'grupo', '')::uuid, gen_random_uuid());
  o       int  := coalesce((p_dados ->> 'ordem')::int, 0);
  quem    text := coalesce(nullif(p_dados ->> 'por', ''), (select u.nome from public.usuarios u where u.id = auth.uid()), 'time');   -- 0322: o robô diz quem
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  tem_cw  boolean := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
                     and c.telefone not like '5500000000%';
  feito   text[] := '{}';
begin
  if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
  update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
  -- 0155: em handoff a Mari fica calada; devolver fecha o ciclo (status ativo, etapa retomada) sem marcar "resolvida"
  if c.status = 'handoff_realizado' then
    perform public._mari_fechar_ciclo(c.id, 'devolvida para a Mari no NIOGEN por ' || quem);
  end if;
  update public.mari_conversas set chatwoot_resolvida = false where id = c.id and coalesce(funil_destino, 'em_andamento') = 'em_andamento';
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[devolvida para a Mari no NIOGEN por ' || quem || ']', false);
  if tem_cw then
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'etiquetas',
      jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
    o := o + 1; perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    o := o + 1; perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'nota',
      jsonb_build_object('content', coalesce(nullif(p_dados ->> 'nota', ''), '↩ Devolvida para a Mari por ' || quem || ' às ' || agora_t || ' — a Mari continua.')));   -- 0322
    feito := feito || 'atribuição removida'::text || 'nota'::text;
  end if;
  return jsonb_build_object('ok', true, 'acoes', o, 'feito', to_jsonb(feito));
end $function$;

-- _conversas_volta_mari (= versão no ar) + a 2ª parte (janela do cliente fechada)
CREATE OR REPLACE FUNCTION public._conversas_volta_mari()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c   public.mari_conversas;
  g   uuid;
  n   int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and (m.chatwoot_status = 'resolved' or (m.chatwoot_status = 'snoozed' and m.funil_destino in ('ja_cliente_nio', 'ja_cliente')))
       and (m.chatwoot_time is not null or m.chatwoot_agente is not null or coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false))
       and not coalesce(m.nao_contatar, false)
       and not (coalesce(m.chatwoot_etiquetas, '{}') && array['nao-contatar', 'suporte-nio'])
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and (coalesce(m.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente', 'instalada')
            -- 0227 (D2): já é cliente Nio fica com o time enquanto há conversa; 72 h sem ninguém falar → o ciclo fecha
            -- (se voltar a escrever, a Mari vê a Saída e passa para o time — cliente Nio é humano)
            or (m.funil_destino in ('ja_cliente_nio', 'ja_cliente')
                and greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at) < now() - interval '72 hours'
                and not exists (select 1 from public.mari_turnos t2 where t2.conversa_id = m.id and t2.papel = 'humano'
                                 and t2.created_at > now() - interval '72 hours')))
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

  -- 0322 (Ricardo, 19/11: "a janela de 24 h fechou… eles precisam voltar para a Mari e para a cadência"): lead SEM venda que o time
  -- assumiu, o TIME falou por último e a janela do CLIENTE fechou (24 h desde a última mensagem dele) → volta para a Mari
  -- pela mesma peça do botão "Devolver para a Mari", anotada na porta. Venda em potencial (crédito aprovado, etapa qualificada,
  -- pedido ou biometria) fica com o time — o "Parada com dono" do Conferir cobra.
  for c in
    select m.* from public.mari_conversas m
     cross join lateral (select t.papel from public.mari_turnos t
                          where t.conversa_id = m.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1) u
     where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
       and m.venda_id is null and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento'
       and (coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false) or m.chatwoot_agente is not null or m.chatwoot_time is not null)
       and coalesce(m.chatwoot_status, 'open') <> 'snoozed'
       and not coalesce(m.nao_contatar, false)
       and not (coalesce(m.chatwoot_etiquetas, '{}') && array['nao-contatar', 'suporte-nio'])
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and (m.espera_ate is null or m.espera_ate <= now())
       and coalesce(m.funil_etapa, '') not in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')
       and not coalesce(m.credito_resultado ~ '^(aprovado|cartao)', false)
       and u.papel = 'humano'   -- o TIME falou por último (num handoff a última é da Mari e quem espera é o cliente: não volta)
       and coalesce((select max(t.created_at) from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'lead'), m.created_at)
           < now() - interval '24 hours'
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 20
     for update of m skip locked
  loop
    declare v_a text; r jsonb;
    begin
      v_a := public._porta_situacao(c.id, null::uuid);
      r := public._porta_devolver(c, null::public.vendas, jsonb_build_object(
             'por', 'NIOGEN (janela de 24 h fechada)',
             'nota', '↩ NIOGEN · o cliente não responde há mais de 24 h e a janela do WhatsApp fechou: a conversa volta para a Mari e a cadência dela segue. Se ele escrever, a Mari atende. Para seguir com o time, assuma de novo.'));
      perform public._porta_anotar('momento:devolver_mari', 'janela_fechada', c.id, null::uuid, v_a, r);
      n := n + 1;
    end;
  end loop;
  return n;
end;
$function$;

commit;
