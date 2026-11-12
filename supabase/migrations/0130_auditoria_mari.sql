-- NIOGEN | supabase/migrations/0130_auditoria_mari.sql | 12/11/2026 — Claude Code
-- Ricardo, 12/11 ~01h20 ("Sim, constrói", Sonnet): auditoria das conversas da Mari pelo Claude — comportamento, falhas de prompt,
-- cadência/templates, erros — 1x por dia (n8n auditoria_mari, 7h30 seg–sáb) ou quando o admin/backoffice pede no NIOGEN
-- (tela Mari › Auditoria, ou "Auditar esta conversa" na gaveta). O pedido vira uma linha 'pedido' aqui; o n8n busca a cada 2 min
-- (8h–22h), chama o Claude e grava. Nada sai para cliente.
--   auditoria_mari                 : pedidos e resultados (achados com evidência e correção sugerida no prompt).
--   _auditoria_mascarar(text)      : tira CPF, telefone e e-mail das falas antes de irem para a API (dado de cliente é da Nio).
--   auditoria_mari_pedir(conversa) : admin/backoffice; devolve o pedido em aberto se já houver um; teto de 20 pedidos/dia.
--   auditoria_mari_proximo(diaria) : service role; cria a diária ou pega o pedido mais antigo e devolve a entrada do Claude.
--   auditoria_mari_gravar(id, ...) : service role; grava o resultado.
--   resumo_diario_whatsapp         : a linha "Paradas" das 8h ganha " · auditoria da Mari: N achado(s)".

create table if not exists public.auditoria_mari (
  id            bigserial primary key,
  parceiro_id   text not null default 'dharma',
  modo          text not null check (modo in ('diaria', 'pedido')),
  conversa_id   uuid,
  pedido_por    uuid,
  pedido_em     timestamptz not null default now(),
  status        text not null default 'pedido' check (status in ('pedido', 'rodando', 'pronta', 'erro')),
  inicio        timestamptz,
  fim           timestamptz,
  janela_de     timestamptz,
  janela_ate    timestamptz,
  modelo        text,
  tokens_in     int,
  tokens_out    int,
  resumo        text,
  achados       jsonb not null default '[]'::jsonb,
  numeros       jsonb,
  erro          text
);
create index if not exists auditoria_mari_status on public.auditoria_mari (status, pedido_em);
create index if not exists auditoria_mari_pedido_em on public.auditoria_mari (pedido_em desc);
alter table public.auditoria_mari enable row level security;
drop policy if exists auditoria_mari_ler on public.auditoria_mari;
create policy auditoria_mari_ler on public.auditoria_mari for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.auditoria_mari from anon;
grant select on public.auditoria_mari to authenticated;

create or replace function public._auditoria_mascarar(p text) returns text language sql immutable as $$
  select regexp_replace(regexp_replace(regexp_replace(coalesce(p, ''),
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[e-mail]', 'g'),
    '\d{3}\.?\d{3}\.?\d{3}-?\d{2}', '[CPF]', 'g'),
    '(\+?55\s?)?\(?\d{2}\)?\s?9?\d{4}[-\s]?\d{4}', '[telefone]', 'g')
$$;

-- Entrada do Claude: conversas com fala na janela (ou a conversa pedida), últimas falas, tags úteis, erros e números.
create or replace function public._auditoria_mari_dados(p_de timestamptz, p_ate timestamptz, p_conversa uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  with cs as (
    select c.* from public.mari_conversas c
     where (p_conversa is not null and c.id = p_conversa)
        or (p_conversa is null and exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.created_at between p_de and p_ate))
     order by c.updated_at desc nulls last
     limit case when p_conversa is null then 60 else 1 end
  ), conv as (
    select jsonb_build_object(
      'conversa_id', c.id, 'nome', split_part(coalesce(c.nome_contato, ''), ' ', 1),
      'cidade', c.cidade, 'cluster', c.cluster, 'origem', c.origem, 'etapa', c.etapa, 'status', c.status,
      'dentro_area', c.dentro_area, 'viabilidade_nio', c.nio_viab_resultado, 'plano_escolhido', c.plano_escolhido,
      'forma_pagamento', c.forma_pagamento, 'handoff_motivo', c.handoff_motivo, 'handoff_em', c.handoff_em,
      'virou_venda', c.venda_id is not null, 'com_humano', (c.humano_atribuido is not null or c.time_atribuido is not null),
      'nao_contatar', c.nao_contatar, 'cadencia_passo', c.cadencia_passo, 'cadencia_proximo_em', c.cadencia_proximo_em,
      'falas', (select coalesce(jsonb_agg(f order by f->>'em'), '[]'::jsonb) from (
          select jsonb_build_object(
            'em', to_char(t.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
            'quem', t.papel,
            'texto', left(public._auditoria_mascarar(t.texto), 600),
            'tags', nullif(case when jsonb_typeof(t.tags) = 'object' then t.tags - 'dados_coletados' - 'endereco' - 'acao_id' else null end, '{}'::jsonb),
            'latencia_s', case when t.latencia_ms is not null then round(t.latencia_ms / 1000.0, 1) end) f
          from public.mari_turnos t
         where t.conversa_id = c.id
           and t.created_at <= p_ate
           and t.created_at >= case when p_conversa is null then p_de - interval '24 hours' else p_de end
         order by t.created_at desc limit case when p_conversa is null then 40 else 120 end) x)
    ) j
    from cs c
  )
  select jsonb_build_object(
    'conversas', (select coalesce(jsonb_agg(j), '[]'::jsonb) from conv),
    'erros', (select coalesce(jsonb_agg(jsonb_build_object(
                'em', to_char(e.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), 'no', e.no_n8n,
                'conversa_id', e.conversa_id, 'mensagem', left(public._auditoria_mascarar(e.mensagem), 240),
                'texto_bloqueado', left(public._auditoria_mascarar(e.payload->>'texto_bloqueado'), 300)) order by e.created_at), '[]'::jsonb)
              from public.mari_erros e
             where e.created_at between p_de and p_ate and (p_conversa is null or e.conversa_id = p_conversa)),
    'numeros', (select jsonb_build_object(
                  'conversas', count(distinct t.conversa_id),
                  'falas_lead', count(*) filter (where t.papel = 'lead'),
                  'falas_mari', count(*) filter (where t.papel = 'mari'),
                  'falas_time', count(*) filter (where t.papel = 'humano'),
                  'toques_cadencia', count(*) filter (where t.papel = 'mari' and t.tags ? 'cadencia'),
                  'handoffs', count(*) filter (where t.papel = 'mari' and t.tags ? 'handoff'),
                  'latencia_media_s', round(avg(t.latencia_ms) filter (where t.papel = 'mari') / 1000.0, 1),
                  'latencia_max_s', round(max(t.latencia_ms) filter (where t.papel = 'mari') / 1000.0, 1),
                  'tokens_in_mari', sum(t.tokens_in), 'tokens_out_mari', sum(t.tokens_out))
                from public.mari_turnos t
               where t.created_at between p_de and p_ate and (p_conversa is null or t.conversa_id = p_conversa))
  ) into v;
  return v;
end $$;
revoke all on function public._auditoria_mari_dados(timestamptz, timestamptz, uuid) from public, anon, authenticated;

create or replace function public.auditoria_mari_pedir(p_conversa uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_hoje int;
begin
  if public.meu_perfil() not in ('admin', 'backoffice') then
    raise exception 'auditoria_mari_pedir: só admin e backoffice' using errcode = '42501';
  end if;
  select id into v_id from public.auditoria_mari
   where status in ('pedido', 'rodando') and conversa_id is not distinct from p_conversa order by pedido_em limit 1;
  if v_id is not null then return jsonb_build_object('ok', true, 'id', v_id, 'ja_havia', true); end if;
  select count(*) into v_hoje from public.auditoria_mari where modo = 'pedido' and pedido_em > now() - interval '24 hours';
  if v_hoje >= 20 then
    return jsonb_build_object('ok', false, 'motivo', 'limite de 20 auditorias pedidas em 24 h');
  end if;
  insert into public.auditoria_mari (modo, conversa_id, pedido_por, janela_de, janela_ate)
  values ('pedido', p_conversa, auth.uid(),
          case when p_conversa is null then now() - interval '24 hours' else now() - interval '7 days' end, now())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'ja_havia', false);
end $$;
revoke all on function public.auditoria_mari_pedir(uuid) from public, anon;
grant execute on function public.auditoria_mari_pedir(uuid) to authenticated;

create or replace function public.auditoria_mari_proximo(p_diaria boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.auditoria_mari; v_de timestamptz; v_dados jsonb;
begin
  -- Pedido travado (n8n caiu no meio): vira erro depois de 15 min, para não segurar a fila.
  update public.auditoria_mari set status = 'erro', fim = now(), erro = 'travou rodando (mais de 15 min)'
   where status = 'rodando' and inicio < now() - interval '15 minutes';
  if p_diaria then
    -- Desde o fim da última diária (segunda pega o fim de semana), no máximo 72 h.
    select greatest(coalesce(max(janela_ate), now() - interval '24 hours'), now() - interval '72 hours') into v_de
      from public.auditoria_mari where modo = 'diaria' and status = 'pronta';
    insert into public.auditoria_mari (modo, status, inicio, janela_de, janela_ate)
    values ('diaria', 'rodando', now(), v_de, now()) returning * into r;
  else
    select * into r from public.auditoria_mari where status = 'pedido' order by pedido_em limit 1 for update skip locked;
    if r.id is null then return jsonb_build_object('tem', false); end if;
    update public.auditoria_mari set status = 'rodando', inicio = now(), janela_ate = now() where id = r.id returning * into r;
  end if;
  v_dados := public._auditoria_mari_dados(r.janela_de, r.janela_ate, r.conversa_id);
  return jsonb_build_object('tem', true, 'id', r.id, 'modo', r.modo, 'conversa_id', r.conversa_id,
    'janela', format('%s a %s', to_char(r.janela_de at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                                to_char(r.janela_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')),
    'tem_conversa', jsonb_array_length(v_dados->'conversas') > 0) || v_dados;
end $$;
revoke all on function public.auditoria_mari_proximo(boolean) from public, anon, authenticated;
grant execute on function public.auditoria_mari_proximo(boolean) to service_role;

create or replace function public.auditoria_mari_gravar(p_id bigint, p_linha jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.auditoria_mari set
    status = case when coalesce(p_linha->>'erro', '') <> '' then 'erro' else 'pronta' end,
    fim = now(), modelo = p_linha->>'modelo', tokens_in = (p_linha->>'tokens_in')::int, tokens_out = (p_linha->>'tokens_out')::int,
    resumo = p_linha->>'resumo', achados = coalesce(p_linha->'achados', '[]'::jsonb), numeros = p_linha->'numeros',
    erro = nullif(p_linha->>'erro', '')
  where id = p_id;
  return jsonb_build_object('ok', found, 'id', p_id);
end $$;
revoke all on function public.auditoria_mari_gravar(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.auditoria_mari_gravar(bigint, jsonb) to service_role;

-- Aviso das 8h: a linha "Paradas" ganha a auditoria do dia (só a diária, só quando terminou).
CREATE OR REPLACE FUNCTION public.resumo_diario_whatsapp(p_dia date DEFAULT (((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date - 1))
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r jsonb; d jsonb; v jsonb; m jsonb; pa jsonb; pz jsonb; e jsonb; ri jsonb;
  dows text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];
  p text[];
  brl text;
  prazos text;
begin
  if auth.role() is distinct from 'service_role' and auth.uid() is not null and public.meu_perfil() is distinct from 'admin' then
    raise exception 'resumo_diario_whatsapp: só admin' using errcode = '42501';
  end if;
  r := public.resumo_diario(p_dia);
  d := r->'dados'; v := d->'vendas'; m := d->'meta_ads'; pa := d->'paradas'; pz := d->'prazos'; e := d->'em_espera'; ri := d->'ritmo';
  brl := replace(to_char((m->>'gasto')::numeric, 'FM999990.00'), '.', ',');
  prazos := case when (pz->'agendar'->>'vencidos')::int + (pz->'agendar'->>'hoje')::int + (pz->'agendar'->>'amanha')::int
                    + (pz->'docs'->>'vencidos')::int + (pz->'docs'->>'hoje')::int + (pz->'docs'->>'amanha')::int = 0
                 then 'nada vencendo hoje nem amanhã'
                 else format('agendar: %s vencido(s), %s hoje, %s amanhã · docs: %s vencido(s), %s hoje, %s amanhã',
                             pz->'agendar'->>'vencidos', pz->'agendar'->>'hoje', pz->'agendar'->>'amanha',
                             pz->'docs'->>'vencidos', pz->'docs'->>'hoje', pz->'docs'->>'amanha') end
            || case when (e->>'abertas')::int > 0 then format(' · em espera: %s (%s para revisar)', e->>'abertas', e->>'revisar_hoje_ou_antes') else '' end;
  p := array[
    format('%s %s', dows[extract(dow from p_dia)::int + 1], to_char(p_dia, 'DD/MM')),
    format('%s nova(s) · %s qualificada(s) pela Mari · %s pedido(s) · %s biometria(s) · %s instalada(s)',
           v->>'criadas', v->>'qualificadas_mari', v->>'pedidos', v->>'biometrias', v->>'instaladas'),
    case when (m->>'conversas')::int > 0
         then format('R$ %s · %s conversa(s) · R$ %s por conversa', brl, m->>'conversas',
                     replace(to_char((m->>'custo_por_conversa')::numeric, 'FM999990.00'), '.', ','))
         else format('R$ %s · nenhuma conversa', brl) end,
    format('%s com humano sem resposta · %s cliente esperando a Mari (há mais de %s h)', pa->>'com_humano', pa->>'cliente_sem_resposta',
           replace(pa->>'horas', '.', ','))
      || coalesce((select format(' · balanço: %s com resposta sugerida no NIOGEN (botão Balanço)', jsonb_array_length(bd.itens))
                     from public.balanco_diario bd
                    where bd.dia = (now() at time zone 'America/Sao_Paulo')::date and bd.erro is null
                      and jsonb_array_length(bd.itens) > 0
                    order by bd.criado_em desc limit 1), '')
      || coalesce((select format(' · auditoria da Mari: %s achado(s) (%s grave(s)) na tela Mari', jsonb_array_length(a.achados),
                                 (select count(*) from jsonb_array_elements(a.achados) x where x->>'gravidade' = 'alta'))
                     from public.auditoria_mari a
                    where a.modo = 'diaria' and a.status = 'pronta' and a.fim > now() - interval '12 hours'
                    order by a.fim desc limit 1), ''),
    prazos,
    case when ri is null or (ri->>'meta')::int = 0 then 'sem meta cadastrada'
         when (ri->>'faltam')::int = 0 then format('%s/%s instaladas · meta batida', ri->>'instaladas', ri->>'meta')
         else format('%s/%s instaladas · faltam %s em %s dias · %s por dia', ri->>'instaladas', ri->>'meta', ri->>'faltam',
                     ri->>'dias_restantes', replace(ri->>'por_dia', '.', ',')) end
  ];
  return jsonb_build_object(
    'template', 'resumo_diario_interno', 'idioma', 'pt_BR',
    'destino', (select valor #>> '{}' from public.config_regras where chave = 'resumo_destino_whatsapp'),
    'params', to_jsonb(p),
    'texto', r->>'texto');
end $function$;
