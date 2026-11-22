-- NIOGEN | supabase/migrations/0360_conversas_leads_lista_rapida.sql | 22/11/2026 — Claude Code (Fable 5.2)
-- Regra 19 (Ricardo, 22/11: "Resolve o tempo de abertura de Leads e Conversas"). Medido logado em 22/11:
--   · Conversas: a v_conversas lida pelo navegador leva 0,86–1,4 s; a MESMA consulta dentro do banco, sem o RLS, leva 0,026 s
--     (explain analyze). A visão é security_invoker: o RLS da mari_conversas, da mari_turnos e da vendas é conferido linha a
--     linha dentro dos laterais (238 conversas × ~33 falas cada).
--   · Leads: a v_leads leva ~1,26 s pelo mesmo motivo (e a tela só começava a consulta 1,4 s depois de abrir — isso é do front).
-- É o mesmo caso da 0108 (oportunidades_abertas: ~6 s pela visão, < 1 s como definer). O que muda: duas funções de LEITURA,
-- SECURITY DEFINER, com a porta de perfil admin/backoffice (quem já lê todas as linhas pelas políticas), que devolvem as mesmas
-- linhas e colunas das visões. Fora de admin/backoffice não devolvem nada e a tela usa a visão, com o RLS de sempre (o vendedor
-- continua vendo só o que é dele). As visões não mudam e seguem em uso por todas as outras telas. Só aditivo.
-- Regra 20: só leitura, nenhum estado. (5) sem conferência nova.
-- Cenário X86 (as funções devolvem exatamente o que as visões devolvem ao backoffice; fora dele, nada).
begin;

create or replace function public.conversas_lista()
returns setof public.v_conversas
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return;
  end if;
  return query select * from public.v_conversas;
end $$;
revoke all on function public.conversas_lista() from public, anon;
grant execute on function public.conversas_lista() to authenticated;

create or replace function public.leads_lista()
returns setof public.v_leads
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return;
  end if;
  return query select * from public.v_leads;
end $$;
revoke all on function public.leads_lista() from public, anon;
grant execute on function public.leads_lista() to authenticated;

commit;
