-- NIOGEN | supabase/migrations/0208_mari_painel_vendas_que_seguem.sql | 15/11/2026 — Claude Code / Opus 5.5
-- Ricardo (15/11): "Não entendi o card Últimos 14 dias, contando conversas 124 / vendas 17". As 17 eram TODOS os registros de venda
-- nascidos de conversa da Mari — 15 deles já em Saída (lead qualificado que desistiu ou caiu). Agora o dia traz:
--   qualificadas = registros de venda criados (o lead chegou a Lead qualificado), vendas = os que seguem (sem Saída).
-- Corpo = 0207 com só o CTE vd trocado.

create or replace function public.mari_painel()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return null; end if;
  with cv as (
    select c.* from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' and coalesce(c.origem, '') <> 'teste'
  ),
  d as (select generate_series(hoje - 13, hoje, interval '1 day')::date as dia),
  novas as (
    select (c.created_at at time zone 'America/Sao_Paulo')::date as dia, count(*) n,
           count(*) filter (where exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead')) resp
      from cv c where c.created_at >= (hoje - 13)::timestamp at time zone 'America/Sao_Paulo' group by 1
  ),
  ho as (
    select (c.handoff_em at time zone 'America/Sao_Paulo')::date as dia, count(*) n
      from cv c where c.handoff_em >= (hoje - 13)::timestamp at time zone 'America/Sao_Paulo' group by 1
  ),
  vd as (
    select (v.criado_em at time zone 'America/Sao_Paulo')::date as dia, count(*) filter (where v.status <> 'saida') n, count(*) q
      from public.vendas v where v.id in (select venda_id from cv where venda_id is not null)
       and v.criado_em >= (hoje - 13)::timestamp at time zone 'America/Sao_Paulo' group by 1
  ),
  inst as (
    select (v.instalado_em at time zone 'America/Sao_Paulo')::date as dia, count(*) n
      from public.vendas v where v.id in (select venda_id from cv where venda_id is not null)
       and v.instalado_em >= (hoje - 13)::timestamp at time zone 'America/Sao_Paulo' group by 1
  )
  select jsonb_build_object(
    'dias', (select jsonb_agg(jsonb_build_object('dia', to_char(d.dia, 'YYYY-MM-DD'), 'dow', extract(isodow from d.dia)::int,
               'conversas', coalesce(novas.n, 0), 'responderam', coalesce(novas.resp, 0), 'handoffs', coalesce(ho.n, 0),
               'vendas', coalesce(vd.n, 0), 'qualificadas', coalesce(vd.q, 0), 'instaladas', coalesce(inst.n, 0)) order by d.dia)
               from d left join novas using (dia) left join ho using (dia) left join vd using (dia) left join inst using (dia)),
    'escada', (select coalesce(jsonb_agg(jsonb_build_object('codigo', e.codigo, 'nome', e.nome, 'n', coalesce(x.n, 0)) order by e.ordem), '[]'::jsonb)
                 from public.config_lead e
                 left join (select l.etapa, count(*) n from public.v_leads l join cv on cv.id = l.conversa_id
                             where l.destino = 'em_andamento' group by 1) x on x.etapa = e.codigo
                where e.tipo = 'etapa' and e.codigo <> 'instalada'),
    'motivos', (select coalesce(jsonb_agg(jsonb_build_object('motivo', m, 'n', n) order by n desc), '[]'::jsonb)
                  from (select coalesce(handoff_motivo, 'sem motivo') m, count(*) n from cv
                         where handoff_em >= now() - interval '7 days' group by 1) z),
    'cidades', (select coalesce(jsonb_agg(jsonb_build_object('cidade', ci, 'n', n) order by n desc), '[]'::jsonb)
                  from (select coalesce(nullif(cidade, ''), 'sem cidade') ci, count(*) n from cv
                         where created_at >= now() - interval '7 days' group by 1 order by 2 desc limit 6) z),
    'origens', (select coalesce(jsonb_agg(jsonb_build_object('origem', o, 'n', n) order by n desc), '[]'::jsonb)
                  from (select coalesce(origem, 'direto') o, count(*) n from cv
                         where created_at >= now() - interval '7 days' group by 1) z),
    'em', now()) into r;
  return r;
end $$;
revoke all on function public.mari_painel() from public, anon;
grant execute on function public.mari_painel() to authenticated;
