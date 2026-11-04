-- NIOGEN | supabase/migrations/0012_aplicar_dfv_rapido.sql | 03/11/2026
-- A 1ª chamada de aplicar_dfv (0011) com a base de JF (143.828 linhas) passou de 100 s e caiu no timeout do proxy da API
-- (nada foi gravado: a transação voltou inteira). Causa: dfv_txt/dfv_int/dfv_num têm "set search_path", e função SQL com SET
-- não é embutida pelo planejador — eram ~40 chamadas de função por linha. Aqui aplicar_dfv usa as mesmas expressões direto
-- e só monta o jsonb "bruto" quando alguma coluna sem destino vier preenchida. Regra e resultado iguais aos da 0011.
-- Os helpers continuam (usados em consultas pontuais); dfv_consultar e o trigger da venda não mudam.

create or replace function public.aplicar_dfv(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  imp        public.importacoes%rowtype;
  v_part     date;
  n_parts    int;
  n_arquivo  int;
  n_ins      int;
  v_ant      jsonb;
  v_resumo   jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice aplicam importação.' using errcode = '42501';
  end if;

  select * into imp from public.importacoes where id = p_importacao_id for update;
  if not found then
    raise exception 'Importação % não encontrada.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.tipo <> 'dfv_hp' then
    raise exception 'Importação % não é base DFV.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.aplicado_em is not null then
    raise exception 'Esta importação já foi aplicada em %.', imp.aplicado_em using errcode = 'P0001';
  end if;

  select count(*), count(distinct dt_dfv_particao)
    into n_arquivo, n_parts
  from (select nullif(btrim(dt_dfv_particao), '') as dt_dfv_particao from public.nio_hp_stage where importacao_id = p_importacao_id) s;
  if n_arquivo = 0 then
    raise exception 'Importação % sem linhas na staging.', p_importacao_id using errcode = 'P0001';
  end if;
  if n_parts <> 1 then
    raise exception 'O arquivo tem % partições (dt_dfv_particao); esperado 1.', n_parts using errcode = 'P0001';
  end if;
  -- epoch em ms (1793664000000 = 03/11/2026, meia-noite UTC).
  v_part := (to_timestamp((select nullif(btrim(dt_dfv_particao), '')::bigint from public.nio_hp_stage
                           where importacao_id = p_importacao_id limit 1) / 1000.0) at time zone 'UTC')::date;

  -- Fotografia da partição que sai (para o "antes × depois" do resumo).
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_ant from (
    select h.uf, h.municipio, min(h.particao) as particao, count(*) as linhas,
           sum(h.hp_tot) as hp_tot, sum(h.hp_livre) as hp_livre, sum(h.hc_tot) as hc_tot
    from public.nio_hp h
    where (h.uf, h.municipio) in (select distinct nullif(btrim(s.uf), ''), nullif(btrim(s.municipio), '')
                                  from public.nio_hp_stage s where s.importacao_id = p_importacao_id)
    group by h.uf, h.municipio) x;

  delete from public.nio_hp h
  where (h.uf, h.municipio) in (select distinct nullif(btrim(s.uf), ''), nullif(btrim(s.municipio), '')
                                from public.nio_hp_stage s where s.importacao_id = p_importacao_id);

  -- Linha repetida no arquivo (mesma chave): fica a primeira.
  insert into public.nio_hp (
    cod_survey, numero, complemento1, complemento2, complemento3, cep, logradouro, cod_logradouro, tipo_endereco,
    bairro, municipio, uf, celula, estacao, cdo, tipo_edificacao, viabilidade, id_viabilidade,
    hp_tot, hp_var, hp_emp, hp_livre, hc_tot, hc_var, hc_emp, classificacao, classe_social, faixa_credito,
    pct_aprov_bairro, qt_propostas_bairro, gross_6m, flag_gross_6m, hp_novo, lat, lon, particao, importacao_id, bruto)
  select distinct on (cod_survey, numero, coalesce(complemento1, ''))
    cod_survey, numero, complemento1, complemento2, complemento3, cep, logradouro, cod_logradouro, tipo_endereco,
    bairro, municipio, uf, celula, estacao, cdo, tipo_edificacao, viabilidade, id_viabilidade,
    hp_tot, hp_var, hp_emp, hp_livre, hc_tot, hc_var, hc_emp, classificacao, classe_social, faixa_credito,
    pct_aprov_bairro, qt_propostas_bairro, gross_6m, flag_gross_6m, hp_novo, lat, lon, v_part, p_importacao_id, bruto
  from (
    select s.linha,
      nullif(btrim(s.cod_survey), '') as cod_survey,
      upper(regexp_replace(coalesce(nullif(btrim(s.no_fachada), ''), 'SN'), '\s', '', 'g')) as numero,
      nullif(btrim(s.complemento1), '') as complemento1, nullif(btrim(s.complemento2), '') as complemento2,
      nullif(btrim(s.complemento3), '') as complemento3,
      regexp_replace(coalesce(s.cep, ''), '\D', '', 'g') as cep,
      nullif(btrim(s.logradouro), '') as logradouro, nullif(btrim(s.codigo_logradouro), '') as cod_logradouro,
      nullif(btrim(s.tipo_endereco), '') as tipo_endereco, nullif(btrim(s.bairro), '') as bairro,
      nullif(btrim(s.municipio), '') as municipio, nullif(btrim(s.uf), '') as uf, nullif(btrim(s.celula), '') as celula,
      nullif(btrim(s.sigla_estacao_abastecedora), '') as estacao, nullif(btrim(s.codigo_cdo), '') as cdo,
      nullif(btrim(s.tipo_edificacao), '') as tipo_edificacao, nullif(btrim(s.viabilidade_atual), '') as viabilidade,
      (case when btrim(s.id_viabilidade) ~ '^-?\d+$' then btrim(s.id_viabilidade)::int end) as id_viabilidade,
      (case when btrim(s.hp_tot) ~ '^-?\d+$' then btrim(s.hp_tot)::int end) as hp_tot, (case when btrim(s.hp_var) ~ '^-?\d+$' then btrim(s.hp_var)::int end) as hp_var, (case when btrim(s.hp_emp) ~ '^-?\d+$' then btrim(s.hp_emp)::int end) as hp_emp,
      (case when btrim(s.hp_livre) ~ '^-?\d+$' then btrim(s.hp_livre)::int end) as hp_livre, (case when btrim(s.hc_tot) ~ '^-?\d+$' then btrim(s.hc_tot)::int end) as hc_tot, (case when btrim(s.hc_var) ~ '^-?\d+$' then btrim(s.hc_var)::int end) as hc_var,
      (case when btrim(s.hc_emp) ~ '^-?\d+$' then btrim(s.hc_emp)::int end) as hc_emp, nullif(btrim(s.classificacao), '') as classificacao,
      nullif(btrim(s.ds_classe_social_dominante), '') as classe_social,
      nullif(btrim(s.ds_faixa_aprovacao_credito_total), '') as faixa_credito,
      (case when btrim(s.pct_aprovados_bairro) ~ '^-?\d+(\.\d+)?$' then btrim(s.pct_aprovados_bairro)::numeric end) as pct_aprov_bairro, (case when btrim(s.qt_propostas_bairro) ~ '^-?\d+$' then btrim(s.qt_propostas_bairro)::int end) as qt_propostas_bairro,
      (case when btrim(s.gross_media_6m_cel) ~ '^-?\d+(\.\d+)?$' then btrim(s.gross_media_6m_cel)::numeric end) as gross_6m, (case when btrim(s.flag_gross_6m_cel) ~ '^-?\d+$' then btrim(s.flag_gross_6m_cel)::int end) as flag_gross_6m,
      (case when btrim(s.f_hp_novo) ~ '^-?\d+$' then btrim(s.f_hp_novo)::int end) as hp_novo,
      (case when btrim(s.latitude) ~ '^-?\d+(\.\d+)?$' then btrim(s.latitude)::numeric end)::double precision as lat, (case when btrim(s.longitude) ~ '^-?\d+(\.\d+)?$' then btrim(s.longitude)::numeric end)::double precision as lon,
      -- bruto só quando alguma coluna sem destino vier preenchida (hoje nenhuma): evita montar jsonb em 143 mil linhas.
      case when concat(s.giro_medio_6m_cel, s.vll_media_6m_cel, s.perc_hps_area_risco, s.dt_construcao_2025, s.projeto_hp_novo,
                       s.score_medio_cel, s.pct_aprov_ind_loc_out_cel, s.pct_aprovados_cc_bairro, s.pct_posse_cartao_bairro,
                       regexp_replace(coalesce(s.ds_faixa_aprovacao_credito_local, ''), '^N.o informado$', ''),
                       regexp_replace(coalesce(s.ds_faixa_posse_cartao, ''), '^N.o informado$', '')) !~ '\S'
           then '{}'::jsonb else
      (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
         from jsonb_each_text(jsonb_build_object(
           'giro_medio_6m_cel', s.giro_medio_6m_cel, 'vll_media_6m_cel', s.vll_media_6m_cel,
           'perc_hps_area_risco', s.perc_hps_area_risco, 'dt_construcao_2025', s.dt_construcao_2025,
           'projeto_hp_novo', s.projeto_hp_novo, 'score_medio_cel', s.score_medio_cel,
           'pct_aprov_ind_loc_out_cel', s.pct_aprov_ind_loc_out_cel, 'pct_aprovados_cc_bairro', s.pct_aprovados_cc_bairro,
           'pct_posse_cartao_bairro', s.pct_posse_cartao_bairro,
           'ds_faixa_aprovacao_credito_local', s.ds_faixa_aprovacao_credito_local,
           'ds_faixa_posse_cartao', s.ds_faixa_posse_cartao)) e(k, v)
         where nullif(btrim(v), '') is not null and v not ilike 'n_o informado') end as bruto
    from public.nio_hp_stage s
    where s.importacao_id = p_importacao_id
  ) t
  where cod_survey is not null and cep <> '' and municipio is not null and uf is not null
  order by cod_survey, numero, coalesce(complemento1, ''), linha;
  get diagnostics n_ins = row_count;

  select jsonb_build_object(
      'particao', v_part, 'linhas_arquivo', n_arquivo, 'linhas', n_ins, 'descartadas', n_arquivo - n_ins,
      'hp_tot', sum(hp_tot), 'hp_livre', sum(hp_livre), 'hc_tot', sum(hc_tot),
      'casas_ocupadas', count(*) filter (where hp_tot = 1 and hc_tot >= 1),
      'bairros', count(distinct bairro), 'ceps', count(distinct cep),
      'municipios', jsonb_agg(distinct municipio), 'anterior', v_ant)
    into v_resumo
  from public.nio_hp where importacao_id = p_importacao_id;

  delete from public.nio_hp_stage where importacao_id = p_importacao_id;

  update public.importacoes set
    dt_ref      = v_part,
    linhas      = n_arquivo,
    aplicadas   = n_ins,
    ignoradas   = n_arquivo - n_ins,
    resumo      = coalesce(imp.resumo, '{}'::jsonb) || v_resumo,
    aplicado_em = now()
  where id = p_importacao_id;

  return v_resumo;
end;
$$;

revoke execute on function public.aplicar_dfv(uuid) from public, anon;
grant execute on function public.aplicar_dfv(uuid) to authenticated;
