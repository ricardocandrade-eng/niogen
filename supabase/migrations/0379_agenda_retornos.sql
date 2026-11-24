-- NIOGEN | supabase/migrations/0379_agenda_retornos.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 24/11: "quando o cliente pede para retornar no dia/hora X, o Niogen precisa alertar isso, seja a conversa estando com a
-- Mari ou com o Time" → decisões: "Mari retoma, alerta só na Live, detector só sugere".
-- O que já existia e quase não era usado: a cadência da Mari tem o passo RETORNO (na hora de mari_conversas.agendamento_retorno,
-- 9h–21h, texto com a janela aberta ou o template nio_retomada_lead_d3), e a ⏸ espera (0101/0348) tira o lead da Live até uma data e
-- adia a conversa no Chatwoot. Faltavam: hora (a espera do time é sempre 9h), registro do combinado, alerta ao time na hora, cobrança
-- de quem não fez, e ler o pedido do cliente quando quem conversa é o time.
-- O que muda:
--  (1) retornos (tabela, parceiro_id) + v_retornos (situação calculada: agendado · agora · feito · perdido; quem chama agora).
--  (2) _retorno_ler_quando(texto, agora): lê "me liga amanhã às 15h", "sexta de tarde", "dia 28 às 10h", "te dou a resposta amanhã".
--  (3) retorno_marcar(conversa, quando, combinado) — casca 0263 + __nucleo, evento retorno_marcar: o time marca dia E hora.
--      Conversa com a Mari → a Mari retoma na hora (agendamento_retorno; a espera vai até 2 h depois: sem resposta, volta ao time).
--      Conversa com o time → espera até 15 min antes (lead) e o 🔔 aparece na Live › Conferir na hora.
--  (4) retorno_fechar(retorno, como, motivo): Feito / Descartar (sugestão ou marcado), evento retorno_fechar.
--  (5) _mari_espera (= versão no ar + hora): data do cliente em até N dias (mari_espera_antecedencia_dias) é retorno com hora — a Mari
--      chama no horário combinado (hoje também, se ainda não passou); data mais longe continua como antes (o time chama N dias antes).
--      Os dois casos registram o retorno.
--  (6) mari_cadencia_avaliar (= versão no ar + 1 condição): a espera não segura o RETORNO que chegou a hora.
--  (7) detector (gatilho em mari_turnos, só fala do cliente com a conversa no time): acha o pedido de retorno e grava uma SUGESTÃO
--      (nada muda no lead) + nota no Chatwoot. O consultor confirma ou descarta na Live › Conferir.
--  (8) live_conferir (= versão no ar + 2 tipos): retorno_agora (🔔 15 min antes; ⏰ atrasado depois de 1 h) e retorno_sugerido.
--  (9) conferencia_itens: item 36 "retornos_perdidos" (passou da hora sem contato, 48 h).
-- Regra 20: (1) vez e prazo: o retorno tem dono (Mari ou time) e hora; (2) ninguém parado: sem contato 1 h depois vira ⏰ atrasado na
-- Live e atenção na conferência; sugestão some sozinha depois de 3 dias ou passada a hora; (3) toda gravação por função do banco com
-- autor (retorno_marcar / retorno_fechar pela casca e porta_sombra; detector e Mari como 'sistema'); (4) fonte única: a tabela
-- retornos; o "feito" vem dos turnos da conversa; (5) conferência: item 36; cenário X103.
-- Contrato: nenhuma mensagem nova ao cliente — a Mari usa o RETORNO que já existia (texto aprovado / template aprovado, 9h–21h).
-- Desempenho: live_conferir ganha 2 consultas pequenas (índice parcial dos abertos); gatilho só em fala do cliente (regex). Medir a
-- Live antes e depois. Medir em 7 dias: retornos marcados (por origem), feitos na hora, perdidos, sugestões confirmadas/descartadas.
begin;

-- ───────────────────────── (1) tabela e view ─────────────────────────
create table if not exists public.retornos (
  id             uuid primary key default gen_random_uuid(),
  parceiro_id    text not null default 'dharma',
  conversa_id    uuid not null references public.mari_conversas (id) on delete cascade,
  venda_id       uuid references public.vendas (id) on delete set null,
  quando         timestamptz not null,
  tem_hora       boolean not null default true,
  quem           text not null check (quem in ('mari', 'time')),
  origem         text not null check (origem in ('mari', 'time', 'detector')),
  combinado      text,
  estado         text not null default 'marcado' check (estado in ('sugerido', 'marcado', 'feito', 'cancelado')),
  criado_em      timestamptz not null default now(),
  criado_por     uuid,
  fechado_em     timestamptz,
  fechado_por    text,
  fechado_motivo text
);
create index if not exists retornos_abertos_idx on public.retornos (quando) where estado in ('sugerido', 'marcado');
create unique index if not exists retornos_um_aberto on public.retornos (conversa_id, estado) where estado in ('sugerido', 'marcado');
create index if not exists retornos_conversa_idx on public.retornos (conversa_id, criado_em desc);
alter table public.retornos enable row level security;
drop policy if exists retornos_ler on public.retornos;
create policy retornos_ler on public.retornos for select to authenticated
  using ((select coalesce(public.meu_perfil(), '')) in ('admin', 'backoffice'));
revoke insert, update, delete on public.retornos from anon, authenticated;

create or replace view public.v_retornos with (security_invoker = true) as
select r.*,
       (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status <> 'ativo') as com_time,
       case when r.quem = 'mari' and not (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status <> 'ativo')
            then 'mari' else 'time' end as quem_agora,
       case when r.estado <> 'marcado' then r.estado
            -- o cliente voltou a falar depois de combinar, ou alguém falou com ele perto da hora → feito
            when exists (select 1 from public.mari_turnos t where t.conversa_id = r.conversa_id and t.created_at > r.criado_em
                           and (t.papel = 'lead'
                                or (t.papel = 'humano' and t.created_at >= r.quando - interval '15 minutes')
                                or (t.papel = 'mari' and r.quem = 'mari' and t.created_at >= r.quando - interval '15 minutes'))) then 'feito'
            when now() > r.quando + interval '1 hour' then 'perdido'
            when now() >= r.quando - interval '15 minutes' then 'agora'
            else 'agendado' end as situacao
  from public.retornos r
  join public.mari_conversas c on c.id = r.conversa_id;

-- ───────────────────────── (2) leitor do pedido ─────────────────────────
create or replace function public._retorno_ler_quando(p_texto text, p_agora timestamptz default now())
returns jsonb language plpgsql stable set search_path = public as $fn$
declare
  t      text := ' ' || lower(translate(coalesce(p_texto, ''), 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
                                                              'aaaaaeeeeiiiiooooouuuucaaaaaeeeeiiiiooooouuuuc')) || ' ';
  hoje   date := (p_agora at time zone 'America/Sao_Paulo')::date;
  dias   text[] := array['domingo', 'segunda', 'terca', 'quarta', 'quinta', 'sexta', 'sabado'];
  v_dia  date; v_hora time; m text[]; alvo int; h int; tem_h boolean := false; v_q timestamptz; i int;
begin
  -- só quando é pedido de contato / de retorno (com dia ou hora); conversa comum não vira sugestão
  if t !~ '(liga|ligue|ligar|chama|chame|chamar|retorn|fala comigo|falar comigo|fale comigo|entr[ae] em contato|manda (uma )?mensagem|mande (uma )?mensagem|me procur|toque|dou (a |uma )?resposta|te respondo|lhe respondo|respondo (amanha|depois|segunda|terca|quarta|quinta|sexta|sabado|domingo)|conversamos|me lembr)' then
    return null;
  end if;
  -- o dia
  if t ~ 'depois de amanha' then v_dia := hoje + 2;
  elsif t ~ '\mamanha\M' then v_dia := hoje + 1;
  elsif t ~ '\mhoje\M' then v_dia := hoje;
  elsif t ~ '(semana que vem|proxima semana)' then v_dia := hoje + (8 - extract(isodow from hoje)::int);
  end if;
  if v_dia is null then
    m := regexp_match(t, '\m(\d{1,2})/(\d{1,2})\M');
    if m is not null then
      begin
        v_dia := make_date(extract(year from hoje)::int, m[2]::int, m[1]::int);
        if v_dia < hoje then v_dia := (v_dia + interval '1 year')::date; end if;
      exception when others then v_dia := null;
      end;
    end if;
  end if;
  if v_dia is null then
    m := regexp_match(t, '\mdia (\d{1,2})\M');
    if m is not null then
      begin
        v_dia := make_date(extract(year from hoje)::int, extract(month from hoje)::int, m[1]::int);
        if v_dia < hoje then v_dia := (v_dia + interval '1 month')::date; end if;
      exception when others then v_dia := null;
      end;
    end if;
  end if;
  if v_dia is null then
    for i in 1..7 loop
      if t ~ ('\m' || dias[i] || '\M') then alvo := i - 1; exit; end if;
    end loop;
    if alvo is not null then v_dia := hoje + ((alvo - extract(dow from hoje)::int + 7) % 7); end if;
  end if;
  -- a hora
  m := regexp_match(t, '\m(\d{1,2})\s*(?:h|hs|hrs|horas?|:)\s*(\d{2})?');
  if m is not null and m[1]::int between 0 and 23 and coalesce(m[2], '0')::int between 0 and 59 then
    h := m[1]::int; v_hora := make_time(h, coalesce(m[2], '0')::int, 0); tem_h := true;
  else
    m := regexp_match(t, '\m(?:as|a partir das|depois das|apos as|por volta das)\s+(\d{1,2})\M');
    if m is not null and m[1]::int between 1 and 23 then h := m[1]::int; v_hora := make_time(h, 0, 0); tem_h := true; end if;
  end if;
  if tem_h and h < 12 and t ~ ('\m' || h || '\s*(?:h|hs|horas?)?\s*(da|de) (tarde|noite)') then v_hora := v_hora + interval '12 hours'; end if;
  if tem_h and h between 1 and 7 and t !~ '(manha|madrugada)' then v_hora := v_hora + interval '12 hours'; end if;   -- "às 3" = 15h
  if not tem_h then
    if t ~ 'meio[ -]?dia' then v_hora := '12:00';
    elsif t ~ '(de|a|pela|na parte da) manha' then v_hora := '09:00';
    elsif t ~ '(de|a|pela|na parte da) tarde' then v_hora := '14:00';
    elsif t ~ '(de|a|pela) noite' then v_hora := '19:00';
    end if;
    tem_h := v_hora is not null;
  end if;
  if v_dia is null and v_hora is null then return null; end if;
  if v_dia is null then
    v_dia := hoje;
    if ((hoje + v_hora)::timestamp at time zone 'America/Sao_Paulo') <= p_agora then v_dia := hoje + 1; end if;
  end if;
  v_q := ((v_dia + coalesce(v_hora, '09:00'::time))::timestamp at time zone 'America/Sao_Paulo');
  if v_q <= p_agora and alvo is not null then v_q := v_q + interval '7 days'; end if;
  if v_q <= p_agora or v_q > p_agora + interval '60 days' then return null; end if;
  return jsonb_build_object('quando', v_q, 'tem_hora', tem_h, 'trecho', left(btrim(p_texto), 160));
end $fn$;

-- ───────────────────────── gravação comum ─────────────────────────
create or replace function public._retorno_gravar(c public.mari_conversas, p_quando timestamptz, p_quem text, p_origem text,
                                                  p_combinado text, p_estado text, p_tem_hora boolean default true, p_por uuid default null)
returns uuid language plpgsql security definer set search_path = public as $fn$
declare v_id uuid;
begin
  update public.retornos
     set estado = 'cancelado', fechado_em = now(), fechado_por = coalesce(p_origem, 'sistema'),
         fechado_motivo = case when p_estado = 'marcado' and estado = 'sugerido' then 'virou retorno marcado' else 'trocado por outro' end
   where conversa_id = c.id and estado in ('sugerido', 'marcado') and (estado = p_estado or p_estado = 'marcado');
  insert into public.retornos (conversa_id, venda_id, quando, tem_hora, quem, origem, combinado, estado, criado_por)
  values (c.id, c.venda_id, p_quando, coalesce(p_tem_hora, true), p_quem, p_origem, nullif(left(btrim(coalesce(p_combinado, '')), 300), ''), p_estado, p_por)
  returning id into v_id;
  return v_id;
end $fn$;
revoke all on function public._retorno_gravar(public.mari_conversas, timestamptz, text, text, text, text, boolean, uuid) from public, anon, authenticated;

-- ───────────────────────── (3) o time marca ─────────────────────────
create or replace function public.retorno_marcar__nucleo(p_conversa uuid, p_quando timestamptz, p_combinado text default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  c      public.mari_conversas;
  g      uuid := gen_random_uuid();
  v_nome text;
  v_quem text;
  v_id   uuid;
  v_ate  timestamptz;
  v_mot  text;
  v_dh   text := to_char(p_quando at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI');
  v_comb text := nullif(left(btrim(coalesce(p_combinado, '')), 300), '');
  com_time boolean;
  tem_cw boolean;
  feito  text[] := '{}';
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  if p_quando is null then raise exception 'Diga o dia e a hora do retorno.'; end if;
  if p_quando < now() + interval '10 minutes' then raise exception 'Escolha um horário daqui a pelo menos 10 minutos.'; end if;
  if p_quando > now() + interval '60 days' then raise exception 'No máximo 60 dias.'; end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if coalesce(c.nao_contatar, false) then raise exception 'Cliente em Não contatar: não se marca retorno.'; end if;
  perform public._porta_conferir('retorno_marcar', c.id, null::uuid);
  select nome into v_nome from public.usuarios where id = auth.uid();
  v_nome := coalesce(v_nome, 'time');
  tem_cw := coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%';
  com_time := c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status <> 'ativo' or c.venda_id is not null;
  v_quem := case when com_time then 'time' else 'mari' end;
  v_id := public._retorno_gravar(c, p_quando, v_quem, 'time', v_comb, 'marcado', true, auth.uid());

  if v_quem = 'mari' then
    -- a Mari chama na hora (passo RETORNO da cadência); a espera segura o resto até 2 h depois — sem resposta, volta para o time
    v_ate := p_quando + interval '2 hours';
    v_mot := left('retorno combinado ' || v_dh || ' — a Mari chama' || coalesce(' · ' || v_comb, ''), 80);
    update public.mari_conversas
       set agendamento_retorno = p_quando, espera_ate = v_ate, espera_motivo = v_mot, espera_em = now(), espera_por = auth.uid()
     where id = c.id;
    feito := feito || ('a Mari chama o cliente ' || v_dh)::text;
  elsif c.venda_id is null then
    v_ate := greatest(p_quando - interval '15 minutes', now() + interval '1 minute');
    v_mot := left('🔔 retorno ' || v_dh || coalesce(' · ' || v_comb, ''), 80);
    update public.mari_conversas
       set espera_ate = v_ate, espera_motivo = v_mot, espera_em = now(), espera_por = auth.uid()
     where id = c.id;
    feito := feito || ('🔔 na Live ' || v_dh || ' (15 min antes)')::text;
  else
    feito := feito || ('🔔 na Live ' || v_dh || ' (15 min antes)')::text;
  end if;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[retorno combinado para ' || v_dh || coalesce(' — ' || v_comb, '') || ' — '
          || case when v_quem = 'mari' then 'a Mari chama' else 'o time chama' end || ' — marcado no NIOGEN por ' || v_nome || ']', false);
  if tem_cw then
    perform public._bo_enfileirar(g, 1, 'retorno', c.venda_id, c, 'nota', jsonb_build_object('content',
      '📅 Retorno combinado para ' || v_dh || coalesce(' — ' || v_comb, '') || ' (' || v_nome || '). '
      || case when v_quem = 'mari' then 'A Mari chama o cliente na hora; se ele não responder em 2 h, volta para o time.'
              else 'Às ' || to_char(p_quando at time zone 'America/Sao_Paulo', 'HH24:MI') || ' (15 min antes) aparece o 🔔 na Live.' end));
    feito := feito || 'nota'::text;
    if c.venda_id is null and v_ate is not null then
      perform public._bo_enfileirar(g, 2, 'retorno', null, c, 'resolver',
        jsonb_build_object('status', 'snoozed', 'snoozed_until', extract(epoch from v_ate)::bigint));
      feito := feito || 'adiada no Chatwoot até a hora'::text;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'retorno', v_id, 'quem', v_quem, 'feito', to_jsonb(feito),
    'resumo', '✓ retorno ' || v_dh || ' — ' || case when v_quem = 'mari' then 'a Mari chama' else '🔔 na Live na hora' end);
end $fn$;
revoke all on function public.retorno_marcar__nucleo(uuid, timestamptz, text) from public, anon, authenticated;

create or replace function public.retorno_marcar(p_conversa uuid, p_quando timestamptz, p_combinado text default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em retorno_marcar__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.retorno_marcar__nucleo(p_conversa, p_quando, p_combinado); end if;
  perform set_config('porta.dentro', 'retorno_marcar', true);
  v_c := p_conversa;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.retorno_marcar__nucleo(p_conversa, p_quando, p_combinado);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('retorno_marcar', 'retorno_marcar', v_c, null::uuid, v_a, r);
  return r;
end $fn$;
revoke all on function public.retorno_marcar(uuid, timestamptz, text) from public, anon;
grant execute on function public.retorno_marcar(uuid, timestamptz, text) to authenticated;

-- ───────────────────────── (4) feito / descartar / confirmar a sugestão ─────────────────────────
create or replace function public.retorno_fechar__nucleo(p_retorno uuid, p_como text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  r    public.retornos;
  v_nome text;
  c    public.mari_conversas;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into r from public.retornos where id = p_retorno for update;
  if not found then raise exception 'Retorno não encontrado.'; end if;
  if r.estado not in ('sugerido', 'marcado') then
    return jsonb_build_object('ok', true, 'repetido', true, 'resumo', 'Este retorno já foi fechado.');
  end if;
  select nome into v_nome from public.usuarios where id = auth.uid();
  v_nome := coalesce(v_nome, 'time');
  if p_como = 'confirmar' then
    if r.estado <> 'sugerido' then raise exception 'Só uma sugestão se confirma.'; end if;
    if r.quando < now() + interval '10 minutes' then raise exception 'A hora sugerida já passou: marque outra na ficha (📅 Retornar em…).'; end if;
    return public.retorno_marcar__nucleo(r.conversa_id, r.quando, r.combinado);
  elsif p_como in ('feito', 'descartar') then
    update public.retornos
       set estado = case when p_como = 'feito' then 'feito' else 'cancelado' end, fechado_em = now(), fechado_por = v_nome,
           fechado_motivo = coalesce(nullif(left(btrim(coalesce(p_motivo, '')), 200), ''), case when p_como = 'feito' then 'feito pelo time' else 'descartado' end)
     where id = r.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (r.conversa_id, 'sistema', '[retorno de ' || to_char(r.quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' '
            || case when p_como = 'feito' then 'feito' when r.estado = 'sugerido' then 'sugerido: descartado' else 'descartado' end
            || ' por ' || v_nome || ']', false);
    return jsonb_build_object('ok', true, 'resumo', case when p_como = 'feito' then '✓ retorno feito' else '✓ retorno descartado' end);
  end if;
  raise exception 'Use confirmar, feito ou descartar.';
end $fn$;
revoke all on function public.retorno_fechar__nucleo(uuid, text, text) from public, anon, authenticated;

create or replace function public.retorno_fechar(p_retorno uuid, p_como text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare r jsonb; v_c uuid; v_a text;
begin
  -- 0263 (porta em sombra): só anota. O que o sistema faz está todo em retorno_fechar__nucleo — edite LÁ, nunca aqui.
  if coalesce(current_setting('porta.dentro', true), '') <> '' then return public.retorno_fechar__nucleo(p_retorno, p_como, p_motivo); end if;
  perform set_config('porta.dentro', 'retorno_fechar', true);
  select conversa_id into v_c from public.retornos where id = p_retorno;
  v_a := public._porta_situacao(v_c, null::uuid);
  r := public.retorno_fechar__nucleo(p_retorno, p_como, p_motivo);
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('retorno_fechar', 'retorno_fechar', v_c, null::uuid, v_a, r);
  return r;
end $fn$;
revoke all on function public.retorno_fechar(uuid, text, text) from public, anon;
grant execute on function public.retorno_fechar(uuid, text, text) to authenticated;

insert into public.config_evento (codigo, funcao, nome, nota, quem) values
  ('retorno_marcar', 'retorno_marcar', 'Retorno combinado com o cliente (dia e hora)',
   '0379: Mari chama na hora (conversa com ela) ou 🔔 na Live 15 min antes (com o time)', 'time'),
  ('retorno_fechar', 'retorno_fechar', 'Retorno feito, descartado ou sugestão confirmada', '0379', 'time')
on conflict (codigo) do update set funcao = excluded.funcao, nome = excluded.nome, nota = excluded.nota, quem = excluded.quem;
delete from public.config_transicao where evento in ('retorno_marcar', 'retorno_fechar');
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('retorno_marcar', '*', array['=', 'em_espera'], true, null, '0379: lead sem venda vai para a espera até a hora; com venda nada muda', null),
  ('retorno_fechar', '*', array['=', 'em_espera'], true, null, '0379: feito/descartar não mudam a situação; confirmar a sugestão = retorno_marcar', null);

-- ───────────────────────── (5) a Mari: data em até N dias = retorno com hora ─────────────────────────
create or replace function public._mari_espera(c public.mari_conversas, p_retorno text)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  ant   int  := coalesce(nullif(public._bo_cfg('mari_espera_antecedencia_dias', '7'::jsonb) #>> '{}', '')::int, 7);
  v_cli date;
  v_q   timestamptz;   -- 0379: dia e hora que o cliente disse
  v_dia date;
  v_ate timestamptz;
  v_mot text;
  antes text;
  g     uuid := gen_random_uuid();
  r     jsonb;
  v_hora boolean := false;
begin
  begin
    v_cli := (substring(coalesce(p_retorno, '') from '\d{4}-\d{2}-\d{2}'))::date;
    if coalesce(p_retorno, '') ~ '\d{2}:\d{2}' then
      v_q := case when btrim(p_retorno) ~ '([+-]\d{2}(:?\d{2})?|Z)$' then btrim(p_retorno)::timestamptz
                  else btrim(p_retorno)::timestamp at time zone 'America/Sao_Paulo' end;
    end if;
  exception when others then v_cli := null; v_q := null;
  end;
  if v_cli is null or v_cli < hoje or c.venda_id is not null or coalesce(c.nao_contatar, false) then return null; end if;
  -- 0379 (Ricardo 24/11: "Mari retoma"): perto (até N dias) = retorno com hora — a Mari chama no horário (o passo RETORNO da
  -- cadência, com agendamento_retorno), e a espera segura o resto até 2 h depois; sem resposta, volta para o time.
  if v_q is not null and v_cli <= hoje + ant and v_q > now() + interval '5 minutes' then
    v_hora := true;
    v_ate := v_q + interval '2 hours';
    v_mot := 'retorno combinado ' || to_char(v_q at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' — a Mari chama';
  else
    if v_cli <= hoje then return null; end if;
    v_dia := greatest(hoje + 1, least(v_cli - ant, hoje + 60));
    v_ate := (v_dia::text || ' 09:00')::timestamp at time zone 'America/Sao_Paulo';
    v_mot := 'cliente decide até ' || to_char(v_cli, 'DD/MM');
  end if;
  if c.espera_ate is not null and c.espera_ate > now()
     and ((v_hora and abs(extract(epoch from c.espera_ate - v_ate)) < 300)
          or (not v_hora and (c.espera_ate at time zone 'America/Sao_Paulo')::date = (v_ate at time zone 'America/Sao_Paulo')::date)) then
    return jsonb_build_object('ok', true, 'repetida', true, 'ate', v_ate);
  end if;
  antes := public._porta_situacao(c.id, null::uuid);
  update public.mari_conversas
     set espera_ate = v_ate, espera_motivo = v_mot, espera_em = now(), espera_por = null,
         agendamento_retorno = case when v_hora then v_q else agendamento_retorno end
   where id = c.id;
  perform public._retorno_gravar(c, coalesce(case when v_hora then v_q end, v_ate), case when v_hora then 'mari' else 'time' end,
                                 'mari', v_mot, 'marcado', v_hora, null);
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[em espera até ' || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' — ' || v_mot || ' — marcado pela Mari]', false);
  if coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
    perform public._bo_enfileirar(g, 1, 'espera', null, c, 'nota', jsonb_build_object('content',
      case when v_hora
           then '📅 Retorno combinado para ' || to_char(v_q at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
                || ' (marcado pela Mari). A Mari chama o cliente na hora; se ele não responder em 2 h, volta para o Live.'
           else '⏸ Em espera até ' || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM') || ' — ' || v_mot || ' (marcado pela Mari). Volta para o Live no dia, '
                || 'ou antes se o cliente escrever. Combinado com o cliente: perto da data, o nosso time chama.' end));
    perform public._bo_enfileirar(g, 2, 'espera', null, c, 'resolver',
      jsonb_build_object('status', 'snoozed', 'snoozed_until', extract(epoch from coalesce(case when v_hora then v_q end, v_ate))::bigint));
  end if;
  r := jsonb_build_object('ok', true, 'ate', v_ate, 'cliente', v_cli, 'motivo', v_mot, 'hora', v_hora);
  perform public._porta_anotar('aguardar', 'mari_handoff', c.id, null::uuid, antes, r);
  return r;
end $fn$;
revoke execute on function public._mari_espera(public.mari_conversas, text) from public, anon, authenticated;

-- ───────────────────────── (7) detector: fala do cliente com a conversa no time ─────────────────────────
create or replace function public._retorno_detectar()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  c   public.mari_conversas;
  q   jsonb;
  v_q timestamptz;
  g   uuid := gen_random_uuid();
begin
  if new.papel <> 'lead' or coalesce(new.texto, '') = '' then return null; end if;
  begin
    select * into c from public.mari_conversas where id = new.conversa_id;
    if not found or coalesce(c.nao_contatar, false) then return null; end if;
    if coalesce(c.funil_destino, 'em_andamento') <> 'em_andamento' then return null; end if;
    -- com a Mari, quem lê o pedido é ela ([AGENDAMENTO_RETORNO]); o detector é só para a conversa no time
    if not (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status <> 'ativo') then return null; end if;
    q := public._retorno_ler_quando(new.texto, new.created_at);
    if q is null then return null; end if;
    v_q := (q ->> 'quando')::timestamptz;
    if exists (select 1 from public.retornos r where r.conversa_id = c.id and r.estado in ('sugerido', 'marcado') and r.quando = v_q) then return null; end if;
    perform public._retorno_gravar(c, v_q, 'time', 'detector', q ->> 'trecho', 'sugerido', (q ->> 'tem_hora')::boolean, null);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[o cliente pediu retorno — sugestão: ' || to_char(v_q at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
            || '; confirme ou descarte na Live › Conferir]', false);
    if coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
      perform public._bo_enfileirar(g, 1, 'retorno', c.venda_id, c, 'nota', jsonb_build_object('content',
        '📅 O cliente pediu retorno («' || left(q ->> 'trecho', 120) || '»). Sugestão: ' || to_char(v_q at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI')
        || case when (q ->> 'tem_hora')::boolean then '' else ' (ele não disse a hora)' end
        || '. Confirme ou descarte na Live › Conferir — ou marque outra hora na ficha (📅 Retornar em…).'));
    end if;
  exception when others then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (new.conversa_id, '0379 · detector de retorno', sqlerrm, jsonb_build_object('turno', new.id));
  end;
  return null;
end $fn$;
revoke all on function public._retorno_detectar() from public, anon, authenticated;
drop trigger if exists mari_turnos_retorno_detectar on public.mari_turnos;
create trigger mari_turnos_retorno_detectar after insert on public.mari_turnos
  for each row when (new.papel = 'lead') execute function public._retorno_detectar();

-- ───────────────────────── (6) cadência: o RETORNO passa pela espera (= versão no ar + 1 condição) ─────────────────────────
CREATE OR REPLACE FUNCTION public.mari_cadencia_avaliar(p_agora timestamp with time zone DEFAULT now(), p_conversa uuid DEFAULT NULL::uuid)
 RETURNS TABLE(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text, passo_atual text, passo_em timestamp with time zone, proximo_passo text, proximo_em timestamp with time zone, pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text, janela_aberta boolean, janela_fecha_em timestamp with time zone, toques_hoje integer, toques_mes integer, ligar_sugerido boolean, venda_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  v_tq     record;
  v_teto   record;   -- 0102: config_regras.contato_teto_dia/_mes (nulo = sem teto)
  L        timestamptz;   -- última msg do lead
  M        timestamptz;   -- última msg da Mari
  B        timestamptz;   -- base dos D (lead, retorno ou 1º contato)
  f1_at    timestamptz; f_base timestamptz; f_ant timestamptz; fats timestamptz[]; fval timestamptz[]; k int; k2 int; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  v_turno  text; v_dia date;
  v_dom    boolean;   -- 0209: véspera no domingo/feriado (exceção do Ricardo, 15/11)
  v_inst   boolean;
  v_bio    boolean;   -- 0253 (D9): venda com biometria pendente e link já enviado — o lembrete é aviso da venda
  v_volta  timestamptz;   -- 0196   -- 0114: venda com instalação agendada (aviso/lembrete são da venda, não da conversa)
  v_hum    timestamptz;   -- 0274: última fala do time
  v_aviso_h numeric := coalesce(nullif(public._bo_cfg('aviso_venda_espera_horas', '2'::jsonb) #>> '{}', '')::numeric, 2);
  v_pausa  text := nullif(public._bo_cfg('retomada_pausa_regex', 'null'::jsonb) #>> '{}', '');
  l15_at   timestamptz; v_ab_em timestamptz; v_ab_tags jsonb;   -- 0070: lembrete leve da abertura B2
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
  select * into v_teto from public.contato_teto();
  for c in
    select * from public.mari_conversas mc
     where (p_conversa is null or mc.id = p_conversa)
       and mc.canal in ('teste', 'whatsapp')
       and (mc.status = 'ativo'
            or (mc.status = 'handoff_realizado' and mc.venda_id is not null))   -- biometria pendente / instalação agendada
     order by mc.updated_at desc
  loop
    v_passo := null; v_at := null; v_bloq := null; v_acao := null; v_tpl := null; v_cat := null;
    v_params := null; v_txt := null; v_exc := null; v_pode := false; v_lig := false;
    L := c.ultima_msg_lead_at; M := c.ultima_msg_mari_at;
    v_janela := L is not null and p_agora < L + interval '23 hours';
    select * into v_tq from public.mari_toques(c.telefone, p_agora);
    -- ── paradas absolutas ──
    if c.nao_contatar then v_bloq := 'cliente pediu para não ser contatado';
    -- 0274: a Retomada (D3 → Ligar → D7 → D15) sai pela fila do NIOGEN, não pela escada do n8n
    elsif c.retomada_desde is not null and c.retomada_fim_em is null then v_bloq := 'Retomada pelo NIOGEN (D3 → Ligar → D7 → D15)';
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
    -- 0227 (D10): ⏸ Aguardar pausa a cadência até a data (se o cliente escrever, a Mari responde normalmente)
    -- 0379 (agenda de retornos): a espera não segura o RETORNO combinado que chegou a hora (a Mari chama; a espera segue até 2 h depois)
    elsif c.espera_ate is not null and c.espera_ate > p_agora
          and not (c.agendamento_retorno is not null and c.agendamento_retorno <= p_agora
                   and c.agendamento_retorno > coalesce(c.ultima_msg_lead_at, c.created_at)
                   and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno)) then
      v_bloq := 'em espera (⏸) até ' || to_char(c.espera_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    -- 0227 (D5): destino de saída pela regra (CEP fora da área, sem cobertura, já é cliente Nio) não recebe toque
    elsif c.funil_destino in ('fora_area', 'sem_cobertura', 'ja_cliente_nio') then
      v_bloq := 'destino de saída pela regra (' || c.funil_destino || ')';
    elsif c.canal = 'whatsapp' and c.telefone like '5500000000%' then v_bloq := 'telefone de teste';
    -- 0064 (08/11): venda "Em espera" (pendência com terceiro aberta) pausa toda a cadência até a pendência ser encerrada.
    elsif c.venda_id is not null and exists (select 1 from public.venda_pendencias vp
                                              where vp.venda_id = c.venda_id and vp.encerrada_em is null) then
      v_bloq := 'venda em espera (pendência com terceiro)';
    end if;
    -- 0114 (Ricardo, 10/11 ~20h40 "Sim, faça os dois"): o aviso do agendamento (C2) e o lembrete da véspera (C3) são da VENDA —
    -- saem com a conversa em qualquer estado (ativa ou em handoff), com humano/time atribuído, resolvida no Chatwoot ou com
    -- pendência aberta. Só "não contatar" e telefone de teste param.
    v_inst := c.venda_id is not null and exists (select 1 from public.vendas vi where vi.id = c.venda_id
                and vi.status = '2_aguardando_instalacao' and vi.instalacao_agendada_para > p_agora);
    -- 0253 (D9, regra de ouro 6: "aviso da venda sai sempre; só Saída e Não contatar barram"): o lembrete da biometria também.
    -- Antes, com o time atribuído (o normal depois do handoff de venda), o BIO1 ficava barrado e nunca saía.
    v_bio := c.venda_id is not null and exists (select 1 from public.vendas vb where vb.id = c.venda_id
               and vb.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
               and vb.biometria_status = 'pendente' and vb.biometria_link_enviado_em is not null);
    if (v_inst or v_bio) and not coalesce(c.nao_contatar, false) and not (c.canal = 'whatsapp' and c.telefone like '5500000000%') then
      v_bloq := null;
    end if;
    if c.status = 'handoff_realizado' or v_inst or v_bio then
      -- ── venda remota (05/11): biometria pendente e instalação agendada ──
      if v_bloq is not null then continue; end if;
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em, v.forma_pagamento, v.biometria_validada_em,
             exists (select 1 from public.os_andamento oa where oa.venda_id = v.id and oa.estado is not null
                       and oa.pedido = btrim(v.nio_pedido)   -- 0278: só a OS atual (a OS cancelada de um pedido reemitido não conta)
                       and oa.estado not in ('aguardando_pagamento', 'rascunho', 'cancelada', 'cancelando', 'reprovada')
                       and oa.mudou_em > v.biometria_validada_em) as cartao_ok,
             v.nio_pedido,
             (select oa.estado from public.os_andamento oa where oa.pedido = btrim(v.nio_pedido)
                and oa.estado in ('rascunho', 'cancelada', 'cancelando', 'reprovada') limit 1) as os_parada,
             v.instalacao_agendada_para, v.instalacao_turno, v.logradouro, v.numero, v.complemento, v.bairro
        into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.status <> 'saida';
      if not found then continue; end if;
      -- 0191: a biometria vem DEPOIS da OS — os lembretes valem também com a venda já contada (Ativação/Agenda).
      if v_venda.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao') and v_venda.biometria_status = 'pendente' and v_venda.biometria_link_enviado_em is not null then
        select q.fim into v_volta from public.biometria_quedas q
         where q.fim is not null and q.fim > p_agora - interval '48 hours' and q.inicio > v_venda.biometria_link_enviado_em - interval '15 days'
           and v_venda.biometria_link_enviado_em < q.fim
         order by q.fim desc limit 1;
        if v_volta is not null and (c.bio_volta_em is null or c.bio_volta_em < v_volta) then
          -- 0196: a biometria da Nio voltou depois de uma queda e este cliente ficou esperando: a Mari avisa (só na janela de 24 h).
          v_passo := 'BIOVOLTA'; v_at := v_volta;
          select replace(t.texto, '{nome}', public.mari_cadencia_nome(c)) into v_txt from public.config_mari_textos t where t.chave = 'mari_bio_voltou';
          v_acao := 'texto'; v_tpl := null;
          if not v_janela then v_bloq := 'janela de 24 h fechada: o time fala com o cliente (Live)'; end if;
        elsif c.bio_lembrete_em is null or c.bio_lembrete_em < v_venda.biometria_link_enviado_em then
          -- BIO1: D+1 do link, uma vez só. 0032: o link é da Nio (WhatsApp + e-mail, na hora do pedido) — a contagem parte
          -- da hora do pedido e o lembrete é o C1 v2 (sem botão de link): lembra que a Nio mandou, conferir o spam, ajuda por aqui.
          v_passo := 'BIO1';
          v_at := public.mari_proximo_horario(v_venda.biometria_link_enviado_em + interval '1 day', c.cidade);
          v_tpl := 'nio_lembrete_biometria_v2';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
          if v_janela then
            v_acao := 'texto'; v_tpl := null;   -- texto livre (janela de 24 h): o mesmo texto do C1 v2
          else
            v_acao := 'template'; v_cat := 'UTILITY';
          end if;
          if p_agora < v_at then v_bloq := 'aguardando o D+1 do link da biometria (hora do pedido)';
          end if;
        else
          -- BIO3: D+3 sem biometria → o humano liga. Nunca automático.
          v_passo := 'BIO3'; v_acao := 'ligar';
          v_at := v_venda.biometria_link_enviado_em + interval '3 days';
          v_lig := p_agora >= v_at;
          v_bloq := case when p_agora < v_at then 'aguardando o D+3 do link da biometria (hora do pedido)'
                         else 'D+3 sem biometria: o nosso time liga para o cliente (nunca automático)' end;
        end if;
      elsif v_venda.status = '2_aguardando_instalacao' and v_venda.instalacao_agendada_para > p_agora
            and v_venda.biometria_status = 'validada' then   -- 0191: confirmação da instalação só depois da biometria aprovada
        v_dia := (v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date;
        v_turno := coalesce(v_venda.instalacao_turno,
                            case when extract(hour from v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12
                                 then 'tarde' else 'manha' end);
        if v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_avisado_em is null then
          -- 0191 (Ricardo, 14/11): cartão — biometria aprovada, a Nio manda o link do cadastro do cartão. A Mari avisa com jeitinho.
          v_passo := 'CARTAO'; v_at := p_agora;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_aviso';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_lembrete_em is null then
          -- 0191: 24 h sem o cadastro do cartão → um lembrete gentil. 48 h → o time liga (v_jornada / Live).
          v_passo := 'CARTAO2';
          -- 0198 (Ricardo/Rogério, 14/11): a Nio agenda mesmo sem o cartão, mas sem o cadastro NÃO instala — o lembrete sai
          -- em 24 h ou na véspera da visita, o que vier primeiro (nunca antes de 2 h do aviso).
          vis_dia := v_dia - 1;
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          v_at := greatest(c.cartao_avisado_em + interval '2 hours',
                    least(public.mari_proximo_horario(c.cartao_avisado_em + interval '24 hours', c.cidade),
                          public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade)));
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_lembrete';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
          if p_agora < v_at then v_bloq := 'aguardando o lembrete do cartão (24 h ou a véspera da visita)'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok then
          continue;   -- 0191: lembrete já saiu; esperando o cadastro do cartão (48 h → o time liga)
        elsif c.instalacao_avisada_para is distinct from v_venda.instalacao_agendada_para then
          -- C2: assim que agendar (ou reagendar).
          v_passo := 'INSTALACAO'; v_at := p_agora;
          v_params := jsonb_build_array(
            public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end,
            concat_ws(', ', nullif(btrim(v_venda.logradouro), ''), nullif(btrim(v_venda.numero), ''),
                      nullif(btrim(v_venda.complemento), ''), nullif(btrim(v_venda.bairro), '')));
          v_tpl := 'nio_instalacao_agendada';
        elsif c.instalacao_lembrada_para is distinct from v_venda.instalacao_agendada_para then
          -- C3: véspera (dia permitido anterior).
          vis_dia := v_dia - 1;
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          -- 0209 (Ricardo, 15/11: "nesse caso, pode abrir uma exceção e enviar no domingo"): se o aviso do agendamento (C2) saiu
          -- no dia da véspera permitida ou depois (ex.: instalação na segunda agendada no sábado à tarde), a véspera não teria dia
          -- nenhum — então ela sai no dia anterior à instalação mesmo sendo domingo/feriado, das 10h às 16h.
          v_dom := c.instalacao_avisada_em is not null
                   and vis_dia <= (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date
                   and (v_dia - 1) > (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date;
          if v_dom then vis_dia := v_dia - 1; end if;
          vis_ini := case when v_dom then (vis_dia::timestamp + time '10:00') at time zone 'America/Sao_Paulo'
                          else public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade) end;
          v_passo := 'VESPERA'; v_at := vis_ini;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), to_char(v_dia, 'DD/MM'),
                                        case v_turno when 'tarde' then 'tarde' else 'manhã' end);
          v_tpl := 'nio_lembrete_instalacao';
          if p_agora < v_at then v_bloq := 'aguardando a véspera da instalação';
          -- 0114: o texto diz "é amanhã" — nunca sai no próprio dia da instalação.
          elsif (p_agora at time zone 'America/Sao_Paulo')::date >= v_dia then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
          elsif v_dom and p_agora >= (vis_dia::timestamp + time '16:00') at time zone 'America/Sao_Paulo' then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif v_dom then v_exc := 'véspera no domingo/feriado: sem outro dia antes da instalação';   -- passa pela regra do horário (só 10h–16h, acima)
          end if;
        else
          continue;
        end if;
        if v_passo in ('INSTALACAO', 'VESPERA') then
        v_txt := public.mari_render_template(v_tpl, v_params);
        -- 0114: aviso e lembrete da instalação saem SEMPRE como template (com os botões Confirmo/Tudo certo · Preciso remarcar),
        -- mesmo com a janela aberta — a resposta ao botão é o que preenche "Confirmou?" (0112).
        v_acao := 'template'; v_cat := 'UTILITY';
        end if;
      else
        continue;   -- nada a fazer nesta conversa em handoff
      end if;
    elsif v_bloq is null and c.status = 'ativo' then
      -- 0050 (Ricardo, 06/11): venda em Saída não recebe nada da cadência ("Interesse futuro" vira etiqueta no
      -- Chatwoot, 0052; "Sem cobertura" não ganha nada).
      if c.venda_id is not null and exists (select 1 from public.vendas vs where vs.id = c.venda_id and vs.status = 'saida') then
        continue;
      end if;
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
      -- 0199 (trava A): a resposta do TIME também é resposta. Antes, o time respondia, devolvia para a Mari e a escada nunca
      -- recomeçava (M < L para sempre) — Leandro e Lucia Dias parados em silêncio.
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum'
            and not exists (select 1 from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano' and th.created_at >= L) then
        v_bloq := 'aguardando a Mari responder';
      else
        -- ── a escada ──
        B := greatest(coalesce(L, '-infinity'::timestamptz), coalesce(c.cadencia_retorno_em, '-infinity'::timestamptz));
        if L is null then
          B := coalesce((select min(cc.em) from public.contatos_cliente cc where cc.conversa_id = c.id and cc.toque = 'P1'),
                        c.cadencia_passo_em, c.created_at);
          seq := array['P1', 'D7', 'D15', 'ENCERRAR'];
          ats := array[c.created_at, B + interval '7 days', B + interval '15 days', null];
          validos := array[B + interval '7 days', B + interval '15 days', 'infinity'::timestamptz, 'infinity'::timestamptz];
        else
          -- 0141 (Ricardo, 12/11): 5 cutucadas na janela de 24 h, em QUALQUER etapa: 15 min, 1 h, 3 h e 6 h depois da última fala
          -- REAL da Mari e a última chamada ~20 h depois da mensagem do cliente. Fora do horário do contrato (seg–sex 9–21, sáb
          -- 10–16, nunca domingo/feriado) vai para a abertura seguinte, com no mínimo 45 min entre duas, se ainda couber na janela
          -- (até L + 23 h); senão é pulada. O cliente respondeu → L muda e a escada recomeça. Substitui L15/F1/F2.
          -- 0199: a última fala real é da Mari OU do time (a cutucada não sai 15 min depois de uma fala velha da Mari
          -- quando o time acabou de responder).
          f_base := coalesce((select max(t.created_at) from public.mari_turnos t
                               where t.conversa_id = c.id and t.papel in ('mari', 'humano') and coalesce(t.tags ->> 'cadencia', '') = ''), M);
          fats := array[f_base + interval '15 minutes', f_base + interval '1 hour', f_base + interval '3 hours',
                        f_base + interval '6 hours', L + interval '20 hours'];
          -- 0274 (caso Kika, Ricardo 18/11): o cliente disse "vou ver / depois te mando" → 24 h sem cutucada (a escada segue no D3)
          if v_pausa is not null and exists (select 1 from public.mari_turnos tl where tl.conversa_id = c.id and tl.papel = 'lead'
                                               and tl.created_at > L - interval '10 minutes' and tl.texto ~* v_pausa) then
            for k in 1..5 loop
              if fats[k] < L + interval '24 hours' then fats[k] := null; end if;
            end loop;
          end if;
          f_ant := null;
          for k in 1..5 loop
            if c.cadencia_retorno_em is not null then fats[k] := null; continue; end if;
            if f_ant is not null and fats[k] < f_ant + interval '45 minutes' then fats[k] := f_ant + interval '45 minutes'; end if;
            if not public.mari_no_horario(fats[k], c.cidade) then fats[k] := public.mari_proximo_horario(fats[k], c.cidade); end if;
            if fats[k] is null or fats[k] >= L + interval '23 hours' then fats[k] := null; else f_ant := fats[k]; end if;
          end loop;
          fval := array[null, null, null, null, null]::timestamptz[];
          for k in 1..5 loop
            fval[k] := L + interval '23 hours';
            if k < 5 then
              for k2 in (k + 1)..5 loop
                if fats[k2] is not null then fval[k] := least(fats[k2], fval[k]); exit; end if;
              end loop;
            end if;
          end loop;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          seq := array['F1', 'F2', 'F3', 'F4', 'F5', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[fats[1], fats[2], fats[3], fats[4], fats[5], d3_at, d7_at, d15_at, null];
          validos := array[fval[1], fval[2], fval[3], fval[4], fval[5], d7_at, d15_at,
                           'infinity'::timestamptz, 'infinity'::timestamptz];
        end if;
        if c.cadencia_passo = 'D15' then
          ats[array_length(seq, 1)] := c.cadencia_passo_em + interval '48 hours';
        end if;
        idx_atual := coalesce(array_position(seq, c.cadencia_passo), 0);
        if c.cadencia_passo = 'F2' and seq[1] = 'P1' then idx_atual := 1; end if;
        alvo := null; prox := null;
        for i in (idx_atual + 1)..array_length(seq, 1) loop
          if ats[i] is null then continue; end if;
          if seq[i] in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
          if ats[i] <= p_agora and p_agora < validos[i] then alvo := i;
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
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
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
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        -- 0050 (Ricardo, 06/11): venda já criada NUNCA sai sozinha e não recebe a escada de templates de lead —
        -- só as cutucadas F1/F2 dentro da janela; o resto é do backoffice, pela venda.
        if c.venda_id is not null and v_passo not in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_bloq := 'venda criada: o backoffice segue pela venda (a cadência não manda D3/D7/D15 nem encerra)';
        end if;
        v_lig := c.cadencia_passo = 'D3' and p_agora >= c.cadencia_passo_em + interval '1 day' and p_agora < B + interval '6 days';
      end if;
    end if;
    if v_passo is null then
      if v_bloq is null then continue; end if;
    end if;
    -- 0110 (Ricardo, 10/11 16h02): o time mandou (ou ligou) pela 🔥 oportunidade HOJE e o cliente ainda não respondeu →
    -- nenhum toque automático no mesmo dia (nunca dois toques num dia: um do humano e um da Mari); o próximo vai para o dia
    -- útil seguinte. Retorno pedido pelo cliente (v_exc) segue valendo. Cliente respondeu → L passa da mensagem e a regra é a de sempre.
    if v_bloq is null and v_passo is not null and v_exc is null and v_acao in ('texto', 'template')
       and v_passo not in ('INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIOVOLTA')   -- 0114: aviso/lembrete da instalação não são toque de venda
       and (exists (select 1 from public.oportunidades_log ol
                    where ol.conversa_id = c.id and ol.tipo = 'enviada'
                      and ol.criado_em > coalesce(L, '-infinity'::timestamptz)
                      and (ol.criado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)
            -- 0226 (M7): vale para QUALQUER fala do time hoje (NIOGEN ou Chatwoot), não só o 🔥
            or exists (select 1 from public.mari_turnos th
                        where th.conversa_id = c.id and th.papel = 'humano'
                          and th.created_at > coalesce(L, '-infinity'::timestamptz)
                          and (th.created_at at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)) then
      v_bloq := 'o time falou com o cliente hoje (🔥 oportunidade): o toque vai para o próximo dia útil';
      v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
    end if;
    -- 0274 (caso Lucas, Ricardo 18/11): o LEMBRETE automático da venda espera 2 h depois de alguém do time falar com o cliente.
    -- O aviso imediato do que o time acabou de fazer (INSTALACAO com os botões, CARTAO com o link) sai na hora, como antes (E1, E2).
    if v_bloq is null and v_passo in ('BIO1', 'BIOVOLTA', 'CARTAO2', 'VESPERA') then
      select max(th.created_at) into v_hum from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano';
      if v_hum is not null and v_hum > p_agora - make_interval(hours => v_aviso_h::int) then
        v_bloq := 'o time falou com o cliente há menos de ' || v_aviso_h::int || ' h: o aviso da venda espera';
        v_at := greatest(v_at, v_hum + make_interval(hours => v_aviso_h::int));
      end if;
    end if;
    -- 0278 (caso de 18/11, troca da forma de pagamento): a Consulta OS diz que a OS da venda foi cancelada ou virou rascunho no portal
    -- (o time está reemitindo o pedido) → nenhum aviso da venda sai com dado velho. Volta sozinho quando a OS nova é gravada
    -- (Reemitir pedido) ou a OS volta a andar. O motivo aparece na trilha dos lembretes da ficha.
    if v_bloq is null and v_passo in ('BIO1', 'BIO3', 'BIOVOLTA', 'CARTAO', 'CARTAO2', 'INSTALACAO', 'VESPERA') then
      -- (v_venda só existe no ramo da venda; estes passos só nascem lá)
      if v_venda.os_parada is not null then
        v_bloq := 'a OS ' || coalesce(v_venda.nio_pedido, '') || ' está '
               || case v_venda.os_parada when 'rascunho' then 'em rascunho (Draft)' when 'cancelando' then 'em cancelamento' else v_venda.os_parada end
               || ' no portal: o aviso da venda espera a OS nova (ficha › Reemitir pedido)';
      end if;
    end if;
    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      -- 0226 (M5): o retorno pedido pelo cliente também respeita a madrugada (só o horário, não as outras regras)
      if (v_exc is null or v_passo = 'RETORNO') and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_teto.dia is not null and v_tq.hoje >= v_teto.dia then
        v_bloq := 'limite do dia (' || v_teto.dia || ' toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_teto.mes is not null and v_tq.mes >= v_teto.mes then
        v_bloq := 'limite do mês (' || v_teto.mes || ' toques)';
      elsif v_acao = 'template' and not exists (select 1 from public.config_templates_waba t where t.nome = v_tpl and t.status = 'APPROVED') then
        v_bloq := 'template não aprovado';
      else
        v_proib := public.mari_texto_proibido(v_txt);
        if v_proib is not null then v_bloq := 'texto reprovado no filtro (' || v_proib || ')'; end if;
      end if;
    end if;
    v_pode := v_passo is not null and v_bloq is null and v_acao is distinct from 'ligar';
    conversa_id := c.id; telefone := c.telefone; canal := c.canal; chatwoot_conversation_id := c.chatwoot_conversation_id;
    status := c.status; etapa := c.etapa; passo_atual := c.cadencia_passo; passo_em := c.cadencia_passo_em;
    proximo_passo := v_passo; proximo_em := v_at; pode_enviar := v_pode; bloqueio := v_bloq; acao := v_acao;
    template := v_tpl; categoria := v_cat; params := v_params; texto := v_txt; excecao := v_exc;
    janela_aberta := v_janela; janela_fecha_em := case when L is not null then L + interval '24 hours' end;
    toques_hoje := v_tq.hoje; toques_mes := v_tq.mes; ligar_sugerido := v_lig; venda_id := c.venda_id;
    return next;
  end loop;
end;
$function$;

-- ───────────────────────── (8) Live › Conferir: 🔔 retorno e sugestão (= versão no ar + 2 tipos) ─────────────────────────
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
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  -- 0324: venda com o time, o time falou por último e a janela de 24 h do CLIENTE fechou — esperar não resolve: ligar ou template
  jf as (
    select c.id, ul.ult_lead
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult_lead from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead') ul
      cross join lateral (select t.papel from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')
                           order by t.created_at desc limit 1) ut
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null)
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and ((v.id is not null and v.status in ('0_qualificado', '1_vendido'))
            or c.funil_etapa in ('qualificada', 'pedido', 'biometria')
            or coalesce(c.credito_resultado, '') ~ '^(aprovado|cartao)')
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and ut.papel = 'humano'
       and ul.ult_lead < now() - interval '24 hours'
       and (c.janela_acao_em is null or c.janela_acao_em < now() - interval '24 hours')   -- tentou hoje: volta amanhã
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
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
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
      cross join lateral (select greatest(max(t.created_at), c.janela_acao_em) as ult from public.mari_turnos t   -- 0324: a ligação/template conta
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
     and c.id not in (select jf.id from jf)                       -- 0324: a linha da janela fechada é a dela
    union all
    -- (c2) 0324: venda esperando o cliente com a janela do WhatsApp fechada — o time liga ou manda o template
    select 'janela_fechada', c.id::text, c.id, c.venda_id, n.nome, jf.ult_lead + interval '24 hours', 2,
           format('Janela fechada há %s — o cliente não responde desde %s; mensagem livre não sai mais: ligue para %s ou mande o template%s',
                  case when now() - (jf.ult_lead + interval '24 hours') >= interval '48 hours'
                       then floor(extract(epoch from now() - (jf.ult_lead + interval '24 hours')) / 86400)::int || ' dias'
                       else greatest(1, floor(extract(epoch from now() - (jf.ult_lead + interval '24 hours')) / 3600))::int || ' h' end,
                  to_char(jf.ult_lead at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), c.telefone,
                  case when c.janela_acao_em is not null
                       then ' (última tentativa ' || to_char(c.janela_acao_em at time zone 'America/Sao_Paulo', 'DD/MM') || ': '
                            || case c.janela_acao when 'atendeu' then 'atendeu' when 'nao_atendeu' then 'não atendeu' else 'template' end || ')'
                       else '' end)
      from jf
      join public.mari_conversas c on c.id = jf.id
      join nomes n on n.id = c.id
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
           -- 0271 (passo 6, Live): prazo de 24 h úteis a contar da Saída e dono = quem deu a Saída. Vencido = "VENCIDO" no texto (a Live acende).
           case when public._horas_uteis(ev.em, now()) >= 24 then 'VENCIDO · ' else 'prazo: faltam ' || greatest(1, ceil(24 - public._horas_uteis(ev.em, now())))::int || ' h úteis · ' end
             || 'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || coalesce(' · Saída dada por ' || ev.quem, '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select e.criado_em as em, (select split_part(btrim(u.nome), ' ', 1) from public.usuarios u where u.id = e.criado_por) as quem
                            from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status' order by e.criado_em desc limit 1) ev
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
       and a.excecao_vista_chave is distinct from concat_ws('|', a.estado, a.status_ordem, a.acao)   -- 0318: Visto até a OS mudar
    union all
    -- (i3) 0323: Situação do agendamento no dia da visita (sem técnico tarde, técnico definido, a caminho, instalando, cancelada)
    --       — "Ciente" esconde até a Situação mudar; a visita cancelada com a OS já em exceção fica só na linha da exceção
    select 'os_agenda', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), s.desde,
           case when s.aviso in ('cancelado', 'sem_tecnico') then 1 else 2 end,
           s.texto
      from public.os_andamento a
      join public.vendas v on v.id = a.venda_id
      cross join lateral public._os_agenda_aviso(a) s
     where v.status in ('1_vendido', '2_aguardando_instalacao')
       and a.agenda_ciente_chave is distinct from s.chave
       and not (s.aviso = 'cancelado' and a.excecao and a.excecao_vista_chave is distinct from concat_ws('|', a.estado, a.status_ordem, a.acao))
    union all
    -- (i2) 0196: biometria da Nio fora do ar (suspeita automática pelo GED360 ou marcada pelo time)
    select 'biometria_fora', q.id::text, null::uuid, null::uuid, 'Biometria da Nio', q.inicio, 1,
           format('%s desde %s%s · %s venda(s) esperando a biometria — peça à Nio a dispensa e marque "Nio dispensou" em cada ficha; quando voltar, marque "Voltou" (Operações › Biometria)',
                  case when q.confirmada_em is null then 'Biometria da Nio parece fora do ar (GED360 sem biometria nova há ' || q.horas_sem_envio || ' h no horário comercial · confirme no grupo)'
                       else 'Biometria da Nio FORA DO AR' end,
                  to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                  case when q.origem = 'manual' then ' (marcada por ' || coalesce((select u.nome from public.usuarios u where u.id = q.aberta_por), 'time') || ')' else '' end,
                  (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')))
      from public.biometria_quedas q
     where q.fim is null
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
       and not (coalesce(c.vistos, '{}'::jsonb) ? (x ->> 'codigo'))   -- 0318: Visto hoje
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
    union all
    -- (l) 0202: o portal consultou outra rua (ou disse "sem viabilidade" com a fachada viável no DFV) — o time confere a rua
    select 'conferir_rua', c.id::text, c.id, c.venda_id, n.nome, c.rua_conferir_em,
           case when c.rua_conferir_em < now() - interval '4 hours' then 1 else 2 end,
           format('%s — cliente: %s, nº %s · portal: %s%s. Refaça na Cobertura escolhendo a rua do cliente e marque "Conferi"%s',
                  case c.rua_conferir ->> 'motivo' when 'rua_divergente' then 'O portal consultou OUTRA RUA'
                       else 'O portal disse sem viabilidade, mas a fachada está viável no DFV' end,
                  coalesce(nullif(c.rua_conferir ->> 'esperada', ''), c.endereco_cep ->> 'logradouro', '?'), coalesce(c.numero, '?'),
                  coalesce(nullif(split_part(c.rua_conferir ->> 'portal', ',', 1), ''), '?'),
                  coalesce(' · DFV: ' || nullif(c.rua_conferir ->> 'dfv', ''), ''),
                  case when c.rua_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.rua_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274: Saída sai do Conferir
    union all
    -- (n) 0233: unidade a confirmar — o portal tem lista fechada de unidades e a do cliente não bate (ou ele disse "nenhuma
    -- dessas", ou o endereço não tem nenhuma cadastrada). Dono: backoffice. Prazo: 4 h.
    select 'conferir_unidade', c.id::text, c.id, c.venda_id, n.nome, c.unidade_conferir_em,
           case when c.unidade_conferir_em < now() - interval '4 hours' or c.unidade_conferir ->> 'motivo' <> 'escolher' then 1 else 2 end,
           format('%s · %s, nº %s%s',
                  case c.unidade_conferir ->> 'motivo'
                       when 'escolher' then format('Unidade a confirmar — viável no endereço; o cliente disse "%s" e o portal tem: %s. A Mari está perguntando qual é; se ele não escolher, confirme com ele. No pedido, escolha a unidade DELE (nunca outra)',
                                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), 'nada'), coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       when 'nenhuma' then format('Unidade fora do cadastro da Nio — o cliente disse que a unidade dele não é nenhuma de: %s. Peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                                  coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       else format('Endereço sem unidade cadastrada na Nio (complemento "%s") — peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), c.complemento, '?')) end,
                  coalesce(c.endereco_cep ->> 'logradouro', 'CEP ' || c.cep, '?'), coalesce(c.numero, '?'),
                  case when c.unidade_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.unidade_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274
    union all
    -- (o) 0274: Retomada — o D3 saiu há 1 dia e o cliente não respondeu: o time liga (nunca automático). Some quando o D7 sai.
    select 'retomada_ligar', c.id::text, c.id, c.venda_id, n.nome, c.retomada_passo_em + interval '1 day', 2,
           format('Retomada: a Mari mandou o D3 em %s e o cliente não respondeu — ligue para %s. Se não atender, o D7 sai em %s',
                  to_char(c.retomada_passo_em at time zone 'America/Sao_Paulo', 'DD/MM'), c.telefone,
                  to_char(public._retomada_quando(c, 'D7') at time zone 'America/Sao_Paulo', 'DD/MM'))
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.retomada_desde is not null and c.retomada_fim_em is null and c.retomada_passo = 'D3'
       and c.retomada_passo_em < now() - interval '1 day' and not coalesce(c.nao_contatar, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano' and t.created_at > c.retomada_passo_em)
       and (c.retomada_ligacao_em is null or c.retomada_ligacao_em < c.retomada_passo_em)   -- 0315: ligação registrada tira a linha
    union all
    -- (r) 0379: agenda de retornos — retorno combinado com o time chegou (15 min antes) ou passou da hora sem contato
    select 'retorno_agora', r.id::text, r.conversa_id, r.venda_id, n.nome, r.quando, case when r.situacao = 'perdido' then 1 else 2 end,
           format('%s retorno combinado para %s às %s%s — %s',
                  case when r.situacao = 'perdido' then '⏰ ATRASADO:' else '🔔' end,
                  to_char(r.quando at time zone 'America/Sao_Paulo', 'DD/MM'), to_char(r.quando at time zone 'America/Sao_Paulo', 'HH24:MI'),
                  coalesce(' («' || left(r.combinado, 100) || '»)', ''),
                  case when r.situacao = 'perdido' then 'chame o cliente agora e marque Feito' else 'chame o cliente na hora e marque Feito' end)
      from public.v_retornos r
      join nomes n on n.id = r.conversa_id
     where r.estado = 'marcado' and r.quem_agora = 'time' and r.situacao in ('agora', 'perdido')
       and r.quando > now() - interval '3 days' and not n.nao_contatar
    union all
    -- (s) 0379: o cliente pediu retorno numa conversa com o time — sugestão do detector (confirmar ou descartar)
    select 'retorno_sugerido', r.id::text, r.conversa_id, r.venda_id, n.nome, r.criado_em, 2,
           format('O cliente pediu retorno: «%s» — marcar para %s%s?', left(coalesce(r.combinado, '?'), 120),
                  to_char(r.quando at time zone 'America/Sao_Paulo', 'DD/MM'),
                  case when r.tem_hora then ' às ' || to_char(r.quando at time zone 'America/Sao_Paulo', 'HH24:MI') else ' (sem hora: 9h)' end)
      from public.retornos r
      join nomes n on n.id = r.conversa_id
     where r.estado = 'sugerido' and r.quando > now() and r.criado_em > now() - interval '3 days' and not n.nao_contatar
    union all
    -- (m) 0210: o robô do GED360 está barrado (2+ leituras seguidas com erro) — sem ele ninguém fica sabendo da biometria
    select 'ged360_barrado', 'ged360', null::uuid, null::uuid, 'Robô do GED360', g.desde, 1,
           case when g.erro ilike '%simult%'
                then format('O robô do GED360 não lê desde %s: alguém entrou no GED360 com o login do robô ("logins simultâneos"). Saia do GED360 e use "⟳ Consultar no GED360" na ficha — sem o robô, biometria aprovada não avisa ninguém',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'HH24:MI'))
                else format('O robô do GED360 não lê desde %s (%s leituras com erro: %s) — biometria aprovada não avisa ninguém até voltar',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), g.n, left(g.erro, 120)) end
      from (select (select min(l.lida_em) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as desde,
                   (select count(*) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as n,
                   (select l.erro from public.ged360_leituras l order by l.lida_em desc limit 1) as erro,
                   (select l.ok from public.ged360_leituras l order by l.lida_em desc limit 1) as ultima_ok) g
     where g.ultima_ok = false and g.n >= 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;

-- ───────────────────────── (9) conferência: item 36 ─────────────────────────
do $m$
declare
  d text := pg_get_functiondef('public.conferencia_itens(text)'::regprocedure);
  fim text := E'\n  return it;\nend';
  item text := $x$
  -- 36. 0379 — agenda de retornos: retorno combinado com o cliente que passou da hora sem contato (48 h)
  select count(*)::int into n from public.v_retornos where situacao = 'perdido' and quando > now() - interval '48 hours';
  it := it || jsonb_build_object('codigo', 'retornos_perdidos', 'nome', 'Retornos combinados com o cliente',
    'nivel', case when n > 0 then 'atencao' else 'ok' end, 'n', n,
    'texto', case when n = 0 then 'nenhum retorno combinado passou da hora sem contato (48 h)'
                  else format('%s retorno(s) combinado(s) passaram da hora sem ninguém falar com o cliente (48 h)', n) end,
    'fazer', case when n > 0 then 'Live › Conferir › ⏰ retorno ATRASADO: chame o cliente e marque Feito (ou Descartar, com o motivo).' end);
$x$;
begin
  if position('retornos_perdidos' in d) > 0 then
    raise notice '0379: o item retornos_perdidos já existe — nada a fazer';
    return;
  end if;
  if (length(d) - length(replace(d, fim, ''))) / length(fim) <> 1 then
    raise exception '0379: não achei um único "return it;" no fim de conferencia_itens — refazer a migration a partir da versão no ar';
  end if;
  execute replace(d, fim, item || fim);
end $m$;


do $chk$
declare q jsonb;
begin
  q := public._retorno_ler_quando('pode me ligar amanhã às 15h?', (current_date::text || ' 10:00')::timestamp at time zone 'America/Sao_Paulo');
  if q is null or to_char((q ->> 'quando')::timestamptz at time zone 'America/Sao_Paulo', 'HH24:MI') <> '15:00' then
    raise exception '0379: leitor não entendeu "amanhã às 15h" (%)', q;
  end if;
  if public._retorno_ler_quando('vou pensar e depois te falo', now()) is not null then raise exception '0379: leitor viu retorno onde não há'; end if;
  if position('0379' in pg_get_functiondef('public.mari_cadencia_avaliar'::regproc)) = 0 then raise exception '0379: cadência não trocou'; end if;
  if position('retorno_agora' in pg_get_functiondef('public.live_conferir'::regproc)) = 0 then raise exception '0379: live_conferir não trocou'; end if;
  if position('retornos_perdidos' in pg_get_functiondef('public.conferencia_itens(text)'::regprocedure)) = 0 then raise exception '0379: conferência sem o item'; end if;
end $chk$;

commit;
