-- NIOGEN | supabase/migrations/0014_mari_contexto_5g.sql | 04/11/2026
-- mari_contexto passa a devolver config_planos.internet_5g (o INTERNAL_DATA da Mari lê o 5G do banco,
-- não do nome do plano). Só a função muda; grants mantidos.

create or replace function public.mari_contexto(
  p_conversa uuid, p_cep text default null, p_numero text default null,
  p_complemento text default null, p_viacep jsonb default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_conv    public.mari_conversas;
  v_cluster text;
  v_planos  jsonb;
  v_dfv     record;
  v_dfvj    jsonb;
  v_cep     text := nullif(regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'), '');
begin
  select * into v_conv from public.mari_conversas where id = p_conversa;
  if not found then return jsonb_build_object('erro', 'conversa inexistente'); end if;

  -- CEP novo: troca o endereço (e zera o que dependia dele).
  if v_cep is not null and v_cep is distinct from v_conv.cep then
    update public.mari_conversas
       set cep = v_cep, numero = null, complemento = null, endereco_cep = null, cidade = null, uf = null,
           cluster = null, dentro_area = null, dfv_resultado = null, dfv_detalhe = null
     where id = p_conversa;
  end if;

  if p_viacep is not null and not coalesce((p_viacep ->> 'erro')::boolean, false) and v_cep is not null then
    update public.mari_conversas
       set endereco_cep = p_viacep,
           cidade = p_viacep ->> 'localidade',
           uf = p_viacep ->> 'uf'
     where id = p_conversa;
  end if;

  if nullif(btrim(coalesce(p_numero, '')), '') is not null then
    update public.mari_conversas set numero = btrim(p_numero) where id = p_conversa
       and numero is distinct from btrim(p_numero);
  end if;
  if p_complemento is not null then
    update public.mari_conversas set complemento = nullif(btrim(p_complemento), '') where id = p_conversa;
  end if;

  select * into v_conv from public.mari_conversas where id = p_conversa;

  if v_conv.cidade is not null then
    v_cluster := public.cluster_da_area(v_conv.cidade, v_conv.uf, v_conv.endereco_cep ->> 'bairro');
    update public.mari_conversas
       set cluster = v_cluster, dentro_area = v_cluster is not null
     where id = p_conversa;
  end if;

  -- DFV (base só de JF): uma vez por endereço.
  if v_conv.cep is not null and v_conv.numero is not null
     and lower(coalesce(v_conv.cidade, '')) = 'juiz de fora'
     and (v_conv.dfv_resultado is null or p_numero is not null or p_complemento is not null) then
    begin
      select * into v_dfv from public.dfv_consultar(v_conv.cep, v_conv.numero, v_conv.complemento);
      v_dfvj := jsonb_strip_nulls(jsonb_build_object(
        'resultado', v_dfv.resultado, 'hp_livre', v_dfv.hp_livre, 'hc_tot', v_dfv.hc_tot, 'hp_tot', v_dfv.hp_tot,
        'tipo_edificacao', v_dfv.tipo_edificacao, 'faixa_credito', v_dfv.faixa_credito,
        'classificacao', v_dfv.classificacao, 'bairro', v_dfv.bairro, 'particao', v_dfv.particao,
        'opcoes', v_dfv.opcoes));
    exception when others then
      v_dfvj := jsonb_build_object('resultado', 'erro', 'erro', sqlerrm);
      insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
      values (p_conversa, 'mari_contexto/dfv', sqlerrm, jsonb_build_object('cep', v_conv.cep, 'numero', v_conv.numero));
    end;
    update public.mari_conversas set dfv_resultado = v_dfvj ->> 'resultado', dfv_detalhe = v_dfvj where id = p_conversa;
  end if;

  select * into v_conv from public.mari_conversas where id = p_conversa;

  if v_conv.cluster is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'codigo', codigo, 'nome', nome, 'portfolio', portfolio, 'variante', variante,
             'velocidade_mb', velocidade_mb, 'wifi', wifi, 'internet_5g', internet_5g, 'inclusos', to_jsonb(inclusos),
             'preco', preco, 'preco_cartao', preco_cartao, 'taxa_habilitacao', taxa_habilitacao,
             'isencao_meses', isencao_meses) order by portfolio desc, variante, preco), '[]'::jsonb)
      into v_planos
      from public.config_planos
     where ativo and cluster = v_conv.cluster
       and (vigencia_fim is null or vigencia_fim >= current_date);
  end if;

  return jsonb_build_object(
    'conversa', to_jsonb(v_conv) - 'processando_ate' - 'ultima_entrada_ts',
    'planos', coalesce(v_planos, '[]'::jsonb));
end;
$$;

revoke execute on function public.mari_contexto(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.mari_contexto(uuid, text, text, text, jsonb) to service_role;
