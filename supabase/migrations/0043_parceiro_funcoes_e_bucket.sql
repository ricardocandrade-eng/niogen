-- NIOGEN | supabase/migrations/0043_parceiro_funcoes_e_bucket.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- (a) Funções SECURITY DEFINER da página do parceiro (etapa 3): filtram por auth_user_id = auth.uid() e expõem SÓ
--     primeiro nome do cliente, bairro, cidade, plano, etapa, motivo e valores — NUNCA CPF, telefone, e-mail,
--     logradouro, número, pedido da Nio nem a observação interna da conferência.
-- (b) Bucket PRIVADO dos comprovantes de pagamento ao parceiro (parceiro_pagamentos.comprovante_path).
-- Quem não é parceiro (ou é anon) recebe zero linhas.

create or replace function public.parceiro_atual()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.parceiros where auth_user_id = auth.uid()
$$;
revoke execute on function public.parceiro_atual() from public, anon;
grant execute on function public.parceiro_atual() to authenticated;

create or replace function public.parceiro_minhas_vendas()
returns table (
  venda_id uuid, enviada_em timestamptz, primeiro_nome text, bairro text, cidade text, plano text, etapa text,
  conferencia_status text, conferencia_motivo text, conferencia_prazo_ate timestamptz,
  instalada_em timestamptz, comissao numeric, pontos numeric, pagamento_status text, pagamento_vence_em date)
language sql stable security definer set search_path = public as $$
  select
    v.id,
    v.criado_em,
    split_part(btrim(v.cliente_nome), ' ', 1),
    v.bairro,
    v.cidade,
    coalesce(pl.nome_curto, pl.nome),
    case
      when v.status = 'saida'                       then 'cancelada'
      when v.conferencia_status = 'pendente'        then 'em_conferencia'
      when v.conferencia_status = 'reprovada'       then 'reprovada'
      when v.conferencia_status = 'devolvida'       then 'devolvida'
      when v.status = '0_qualificado'               then 'aprovada'
      when v.nio_situacao = 'Concluído' and v.nio_venda_valida is true and v.instalado_em is not null then 'instalada'
      else 'em_instalacao' end,
    v.conferencia_status,
    v.conferencia_motivo,
    case when v.conferencia_status = 'pendente' then v.conferencia_prazo_ate end,
    case when v.nio_situacao = 'Concluído' and v.nio_venda_valida is true then v.instalado_em end,
    public.parceiro_comissao_valor(v.parceiro_id, v.plano_id),
    coalesce((select sum(x.pontos) from public.pontos_lancamentos x where x.venda_id = v.id), 0),
    (select g.status  from public.parceiro_pagamentos g where g.venda_id = v.id and g.tipo = 'comissao'),
    (select g.vence_em from public.parceiro_pagamentos g where g.venda_id = v.id and g.tipo = 'comissao')
  from public.vendas v
  left join public.config_planos pl on pl.id = v.plano_id
  where v.parceiro_id = public.parceiro_atual()
  order by v.criado_em desc
$$;

create or replace function public.parceiro_meus_pontos()
returns table (
  competencia date, pontos numeric, degrau_pontos numeric, degrau_premio numeric,
  proximo_degrau_pontos numeric, proximo_degrau_premio numeric, faltam_pontos numeric, apurado boolean)
language sql stable security definer set search_path = public as $$
  select m.competencia, m.pontos, m.degrau_pontos, m.degrau_premio,
         m.proximo_degrau_pontos, m.proximo_degrau_premio, m.faltam_pontos, m.apurado
    from public.v_parceiro_pontos_mes m
   where m.parceiro_id = public.parceiro_atual()
   order by m.competencia desc
$$;

create or replace function public.parceiro_meus_pagamentos()
returns table (
  id bigint, tipo text, competencia date, valor numeric, vence_em date, status text, pago_em timestamptz, tem_comprovante boolean)
language sql stable security definer set search_path = public as $$
  select g.id, g.tipo, g.competencia, g.valor, g.vence_em, g.status, g.pago_em, (g.comprovante_path is not null)
    from public.parceiro_pagamentos g
   where g.parceiro_id = public.parceiro_atual() and g.status <> 'cancelado'
   order by g.vence_em desc, g.id desc
$$;

revoke execute on function public.parceiro_minhas_vendas(), public.parceiro_meus_pontos(), public.parceiro_meus_pagamentos() from public, anon;
grant execute on function public.parceiro_minhas_vendas(), public.parceiro_meus_pontos(), public.parceiro_meus_pagamentos() to authenticated;

-- ─────────────────────── bucket privado dos comprovantes ───────────────────────
insert into storage.buckets (id, name, public)
values ('comprovantes_parceiros', 'comprovantes_parceiros', false)
on conflict (id) do nothing;

drop policy if exists comprovantes_parceiros_admin on storage.objects;
create policy comprovantes_parceiros_admin on storage.objects
  for all to authenticated
  using (bucket_id = 'comprovantes_parceiros' and public.meu_perfil() = 'admin')
  with check (bucket_id = 'comprovantes_parceiros' and public.meu_perfil() = 'admin');
drop policy if exists comprovantes_parceiros_ler on storage.objects;
create policy comprovantes_parceiros_ler on storage.objects
  for select to authenticated
  using (bucket_id = 'comprovantes_parceiros' and public.meu_perfil() = 'backoffice');
