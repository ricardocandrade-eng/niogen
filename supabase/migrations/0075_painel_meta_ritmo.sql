-- NIOGEN | supabase/migrations/0075_painel_meta_ritmo.sql | 09/11/2026 — Claude Code (Prompt_rodada_noturna_ondas2e3_091126_0100, item 2 · onda 2.1)
-- Por quê: o Painel precisa de uma faixa "primeira venda" no topo — meta do mês × instaladas, ritmo (faltam N em D dias → X por dia)
--          e paradas por etapa com o prazo do contrato. A mesma conta do ritmo é usada pelo resumo diário (item 5).
-- O quê (só aditivo):
--   1. config_metas ganha parceiro_id (regra 15; hoje só 'dharma'). As metas 30/50/70 já estavam lá desde a v0.2.
--   2. config_regras (chave → valor jsonb, parceiro_id): prazos do contrato e flags lidos pelo front e pelas funções — nada fixo no código.
--   3. painel_meta_ritmo(p_hoje): devolve só números (meta, instaladas, faltam, dias, por dia) para qualquer perfil logado;
--      SECURITY DEFINER para o vendedor também ver o ritmo da empresa, sem nenhum dado de cliente.

alter table public.config_metas add column if not exists parceiro_id text not null default 'dharma';

create table if not exists public.config_regras (
  chave       text primary key,
  valor       jsonb not null,
  descricao   text,
  parceiro_id text not null default 'dharma',
  atualizado_em timestamptz not null default now()
);
alter table public.config_regras enable row level security;
drop policy if exists config_regras_ler on public.config_regras;
create policy config_regras_ler on public.config_regras for select to authenticated using (public.meu_perfil() is not null);
drop policy if exists config_regras_admin on public.config_regras;
create policy config_regras_admin on public.config_regras for all to authenticated
  using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
revoke all on public.config_regras from anon;
grant select on public.config_regras to authenticated;
grant insert, update, delete on public.config_regras to authenticated;

insert into public.config_regras (chave, valor, descricao) values
  ('prazo_agendar_horas', '4',  'Contrato: agendar a instalação em até 4 h depois da venda (Painel pinta de vermelho acima disso)'),
  ('prazo_docs_dias',     '15', 'Contrato: documentos à Nio em até 15 dias da instalação'),
  ('meta_conta',          '"instaladas"', 'O que conta para a meta do mês na faixa do Painel: vendas instaladas no mês (instalado_em), sem Saída')
on conflict (chave) do nothing;

create or replace function public.config_regra(p_chave text, p_padrao jsonb default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select valor from public.config_regras where chave = p_chave and parceiro_id = 'dharma'), p_padrao);
$$;
revoke all on function public.config_regra(text, jsonb) from public, anon;
grant execute on function public.config_regra(text, jsonb) to authenticated, service_role;

-- Meta do mês × instaladas e ritmo. p_hoje conta como dia disponível (dias corridos até o fim do mês, hoje incluído).
-- Feriados ficam para a pendência 16 (aqui são dias corridos, como pedido).
create or replace function public.painel_meta_ritmo(p_hoje date default (now() at time zone 'America/Sao_Paulo')::date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ini date := date_trunc('month', p_hoje)::date;
  v_fim date := (date_trunc('month', p_hoje) + interval '1 month - 1 day')::date;
  v_meta int; v_inst int; v_faltam int; v_dias int;
begin
  if auth.role() <> 'service_role' and public.meu_perfil() is null then
    return null;
  end if;
  select meta_vendas into v_meta from public.config_metas where mes = v_ini and parceiro_id = 'dharma';
  select count(*) into v_inst
    from public.vendas v
   where v.instalado_em is not null
     and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
     and (v.instalado_em at time zone 'America/Sao_Paulo')::date between v_ini and v_fim;
  v_meta := coalesce(v_meta, 0);
  v_faltam := greatest(v_meta - v_inst, 0);
  v_dias := v_fim - p_hoje + 1;
  return jsonb_build_object(
    'mes', to_char(v_ini, 'YYYY-MM'),
    'meta', v_meta,
    'instaladas', v_inst,
    'faltam', v_faltam,
    'dias_restantes', v_dias,
    'por_dia', case when v_dias > 0 then round(v_faltam::numeric / v_dias, 1) else v_faltam end,
    'pct', case when v_meta > 0 then round(100.0 * v_inst / v_meta, 1) else null end
  );
end $$;
revoke all on function public.painel_meta_ritmo(date) from public, anon;
grant execute on function public.painel_meta_ritmo(date) to authenticated, service_role;
