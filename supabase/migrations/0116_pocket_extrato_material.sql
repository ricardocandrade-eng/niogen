-- NIOGEN | supabase/migrations/0116_pocket_extrato_material.sql | 10/11/2026 — Claude Code (docs/Prompt_pocket_parceiro_101126_2025.md)
-- Complementos do Pocket do Parceiro (0115):
--  1. parceiro_meus_pagamentos devolve o caminho do comprovante DO PRÓPRIO parceiro (o front gera a URL assinada de 60 s;
--     a policy comprovantes_parceiros_proprio só deixa abrir o dele).
--  2. parceiro_enviar_venda grava o tempo de envio (segundos do 1º campo ao botão) no evento parceiro_enviou — medida do
--     resultado do prompt ("envia venda em < 3 min").
--  3. parceiro_material(): conteúdos publicados com chave 'parceiro_%' (tabela `conteudos`, a mesma do guia do backoffice).

drop function if exists public.parceiro_meus_pagamentos();
create function public.parceiro_meus_pagamentos()
returns table (
  id bigint, tipo text, tipo_texto text, competencia date, valor numeric, vence_em date, status text,
  pago_em timestamptz, tem_comprovante boolean, venda_primeiro_nome text, proximo_recebe_em date, proximo_valor numeric,
  comprovante_path text)
language sql stable security definer set search_path = public as $$
  with eu as (select * from public.parceiros where id = public.parceiro_atual()),
  prox as (
    select g.vence_em, sum(g.valor) as valor from public.parceiro_pagamentos g, eu
     where g.parceiro_id = eu.id and g.status = 'previsto' and g.vence_em >= (now() at time zone 'America/Sao_Paulo')::date
     group by g.vence_em order by g.vence_em limit 1
  )
  select g.id, g.tipo,
         case g.tipo when 'comissao' then 'Comissão' when 'premio_degrau' then 'Ajuda de custo' when 'bonus_boas_vindas' then 'Bônus de boas-vindas'
                     when 'largada_abatimento' then 'Abatimento da largada' else 'Incentivo' end,
         g.competencia, g.valor, g.vence_em, g.status, g.pago_em, (g.comprovante_path is not null),
         (select split_part(btrim(v.cliente_nome), ' ', 1) from public.vendas v where v.id = g.venda_id),
         (select vence_em from prox), (select valor from prox), g.comprovante_path
    from public.parceiro_pagamentos g, eu
   where g.parceiro_id = eu.id and g.status <> 'cancelado'
  union all
  select null, 'largada', 'Largada', date_trunc('month', eu.largada_paga_em)::date, eu.largada_valor, eu.largada_paga_em, 'pago',
         eu.largada_paga_em::timestamptz, false, null, (select vence_em from prox), (select valor from prox), null
    from eu where eu.largada_paga_em is not null and eu.largada_valor > 0
  order by 6 desc nulls first, 1 desc nulls last
$$;
revoke execute on function public.parceiro_meus_pagamentos() from public, anon;
grant execute on function public.parceiro_meus_pagamentos() to authenticated;

-- Tempo de envio no evento: troca só a linha do evento (o resto da função é o da 0115).
do $$
declare
  def text := pg_get_functiondef('public.parceiro_enviar_venda(jsonb)'::regprocedure);
begin
  if position('tempo_s' in def) = 0 then
    def := replace(def,
      $a$jsonb_build_object('parceiro_id', par.id, 'parceiro', par.nome, 'observacao', obs)$a$,
      $b$jsonb_build_object('parceiro_id', par.id, 'parceiro', par.nome, 'observacao', obs, 'tempo_s', case when (p ->> 'tempo_s') ~ '^[0-9]{1,6}$' then (p ->> 'tempo_s')::int end)$b$);
    if position('tempo_s' in def) = 0 then
      raise exception '0116: não achei a linha do evento em parceiro_enviar_venda';
    end if;
    execute def;
  end if;
end;
$$;

create or replace function public.parceiro_material()
returns table (chave text, titulo text, markdown text, rev text, publicado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select c.chave, c.titulo, c.markdown, c.rev, c.publicado_em
    from public.conteudos c
   where public.parceiro_atual() is not null and c.chave like 'parceiro\_%'
   order by c.chave
$$;
revoke execute on function public.parceiro_material() from public, anon;
grant execute on function public.parceiro_material() to authenticated;
