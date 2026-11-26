-- NIOGEN | supabase/migrations/0415_ferramentas.sql | 26/11/2026 — Claude Code (Opus 5.5)
-- Resumo: FERRAMENTAS — uma tela que mostra, de cada ferramenta paga do ecossistema (Vultr, n8n, Supabase, Chatwoot, Claude,
-- OpenAI, Meta, domínio, site…), se ESTÁ NO AR, QUANTO CUSTA e QUANDO VENCE (Ricardo, 26/11/2026: "São muitas ferramentas que
-- usamos em todo ecossistema … e todas envolvem pagamentos. Acha viável construirmos uma tela?" → "Sim, monta").
-- Motivo de fundo: a queda de 16/11 (VPS do n8n parada por falta de pagamento na Vultr, ~1h30 sem Mari, Live e Pulso — 0230).
--   1. ferramentas — o cadastro (o que é, como se confere, custo, moeda, como cobra, dia/vencimento, rateio com a Vero, link do painel).
--      Escrita só por ferramenta_salvar() (admin), com autor e hora.
--   2. ferramentas_leituras — cada conferência automática (guarda 30 dias). Escrita só por ferramentas_registrar() (service_role),
--      chamada pela edge function `ferramentas-vigia` de hora em hora (pg_cron). O vencimento do domínio vem do RDAP do Registro.br.
--   3. ferramentas_painel() — a tela inteira numa chamada (regra 19): estado de cada uma, custo do mês em R$, custo por plano
--      instalado no mês, o que vence nos próximos dias e o que falta preencher. Só admin (é dinheiro).
--      O n8n e a Meta não dependem da edge: o n8n sai do vigia de 2 em 2 min (vigia_n8n_leituras, 0230) e a Meta do saldo coletado (0078).
--   4. conferencia_itens ganha o item 40 "Ferramentas": alguma fora do ar, vigia parado há 3 h ou vencimento perto.
-- Regra 15: parceiro_id na tabela de cadastro; URLs, limites e cotação em config_regras.ferramentas_vigia; nada fixo na tela.
-- Regra 20: (1) não é lead — não se aplica · (2) ferramenta parada ou vencendo vira alerta na conferência das 7h10 · (3) o cadastro
--   muda só por ferramenta_salvar e a leitura só por ferramentas_registrar · (4) fonte única: a conferência automática para o estado,
--   o painel do fornecedor para o valor (lançado aqui) · (5) item 40 em conferencia_itens.
-- Segredos (regra 5): VULTR_API_KEY só em Supabase › Edge Functions › Secrets; nada de chave aqui nem na tela.
begin;

-- 0. config ----------------------------------------------------------------------------------------------------------------
insert into public.config_regras (chave, valor, descricao) values
  ('ferramentas_vigia',
   jsonb_build_object('ligado', true, 'aviso_dias', 5, 'velho_horas', 3, 'timeout_ms', 10000,
                      'cotacao_url', 'https://economia.awesomeapi.com.br/json/last/USD-BRL',
                      'cotacao_usd', null, 'cotacao_em', null),
   'Ferramentas (0415): pg_cron de hora em hora → edge ferramentas-vigia. aviso_dias = quantos dias antes do vencimento vira atenção; velho_horas = leitura mais velha que isso = sem leitura. cotacao_usd é gravada pela edge (dólar comercial).')
on conflict (chave) do nothing;

-- 1. cadastro ---------------------------------------------------------------------------------------------------------------
create table if not exists public.ferramentas (
  id                  text primary key check (id ~ '^[a-z0-9_]{2,40}$'),
  parceiro_id         text not null default 'dharma',
  nome                text not null,
  categoria           text not null default 'infra' check (categoria in ('infra', 'ia', 'atendimento', 'dominio', 'midia', 'escritorio')),
  para_que            text,
  checagem            text not null default 'nenhuma'
                      check (checagem in ('nenhuma', 'http', 'chatwoot_api', 'statuspage', 'rdap', 'vultr_conta', 'vultr_instancia', 'n8n_vigia', 'meta_saldo')),
  checagem_alvo       text,                         -- URL, domínio ou IP, conforme a checagem
  custo_valor         numeric(12, 2) check (custo_valor is null or custo_valor >= 0),
  custo_moeda         text not null default 'BRL' check (custo_moeda in ('BRL', 'USD')),
  cobranca            text not null default 'mensal' check (cobranca in ('mensal', 'anual', 'uso', 'pre_pago', 'gratis', 'incluso')),
  dia_cobranca        int check (dia_cobranca between 1 and 31),
  proximo_vencimento  date,
  rateio_pct          numeric(5, 2) not null default 100 check (rateio_pct between 0 and 100),   -- parte que é da Dharma (a VPS é dividida com a Vero)
  forma_pagamento     text,                         -- "cartão", "boleto", "Pix"… nunca número de cartão
  painel_url          text,                         -- onde se paga / vê a fatura
  ativo               boolean not null default true,
  ordem               int not null default 100,
  obs                 text,
  atualizado_por      uuid,
  atualizado_em       timestamptz not null default now()
);
comment on table public.ferramentas is
  'Ferramentas pagas do ecossistema (0415): estado, custo e vencimento. Escrita só por ferramenta_salvar() (admin); leitura automática em ferramentas_leituras.';

create table if not exists public.ferramentas_leituras (
  id             bigint generated always as identity primary key,
  ferramenta_id  text not null references public.ferramentas (id) on update cascade on delete cascade,
  lido_em        timestamptz not null default now(),
  nivel          text not null check (nivel in ('ok', 'atencao', 'parado', 'sem_leitura')),
  texto          text,
  ms             int,
  dado           jsonb
);
create index if not exists ferramentas_leituras_ult on public.ferramentas_leituras (ferramenta_id, lido_em desc);

alter table public.ferramentas enable row level security;
alter table public.ferramentas_leituras enable row level security;
drop policy if exists ferramentas_ler on public.ferramentas;
create policy ferramentas_ler on public.ferramentas for select to authenticated using ((select public.meu_perfil()) = 'admin');
drop policy if exists ferramentas_leituras_ler on public.ferramentas_leituras;
create policy ferramentas_leituras_ler on public.ferramentas_leituras for select to authenticated using ((select public.meu_perfil()) = 'admin');
revoke all on public.ferramentas, public.ferramentas_leituras from anon;

-- o que já se sabe (valor nulo = a preencher na tela)
insert into public.ferramentas (id, nome, categoria, para_que, checagem, checagem_alvo, custo_valor, custo_moeda, cobranca, painel_url, ordem, obs) values
  ('vultr', 'Vultr (conta)', 'infra', 'As duas VPS: a do n8n (45.32.161.130, dividida com a Vero) e a niogen-portal-br (216.128.168.202, robôs do portal)',
     'vultr_conta', null, null, 'USD', 'pre_pago', 'https://my.vultr.com/billing/', 10,
     'Em 16/11 a VPS do n8n parou por falta de pagamento. Sem VULTR_API_KEY a tela não lê saldo nem as VPS.'),
  ('n8n', 'n8n (VPS 45.32.161.130)', 'infra', 'Mari, cadência, importações, Pulso', 'n8n_vigia', null, null, 'USD', 'incluso', null, 20,
     'Cobrado dentro da Vultr. Conferido de 2 em 2 min pelo vigia do n8n.'),
  ('portal_br', 'VPS niogen-portal-br', 'infra', 'Operador do portal PAP, crédito, Consulta OS, Dashboard', 'vultr_instancia', '216.128.168.202', null, 'USD', 'incluso', null, 30,
     'Cobrada dentro da Vultr. Sem porta pública: o estado vem da API da Vultr.'),
  ('supabase', 'Supabase (Pro + Small)', 'infra', 'Banco único do NIOGEN e da Mari, edge functions, backup diário', 'statuspage', 'https://status.supabase.com/api/v2/status.json',
     39.83, 'USD', 'mensal', 'https://supabase.com/dashboard/org/_/billing', 40, 'Pro US$ 25 + máquina Small ~US$ 14,83 (INFRA, 14/11). Conferir o valor na fatura.'),
  ('chatwoot', 'Chatwoot (conta Nio)', 'atendimento', 'Caixa do WhatsApp da Mari (inbox 153431)', 'chatwoot_api', 'https://app.chatwoot.com/api', null, 'USD', 'mensal',
     'https://app.chatwoot.com/app/accounts/195428/settings/billing', 50, 'Plano Startups.'),
  ('claude_api', 'Claude API (Anthropic)', 'ia', 'A cabeça da Mari, Sugerir resposta', 'statuspage', 'https://status.claude.com/api/v2/status.json', null, 'USD', 'uso',
     'https://console.anthropic.com/settings/billing', 60, 'Cobrança por uso: lançar a média do mês.'),
  ('openai', 'OpenAI (transcrição)', 'ia', 'Transcrição dos áudios da Mari (gpt-4o-mini-transcribe)', 'statuspage', 'https://status.openai.com/api/v2/status.json', null, 'USD', 'uso',
     'https://platform.openai.com/settings/organization/billing/overview', 70, 'Cobrança por minuto de áudio.'),
  ('meta_ads', 'Meta Ads (CA Nio)', 'midia', 'Anúncios — gasto e cobrança da conta', 'meta_saldo', null, null, 'BRL', 'uso',
     'https://business.facebook.com/billing_hub/', 80, 'Mídia: aparece aqui pelo vencimento, mas fica fora do total das ferramentas.'),
  ('waba', 'WhatsApp Cloud API (WABA Nio)', 'atendimento', 'Conversas cobradas pela Meta (templates de marketing e utilidade)', 'nenhuma', null, null, 'BRL', 'uso',
     'https://business.facebook.com/billing_hub/', 90, 'O estado do número é vigiado no Pulso.'),
  ('dominio', 'Domínio dharmatelecom.com.br', 'dominio', 'Endereço do NIOGEN e da Dharma (Registro.br)', 'rdap', 'dharmatelecom.com.br', null, 'BRL', 'anual',
     'https://registro.br/painel/', 100, 'O vencimento vem sozinho do Registro.br.'),
  ('site', 'Site do NIOGEN (GitHub Pages)', 'infra', 'As telas do NIOGEN', 'http', 'https://ricardocandrade-eng.github.io/niogen/', 0, 'BRL', 'gratis', null, 110, null),
  ('cloudflare', 'Cloudflare (DNS)', 'dominio', 'DNS do domínio', 'statuspage', 'https://www.cloudflarestatus.com/api/v2/status.json', 0, 'BRL', 'gratis',
     'https://dash.cloudflare.com/', 120, null),
  ('zoho', 'Zoho Mail', 'escritorio', 'E-mail que manda a NFS-e para a Nio', 'nenhuma', null, null, 'BRL', 'mensal', 'https://mail.zoho.com/', 130, null)
on conflict (id) do nothing;

-- 2. leitura (service_role) --------------------------------------------------------------------------------------------------
-- p_leituras: [{id, nivel, texto, ms, dado}] · p_cotacao: dólar comercial (null = não leu)
create or replace function public.ferramentas_registrar(p_leituras jsonb, p_cotacao numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r jsonb; n int := 0; v_exp date;
begin
  if auth.role() <> 'service_role' and session_user <> 'postgres' then
    raise exception 'Só o vigia grava leitura.' using errcode = '42501';
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_leituras, '[]'::jsonb)) loop
    if not exists (select 1 from public.ferramentas where id = r ->> 'id') then continue; end if;
    insert into public.ferramentas_leituras (ferramenta_id, nivel, texto, ms, dado)
    values (r ->> 'id',
            case when r ->> 'nivel' in ('ok', 'atencao', 'parado', 'sem_leitura') then r ->> 'nivel' else 'sem_leitura' end,
            left(r ->> 'texto', 400), nullif(r ->> 'ms', '')::int, r -> 'dado');
    -- vencimento automático (RDAP do domínio)
    v_exp := nullif(r #>> '{dado,expira}', '')::date;
    if v_exp is not null then
      update public.ferramentas set proximo_vencimento = v_exp where id = r ->> 'id' and proximo_vencimento is distinct from v_exp;
    end if;
    n := n + 1;
  end loop;
  if p_cotacao is not null and p_cotacao between 1 and 50 then
    update public.config_regras
       set valor = valor || jsonb_build_object('cotacao_usd', round(p_cotacao, 4), 'cotacao_em', now())
     where chave = 'ferramentas_vigia';
  end if;
  delete from public.ferramentas_leituras where lido_em < now() - interval '30 days';
  return jsonb_build_object('gravadas', n);
end $$;
revoke all on function public.ferramentas_registrar(jsonb, numeric) from public, anon, authenticated;
grant execute on function public.ferramentas_registrar(jsonb, numeric) to service_role;

-- o que a edge confere (só as checagens que ela faz)
create or replace function public.ferramentas_para_vigiar()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cfg', coalesce((select valor from public.config_regras where chave = 'ferramentas_vigia'), '{}'::jsonb),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'checagem', checagem, 'alvo', checagem_alvo) order by ordem)
                         from public.ferramentas
                        where ativo and checagem in ('http', 'chatwoot_api', 'statuspage', 'rdap', 'vultr_conta', 'vultr_instancia')), '[]'::jsonb));
$$;
revoke all on function public.ferramentas_para_vigiar() from public, anon, authenticated;
grant execute on function public.ferramentas_para_vigiar() to service_role;

-- 3. a tela ------------------------------------------------------------------------------------------------------------------
-- estado de uma ferramenta: {nivel, texto, lido_em, dado}
create or replace function public._ferramenta_estado(p_id text, p_checagem text, p_velho_h int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l record; v record; q record; m record;
begin
  if p_checagem = 'nenhuma' then
    return jsonb_build_object('nivel', 'sem_leitura', 'texto', 'sem conferência automática');
  elsif p_checagem = 'n8n_vigia' then
    select * into q from public.vigia_n8n_quedas where ate is null limit 1;
    select * into v from public.vigia_n8n_leituras order by lido_em desc limit 1;
    if v.id is null then return jsonb_build_object('nivel', 'sem_leitura', 'texto', 'o vigia do n8n ainda não leu'); end if;
    if v.lido_em < now() - interval '10 minutes' then
      return jsonb_build_object('nivel', 'sem_leitura', 'texto', 'o vigia do n8n não lê há mais de 10 min', 'lido_em', v.lido_em);
    end if;
    if q.id is not null and q.falhas >= 2 then
      return jsonb_build_object('nivel', 'parado', 'lido_em', v.lido_em,
        'texto', format('fora do ar desde %s (%s)', to_char(q.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), coalesce(q.ultimo_erro, 'healthz falhou')));
    end if;
    return jsonb_build_object('nivel', case when v.ok then 'ok' else 'atencao' end, 'lido_em', v.lido_em,
      'texto', case when v.ok then format('no ar · responde em %s ms', v.ms) else coalesce(v.erro, 'healthz falhou') end);
  elsif p_checagem = 'meta_saldo' then
    select * into m from public.meta_ads_conta_saldo where parceiro_id = 'dharma' order by coletado_em desc limit 1;
    if m.act_id is null then return jsonb_build_object('nivel', 'sem_leitura', 'texto', 'saldo da conta ainda não coletado'); end if;
    return jsonb_build_object(
      'nivel', case when m.coletado_em < now() - interval '6 hours' then 'sem_leitura'
                    when m.limite_cobranca > 0 and m.saldo >= 0.85 * m.limite_cobranca then 'atencao' else 'ok' end,
      'lido_em', m.coletado_em,
      'texto', concat_ws(' · ', format('em aberto R$ %s', to_char(m.saldo, 'FM999G990D00')),
                         case when m.limite_cobranca > 0 then format('limite R$ %s', to_char(m.limite_cobranca, 'FM999G990D00')) end),
      'dado', jsonb_build_object('saldo', m.saldo, 'limite', m.limite_cobranca, 'vence', m.proxima_cobranca_em));
  end if;
  select * into l from public.ferramentas_leituras where ferramenta_id = p_id order by lido_em desc limit 1;
  if l.id is null then return jsonb_build_object('nivel', 'sem_leitura', 'texto', 'ainda não conferida'); end if;
  if l.lido_em < now() - make_interval(hours => p_velho_h) then
    return jsonb_build_object('nivel', 'sem_leitura', 'texto', 'leitura velha — o vigia parou?', 'lido_em', l.lido_em, 'dado', l.dado);
  end if;
  return jsonb_build_object('nivel', l.nivel, 'texto', l.texto, 'lido_em', l.lido_em, 'dado', l.dado);
end $$;
revoke all on function public._ferramenta_estado(text, text, int) from public, anon, authenticated;

-- próximo vencimento: o gravado, ou o próximo "dia de cobrança" do mês
create or replace function public._ferramenta_vence(p_venc date, p_dia int, p_cobranca text, p_hoje date)
returns date language sql immutable set search_path = public as $$
  select case
    when p_venc is not null and (p_venc >= p_hoje or p_cobranca not in ('mensal')) then p_venc
    when p_dia is not null and p_cobranca in ('mensal', 'pre_pago', 'uso') then
      (select min(d) from (select (date_trunc('month', p_hoje) + make_interval(months => k))::date
                                  + (least(p_dia, extract(day from (date_trunc('month', p_hoje) + make_interval(months => k + 1) - interval '1 day'))::int) - 1) as d
                             from generate_series(0, 1) k) z where d >= p_hoje)
    else p_venc end;
$$;

create or replace function public.ferramentas_painel()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg     jsonb := coalesce((select valor from public.config_regras where chave = 'ferramentas_vigia'), '{}'::jsonb);
  v_aviso int := coalesce((cfg ->> 'aviso_dias')::int, 5);
  v_velho int := coalesce((cfg ->> 'velho_horas')::int, 3);
  v_usd   numeric := nullif(cfg ->> 'cotacao_usd', '')::numeric;
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini   date := date_trunc('month', v_hoje)::date;
  itens   jsonb := '[]'::jsonb;
  r record; e jsonb; v_venc date; v_mes numeric; v_nivel text; v_alertas text[];
  v_total numeric := 0; v_preencher int := 0; v_inst int; v_meta_gasto numeric;
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception 'As ferramentas são só do admin.' using errcode = '42501';
  end if;
  for r in select * from public.ferramentas where ativo and parceiro_id = 'dharma' order by ordem, nome loop
    e := public._ferramenta_estado(r.id, r.checagem, v_velho);
    v_venc := coalesce(public._ferramenta_vence(r.proximo_vencimento, r.dia_cobranca, r.cobranca, v_hoje),
                       nullif(e #>> '{dado,vence}', '')::date);
    -- custo do mês na moeda da Dharma (anual ÷ 12; rateio com a Vero)
    v_mes := case when r.cobranca in ('gratis', 'incluso') then 0
                  when r.custo_valor is null then null
                  else r.custo_valor / case when r.cobranca = 'anual' then 12 else 1 end
                       * r.rateio_pct / 100 * case when r.custo_moeda = 'USD' then coalesce(v_usd, 0) else 1 end end;
    if r.categoria <> 'midia' then
      v_total := v_total + coalesce(v_mes, 0);
      if v_mes is null then v_preencher := v_preencher + 1; end if;
    end if;
    v_nivel := e ->> 'nivel';
    v_alertas := '{}';
    if v_venc is not null and v_venc < v_hoje then
      v_alertas := v_alertas || format('venceu em %s', to_char(v_venc, 'DD/MM'));
      v_nivel := 'parado';
    elsif v_venc is not null and v_venc - v_hoje <= v_aviso then
      v_alertas := v_alertas || case when v_venc = v_hoje then 'vence hoje' else format('vence em %s dia(s) (%s)', v_venc - v_hoje, to_char(v_venc, 'DD/MM')) end;
      if v_nivel in ('ok', 'sem_leitura') then v_nivel := 'atencao'; end if;
    end if;
    itens := itens || jsonb_build_object(
      'id', r.id, 'nome', r.nome, 'categoria', r.categoria, 'para_que', r.para_que, 'checagem', r.checagem, 'checagem_alvo', r.checagem_alvo,
      'custo_valor', r.custo_valor, 'custo_moeda', r.custo_moeda, 'cobranca', r.cobranca, 'dia_cobranca', r.dia_cobranca,
      'proximo_vencimento', r.proximo_vencimento, 'rateio_pct', r.rateio_pct, 'forma_pagamento', r.forma_pagamento,
      'painel_url', r.painel_url, 'obs', r.obs, 'ordem', r.ordem,
      'nivel', v_nivel, 'estado', e, 'vence', v_venc, 'dias', case when v_venc is not null then v_venc - v_hoje end,
      'custo_mes_brl', round(v_mes, 2), 'alertas', to_jsonb(v_alertas),
      'a_preencher', v_mes is null and r.categoria <> 'midia');
  end loop;

  select count(*) into v_inst from public.vendas v
   where v.instalado_em is not null and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
     and (v.instalado_em at time zone 'America/Sao_Paulo')::date between v_ini and v_hoje;
  select coalesce(sum(gasto), 0) into v_meta_gasto from public.meta_ads_diario where dia between v_ini and v_hoje;

  return jsonb_build_object(
    'hoje', v_hoje, 'agora', now(), 'aviso_dias', v_aviso,
    'cotacao_usd', v_usd, 'cotacao_em', cfg ->> 'cotacao_em',
    'vigia_lido_em', (select max(lido_em) from public.ferramentas_leituras),
    'total_mes_brl', round(v_total, 2), 'a_preencher', v_preencher,
    'planos_mes', v_inst, 'custo_por_plano', case when v_inst > 0 then round(v_total / v_inst, 2) end,
    'meta_gasto_mes', v_meta_gasto,
    'itens', itens);
end $$;
revoke all on function public.ferramentas_painel() from public, anon;
grant execute on function public.ferramentas_painel() to authenticated;

-- 4. salvar (admin) — cadastra ou altera; só os campos que vierem em p
create or replace function public.ferramenta_salvar(p_id text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id text := lower(trim(p_id));
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception 'Só o admin mexe nas ferramentas.' using errcode = '42501';
  end if;
  if v_id is null or v_id !~ '^[a-z0-9_]{2,40}$' then raise exception 'Identificador inválido (minúsculas, números e _).'; end if;
  if not exists (select 1 from public.ferramentas where id = v_id) then
    if coalesce(trim(p ->> 'nome'), '') = '' then raise exception 'Ferramenta nova precisa de nome.'; end if;
    insert into public.ferramentas (id, nome) values (v_id, trim(p ->> 'nome'));
  end if;
  update public.ferramentas f set
    nome               = case when p ? 'nome' then coalesce(nullif(trim(p ->> 'nome'), ''), f.nome) else f.nome end,
    categoria          = case when p ? 'categoria' then p ->> 'categoria' else f.categoria end,
    para_que           = case when p ? 'para_que' then nullif(trim(p ->> 'para_que'), '') else f.para_que end,
    custo_valor        = case when p ? 'custo_valor' then nullif(p ->> 'custo_valor', '')::numeric else f.custo_valor end,
    custo_moeda        = case when p ? 'custo_moeda' then p ->> 'custo_moeda' else f.custo_moeda end,
    cobranca           = case when p ? 'cobranca' then p ->> 'cobranca' else f.cobranca end,
    dia_cobranca       = case when p ? 'dia_cobranca' then nullif(p ->> 'dia_cobranca', '')::int else f.dia_cobranca end,
    proximo_vencimento = case when p ? 'proximo_vencimento' then nullif(p ->> 'proximo_vencimento', '')::date else f.proximo_vencimento end,
    rateio_pct         = case when p ? 'rateio_pct' then coalesce(nullif(p ->> 'rateio_pct', '')::numeric, 100) else f.rateio_pct end,
    forma_pagamento    = case when p ? 'forma_pagamento' then nullif(trim(p ->> 'forma_pagamento'), '') else f.forma_pagamento end,
    painel_url         = case when p ? 'painel_url' then nullif(trim(p ->> 'painel_url'), '') else f.painel_url end,
    obs                = case when p ? 'obs' then nullif(trim(p ->> 'obs'), '') else f.obs end,
    ativo              = case when p ? 'ativo' then coalesce((p ->> 'ativo')::boolean, true) else f.ativo end,
    atualizado_por     = auth.uid(),
    atualizado_em      = now()
  where f.id = v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.ferramenta_salvar(text, jsonb) from public, anon;
grant execute on function public.ferramenta_salvar(text, jsonb) to authenticated;

-- 5. agenda: de hora em hora, no minuto 7 --------------------------------------------------------------------------------------
-- (a cópia local do portão não tem pg_cron: lá o agendamento é pulado)
do $agenda$
begin
  if not exists (select 1 from pg_namespace where nspname = 'cron') then
    raise notice '0415: sem pg_cron (cópia local) — agendamento pulado';
    return;
  end if;
  execute $x$select cron.unschedule('ferramentas_vigia') where exists (select 1 from cron.job where jobname = 'ferramentas_vigia')$x$;
  execute $x$select cron.schedule('ferramentas_vigia', '7 * * * *', $cron$
  select net.http_post(
    url := 'https://zlrfwbkblytnokuexjti.supabase.co/functions/v1/ferramentas-vigia',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 60000)
  where coalesce((select (valor ->> 'ligado')::boolean from public.config_regras where chave = 'ferramentas_vigia'), true);
$cron$)$x$;
end $agenda$;

-- 6. conferência: item 40 ----------------------------------------------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('''ferramentas''' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0415: conferencia_itens mudou — refazer o item das Ferramentas a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 40. 0415 — Ferramentas: alguma fora do ar, vigia sem ler há 3 h ou vencimento nos próximos dias?
  select count(*)::int into n from public.ferramentas f
   where f.ativo and f.checagem not in (''nenhuma'', ''n8n_vigia'', ''meta_saldo'')
     and (select l.nivel from public.ferramentas_leituras l where l.ferramenta_id = f.id order by l.lido_em desc limit 1) = ''parado'';
  select count(*)::int into n2 from public.ferramentas f
   where f.ativo and f.cobranca not in (''gratis'', ''incluso'')
     and public._ferramenta_vence(f.proximo_vencimento, f.dia_cobranca, f.cobranca, (now() at time zone ''America/Sao_Paulo'')::date)
         <= (now() at time zone ''America/Sao_Paulo'')::date + coalesce((select (valor ->> ''aviso_dias'')::int from public.config_regras where chave = ''ferramentas_vigia''), 5);
  it := it || jsonb_build_object(''codigo'', ''ferramentas'', ''nome'', ''Ferramentas pagas (no ar e vencimento)'',
    ''nivel'', case when n > 0 or not exists (select 1 from public.ferramentas_leituras where lido_em > now() - interval ''3 hours'') then ''falha''
                    when n2 > 0 then ''atencao'' else ''ok'' end,
    ''n'', n + n2,
    ''texto'', coalesce(nullif(concat_ws('' · '',
      case when not exists (select 1 from public.ferramentas_leituras where lido_em > now() - interval ''3 hours'') then ''o vigia das ferramentas não lê há 3 h'' end,
      case when n > 0 then format(''%s ferramenta(s) fora do ar'', n) end,
      case when n2 > 0 then format(''%s vencimento(s) nos próximos dias'', n2) end), ''''), ''todas no ar, nada vencendo''),
    ''fazer'', case when n > 0 or n2 > 0 then ''Abrir Financeiro › Ferramentas: ver qual é e pagar ou religar antes de cair.'' end);

  return it;
end');
  execute d;
end $$;

commit;
