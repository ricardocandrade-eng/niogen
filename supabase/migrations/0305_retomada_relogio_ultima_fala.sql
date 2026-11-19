-- NIOGEN | supabase/migrations/0305_retomada_relogio_ultima_fala.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Caso L-181 (conversa 167) e mais 4 da Fila Vero, 18/11 (diagnóstico §32): o lead só tocou em "Quero ver a oferta", nunca escreveu;
-- a Saída "Sem resposta" manual abriu a Retomada e o D3 saiu na hora com "a gente começou a conversar… e parou no meio".
-- Ricardo, 18/11: quem clicou mostrou interesse e DEVE entrar na Retomada, mas (1) na Retomada aberta por Saída manual o D3 sai
-- 3 dias depois da última fala (a última mensagem do cliente ou, se ele nunca escreveu, o último toque nosso), e o D7 e o D15 contam
-- da mesma base; (2) quem nunca escreveu recebe um D3 que fala do clique, nunca "paramos no meio" → "Template novo na Meta".
-- O que muda:
--  (1) mari_conversas.retomada_base: o "dia 0" do relógio. Saída manual (saida_sem_resposta, saida_recusou, backfill): a última fala
--      antes da abertura. Retomada pelo time (time_sem_resposta, já passou 24 h úteis): abertura − 3 dias, ou seja, o D3 na hora, como antes.
--  (2) _retomada_quando(c, passo): D3 = base + 3 dias (nunca antes da abertura) · D7 = base + 7 dias, e pelo menos 4 dias depois do D3 ·
--      D15 = base + 15 dias, e pelo menos 8 dias depois do D7 · fim = D15 + 48 h. _retomada_tick, a Live (data do D7 no "ligue") e
--      a ficha usam a mesma conta.
--  (3) template nio_retomada_clique_d3 (MARKETING, submetido por n8n/waba_template_retomada_clique.py). Vai para quem tem origem
--      fila_vero e nenhuma mensagem do cliente. Enquanto a Meta não aprova, o D3 dessa pessoa não sai (nota no histórico) e a
--      Retomada segue para o D7 na data certa. O D3 de quem conversou continua o mesmo.
--  (4) ficha_venda devolve as colunas da Retomada (o desenho da 0304 não as recebia pela chamada única da 0283).
--  (5) Retomadas abertas: a base é gravada (conta da última fala antes da abertura). As 5 da Fila Vero que já receberam o D3 passam o
--      D7 de 23/11 para 25/11; as que ainda esperam o D3 (Saída manual) passam a esperar 3 dias da última fala.
-- Regra 20: (1) nenhuma tabela nova; (2) não muda destino nem dono; (3) a peça é a mesma (_retomada_tick); (4) a Live só muda a data
-- do texto; (5) cenário X39. Funções recriadas da versão no ar (18/11 ~23h).
begin;

alter table public.mari_conversas add column if not exists retomada_base timestamptz;
comment on column public.mari_conversas.retomada_base is
  '0305: dia 0 do relógio da Retomada (D3 = +3 dias, D7 = +7, D15 = +15). Saída manual: última fala antes da abertura; time_sem_resposta: abertura − 3 dias.';

insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, status, uso) values
  ('nio_retomada_clique_d3', 'MARKETING', 'pt_BR',
   E'Oi, {{1}}! Aqui é a Mari, da Nio 👋\n\nVi que você abriu a oferta da internet fibra da Nio. Ainda quer que eu veja se ela chega no seu endereço? Leva um minutinho 😊',
   '[]'::jsonb, 'PENDING', 'RETOMADA_CLIQUE_D3')
on conflict (nome) do nothing;

-- quem só tocou em "Quero ver a oferta" (Fila Vero) e nunca escreveu
create or replace function public._retomada_so_clicou(c public.mari_conversas) returns boolean
language sql stable set search_path to 'public' as $function$
  select c.origem = 'fila_vero'
     and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead')
$function$;

-- o dia 0 do relógio: a última mensagem do cliente antes de p_ate ou, se ele nunca escreveu, o último toque nosso (Mari ou time)
create or replace function public._retomada_base(c public.mari_conversas, p_origem text, p_ate timestamptz default now()) returns timestamptz
language sql stable set search_path to 'public' as $function$
  select case when p_origem = 'time_sem_resposta' then p_ate - interval '3 days'
    else coalesce(
      (select max(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at <= p_ate),
      (select max(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('mari', 'humano') and t.created_at <= p_ate),
      p_ate - interval '3 days') end
$function$;

-- quando sai o passo (D3, D7, D15, FIM) — a mesma conta no tick, na Live e na ficha
create or replace function public._retomada_quando(c public.mari_conversas, p_passo text) returns timestamptz
language sql stable set search_path to 'public' as $function$
  select case p_passo
    when 'D3'  then greatest(b + interval '3 days', c.retomada_desde)
    when 'D7'  then greatest(b + interval '7 days', coalesce(c.retomada_passo_em, c.retomada_desde) + interval '4 days')
    when 'D15' then greatest(b + interval '15 days', coalesce(c.retomada_passo_em, c.retomada_desde) + interval '8 days')
    else coalesce(c.retomada_passo_em, c.retomada_desde) + interval '48 hours' end
  from (select coalesce(c.retomada_base, c.retomada_desde - interval '3 days') as b) x
$function$;
revoke execute on function public._retomada_base(public.mari_conversas, text, timestamptz) from public, anon, authenticated;
revoke execute on function public._retomada_so_clicou(public.mari_conversas) from public, anon, authenticated;
revoke execute on function public._retomada_quando(public.mari_conversas, text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public._retomada_iniciar(c mari_conversas, p_origem text, p_quem text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g uuid := gen_random_uuid(); dono text := nullif(btrim(coalesce(c.chatwoot_agente, '')), '');
        v_base timestamptz := public._retomada_base(c, p_origem);
begin
  update public.mari_conversas
     set retomada_desde = now(), retomada_origem = p_origem, retomada_passo = null, retomada_passo_em = null,
         retomada_fim_em = null, retomada_fim = null, retomada_dono = dono, retomada_base = v_base
   where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[Retomada: o cliente parou de responder' || case p_origem when 'time_sem_resposta' then ' ao time' else '' end
          || ' — a Mari retoma o contato (D3 → Ligar → D7 → D15)' || coalesce('; dono guardado: ' || dono, '')
          || coalesce('; pedido por ' || p_quem, '') || ']', false);
  if c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
    perform public._bo_enfileirar(g, 1, 'retomada', c.venda_id, c, 'nota', jsonb_build_object('content',
      '↩ Retomada: ' || case p_origem when 'time_sem_resposta' then 'o cliente não responde ao time há 24 h úteis'
                                      when 'saida_recusou' then 'Saída "Recusou"' || coalesce(' · ' || c.saida_sub, ' (sem motivo)')
                                      else 'Saída "Sem resposta"' end
      || ' — a Mari manda o D3 ' || case when p_origem = 'time_sem_resposta' then 'agora (em horário)'
         else 'em ' || to_char(greatest(v_base + interval '3 days', now()) at time zone 'America/Sao_Paulo', 'DD/MM') || ' (3 dias depois da última fala)' end
      || ', o D7 e o D15; no D3 + 1 dia o NIOGEN pede para ligar. '
      || case when dono is not null then 'Se o cliente responder, a conversa volta para ' || dono || '.'
              else 'Se o cliente responder, a Mari atende.' end));
  end if;
  return jsonb_build_object('ok', true, 'origem', p_origem);
end $function$
;

CREATE OR REPLACE FUNCTION public._retomada_tick(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c      public.mari_conversas;
  ult    record;
  n      int := 0;
  v_h    numeric := coalesce(nullif(public._bo_cfg('retomada_time_horas_uteis', '24'::jsonb) #>> '{}', '')::numeric, 24);
  v_max  int := coalesce(nullif(public._bo_cfg('retomada_time_max_dias', '7'::jsonb) #>> '{}', '')::int, 7);
  prox   text; quando timestamptz; motivo text;
  teto   record; tq record;
  v_tpl  public.config_templates_waba;
  v_nome text; params jsonb; pay jsonb; v_clique boolean; v_tnome text;
begin
  -- (a) começa: o time falou por último, lead sem venda, e o cliente não respondeu em N horas úteis. Com ou sem dono: desde a 0227
  -- o lead sem venda volta para a Mari em 24 h (_conversas_volta_mari), mas a conversa fica resolvida e a escada do n8n não toca nela.
  for c in
    select m.* from public.mari_conversas m
     cross join lateral (select t.papel, t.created_at from public.mari_turnos t
                          where t.conversa_id = m.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1) u
     where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
       and m.venda_id is null and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento'
       and m.espera_ate is null and not coalesce(m.nao_contatar, false)
       and m.status in ('ativo', 'handoff_realizado')
       -- só onde a escada do n8n não toca: conversa resolvida/adiada ou com dono/time (aberta e sem dono, a escada normal já segue)
       and (coalesce(m.chatwoot_resolvida, false) or coalesce(m.chatwoot_status, 'open') <> 'open'
            or m.chatwoot_agente is not null or m.chatwoot_time is not null or coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false))
       and (m.retomada_desde is null or (m.retomada_fim_em is not null and m.retomada_desde < coalesce(m.ultima_msg_lead_at, '-infinity'::timestamptz)))
       and u.papel = 'humano' and u.created_at > p_agora - make_interval(days => v_max)
       and public._horas_uteis(u.created_at, p_agora) >= v_h
       and public._retomada_nao_liga(m) is null
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 30
     for update of m skip locked
  loop
    perform public._retomada_iniciar(c, 'time_sem_resposta', null);
    n := n + 1;
  end loop;

  -- (b) anda (0305): o relógio conta da base (_retomada_base): D3 = base + 3 dias → Ligar (D3 + 1 dia, na Live) → D7 = base + 7 dias
  --     (≥ D3 + 4) → D15 = base + 15 dias (≥ D7 + 8) → fim (D15 + 48 h). Retomada pelo time: base = abertura − 3 dias (D3 na hora).
  select * into teto from public.contato_teto();
  for c in
    select m.* from public.mari_conversas m
     where m.retomada_desde is not null and m.retomada_fim_em is null
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     order by coalesce(m.retomada_passo_em, m.retomada_desde)
     limit 200
     for update of m skip locked
  loop
    if c.ultima_msg_lead_at > c.retomada_desde then perform public._retomada_fechar(c, 'respondeu'); continue; end if;
    motivo := public._retomada_nao_liga(c);
    if motivo is not null then perform public._retomada_fechar(c, 'não liga: ' || motivo); continue; end if;
    prox := case coalesce(c.retomada_passo, '') when '' then 'D3' when 'D3' then 'D7' when 'D7' then 'D15' when 'D15' then 'FIM' end;
    if prox is null then continue; end if;
    quando := public._retomada_quando(c, prox);
    if p_agora < quando then continue; end if;
    if prox = 'FIM' then perform public._retomada_fechar(c, 'sem resposta'); n := n + 1; continue; end if;
    -- regras do envio: horário do contrato, nada no dia em que o time falou, teto, template aprovado
    if not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
    if exists (select 1 from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano'
                and (th.created_at at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date) then continue; end if;
    select * into tq from public.mari_toques(c.telefone, p_agora);
    if (teto.dia is not null and tq.hoje >= teto.dia) or (teto.mes is not null and tq.mes >= teto.mes) then continue; end if;
    -- 0305: quem só tocou em "Quero ver a oferta" (Fila Vero) e nunca escreveu recebe o D3 do clique, nunca o "parou no meio"
    v_clique := prox = 'D3' and public._retomada_so_clicou(c);
    v_tnome := case when v_clique then 'nio_retomada_clique_d3' when prox = 'D3' then 'nio_retomada_lead_d3'
                    when prox = 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end;
    v_tpl := null;
    select * into v_tpl from public.config_templates_waba where nome = v_tnome and status = 'APPROVED';
    if v_tpl.nome is null then
      if v_clique then
        -- o template do clique ainda não foi aprovado pela Meta: o D3 não sai e a Retomada segue para o D7 na data certa
        update public.mari_conversas set retomada_passo = 'D3', retomada_passo_em = p_agora where id = c.id;
        insert into public.mari_turnos (conversa_id, papel, texto, pendente)
        values (c.id, 'sistema', '[Retomada: o D3 de quem só clicou na oferta não saiu — o template nio_retomada_clique_d3 ainda não foi aprovado pela Meta; segue o D7]', false);
        n := n + 1;
      end if;
      continue;
    end if;
    v_nome := public.mari_cadencia_nome(c);
    params := case when prox = 'D3' and not v_clique then jsonb_build_array(v_nome, public.mari_cadencia_contexto(c)) else jsonb_build_array(v_nome) end;
    pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, params), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'rotulo', 'Retomada ' || prox, 'texto_chave', 'retomada_' || lower(prox),
      'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body',
          coalesce((select jsonb_object_agg((o)::text, e) from jsonb_array_elements_text(params) with ordinality as t(e, o)), '{}'::jsonb))));
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'retomada', c.venda_id, c, 'mensagem', pay);
    update public.mari_conversas set retomada_passo = prox, retomada_passo_em = p_agora where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           -- 0271 (passo 6, Live): prazo de 24 h úteis a contar da Saída e dono = quem deu a Saída. Vencido = "VENCIDO" no texto (a Live acende).
           case when public._horas_uteis(ev.em, now()) >= 24 then 'VENCIDO · ' else 'prazo: faltam ' || greatest(1, ceil(24 - public._horas_uteis(ev.em, now())))::int || ' h úteis · ' end
             || 'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || coalesce(' · Saída dada por ' || ev.quem, '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select e.criado_em as em, (select split_part(btrim(u.nome), ' ', 1) from public.usuarios u where u.id = e.criado_por) as quem
                            from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status' order by e.criado_em desc limit 1) ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
    union all
    -- (i2) 0196: biometria da Nio fora do ar (suspeita automática pelo GED360 ou marcada pelo time)
    select 'biometria_fora', q.id::text, null::uuid, null::uuid, 'Biometria da Nio', q.inicio, 1,
           format('%s desde %s%s · %s venda(s) esperando a biometria — peça à Nio a dispensa e marque "Nio dispensou" em cada ficha; quando voltar, marque "Voltou" (Operações › Biometria)',
                  case when q.confirmada_em is null then 'Biometria da Nio parece fora do ar (GED360 sem biometria nova há ' || q.horas_sem_envio || ' h no horário comercial · confirme no grupo)'
                       else 'Biometria da Nio FORA DO AR' end,
                  to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                  case when q.origem = 'manual' then ' (marcada por ' || coalesce((select u.nome from public.usuarios u where u.id = q.aberta_por), 'time') || ')' else '' end,
                  (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')))
      from public.biometria_quedas q
     where q.fim is null
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
    union all
    -- (l) 0202: o portal consultou outra rua (ou disse "sem viabilidade" com a fachada viável no DFV) — o time confere a rua
    select 'conferir_rua', c.id::text, c.id, c.venda_id, n.nome, c.rua_conferir_em,
           case when c.rua_conferir_em < now() - interval '4 hours' then 1 else 2 end,
           format('%s — cliente: %s, nº %s · portal: %s%s. Refaça na Cobertura escolhendo a rua do cliente e marque "Conferi"%s',
                  case c.rua_conferir ->> 'motivo' when 'rua_divergente' then 'O portal consultou OUTRA RUA'
                       else 'O portal disse sem viabilidade, mas a fachada está viável no DFV' end,
                  coalesce(nullif(c.rua_conferir ->> 'esperada', ''), c.endereco_cep ->> 'logradouro', '?'), coalesce(c.numero, '?'),
                  coalesce(nullif(split_part(c.rua_conferir ->> 'portal', ',', 1), ''), '?'),
                  coalesce(' · DFV: ' || nullif(c.rua_conferir ->> 'dfv', ''), ''),
                  case when c.rua_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.rua_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274: Saída sai do Conferir
    union all
    -- (n) 0233: unidade a confirmar — o portal tem lista fechada de unidades e a do cliente não bate (ou ele disse "nenhuma
    -- dessas", ou o endereço não tem nenhuma cadastrada). Dono: backoffice. Prazo: 4 h.
    select 'conferir_unidade', c.id::text, c.id, c.venda_id, n.nome, c.unidade_conferir_em,
           case when c.unidade_conferir_em < now() - interval '4 hours' or c.unidade_conferir ->> 'motivo' <> 'escolher' then 1 else 2 end,
           format('%s · %s, nº %s%s',
                  case c.unidade_conferir ->> 'motivo'
                       when 'escolher' then format('Unidade a confirmar — viável no endereço; o cliente disse "%s" e o portal tem: %s. A Mari está perguntando qual é; se ele não escolher, confirme com ele. No pedido, escolha a unidade DELE (nunca outra)',
                                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), 'nada'), coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       when 'nenhuma' then format('Unidade fora do cadastro da Nio — o cliente disse que a unidade dele não é nenhuma de: %s. Peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                                  coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       else format('Endereço sem unidade cadastrada na Nio (complemento "%s") — peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), c.complemento, '?')) end,
                  coalesce(c.endereco_cep ->> 'logradouro', 'CEP ' || c.cep, '?'), coalesce(c.numero, '?'),
                  case when c.unidade_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.unidade_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274
    union all
    -- (o) 0274: Retomada — o D3 saiu há 1 dia e o cliente não respondeu: o time liga (nunca automático). Some quando o D7 sai.
    select 'retomada_ligar', c.id::text, c.id, c.venda_id, n.nome, c.retomada_passo_em + interval '1 day', 2,
           format('Retomada: a Mari mandou o D3 em %s e o cliente não respondeu — ligue para %s. Se não atender, o D7 sai em %s',
                  to_char(c.retomada_passo_em at time zone 'America/Sao_Paulo', 'DD/MM'), c.telefone,
                  to_char(public._retomada_quando(c, 'D7') at time zone 'America/Sao_Paulo', 'DD/MM'))
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.retomada_desde is not null and c.retomada_fim_em is null and c.retomada_passo = 'D3'
       and c.retomada_passo_em < now() - interval '1 day' and not coalesce(c.nao_contatar, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano' and t.created_at > c.retomada_passo_em)
    union all
    -- (m) 0210: o robô do GED360 está barrado (2+ leituras seguidas com erro) — sem ele ninguém fica sabendo da biometria
    select 'ged360_barrado', 'ged360', null::uuid, null::uuid, 'Robô do GED360', g.desde, 1,
           case when g.erro ilike '%simult%'
                then format('O robô do GED360 não lê desde %s: alguém entrou no GED360 com o login do robô ("logins simultâneos"). Saia do GED360 e use "⟳ Consultar no GED360" na ficha — sem o robô, biometria aprovada não avisa ninguém',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'HH24:MI'))
                else format('O robô do GED360 não lê desde %s (%s leituras com erro: %s) — biometria aprovada não avisa ninguém até voltar',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), g.n, left(g.erro, 120)) end
      from (select (select min(l.lida_em) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as desde,
                   (select count(*) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as n,
                   (select l.erro from public.ged360_leituras l order by l.lida_em desc limit 1) as erro,
                   (select l.ok from public.ged360_leituras l order by l.lida_em desc limit 1) as ultima_ok) g
     where g.ultima_ok = false and g.n >= 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ficha_venda(p_venda uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  r  jsonb := '{}'::jsonb;
  bo boolean := coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice');
  x  jsonb;
  conv_cols text[] := array['id', 'lead_numero', 'chatwoot_conversation_id', 'chatwoot_agente', 'chatwoot_time', 'chatwoot_status', 'chatwoot_etiquetas',
    'humano_atribuido', 'nao_contatar', 'ultima_msg_lead_at', 'handoff_briefing', 'handoff_em', 'handoff_motivo', 'cobertura_decisao',
    'nio_viab_resultado', 'nio_viab_velocidade', 'credito_resultado', 'credito_em', 'credito_endereco', 'credito_formas', 'credito_consultas',
    'forma_pagamento', 'nio_pedido_aberto', 'antifraude_situacao', 'antifraude_em', 'antifraude_hist', 'funil_etapa', 'funil_destino',
    'funil_detalhe', 'funil_alerta', 'status', 'origem', 'created_at', 'cadencia_passo', 'cadencia_retorno_em', 'agendamento_retorno',
    'chatwoot_resolvida', 'time_atribuido', 'venda_id', 'bio_lembrete_em', 'instalacao_avisada_para', 'instalacao_avisada_em',
    'retomada_desde', 'retomada_passo', 'retomada_passo_em', 'retomada_fim_em', 'retomada_fim', 'retomada_base'];
  extra_cols text[] := array['lead_numero', 'nio_viab_por', 'ponto_referencia', 'nio_os', 'nio_os_em', 'contato_nome', 'contato_relacao', 'nio_interesse',
    'nio_interesse_em', 'titular_trocado_em', 'docs_dispensados_em', 'biometria_dispensada_em', 'biometria_dispensa_motivo', 'cartao_pago_em',
    'conferencia_obs', 'conferencia_em', 'conferencia_por', 'parceiro_indevida', 'parceiro_indevida_motivo', 'parceiro_indevida_em'];
begin
  begin
    select to_jsonb(t) into x from public.v_vendas t where t.id = p_venda;
    r := r || jsonb_build_object('v', x);
  exception when others then r := r || jsonb_build_object('v', null, 'v_erro', sqlerrm); end;
  if r -> 'v' is null or jsonb_typeof(r -> 'v') = 'null' then return r; end if;

  begin
    select coalesce(jsonb_agg(to_jsonb(e) order by e.criado_em), '[]'::jsonb) into x from public.eventos_venda e where e.venda_id = p_venda;
    r := r || jsonb_build_object('eventos', x);
  exception when others then r := r || jsonb_build_object('eventos', null); end;

  begin
    select to_jsonb(t) into x from public.v_contatos_limite t where t.venda_id = p_venda limit 1;
    r := r || jsonb_build_object('lim', x);
  exception when others then r := r || jsonb_build_object('lim', null); end;

  begin
    select coalesce(jsonb_agg(jsonb_build_object('qtd', a.qtd, 'comissao_prevista', a.comissao_prevista,
             'config_adicionais', (select jsonb_build_object('nome', ca.nome, 'preco', ca.preco) from public.config_adicionais ca where ca.id = a.adicional_id))
             order by a.id), '[]'::jsonb)
      into x from public.venda_adicionais a where a.venda_id = p_venda;
    r := r || jsonb_build_object('adics', x);
  exception when others then r := r || jsonb_build_object('adics', null); end;

  if bo then
    begin
      select coalesce(jsonb_agg(y), '[]'::jsonb) into x from (
        select (select jsonb_object_agg(k, val) from jsonb_each(to_jsonb(m)) j(k, val) where k = any(conv_cols)) y
          from public.mari_conversas m where m.venda_id = p_venda order by m.created_at desc limit 1) s;
      r := r || jsonb_build_object('conv', x);
    exception when others then r := r || jsonb_build_object('conv', null); end;
  else
    r := r || jsonb_build_object('conv', '[]'::jsonb);
  end if;

  begin
    select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'canal', k.canal, 'direcao', k.direcao, 'por', k.por, 'em', k.em,
             'resumo', k.resumo, 'toque', k.toque) order by k.em desc), '[]'::jsonb)
      into x from (select * from public.contatos_cliente c where c.venda_id = p_venda order by c.em desc limit 30) k;
    r := r || jsonb_build_object('contatos', x);
  exception when others then r := r || jsonb_build_object('contatos', null); end;

  begin
    select (select jsonb_object_agg(k, val) from jsonb_each(to_jsonb(t)) j(k, val) where k = any(extra_cols)) into x
      from public.vendas t where t.id = p_venda;
    r := r || jsonb_build_object('extra', x);
  exception when others then r := r || jsonb_build_object('extra', null); end;

  begin
    select coalesce(jsonb_agg(to_jsonb(p) order by p.aberta_em desc), '[]'::jsonb) into x from public.venda_pendencias p where p.venda_id = p_venda;
    r := r || jsonb_build_object('pend', x);
  exception when others then r := r || jsonb_build_object('pend', null); end;

  begin
    r := r || jsonb_build_object('avisos', public.ficha_avisos(p_venda => p_venda));
  exception when others then r := r || jsonb_build_object('avisos', null, 'avisos_erro', true); end;

  if bo then
    begin
      select to_jsonb(t) into x from public.v_venda_andamento t where t.venda_id = p_venda limit 1;
      r := r || jsonb_build_object('andamento', x);
    exception when others then r := r || jsonb_build_object('andamento', null); end;
    begin
      select to_jsonb(t) into x from public.v_venda_meta t where t.venda_id = p_venda limit 1;
      r := r || jsonb_build_object('meta', x);
    exception when others then r := r || jsonb_build_object('meta', null); end;
  end if;

  begin
    select to_jsonb(t) into x from public.v_leads t where t.venda_id = p_venda limit 1;
    r := r || jsonb_build_object('lead', x);
  exception when others then r := r || jsonb_build_object('lead', null); end;

  begin
    select to_jsonb(t) into x from public.v_dinheiro t where t.venda_id = p_venda limit 1;
    r := r || jsonb_build_object('din', x);
  exception when others then r := r || jsonb_build_object('din', null); end;

  -- 0296 (ponderação 5): o post-it do lead (da venda ou da conversa dela)
  begin
    select jsonb_build_object('texto', n.texto, 'em', n.atualizado_em, 'por', u.nome) into x
      from public.lead_nota n left join public.usuarios u on u.id = n.atualizado_por
     where n.venda_id = p_venda
        or n.conversa_id = (select m.id from public.mari_conversas m where m.venda_id = p_venda order by m.created_at desc limit 1)
     order by n.atualizado_em desc limit 1;
    r := r || jsonb_build_object('nota', x);
  exception when others then r := r || jsonb_build_object('nota', null); end;

  return r;
end $function$;

-- (5) Retomadas abertas: grava a base pela última fala antes da abertura
update public.mari_conversas m
   set retomada_base = public._retomada_base(m, m.retomada_origem, m.retomada_desde)
 where m.retomada_desde is not null and m.retomada_fim_em is null and m.retomada_base is null;

commit;
