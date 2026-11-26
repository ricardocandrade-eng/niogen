-- NIOGEN | 0419_area_recalcula_conversas.sql | 26/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (26/11/2026, Parte B do docs/Prompt_area_nacional_niogen_mari_261126_1126.md): "Só os 3 leads".
-- Caso L-382 (Duque de Caxias/RJ): o Reabrir recusava com "o CEP deste lead continua fora da área" porque a conversa guardou
-- dentro_area = false quando o CEP foi consultado (25/11), antes da área nacional (0417). _funil_calcular lê esse retrato e
-- dá regra dura fora_area. Nada recalculava o retrato quando a área mudava. O L-228 (São Paulo) tinha o mesmo, mais
-- elegibilidade = fora_area. O L-276 (Cabo Frio, sem cidade gravada) não tinha trava.
-- O que faz:
--   1. public._area_recalcular_conversas(uf): LIBERA — a conversa cuja cidade agora vende passa a dentro_area = true com o cluster
--      de agora e perde a marca elegibilidade = fora_area. Nunca faz o contrário: desligar área não muda conversa que já existe
--      (mudaria a situação de lead com venda em andamento por fora da porta); a venda nova lá é barrada pelo trigger da venda. Não reabre ninguém e
--      não mexe em situação, vez ou Chatwoot: o Reabrir continua sendo o clique do time, pela porta (regra 20).
--   2. _area_ativar (0417) chama o recálculo quando LIGA uma UF ou cidade — o lead recusado antes volta a poder ser reaberto.
--   3. Roda uma vez agora (destrava o L-382 e o L-228; os outros 176 já batiam).
--   4. Conferência item 43: conversa marcada fora da área numa cidade que hoje vende (o caso que trava o Reabrir).
-- Regra 20: (1)–(3) o retrato da área é dado derivado (a cidade é o fato), muda por função do banco e não muda estado;
--   (4) a área continua vindo só da config_area; (5) item 43.
begin;

-- 1. Recálculo -----------------------------------------------------------------------------------------------------------------
create or replace function public._area_recalcular_conversas(p_uf text default null, p_area_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_n int; v_lista text[];
begin
  with alvo as (
    select c.id, public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> 'bairro') as cl
      from public.mari_conversas c
     where coalesce(btrim(c.cidade), '') <> ''
       and (p_uf is null or upper(coalesce(c.uf, 'MG')) = upper(btrim(p_uf)))
       and (p_area_id is null or exists (select 1 from public.config_area a where a.id = p_area_id
                                          and upper(a.uf) = upper(coalesce(c.uf, 'MG'))
                                          and public.area_norm(a.cidade) = public.area_norm(c.cidade)))),
  muda as (
    update public.mari_conversas c
       set cluster = alvo.cl,
           dentro_area = true,
           elegibilidade = case when c.elegibilidade = 'fora_area' then null else c.elegibilidade end
      from alvo
     where c.id = alvo.id
       and alvo.cl is not null
       and (c.dentro_area is distinct from true or c.cluster is distinct from alvo.cl or c.elegibilidade = 'fora_area')
    returning c.lead_numero, c.cidade, c.uf)
  select count(*), array_agg('L-' || lead_numero || ' ' || cidade || '/' || coalesce(uf, '?')
                              order by lead_numero)
    into v_n, v_lista from muda;
  return jsonb_build_object('conversas', v_n, 'quais', to_jsonb(coalesce(v_lista, '{}')));
end $$;
revoke all on function public._area_recalcular_conversas(text, bigint) from public, anon, authenticated;
comment on function public._area_recalcular_conversas(text, bigint) is
  '0419: libera a conversa cuja cidade agora vende (dentro_area, cluster, sem elegibilidade fora_area). Nunca marca fora. Não reabre lead.';

-- 2. _area_ativar recalcula o que mudou (mesma assinatura e mesmo retorno da 0417, com a chave "conversas") -----------------
create or replace function public._area_ativar(p_uf text, p_area_id bigint, p_ativa boolean, p_motivo text, p_autor text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare n int; r jsonb;
begin
  if p_ativa is null or coalesce(btrim(p_motivo), '') = '' then
    raise exception 'Diga se liga ou desliga e o motivo.' using errcode = 'P0001';
  end if;
  with alvo as (
    select a.id, a.uf, a.cidade, a.ativo from public.config_area a
     where (p_area_id is not null and a.id = p_area_id)
        or (p_area_id is null and upper(a.uf) = upper(btrim(p_uf)))
     for update),
  muda as (
    update public.config_area a set ativo = p_ativa from alvo
     where a.id = alvo.id and a.ativo is distinct from p_ativa
     returning a.id, a.uf, a.cidade, alvo.ativo as de)
  insert into public.area_ativa_hist (area_id, uf, cidade, de, para, motivo, autor)
  select id, uf, cidade, de, p_ativa, btrim(p_motivo), p_autor from muda;
  get diagnostics n = row_count;
  r := case when n > 0 and p_ativa then public._area_recalcular_conversas(case when p_area_id is null then p_uf end, p_area_id)
            else jsonb_build_object('conversas', 0) end;
  return jsonb_build_object('mudaram', n,
    'ativas_na_uf', (select count(*) from public.config_area a
                      where a.ativo and upper(a.uf) = upper(coalesce(btrim(p_uf), (select uf from public.config_area where id = p_area_id)))),
    'conversas_recalculadas', r -> 'conversas');
end $$;
revoke all on function public._area_ativar(text, bigint, boolean, text, text) from public, anon, authenticated;

-- 3. Uma vez agora -------------------------------------------------------------------------------------------------------------
do $$
declare r jsonb := public._area_recalcular_conversas(null, null);
begin
  raise notice '0419: retrato da área refeito em % conversa(s): %', r ->> 'conversas', r -> 'quais';
end $$;

-- 4. Conferência: item 43 ------------------------------------------------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('''area_retrato_conversa''' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0419: conferencia_itens mudou — refazer o item do retrato da área a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 43. 0419 — Área: a conversa diz "dentro/fora da área" igual à área de hoje (retrato velho trava o Reabrir — caso L-382)
  select count(*)::int, string_agg(''L-'' || c.lead_numero || '' '' || c.cidade, '', '' order by c.lead_numero) into n, ex
    from public.mari_conversas c
   where coalesce(btrim(c.cidade), '''') <> ''''
     and (c.dentro_area is false or c.elegibilidade = ''fora_area'')
     and public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> ''bairro'') is not null;
  it := it || jsonb_build_object(''codigo'', ''area_retrato_conversa'', ''nome'', ''Área: nenhuma conversa marcada fora numa cidade que vende'',
    ''nivel'', case when n = 0 then ''ok'' else ''falha'' end, ''n'', n,
    ''texto'', case when n = 0 then ''nenhuma conversa marcada fora da área numa cidade que hoje vende''
                    else format(''%s conversa(s) marcada(s) fora da área numa cidade que vende: %s'', n, left(ex, 300)) end,
    ''fazer'', case when n = 0 then null else ''Avisar o Claude Code: rodar _area_recalcular_conversas() — o Reabrir recusa lead com retrato velho.'' end);

  return it;
end');
  execute d;
end $$;

-- 5. Conferência final ---------------------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.mari_conversas c
              where coalesce(btrim(c.cidade), '') <> ''
                and (c.dentro_area is false or c.elegibilidade = 'fora_area')
                and public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> 'bairro') is not null) then
    raise exception '0419: ainda há conversa marcada fora da área numa cidade que vende';
  end if;
end $$;

commit;
