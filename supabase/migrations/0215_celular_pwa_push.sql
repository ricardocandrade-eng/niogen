-- NIOGEN | supabase/migrations/0215_celular_pwa_push.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (15/11, protótipo docs/LAYOUT_conversas_mobile_151126_1304.html): NIOGEN no celular — PWA, Conversas no
-- padrão WhatsApp, Pulso como aba e Web Push só dos gatilhos do Live.
-- Esta migration:
--   1. v_conversas ganha no fim: nao_lidas (falas do cliente depois da última resposta), plano, comissao e valor_mes
--      (a lista do celular mostra badge e quanto vale sem chamada extra — regra 19).
--   2. push_subscriptions (um aparelho por linha) + push_envios (cada aviso; o único (aparelho, gatilho, cliente, dia) é a
--      trava de "no máximo um por gatilho por cliente por dia") + app_sessoes (sessões do app instalado, para a medida).
--   3. RPCs da tela: push_inscrever · push_remover · push_testar · app_sessao_registrar.
--   4. RPCs do n8n (service role): push_pendentes(p_vapid_publica) e push_resultado(p_itens) — fluxo push_live, a cada 2 min.
--   5. push_medida(p_dias): a medida de 7 dias pedida (toque em ≤ 1 h, tempo até o 1º toque, docs vencidos, sessões do app).
--   6. pulso_batimentos: push_live entra no Pulso › Fluxos.
-- Regra 20: nenhum estado de lead novo. Aviso não muda etapa, status, destino, vez nem prazo (1 e 3 intactas); os gatilhos são
-- os do Live (fonte única: v_oportunidades, vendas, mari_alarmes — 4); cada envio fica em push_envios com status e HTTP, e o
-- fluxo aparece no Pulso (5: a conferência é o batimento do push_live + push_medida; não entra em conferencia_itens porque
-- não cria pendência de cliente). Regra 15: tabelas novas com parceiro_id. Chave VAPID privada só no .env da VPS (regra 5).
begin;

-- ───────────────────────── 1. v_conversas: não lidas, plano e quanto vale (colunas novas no fim) ─────────────────────────
create or replace view public.v_conversas with (security_invoker = true) as
SELECT c.id,
    c.venda_id,
    COALESCE(NULLIF(btrim(c.dados ->> 'nome'::text), ''::text), NULLIF(btrim(c.nome_contato), ''::text), 'Contato'::text) AS nome,
    c.telefone,
    c.cidade,
    c.origem,
    c.chatwoot_conversation_id,
    c.chatwoot_status,
    COALESCE(c.chatwoot_etiquetas, '{}'::text[]) AS etiquetas,
        CASE
            WHEN COALESCE(c.nao_contatar, false) THEN NULL::text
            WHEN c.chatwoot_agente IS NOT NULL THEN 'pessoa'::text
            WHEN COALESCE(c.humano_atribuido, false) THEN 'pessoa'::text
            WHEN c.chatwoot_status = 'resolved'::text THEN NULL::text
            WHEN c.chatwoot_time IS NOT NULL THEN 'time'::text
            ELSE 'mari'::text
        END AS dono_tipo,
        CASE
            WHEN COALESCE(c.nao_contatar, false) THEN NULL::text
            WHEN c.chatwoot_agente IS NOT NULL THEN c.chatwoot_agente
            WHEN COALESCE(c.humano_atribuido, false) THEN 'time (assumida)'::text
            WHEN c.chatwoot_status = 'resolved'::text THEN NULL::text
            WHEN c.chatwoot_time IS NOT NULL THEN 'time '::text || c.chatwoot_time
            ELSE 'Mari'::text
        END AS dono_nome,
    COALESCE(u.created_at, c.created_at) AS ultima_em,
    u.papel AS ultima_quem,
    "left"(regexp_replace(COALESCE(u.texto, ''::text), '\s+'::text, ' '::text, 'g'::text), 160) AS ultima_txt,
    l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone) AND l.ult_lead > (now() - '7 days'::interval) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) AND NOT (c.espera_ate IS NOT NULL AND l.ult_lead <= c.espera_em) AND cliente_confirmou_desde(c.id, l.ult_resp) IS NULL AS cliente_esperando,
        CASE
            WHEN l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone) AND (COALESCE(c.chatwoot_status, 'open'::text) <> ALL (ARRAY['resolved'::text, 'snoozed'::text])) AND cliente_confirmou_desde(c.id, l.ult_resp) IS NULL THEN floor(EXTRACT(epoch FROM now() - l.ult_lead) / 60::numeric)::integer
            ELSE NULL::integer
        END AS esperando_min,
    l.ult_lead,
    l.ult_lead IS NOT NULL AND l.ult_lead > (now() - '23:00:00'::interval) AS janela_aberta,
        CASE
            WHEN v.id IS NOT NULL THEN jornada_etapa(v.status, v.nio_pedido, v.credito_resultado)
            ELSE 1
        END AS etapa,
    COALESCE(c.nao_contatar, false) OR (c.status = ANY (ARRAY['encerrado_humano'::text, 'encerrado_ia'::text])) OR COALESCE(v.status, ''::text) = 'saida'::text OR COALESCE(c.quadro_encerrada_motivo, ''::text) = 'suporte_nio'::text AS encerrada,
    c.created_at,
    'dharma'::text AS parceiro_id,
    c.funil_etapa,
    c.funil_destino,
    c.funil_detalhe,
    c.funil_destino_em,
    c.funil_alerta,
    c.funil_alerta_em,
    -- 0214 (celular): não lidas = falas do cliente depois da última resposta (Mari ou time); plano e quanto vale.
    CASE WHEN l.ult_lead IS NOT NULL AND l.ult_lead > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone)
         THEN (SELECT count(*)::integer FROM mari_turnos t3 WHERE t3.conversa_id = c.id AND t3.papel = 'lead'::text
                 AND t3.created_at > COALESCE(l.ult_resp, '-infinity'::timestamp with time zone))
         ELSE 0 END AS nao_lidas,
    COALESCE(pv.nome_curto, pv.nome, pe.plano) AS plano,
    v.comissao_prevista AS comissao,
    COALESCE(v.valor_mensal, pe.valor) AS valor_mes
   FROM mari_conversas c
     LEFT JOIN vendas v ON v.id = c.venda_id
     LEFT JOIN config_planos pv ON pv.id = v.plano_id
     LEFT JOIN LATERAL _oport_plano(c.plano_escolhido, c.forma_pagamento, c.cluster, c.segmento) pe(plano, valor) ON v.id IS NULL AND c.plano_escolhido IS NOT NULL
     CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE t.papel = 'lead'::text) AS ult_lead,
            GREATEST(max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])), c.dispensada_em) AS ult_resp
           FROM mari_turnos t
          WHERE t.conversa_id = c.id) l
     LEFT JOIN LATERAL ( SELECT t.papel,
            t.texto,
            t.created_at
           FROM mari_turnos t
          WHERE t.conversa_id = c.id AND (t.papel = ANY (ARRAY['lead'::text, 'mari'::text, 'humano'::text]))
          ORDER BY t.created_at DESC
         LIMIT 1) u ON true
  WHERE c.canal = 'whatsapp'::text AND COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text;

-- ───────────────────────── 2. Web Push: aparelhos inscritos ─────────────────────────
-- Uma linha por aparelho (endpoint do navegador). As chaves do aparelho (p256dh, auth) não são segredo do servidor: servem para
-- cifrar a notificação PARA aquele aparelho. A chave VAPID privada fica só em /opt/niogen/push/.env (VPS do n8n).
create table if not exists public.push_subscriptions (
  id               uuid primary key default gen_random_uuid(),
  parceiro_id      text not null default 'dharma',
  perfil           uuid not null references public.usuarios (id) on delete cascade,
  endpoint         text not null unique,
  keys             jsonb not null,
  user_agent       text,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now(),
  ativo            boolean not null default true,
  desligado_em     timestamptz,
  desligado_motivo text,
  ultimo_envio_em  timestamptz,
  falhas           integer not null default 0
);
create index if not exists push_subscriptions_perfil_idx on public.push_subscriptions (perfil) where ativo;
alter table public.push_subscriptions enable row level security;
drop policy if exists push_subscriptions_ler_meus on public.push_subscriptions;
create policy push_subscriptions_ler_meus on public.push_subscriptions for select to authenticated
  using (perfil = (select auth.uid()) or (select public.meu_perfil()) = 'admin');
revoke insert, update, delete on public.push_subscriptions from anon, authenticated;

-- Cada notificação que saiu (ou tentou sair). O único (aparelho, gatilho, chave, dia) é a trava de "no máximo uma por gatilho
-- por cliente por dia". chave = id da conversa (ou da venda); dia = data de São Paulo.
create table if not exists public.push_envios (
  id              uuid primary key default gen_random_uuid(),
  parceiro_id     text not null default 'dharma',
  subscription_id uuid not null references public.push_subscriptions (id) on delete cascade,
  perfil          uuid not null,
  gatilho         text not null check (gatilho in ('janela_24h', 'objecao', 'docs_vencendo', 'fatura_d5', 'm10_risco', 'mari_parada', 'teste')),
  chave           text not null,
  conversa_id     uuid,
  venda_id        uuid,
  dia             date not null default (now() at time zone 'America/Sao_Paulo')::date,
  titulo          text not null,
  corpo           text not null,
  url             text not null,
  criado_em       timestamptz not null default now(),
  status          text not null default 'pendente' check (status in ('pendente', 'enviado', 'erro', 'expirado')),
  http_status     integer,
  erro            text,
  enviado_em      timestamptz,
  aberto_em       timestamptz,
  unique (subscription_id, gatilho, chave, dia)
);
create index if not exists push_envios_criado_idx on public.push_envios (criado_em);
create index if not exists push_envios_conversa_idx on public.push_envios (conversa_id, criado_em);
alter table public.push_envios enable row level security;
drop policy if exists push_envios_ler on public.push_envios;
create policy push_envios_ler on public.push_envios for select to authenticated
  using (perfil = (select auth.uid()) or (select public.meu_perfil()) = 'admin');
revoke insert, update, delete on public.push_envios from anon, authenticated;

-- Sessões abertas pelo app instalado (medida do resultado, item 6). Uma por aba aberta em modo app.
create table if not exists public.app_sessoes (
  id          bigint generated always as identity primary key,
  parceiro_id text not null default 'dharma',
  perfil      uuid not null references public.usuarios (id) on delete cascade,
  modo        text not null check (modo in ('standalone', 'navegador')),
  tela        text,
  origem      text,      -- 'push' quando a sessão nasceu do clique numa notificação
  criado_em   timestamptz not null default now()
);
create index if not exists app_sessoes_criado_idx on public.app_sessoes (criado_em);
alter table public.app_sessoes enable row level security;
drop policy if exists app_sessoes_ler on public.app_sessoes;
create policy app_sessoes_ler on public.app_sessoes for select to authenticated using ((select public.meu_perfil()) = 'admin');
revoke insert, update, delete on public.app_sessoes from anon, authenticated;

-- Liga/desliga geral e a chave PÚBLICA do VAPID (o navegador precisa dela para se inscrever; a privada nunca sai da VPS).
-- A pública é gravada pelo próprio fluxo push_live a cada rodada (push_pendentes(p_vapid_publica)), lida no niogen-push.
insert into public.config_regras (chave, valor, descricao, parceiro_id)
values ('push', '{"ligado": true, "vapid_publica": null, "max_por_rodada": 40}'::jsonb,
        'Web Push do NIOGEN (0214): ligado, chave pública VAPID (gravada pelo fluxo push_live) e teto por rodada. A chave privada fica só no .env da VPS.', 'dharma')
on conflict (chave) do nothing;

-- ───────────────────────── 3. RPCs do aparelho (tela) ─────────────────────────
create or replace function public.push_inscrever(p_endpoint text, p_keys jsonb, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice recebem os avisos do Live.' using errcode = '42501';
  end if;
  if coalesce(btrim(p_endpoint), '') !~ '^https://' or p_keys ->> 'p256dh' is null or p_keys ->> 'auth' is null then
    raise exception 'Inscrição inválida (endpoint ou chaves do aparelho).' using errcode = '22023';
  end if;
  insert into public.push_subscriptions (perfil, endpoint, keys, user_agent)
  values (auth.uid(), btrim(p_endpoint), jsonb_build_object('p256dh', p_keys ->> 'p256dh', 'auth', p_keys ->> 'auth'), left(p_user_agent, 300))
  on conflict (endpoint) do update
     set perfil = excluded.perfil, keys = excluded.keys, user_agent = excluded.user_agent, atualizado_em = now(),
         ativo = true, desligado_em = null, desligado_motivo = null, falhas = 0
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'resumo', 'Avisos do Live ligados neste aparelho');
end $$;
revoke all on function public.push_inscrever(text, jsonb, text) from public, anon;
grant execute on function public.push_inscrever(text, jsonb, text) to authenticated;

create or replace function public.push_remover(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'Faça login.' using errcode = '42501'; end if;
  update public.push_subscriptions
     set ativo = false, desligado_em = now(), desligado_motivo = 'desligado pelo usuário', atualizado_em = now()
   where endpoint = btrim(p_endpoint) and (perfil = auth.uid() or public.meu_perfil() = 'admin') and ativo;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'removidas', n, 'resumo', 'Avisos desligados neste aparelho');
end $$;
revoke all on function public.push_remover(text) from public, anon;
grant execute on function public.push_remover(text) to authenticated;

-- Abriu o app instalado (uma vez por aba). origem 'push' = veio do clique numa notificação (marca o envio como aberto).
create or replace function public.app_sessao_registrar(p_modo text, p_tela text default null, p_origem text default null, p_envio uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_modo not in ('standalone', 'navegador') then return; end if;
  insert into public.app_sessoes (perfil, modo, tela, origem) values (auth.uid(), p_modo, left(p_tela, 60), left(p_origem, 20));
  if p_envio is not null then
    update public.push_envios set aberto_em = coalesce(aberto_em, now()) where id = p_envio and perfil = auth.uid();
  end if;
end $$;
revoke all on function public.app_sessao_registrar(text, text, text, uuid) from public, anon;
grant execute on function public.app_sessao_registrar(text, text, text, uuid) to authenticated;

-- Notificação de teste para o próprio aparelho (botão "Testar" em Mais › Avisos). Sai na próxima rodada do push_live (≤ 2 min).
create or replace function public.push_testar()
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  insert into public.push_envios (subscription_id, perfil, gatilho, chave, titulo, corpo, url)
  select s.id, s.perfil, 'teste', 'teste-' || to_char(now(), 'HH24MI'), 'NIOGEN · teste', 'Os avisos do Live chegam neste aparelho.', 'fila.html'
    from public.push_subscriptions s where s.perfil = auth.uid() and s.ativo
  on conflict do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0, 'aparelhos', n,
    'resumo', case when n > 0 then 'Teste na fila: chega em até 2 min' else 'Nenhum aparelho seu com avisos ligados' end);
end $$;
revoke all on function public.push_testar() from public, anon;
grant execute on function public.push_testar() to authenticated;

-- ───────────────────────── 4. O que notificar (só o n8n, service role) ─────────────────────────
-- Só os gatilhos do Live (nunca mensagem comum de cliente):
--   janela_24h  = oportunidade O1 (janela de 24 h fechando)          objecao  = oportunidade O3 (objeção parada)
--   docs_vencendo = venda instalada sem documentos, prazo em ≤ 3 dias ou vencido (só com config_regras.docs_exigidos = true)
--   fatura_d5   = oportunidades O8/O9 (hoje DESLIGADAS em config_oportunidades — passam a avisar quando forem ligadas)
--   m10_risco   = ainda sem fonte (a importação de faturas não existe); o gatilho está reservado no check
--   mari_parada = mari_alarmes aberto e já avisado (o mesmo episódio do mari_alarme_silencio) — só para admin
-- Alerta interno vale a qualquer hora (a janela seg–sex 9–21 / sáb 10–16 é para toque em cliente). Teto: max_por_rodada.
-- Grava a linha em push_envios (o único é a trava) e devolve o que mandar, com as chaves do aparelho.
create or replace function public.push_pendentes(p_vapid_publica text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg   jsonb := coalesce((select valor from public.config_regras where chave = 'push'), '{}'::jsonb);
  v_max   int := coalesce((v_cfg ->> 'max_por_rodada')::int, 40);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  v_docs_on boolean := coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'docs_exigidos'), true);
  v_saida jsonb;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Só o n8n (service role).' using errcode = '42501'; end if;
  if nullif(btrim(p_vapid_publica), '') is not null and v_cfg ->> 'vapid_publica' is distinct from btrim(p_vapid_publica) then
    update public.config_regras set valor = jsonb_set(valor, '{vapid_publica}', to_jsonb(btrim(p_vapid_publica))), atualizado_em = now()
     where chave = 'push';
  end if;
  if not coalesce((v_cfg ->> 'ligado')::boolean, true) then return '[]'::jsonb; end if;

  with ev as (
    select 'janela_24h'::text as gatilho, o.conversa_id::text as chave, o.conversa_id, null::uuid as venda_id,
           '⏱ Janela de 24 h fechando' || coalesce(' · R$ ' || to_char(o.valor_mes, 'FM999G990'), '') as titulo,
           coalesce(nullif(split_part(btrim(o.nome), ' ', 1), ''), 'Cliente') || coalesce(' · ' || o.cidade, '') || ' — ' || o.motivo as corpo,
           'fila.html?de=push#conversa=' || o.conversa_id as url, false as so_admin
      from public.v_oportunidades o where 'O1' = any (o.regras)
    union all
    select 'objecao', o.conversa_id::text, o.conversa_id, null,
           '🔥 Objeção parada' || coalesce(' · R$ ' || to_char(o.valor_mes, 'FM999G990'), ''),
           coalesce(nullif(split_part(btrim(o.nome), ' ', 1), ''), 'Cliente') || coalesce(' · ' || o.cidade, '') || ' — ' || o.motivo,
           'fila.html?de=push#conversa=' || o.conversa_id, false
      from public.v_oportunidades o where 'O3' = any (o.regras)
    union all
    select 'fatura_d5', o.conversa_id::text, o.conversa_id, null, '💰 Fatura em aberto',
           coalesce(nullif(split_part(btrim(o.nome), ' ', 1), ''), 'Cliente') || ' — ' || o.motivo,
           'fila.html?de=push#conversa=' || o.conversa_id, false
      from public.v_oportunidades o where o.regras && array['O8', 'O9']
    union all
    select 'docs_vencendo', v.id::text, null, v.id, '📄 Documentos vencendo',
           coalesce(nullif(split_part(btrim(v.cliente_nome), ' ', 1), ''), 'Cliente') || coalesce(' · ' || v.cidade, '') || ' — '
             || case when v.instalado_em + make_interval(days => v_docs) < now() then 'prazo dos documentos à Nio venceu em '
                     else 'documentos à Nio até ' end
             || to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'),
           'fila.html?de=push#venda=' || v.id, false
      from public.vendas v
     where v_docs_on and v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null
       and v.docs_entregues_em is null and v.docs_dispensados_em is null
       and v.instalado_em > now() - interval '90 days'
       and v.instalado_em + make_interval(days => v_docs) <= now() + interval '3 days'
    union all
    select 'mari_parada', a.conversa_id::text, a.conversa_id, null, '🔴 Mari parada',
           coalesce(nullif(split_part(btrim(s.nome), ' ', 1), ''), 'Cliente') || ' esperando resposta há '
             || floor(extract(epoch from (now() - a.episodio_inicio)) / 60)::int || ' min — ninguém respondeu',
           'conversas.html?de=push#c=' || a.conversa_id, true
      from public.mari_alarmes a join public.v_mari_sem_resposta s on s.id = a.conversa_id
     where a.resolvido_em is null and a.avisado_em is not null
  ), alvo as (
    select s.id as sub_id, s.perfil, s.endpoint, s.keys, u.perfil as tipo
      from public.push_subscriptions s join public.usuarios u on u.id = s.perfil
     where s.ativo and u.ativo and u.perfil in ('admin', 'backoffice')
  ), novos as (
    insert into public.push_envios (subscription_id, perfil, gatilho, chave, conversa_id, venda_id, titulo, corpo, url)
    select a.sub_id, a.perfil, e.gatilho, e.chave, e.conversa_id, e.venda_id, left(e.titulo, 80), left(e.corpo, 180), e.url
      from ev e join alvo a on (not e.so_admin or a.tipo = 'admin')
     order by case e.gatilho when 'mari_parada' then 0 when 'janela_24h' then 1 when 'docs_vencendo' then 2 else 3 end
     limit v_max
    on conflict (subscription_id, gatilho, chave, dia) do nothing
    returning id, subscription_id, gatilho, chave, titulo, corpo, url
  ), testes as (
    select p.id, p.subscription_id, p.gatilho, p.chave, p.titulo, p.corpo, p.url
      from public.push_envios p where p.gatilho = 'teste' and p.status = 'pendente' and p.criado_em > now() - interval '30 minutes'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id, 'endpoint', s.endpoint, 'keys', s.keys,
           'payload', jsonb_build_object('titulo', n.titulo, 'corpo', n.corpo,
                                         'url', n.url,
                                         'envio', n.id, 'tag', n.gatilho || ':' || n.chave, 'gatilho', n.gatilho))), '[]'::jsonb)
    into v_saida
    from (select * from novos union all select * from testes) n join public.push_subscriptions s on s.id = n.subscription_id;
  return v_saida;
end $$;
revoke all on function public.push_pendentes(text) from public, anon, authenticated;
grant execute on function public.push_pendentes(text) to service_role;

-- Resultado de cada envio (lote). 404/410 = o aparelho saiu (desinstalou, trocou de navegador): a inscrição desliga sozinha.
create or replace function public.push_resultado(p_itens jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; v_st int; n int := 0;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Só o n8n (service role).' using errcode = '42501'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) loop
    v_st := nullif(it ->> 'status', '')::int;
    update public.push_envios
       set status = case when v_st between 200 and 299 then 'enviado' when v_st in (404, 410) then 'expirado' else 'erro' end,
           http_status = v_st, erro = left(it ->> 'erro', 300), enviado_em = now()
     where id = (it ->> 'id')::uuid;
    update public.push_subscriptions s
       set ultimo_envio_em = case when v_st between 200 and 299 then now() else s.ultimo_envio_em end,
           falhas = case when v_st between 200 and 299 then 0 else s.falhas + 1 end,
           ativo = case when v_st in (404, 410) or s.falhas >= 9 then false else s.ativo end,
           desligado_em = case when (v_st in (404, 410) or s.falhas >= 9) and s.ativo then now() else s.desligado_em end,
           desligado_motivo = case when v_st in (404, 410) then 'aparelho saiu (HTTP ' || v_st || ')'
                                   when s.falhas >= 9 and s.ativo then '10 falhas seguidas' else s.desligado_motivo end
     where s.id = (select subscription_id from public.push_envios where id = (it ->> 'id')::uuid);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'gravados', n);
end $$;
revoke all on function public.push_resultado(jsonb) from public, anon, authenticated;
grant execute on function public.push_resultado(jsonb) to service_role;

-- ───────────────────────── 5. Medida em 7 dias (item 6 do pedido) ─────────────────────────
-- % dos avisos de cliente tocados por humano em ≤ 1 h · tempo médio até o 1º toque humano · documentos que venceram no período
-- · faturas vencidas (sem fonte ainda) · sessões do app instalado. Toque humano = fala do time (mari_turnos papel humano) ou
-- oportunidade enviada (oportunidades_log tipo enviada) na conversa, depois do 1º aviso do dia.
create or replace function public.push_medida(p_dias int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_docs int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' and auth.role() is distinct from 'service_role' then
    raise exception 'Só admin.' using errcode = '42501';
  end if;
  with ev as (
    select e.gatilho, e.chave, e.dia, min(e.criado_em) as em, min(e.conversa_id::text)::uuid as conversa_id
      from public.push_envios e
     where e.criado_em > now() - make_interval(days => p_dias) and e.status = 'enviado' and e.gatilho not in ('teste', 'mari_parada')
     group by 1, 2, 3
  ), toque as (
    select ev.*, (select min(x) from (
             select min(t.created_at) as x from public.mari_turnos t where t.conversa_id = ev.conversa_id and t.papel = 'humano' and t.created_at >= ev.em
             union all
             select min(l.criado_em) from public.oportunidades_log l where l.conversa_id = ev.conversa_id and l.tipo = 'enviada' and l.criado_em >= ev.em) z) as tocou_em
      from ev
  )
  select jsonb_build_object(
    'dias', p_dias,
    'avisos_cliente', (select count(*) from toque),
    'tocados_1h', (select count(*) from toque where tocou_em <= em + interval '1 hour'),
    'pct_tocados_1h', (select round(100.0 * count(*) filter (where tocou_em <= em + interval '1 hour') / nullif(count(*), 0), 1) from toque),
    'min_medio_1o_toque', (select round(avg(extract(epoch from (tocou_em - em)) / 60)::numeric, 1) from toque where tocou_em is not null),
    'docs_vencidos', (select count(*) from public.vendas vd
                       where vd.instalado_em is not null and vd.docs_dispensados_em is null
                         and vd.instalado_em + make_interval(days => v_docs) between now() - make_interval(days => p_dias) and now()
                         and (vd.docs_entregues_em is null or vd.docs_entregues_em > vd.instalado_em + make_interval(days => v_docs))),
    'faturas_vencidas', null,
    'faturas_obs', 'sem fonte: a importação das faturas da Nio ainda não existe',
    'sessoes_app', (select count(*) from public.app_sessoes s where s.modo = 'standalone' and s.criado_em > now() - make_interval(days => p_dias)),
    'sessoes_por_push', (select count(*) from public.app_sessoes s where s.origem = 'push' and s.criado_em > now() - make_interval(days => p_dias)),
    'aparelhos_ativos', (select count(*) from public.push_subscriptions where ativo),
    'envios_erro', (select count(*) from public.push_envios where status = 'erro' and criado_em > now() - make_interval(days => p_dias))
  ) into v;
  return v;
end $$;
revoke all on function public.push_medida(int) from public, anon;
grant execute on function public.push_medida(int) to authenticated, service_role;

-- ───────────────────────── 6. Pulso › Fluxos: o fluxo novo entra no batimento ─────────────────────────
-- workflow_id é preenchido pelo deploy (n8n/deploy_push.py criar). Sem ele o Pulso mostra "ainda sem batimento".
insert into public.pulso_batimentos (parceiro_id, fluxo, workflow_id, descricao, roda, critico, intervalo_esperado_min, salva_ok, ativo)
select 'dharma', 'push_live', null, 'Avisos do Live no celular (Web Push)', 'a cada 2 min', false, 2, false, true
 where not exists (select 1 from public.pulso_batimentos where fluxo = 'push_live');

commit;
