-- NIOGEN | supabase/migrations/0137_teto_operador_distintos.sql | 12/11/2026 — Claude Code
-- Teste real do Ricardo (12/11 ~09h10, o número dele): a conversa nova não foi consultada — o teto por telefone (0133) contava
-- CONVERSAS (3 em 7 dias, todas do mesmo endereço, testes da madrugada). O teto passa a contar o que é abuso de verdade:
-- 3 ENDEREÇOS diferentes (viabilidade) e 3 CPFs diferentes (duplicidade) por telefone em 7 dias. Teto por conversa igual.

create or replace function public.mari_viab_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  -- Teto por telefone: mais de 3 conversas consultadas em 7 dias → não consulta (marca para não voltar à fila).
  -- 0137: conta ENDEREÇOS diferentes (CEP+nº), não conversas — quem volta ao mesmo endereço não pesa (teste do Ricardo, 12/11 09h).
  update public.mari_conversas c set nio_viab_em = now(), cobertura_decisao = 'indefinida',
         cobertura_detalhe = jsonb_build_object('teto', 'telefone: 3 endereços diferentes consultados em 7 dias'), cobertura_em = now()
   where c.nio_viab_em is null and c.updated_at > now() - interval '12 hours'
     and (select count(distinct (regexp_replace(coalesce(o.cep, ''), '\D', '', 'g'), btrim(coalesce(o.numero, ''))))
            from public.mari_conversas o
           where o.telefone = c.telefone and o.viab_consultas > 0 and o.cobertura_em > now() - interval '7 days'
             and (regexp_replace(coalesce(o.cep, ''), '\D', '', 'g'), btrim(coalesce(o.numero, '')))
                 is distinct from (regexp_replace(coalesce(c.cep, ''), '\D', '', 'g'), btrim(coalesce(c.numero, '')))) >= 3;
  with alvo as (
    select c.id from public.mari_conversas c
     where regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') ~ '^\d{8}$'
       and nullif(btrim(coalesce(c.numero, '')), '') is not null
       and c.nio_viab_em is null
       and c.viab_consultas < 3                       -- teto por conversa: 3 endereços
       and coalesce(c.telefone, '') !~ '^55000000'    -- telefones de teste (bateria) nunca vão ao operador
       and coalesce(c.nao_contatar, false) = false
       and coalesce(c.dentro_area, true)
       and c.updated_at > now() - interval '12 hours'
       and (c.venda_id is null or c.handoff_em > now() - interval '12 hours')
     order by c.updated_at desc
     limit greatest(1, least(p_limite, 5))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set nio_viab_em = now(), viab_consultas = c.viab_consultas + 1
      from alvo where c.id = alvo.id
    returning c.id, c.cep, c.numero, c.complemento, c.cidade, c.uf
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'conversa_id', id,
           'cep', regexp_replace(cep, '\D', '', 'g'),
           'numero', btrim(numero),
           'complemento', case when complemento ~* '(ap|apto|apartamento|bloco|bl|sala|loja|casa\s+[a-z0-9]\b|fundos|\d)' and complemento !~* '^\s*(casa|nenhum|nao|não|sem)\s*$'
                               then left(btrim(complemento), 60) else '' end,
           'uf', coalesce(uf, 'MG'), 'municipio', upper(coalesce(cidade, '')))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_viab_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_viab_pendentes(int) to service_role;

create or replace function public.mari_dup_pendentes(p_limite int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where public._cpf_ok(c.dados->>'cpf')
       and c.plano_escolhido is not null
       and c.nio_pedido_aberto_em is null
       and c.dup_consultas < 1
       and coalesce(c.telefone, '') !~ '^55000000'
       and coalesce(c.nao_contatar, false) = false
       and c.updated_at > now() - interval '12 hours'
       and (c.venda_id is null or c.handoff_em > now() - interval '12 hours')
       -- 0137: CPFs diferentes por telefone (o mesmo CPF volta pelo cache de 24 h do operador e não pesa)
       and (select count(distinct regexp_replace(o.dados->>'cpf', '\D', '', 'g')) from public.mari_conversas o
             where o.telefone = c.telefone and o.dup_consultas > 0 and o.nio_pedido_aberto_em > now() - interval '7 days'
               and regexp_replace(o.dados->>'cpf', '\D', '', 'g') <> regexp_replace(c.dados->>'cpf', '\D', '', 'g')) < 3
     order by c.updated_at desc
     limit greatest(1, least(p_limite, 3))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set nio_pedido_aberto_em = now(), dup_consultas = c.dup_consultas + 1
      from alvo where c.id = alvo.id
    returning c.id, c.dados->>'cpf' cpf
  )
  select coalesce(jsonb_agg(jsonb_build_object('conversa_id', id, 'cpf', regexp_replace(cpf, '\D', '', 'g'))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $$;
revoke all on function public.mari_dup_pendentes(int) from public, anon, authenticated;
grant execute on function public.mari_dup_pendentes(int) to service_role;
