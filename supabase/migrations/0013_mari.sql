-- NIOGEN | supabase/migrations/0013_mari.sql | 04/11/2026
-- Mari v1 (modo teste): conversas, turnos, erros, guards estruturais do motor (debounce,
-- consolidação, lock por conversa — o equivalente Nio das RPCs da Renata), contexto do
-- endereço (área, cluster, planos, DFV), handoff que cria a venda em 0 – Qualificado,
-- views da futura tela Mari e limpeza dos dados de teste.
-- Fonte: docs/PROMPT_CODE_08_mari_v1_dryrun_041126_0845.md (Drive). Idempotente.
-- Escrita só pelo service role (n8n). Leitura das views: admin/backoffice.

-- ============================================================================
-- vendas: campo de observações (briefing da Mari) — aditivo
-- ============================================================================
alter table public.vendas add column if not exists observacoes text;

-- ============================================================================
-- Tabelas
-- ============================================================================
create table if not exists public.mari_conversas (
  id                        uuid primary key default gen_random_uuid(),
  telefone                  text not null check (telefone ~ '^\d{10,15}$'),   -- só dígitos, com DDI
  nome_contato              text,
  nome_confiavel            boolean not null default false,
  canal                     text not null default 'teste' check (canal in ('teste', 'whatsapp')),
  chatwoot_conversation_id  text,
  status                    text not null default 'ativo'
                              check (status in ('ativo', 'handoff_realizado', 'encerrado_humano', 'encerrado_ia')),
  etapa                     text not null default 'abertura'
                              check (etapa in ('abertura', 'endereco', 'elegibilidade', 'planos', 'coleta', 'resumo', 'handoff')),
  cep                       text,
  numero                    text,
  complemento               text,
  endereco_cep              jsonb,                       -- retorno do ViaCEP
  cidade                    text,
  uf                        text,
  cluster                   text check (cluster in ('regular', 'btu')),
  dentro_area               boolean,
  segmento                  text not null default 'varejo' check (segmento in ('varejo', 'empresas')),
  mei                       boolean,
  elegibilidade             text check (elegibilidade in ('ok', 'ja_cliente', 'cancelou_30d', 'fora_area')),
  dfv_resultado             text,
  dfv_detalhe               jsonb,
  plano_escolhido           text references public.config_planos (codigo),
  forma_pagamento           text check (forma_pagamento in ('boleto', 'cartao', 'dacc')),
  visita_preferencia        text,
  dados                     jsonb not null default '{}'::jsonb,   -- nome, cpf, telefone, email
  lgpd_enviada              boolean not null default false,
  upsell_oferecido          boolean not null default false,
  nao_contatar              boolean not null default false,
  ultima_msg_lead_at        timestamptz,
  followup_next_at          timestamptz,
  followup_count            int not null default 0,
  agendamento_retorno       timestamptz,
  origem                    text not null default 'direto'
                              check (origem in ('meta_ads', 'site', 'fila_vero', 'indicacao', 'direto', 'teste')),
  handoff_motivo            text,
  handoff_em                timestamptz,
  venda_id                  uuid references public.vendas (id) on delete set null,
  -- guards estruturais do motor (não são dado de negócio)
  ultima_entrada_ts         timestamptz,                 -- debounce: carimbo da última mensagem recebida
  processando_ate           timestamptz,                 -- lock por conversa (TTL)
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

-- Uma conversa aberta (ativa ou em handoff) por telefone e canal.
create unique index if not exists mari_conversas_aberta_uidx
  on public.mari_conversas (telefone, canal) where status in ('ativo', 'handoff_realizado');
create index if not exists mari_conversas_telefone_idx on public.mari_conversas (telefone, created_at desc);
create index if not exists mari_conversas_venda_idx on public.mari_conversas (venda_id);

create table if not exists public.mari_turnos (
  id           bigint generated always as identity primary key,
  conversa_id  uuid not null references public.mari_conversas (id) on delete cascade,
  papel        text not null check (papel in ('lead', 'mari', 'humano', 'sistema')),
  texto        text not null default '',
  tags         jsonb,
  modelo       text,
  tokens_in    int,
  tokens_out   int,
  latencia_ms  int,
  pendente     boolean not null default false,     -- mensagem do lead ainda não respondida (consolidação)
  created_at   timestamptz not null default now()
);
create index if not exists mari_turnos_conversa_idx on public.mari_turnos (conversa_id, created_at);
create index if not exists mari_turnos_pendente_idx on public.mari_turnos (conversa_id) where pendente;

create table if not exists public.mari_erros (
  id           bigint generated always as identity primary key,
  conversa_id  uuid references public.mari_conversas (id) on delete cascade,
  no_n8n       text,
  mensagem     text,
  payload      jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists mari_erros_conversa_idx on public.mari_erros (conversa_id, created_at);

-- updated_at
create or replace function public.mari_touch()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists mari_conversas_touch on public.mari_conversas;
create trigger mari_conversas_touch before update on public.mari_conversas
  for each row execute function public.mari_touch();

-- ============================================================================
-- Auxiliares
-- ============================================================================

-- CPF válido pelo dígito verificador (11 dígitos, não repetidos).
create or replace function public.mari_cpf_valido(p text)
returns boolean language plpgsql immutable set search_path = public as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  s int; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0;
  for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end;
$$;

-- ============================================================================
-- Guards estruturais (padrão Renata: register_webhook / should_process / lock)
-- ============================================================================

-- Entrada: registra a mensagem do lead (pendente) e carimba o debounce.
-- Abre conversa nova se não houver uma aberta para o telefone/canal.
create or replace function public.mari_entrada(
  p_telefone text, p_nome text, p_texto text,
  p_canal text default 'teste', p_origem text default null,
  p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when p_origem in ('meta_ads', 'site', 'fila_vero', 'indicacao', 'direto', 'teste') then p_origem end;
begin
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else 'direto' end),
            p_chatwoot_conversation_id)
    returning * into v_conv;
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), v_conv.status = 'ativo');

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), ''))
   where id = v_conv.id;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', v_conv.status <> 'ativo',          -- em handoff: humano conduz, Mari calada
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$$;

-- Consolidação: só a execução mais recente segue (debounce); pega o lock da conversa;
-- devolve as mensagens pendentes juntas, o histórico e o estado.
-- resultado: 'superado' | 'ocupado' | 'vazio' | 'silencio' | 'ok'
create or replace function public.mari_consolidar(p_conversa uuid, p_ts timestamptz, p_ttl_seg int default 45)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_conv public.mari_conversas;
  v_ids  bigint[];
  v_txt  text;
  v_hist jsonb;
begin
  select * into v_conv from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('resultado', 'vazio'); end if;
  if v_conv.status <> 'ativo' then return jsonb_build_object('resultado', 'silencio', 'status', v_conv.status); end if;
  if v_conv.ultima_entrada_ts > p_ts then return jsonb_build_object('resultado', 'superado'); end if;
  if v_conv.processando_ate is not null and v_conv.processando_ate > now() then
    return jsonb_build_object('resultado', 'ocupado');
  end if;

  select array_agg(id order by id), string_agg(texto, E'\n' order by id)
    into v_ids, v_txt
    from public.mari_turnos where conversa_id = p_conversa and pendente;
  if v_ids is null then return jsonb_build_object('resultado', 'vazio'); end if;

  update public.mari_turnos set pendente = false where id = any (v_ids);
  update public.mari_conversas set processando_ate = now() + make_interval(secs => p_ttl_seg) where id = p_conversa;

  -- Histórico (sem as pendentes de agora), últimos 60 turnos, mais antigo primeiro.
  select coalesce(jsonb_agg(jsonb_build_object('papel', papel, 'texto', texto) order by id), '[]'::jsonb)
    into v_hist
    from (select id, papel, texto from public.mari_turnos
           where conversa_id = p_conversa and not (id = any (v_ids)) and papel in ('lead', 'mari', 'humano')
           order by id desc limit 60) t;

  return jsonb_build_object(
    'resultado', 'ok',
    'mensagem', v_txt,
    'n_mensagens', cardinality(v_ids),
    'turno_ids', to_jsonb(v_ids),
    'historico', v_hist,
    'conversa', to_jsonb(v_conv) - 'processando_ate' - 'ultima_entrada_ts');
end;
$$;

create or replace function public.mari_liberar(p_conversa uuid)
returns void language sql set search_path = public as $$
  update public.mari_conversas set processando_ate = null where id = p_conversa;
$$;

-- ============================================================================
-- Contexto do endereço: grava CEP/número/ViaCEP na conversa e devolve área, cluster,
-- planos ativos do cluster e (Juiz de Fora) a consulta DFV.
-- ============================================================================
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
             'velocidade_mb', velocidade_mb, 'wifi', wifi, 'inclusos', to_jsonb(inclusos),
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

-- ============================================================================
-- Salvar turno: grava a fala da Mari, aplica as atualizações extraídas das tags e libera o lock.
-- ============================================================================
create or replace function public.mari_salvar_turno(
  p_conversa uuid, p_texto text, p_tags jsonb default null, p_modelo text default null,
  p_tokens_in int default null, p_tokens_out int default null, p_latencia_ms int default null,
  p_upd jsonb default '{}'::jsonb, p_papel text default 'mari')
returns jsonb language plpgsql set search_path = public as $$
declare
  u jsonb := coalesce(p_upd, '{}'::jsonb);
begin
  if coalesce(p_texto, '') <> '' or p_tags is not null then
    insert into public.mari_turnos (conversa_id, papel, texto, tags, modelo, tokens_in, tokens_out, latencia_ms)
    values (p_conversa, p_papel, coalesce(p_texto, ''), p_tags, p_modelo, p_tokens_in, p_tokens_out, p_latencia_ms);
  end if;

  update public.mari_conversas c set
    etapa              = coalesce(u ->> 'etapa', c.etapa),
    elegibilidade      = coalesce(u ->> 'elegibilidade', c.elegibilidade),
    segmento           = coalesce(u ->> 'segmento', c.segmento),
    mei                = coalesce((u ->> 'mei')::boolean, c.mei),
    plano_escolhido    = case when u ? 'plano_escolhido' then u ->> 'plano_escolhido' else c.plano_escolhido end,
    forma_pagamento    = coalesce(u ->> 'forma_pagamento', c.forma_pagamento),
    visita_preferencia = coalesce(u ->> 'visita_preferencia', c.visita_preferencia),
    dados              = c.dados || coalesce(u -> 'dados', '{}'::jsonb),
    lgpd_enviada       = c.lgpd_enviada or coalesce((u ->> 'lgpd_enviada')::boolean, false),
    upsell_oferecido   = c.upsell_oferecido or coalesce((u ->> 'upsell_oferecido')::boolean, false),
    nome_confiavel     = coalesce((u ->> 'nome_confiavel')::boolean, c.nome_confiavel),
    agendamento_retorno= coalesce((u ->> 'agendamento_retorno')::timestamptz, c.agendamento_retorno),
    complemento        = case when u ? 'complemento' then nullif(u ->> 'complemento', '') else c.complemento end,
    processando_ate    = null
  where c.id = p_conversa;

  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================================
-- Handoff: grava status/etapa; com dados completos e elegibilidade ok, cria a venda em
-- 0 – Qualificado. Toda trava de vendas vale; recusa vira mari_erros e volta o motivo.
-- ============================================================================
create or replace function public.mari_handoff(p_conversa uuid, p_motivo text, p_lead jsonb default '{}'::jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  c        public.mari_conversas;
  l        jsonb := coalesce(p_lead, '{}'::jsonb);
  d        jsonb;
  v_plano  public.config_planos;
  v_venda  uuid;
  v_motivo text;
  v_seg    text;
  v_forma  text;
  v_orig   text;
  v_cpf    text;
  v_tel    text;
  v_cluster text;
  v_dfv    jsonb;
  v_brief  text;
  v_obs    text;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'motivo_recusa', 'conversa inexistente'); end if;

  -- Guard-rail 10: não repetir handoff.
  if c.status <> 'ativo' then
    return jsonb_build_object('ok', true, 'repetido', true, 'venda_id', c.venda_id);
  end if;

  d := c.dados || coalesce(l -> 'dados', '{}'::jsonb);

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    dados = d, processando_ate = null,
    nao_contatar = nao_contatar or p_motivo = 'recusa_compra',
    agendamento_retorno = coalesce((l ->> 'agendamento_retorno')::timestamptz, agendamento_retorno)
  where id = p_conversa
  returning * into c;

  if p_motivo <> 'dados_completos' then
    return jsonb_build_object('ok', true, 'venda_id', null);
  end if;

  -- Pré-condições da venda (ordem: elegibilidade, área, plano, dados mínimos, duplicidade).
  v_cluster := public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> 'bairro');
  v_cpf := regexp_replace(coalesce(d ->> 'cpf', ''), '\D', '', 'g');
  v_tel := regexp_replace(coalesce(d ->> 'telefone', c.telefone), '\D', '', 'g');
  select * into v_plano from public.config_planos where codigo = c.plano_escolhido;

  v_motivo := case
    when coalesce(c.elegibilidade, '') <> 'ok' then 'elegibilidade não confirmada (' || coalesce(c.elegibilidade, 'vazia') || ')'
    when v_cluster is null then 'fora da área de atuação (' || coalesce(c.cidade, 'cidade desconhecida') || ')'
    when v_plano.id is null then 'plano não escolhido'
    when coalesce(btrim(d ->> 'nome'), '') = '' then 'nome do cliente ausente'
    when c.cep is null or c.numero is null then 'endereço incompleto'
    when exists (select 1 from public.vendas v where v.status <> 'saida'
                   and ((v_cpf <> '' and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = v_cpf)
                     or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = c.cep
                         and lower(btrim(coalesce(v.numero, ''))) = lower(btrim(c.numero))
                         and lower(btrim(coalesce(v.complemento, ''))) = lower(btrim(coalesce(c.complemento, ''))))))
      then 'duplicidade: CPF ou endereço já tem venda ativa no NIOGEN'
  end;

  if v_motivo is null then
    v_seg := case when c.segmento = 'empresas' then case when c.mei then 'MEI' else 'NMEI' end else 'PF' end;
    v_forma := coalesce(c.forma_pagamento, l ->> 'forma_pagamento');
    v_forma := case v_forma when 'debito' then 'dacc' when 'debito_automatico' then 'dacc' else v_forma end;
    if v_forma not in ('boleto', 'cartao', 'dacc') then v_forma := null; end if;
    v_orig := case when c.origem in ('meta_ads', 'site', 'fila_vero', 'indicacao') then c.origem else 'outro' end;
    v_dfv := c.dfv_detalhe;

    v_brief := coalesce(l ->> 'briefing', '');
    v_obs := concat_ws(E'\n',
      'Mari (' || c.canal || ') — handoff dados_completos em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
      'Plano: ' || v_plano.nome || ' · forma: ' || coalesce(v_forma, '?'),
      'Visita: ' || coalesce(c.visita_preferencia, l ->> 'visita_preferencia', '?'),
      'DFV: ' || case coalesce(c.dfv_resultado, '')
                   when 'viavel' then 'viável'
                   when 'viavel_predio' then 'viável (prédio) — conferir unidade'
                   when 'endereco_ocupado' then 'indica Nio ativo no endereço — confirmar com o cliente e no APP antes da visita'
                   else 'conferir manualmente antes da visita' end,
      nullif(v_brief, ''));

    begin
      insert into public.vendas (
        status, origem, origem_ref, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
        cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento,
        trava_area, trava_cpf_valido, trava_contato_confirmado, observacoes,
        dfv_viabilidade, dfv_resultado, dfv_hp_livre, dfv_hcs, dfv_faixa_credito, dfv_classificacao,
        dfv_particao, dfv_origem, dfv_consultado_em)
      values (
        '0_qualificado', v_orig, 'mari:' || c.id, btrim(d ->> 'nome'), nullif(v_cpf, ''), v_tel, nullif(btrim(d ->> 'email'), ''), v_seg,
        c.cep, c.endereco_cep ->> 'logradouro', c.numero, c.complemento,
        coalesce(c.endereco_cep ->> 'bairro', v_dfv ->> 'bairro'), c.cidade, c.uf, v_plano.id, v_forma,
        true, case when v_cpf <> '' then public.mari_cpf_valido(v_cpf) end,
        case when coalesce((d ->> 'telefone_confirmado')::boolean, false) or v_tel <> '' then true end, v_obs,
        case c.dfv_resultado
          when 'viavel' then 'viavel' when 'viavel_predio' then 'viavel_predio'
          when 'endereco_ocupado' then 'sem_viabilidade' when 'sem_porta_livre' then 'sem_viabilidade'
          when 'nao_encontrado' then 'nao_encontrado'
          else 'nao_consultado' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then c.dfv_resultado end,
        (v_dfv ->> 'hp_livre')::int, (v_dfv ->> 'hc_tot')::int,
        public.dfv_faixa_codigo(v_dfv ->> 'faixa_credito'),
        case when v_dfv ->> 'classificacao' in ('ALTO', 'MEDIO', 'BAIXO') then v_dfv ->> 'classificacao' end,
        (v_dfv ->> 'particao')::date,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then 'auto' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then now() end)
      returning id into v_venda;

      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v_venda, 'mari_handoff', jsonb_strip_nulls(jsonb_build_object(
        'conversa_id', c.id, 'motivo', p_motivo, 'canal', c.canal, 'briefing', nullif(v_brief, ''),
        'visita_preferencia', c.visita_preferencia, 'dfv_resultado', c.dfv_resultado)));

      update public.mari_conversas set venda_id = v_venda where id = p_conversa;
    exception when others then
      v_motivo := sqlerrm;
    end;
  end if;

  if v_motivo is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_handoff', 'venda não criada: ' || v_motivo, jsonb_build_object('lead', l, 'dados', d));
    return jsonb_build_object('ok', false, 'venda_id', null, 'motivo_recusa', v_motivo);
  end if;

  return jsonb_build_object('ok', true, 'venda_id', v_venda);
end;
$$;

-- ============================================================================
-- Limpeza dos dados de teste (padrão sweep_test_data da Renata): conversas canal 'teste'
-- com o prefixo de telefone dado, seus turnos/erros e as vendas que elas criaram.
-- ============================================================================
create or replace function public.mari_limpar_teste(p_prefixo text default '5500000000')
returns jsonb language plpgsql set search_path = public as $$
declare
  v_vendas int; v_conv int;
begin
  if coalesce(p_prefixo, '') !~ '^\d{6,}$' then
    raise exception 'prefixo inválido (mínimo 6 dígitos)' using errcode = '22023';
  end if;
  with alvo as (
    select id, venda_id from public.mari_conversas
     where canal = 'teste' and telefone like p_prefixo || '%'),
  apagadas as (
    delete from public.vendas v
     where v.id in (select venda_id from alvo where venda_id is not null)
        or v.origem_ref in (select 'mari:' || id from alvo)
    returning 1)
  select count(*) into v_vendas from apagadas;

  with apagadas as (
    delete from public.mari_conversas where canal = 'teste' and telefone like p_prefixo || '%' returning 1)
  select count(*) into v_conv from apagadas;

  return jsonb_build_object('vendas', v_vendas, 'conversas', v_conv);
end;
$$;

-- ============================================================================
-- Views da futura tela Mari
-- ============================================================================
drop view if exists public.v_mari_metricas;
drop view if exists public.v_mari_conversas;

create view public.v_mari_conversas
with (security_invoker = true) as
select
  c.id, c.telefone, c.nome_contato, c.canal, c.origem, c.status, c.etapa,
  c.cidade, c.uf, c.cluster, c.dentro_area, c.segmento, c.elegibilidade,
  c.plano_escolhido, p.nome as plano_nome, c.forma_pagamento, c.dfv_resultado,
  c.handoff_motivo, c.handoff_em, c.venda_id,
  c.created_at, c.updated_at, c.ultima_msg_lead_at,
  now() - c.created_at as idade,
  (select count(*) from public.mari_turnos t where t.conversa_id = c.id)::int as turnos
from public.mari_conversas c
left join public.config_planos p on p.codigo = c.plano_escolhido;

create view public.v_mari_metricas
with (security_invoker = true) as
with base as (
  select (c.created_at at time zone 'America/Sao_Paulo')::date as dia, c.*
  from public.mari_conversas c
  where c.canal <> 'teste'
)
select
  b.dia,
  count(*)::int as conversas,
  count(*) filter (where b.venda_id is not null)::int as qualificadas,
  round(100.0 * count(*) filter (where b.venda_id is not null) / nullif(count(*), 0), 1) as pct_qualificacao,
  coalesce((select jsonb_object_agg(x.handoff_motivo, x.n)
              from (select b2.handoff_motivo, count(*)::int as n from base b2
                     where b2.dia = b.dia and b2.handoff_motivo is not null group by 1) x), '{}'::jsonb) as handoffs_por_motivo
from base b
group by b.dia;

-- ============================================================================
-- RLS e permissões: escrita só service role; leitura admin/backoffice.
-- ============================================================================
alter table public.mari_conversas enable row level security;
alter table public.mari_turnos    enable row level security;
alter table public.mari_erros     enable row level security;

drop policy if exists mari_conversas_ler on public.mari_conversas;
create policy mari_conversas_ler on public.mari_conversas for select to authenticated
  using (public.meu_perfil() in ('admin', 'backoffice'));
drop policy if exists mari_turnos_ler on public.mari_turnos;
create policy mari_turnos_ler on public.mari_turnos for select to authenticated
  using (public.meu_perfil() in ('admin', 'backoffice'));
drop policy if exists mari_erros_ler on public.mari_erros;
create policy mari_erros_ler on public.mari_erros for select to authenticated
  using (public.meu_perfil() in ('admin', 'backoffice'));

revoke all on public.mari_conversas, public.mari_turnos, public.mari_erros from anon;
revoke insert, update, delete, truncate on public.mari_conversas, public.mari_turnos, public.mari_erros from authenticated;
revoke all on public.v_mari_conversas, public.v_mari_metricas from anon;
grant select on public.v_mari_conversas, public.v_mari_metricas to authenticated;

revoke execute on function public.mari_cpf_valido(text) from public, anon;
grant execute on function public.mari_cpf_valido(text) to authenticated, service_role;
revoke execute on function public.mari_touch() from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.mari_entrada(text, text, text, text, text, text)',
    'public.mari_consolidar(uuid, timestamptz, int)',
    'public.mari_liberar(uuid)',
    'public.mari_contexto(uuid, text, text, text, jsonb)',
    'public.mari_salvar_turno(uuid, text, jsonb, text, int, int, int, jsonb, text)',
    'public.mari_handoff(uuid, text, jsonb)',
    'public.mari_limpar_teste(text)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;
