-- NIOGEN | supabase/migrations/0076_ficha_unica_avisos.sql | 09/11/2026 — Claude Code (Prompt_rodada_noturna_ondas2e3_091126_0100, item 4 · onda 3.1 fase 1)
-- Por quê: a mesma pessoa pode entrar duas vezes (Mari + venda de rua, CPF diferente no mesmo endereço, venda que saiu e voltou).
--          Pelo contrato, recompra = multa R$ 500 e cliente/endereço já Nio = estorno 100 %. Fase 1 = SÓ AVISO: nada bloqueia.
-- O quê (só aditivo):
--   1. Chaves normalizadas: doc_norm (CPF/CNPJ só dígitos), tel_e164 (+55 DDD 9 XXXX-XXXX), end_chave (CEP + número + complemento).
--   2. ficha_avisos(venda | doc, tel, cep, número, complemento) → {bloquear, selos[]}: cruza vendas (ativas e em Saída, com a situação
--      do OSAB do pedido), mari_conversas (mesmo telefone) e a base DFV (endereço com Nio = endereco_ocupado). A Fila Vero ainda não tem
--      tabela no Supabase (vive no clone GAS) — entra quando a ingestão for reescrita.
--   3. config_regras.bloquear_duplicado = false (a trava antes do pedido é a fase 2, com o OK do Ricardo).
-- Núcleo (não depende da Mari): sem conversas, os outros selos funcionam igual.

create or replace function public.doc_norm(p text)
returns text language sql immutable set search_path = '' as $$
  select case when length(d) in (11, 14) then d end
    from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$$;

-- Telefone em E.164 com o 9: aceita "(32) 9 9999-0000", "32999990000", "5532999990000", "553299990000" (celular antigo sem o 9).
create or replace function public.tel_e164(p text)
returns text language sql immutable set search_path = '' as $$
  select case
    when d is null then null
    when length(d) = 13 and d like '55%' then '+' || d
    when length(d) = 12 and d like '55%' and substr(d, 5, 1) in ('6', '7', '8', '9') then '+' || substr(d, 1, 4) || '9' || substr(d, 5)
    when length(d) = 12 and d like '55%' then '+' || d          -- fixo
    else null end
  from (select case
                 when length(x) in (10, 11) then '55' || x
                 else nullif(x, '') end as d
          from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as x) a) b
$$;

create or replace function public.end_chave(p_cep text, p_numero text, p_complemento text default null)
returns text language sql immutable set search_path = '' as $$
  select case when length(c) = 8 and n <> '' then c || '|' || n || '|' || coalesce(k, '') end
    from (select regexp_replace(coalesce(p_cep, ''), '\D', '', 'g') as c,
                 upper(regexp_replace(coalesce(p_numero, ''), '[^[:alnum:]]', '', 'g')) as n,
                 nullif(upper(regexp_replace(coalesce(p_complemento, ''), '[^[:alnum:]]', '', 'g')), '') as k) x
$$;
grant execute on function public.doc_norm(text), public.tel_e164(text), public.end_chave(text, text, text) to authenticated, service_role;

insert into public.config_regras (chave, valor, descricao) values
  ('bloquear_duplicado', 'false', 'Ficha única: false = só aviso (fase 1). true = trava antes do pedido (fase 2, precisa do OK do Ricardo — recompra R$ 500, estorno 100 %)')
on conflict (chave) do nothing;

create or replace function public.ficha_avisos(
  p_venda uuid default null, p_doc text default null, p_tel text default null,
  p_cep text default null, p_numero text default null, p_complemento text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v public.vendas%rowtype;
  k_doc text; k_tel text; k_cep text; k_num text; k_comp text;
  ve_nome boolean := public.meu_perfil() in ('admin', 'backoffice');
  selos jsonb := '[]'::jsonb;
  r record; n int; dfv text; c record;
  etapa jsonb := '{"0_qualificado":"Qualificado","1_vendido":"Vendido","2_aguardando_instalacao":"Aguardando instalação","3_instalado":"Instalado","4_ativo_provisorio":"Ativo","5_comissao_firme":"Ativo"}';
begin
  if auth.role() is distinct from 'service_role' and public.meu_perfil() is null and auth.uid() is not null then
    return null;
  end if;
  if p_venda is not null then
    select * into v from public.vendas where id = p_venda;
    p_doc := coalesce(p_doc, v.cliente_cpf_cnpj);
    p_tel := coalesce(p_tel, v.cliente_whatsapp);
    p_cep := coalesce(p_cep, v.cep);
    p_numero := coalesce(p_numero, v.numero);
    p_complemento := coalesce(p_complemento, v.complemento);
  end if;
  k_doc := public.doc_norm(p_doc);
  k_tel := public.tel_e164(p_tel);
  k_cep := nullif(regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'), '');
  k_num := nullif(upper(regexp_replace(coalesce(p_numero, ''), '[^[:alnum:]]', '', 'g')), '');
  k_comp := public.dfv_comp_norm(p_complemento);
  if length(coalesce(k_cep, '')) <> 8 then k_cep := null; end if;

  -- 1 e 2. Outras vendas com o mesmo CPF/CNPJ, telefone ou endereço (mesmo complemento, ou um dos dois sem complemento).
  for r in
    select x.*, o.situacao as osab_situacao,
           (select max(e.criado_em) from public.eventos_venda e
             where e.venda_id = x.id and e.tipo = 'status' and e.detalhe->>'para' = 'saida') as saida_em
      from (select vv.id, vv.cliente_nome, vv.status, vv.motivo_saida, vv.nio_pedido, vv.criado_em,
                   (k_doc is not null and public.doc_norm(vv.cliente_cpf_cnpj) = k_doc) as m_doc,
                   (k_tel is not null and public.tel_e164(vv.cliente_whatsapp) = k_tel) as m_tel,
                   (k_cep is not null and k_num is not null
                    and regexp_replace(coalesce(vv.cep, ''), '\D', '', 'g') = k_cep
                    and upper(regexp_replace(coalesce(vv.numero, ''), '[^[:alnum:]]', '', 'g')) = k_num
                    and (k_comp is null or public.dfv_comp_norm(vv.complemento) is null or public.dfv_comp_norm(vv.complemento) = k_comp)) as m_end
              from public.vendas vv
             where vv.id is distinct from p_venda) x
      left join public.nio_osab o on o.pedido = x.nio_pedido
     where x.m_doc or x.m_tel or x.m_end
     order by (x.status = 'saida'), x.criado_em desc
     limit 10
  loop
    declare
      quem text := case when ve_nome then coalesce(split_part(btrim(r.cliente_nome), ' ', 1), 'cliente') else 'outro cliente' end;
      porque text := array_to_string(array_remove(array[
        case when r.m_doc then 'mesmo CPF/CNPJ' end, case when r.m_tel then 'mesmo telefone' end, case when r.m_end then 'mesmo endereço' end], null), ', ');
      osab text := case when r.osab_situacao is not null then ' · OSAB: ' || r.osab_situacao else '' end;
    begin
      if r.status = 'saida' then
        selos := selos || jsonb_build_object('tipo', 'saida', 'nivel', 'warn', 'venda_id', r.id,
          'texto', format('Já existe venda em Saída há %s dia%s (%s%s) · %s%s',
                          greatest(0, (current_date - coalesce(r.saida_em, r.criado_em)::date)),
                          case when greatest(0, (current_date - coalesce(r.saida_em, r.criado_em)::date)) = 1 then '' else 's' end,
                          quem, coalesce(', ' || r.motivo_saida, ''), porque, osab));
      else
        selos := selos || jsonb_build_object('tipo', 'duplicado', 'nivel', 'bad', 'venda_id', r.id,
          'texto', format('Possível duplicado (venda de %s, etapa %s) · %s%s', quem, coalesce(etapa->>r.status, r.status), porque, osab));
      end if;
    end;
  end loop;

  -- 3. Endereço com Nio ativo na base DFV (a mesma resposta da consulta da tela Cobertura).
  if k_cep is not null and k_num is not null then
    begin
      select d.resultado into dfv from public.dfv_consultar(k_cep, p_numero, p_complemento) d limit 1;
    exception when others then dfv := null;
    end;
  end if;
  if dfv = 'endereco_ocupado' or (p_venda is not null and v.dfv_resultado = 'endereco_ocupado') then
    selos := selos || jsonb_build_object('tipo', 'dfv', 'nivel', 'bad',
      'texto', 'Endereço com Nio ativo (DFV) · cliente/endereço já na base Nio = estorno 100 % — conferir no portal antes do pedido');
  end if;

  -- 4. Mesmo telefone em outra conversa da Mari (fora a conversa desta venda; conversas de teste não contam).
  if k_tel is not null then
    select count(*) as n, max(mc.updated_at) as ult,
           (array_agg(mc.id order by mc.updated_at desc))[1] as id,
           (array_agg(mc.status order by mc.updated_at desc))[1] as status
      into c
      from public.mari_conversas mc
     where public.tel_e164(mc.telefone) = k_tel
       and coalesce(mc.canal, '') <> 'teste'
       and (p_venda is null or mc.venda_id is distinct from p_venda);
    if c.n > 0 then
      selos := selos || jsonb_build_object('tipo', 'telefone', 'nivel', 'warn', 'conversa_id', case when ve_nome then c.id end,
        'texto', case when c.n > 1 then format('Mesmo telefone em %s outras conversas da Mari (a última: %s)', c.n, replace(coalesce(c.status, '—'), '_', ' '))
                      else format('Mesmo telefone em outra conversa da Mari (%s)', replace(coalesce(c.status, '—'), '_', ' ')) end);
    end if;
  end if;

  return jsonb_build_object(
    'bloquear', coalesce((public.config_regra('bloquear_duplicado', 'false'))::text = 'true', false),
    'chaves', jsonb_build_object('doc', k_doc is not null, 'tel', k_tel is not null, 'endereco', k_cep is not null and k_num is not null),
    'selos', selos);
end $$;
revoke all on function public.ficha_avisos(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.ficha_avisos(uuid, text, text, text, text, text) to authenticated, service_role;
