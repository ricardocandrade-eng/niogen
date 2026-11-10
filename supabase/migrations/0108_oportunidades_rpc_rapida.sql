-- NIOGEN | supabase/migrations/0108_oportunidades_rpc_rapida.sql | 10/11/2026 — Claude Code
-- Medido no Pages (10/11): a v_oportunidades lida pelo navegador (security_invoker → RLS da mari_conversas/mari_turnos linha a
-- linha dentro da v_mari_quadro) leva ~6 s; a mesma conta como definer (dentro do mari_ao_vivo) leva < 1 s. O menu lê as
-- oportunidades a cada minuto em todas as telas → RPC oportunidades_abertas() SECURITY DEFINER com a porta de perfil
-- admin/backoffice (a mesma das RPCs da 0107). A view continua para uso interno e para o ensaio. Só aditivo.
create or replace function public.oportunidades_abertas()
returns setof public.v_oportunidades
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return;
  end if;
  return query select * from public.v_oportunidades order by ordem;
end $$;
revoke all on function public.oportunidades_abertas() from public, anon;
grant execute on function public.oportunidades_abertas() to authenticated;
