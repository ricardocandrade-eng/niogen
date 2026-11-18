-- NIOGEN | supabase/migrations/0296_numero_lead_postit_aviso_c4.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "Pode ir para o passo 6" (fase 2 do diagnóstico de fechamento, §6 passo 6 — o que não toca estado). Três peças:
--  (1) Ponderação 7 — NÚMERO DO LEAD curto e sequencial (L-142): mari_conversas.lead_numero e vendas.lead_numero, da mesma sequência
--      (lead_numero_seq); os de hoje numerados pela data de criação. A ficha mostra o da conversa (ou o da venda sem conversa) ao lado
--      do nome, junto com o nº da conversa do Chatwoot (ponderação 6), e a busca aceita "L-142". Não é estado.
--  (2) Ponderação 5 — POST-IT: lead_nota (um texto livre por lead; fica na conversa quando há, senão na venda), gravado só pela
--      lead_nota_gravar (admin/backoffice, com quem e quando). Não mexe em situação, vez, Chatwoot nem cadência. A ficha_venda
--      devolve o número e o post-it (sem chamada nova na ficha da venda).
--  (3) C4 (decisão de 17/11) — AVISO NO CELULAR: handoff para o time (pediu uma pessoa / objeção / urgência) sem ninguém responder em
--      2 h úteis vira push para o admin (push_pendentes, gatilho handoff_sem_resposta; 1 por dia por conversa; config
--      handoff_aviso_celular_horas_uteis). Em 24 h úteis a Mari volta sozinha (0266), como antes.
-- Recriadas da versão no ar: ficha_venda (md5 96326ee8…) e push_pendentes (md5 f65de294…) = produção.
-- Regra 20: nada de estado novo nem fonte nova (número, nota e aviso são leitura/anotação); número com índice; nota só pela função;
-- aviso medido no push_envios. Cenário X31. Tela: ficha (cabeçalho e post-it) e busca por L-n; Live sem mudança.
-- Desempenho: ficha da venda sem chamada nova; ficha só da conversa: +1 leitura em paralelo.
begin;

-- ───────────────────────── 1. número do lead ─────────────────────────
create sequence if not exists public.lead_numero_seq;
alter table public.mari_conversas add column if not exists lead_numero bigint;
alter table public.vendas         add column if not exists lead_numero bigint;

-- os de hoje, pela ordem de chegada (conversas e vendas sem conversa juntas), sem disparar os gatilhos de estado
alter table public.mari_conversas disable trigger user;
alter table public.vendas disable trigger user;
create temporary table _ordem on commit drop as
  select id, row_number() over (order by created_at, id) as n from (
    select m.id, m.created_at from public.mari_conversas m
    union all
    select v.id, v.criado_em as created_at from public.vendas v where not exists (select 1 from public.mari_conversas m2 where m2.venda_id = v.id)) a;
update public.mari_conversas m set lead_numero = o.n from _ordem o where o.id = m.id and m.lead_numero is null;
update public.vendas v set lead_numero = o.n from _ordem o where o.id = v.id and v.lead_numero is null;
-- venda com conversa: o mesmo número da conversa (a mais nova, se houver mais de uma)
update public.vendas v set lead_numero = (select m.lead_numero from public.mari_conversas m where m.venda_id = v.id order by m.created_at desc limit 1)
 where v.lead_numero is null;
alter table public.mari_conversas enable trigger user;
alter table public.vendas enable trigger user;

select setval('public.lead_numero_seq', greatest(
  coalesce((select max(lead_numero) from public.mari_conversas), 0), coalesce((select max(lead_numero) from public.vendas), 0), 1));
alter table public.mari_conversas alter column lead_numero set default nextval('public.lead_numero_seq');
alter table public.vendas         alter column lead_numero set default nextval('public.lead_numero_seq');
create unique index if not exists mari_conversas_numero on public.mari_conversas (lead_numero);
create index if not exists vendas_numero on public.vendas (lead_numero);
comment on column public.mari_conversas.lead_numero is '0296: nº do lead (L-n), sequencial; a venda da conversa mostra o da conversa.';
comment on column public.vendas.lead_numero is '0296: nº na sequência dos leads; vale como L-n quando a venda não tem conversa.';

-- ───────────────────────── 2. post-it ─────────────────────────
create table if not exists public.lead_nota (
  id             bigserial primary key,
  parceiro_id    text not null default 'dharma',
  conversa_id    uuid unique,
  venda_id       uuid unique,
  texto          text not null default '',
  atualizado_por uuid,
  atualizado_em  timestamptz not null default now(),
  check (conversa_id is not null or venda_id is not null)
);
alter table public.lead_nota enable row level security;
drop policy if exists lead_nota_ler on public.lead_nota;
create policy lead_nota_ler on public.lead_nota for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.lead_nota from anon, authenticated;
grant select on public.lead_nota to authenticated;

create or replace function public.lead_nota_gravar(p_conversa uuid, p_venda uuid, p_texto text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c uuid := p_conversa; t text := left(btrim(coalesce(p_texto, '')), 2000);
begin
  if coalesce((select public.meu_perfil()), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  -- a nota é do lead: com conversa, fica na conversa (a ficha da venda e a da conversa mostram a mesma)
  if c is null and p_venda is not null then
    select m.id into c from public.mari_conversas m where m.venda_id = p_venda order by m.created_at desc limit 1;
  end if;
  if c is null and p_venda is null then raise exception 'Lead não encontrado.'; end if;
  if c is not null then
    insert into public.lead_nota (conversa_id, texto, atualizado_por, atualizado_em) values (c, t, auth.uid(), now())
    on conflict (conversa_id) do update set texto = excluded.texto, atualizado_por = excluded.atualizado_por, atualizado_em = now();
  else
    insert into public.lead_nota (venda_id, texto, atualizado_por, atualizado_em) values (p_venda, t, auth.uid(), now())
    on conflict (venda_id) do update set texto = excluded.texto, atualizado_por = excluded.atualizado_por, atualizado_em = now();
  end if;
  return jsonb_build_object('ok', true, 'texto', t);
end $$;
revoke all on function public.lead_nota_gravar(uuid, uuid, text) from public, anon;
grant execute on function public.lead_nota_gravar(uuid, uuid, text) to authenticated;

-- ───────────────────────── 3a. o tipo de aviso novo no celular ─────────────────────────
alter table public.push_envios drop constraint if exists push_envios_gatilho_check;
alter table public.push_envios add constraint push_envios_gatilho_check check (gatilho = any (array['janela_24h', 'objecao', 'docs_vencendo',
  'fatura_d5', 'm10_risco', 'mari_parada', 'teste', 'handoff_sem_resposta']));

-- ───────────────────────── a ficha da venda traz o número e o post-it (sem chamada nova) ─────────────────────────
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
    'chatwoot_resolvida', 'time_atribuido', 'venda_id', 'bio_lembrete_em', 'instalacao_avisada_para', 'instalacao_avisada_em'];
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

-- ───────────────────────── 3. C4: aviso no celular ─────────────────────────
CREATE OR REPLACE FUNCTION public.push_pendentes(p_vapid_publica text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    union all
    -- 0296 (C4, Ricardo 17/11): handoff para o time sem ninguém responder em 2 h úteis → aviso no celular do admin
    -- (em 24 h úteis a Mari volta sozinha: prazo:handoff_sem_resposta, na _porta_prazos)
    select 'handoff_sem_resposta', m.id::text, m.id, null,
           '🙋 Handoff sem resposta há ' || floor(public._horas_uteis(m.handoff_em, now()))::int || ' h úteis',
           coalesce(nullif(split_part(btrim(coalesce(m.nome_contato, '')), ' ', 1), ''), 'Cliente') || coalesce(' · ' || m.cidade, '')
             || ' — pediu ' || case m.handoff_motivo when 'pedido_humano' then 'uma pessoa' when 'objecao' then 'ajuda com uma objeção'
                                                     else 'atenção urgente' end || ' e ninguém do time respondeu',
           'fila.html?de=push#conversa=' || m.id, true
      from public.mari_conversas m
     where m.canal = 'whatsapp' and m.status = 'handoff_realizado' and m.handoff_motivo in ('pedido_humano', 'objecao', 'urgencia_alta')
       and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento' and m.espera_ate is null
       and (coalesce(m.time_atribuido, false) or m.chatwoot_time is not null)
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false)
       and coalesce(m.telefone, '') not like '5500000000%'
       and m.handoff_em > now() - interval '7 days'
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano' and t.created_at > m.handoff_em)
       and public._horas_uteis(m.handoff_em, now())
           >= coalesce(nullif(public._bo_cfg('handoff_aviso_celular_horas_uteis', '2'::jsonb) #>> '{}', '')::numeric, 2)
  ), alvo as (
    select s.id as sub_id, s.perfil, s.endpoint, s.keys, u.perfil as tipo
      from public.push_subscriptions s join public.usuarios u on u.id = s.perfil
     where s.ativo and u.ativo and u.perfil in ('admin', 'backoffice')
  ), novos as (
    insert into public.push_envios (subscription_id, perfil, gatilho, chave, conversa_id, venda_id, titulo, corpo, url)
    select a.sub_id, a.perfil, e.gatilho, e.chave, e.conversa_id, e.venda_id, left(e.titulo, 80), left(e.corpo, 180), e.url
      from ev e join alvo a on (not e.so_admin or a.tipo = 'admin')
     order by case e.gatilho when 'mari_parada' then 0 when 'handoff_sem_resposta' then 0 when 'janela_24h' then 1 when 'docs_vencendo' then 2 else 3 end
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
end $function$;

commit;
