-- NIOGEN | supabase/migrations/0408_agente_trafego_dono_campanha.sql | 25/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo, 25/11 ~21h ("Sim, põe a trava"): o agente de tráfego só mexe em campanha da Dharma. O retrato que ele lê
-- (agente_trafego_retrato, gravado de 30 em 30 min em agente/funil_agente_trafego.json) passa a dizer o DONO de cada campanha,
-- vindo de meta_ads_campanhas_dono (0406, Configurações › Agência): 'dharma', 'agencia' ou 'sem_dono'.
--   por_anuncio[] e por_conjunto[]: + campanha_id e dono · chave nova campanhas_dono: [{campanha_id, campanha, dono}]
-- A função é mexida por várias migrations: o trecho entra por troca de texto na versão que estiver no ar (como 0369/0406), e
-- recusa se ela mudou de forma. Nada muda nos números: só campos novos.
-- Regra 20: (1) nenhum estado novo · (2)/(3) não se aplica (só leitura) · (4) o dono tem uma fonte só (meta_ads_campanhas_dono) ·
-- (5) a conferência da 0406 já acusa campanha sem dono há mais de 24 h.
begin;

do $$
declare d text := pg_get_functiondef('public.agente_trafego_retrato(integer)'::regprocedure);
  a1 text := $q$'campanha', a.campanha_nome, 'status', a.status_efetivo,$q$;
  a2 text := $q$select a.adset_nome, a.campanha_nome from public.meta_ads_anuncios a$q$;
  a3 text := $q$'campanha', c.campanha_nome,$q$;
  a4 text := $q$|| public._agente_trafego_cobertura(jan.de)$q$;
  conta int;
begin
  if position('campanhas_dono' in d) > 0 then return; end if;
  foreach conta in array array[
      (length(d) - length(replace(d, a1, ''))) / length(a1), (length(d) - length(replace(d, a2, ''))) / length(a2),
      (length(d) - length(replace(d, a3, ''))) / length(a3), (length(d) - length(replace(d, a4, ''))) / length(a4)] loop
    if conta <> 1 then raise exception '0408: agente_trafego_retrato mudou — refazer o trecho do dono a partir da versão no ar'; end if;
  end loop;
  d := replace(d, a1, $q$'campanha', a.campanha_nome, 'campanha_id', a.campanha_id,
                                          'dono', coalesce((select dn.dono from public.meta_ads_campanhas_dono dn where dn.campanha_id = a.campanha_id), 'sem_dono'),
                                          'status', a.status_efetivo,$q$);
  d := replace(d, a2, $q$select a.adset_nome, a.campanha_nome, a.campanha_id from public.meta_ads_anuncios a$q$);
  d := replace(d, a3, $q$'campanha', c.campanha_nome, 'campanha_id', c.campanha_id,
                                          'dono', coalesce((select dn.dono from public.meta_ads_campanhas_dono dn where dn.campanha_id = c.campanha_id), 'sem_dono'),$q$);
  d := replace(d, a4, $q$|| jsonb_build_object('campanhas_dono', coalesce((   -- 0408: o agente só mexe em dono 'dharma'
         select jsonb_agg(jsonb_build_object('campanha_id', dn.campanha_id, 'campanha', dn.campanha_nome, 'dono', coalesce(dn.dono, 'sem_dono'))
                          order by dn.campanha_nome)
           from public.meta_ads_campanhas_dono dn), '[]'::jsonb))
  || public._agente_trafego_cobertura(jan.de)$q$);
  execute d;
end $$;

commit;
