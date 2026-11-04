-- NIOGEN | supabase/migrations/0018_mari_cadencia.sql | 04/11/2026 — Claude Code (prompt nº 11)
-- Cadência da Mari: F1/F2 dentro da janela de 24 h + D3/D7/D15 por template + avulsos (1º contato,
-- confirmação de visita, retorno pedido pelo cliente). A DECISÃO fica no banco; o n8n (mari_cadencia) só executa.
-- Fonte: docs/PROMPT_CODE_11_mari_cadencia_041126_1410.md e docs/MARI_roteiro_atendimento_031126_1430.md
-- § Cadência (rev. 04/11 14h05) — Drive. O prompt pedia "0017"; a 0017 já é config_planos_nome_curto.
-- Idempotente. Escrita só pelo service role (n8n); leitura admin/backoffice.
--
-- Decisões de implementação (registradas no Diário):
--  * contatos_cliente passa a aceitar toque sem venda (lead da Mari): venda_id opcional, + telefone, conversa_id,
--    toque, tipo. O teto 2/dia · 15/mês é contado POR TELEFONE (v_contatos_limite também soma os toques do telefone).
--  * Lead que nunca escreveu (1º contato por template): P1 → D7 → D15 (o D3 diz "começamos a conversar" — não serve).
--  * Retorno pedido pelo cliente ([AGENDAMENTO_RETORNO]): sai mesmo fora do horário ("pedido do cliente"), mas
--    respeita o teto do contrato; enquanto o retorno está no futuro, a escada fica parada.
--  * Confirmação de visita: véspera (dia permitido anterior) da biometria agendada na venda; respeita humano atribuído.

-- ============================================================================
-- 1. Feriados (contato nunca em domingo/feriado)
-- ============================================================================
create table if not exists public.config_feriados (
  data    date not null,
  nome    text not null,
  escopo  text not null check (escopo in ('nacional', 'municipal')),
  cidade  text not null default '',          -- '' = nacional; municipal: nome da cidade como em mari_conversas.cidade
  uf      text not null default '',
  primary key (data, escopo, cidade)
);

insert into public.config_feriados (data, nome, escopo, cidade, uf) values
  ('2026-11-02', 'Finados', 'nacional', '', ''),
  ('2026-11-15', 'Proclamação da República', 'nacional', '', ''),
  ('2026-11-20', 'Dia Nacional de Zumbi e da Consciência Negra', 'nacional', '', ''),
  ('2026-12-25', 'Natal', 'nacional', '', ''),
  ('2027-01-01', 'Confraternização Universal', 'nacional', '', ''),
  -- Juiz de Fora: nenhum feriado municipal entre nov/2026 e jan/2027 (os municipais são Corpus Christi e
  -- Santo Antônio, 13/06). Os de 2027 já entram para a régua não esquecer. Conferir a portaria anual da Prefeitura.
  ('2027-05-27', 'Corpus Christi (municipal)', 'municipal', 'Juiz de Fora', 'MG'),
  ('2027-06-13', 'Santo Antônio, padroeiro (municipal)', 'municipal', 'Juiz de Fora', 'MG')
on conflict do nothing;

-- ============================================================================
-- 2. Templates WABA aprovados (corpo exato — para renderizar a bolha no Chatwoot)
-- ============================================================================
create table if not exists public.config_templates_waba (
  nome       text primary key,
  categoria  text not null check (categoria in ('MARKETING', 'UTILITY')),
  idioma     text not null default 'pt_BR',
  corpo      text not null,
  botoes     jsonb not null default '[]'::jsonb,
  rodape     text,
  meta_id    text,
  status     text not null default 'PENDING' check (status in ('PENDING', 'APPROVED', 'REJECTED', 'PAUSED', 'DISABLED')),
  uso        text,                                -- passo da cadência que usa
  atualizado_em timestamptz not null default now()
);

insert into public.config_templates_waba (nome, categoria, corpo, botoes, rodape, meta_id, status, uso) values
  ('nio_primeiro_contato', 'MARKETING',
   E'Olá, {{1}}! Aqui é a Mari, da Nio 👋\n\nRecebemos seu interesse na internet fibra da Nio. Os planos vão de 600 Mega a 1 Giga, com valor fixo até janeiro de 2030, e a partir do Essencial já vêm com internet 5G.\n\nPosso verificar a disponibilidade no seu endereço?',
   '["Sim, pode consultar", "Agora não"]', 'Responda SAIR para não receber mensagens.', '4153206124988657', 'APPROVED', 'P1'),
  ('nio_retomada_lead_d3', 'MARKETING',
   E'Oi, {{1}}! Aqui é a Mari, da Nio 👋\n\nVi que a gente começou a conversar sobre {{2}} e parou no meio. Quer retomar? Te mostro as opções rapidinho 😊',
   '["Quero retomar!", "Não tenho interesse"]', 'Responda SAIR para não receber mensagens.', '1437390127842255', 'APPROVED', 'D3 · RETORNO fora da janela'),
  ('nio_retomada_lead_d7', 'MARKETING',
   E'Oi, {{1}}! É a Mari, da Nio 😊\n\nPassando pra lembrar: a internet fibra da Nio tem valor fixo até janeiro de 2030, e a partir do Essencial já vem com internet 5G.\n\nQuer que eu veja a disponibilidade na sua rua? Leva um minutinho.',
   '["Quero retomar!", "Me chama mais tarde", "Não tenho interesse"]', 'Responda SAIR para não receber mensagens.', '1857110861956250', 'APPROVED', 'D7'),
  ('nio_retomada_lead_d15', 'MARKETING',
   E'Oi, {{1}}! É a Mari, da Nio.\n\nComo não conseguimos conversar, vou encerrar seu atendimento por aqui pra não te incomodar. Se mais pra frente quiser internet fibra, é só responder esta mensagem que a gente retoma de onde parou 😊',
   '["Quero retomar!"]', null, '1137641239177349', 'APPROVED', 'D15'),
  ('nio_confirmacao_visita', 'UTILITY',
   E'Oi, {{1}}! Aqui é a Mari, da Nio 👋 Confirmando a visita do nosso consultor para a biometria do seu pedido:\n\nDia: {{2}}\nHorário: {{3}}\nEndereço: {{4}}\n\nO titular precisa estar presente com um documento com foto. Podemos confirmar?',
   '["Confirmo", "Preciso remarcar"]', null, '1630731498012089', 'APPROVED', 'VISITA')
on conflict (nome) do nothing;

-- ============================================================================
-- 3. Colunas novas (aditivas)
-- ============================================================================
alter table public.mari_conversas add column if not exists ultima_msg_mari_at timestamptz;
alter table public.mari_conversas add column if not exists cadencia_passo text not null default 'nenhum';
alter table public.mari_conversas add column if not exists cadencia_passo_em timestamptz;
alter table public.mari_conversas add column if not exists cadencia_proximo_em timestamptz;
alter table public.mari_conversas add column if not exists cadencia_retorno_em timestamptz;   -- quando o retorno pedido saiu
alter table public.mari_conversas add column if not exists visita_confirmada_para timestamptz; -- biometria_em já confirmada
alter table public.mari_conversas add column if not exists humano_atribuido boolean not null default false;
alter table public.mari_conversas add column if not exists time_atribuido boolean not null default false;
alter table public.mari_conversas add column if not exists chatwoot_resolvida boolean not null default false;

alter table public.mari_conversas drop constraint if exists mari_conversas_cadencia_passo_check;
alter table public.mari_conversas add constraint mari_conversas_cadencia_passo_check
  check (cadencia_passo in ('nenhum', 'P1', 'F1', 'F2', 'D3', 'D7', 'D15', 'encerrada'));

-- última fala da Mari nas conversas que já existem
update public.mari_conversas c set ultima_msg_mari_at = t.ultima
  from (select conversa_id, max(created_at) as ultima from public.mari_turnos where papel = 'mari' group by 1) t
 where t.conversa_id = c.id and c.ultima_msg_mari_at is null;

-- contatos_cliente: toque da Mari sem venda (lead) + telefone
alter table public.contatos_cliente alter column venda_id drop not null;
alter table public.contatos_cliente add column if not exists telefone text;
alter table public.contatos_cliente add column if not exists conversa_id uuid references public.mari_conversas (id) on delete cascade;
alter table public.contatos_cliente add column if not exists toque text;          -- P1, F1, F2, D3, D7, D15, VISITA, RETORNO…
alter table public.contatos_cliente add column if not exists tipo text;
alter table public.contatos_cliente drop constraint if exists contatos_cliente_tipo_check;
alter table public.contatos_cliente add constraint contatos_cliente_tipo_check check (tipo is null or tipo in ('ativo', 'receptivo'));
alter table public.contatos_cliente drop constraint if exists contatos_cliente_alvo_check;
alter table public.contatos_cliente add constraint contatos_cliente_alvo_check check (venda_id is not null or telefone is not null);
create index if not exists contatos_cliente_telefone_idx on public.contatos_cliente (telefone, em);
create index if not exists contatos_cliente_conversa_idx on public.contatos_cliente (conversa_id);

-- ============================================================================
-- 4. Telefone normalizado (só dígitos, com 55) e preenchimento automático
-- ============================================================================
create or replace function public.tel_norm(p text)
returns text language sql immutable set search_path = public as $$
  select case
    when d = '' then null
    when length(d) in (10, 11) then '55' || d
    else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$$;

create or replace function public.contatos_preenche_telefone()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.telefone is null and new.venda_id is not null then
    select public.tel_norm(cliente_whatsapp) into new.telefone from public.vendas where id = new.venda_id;
  else
    new.telefone := public.tel_norm(new.telefone);
  end if;
  return new;
end;
$$;
drop trigger if exists contatos_preenche_telefone on public.contatos_cliente;
create trigger contatos_preenche_telefone before insert on public.contatos_cliente
  for each row execute function public.contatos_preenche_telefone();

update public.contatos_cliente c set telefone = public.tel_norm(v.cliente_whatsapp)
  from public.vendas v where v.id = c.venda_id and c.telefone is null;

-- O evento da venda só existe quando há venda (toque de lead não tem).
create or replace function public.contatos_registra_evento()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.venda_id is null then return null; end if;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (new.venda_id, 'contato',
          jsonb_strip_nulls(jsonb_build_object('canal', new.canal, 'direcao', new.direcao, 'por', new.por,
                                               'resumo', new.resumo, 'toque', new.toque)),
          auth.uid());
  return null;
end;
$$;

-- Teto do contrato: mesmas colunas, agora somando também os toques pelo telefone da venda.
create or replace view public.v_contatos_limite
with (security_invoker = true) as
select
  v.id as venda_id,
  count(c.id) filter (
    where (c.em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
  )::int as hoje,
  count(c.id) filter (
    where date_trunc('month', c.em at time zone 'America/Sao_Paulo') = date_trunc('month', now() at time zone 'America/Sao_Paulo')
  )::int as mes
from public.vendas v
left join public.contatos_cliente c
  on c.direcao = 'saida'
 and (c.venda_id = v.id or (c.telefone is not null and c.telefone = public.tel_norm(v.cliente_whatsapp)))
group by v.id;

-- Backoffice lê os toques da Mari (lead sem venda); vendedor continua só com os das vendas dele.
drop policy if exists contatos_mari_ler on public.contatos_cliente;
create policy contatos_mari_ler on public.contatos_cliente for select to authenticated
  using (public.meu_perfil() = 'backoffice' and conversa_id is not null);

-- ============================================================================
-- 5. Carimbos pelos turnos: fala da Mari carimba ultima_msg_mari_at; fala do lead zera a escada.
-- ============================================================================
create or replace function public.mari_turnos_carimba()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.papel = 'mari' and coalesce(new.texto, '') <> '' then
    update public.mari_conversas
       set ultima_msg_mari_at = greatest(coalesce(ultima_msg_mari_at, new.created_at), new.created_at)
     where id = new.conversa_id;
  elsif new.papel = 'lead' then
    update public.mari_conversas
       set cadencia_passo = 'nenhum', cadencia_passo_em = null, cadencia_proximo_em = null
     where id = new.conversa_id and cadencia_passo not in ('nenhum', 'encerrada');
  end if;
  return null;
end;
$$;
drop trigger if exists mari_turnos_carimba on public.mari_turnos;
create trigger mari_turnos_carimba after insert on public.mari_turnos
  for each row execute function public.mari_turnos_carimba();

-- ============================================================================
-- 6. Horário do contrato: seg–sex 9–21 · sáb 10–16 · nunca domingo/feriado (America/Sao_Paulo)
-- ============================================================================
create or replace function public.mari_dia_permitido(p_dia date, p_cidade text default null)
returns boolean language sql stable set search_path = public as $$
  select extract(isodow from p_dia) <> 7
     and not exists (select 1 from public.config_feriados f
                      where f.data = p_dia
                        and (f.escopo = 'nacional'
                             or (f.escopo = 'municipal' and lower(f.cidade) = lower(btrim(coalesce(p_cidade, ''))))))
$$;

-- abre/fecha do dia (hora local); null se o dia não é permitido
create or replace function public.mari_janela_dia(p_dia date, p_cidade text default null, out abre timestamp, out fecha timestamp)
language sql stable set search_path = public as $$
  select case when public.mari_dia_permitido(p_dia, p_cidade) then
           p_dia + case when extract(isodow from p_dia) = 6 then time '10:00' else time '09:00' end end,
         case when public.mari_dia_permitido(p_dia, p_cidade) then
           p_dia + case when extract(isodow from p_dia) = 6 then time '16:00' else time '21:00' end end
$$;

create or replace function public.mari_no_horario(p_ts timestamptz, p_cidade text default null)
returns boolean language sql stable set search_path = public as $$
  select coalesce(l >= j.abre and l < j.fecha, false)
    from (select p_ts at time zone 'America/Sao_Paulo' as l) x,
         lateral public.mari_janela_dia((x.l)::date, p_cidade) j
$$;

-- primeiro instante permitido >= p_ts
create or replace function public.mari_proximo_horario(p_ts timestamptz, p_cidade text default null)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  l timestamp := p_ts at time zone 'America/Sao_Paulo';
  j record; i int;
begin
  for i in 0..20 loop
    select * into j from public.mari_janela_dia(l::date + i, p_cidade);
    if j.abre is not null then
      if i = 0 then
        if l < j.fecha then return greatest(l, j.abre) at time zone 'America/Sao_Paulo'; end if;
      else
        return j.abre at time zone 'America/Sao_Paulo';
      end if;
    end if;
  end loop;
  return null;
end;
$$;

-- "fim do horário anterior": último instante permitido <= p_ts, com folga antes do fechamento
-- (a rodada é a cada 10 min — folga de 15 min garante que uma rodada pega).
create or replace function public.mari_ultimo_horario(p_ts timestamptz, p_cidade text default null, p_folga interval default '15 minutes')
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  l timestamp := p_ts at time zone 'America/Sao_Paulo';
  j record; i int; f timestamp;
begin
  for i in 0..20 loop
    select * into j from public.mari_janela_dia(l::date - i, p_cidade);
    if j.abre is not null then
      f := j.fecha - p_folga;
      if i = 0 then
        if l >= j.abre then return least(l, f) at time zone 'America/Sao_Paulo'; end if;
      else
        return f at time zone 'America/Sao_Paulo';
      end if;
    end if;
  end loop;
  return null;
end;
$$;

-- toques de saída do telefone no dia e no mês de p_agora (teto 2/dia · 15/mês)
create or replace function public.mari_toques(p_tel text, p_agora timestamptz default now(), out hoje int, out mes int)
language sql stable set search_path = public as $$
  select
    count(*) filter (where (c.em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)::int,
    count(*) filter (where date_trunc('month', c.em at time zone 'America/Sao_Paulo') = date_trunc('month', p_agora at time zone 'America/Sao_Paulo'))::int
  from public.contatos_cliente c
  where c.direcao = 'saida' and c.telefone = public.tel_norm(p_tel)
$$;

-- ============================================================================
-- 7. Textos (F1/F2 do roteiro, exatos) e variáveis dos templates
-- ============================================================================
create or replace function public.mari_cadencia_campo_falta(c public.mari_conversas)
returns text language sql stable set search_path = public as $$
  select case
    when coalesce(btrim(c.dados ->> 'nome'), '') = '' then 'seu nome completo'
    when coalesce(btrim(c.dados ->> 'cpf'), '') = '' then 'seu CPF'
    when coalesce(btrim(c.dados ->> 'email'), '') = '' then 'seu e-mail'
    when c.forma_pagamento is null then 'a forma de pagamento'
    when coalesce(btrim(c.visita_preferencia), '') = '' then 'o melhor período para a visita'
    else 'a confirmação dos seus dados' end
$$;

create or replace function public.mari_cadencia_texto(c public.mari_conversas, p_passo text)
returns text language sql stable set search_path = public as $$
  select case
    when c.etapa in ('abertura', 'endereco') then case p_passo
      when 'F1' then 'Conseguiu ver o CEP e o número da casa? Com eles eu já te mostro as opções 😊'
      else 'Passando aqui de novo: se me mandar o CEP e o número, te mostro os planos da sua região rapidinho 😊' end
    when c.etapa = 'elegibilidade' then case p_passo
      when 'F1' then 'Só falta essa: alguém no endereço já tem Nio (ou tinha Oi Fibra)? 😊'
      else 'Ainda dá tempo! Me confirma se alguém aí já tem Nio que eu sigo com as opções 😊' end
    when c.etapa = 'planos' then case p_passo
      when 'F1' then 'Ficou alguma dúvida sobre os planos? Se quiser, te ajudo a escolher 😊'
      else 'Separei aqui as opções da sua região. Qual delas te chamou mais atenção? 😊' end
    when c.etapa = 'coleta' then case p_passo
      when 'F1' then 'Estamos quase lá! Falta só ' || public.mari_cadencia_campo_falta(c) || ' pra eu adiantar seu pedido 😊'
      else 'Seu pedido está quase pronto — me passa ' || public.mari_cadencia_campo_falta(c) || ' quando puder? 😊' end
    else case p_passo   -- resumo (e qualquer etapa nova)
      when 'F1' then 'Conseguiu conferir os dados? Se estiver tudo certo, é só me confirmar 😊'
      else 'Seus dados estão prontos pra seguir — me confirma que está tudo certo? 😊' end
  end
$$;

-- {{1}}: primeiro nome só se confiável; senão "tudo bem" (todos os corpos leem bem assim)
create or replace function public.mari_cadencia_nome(c public.mari_conversas)
returns text language sql stable set search_path = public as $$
  select coalesce(
    nullif(initcap(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1)), ''),
    case when c.nome_confiavel then nullif(initcap(split_part(btrim(coalesce(c.nome_contato, '')), ' ', 1)), '') end,
    'tudo bem')
$$;

-- {{2}} do D3: "<plano> em <cidade>" ou "internet fibra em <cidade>"
create or replace function public.mari_cadencia_contexto(c public.mari_conversas)
returns text language sql stable set search_path = public as $$
  select case
    when p.codigo is not null and c.cidade is not null
      then 'o Nio ' || case when p.portfolio = 'empresas' then 'Empresas ' else '' end || p.familia || ' em ' || c.cidade
    when c.cidade is not null then 'internet fibra em ' || c.cidade
    else 'internet fibra' end
  from (select 1) x left join public.config_planos p on p.codigo = c.plano_escolhido
$$;

create or replace function public.mari_render_template(p_nome text, p_params jsonb)
returns text language plpgsql stable set search_path = public as $$
declare
  s text; i int;
begin
  select corpo into s from public.config_templates_waba where nome = p_nome;
  if s is null then return null; end if;
  for i in 1..coalesce(jsonb_array_length(p_params), 0) loop
    s := replace(s, '{{' || i || '}}', p_params ->> (i - 1));
  end loop;
  return s;
end;
$$;

-- palavras proibidas (mesma lista do filtro de saída do mari_principal; o nome da revendedora montado por partes)
create or replace function public.mari_texto_proibido(p text)
returns text language plpgsql immutable set search_path = public as $$
declare
  n text := lower(translate(coalesce(p, ''), 'ÁÀÂÃÉÊÍÓÔÕÚÇáàâãéêíóôõúç', 'AAAAEEIOOOUCaaaaeeiooouc'));
  k text;
begin
  foreach k in array array['dh' || 'arma', 'gratis', 'gratuit', 'combo', 'pacote', 'bundle', 'nio 5g', 'nio movel',
                           'nio cel', 'nio mobile', 'chip da nio', '2028', 'cobertura confirmada', 'sem fidelidade'] loop
    if position(k in n) > 0 then return k; end if;
  end loop;
  if position('*' in coalesce(p, '')) > 0 then return '*'; end if;
  if coalesce(p, '') ~ '\{\{|\[' then return 'placeholder'; end if;
  return null;
end;
$$;

-- ============================================================================
-- 8. O cérebro: avalia cada conversa em p_agora e devolve o próximo passo, se pode sair agora e por quê não.
-- ============================================================================
drop function if exists public.mari_cadencia_avaliar(timestamptz, uuid);
create or replace function public.mari_cadencia_avaliar(p_agora timestamptz default now(), p_conversa uuid default null)
returns table (
  conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text,
  passo_atual text, passo_em timestamptz, proximo_passo text, proximo_em timestamptz,
  pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text,
  excecao text, janela_aberta boolean, janela_fecha_em timestamptz, toques_hoje int, toques_mes int,
  ligar_sugerido boolean, venda_id uuid)
language plpgsql stable set search_path = public as $$
declare
  c        public.mari_conversas;
  v_tq     record;
  L        timestamptz;   -- última msg do lead
  M        timestamptz;   -- última msg da Mari
  B        timestamptz;   -- base dos D (lead, retorno ou 1º contato)
  f1_at    timestamptz; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
  for c in
    select * from public.mari_conversas mc
     where (p_conversa is null or mc.id = p_conversa)
       and mc.canal in ('teste', 'whatsapp')
       and (mc.status = 'ativo'
            or (mc.status = 'handoff_realizado' and mc.venda_id is not null))   -- só para a confirmação de visita
     order by mc.updated_at desc
  loop
    v_passo := null; v_at := null; v_bloq := null; v_acao := null; v_tpl := null; v_cat := null;
    v_params := null; v_txt := null; v_exc := null; v_pode := false; v_lig := false;
    L := c.ultima_msg_lead_at; M := c.ultima_msg_mari_at;
    v_janela := L is not null and p_agora < L + interval '23 hours';
    select * into v_tq from public.mari_toques(c.telefone, p_agora);

    -- ── paradas absolutas ──
    if c.nao_contatar then v_bloq := 'cliente pediu para não ser contatado';
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
    elsif c.canal = 'whatsapp' and c.telefone like '5500000000%' then v_bloq := 'telefone de teste';
    end if;

    -- ── confirmação de visita (conversa em handoff com venda e biometria agendada) ──
    if c.status = 'handoff_realizado' then
      if v_bloq is not null then continue; end if;   -- em handoff só interessa a visita
      select v.id, v.biometria_em, v.logradouro, v.numero, v.complemento into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.biometria_status = 'agendada' and v.biometria_em > p_agora
         and v.status <> 'saida';
      if not found or c.visita_confirmada_para is not distinct from v_venda.biometria_em then
        continue;   -- nada a fazer nesta conversa
      end if;
      vis_dia := (v_venda.biometria_em at time zone 'America/Sao_Paulo')::date - 1;
      while not public.mari_dia_permitido(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
      vis_ini := public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade);
      v_passo := 'VISITA'; v_at := vis_ini;
      v_params := jsonb_build_array(
        public.mari_cadencia_nome(c),
        semana[extract(isodow from (v_venda.biometria_em at time zone 'America/Sao_Paulo'))::int] || ', ' ||
          to_char(v_venda.biometria_em at time zone 'America/Sao_Paulo', 'DD/MM'),
        replace(to_char(v_venda.biometria_em at time zone 'America/Sao_Paulo', 'FMHH24"h"MI'), 'h00', 'h') || ' às ' ||
          replace(to_char((v_venda.biometria_em + interval '1 hour') at time zone 'America/Sao_Paulo', 'FMHH24"h"MI'), 'h00', 'h'),
        concat_ws(', ', nullif(btrim(v_venda.logradouro), ''), nullif(btrim(v_venda.numero), ''), nullif(btrim(v_venda.complemento), '')));
      v_txt := public.mari_render_template('nio_confirmacao_visita', v_params);
      if v_janela then v_acao := 'texto'; else v_acao := 'template'; v_tpl := 'nio_confirmacao_visita'; v_cat := 'UTILITY'; end if;
      if p_agora < v_at then v_bloq := 'aguardando a véspera da visita';
      elsif p_agora > v_venda.biometria_em - interval '2 hours' then v_bloq := 'visita próxima demais';
      end if;
    elsif v_bloq is null and c.status = 'ativo' then
      -- ── retorno pedido pelo cliente: prioridade, pode sair fora do horário ──
      if c.agendamento_retorno is not null
         and c.agendamento_retorno > coalesce(L, c.created_at)
         and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno) then
        v_passo := 'RETORNO'; v_at := c.agendamento_retorno; v_exc := 'pedido do cliente';
        if v_janela then
          v_acao := 'texto';
          v_txt := 'Oi' || case when public.mari_cadencia_nome(c) <> 'tudo bem' then ', ' || public.mari_cadencia_nome(c) else '' end
                   || '! Como combinamos, estou passando pra gente retomar. Quer seguir de onde paramos? 😊';
        else
          v_acao := 'template'; v_tpl := 'nio_retomada_lead_d3'; v_cat := 'MARKETING';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if p_agora < v_at then v_bloq := 'retorno agendado pelo cliente'; end if;
      elsif c.processando_ate is not null and c.processando_ate > p_agora then
        v_bloq := 'Mari respondendo agora';
      elsif L is null and c.origem not in ('meta_ads', 'site', 'indicacao') then
        continue;   -- sem mensagem do lead e sem origem de formulário: não há escada
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum' then
        v_bloq := 'aguardando a Mari responder';
      else
        -- ── a escada ──
        B := greatest(coalesce(L, '-infinity'::timestamptz), coalesce(c.cadencia_retorno_em, '-infinity'::timestamptz));
        if L is null then
          -- lead de formulário/site/indicação que nunca escreveu: P1 → D7 → D15
          B := coalesce((select min(cc.em) from public.contatos_cliente cc where cc.conversa_id = c.id and cc.toque = 'P1'),
                        c.cadencia_passo_em, c.created_at);
          seq := array['P1', 'D7', 'D15', 'ENCERRAR'];
          ats := array[c.created_at, B + interval '7 days', B + interval '15 days', null];
          validos := array[B + interval '7 days', B + interval '15 days', 'infinity'::timestamptz, 'infinity'::timestamptz];
        else
          f1_at := M + interval '60 minutes';
          if c.cadencia_retorno_em is not null or not public.mari_no_horario(f1_at, c.cidade) or f1_at >= L + interval '20 hours' then
            f1_at := null;   -- F1 que cairia fora do horário não sai (vai para o F2)
          end if;
          f2_at := public.mari_proximo_horario(L + interval '20 hours', c.cidade);
          f2_ate := L + interval '23 hours';
          if c.cadencia_retorno_em is not null then
            f2_at := null;
          elsif f2_at is null or f2_at >= f2_ate then
            -- fora do horário: antecipa para o fim do horário anterior, se ainda fizer sentido; senão pula para o D3
            a_ant := public.mari_ultimo_horario(L + interval '20 hours', c.cidade);
            if a_ant is not null and a_ant >= greatest(M, coalesce(c.cadencia_passo_em, M), coalesce(f1_at, M)) + interval '30 minutes' then
              f2_at := a_ant; f2_ate := least(L + interval '23 hours', a_ant + interval '15 minutes');
            else
              f2_at := null;
            end if;
          end if;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          seq := array['F1', 'F2', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[f1_at, f2_at, d3_at, d7_at, d15_at, null];
          validos := array[least(L + interval '20 hours', coalesce(f2_at, 'infinity')), f2_ate, d7_at, d15_at,
                           'infinity'::timestamptz, 'infinity'::timestamptz];
        end if;
        -- encerramento: 48 h depois do D15
        if c.cadencia_passo = 'D15' then
          ats[array_length(seq, 1)] := c.cadencia_passo_em + interval '48 hours';
        end if;

        idx_atual := coalesce(array_position(seq, c.cadencia_passo), 0);
        if c.cadencia_passo = 'F2' and seq[1] = 'P1' then idx_atual := 1; end if;   -- retorno de lead sem conversa
        alvo := null; prox := null;
        for i in (idx_atual + 1)..array_length(seq, 1) loop
          if ats[i] is null then continue; end if;
          -- F1/F2 que venceu fora do horário não sai (F1 → F2; F2 → D3)
          if seq[i] in ('F1', 'F2') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
          if ats[i] <= p_agora and p_agora < validos[i] then alvo := i;            -- o mais adiantado vencido e válido
          elsif ats[i] > p_agora and prox is null then prox := i;
          end if;
        end loop;

        if alvo is not null then
          v_passo := seq[alvo]; v_at := ats[alvo];
        elsif prox is not null then
          v_passo := seq[prox]; v_at := ats[prox]; v_bloq := 'aguardando';
        else
          continue;
        end if;

        if v_passo in ('F1', 'F2') then
          v_acao := 'texto'; v_txt := public.mari_cadencia_texto(c, v_passo);
        elsif v_passo = 'ENCERRAR' then
          v_acao := 'encerrar'; v_txt := null;
        else
          v_acao := 'template';
          v_tpl := case v_passo when 'P1' then 'nio_primeiro_contato' when 'D3' then 'nio_retomada_lead_d3'
                                when 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end;
          v_cat := 'MARKETING';
          v_params := case when v_tpl = 'nio_retomada_lead_d3'
                           then jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c))
                           else jsonb_build_array(public.mari_cadencia_nome(c)) end;
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if v_passo in ('F1', 'F2') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        -- ligação do consultor D4–D5: só aviso, nunca automática
        v_lig := c.cadencia_passo = 'D3' and p_agora >= c.cadencia_passo_em + interval '1 day' and p_agora < B + interval '6 days';
      end if;
    end if;

    if v_passo is null then
      if v_bloq is null then continue; end if;
      -- parada absoluta: mostra a conversa com o motivo, sem passo
    end if;

    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao <> 'encerrar' then
      if v_exc is null and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_tq.hoje >= 2 then
        v_bloq := 'limite do dia (2 toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_tq.mes >= 15 then
        v_bloq := 'limite do mês (15 toques)';
      elsif v_acao = 'template' and not exists (select 1 from public.config_templates_waba t where t.nome = v_tpl and t.status = 'APPROVED') then
        v_bloq := 'template não aprovado';
      else
        v_proib := public.mari_texto_proibido(v_txt);
        if v_proib is not null then v_bloq := 'texto reprovado no filtro (' || v_proib || ')'; end if;
      end if;
    end if;
    v_pode := v_passo is not null and v_bloq is null;

    conversa_id := c.id; telefone := c.telefone; canal := c.canal; chatwoot_conversation_id := c.chatwoot_conversation_id;
    status := c.status; etapa := c.etapa; passo_atual := c.cadencia_passo; passo_em := c.cadencia_passo_em;
    proximo_passo := v_passo; proximo_em := v_at; pode_enviar := v_pode; bloqueio := v_bloq; acao := v_acao;
    template := v_tpl; categoria := v_cat; params := v_params; texto := v_txt; excecao := v_exc;
    janela_aberta := v_janela; janela_fecha_em := case when L is not null then L + interval '24 hours' end;
    toques_hoje := v_tq.hoje; toques_mes := v_tq.mes; ligar_sugerido := v_lig; venda_id := c.venda_id;
    return next;
  end loop;
end;
$$;

-- Candidatos da rodada (o n8n executa). p_canal: 'teste' (simulação) ou 'whatsapp' (envio real pelo Chatwoot).
drop function if exists public.mari_cadencia_candidatos(timestamptz, text, int);
create or replace function public.mari_cadencia_candidatos(p_agora timestamptz default now(), p_canal text default 'teste', p_limite int default 30)
returns setof jsonb language sql stable set search_path = public as $$
  select to_jsonb(a) from public.mari_cadencia_avaliar(p_agora, null) a
   where a.pode_enviar and a.canal = p_canal
   order by case a.proximo_passo when 'RETORNO' then 0 when 'VISITA' then 1 when 'F1' then 2 when 'F2' then 3 else 4 end,
            a.proximo_em
   limit least(greatest(coalesce(p_limite, 30), 1), 30)
$$;

-- Registro do envio (ou da falha). Falha não queima o passo: só vira linha em mari_erros.
drop function if exists public.mari_cadencia_registrar(uuid, text, boolean, text, timestamptz, text, text);
create or replace function public.mari_cadencia_registrar(
  p_conversa uuid, p_passo text, p_ok boolean, p_erro text default null,
  p_agora timestamptz default now(), p_texto text default null, p_excecao text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  c public.mari_conversas;
  v_bio timestamptz;
  v_prox record;
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'conversa inexistente'); end if;

  if not coalesce(p_ok, false) then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_cadencia', 'envio da cadência falhou (' || coalesce(p_passo, '?') || '): ' || coalesce(p_erro, 'sem detalhe'),
            jsonb_build_object('passo', p_passo, 'agora', p_agora));
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  if p_passo = 'ENCERRAR' then
    update public.mari_conversas set status = 'encerrado_ia', handoff_motivo = 'sem_contato',
           cadencia_passo = 'encerrada', cadencia_passo_em = p_agora, cadencia_proximo_em = null
     where id = p_conversa;
    insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
    values (p_conversa, 'sistema', 'Saída "Sem contato": 48 h sem resposta depois do D15.',
            jsonb_build_object('cadencia', 'ENCERRAR'), p_agora);
    return jsonb_build_object('ok', true, 'registrado', 'encerrada');
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
  values (p_conversa, 'mari', coalesce(p_texto, ''),
          jsonb_strip_nulls(jsonb_build_object('cadencia', p_passo, 'excecao', p_excecao, 'simulado', c.canal = 'teste')), p_agora);

  insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
  values (c.venda_id, c.id, c.telefone, 'whatsapp', 'saida', 'mari', p_agora, p_passo, 'ativo',
          'cadência ' || p_passo || coalesce(' · ' || p_excecao, '') || case when c.canal = 'teste' then ' (simulado)' else '' end);

  if p_passo = 'RETORNO' then
    update public.mari_conversas set cadencia_retorno_em = p_agora,
           cadencia_passo = case when cadencia_passo in ('nenhum', 'F1', 'P1') then 'F2' else cadencia_passo end,
           cadencia_passo_em = p_agora
     where id = p_conversa;
  elsif p_passo = 'VISITA' then
    select biometria_em into v_bio from public.vendas where id = c.venda_id;
    update public.mari_conversas set visita_confirmada_para = v_bio where id = p_conversa;
  else
    update public.mari_conversas set cadencia_passo = p_passo, cadencia_passo_em = p_agora where id = p_conversa;
  end if;

  select a.proximo_passo, a.proximo_em into v_prox
    from public.mari_cadencia_avaliar(p_agora + interval '1 second', p_conversa) a limit 1;
  update public.mari_conversas set cadencia_proximo_em = v_prox.proximo_em where id = p_conversa;

  return jsonb_build_object('ok', true, 'registrado', p_passo, 'proximo_passo', v_prox.proximo_passo, 'proximo_em', v_prox.proximo_em);
end;
$$;

-- Guard do Chatwoot (modo chatwoot): humano/time atribuído ou conversa resolvida param a escada.
create or replace function public.mari_cadencia_parar(p_conversa uuid, p_humano boolean default false,
  p_time boolean default false, p_resolvida boolean default false)
returns jsonb language sql set search_path = public as $$
  update public.mari_conversas set
    humano_atribuido = humano_atribuido or coalesce(p_humano, false),
    time_atribuido = time_atribuido or coalesce(p_time, false),
    chatwoot_resolvida = chatwoot_resolvida or coalesce(p_resolvida, false)
  where id = p_conversa
  returning jsonb_build_object('ok', true, 'humano', humano_atribuido, 'time', time_atribuido, 'resolvida', chatwoot_resolvida)
$$;

-- ============================================================================
-- 9. View da tela Mari
-- ============================================================================
drop view if exists public.v_mari_cadencia;
create view public.v_mari_cadencia
with (security_invoker = true) as
select a.conversa_id, a.telefone, a.canal, a.status, a.etapa, a.passo_atual, a.passo_em,
       a.proximo_passo, a.proximo_em, a.pode_enviar, a.bloqueio, a.acao, a.template, a.excecao,
       a.janela_aberta, a.janela_fecha_em, a.toques_hoje, a.toques_mes, a.ligar_sugerido, a.venda_id
  from public.mari_cadencia_avaliar(now(), null) a;

-- ============================================================================
-- 10. RLS e permissões
-- ============================================================================
alter table public.config_feriados enable row level security;
alter table public.config_templates_waba enable row level security;
drop policy if exists feriados_ler on public.config_feriados;
create policy feriados_ler on public.config_feriados for select to authenticated using (true);
drop policy if exists feriados_admin on public.config_feriados;
create policy feriados_admin on public.config_feriados for all to authenticated
  using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
drop policy if exists templates_ler on public.config_templates_waba;
create policy templates_ler on public.config_templates_waba for select to authenticated
  using (public.meu_perfil() in ('admin', 'backoffice'));
revoke all on public.config_feriados, public.config_templates_waba from anon;
grant select on public.config_feriados, public.config_templates_waba to authenticated;
grant insert, update, delete on public.config_feriados to authenticated;   -- a policy limita ao admin

revoke all on public.v_mari_cadencia from anon;
grant select on public.v_mari_cadencia to authenticated;

do $$
declare f text;
begin
  -- leitura (a view da tela chama o avaliar como invoker: RLS de quem consulta)
  foreach f in array array[
    'public.tel_norm(text)',
    'public.mari_dia_permitido(date, text)',
    'public.mari_janela_dia(date, text)',
    'public.mari_no_horario(timestamptz, text)',
    'public.mari_proximo_horario(timestamptz, text)',
    'public.mari_ultimo_horario(timestamptz, text, interval)',
    'public.mari_toques(text, timestamptz)',
    'public.mari_cadencia_campo_falta(public.mari_conversas)',
    'public.mari_cadencia_texto(public.mari_conversas, text)',
    'public.mari_cadencia_nome(public.mari_conversas)',
    'public.mari_cadencia_contexto(public.mari_conversas)',
    'public.mari_render_template(text, jsonb)',
    'public.mari_texto_proibido(text)',
    'public.mari_cadencia_avaliar(timestamptz, uuid)']
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
  -- escrita / execução: só o n8n
  foreach f in array array[
    'public.mari_cadencia_candidatos(timestamptz, text, int)',
    'public.mari_cadencia_registrar(uuid, text, boolean, text, timestamptz, text, text)',
    'public.mari_cadencia_parar(uuid, boolean, boolean, boolean)']
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['public.mari_turnos_carimba()', 'public.contatos_preenche_telefone()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end;
$$;
