-- NIOGEN | 0168_operador_os.sql | 13/11/2026 — Claude Code (docs/Prompt_operador_os_etapa3_131126_0300.md, etapas 3c, 3f e 5b)
-- Levantamento que decidiu o desenho: docs/LEVANTAMENTO_consulta_os_131126_0955.md (Drive).
--
--   1. nio_osab ganha os campos que só o OSAB do PAINEL traz (Performance em Foco › Exportação - OSAB): fonte, hora da
--      atualização na Nio, data da ativação, andamento do atendimento de campo (BA) e a execução real.
--   2. config_os_estados: traduz o TEXTO da Nio para estado · vez · ação. Texto que não está aqui: guarda, avisa e NÃO mexe na venda.
--   3. os_leituras: cada leitura que MUDOU, com a origem (operador, osab, extensao). Leitura igual à anterior não grava nada.
--   4. os_andamento: o estado atual de cada OS (uma linha por pedido). A linha do tempo sai de os_leituras.
--   5. os_registrar_leitura(): a única porta de entrada. Traduz, grava se mudou e aplica o efeito na venda:
--        concluída (operador/extensão) → venda vira Instalada (o OSAB confirma depois e leva a Ativa, com a data real);
--        agendamento da Nio diferente do nosso → a data da Nio vence; exceção → aparece na Live (live_conferir).
--      A leitura do operador NUNCA tira venda do funil: cancelamento visto na Consulta OS vira exceção "conferir o motivo".
--   6. os_fila(): o que o operador deve ler agora (hoje · abertas · instaladas há menos de 30 dias). Só service_role (traz CPF).
--   7. aplicar_osab(): aceita a fonte painel (sem fg_venda_valida: concluído COM data real da instalação conta), roda também
--      com a chave de serviço (OSAB automático) e alimenta os_leituras. osab_importar(): arquivo já lido → importação aplicada.
--   8. live_conferir(): item novo 'os_excecao' com o valor em jogo e a ação.
-- Tudo com parceiro_id (regra 15), RLS e security_invoker nas views. Nada aqui toca a Mari, a cadência ou a v_funil.

-- ───────────────────────── 1. nio_osab: campos do painel ─────────────────────────
alter table public.nio_osab
  add column if not exists fonte             text not null default 'email' check (fonte in ('email', 'painel')),
  add column if not exists atualizado_nio_em timestamptz,
  add column if not exists data_ativacao     timestamptz,
  add column if not exists estado_ba         text,
  add column if not exists status_ba         text,
  add column if not exists motivo_ba         text,
  add column if not exists faixa_agendamento text,
  add column if not exists execucao_inicio   timestamptz,
  add column if not exists execucao_fim      timestamptz;

-- ───────────────────────── 2. config_os_estados ─────────────────────────
create table if not exists public.config_os_estados (
  id          bigint generated always as identity primary key,
  parceiro_id text not null default 'dharma',
  campo       text not null check (campo in ('status_ordem', 'status_agendamento', 'estado_ba')),
  texto       text not null,                                   -- o texto EXATO da Nio
  texto_norm  text generated always as (lower(btrim(texto))) stored,
  prefixo     boolean not null default false,                  -- true = vale para todo texto que COMEÇA assim (Draft-…, Reprovado…)
  estado      text check (estado in ('aberta', 'agendada', 'em_campo', 'concluida', 'pendencia_cliente', 'pendencia_tecnica',
                                     'cancelando', 'cancelada', 'reprovada', 'rascunho')),   -- nulo = ainda sem tradução
  vez         text check (vez in ('nio', 'time', 'cliente')),
  acao        text,                                            -- o que fazer, na língua de quem atende
  excecao     boolean not null default false,                  -- true = vai para a Live
  origem      text not null default 'seed' check (origem in ('seed', 'visto', 'admin')),   -- 'visto' = apareceu numa leitura e ninguém traduziu
  observacao  text,
  visto_em    timestamptz,
  criado_em   timestamptz not null default now(),
  unique (parceiro_id, campo, texto_norm)
);
comment on table public.config_os_estados is
  'Traduz o texto da Nio (Consulta OS e OSAB) para estado, vez e ação. Texto sem tradução (estado nulo) não mexe na venda.';

alter table public.config_os_estados enable row level security;
drop policy if exists config_os_estados_ler on public.config_os_estados;
create policy config_os_estados_ler on public.config_os_estados for select to authenticated
  using ((select public.meu_perfil()) is not null);
drop policy if exists config_os_estados_admin on public.config_os_estados;
create policy config_os_estados_admin on public.config_os_estados for all to authenticated
  using ((select public.meu_perfil()) = 'admin') with check ((select public.meu_perfil()) = 'admin');

-- Semente. 'Em Aprovisionamento', 'Concluído com sucesso' e 'ATRIBUÍDO' foram VISTOS na Consulta OS e no painel em 13/11.
-- Os outros status da ordem vêm do OSAB de exemplo do e-mail (referencia-nio/OSAB_28-09-26.xlsx) — o mesmo campo, ainda não
-- vistos numa ordem da Dharma.
insert into public.config_os_estados (campo, texto, prefixo, estado, vez, acao, excecao, observacao) values
  ('status_ordem', 'Em Aprovisionamento', false, 'aberta', 'nio', 'Aguardar a visita da Nio', false, 'visto na Consulta OS e no painel em 13/11/2026; com data vira "agendada"'),
  ('status_ordem', 'Concluído', false, 'concluida', 'time', 'Instalada: conferir os documentos em 15 dias', false, 'do OSAB de exemplo'),
  ('status_ordem', 'Pendência Cliente', false, 'pendencia_cliente', 'time', 'Pendência do cliente → ligar agora e remarcar', true, 'do OSAB de exemplo'),
  ('status_ordem', 'Pendência Técnica', false, 'pendencia_tecnica', 'nio', 'Pendência técnica da Nio → acompanhar e avisar o cliente', true, 'do OSAB de exemplo'),
  ('status_ordem', 'Em Cancelamento', false, 'cancelando', 'time', 'Em cancelamento na Nio → conferir o motivo e tentar reverter', true, 'do OSAB de exemplo'),
  ('status_ordem', 'Cancelado', false, 'cancelada', 'time', 'Cancelada pela Nio → conferir o motivo', true, 'do OSAB de exemplo'),
  ('status_ordem', 'Reprovado', true, 'reprovada', 'time', 'Reprovada pela Nio → conferir o motivo', true, 'do OSAB de exemplo (Reprovado Analise de Fraude-…)'),
  ('status_ordem', 'Draft-', true, 'rascunho', 'time', 'Pedido não concluído no portal → refazer o pedido', true, 'do OSAB de exemplo (Draft-…)'),
  ('status_agendamento', 'Concluído com sucesso', false, 'agendada', 'nio', null, false, 'visto na Consulta OS em 13/11/2026: o agendamento foi feito'),
  ('estado_ba', 'ATRIBUÍDO', false, 'agendada', 'nio', null, false, 'visto no painel em 13/11/2026: atendimento atribuído')
on conflict (parceiro_id, campo, texto_norm) do nothing;

create or replace function public._os_traduzir(p_parceiro text, p_campo text, p_texto text)
returns public.config_os_estados language sql stable set search_path = public as $$
  select c.* from public.config_os_estados c
   where c.parceiro_id = p_parceiro and c.campo = p_campo and nullif(btrim(p_texto), '') is not null
     and (c.texto_norm = lower(btrim(p_texto)) or (c.prefixo and lower(btrim(p_texto)) like c.texto_norm || '%'))
   order by (c.texto_norm = lower(btrim(p_texto))) desc, length(c.texto_norm) desc
   limit 1;
$$;
revoke all on function public._os_traduzir(text, text, text) from public, anon, authenticated;

-- ───────────────────────── 3. os_leituras ─────────────────────────
create table if not exists public.os_leituras (
  id                  bigint generated always as identity primary key,
  parceiro_id         text not null default 'dharma',
  pedido              text not null,
  venda_id            uuid references public.vendas (id) on delete set null,
  origem              text not null check (origem in ('operador', 'osab', 'extensao')),
  lido_em             timestamptz not null default now(),
  referencia_em       timestamptz not null default now(),      -- de quando é o dado na Nio (OSAB: hora da atualização do painel)
  status_ordem        text,
  status_agendamento  text,
  agendamento_data    date,
  janela              text,
  pendencia           text,
  caso                text,
  motivo_cancelamento text,
  numero_ba           text,
  estado_ba           text,
  status_ba           text,
  motivo_ba           text,
  execucao_inicio     timestamptz,
  execucao_fim        timestamptz,
  data_ativacao       timestamptz,
  estado              text,                                    -- traduzido na hora; nulo = texto sem tradução
  desconhecido        text[],                                  -- textos sem tradução desta leitura
  efeito              text,                                    -- o que a leitura fez na venda (nulo = nada)
  assinatura          text not null,
  importacao_id       uuid references public.importacoes (id) on delete set null
);
create index if not exists os_leituras_pedido_idx on public.os_leituras (parceiro_id, pedido, lido_em desc);
create index if not exists os_leituras_venda_idx on public.os_leituras (venda_id) where venda_id is not null;
comment on table public.os_leituras is 'Cada leitura da OS que MUDOU alguma coisa (operador, OSAB ou extensão). Leitura igual à anterior não é gravada.';

-- ───────────────────────── 4. os_andamento ─────────────────────────
create table if not exists public.os_andamento (
  parceiro_id         text not null default 'dharma',
  pedido              text not null,
  venda_id            uuid references public.vendas (id) on delete set null,
  estado              text,
  vez                 text,
  acao                text,
  excecao             boolean not null default false,
  excecao_desde       timestamptz,
  status_ordem        text,
  status_agendamento  text,
  agendamento_data    date,
  janela              text,
  pendencia           text,
  caso                text,
  motivo_cancelamento text,
  numero_ba           text,
  estado_ba           text,
  status_ba           text,
  motivo_ba           text,
  execucao_inicio     timestamptz,
  execucao_fim        timestamptz,
  data_ativacao       timestamptz,
  desconhecido        text[],
  agendamentos        int not null default 0,                  -- datas de agendamento diferentes já vistas (1 = instalou na 1ª visita)
  referencia_em       timestamptz,
  origem_ultima       text,
  primeira_leitura_em timestamptz not null default now(),
  mudou_em            timestamptz not null default now(),
  assinatura_operador text,
  assinatura_osab     text,
  assinatura_extensao text,
  primary key (parceiro_id, pedido)
);
create index if not exists os_andamento_venda_idx on public.os_andamento (venda_id) where venda_id is not null;
comment on table public.os_andamento is 'Estado atual de cada OS na Nio (uma linha por pedido). Fonte: os_registrar_leitura().';

alter table public.os_leituras enable row level security;
alter table public.os_andamento enable row level security;
-- Lê quem vê a venda (o RLS de vendas decide); admin e backoffice leem também a OS ainda sem venda casada. Escrita só pela função.
drop policy if exists os_leituras_ler on public.os_leituras;
create policy os_leituras_ler on public.os_leituras for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice') or exists (select 1 from public.vendas v where v.id = os_leituras.venda_id));
drop policy if exists os_andamento_ler on public.os_andamento;
create policy os_andamento_ler on public.os_andamento for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice') or exists (select 1 from public.vendas v where v.id = os_andamento.venda_id));
revoke all on public.os_leituras, public.os_andamento from anon;
grant select on public.os_leituras, public.os_andamento, public.config_os_estados to authenticated;
grant insert, update, delete on public.config_os_estados to authenticated;   -- o RLS restringe a admin

-- Quem pode gravar leitura: a chave de serviço (n8n / operador), admin e backoffice (extensão e OSAB pela tela) e o CLI.
create or replace function public._os_pode_gravar() returns boolean language sql stable set search_path = public as $$
  select session_user <> 'authenticator'
      or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
      or coalesce(public.meu_perfil(), '') in ('admin', 'backoffice');
$$;
revoke all on function public._os_pode_gravar() from public, anon;
grant execute on function public._os_pode_gravar() to authenticated, service_role;

-- ───────────────────────── 5. os_registrar_leitura ─────────────────────────
-- p_dados (todas as chaves são opcionais): status_ordem · status_agendamento · agendamento ("13/11/2026 - 08:00 às 12:00") ou
-- agendamento_data (AAAA-MM-DD) + janela · pendencia · caso · motivo_cancelamento · numero_ba · estado_ba · status_ba ·
-- motivo_ba · execucao_inicio · execucao_fim · data_ativacao. Nada de nome, CPF, telefone, e-mail ou endereço.
create or replace function public.os_registrar_leitura(p_pedido text, p_origem text, p_dados jsonb,
                                                       p_referencia_em timestamptz default null,
                                                       p_importacao_id uuid default null, p_parceiro text default 'dharma')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t           text := nullif(btrim(coalesce(p_pedido, '')), '');
  v_ref       timestamptz := coalesce(p_referencia_em, now());
  d           jsonb := coalesce(p_dados, '{}'::jsonb);
  limpo       text;
  f_status    text := nullif(btrim(d ->> 'status_ordem'), '');
  f_sag       text := nullif(btrim(d ->> 'status_agendamento'), '');
  f_data      date;
  f_janela    text := nullif(btrim(d ->> 'janela'), '');
  f_pend      text := nullif(nullif(btrim(d ->> 'pendencia'), ''), '-');
  f_caso      text := nullif(nullif(btrim(d ->> 'caso'), ''), '-');
  f_motivo    text := nullif(nullif(btrim(d ->> 'motivo_cancelamento'), ''), '-');
  f_ba        text := nullif(btrim(d ->> 'numero_ba'), '');
  f_eba       text := nullif(btrim(d ->> 'estado_ba'), '');
  f_sba       text := nullif(btrim(d ->> 'status_ba'), '');
  f_mba       text := nullif(btrim(d ->> 'motivo_ba'), '');
  f_ini       timestamptz := nullif(btrim(d ->> 'execucao_inicio'), '')::timestamptz;
  f_fim       timestamptz := nullif(btrim(d ->> 'execucao_fim'), '')::timestamptz;
  f_ativ      timestamptz := nullif(btrim(d ->> 'data_ativacao'), '')::timestamptz;
  m           text[];
  v_ass       text;
  a           public.os_andamento%rowtype;
  tem         boolean;
  v           public.vendas%rowtype;
  cs          public.config_os_estados;
  cb          public.config_os_estados;
  v_desc      text[] := '{}';
  v_estado    text;
  v_vez       text;
  v_acao      text;
  v_exc       boolean := false;
  v_fresco    boolean;
  v_efeito    text := null;
  v_quando    timestamptz;
  v_n         int;
  v_ainda     boolean;
begin
  if not public._os_pode_gravar() then
    raise exception 'Sem permissão para gravar leitura de OS.' using errcode = '42501';
  end if;
  if t is null then raise exception 'Pedido vazio.' using errcode = 'P0001'; end if;
  if p_origem not in ('operador', 'osab', 'extensao') then raise exception 'Origem inválida: %', p_origem using errcode = 'P0001'; end if;

  -- agendamento: "13/11/2026 - 08:00 às 12:00" (Consulta OS) ou data + janela separadas (OSAB)
  limpo := nullif(btrim(d ->> 'agendamento'), '');
  if limpo is not null and limpo <> '-' then
    m := regexp_match(limpo, '(\d{2})/(\d{2})/(\d{4})');
    if m is not null then f_data := make_date(m[3]::int, m[2]::int, m[1]::int); end if;
    m := regexp_match(limpo, '(\d{1,2}:\d{2})\D+(\d{1,2}:\d{2})');
    if m is not null then f_janela := m[1] || ' - ' || m[2]; end if;
  end if;
  if f_data is null and nullif(btrim(d ->> 'agendamento_data'), '') is not null then
    f_data := left(btrim(d ->> 'agendamento_data'), 10)::date;
  end if;
  if f_janela is not null then
    m := regexp_match(f_janela, '(\d{1,2}:\d{2})\D+(\d{1,2}:\d{2})');
    if m is not null then f_janela := lpad(m[1], 5, '0') || ' - ' || lpad(m[2], 5, '0'); end if;
  end if;

  v_ass := md5(concat_ws('|', coalesce(f_status, ''), coalesce(f_sag, ''), coalesce(f_data::text, ''), coalesce(f_janela, ''),
                         coalesce(f_pend, ''), coalesce(f_caso, ''), coalesce(f_motivo, ''), coalesce(f_ba, ''), coalesce(f_eba, ''),
                         coalesce(f_sba, ''), coalesce(f_mba, ''), coalesce(f_ini::text, ''), coalesce(f_fim::text, ''), coalesce(f_ativ::text, '')));

  select * into a from public.os_andamento where parceiro_id = p_parceiro and pedido = t for update;
  tem := found;
  -- Leitura igual à última da mesma origem: não grava nada (regra 19; lição da 0161). Exceção: a OS estava com texto sem
  -- tradução e alguém já traduziu — aí a mesma leitura é avaliada de novo.
  v_ainda := tem and a.desconhecido is not null
             and ((f_status is not null and (public._os_traduzir(p_parceiro, 'status_ordem', f_status)).estado is null)
               or (f_eba is not null and (public._os_traduzir(p_parceiro, 'estado_ba', f_eba)).estado is null));
  if tem and (a.desconhecido is null or v_ainda)
     and v_ass = (case p_origem when 'operador' then a.assinatura_operador when 'osab' then a.assinatura_osab else a.assinatura_extensao end) then
    return jsonb_build_object('ok', true, 'mudou', false, 'pedido', t, 'estado', a.estado);
  end if;

  select * into v from public.vendas x
   where nullif(btrim(x.nio_os), '') = t or nullif(btrim(x.nio_pedido), '') = t
   order by (x.status <> 'saida') desc, x.criado_em desc limit 1;

  -- A leitura mais antiga que a já guardada (OSAB do painel carregado horas antes) não rebaixa os campos comuns.
  v_fresco := not tem or a.referencia_em is null or v_ref >= a.referencia_em;

  -- tradução (texto sem tradução entra em config_os_estados como 'visto', para alguém traduzir)
  if f_status is not null then
    cs := public._os_traduzir(p_parceiro, 'status_ordem', f_status);
    if cs.id is null or cs.estado is null then
      v_desc := v_desc || ('status_ordem: ' || f_status);
      insert into public.config_os_estados (parceiro_id, campo, texto, origem, visto_em)
      values (p_parceiro, 'status_ordem', f_status, 'visto', now()) on conflict (parceiro_id, campo, texto_norm) do nothing;
    end if;
  end if;
  if f_eba is not null then
    cb := public._os_traduzir(p_parceiro, 'estado_ba', f_eba);
    if cb.id is null or cb.estado is null then
      v_desc := v_desc || ('estado_ba: ' || f_eba);
      insert into public.config_os_estados (parceiro_id, campo, texto, origem, visto_em)
      values (p_parceiro, 'estado_ba', f_eba, 'visto', now()) on conflict (parceiro_id, campo, texto_norm) do nothing;
    end if;
  end if;
  if f_sag is not null and (public._os_traduzir(p_parceiro, 'status_agendamento', f_sag)).id is null then
    insert into public.config_os_estados (parceiro_id, campo, texto, origem, visto_em)
    values (p_parceiro, 'status_agendamento', f_sag, 'visto', now()) on conflict (parceiro_id, campo, texto_norm) do nothing;
  end if;

  -- Estado da OS: manda o status da ordem; o BA só refina (em campo) enquanto a ordem está aberta.
  if f_status is not null and cs.estado is not null then
    v_estado := cs.estado; v_vez := cs.vez; v_acao := cs.acao; v_exc := cs.excecao;
    if v_estado = 'aberta' and cb.estado = 'em_campo' then
      v_estado := 'em_campo'; v_acao := coalesce(cb.acao, v_acao);
    elsif v_estado = 'aberta' and coalesce(f_data, case when tem then a.agendamento_data end) is not null then
      v_estado := 'agendada';
    end if;
    if cb.excecao then v_exc := true; v_acao := coalesce(cb.acao, v_acao); v_vez := coalesce(cb.vez, v_vez); end if;
  elsif f_status is null and tem then
    v_estado := a.estado; v_vez := a.vez; v_acao := a.acao; v_exc := a.excecao;   -- leitura sem status não apaga o estado
  end if;
  -- Pendência escrita pela Nio numa ordem aberta é exceção mesmo com status "normal".
  if f_pend is not null and upper(f_pend) not in ('OK', 'N/A') and coalesce(v_estado, 'aberta') in ('aberta', 'agendada', 'em_campo') then
    v_exc := true;
    v_acao := 'Pendência na Nio: ' || left(f_pend, 80) || ' → resolver e remarcar';
    v_vez := 'time';
  end if;
  -- Texto que ninguém traduziu: avisa (exceção), mas não mexe na venda.
  if cardinality(v_desc) > 0 then
    v_exc := true;
    v_acao := 'A Nio mostrou um texto novo (' || left(array_to_string(v_desc, ' · '), 100) || ') → avisar o Ricardo para traduzir (config_os_estados)';
    v_vez := 'time';
  end if;

  -- ───── efeito na venda (só com tradução completa; a leitura do operador nunca tira venda do funil) ─────
  if v.id is not null and cardinality(v_desc) = 0 and v_fresco then
    if f_status is not null and f_status is distinct from v.nio_situacao and p_origem <> 'osab' then
      update public.vendas set nio_situacao = f_status where id = v.id;   -- o OSAB grava o dele em aplicar_osab
    end if;
    -- agendamento: a data da Nio vence a nossa
    if f_data is not null and v.status in ('1_vendido', '2_aguardando_instalacao') then
      m := regexp_match(coalesce(f_janela, ''), '(\d{2}):(\d{2})');
      v_quando := ((f_data::text || ' ' || coalesce(m[1] || ':' || m[2], '08:00'))::timestamp) at time zone 'America/Sao_Paulo';
      if v.instalacao_agendada_para is null
         or (v.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date <> f_data then
        update public.vendas set instalacao_agendada_para = v_quando where id = v.id;
        insert into public.eventos_venda (venda_id, tipo, detalhe)
        values (v.id, 'os_agendamento', jsonb_strip_nulls(jsonb_build_object(
          'de', v.instalacao_agendada_para, 'para', v_quando, 'janela', f_janela, 'origem', p_origem, 'pedido', t)));
        v_efeito := case when v.instalacao_agendada_para is null then 'agendamento gravado' else 'agendamento atualizado pela Nio' end;
      end if;
    end if;
    -- concluída: a venda vira Instalada. O OSAB confirma (aplicar_osab) e leva a Ativa com a data real.
    if v_estado = 'concluida' and p_origem <> 'osab' and v.status in ('1_vendido', '2_aguardando_instalacao') then
      update public.vendas set status = '3_instalado', instalado_em = coalesce(f_fim, f_ativ, now()) where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v.id, 'os_instalada', jsonb_strip_nulls(jsonb_build_object(
        'status_ordem', f_status, 'origem', p_origem, 'pedido', t, 'sem_clique', true)));
      v_efeito := 'venda marcada como Instalada';
    end if;
  end if;
  -- Exceção só interessa enquanto a venda está em andamento.
  if v.id is not null and v.status not in ('1_vendido', '2_aguardando_instalacao') and cardinality(v_desc) = 0
     and not (v_estado in ('cancelando', 'cancelada') and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')) then
    v_exc := false;
  end if;

  insert into public.os_leituras (parceiro_id, pedido, venda_id, origem, referencia_em, status_ordem, status_agendamento, agendamento_data,
                                  janela, pendencia, caso, motivo_cancelamento, numero_ba, estado_ba, status_ba, motivo_ba,
                                  execucao_inicio, execucao_fim, data_ativacao, estado, desconhecido, efeito, assinatura, importacao_id)
  values (p_parceiro, t, v.id, p_origem, v_ref, f_status, f_sag, f_data, f_janela, f_pend, f_caso, f_motivo, f_ba, f_eba, f_sba, f_mba,
          f_ini, f_fim, f_ativ, v_estado, nullif(v_desc, '{}'), v_efeito, v_ass, p_importacao_id);

  select count(distinct l.agendamento_data) into v_n from public.os_leituras l
   where l.parceiro_id = p_parceiro and l.pedido = t and l.agendamento_data is not null;

  if not tem then
    insert into public.os_andamento (parceiro_id, pedido, venda_id, estado, vez, acao, excecao, excecao_desde, status_ordem, status_agendamento,
                                     agendamento_data, janela, pendencia, caso, motivo_cancelamento, numero_ba, estado_ba, status_ba, motivo_ba,
                                     execucao_inicio, execucao_fim, data_ativacao, desconhecido, agendamentos, referencia_em, origem_ultima,
                                     assinatura_operador, assinatura_osab, assinatura_extensao)
    values (p_parceiro, t, v.id, v_estado, v_vez, v_acao, v_exc, case when v_exc then now() end, f_status, f_sag, f_data, f_janela, f_pend, f_caso,
            f_motivo, f_ba, f_eba, f_sba, f_mba, f_ini, f_fim, f_ativ, nullif(v_desc, '{}'), v_n, v_ref, p_origem,
            case when p_origem = 'operador' then v_ass end, case when p_origem = 'osab' then v_ass end, case when p_origem = 'extensao' then v_ass end);
  else
    update public.os_andamento set
      venda_id            = coalesce(v.id, venda_id),
      -- campos comuns: só a leitura mais nova manda; o que só o OSAB traz (BA, execução, ativação) entra sempre que vier
      estado              = case when v_fresco then v_estado else estado end,
      vez                 = case when v_fresco then v_vez else vez end,
      acao                = case when v_fresco then v_acao else acao end,
      excecao             = case when v_fresco then v_exc else excecao end,
      excecao_desde       = case when not v_fresco then excecao_desde when v_exc then coalesce(excecao_desde, now()) else null end,
      status_ordem        = case when v_fresco then coalesce(f_status, status_ordem) else status_ordem end,
      status_agendamento  = case when v_fresco then coalesce(f_sag, status_agendamento) else status_agendamento end,
      agendamento_data    = case when v_fresco then coalesce(f_data, agendamento_data) else agendamento_data end,
      janela              = case when v_fresco then coalesce(f_janela, janela) else janela end,
      pendencia           = case when v_fresco and (f_status is not null or f_pend is not null) then f_pend else pendencia end,
      caso                = case when v_fresco and p_origem <> 'osab' then f_caso else caso end,
      motivo_cancelamento = case when v_fresco then coalesce(f_motivo, motivo_cancelamento) else motivo_cancelamento end,
      numero_ba           = coalesce(f_ba, numero_ba),
      estado_ba           = coalesce(f_eba, estado_ba),
      status_ba           = coalesce(f_sba, status_ba),
      motivo_ba           = coalesce(f_mba, motivo_ba),
      execucao_inicio     = coalesce(f_ini, execucao_inicio),
      execucao_fim        = coalesce(f_fim, execucao_fim),
      data_ativacao       = coalesce(f_ativ, data_ativacao),
      desconhecido        = case when v_fresco then nullif(v_desc, '{}') else desconhecido end,
      agendamentos        = v_n,
      referencia_em       = greatest(referencia_em, v_ref),
      origem_ultima       = p_origem,
      mudou_em            = now(),
      assinatura_operador = case when p_origem = 'operador' then v_ass else assinatura_operador end,
      assinatura_osab     = case when p_origem = 'osab' then v_ass else assinatura_osab end,
      assinatura_extensao = case when p_origem = 'extensao' then v_ass else assinatura_extensao end
    where parceiro_id = p_parceiro and pedido = t;
  end if;

  return jsonb_strip_nulls(jsonb_build_object('ok', true, 'mudou', true, 'pedido', t, 'venda_id', v.id, 'estado', v_estado,
    'excecao', v_exc, 'acao', v_acao, 'efeito', v_efeito, 'desconhecido', nullif(v_desc, '{}')));
end;
$$;
revoke all on function public.os_registrar_leitura(text, text, jsonb, timestamptz, uuid, text) from public, anon;
grant execute on function public.os_registrar_leitura(text, text, jsonb, timestamptz, uuid, text) to authenticated, service_role;

-- ───────────────────────── 6. os_fila ─────────────────────────
-- O que ler agora. p_tipo: 'hoje' (instalação marcada para hoje) · 'abertas' (toda OS em andamento) · 'instaladas' (há menos
-- de 30 dias, para pegar cancelamento). Devolve o CPF — por isso só a chave de serviço e o CLI chamam.
create or replace function public.os_fila(p_tipo text default 'abertas', p_parceiro text default 'dharma')
returns table (pedido text, cpf text, venda_id uuid, criada_em date, tipo text)
language plpgsql stable security definer set search_path = public as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if session_user = 'authenticator'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'Só o operador lê a fila de OS.' using errcode = '42501';
  end if;
  return query
  select x.ped, x.doc, x.id, x.criada, p_tipo
    from (
      select coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) as ped,
             regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') as doc,
             v.id, coalesce(v.nio_os_em, v.nio_pedido_em, v.vendido_em, v.criado_em)::date as criada,
             v.status, v.instalacao_agendada_para, v.instalado_em
        from public.vendas v
    ) x
    left join public.os_andamento a on a.parceiro_id = p_parceiro and a.pedido = x.ped
   where x.ped ~ '^\d{8}$' and length(x.doc) in (11, 14)
     and case p_tipo
           when 'hoje' then x.status in ('1_vendido', '2_aguardando_instalacao')
                            and hoje in ((x.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date, a.agendamento_data)
           when 'abertas' then x.status in ('1_vendido', '2_aguardando_instalacao')
           when 'instaladas' then x.status in ('3_instalado', '4_ativo_provisorio') and x.instalado_em > now() - interval '30 days'
           else false end
   order by x.instalacao_agendada_para nulls last, x.criada;
end;
$$;
revoke all on function public.os_fila(text, text) from public, anon, authenticated;
grant execute on function public.os_fila(text, text) to service_role;

-- ───────────────────────── v_os_andamento (tela Operações e ficha) ─────────────────────────
create or replace view public.v_os_andamento with (security_invoker = true) as
select a.parceiro_id, a.pedido, a.venda_id, a.estado, a.vez, a.acao, a.excecao, a.excecao_desde, a.status_ordem, a.status_agendamento,
       a.agendamento_data, a.janela, a.pendencia, a.caso, a.motivo_cancelamento, a.numero_ba, a.estado_ba, a.status_ba, a.motivo_ba,
       a.execucao_inicio, a.execucao_fim, a.data_ativacao, a.desconhecido, a.agendamentos, a.referencia_em, a.origem_ultima,
       a.primeira_leitura_em, a.mudou_em,
       case a.estado when 'aberta' then 'OS aberta' when 'agendada' then 'Agendada' when 'em_campo' then 'Técnico em campo'
                     when 'concluida' then 'Concluída' when 'pendencia_cliente' then 'Pendência do cliente'
                     when 'pendencia_tecnica' then 'Pendência técnica' when 'cancelando' then 'Em cancelamento'
                     when 'cancelada' then 'Cancelada pela Nio' when 'reprovada' then 'Reprovada pela Nio'
                     when 'rascunho' then 'Pedido não concluído' else 'Texto novo da Nio' end as estado_nome
  from public.os_andamento a;
grant select on public.v_os_andamento to authenticated;
revoke all on public.v_os_andamento from anon;


-- ───────────────────────── 7. aplicar_osab: fonte painel, chave de serviço e andamento da OS ─────────────────────────
-- Recriada a partir da produção (pg_get_functiondef em 13/11/2026); só três trechos mudam: quem pode aplicar, a regra do
-- "concluído" para a fonte painel e a chamada de os_registrar_leitura no fim de cada linha.
CREATE OR REPLACE FUNCTION public.aplicar_osab(p_importacao_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  imp         public.importacoes%rowtype;
  r           record;
  v_concl     boolean;
  v_cancel    boolean;
  v_risco     boolean;
  v_pcod      text;
  v_pdesc     text;
  v_novo      text;
  v_mudou     boolean;
  n_atual     int := 0;
  n_status    int := 0;
  n_saidas    int := 0;
  n_pend      int := 0;
  n_inval     int := 0;
  n_sem       int := 0;
  sem         jsonb;
  v_resumo    jsonb;
begin
  if not public._os_pode_gravar() then   -- 0168: admin, backoffice e a chave de serviço (OSAB automático do operador)
    raise exception 'Só admin ou backoffice aplicam importação.' using errcode = '42501';
  end if;

  select * into imp from public.importacoes where id = p_importacao_id for update;
  if not found then
    raise exception 'Importação % não encontrada.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.tipo <> 'osab' then
    raise exception 'Importação % não é OSAB.', p_importacao_id using errcode = 'P0001';
  end if;
  if imp.aplicado_em is not null then
    raise exception 'Esta importação já foi aplicada em %.', imp.aplicado_em using errcode = 'P0001';
  end if;

  -- Wipe-and-replace: o snapshot passa a ser só o arquivo atual.
  delete from public.nio_osab where importacao_id is distinct from p_importacao_id;

  for r in
    select o.*,
           v.id                        as venda_id,
           v.status                    as v_status,
           v.nio_situacao              as v_situacao,
           v.nio_pendencia_cod         as v_pcod,
           v.nio_pendencia_desc        as v_pdesc,
           v.nio_venda_valida          as v_valida
    from public.nio_osab o
    join public.vendas v on v.nio_pedido = o.pedido
    where o.importacao_id = p_importacao_id
  loop
    n_atual  := n_atual + 1;
    -- 0168: o OSAB do painel não traz fg_venda_valida — ali vale concluído COM a data real da instalação.
    v_concl  := r.situacao = 'Concluído'
                and (r.venda_valida is true or (r.fonte = 'painel' and r.venda_valida is null and r.data_fechamento is not null));
    v_cancel := public.osab_cancelada(r.situacao);
    v_risco  := public.osab_risco(r.venda_valida, r.desc_pendencia, concat_ws(' ', r.motivo_cancelamento, r.submotivo_cancelamento));

    -- Pendência: vazio no OSAB = mantém; OK / 00 / N/A = resolvida; resto = pendência da Nio.
    if coalesce(btrim(r.cod_pendencia), '') = '' and coalesce(btrim(r.desc_pendencia), '') = '' then
      v_pcod := r.v_pcod;
      v_pdesc := r.v_pdesc;
    elsif upper(btrim(coalesce(r.desc_pendencia, ''))) in ('OK', 'N/A') or btrim(coalesce(r.cod_pendencia, '')) in ('0', '00') then
      v_pcod := null;
      v_pdesc := null;
    else
      v_pcod := nullif(btrim(r.cod_pendencia), '');
      v_pdesc := nullif(btrim(r.desc_pendencia), '');
    end if;

    update public.vendas set
      nio_situacao             = coalesce(nullif(btrim(r.situacao), ''), nio_situacao),
      nio_pendencia_cod        = v_pcod,
      nio_pendencia_desc       = v_pdesc,
      nio_venda_valida         = coalesce(r.venda_valida, nio_venda_valida),
      instalacao_agendada_para = coalesce(instalacao_agendada_para, r.data_agendamento),
      instalado_em             = case when v_concl then coalesce(r.data_fechamento, instalado_em) else instalado_em end,   -- 0153: a data da Nio vence a hora da leitura
      ativado_em               = case when v_concl then coalesce(r.data_fechamento, ativado_em) else ativado_em end,
      nio_osab_em              = now()
    where id = r.venda_id;

    -- Status: só avança. Concluído/válida leva 2 → 3 → 4; cancelamento leva 1–2 → saída.
    v_novo := null;
    if v_concl and r.v_status in ('1_vendido', '2_aguardando_instalacao', '3_instalado') then   -- 0153: OS aberta sem agendamento no NIOGEN também avança
      if r.v_status in ('1_vendido', '2_aguardando_instalacao') then
        update public.vendas set status = '3_instalado' where id = r.venda_id;
      end if;
      update public.vendas set status = '4_ativo_provisorio' where id = r.venda_id;
      v_novo := '4_ativo_provisorio';
    elsif v_cancel and r.v_status in ('1_vendido', '2_aguardando_instalacao') then
      update public.vendas set
        status = 'saida',
        motivo_saida = 'Nio: ' || coalesce(nullif(btrim(r.motivo_cancelamento), ''), r.situacao)
                       || coalesce(' · ' || nullif(btrim(r.submotivo_cancelamento), ''), '')
      where id = r.venda_id;
      v_novo := 'saida';
      n_saidas := n_saidas + 1;
    elsif v_cancel and r.v_status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
      -- 0157: cancelou DEPOIS de instalar. O status não volta (a venda chegou lá); fica a marca, que a trilha do dinheiro lê.
      update public.vendas set
        cancelada_apos_instalar_em = coalesce(cancelada_apos_instalar_em, now()),
        cancelada_apos_instalar_motivo = coalesce(nullif(btrim(r.motivo_cancelamento), ''), r.situacao)
                                         || coalesce(' · ' || nullif(btrim(r.submotivo_cancelamento), ''), '')
      where id = r.venda_id and cancelada_apos_instalar_em is null;
      if found then
        insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
        values (r.venda_id, 'cancelada_apos_instalar', jsonb_strip_nulls(jsonb_build_object(
          'situacao', r.situacao, 'motivo', r.motivo_cancelamento, 'submotivo', r.submotivo_cancelamento,
          'importacao_id', p_importacao_id)), auth.uid());
      end if;
    end if;
    if v_novo is not null then n_status := n_status + 1; end if;
    if v_novo is null and v_pcod is not null and r.v_status in ('1_vendido', '2_aguardando_instalacao') then
      n_pend := n_pend + 1;
    end if;
    if v_risco then n_inval := n_inval + 1; end if;

    -- Evento só quando algo mudou (reimportar o mesmo arquivo não enche a linha do tempo).
    v_mudou := v_novo is not null
            or r.situacao is distinct from r.v_situacao
            or v_pcod is distinct from r.v_pcod
            or r.venda_valida is distinct from r.v_valida;
    if v_mudou then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (r.venda_id, 'osab', jsonb_strip_nulls(jsonb_build_object(
        'situacao', r.situacao, 'pendencia_cod', v_pcod, 'pendencia_desc', v_pdesc, 'venda_valida', r.venda_valida,
        'de', case when v_novo is not null then r.v_status end, 'para', v_novo,
        'dt_ref', r.dt_ref, 'importacao_id', p_importacao_id)), auth.uid());
      if v_risco then
        insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
        values (r.venda_id, 'osab_venda_invalida', jsonb_strip_nulls(jsonb_build_object(
          'venda_valida', r.venda_valida, 'pendencia_desc', r.desc_pendencia,
          'motivo', nullif(concat_ws(' · ', r.motivo_cancelamento, r.submotivo_cancelamento), ''),
          'importacao_id', p_importacao_id)), auth.uid());
      end if;
    end if;

    -- 0168: o andamento da OS recebe a mesma leitura (origem osab). Igual à anterior: não grava.
    perform public.os_registrar_leitura(r.pedido, 'osab', jsonb_strip_nulls(jsonb_build_object(
      'status_ordem', r.situacao,
      'agendamento_data', (r.data_agendamento at time zone 'America/Sao_Paulo')::date,
      'janela', r.faixa_agendamento,
      'pendencia', r.desc_pendencia,
      'motivo_cancelamento', nullif(concat_ws(' · ', nullif(btrim(r.motivo_cancelamento), ''), nullif(btrim(r.submotivo_cancelamento), '')), ''),
      'numero_ba', r.numero_ba, 'estado_ba', r.estado_ba, 'status_ba', r.status_ba, 'motivo_ba', r.motivo_ba,
      'execucao_inicio', r.execucao_inicio, 'execucao_fim', r.execucao_fim, 'data_ativacao', r.data_ativacao)),
      coalesce(r.atualizado_nio_em, r.dt_ref::timestamp at time zone 'America/Sao_Paulo', now()), p_importacao_id);
  end loop;

  -- Pedidos que a Nio enxerga e o NIOGEN não.
  select count(*), coalesce(jsonb_agg(s.pedido order by s.pedido) filter (where s.n <= 1000), '[]'::jsonb)
    into n_sem, sem
  from (
    select o.pedido, row_number() over (order by o.pedido) as n
    from public.nio_osab o
    where o.importacao_id = p_importacao_id
      and not exists (select 1 from public.vendas v where v.nio_pedido = o.pedido)
  ) s;

  v_resumo := coalesce(imp.resumo, '{}'::jsonb) || jsonb_build_object(
    'atualizadas', n_atual, 'mudaram_status', n_status, 'saidas', n_saidas, 'pendencias', n_pend,
    'invalidas', n_inval, 'sem_venda', n_sem, 'sem_venda_pedidos', sem);

  update public.importacoes set
    aplicadas   = n_atual,
    ignoradas   = coalesce(ignoradas, 0) + n_sem,
    resumo      = v_resumo,
    aplicado_em = now()
  where id = p_importacao_id;

  return v_resumo;
end;
$function$;

-- OSAB automático (3e): o operador baixa o arquivo do painel, lê as linhas e chama esta função. Arquivo vazio é recusado
-- (aplicar_osab troca o retrato inteiro: um download que falhou não pode apagar o que havia).
create or replace function public.osab_importar(p_arquivo text, p_linhas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_imp uuid;
  n     int;
begin
  if not public._os_pode_gravar() then
    raise exception 'Sem permissão para importar o OSAB.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_linhas) is distinct from 'array' then raise exception 'p_linhas precisa ser uma lista.' using errcode = 'P0001'; end if;
  select count(distinct nullif(btrim(x ->> 'pedido'), '')) into n from jsonb_array_elements(p_linhas) x;
  if coalesce(n, 0) = 0 then
    raise exception 'OSAB sem nenhum pedido: nada foi importado.' using errcode = 'P0001';
  end if;
  insert into public.importacoes (tipo, arquivo_nome, dt_ref, linhas, aplicadas, ignoradas, resumo)
  values ('osab', left(coalesce(nullif(btrim(p_arquivo), ''), 'OSAB automático'), 200),
          (select max(left(x ->> 'dt_ref', 10)::date) from jsonb_array_elements(p_linhas) x where nullif(x ->> 'dt_ref', '') is not null),
          jsonb_array_length(p_linhas), 0, jsonb_array_length(p_linhas) - n,
          jsonb_build_object('automatico', true, 'pedidos', n))
  returning id into v_imp;
  delete from public.nio_osab o using jsonb_array_elements(p_linhas) x where o.pedido = nullif(btrim(x ->> 'pedido'), '');
  insert into public.nio_osab
  select (jsonb_populate_record(null::public.nio_osab,
            x || jsonb_build_object('importacao_id', v_imp, 'fonte', coalesce(nullif(x ->> 'fonte', ''), 'painel')))).*
    from (select distinct on (nullif(btrim(e ->> 'pedido'), '')) e as x
            from jsonb_array_elements(p_linhas) e
           where nullif(btrim(e ->> 'pedido'), '') is not null
           order by nullif(btrim(e ->> 'pedido'), ''), e ->> 'atualizado_nio_em' desc nulls last) s;
  return public.aplicar_osab(v_imp) || jsonb_build_object('importacao_id', v_imp);
end;
$$;
revoke all on function public.osab_importar(text, jsonb) from public, anon, authenticated;
grant execute on function public.osab_importar(text, jsonb) to service_role;

-- ───────────────────────── 8. live_conferir: exceção da OS ─────────────────────────
-- Recriada a partir da produção (pg_get_functiondef em 13/11/2026); só entra o item (i) 'os_excecao'.
CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar'
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select max(e.criado_em) as em from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status') ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;
revoke all on function public.live_conferir() from public, anon;
grant execute on function public.live_conferir() to authenticated;
