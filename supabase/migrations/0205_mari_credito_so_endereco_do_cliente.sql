-- NIOGEN | supabase/migrations/0205_mari_credito_so_endereco_do_cliente.sql | 15/11/2026 — Claude Code / Opus 5.5
-- Ricardo (15/11 ~00h20): "A Mari não pode usar endereço padrão, eu acho. Isso é apenas para a tela Cobertura, para casos que queremos
-- ver se o CPF aprova." A 0204 já mandava o endereço do cliente quando viável, mas ainda caía no endereço padrão sem viabilidade.
-- Agora a mari_credito_pendentes só pega conversa com CEP + número e viabilidade VIÁVEL — o pedido ao operador sempre leva o
-- endereço do cliente, nunca o padrão. Conversa sem viabilidade viável fica sem consulta automática de crédito (o time consulta
-- pela ficha quando fizer sentido). Corpo = 0204 com só esse trecho trocado.

create or replace function public.mari_credito_pendentes(p_limite integer default 1)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v jsonb;
begin
  with alvo as (
    select c.id from public.mari_conversas c
     where c.credito_em is null and c.credito_consultas < 2
       and public._cpf_ok(c.dados->>'cpf')
       and coalesce(c.dados->>'email', '') ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
       and coalesce(c.dados->>'email_confirmado', '') <> 'false'
       and coalesce(c.nao_contatar, false) = false
       and coalesce(c.telefone, '') !~ '^55000000'
       and c.updated_at > now() - interval '12 hours'
       -- 0205 (Ricardo, 15/11: "a Mari não pode usar endereço padrão — isso é só para a tela Cobertura"): a Mari só consulta
       -- crédito com o ENDEREÇO DO CLIENTE e só depois da viabilidade dar VIÁVEL. Sem isso, não consulta (o time decide).
       and regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') ~ '^\d{8}$' and nullif(btrim(coalesce(c.numero, '')), '') is not null
       and (c.cobertura_decisao = 'viavel' or c.nio_viab_resultado = 'viavel')
       and (select count(distinct regexp_replace(o.dados->>'cpf', '\D', '', 'g')) from public.mari_conversas o
             where o.telefone = c.telefone and o.credito_consultas > 0 and o.credito_em > now() - interval '7 days'
               and regexp_replace(o.dados->>'cpf', '\D', '', 'g') <> regexp_replace(c.dados->>'cpf', '\D', '', 'g')) < 3
     order by c.updated_at
     limit greatest(1, least(p_limite, 2))
     for update skip locked
  ), marcadas as (
    update public.mari_conversas c set credito_consultas = c.credito_consultas + 1, credito_em = now(),
           credito_autorizado_em = coalesce(c.credito_autorizado_em, now()),
           credito_autorizacao_frase = coalesce(c.credito_autorizacao_frase, 'automática — sem pergunta (Ricardo, 12/11)')
      from alvo where c.id = alvo.id
    returning c.id, c.dados, c.telefone, c.cep, c.numero, c.complemento, c.endereco_cep,
              (c.cobertura_decisao = 'viavel' or c.nio_viab_resultado = 'viavel') as viavel
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'conversa_id', id,
           'cpf', regexp_replace(dados->>'cpf', '\D', '', 'g'),
           'celular', right(regexp_replace(coalesce(dados->>'telefone', telefone, ''), '\D', '', 'g'), 11),
           'email', lower(dados->>'email'),
           -- 0204: endereço do cliente quando viável (null → o operador usa o endereço padrão e o resultado sai marcado)
           'endereco', case when true and regexp_replace(coalesce(cep, ''), '\D', '', 'g') ~ '^\d{8}$' and nullif(btrim(coalesce(numero, '')), '') is not null
             then jsonb_build_object('cep', regexp_replace(cep, '\D', '', 'g'), 'numero', btrim(numero),
                    'complemento', case when complemento ~* '(ap|apto|apartamento|bloco|bl|sala|loja|casa\s+[a-z0-9]\b|fundos|\d)'
                                         and complemento !~* '^\s*(casa|nenhum|nao|não|sem)\s*$' then left(btrim(complemento), 60) else '' end,
                    'referencia', left(coalesce(nullif(btrim(dados->>'referencia'), ''), 'Sem referência'), 80),
                    'logradouro_esperado', left(coalesce(nullif(btrim(dados->>'rua_confirmada'), ''), nullif(btrim(dados->>'rua_informada'), ''),
                                                         endereco_cep->>'logradouro', ''), 120)) end))), '[]'::jsonb)
    into v from marcadas;
  return v;
end $function$;
revoke all on function public.mari_credito_pendentes(integer) from public, anon, authenticated;
grant execute on function public.mari_credito_pendentes(integer) to service_role;
