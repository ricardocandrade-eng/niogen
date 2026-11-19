-- NIOGEN | supabase/migrations/0307_projetor_sombra.sql | 19/11/2026 02h30 — Claude Code (Opus 5.5), tarefa agendada niogen-passo4-madrugada
-- Ricardo, 19/11 ~02h: "Sim, deixe assim: preparação e sombra de madrugada" (fase 2, passo 4 — docs/DIAGNOSTICO_fechamento_porta_181126_1503.md §6).
-- Passo 4 = "um projetor só": hoje 27 funções enfileiram ordens ao Chatwoot por _bo_enfileirar (e 10 gravam direto em chatwoot_acoes);
-- no fim do passo 4 todas pedem à porta (_porta_projetar), que decide pela SITUAÇÃO do lead. Esta migration liga o projetor único
-- EM SOMBRA, no mesmo padrão do passo 2 (0293/0294, lead_estado):
--  (1) projetor_sombra: para CADA ordem que entra na fila (chatwoot_acoes), uma linha com o que o projetor único faria com ela:
--        igual      → o projetor mandaria a mesma ordem (mensagem e nota passam sempre: são conteúdo, não estado)
--        a_mais     → a ordem não muda nada no Chatwoot (já está assim): o projetor não mandaria
--        contraria  → a ordem vai contra a situação do lead (ex.: abrir a conversa de quem está em Saída)
--        repetida   → a mesma ordem (tipo + conteúdo) já entrou na MESMA transação para a mesma conversa
--        agendada   → ordem para depois (executar_apos > 1 min): só se julga na hora em que sair (fica anotada)
--        falta      → linha sem ordem: no fim da transação a situação pede algo que nenhuma ordem pediu (resolver, tirar o dono,
--                     etiqueta) — o projetor mandaria
--        erro       → a sombra não conseguiu julgar (o erro fica na linha; a ordem de verdade segue normal)
--      A situação é a do fim da transação (_porta_situacao → v_lead_situacao); o Chatwoot "antes" é o espelho no instante da ordem.
--      Regras da situação: config_situacao.cw_status (aberta/resolvida/adiada) e .dono (nenhum/time/qualquer); etiquetas pela mesma
--      conta do _porta_projetar no ar (destino, handoff, suporte-nio, nao-contatar).
--  (2) v_projetor_sombra_divergencias (o que saiu × o que o projetor mandaria) e v_projetor_sombra_resumo (por dia, origem e veredito).
-- NADA muda no que é enviado: nenhuma função existente é recriada, a fila (chatwoot_acoes) continua igual e a sombra NUNCA grava
-- em chatwoot_acoes. Os dois gatilhos engolem qualquer erro (a ordem de verdade nunca cai por causa da sombra).
-- Funções no ar conferidas (md5 de pg_get_functiondef em 19/11 ~02h25): _bo_enfileirar 9e35bf8c…, _porta_ordem 4a96d161…,
-- _porta_projetar 0922bef7… — a migration para se alguma delas mudou (a conta de etiquetas é cópia da do _porta_projetar).
-- Regra 20: (1) nenhum estado novo de lead; (2) sem estado novo; (3) quem grava é só o gatilho da fila; (4) fonte única: a situação;
-- (5) conferência: v_projetor_sombra_divergencias + cenário X40. Item no Conferir do Painel/Live fica para depois (Live: debate antes).
-- Tela, guia do backoffice, n8n: sem impacto. Desempenho: 1 leitura da conversa por ordem + 1 da situação por conversa no fim da transação.
-- Volta: supabase/rascunhos/0307_projetor_sombra_VOLTA.sql.
begin;

do $$
declare m text;
begin
  select md5(pg_get_functiondef('public._porta_projetar(uuid,text,text,text,boolean)'::regprocedure)) into m;
  if m <> '0922bef741d73689e9bb89831066f905' then raise exception '0307: _porta_projetar mudou no ar (md5 %): refaça a conta de etiquetas', m; end if;
  select md5(pg_get_functiondef('public._bo_enfileirar(uuid,integer,text,uuid,mari_conversas,text,jsonb,timestamp with time zone,text,text)'::regprocedure)) into m;
  if m <> '9e35bf8c42683484619c926844cce9b9' then raise exception '0307: _bo_enfileirar mudou no ar (md5 %)', m; end if;
end $$;

-- ───────────────────────── 1. a tabela da sombra ─────────────────────────
create table if not exists public.projetor_sombra (
  id          bigserial primary key,
  parceiro_id text not null default 'dharma',
  tx          bigint not null,                  -- pg_current_xact_id(): as ordens da mesma transação
  acao_id     bigint,                           -- a ordem de verdade (chatwoot_acoes.id); nula na linha "falta"
  conversa_id uuid,
  momento     text,                             -- a origem da ordem (chatwoot_acoes.momento)
  tipo        text not null,
  payload     jsonb,
  executar_apos timestamptz,
  cw_antes    jsonb,                            -- o espelho do Chatwoot no instante da ordem: status, agente, time, etiquetas
  situacao    text,                             -- a situação do lead no fim da transação
  veredito    text not null default 'pendente'
              check (veredito in ('pendente', 'igual', 'a_mais', 'contraria', 'repetida', 'agendada', 'falta', 'erro')),
  motivo      text,
  mandaria    jsonb,                            -- na linha "falta": a ordem que o projetor mandaria
  em          timestamptz not null default now()
);
create index if not exists projetor_sombra_tx on public.projetor_sombra (tx, conversa_id);
create index if not exists projetor_sombra_em on public.projetor_sombra (em desc);
create index if not exists projetor_sombra_acao on public.projetor_sombra (acao_id);
comment on table public.projetor_sombra is
  '0307 (fase 2, passo 4, em sombra): para cada ordem que entra em chatwoot_acoes, o que o projetor único (pela situação) faria. '
  'Só o gatilho da fila grava. Não manda nada.';
alter table public.projetor_sombra enable row level security;
drop policy if exists projetor_sombra_ler on public.projetor_sombra;
create policy projetor_sombra_ler on public.projetor_sombra for select to authenticated using (true);
revoke insert, update, delete on public.projetor_sombra from anon, authenticated;

-- ───────────────────────── 2. as etiquetas que a situação pede (a conta do _porta_projetar no ar) ─────────────────────────
create or replace function public._projetor_etiquetas(c public.mari_conversas, s text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  todas jsonb; lab text; adds jsonb := '[]'::jsonb; rems jsonb := '[]'::jsonb; sil boolean; fim boolean;
begin
  fim := s in ('saida_pode_voltar', 'saida_definitiva', 'nao_contatar', 'cliente_nio');
  sil := coalesce(c.quadro_encerrada_motivo, '') = 'suporte_nio';
  select coalesce(jsonb_agg(etiqueta), '[]'::jsonb) into todas from public.config_funil
   where parceiro_id = 'dharma' and tipo = 'destino' and etiqueta is not null;
  if fim or s = 'instalada' then
    select etiqueta into lab from public.config_funil where parceiro_id = 'dharma' and tipo = 'destino' and codigo = c.funil_destino;
    if lab is not null then adds := adds || to_jsonb(lab); end if;
    if sil then adds := adds || '"suporte-nio"'::jsonb; end if;
    rems := (todas - coalesce(lab, '')) || case when fim then '["handoff-venda", "handoff-humano"]'::jsonb else '[]'::jsonb end;
  else
    rems := todas;
  end if;
  if not sil then rems := rems || '"suporte-nio"'::jsonb; end if;
  if coalesce(c.nao_contatar, false) then adds := adds || '"nao-contatar"'::jsonb;   -- a etiqueta segue a coluna (0273)
  else rems := rems || '"nao-contatar"'::jsonb; end if;
  return jsonb_build_object('add', adds, 'remove', rems);
end $$;

-- ───────────────────────── 3. anotar cada ordem (na hora) ─────────────────────────
create or replace function public._projetor_sombra_anotar()
returns trigger language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  begin
    select * into c from public.mari_conversas where id = new.conversa_id;
    insert into public.projetor_sombra (tx, acao_id, conversa_id, momento, tipo, payload, executar_apos, cw_antes)
    values (pg_current_xact_id()::text::bigint, new.id, new.conversa_id, new.momento, new.tipo, new.payload, new.executar_apos,
            jsonb_build_object('status', coalesce(c.chatwoot_status, 'open'), 'agente', c.chatwoot_agente, 'time', c.chatwoot_time,
                               'etiquetas', to_jsonb(coalesce(c.chatwoot_etiquetas, '{}'::text[]))));
  exception when others then
    null;   -- a sombra nunca derruba a ordem de verdade
  end;
  return null;
end $$;

drop trigger if exists zz_projetor_sombra on public.chatwoot_acoes;
create trigger zz_projetor_sombra after insert on public.chatwoot_acoes
  for each row execute function public._projetor_sombra_anotar();

-- ───────────────────────── 4. julgar no fim da transação ─────────────────────────
create or replace function public._projetor_sombra_julgar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas; s text; cs public.config_situacao; r public.projetor_sombra; e jsonb;
  st text; ag text; tm text; etq jsonb; v text; mot text; quero jsonb; antes jsonb; adds jsonb; rems jsonb; e2 record;
  tem_agendada_resolver boolean := false;
begin
  if not exists (select 1 from public.projetor_sombra p where p.tx = new.tx and p.conversa_id is not distinct from new.conversa_id
                  and p.veredito = 'pendente') then
    return null;   -- outra linha desta transação já julgou esta conversa
  end if;
  begin
    select * into c from public.mari_conversas where id = new.conversa_id;
    s := case when c.id is null then '(sem conversa)' else public._porta_situacao(c.id, null::uuid) end;
    select * into cs from public.config_situacao where codigo = s;
    e := case when c.id is null then '{"add":[],"remove":[]}'::jsonb else public._projetor_etiquetas(c, s) end;
    -- o Chatwoot no fim da transação: o espelho de agora + as ordens desta transação que ainda não saíram
    st := coalesce(c.chatwoot_status, 'open'); ag := c.chatwoot_agente; tm := c.chatwoot_time;
    etq := to_jsonb(coalesce(c.chatwoot_etiquetas, '{}'::text[]));

    for r in select * from public.projetor_sombra p where p.tx = new.tx and p.conversa_id is not distinct from new.conversa_id
               and p.veredito = 'pendente' order by p.id loop
      antes := coalesce(r.cw_antes, '{}'::jsonb); v := 'igual'; mot := null;
      if exists (select 1 from public.projetor_sombra p where p.tx = r.tx and p.conversa_id is not distinct from r.conversa_id
                   and p.id < r.id and p.acao_id is not null and p.tipo = r.tipo and p.payload = r.payload) then
        v := 'repetida'; mot := 'a mesma ordem já entrou nesta transação';
      elsif r.executar_apos > r.em + interval '1 minute' then
        v := 'agendada'; mot := 'sai às ' || to_char(r.executar_apos at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ': julgar na hora';
      elsif r.tipo = 'resolver' then
        if cs.cw_status is not null and not ((r.payload ->> 'status') = any (cs.cw_status)) then
          v := 'contraria'; mot := 'situação ' || s || ' pede ' || array_to_string(cs.cw_status, '/') || ', a ordem põe ' || (r.payload ->> 'status');
        elsif antes ->> 'status' = r.payload ->> 'status' then
          v := 'a_mais'; mot := 'o Chatwoot já estava ' || (r.payload ->> 'status');
        end if;
      elsif r.tipo = 'atribuir' then
        if cs.dono = 'nenhum' then v := 'contraria'; mot := 'situação ' || s || ' é sem dono, a ordem põe dono'; end if;
      elsif r.tipo = 'desatribuir' then
        if r.payload ? 'team_id' and cs.dono = 'time' and (r.payload ->> 'team_id') is null then
          v := 'contraria'; mot := 'situação ' || s || ' é com o time, a ordem tira o time';
        elsif (r.payload ? 'assignee_id' and antes ->> 'agente' is null) or (r.payload ? 'team_id' and antes ->> 'time' is null) then
          v := 'a_mais'; mot := 'já estava sem ' || case when r.payload ? 'team_id' then 'time' else 'pessoa' end;
        end if;
      elsif r.tipo = 'etiquetas' then
        adds := coalesce(r.payload -> 'add', '[]'::jsonb); rems := coalesce(r.payload -> 'remove', '[]'::jsonb);
        if exists (select 1 from jsonb_array_elements_text(adds) x where (e -> 'remove') ? x)
           or exists (select 1 from jsonb_array_elements_text(rems) x where (e -> 'add') ? x) then
          v := 'contraria'; mot := 'situação ' || s || ' pede etiquetas ' || e::text;
        elsif not exists (select 1 from jsonb_array_elements_text(adds) x where not (coalesce(antes -> 'etiquetas', '[]'::jsonb) ? x))
          and not exists (select 1 from jsonb_array_elements_text(rems) x where coalesce(antes -> 'etiquetas', '[]'::jsonb) ? x) then
          v := 'a_mais'; mot := 'as etiquetas já estavam assim';
        end if;
      end if;
      update public.projetor_sombra set veredito = v, motivo = mot, situacao = s where id = r.id;
    end loop;

    -- o Chatwoot depois das ordens que ainda não saíram (desta e de transações anteriores; a que saiu já está no espelho)
    for e2 in select a.tipo, a.payload, a.executar_apos from public.chatwoot_acoes a
               where a.conversa_id = c.id and a.status in ('pendente', 'executando') order by a.id loop
      if e2.executar_apos > now() + interval '1 minute' then
        if e2.tipo = 'resolver' then tem_agendada_resolver := true; end if;
        continue;
      end if;
      if e2.tipo = 'resolver' then st := coalesce(e2.payload ->> 'status', st);
      elsif e2.tipo = 'atribuir' then
        if e2.payload ? 'assignee_id' then ag := coalesce(e2.payload ->> 'assignee_id', ag); end if;
        if e2.payload ? 'team_id' then tm := coalesce(e2.payload ->> 'team_id', tm); end if;
      elsif e2.tipo = 'desatribuir' then
        if e2.payload ? 'assignee_id' then ag := null; end if;
        if e2.payload ? 'team_id' then tm := null; end if;
      elsif e2.tipo = 'etiquetas' then
        etq := (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (
                  select x from jsonb_array_elements_text(etq) x where not (coalesce(e2.payload -> 'remove', '[]'::jsonb) ? x)
                  union select x from jsonb_array_elements_text(coalesce(e2.payload -> 'add', '[]'::jsonb)) x) z);
      end if;
    end loop;

    -- o que a situação pede e nenhuma ordem pediu (o projetor mandaria) — só conversa de WhatsApp com Chatwoot, como no projetor
    if c.id is not null and coalesce(c.canal, '') = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
       and coalesce(c.telefone, '') not like '5500000000%' then
      if cs.cw_status is not null and not (st = any (cs.cw_status)) and not tem_agendada_resolver then
        quero := jsonb_build_object('status', cs.cw_status[1]);
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'resolver', null, s, 'falta', 'situação ' || s || ' pede ' || array_to_string(cs.cw_status, '/')
                || ', o Chatwoot fica ' || st, quero);
      end if;
      if cs.dono = 'nenhum' and (ag is not null or tm is not null) then
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'desatribuir', null, s, 'falta', 'situação ' || s || ' é sem dono, o Chatwoot fica com '
                || concat_ws(' e ', case when ag is not null then 'pessoa' end, case when tm is not null then 'time' end),
                jsonb_build_object('assignee_id', null, 'team_id', null));
      end if;
      quero := jsonb_build_object(
        'add', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(e -> 'add') x where not (etq ? x)),
        'remove', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(e -> 'remove') x where etq ? x));
      if jsonb_array_length(quero -> 'add') > 0 or jsonb_array_length(quero -> 'remove') > 0 then
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'etiquetas', null, s, 'falta', 'situação ' || s || ' pede outras etiquetas', quero);
      end if;
    end if;
  exception when others then
    update public.projetor_sombra set veredito = 'erro', motivo = left(sqlerrm, 300)
     where tx = new.tx and conversa_id is not distinct from new.conversa_id and veredito = 'pendente';
  end;
  return null;
exception when others then
  return null;   -- nunca derruba a transação de verdade
end $$;

drop trigger if exists projetor_sombra_julgar on public.projetor_sombra;
create constraint trigger projetor_sombra_julgar after insert on public.projetor_sombra
  deferrable initially deferred for each row when (new.veredito = 'pendente')
  execute function public._projetor_sombra_julgar();

-- ───────────────────────── 5. as leituras ─────────────────────────
create or replace view public.v_projetor_sombra_divergencias with (security_invoker = true) as
select p.id, p.em, p.tx, p.conversa_id, c.chatwoot_conversation_id, p.momento, p.tipo, p.veredito, p.situacao, p.motivo,
       coalesce(p.payload, p.mandaria) as ordem, p.acao_id
  from public.projetor_sombra p
  left join public.mari_conversas c on c.id = p.conversa_id
 where p.veredito in ('a_mais', 'contraria', 'repetida', 'falta', 'erro');
comment on view public.v_projetor_sombra_divergencias is
  '0307: o que saiu × o que o projetor único (pela situação) mandaria. a_mais/repetida = ordem que sobraria; contraria = vai contra a '
  'situação; falta = a situação pede e ninguém pediu; erro = a sombra não julgou.';

create or replace view public.v_projetor_sombra_resumo with (security_invoker = true) as
select (p.em at time zone 'America/Sao_Paulo')::date as dia, p.momento, p.tipo, p.veredito, count(*) as ordens,
       count(distinct p.conversa_id) as conversas
  from public.projetor_sombra p
 group by 1, 2, 3, 4;
comment on view public.v_projetor_sombra_resumo is '0307: a sombra do projetor por dia, origem, tipo e veredito.';

grant select on public.projetor_sombra, public.v_projetor_sombra_divergencias, public.v_projetor_sombra_resumo to authenticated;

commit;
