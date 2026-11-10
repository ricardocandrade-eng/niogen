-- NIOGEN | supabase/migrations/0099_mari_rodada_unica.sql | 10/11/2026 — Claude Code
-- Prompt docs/Prompt_mari_rodada_unica_091126_2350.md (partes 4, 5 e 7). O que já existia e NÃO muda: config_feriados com
-- 20/11, 25/12 e 01/01 (nacionais), a cadência da Mari já parando em feriado (mari_dia_permitido → mari_janela_dia →
-- mari_no_horario / mari_cadencia_avaliar) e o venda_id na v_mari_cadencia (pendência 40 já resolvida).
--   1. config_feriados: parceiro_id (regra 15) e escopo 'estadual' (UF) — feriados municipais das 38 cidades: o Ricardo completa.
--   2. mari_contexto devolve 'no_horario' (horário do contrato COM feriado, pela cidade da conversa) — o motor da Mari usa
--      para o prazo do consultor ("no próximo horário de atendimento" em feriado). A Mari continua respondendo quem escreve.
--   3. painel_meta_ritmo: "faltam N em D dias" conta só dias de contato (sem domingo e sem feriado) — dias úteis.
--   4. Termômetro (tela Mari): o item "Telefone confirmado" passa a exigir dados.telefone_confirmado (o motor grava desde
--      esta rodada). Conversas antigas com o telefone igual ao do WhatsApp ganham a marca (é o próprio número).
--   5. Abertura B2 (texto aprovado 09/11 ~00h15): 💚 na saudação e linhas em branco no "Ver minha rua".

-- ───────── 1. feriados ─────────
alter table public.config_feriados add column if not exists parceiro_id text not null default 'dharma';
alter table public.config_feriados drop constraint if exists config_feriados_escopo_check;
alter table public.config_feriados add constraint config_feriados_escopo_check check (escopo in ('nacional', 'estadual', 'municipal'));
comment on table public.config_feriados is 'Feriados sem toque ativo (cadência, régua, lembretes). escopo: nacional · estadual (uf) · municipal (cidade). A área de atuação é toda MG: estadual vale para UF = MG.';

insert into public.config_feriados (data, nome, escopo, cidade, uf) values
  ('2026-11-20', 'Dia Nacional de Zumbi e da Consciência Negra', 'nacional', '', null),
  ('2026-12-25', 'Natal', 'nacional', '', null),
  ('2027-01-01', 'Confraternização Universal', 'nacional', '', null)
on conflict (data, escopo, cidade) do nothing;

create or replace function public.mari_dia_permitido(p_dia date, p_cidade text default null::text)
returns boolean language sql stable set search_path to 'public' as $function$
  select extract(isodow from p_dia) <> 7
     and not exists (select 1 from public.config_feriados f
                      where f.data = p_dia
                        and (f.escopo = 'nacional'
                             or (f.escopo = 'estadual' and upper(coalesce(f.uf, 'MG')) = 'MG')
                             or (f.escopo = 'municipal' and lower(f.cidade) = lower(btrim(coalesce(p_cidade, ''))))))
$function$;

create or replace function public.proximo_dia_util(p_data date, p_cidade text default 'Juiz de Fora'::text)
returns date language plpgsql stable set search_path to 'public' as $function$
declare
  d date := p_data + 1;
  i int := 0;
begin
  while i < 40 loop
    if extract(isodow from d) < 6
       and not exists (select 1 from public.config_feriados f
                        where f.data = d
                          and (f.escopo = 'nacional'
                               or (f.escopo = 'estadual' and upper(coalesce(f.uf, 'MG')) = 'MG')
                               or (f.escopo = 'municipal' and lower(f.cidade) = lower(btrim(coalesce(p_cidade, '')))))) then
      return d;
    end if;
    d := d + 1;
    i := i + 1;
  end loop;
  return d;
end;
$function$;

-- ───────── 2. mari_contexto + no_horario ─────────
create or replace function public.mari_contexto(p_conversa uuid, p_cep text default null::text, p_numero text default null::text,
  p_complemento text default null::text, p_viacep jsonb default null::jsonb)
returns jsonb language plpgsql set search_path to 'public' as $function$
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
    'planos', coalesce(v_planos, '[]'::jsonb),
    -- 0099: horário do contrato agora (seg–sex 9–21, sáb 10–16, sem domingo nem feriado da cidade) — prazo do consultor.
    'no_horario', public.mari_no_horario(now(), v_conv.cidade));
end;
$function$;

-- ───────── 3. Painel: dias úteis no ritmo da meta ─────────
create or replace function public.painel_meta_ritmo(p_hoje date default ((now() at time zone 'America/Sao_Paulo'::text))::date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_ini date := date_trunc('month', p_hoje)::date;
  v_fim date := (date_trunc('month', p_hoje) + interval '1 month - 1 day')::date;
  v_meta int; v_inst int; v_faltam int; v_dias int;
begin
  if auth.role() <> 'service_role' and public.meu_perfil() is null then
    return null;
  end if;
  select meta_vendas into v_meta from public.config_metas where mes = v_ini and parceiro_id = 'dharma';
  select count(*) into v_inst
    from public.vendas v
   where v.instalado_em is not null
     and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
     and (v.instalado_em at time zone 'America/Sao_Paulo')::date between v_ini and v_fim;
  v_meta := coalesce(v_meta, 0);
  v_faltam := greatest(v_meta - v_inst, 0);
  -- 0099: dias úteis = dias de contato (sem domingo e sem feriado nacional/estadual), de hoje ao fim do mês.
  select count(*) into v_dias from generate_series(p_hoje, v_fim, interval '1 day') g(d)
   where public.mari_dia_permitido(g.d::date, null);
  return jsonb_build_object(
    'mes', to_char(v_ini, 'YYYY-MM'),
    'meta', v_meta,
    'instaladas', v_inst,
    'faltam', v_faltam,
    'dias_restantes', v_dias,
    'dias_uteis', true,
    'por_dia', case when v_dias > 0 then round(v_faltam::numeric / v_dias, 1) else v_faltam end,
    'pct', case when v_meta > 0 then round(100.0 * v_inst / v_meta, 1) else null end
  );
end $function$;

-- ───────── 4. termômetro: telefone confirmado de verdade ─────────
create or replace function public._mari_item_validado(p_regra text, p_valor text, p_c jsonb)
returns boolean language sql immutable set search_path = public as $$
  select case coalesce(p_regra, 'nenhuma')
    when 'nenhuma'             then p_valor is not null
    when 'cpf_valido'          then public.mari_cpf_valido(p_valor)
    when 'cnpj_valido'         then public.mari_cnpj_valido(p_valor)
    when 'cep_na_area'         then coalesce((p_c ->> 'dentro_area')::boolean, false)
    -- 0099: só com a marca do motor (o do WhatsApp, ou outro número que o cliente confirmou)
    when 'telefone_confirmado' then length(regexp_replace(coalesce(p_valor, ''), '\D', '', 'g')) between 10 and 13
                                    and coalesce((p_c -> 'dados' ->> 'telefone_confirmado')::boolean, false)
    else false end
$$;

-- conversas antigas: telefone igual ao do WhatsApp (com o 9 de volta) = confirmado
update public.mari_conversas c
   set dados = coalesce(c.dados, '{}'::jsonb) || jsonb_build_object('telefone_confirmado', true)
 where c.dados ? 'telefone'
   and not coalesce((c.dados ->> 'telefone_confirmado')::boolean, false)
   and regexp_replace(c.dados ->> 'telefone', '\D', '', 'g') in (
         regexp_replace(regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g'), '^55(?=\d{10,11}$)', ''),
         regexp_replace(regexp_replace(regexp_replace(coalesce(c.telefone, ''), '\D', '', 'g'), '^55(?=\d{10,11}$)', ''), '^(\d{2})([6-9]\d{7})$', '\19\2'));

-- ───────── 5. abertura B2 (texto aprovado) ─────────
update public.config_mari_textos set texto = replace(texto, 'tudo bem? 😊', 'tudo bem? 💚')
 where chave in ('abertura_corpo', 'abertura_fallback') and texto like '%tudo bem? 😊%';
update public.config_mari_textos
   set texto = E'Oba! Me manda só o seu CEP que eu já confiro pra você.\n\nSe não lembrar, tudo bem.\n\nPode mandar o nome da rua e o bairro 😉'
 where chave = 'abertura_resp_rua';
