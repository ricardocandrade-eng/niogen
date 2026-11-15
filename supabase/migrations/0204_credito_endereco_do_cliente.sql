-- NIOGEN | supabase/migrations/0204_credito_endereco_do_cliente.sql | 15/11/2026 — Claude Code / Opus 5.5
-- Ricardo (14/11 ~23h10, "isso é gravíssimo"): Helton — o NIOGEN mostrou crédito APROVADO (todas as formas) e o portal, na mão,
-- "Negado - Critérios Antifraude". Causa: a consulta automática da Mari usa o ENDEREÇO PADRÃO (o do escritório) e a análise
-- antifraude da Nio olha o endereço; e o cache do operador (só por CPF) devolveu essa resposta à consulta da ficha feita com o
-- endereço do cliente (corrigido em portal/servico.py). Aqui:
--   1. mari_conversas.credito_endereco ('cliente' | 'padrao'): com que endereço o crédito da Mari foi lido.
--   2. mari_credito_pendentes: espera a viabilidade decidir (cobertura_decisao) e, se o endereço do cliente é viável, manda o
--      ENDEREÇO DO CLIENTE (CEP, número, complemento só se for unidade, rua esperada). Sem viabilidade → endereço padrão, marcado.
--   3. mari_credito_gravar: grava credito_endereco; a nota no Chatwoot e o operador_consultas dizem quando foi o endereço padrão
--      ("APROVADO NO ENDEREÇO PADRÃO — confirmar no endereço do cliente antes do pedido").
--   4. Acerto: todo crédito da Mari gravado até aqui foi lido com o endereço padrão → credito_endereco = 'padrao'.
-- Corpos = produção (pg_get_functiondef em 15/11) com os trechos marcados 0204.

alter table public.mari_conversas add column if not exists credito_endereco text
  check (credito_endereco is null or credito_endereco in ('cliente', 'padrao'));
comment on column public.mari_conversas.credito_endereco is
  '0204: endereço usado na consulta de crédito da Mari. padrao = endereço do escritório: o resultado NÃO vale para o endereço do cliente (antifraude da Nio olha o endereço).';

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
       -- 0204: com endereço informado, espera a viabilidade decidir (o crédito sai com o endereço do cliente quando ele é viável)
       and (c.cep is null or c.numero is null or c.cobertura_decisao is not null or c.nio_viab_em < now() - interval '30 minutes')
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
           'endereco', case when viavel and regexp_replace(coalesce(cep, ''), '\D', '', 'g') ~ '^\d{8}$' and nullif(btrim(coalesce(numero, '')), '') is not null
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

create or replace function public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_op text := p_saida->>'resultado'; v text; c record;
        v_end text := case when p_saida->'endereco'->>'origem' = 'cliente' then 'cliente' when p_saida->'endereco'->>'origem' = 'padrao' then 'padrao' end;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(), credito_endereco = v_end,
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' else nio_pedido_aberto end
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada', 'endereco', v_end,
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null) then
    insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload, status)
    values (gen_random_uuid(), 1, 'credito', c.venda_id, p_conversa, c.chatwoot_conversation_id, 'nota',
            jsonb_build_object('content', '💳 Crédito (consulta automática da Mari, autorizada pelo cliente'
              || coalesce(' em ' || to_char(c.credito_autorizado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '') || '): '
              || case v when 'aprovado_todas' then 'APROVADO — todas as formas'
                        when 'aprovado_parcial' then 'APROVADO — formas: ' || coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(p_saida->'formas_liberadas') x), '?')
                        when 'aprovado_cartao' then 'APROVADO SÓ NO CARTÃO — se o cliente não usa cartão, outra pessoa da casa pode ser a titular'
                        when 'pendente' then 'PENDENTE (a Nio responde em até 24 h)'
                        when 'negado' then 'NEGADO neste CPF'
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF — conferir antes de abrir outro (recompra = multa R$ 500)'
                        else 'o portal não decidiu — consultar na Cobertura' end
              -- 0204: lido no endereço padrão → não vale para o endereço do cliente
              || case when v_end = 'padrao' and v like 'aprovado%' then ' · ⚠ LIDO NO ENDEREÇO PADRÃO (não o do cliente): CONFIRME o crédito no endereço do cliente antes do pedido — a análise antifraude da Nio olha o endereço' else '' end
              || '. Grave o resultado na ficha.'), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v, 'endereco', v_end);
end $function$;
revoke all on function public.mari_credito_gravar(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.mari_credito_gravar(uuid, jsonb) to service_role;

-- 4. Acerto: até aqui a Mari sempre consultou com o endereço padrão (mari_credito_pendentes não mandava endereço).
update public.mari_conversas set credito_endereco = 'padrao'
 where credito_resultado is not null and credito_endereco is null
   and exists (select 1 from public.operador_consultas o where o.conversa_id = mari_conversas.id and o.tipo = 'credito' and o.origem = 'mari');
