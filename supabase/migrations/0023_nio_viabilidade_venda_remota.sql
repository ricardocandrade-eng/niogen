-- NIOGEN | supabase/migrations/0023_nio_viabilidade_venda_remota.sql | 05/11/2026 — Claude Code (prompt nº 15)
-- Venda 100 % remota (decisão do Ricardo, 05/11 09h32, com as respostas do Rogério): não existe biometria em campo.
-- O pedido é aberto no portal PAP (perfil BO), a biometria vai por LINK ao cliente, o crédito sai no portal e a
-- instalação é agendada pelo nosso time em data + turno. Esta migration:
--   1. vendas: viabilidade oficial do portal (nio_viab_*), crédito, biometria por link, preferência e turno da instalação;
--      biometria_status passa a ser nao_enviada | pendente | com_risco | validada (o antigo agendada/aprovada/reprovada
--      é normalizado no trigger — front antigo continua gravando sem erro). Um campo só, nunca dois.
--   2. mari_conversas: nio_viab_* e instalacao_preferencia (visita_preferencia fica só como histórico; nada novo grava nela).
--   3. nio_viab_log: uma linha por consulta ao portal (auditoria + cache de 7 dias por cep+numero+complemento).
--      ⚠️ Nível A EM ESPERA (05/11): o login BO do portal é SSO Microsoft (SAML), não automatizável pelo n8n.
--      A tabela e as colunas ficam prontas; enquanto não houver usuário de integração, nada grava aqui.
--   4. Trava 0 → 1: nº do pedido do portal + biometria VALIDADA + viabilidade (oficial viável < 7 d ou DFV viável < 7 d).
--   5. mari_salvar_turno grava instalacao_preferencia; mari_handoff leva preferência e viabilidade para a venda e
--      escreve o próximo passo do humano (abrir pedido no portal → link da biometria → agendar).
--   6. v_funil ganha as colunas novas e os cálculos de alerta (horas com biometria/crédito pendentes, viab_ok).

-- ─────────────────────────────── 1. vendas ───────────────────────────────
alter table public.vendas
  add column if not exists nio_viab_resultado        text,
  add column if not exists nio_viab_velocidade       text,
  add column if not exists nio_viab_interesse_id     text,   -- interesse criado no portal (vale como "nº do interesse")
  add column if not exists nio_viab_endereco_id      text,
  add column if not exists nio_viab_em               timestamptz,
  add column if not exists nio_viab_origem           text,
  add column if not exists credito_resultado         text,
  add column if not exists credito_em                timestamptz,
  add column if not exists biometria_link            text,   -- link do portal mandado ao cliente (dado do pedido; nunca reaproveitar)
  add column if not exists biometria_link_enviado_em timestamptz,
  add column if not exists biometria_validada_em     timestamptz,
  add column if not exists instalacao_preferencia    text,   -- o que o cliente pediu à Mari/vendedor (manhã/tarde)
  add column if not exists instalacao_turno          text;   -- o turno agendado no portal

alter table public.vendas drop constraint if exists vendas_nio_viab_resultado_check;
alter table public.vendas add constraint vendas_nio_viab_resultado_check
  check (nio_viab_resultado in ('viavel', 'sem_viabilidade', 'posse', 'indisponivel'));
alter table public.vendas drop constraint if exists vendas_nio_viab_origem_check;
alter table public.vendas add constraint vendas_nio_viab_origem_check
  check (nio_viab_origem in ('mari', 'niogen', 'manual'));
alter table public.vendas drop constraint if exists vendas_credito_resultado_check;
alter table public.vendas add constraint vendas_credito_resultado_check
  check (credito_resultado in ('pendente', 'aprovado', 'so_cartao', 'negado'));
alter table public.vendas drop constraint if exists vendas_instalacao_turno_check;
alter table public.vendas add constraint vendas_instalacao_turno_check
  check (instalacao_turno in ('manha', 'tarde'));

-- biometria_status: valores novos (o portal mostra Pendente · com Risco · Validada; "não enviada" = link ainda não saiu).
update public.vendas set biometria_status = case biometria_status
  when 'agendada' then 'pendente' when 'aprovada' then 'validada' when 'reprovada' then 'com_risco' else biometria_status end
where biometria_status in ('agendada', 'aprovada', 'reprovada');
alter table public.vendas drop constraint if exists vendas_biometria_status_check;
alter table public.vendas add constraint vendas_biometria_status_check
  check (biometria_status in ('nao_enviada', 'pendente', 'com_risco', 'validada'));

comment on column public.vendas.biometria_status is
  'Biometria por link do portal PAP (05/11: não existe biometria em campo): nao_enviada | pendente | com_risco | validada.';
comment on column public.vendas.biometria_em is 'Última mudança do biometria_status (carimbo do trigger).';
comment on column public.vendas.nio_pedido is 'Nº do pedido aberto no portal PAP (perfil BO).';
comment on column public.vendas.nio_viab_resultado is
  'Viabilidade oficial do portal PAP (nível A): viavel | sem_viabilidade | posse (endereço já tem Nio) | indisponivel.';

-- Normaliza valores antigos e carimba datas. Roda antes de vendas_antes_status (ordem alfabética dos triggers).
create or replace function public.vendas_antes_biometria()
returns trigger language plpgsql set search_path = public as $$
begin
  new.biometria_status := case new.biometria_status
    when 'agendada' then 'pendente' when 'aprovada' then 'validada' when 'reprovada' then 'com_risco'
    else new.biometria_status end;

  if tg_op = 'INSERT' or new.biometria_status is distinct from old.biometria_status then
    if new.biometria_status is not null then
      new.biometria_em := now();
    end if;
    if new.biometria_status = 'validada' then
      new.biometria_validada_em := coalesce(new.biometria_validada_em, now());
    end if;
    if new.biometria_status in ('pendente', 'com_risco', 'validada') then
      new.biometria_link_enviado_em := coalesce(new.biometria_link_enviado_em, now());
    end if;
  end if;

  if new.credito_resultado is not null
     and (tg_op = 'INSERT' or new.credito_resultado is distinct from old.credito_resultado) then
    new.credito_em := now();
  end if;

  if new.nio_viab_resultado is not null
     and (tg_op = 'INSERT' or new.nio_viab_resultado is distinct from old.nio_viab_resultado) then
    new.nio_viab_em := coalesce(new.nio_viab_em, now());
  end if;
  return new;
end;
$$;

drop trigger if exists vendas_antes_biometria on public.vendas;
create trigger vendas_antes_biometria
  before insert or update of biometria_status, credito_resultado, nio_viab_resultado on public.vendas
  for each row execute function public.vendas_antes_biometria();
revoke execute on function public.vendas_antes_biometria() from public, anon, authenticated;

-- ─────────────────────── 4. Trava 0 → 1 (venda remota) ───────────────────────
create or replace function public.vendas_antes_status()
returns trigger language plpgsql set search_path = public as $$
declare
  mudou   boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
begin
  if not mudou then
    return new;
  end if;

  -- Sem pedido aberto no portal PAP e biometria validada (link) não existe venda (Anexo II; venda remota 05/11).
  if vendida
     and (coalesce(btrim(new.nio_pedido), '') = '' or new.biometria_status is distinct from 'validada') then
    raise exception 'Venda bloqueada: para passar de Qualificado é obrigatório o nº do pedido do portal PAP e a biometria validada (link).'
      using errcode = 'P0001';
  end if;

  -- Viabilidade: só na entrada em 1–5 (de Qualificado, de Saída ou já inserida vendida). Vale a oficial do portal
  -- (nível A) OU a base DFV, as duas com menos de 7 dias. O OSAB levando 2 → 3 → 4 não passa aqui.
  if vendida and (tg_op = 'INSERT' or old.status in ('0_qualificado', 'saida'))
     and not new.dfv_dispensado
     and not (new.nio_viab_resultado = 'viavel' and new.nio_viab_em >= now() - interval '7 days')
     and not (new.dfv_viabilidade in ('viavel', 'viavel_predio') and new.dfv_consultado_em >= now() - interval '7 days') then
    raise exception 'Consulte a viabilidade (portal da Nio ou DFV) antes de registrar a venda — resultado deve ser viável e ter menos de 7 dias.'
      using errcode = 'P0001';
  end if;

  if new.status = 'saida' and coalesce(btrim(new.motivo_saida), '') = '' then
    raise exception 'Saída exige motivo.' using errcode = 'P0001';
  end if;

  if new.status = '1_vendido' then
    new.vendido_em := coalesce(new.vendido_em, now());
  elsif new.status = '2_aguardando_instalacao' then
    new.vendido_em := coalesce(new.vendido_em, now());
    new.agendamento_registrado_em := now();
  elsif new.status = '3_instalado' then
    new.instalado_em := coalesce(new.instalado_em, now());
  elsif new.status = '4_ativo_provisorio' then
    new.ativado_em := coalesce(new.ativado_em, now());
  end if;

  return new;
end;
$$;

-- ─────────────────────────────── 2. mari_conversas ───────────────────────────────
alter table public.mari_conversas
  add column if not exists nio_viab_resultado     text,
  add column if not exists nio_viab_velocidade    text,
  add column if not exists nio_viab_interesse_id  text,
  add column if not exists nio_viab_em            timestamptz,
  add column if not exists instalacao_preferencia text;
alter table public.mari_conversas drop constraint if exists mari_conversas_nio_viab_resultado_check;
alter table public.mari_conversas add constraint mari_conversas_nio_viab_resultado_check
  check (nio_viab_resultado in ('viavel', 'sem_viabilidade', 'posse', 'indisponivel'));
comment on column public.mari_conversas.visita_preferencia is
  'HISTÓRICO (até 05/11): preferência de visita da v1–v3. Desde a v4 (venda remota) vale instalacao_preferencia.';

-- ─────────────────────────────── 3. nio_viab_log ───────────────────────────────
create table if not exists public.nio_viab_log (
  id           bigint generated always as identity primary key,
  criado_em    timestamptz not null default now(),
  origem       text not null check (origem in ('mari', 'niogen', 'manual', 'teste')),
  conversa_id  uuid references public.mari_conversas (id) on delete set null,
  venda_id     uuid references public.vendas (id) on delete set null,
  cep          text not null,
  numero       text not null,
  complemento  text,
  chave        text generated always as (
                 regexp_replace(cep, '\D', '', 'g') || '|' || lower(btrim(numero)) || '|' || lower(btrim(coalesce(complemento, '')))
               ) stored,
  entrada      jsonb,
  saida        jsonb,
  resultado    text check (resultado in ('viavel', 'sem_viabilidade', 'posse', 'indisponivel')),
  duracao_ms   int,
  erro         text
);
create index if not exists nio_viab_log_chave_idx on public.nio_viab_log (chave, criado_em desc);
alter table public.nio_viab_log enable row level security;
drop policy if exists nio_viab_log_ler on public.nio_viab_log;
create policy nio_viab_log_ler on public.nio_viab_log for select
  using (public.meu_perfil() in ('admin', 'backoffice'));
revoke all on public.nio_viab_log from anon;
revoke insert, update, delete, truncate on public.nio_viab_log from authenticated;
comment on table public.nio_viab_log is
  'Uma linha por consulta de viabilidade ao portal PAP (nível A). Cache de 7 dias por chave. Grava só o service_role (n8n). '
  'Nível A em espera desde 05/11 (login BO = SSO Microsoft).';

-- ─────────────────── 5a. mari_salvar_turno: instalacao_preferencia ───────────────────
create or replace function public.mari_salvar_turno(
  p_conversa uuid, p_texto text, p_tags jsonb default null, p_modelo text default null,
  p_tokens_in int default null, p_tokens_out int default null, p_latencia_ms int default null,
  p_upd jsonb default '{}'::jsonb, p_papel text default 'mari', p_erro jsonb default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  u jsonb := coalesce(p_upd, '{}'::jsonb);
  c public.mari_conversas;
  v_num  text;
  v_comp text;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;

  if coalesce(p_texto, '') <> '' or p_tags is not null then
    insert into public.mari_turnos (conversa_id, papel, texto, tags, modelo, tokens_in, tokens_out, latencia_ms)
    values (p_conversa, p_papel, coalesce(p_texto, ''), p_tags, p_modelo, p_tokens_in, p_tokens_out, p_latencia_ms);
  end if;

  if p_erro is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, coalesce(p_erro ->> 'no', 'mari_principal'), p_erro ->> 'mensagem', p_erro -> 'payload');
  end if;

  v_num  := case when u ? 'numero' then nullif(btrim(u ->> 'numero'), '') else c.numero end;
  v_comp := case when u ? 'complemento' then nullif(btrim(u ->> 'complemento'), '') else c.complemento end;

  update public.mari_conversas set
    etapa                  = coalesce(u ->> 'etapa', etapa),
    elegibilidade          = coalesce(u ->> 'elegibilidade', elegibilidade),
    segmento               = coalesce(u ->> 'segmento', segmento),
    mei                    = coalesce((u ->> 'mei')::boolean, mei),
    plano_escolhido        = case when u ? 'plano_escolhido' then u ->> 'plano_escolhido' else plano_escolhido end,
    forma_pagamento        = coalesce(u ->> 'forma_pagamento', forma_pagamento),
    visita_preferencia     = coalesce(u ->> 'visita_preferencia', visita_preferencia),   -- v1–v3 (histórico)
    instalacao_preferencia = coalesce(u ->> 'instalacao_preferencia', instalacao_preferencia),
    dados                  = dados || coalesce(u -> 'dados', '{}'::jsonb),
    lgpd_enviada           = lgpd_enviada or coalesce((u ->> 'lgpd_enviada')::boolean, false),
    upsell_oferecido       = upsell_oferecido or coalesce((u ->> 'upsell_oferecido')::boolean, false),
    nome_confiavel         = coalesce((u ->> 'nome_confiavel')::boolean, nome_confiavel),
    agendamento_retorno    = coalesce((u ->> 'agendamento_retorno')::timestamptz, agendamento_retorno),
    numero                 = v_num,
    complemento            = v_comp,
    dfv_resultado          = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null else dfv_resultado end,
    dfv_detalhe            = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null else dfv_detalhe end,
    -- viabilidade oficial: vem do n8n (nível A); endereço mudou → some.
    nio_viab_resultado     = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null
                                  else coalesce(u ->> 'nio_viab_resultado', nio_viab_resultado) end,
    nio_viab_velocidade    = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null
                                  else coalesce(u ->> 'nio_viab_velocidade', nio_viab_velocidade) end,
    nio_viab_interesse_id  = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null
                                  else coalesce(u ->> 'nio_viab_interesse_id', nio_viab_interesse_id) end,
    nio_viab_em            = case when row(v_num, v_comp) is distinct from row(c.numero, c.complemento) then null
                                  when u ? 'nio_viab_resultado' then now() else nio_viab_em end,
    processando_ate        = null
  where id = p_conversa;

  return jsonb_build_object('ok', true);
end;
$$;

-- ─────────────────── 5b. mari_handoff: venda remota + viabilidade oficial ───────────────────
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
  v_inst   text;
  v_viab   text;
  v_prox   text;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'motivo_recusa', 'conversa inexistente'); end if;

  -- Guard-rail 10: não repetir handoff.
  if c.status <> 'ativo' then
    return jsonb_build_object('ok', true, 'repetido', true, 'venda_id', c.venda_id);
  end if;

  d := c.dados || coalesce(l -> 'dados', '{}'::jsonb);
  v_inst := coalesce(nullif(btrim(c.instalacao_preferencia), ''), nullif(btrim(l ->> 'instalacao_preferencia'), ''));
  v_viab := coalesce(c.nio_viab_resultado, nullif(l ->> 'nio_viab_resultado', ''));
  if v_viab not in ('viavel', 'sem_viabilidade', 'posse', 'indisponivel') then v_viab := null; end if;

  -- Próximo passo do humano (venda remota, 05/11): sempre o mesmo texto, não depende do modelo.
  v_prox := case when p_motivo = 'dados_completos' then
    'Próximo passo: abrir pedido no portal PAP'
    || case when coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') is not null
            then ' (interesse ' || coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') || ' já criado na viabilidade)' else '' end
    || ' → mandar o link da biometria por esta conversa → agendar a instalação ('
    || coalesce(v_inst, 'preferência não informada') || ').' end;

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    handoff_briefing = concat_ws(E'\n', coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing), v_prox),   -- 0019: todo motivo
    dados = d, processando_ate = null,
    instalacao_preferencia = coalesce(v_inst, instalacao_preferencia),
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
    when v_viab = 'sem_viabilidade' then 'portal da Nio: endereço sem viabilidade'
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
      'Instalação: preferência ' || coalesce(v_inst, '?') || ' (data o nosso time confirma)',
      'Viabilidade Nio (portal): ' || case v_viab
                   when 'viavel' then 'viável' || coalesce(' · até ' || coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'), '')
                   when 'posse' then 'endereço já tem Nio (posse) — cliente disse que não tem; conferir no portal'
                   when 'indisponivel' then 'portal não respondeu — consultar no portal ao abrir o pedido'
                   else 'não consultada — consultar no portal ao abrir o pedido' end,
      'DFV: ' || case coalesce(c.dfv_resultado, '')
                   when 'viavel' then 'viável'
                   when 'viavel_predio' then 'viável (prédio) — conferir unidade'
                   when 'endereco_ocupado' then 'indica Nio ativo no endereço — confirmar com o cliente e no portal antes de abrir o pedido'
                   else 'conferir manualmente antes de abrir o pedido' end,
      nullif(v_brief, ''),
      v_prox);

    begin
      insert into public.vendas (
        status, origem, origem_ref, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
        cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento,
        trava_area, trava_cpf_valido, trava_contato_confirmado, observacoes,
        dfv_viabilidade, dfv_resultado, dfv_hp_livre, dfv_hcs, dfv_faixa_credito, dfv_classificacao,
        dfv_particao, dfv_origem, dfv_consultado_em,
        instalacao_preferencia, biometria_status,
        nio_viab_resultado, nio_viab_velocidade, nio_viab_interesse_id, nio_viab_em, nio_viab_origem)
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
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then now() end,
        v_inst, 'nao_enviada',
        v_viab, coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'),
        coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id'),
        case when v_viab is not null then coalesce(c.nio_viab_em, now()) end,
        case when v_viab is not null then 'mari' end)
      returning id into v_venda;

      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v_venda, 'mari_handoff', jsonb_strip_nulls(jsonb_build_object(
        'conversa_id', c.id, 'motivo', p_motivo, 'canal', c.canal, 'briefing', nullif(v_brief, ''),
        'instalacao_preferencia', v_inst, 'nio_viab_resultado', v_viab, 'dfv_resultado', c.dfv_resultado)));

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

-- ─────────────────────────────── 6. v_funil ───────────────────────────────
create or replace view public.v_funil with (security_invoker = true) as
select
  v.id, v.criado_em, v.criado_por, v.status, v.motivo_saida, v.interesse_futuro_em, v.origem, v.origem_ref,
  v.cliente_nome, v.cliente_cpf_cnpj, v.cliente_whatsapp, v.cliente_email, v.segmento,
  v.cep, v.logradouro, v.numero, v.complemento, v.bairro, v.cidade, v.uf, v.plano_id, v.forma_pagamento,
  v.vencimento_dia, v.comissao_prevista, v.comissao_paga, v.ciclo_pago, v.estorno_previsto,
  v.nio_pedido, v.nio_contrato, v.nio_situacao, v.nio_pendencia_cod, v.nio_pendencia_desc,
  v.biometria_status, v.biometria_em, v.vendido_em, v.agendamento_registrado_em, v.instalacao_agendada_para,
  v.instalado_em, v.ativado_em, v.docs_entregues_em, v.vendedor_id,
  v.trava_cobertura, v.trava_area, v.trava_sem_produto_ativo, v.trava_sem_cancelamento_30d, v.trava_cpf_valido,
  v.trava_contato_confirmado, v.nio_osab_em, v.nio_venda_valida, v.valor_mensal, v.comissao_nominal,
  v.comissao_adicionais, v.bonus_transicao_previsto, v.bonus_nmei_previsto, v.bonus_m10_potencial, v.primeiro_vencimento,
  v.dfv_viabilidade, v.dfv_consultado_em, v.dfv_consultado_por, v.dfv_faixa_credito, v.dfv_classificacao,
  v.dfv_hp_livre, v.dfv_hcs, v.dfv_dispensado, v.dfv_dispensa_motivo, v.dfv_origem, v.dfv_resultado, v.dfv_particao,
  p.nome as plano_nome, p.familia as plano_familia, p.velocidade as plano_velocidade, p.preco as plano_preco,
  p.codigo as plano_codigo, p.portfolio as plano_portfolio, p.variante as plano_variante, p.cluster as plano_cluster,
  p.preco_cartao as plano_preco_cartao, p.taxa_a_vista as plano_taxa_a_vista, p.isencao_meses as plano_isencao_meses,
  u.nome as vendedor_nome,
  case when v.status = '1_vendido' and v.agendamento_registrado_em is null and v.vendido_em is not null
       then round(extract(epoch from now() - v.vendido_em) / 3600, 2) end as horas_sem_agendamento,
  case when v.status = '0_qualificado' and v.biometria_status is distinct from 'validada'
       then round(extract(epoch from now() - v.criado_em) / 86400, 2) end as dias_esperando_biometria,
  v.instalado_em + interval '15 days' as docs_prazo_em,
  coalesce(v.ativado_em, v.instalado_em) + interval '30 days' as firme_em,
  (v.dfv_viabilidade in ('viavel', 'viavel_predio') and v.dfv_consultado_em >= now() - interval '7 days') as dfv_ok,
  case when v.dfv_consultado_em is not null then floor(extract(epoch from now() - v.dfv_consultado_em) / 86400)::int end as dfv_dias,
  coalesce(v.ativado_em, v.instalado_em) + interval '180 days' as downgrade_ate,
  -- 0023 (venda remota) ──────────────────────────────
  v.nio_viab_resultado, v.nio_viab_velocidade, v.nio_viab_interesse_id, v.nio_viab_endereco_id, v.nio_viab_em, v.nio_viab_origem,
  v.credito_resultado, v.credito_em, v.biometria_link, v.biometria_link_enviado_em, v.biometria_validada_em,
  v.instalacao_preferencia, v.instalacao_turno,
  (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') as nio_viab_ok,
  ((v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days')
    or (v.dfv_viabilidade in ('viavel', 'viavel_predio') and v.dfv_consultado_em >= now() - interval '7 days')
    or coalesce(v.dfv_dispensado, false)) as viab_ok,
  case when v.status = '0_qualificado' and v.biometria_status in ('pendente', 'com_risco') and v.biometria_link_enviado_em is not null
       then round(extract(epoch from now() - v.biometria_link_enviado_em) / 3600, 1) end as horas_biometria_pendente,
  case when v.status = '0_qualificado' and v.credito_resultado = 'pendente' and v.credito_em is not null
       then round(extract(epoch from now() - v.credito_em) / 3600, 1) end as horas_credito_pendente,
  -- "A agendar com > 4 h" conta do que vier depois: biometria validada ou pedido (vendido_em).
  greatest(v.biometria_validada_em, v.vendido_em) as agendar_desde
from public.vendas v
left join public.config_planos p on p.id = v.plano_id
left join public.usuarios u on u.id = v.vendedor_id;
