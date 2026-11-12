-- NIOGEN | supabase/migrations/0127_balanco_diario.sql | 11/11/2026 — Claude Code
-- Balanço diário das conversas paradas, escrito pelo Claude (Ricardo, 11/11 ~22h: "usar a API do Claude para fazer esse balanço 1x por dia
-- e me alertar" → "n8n + API do Claude"). Resultado perseguido: nenhum lead esperando o time por horas sem alguém saber o que
-- responder (11/11: 7 conversas paradas de 4 a 23 h). Medir em 7 dias: quantas conversas do balanço foram respondidas no mesmo dia.
--   1. balanco_diario — uma linha por rodada (n8n balanco_diario, 7h45 seg–sáb): resumo + itens (conversa, urgência, situação,
--      ação, resposta sugerida). Só admin/backoffice lê; quem grava é o n8n (service role). Regra 15: nasce com parceiro_id.
--   2. balanco_diario_entrada() — o que o n8n manda ao Claude: números de ontem/24 h e as conversas com cliente esperando o time há
--      mais de config_regras.resumo_parada_horas (fora as encerradas e silenciadas), com as últimas 12 falas. Sem CPF nem telefone.
--      Só service_role.
--   3. resumo_diario_whatsapp(): a linha "Paradas" do WhatsApp das 8h ganha " · balanço: N com resposta sugerida no Painel".

create table if not exists public.balanco_diario (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  dia         date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  criado_em   timestamptz not null default now(),
  modelo      text,
  tokens_in   integer,
  tokens_out  integer,
  resumo      text,
  itens       jsonb not null default '[]'::jsonb,
  erro        text
);
create index if not exists balanco_diario_dia on public.balanco_diario (dia desc, criado_em desc);
alter table public.balanco_diario enable row level security;
drop policy if exists balanco_diario_ler on public.balanco_diario;
create policy balanco_diario_ler on public.balanco_diario for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));

create or replace function public.balanco_diario_entrada()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'resumo_parada_horas'), 2);
  hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'balanco_diario_entrada: só o n8n (service role)' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'agora', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
    'horas_parada', horas,
    'numeros', jsonb_build_object(
      'leads_ontem', (select count(*) from public.mari_conversas c
                       where (c.created_at at time zone 'America/Sao_Paulo')::date = hoje - 1
                         and coalesce(c.telefone, '') not like '5500000000%' and c.canal = 'whatsapp'),
      'mari_respostas_24h', (select count(*) from public.mari_turnos t where t.papel = 'mari' and t.created_at > now() - interval '24 hours'),
      'mari_latencia_media_s', (select round(avg(t.latencia_ms) / 1000.0, 1) from public.mari_turnos t
                                 where t.papel = 'mari' and t.created_at > now() - interval '24 hours'),
      'erros_24h', (select count(*) from public.mari_erros e where e.created_at > now() - interval '24 hours')),
    'conversas', coalesce((
      select jsonb_agg(x order by x.esperando_h desc)
        from (select v.id as conversa_id,
                     split_part(v.nome, ' ', 1) as nome,
                     v.cidade, v.etapa, v.dono_nome as dono,
                     round(v.esperando_min / 60.0, 1) as esperando_h,
                     c.handoff_motivo, c.plano_escolhido, c.forma_pagamento,
                     left(c.handoff_briefing, 700) as resumo_da_mari,
                     (select jsonb_agg(jsonb_build_object(
                               'quem', t.papel,
                               'quando', to_char(t.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                               'texto', left(t.texto, 400)) order by t.created_at)
                        from (select t2.* from public.mari_turnos t2
                               where t2.conversa_id = v.id and t2.papel in ('lead', 'mari', 'humano')
                               order by t2.created_at desc limit 12) t) as ultimas_falas
                from public.v_conversas v
                join public.mari_conversas c on c.id = v.id
               where v.cliente_esperando and not v.encerrada and v.esperando_min >= horas * 60
               order by v.esperando_min desc
               limit 20) x), '[]'::jsonb));
end $$;
revoke all on function public.balanco_diario_entrada() from public, anon, authenticated;
grant execute on function public.balanco_diario_entrada() to service_role;

-- 3. resumo das 8h
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
      || coalesce((select format(' · balanço: %s com resposta sugerida no Painel', jsonb_array_length(bd.itens))
                     from public.balanco_diario bd
                    where bd.dia = (now() at time zone 'America/Sao_Paulo')::date and bd.erro is null
                      and jsonb_array_length(bd.itens) > 0
                    order by bd.criado_em desc limit 1), ''),
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
