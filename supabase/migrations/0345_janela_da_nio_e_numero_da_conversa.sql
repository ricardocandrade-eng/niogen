-- NIOGEN | supabase/migrations/0345_janela_da_nio_e_numero_da_conversa.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 21/11 ("Sim, corrige as duas"), da conferência do fluxo da L-217 (Jussara, Chatwoot 198, OS 12242686):
--  (1) HORÁRIO: a OS foi gravada pela ficha com o dia à mão e o período que o campo trazia pronto (13:00 = tarde). A Consulta OS
--      leu 08:00 às 12:00 quatro minutos depois, mas os_registrar_leitura só corrigia a agenda quando a DATA mudava — mesmo dia
--      com outra janela passava. No dia seguinte a cadência avisou "tarde, 13h às 17h" e a cliente estranhou ("Pedi de manhã").
--      Agora a janela da Nio (período de verdade, começo entre 6h e 18h) corrige horário e turno no mesmo dia; o dia inteiro
--      (00:00 às 23:59) não mexe. Com a venda ainda aguardando, o aviso de instalação sai pela cadência com o horário certo
--      (ela reavisa quando instalacao_avisada_para ≠ instalacao_agendada_para, como numa troca de data).
--  (2) NÚMERO: a venda criada pela Mari pegava o próximo número da sequência (default da coluna) em vez do da conversa — 3 de 3
--      vendas desde a 0296 (L-204/203, L-212/209, L-218/217). Agora a venda com origem_ref 'mari:<conversa>' nasce com o número
--      da conversa (gatilho BEFORE INSERT); venda sem conversa continua com número próprio da sequência.
--  Uma vez: as 3 vendas renumeradas e a L-217 com horário/turno da janela da Nio (08:00, manhã) — com os gatilhos de usuário
--  desligados (não é estado; nada de aviso nem projeção), com evento na linha do tempo da venda.
-- Recriada da versão no ar: os_registrar_leitura (md5 e25ecccd16e52acd5ccbf766985a8bc9) = produção.
-- Regra 20: (1) nenhum estado novo — horário e turno são dado da Nio (regra 4: OS → a Nio), a porta segue igual; (2) sem prazo
--     novo; (3) a correção é de função do banco, com evento (os_agendamento, de → para, turno) e origem; (4) fonte única: a janela
--     da Nio passa a vencer a nossa por inteiro; (5) conferência: sem item novo — toda leitura da Consulta OS corrige sozinha, e a
--     divergência que sobrar (venda já instalada) é histórico. Cenários X70 e X71. Tela: ficha (o período à mão deixa de vir
--     pronto). Live: sem mudança. Desempenho: sem impacto (mesma leitura; 1 select por venda nova).
begin;

CREATE OR REPLACE FUNCTION public.os_registrar_leitura(p_pedido text, p_origem text, p_dados jsonb, p_referencia_em timestamp with time zone DEFAULT NULL::timestamp with time zone, p_importacao_id uuid DEFAULT NULL::uuid, p_parceiro text DEFAULT 'dharma'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  m2          text[];        -- 0345: janela com começo e fim
  v_periodo   boolean;       -- 0345: a janela é um período de verdade (não o dia inteiro)
  v_turno     text;          -- 0345: manha | tarde, pela janela da Nio
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
    -- 0345 (caso L-217): a JANELA da Nio também vence. Mesmo dia com outro período (gravado "tarde" à mão, Nio 08:00 às 12:00)
    -- corrige o horário e o turno. Janela que não é período (00:00 às 23:59 = dia inteiro) não mexe no horário nem no turno.
    if f_data is not null and v.status in ('1_vendido', '2_aguardando_instalacao') then
      m := regexp_match(coalesce(f_janela, ''), '(\d{2}):(\d{2})');
      m2 := regexp_match(coalesce(f_janela, ''), '(\d{2}):(\d{2})\D+(\d{2}):(\d{2})');
      v_periodo := m2 is not null and m2[1]::int between 6 and 18 and m2[3]::int > m2[1]::int;
      v_turno := case when v_periodo then case when m2[1]::int < 12 then 'manha' else 'tarde' end end;
      v_quando := ((f_data::text || ' ' || coalesce(m[1] || ':' || m[2], '08:00'))::timestamp) at time zone 'America/Sao_Paulo';
      if v.instalacao_agendada_para is null
         or (v.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date <> f_data
         or (v_periodo and (v.instalacao_agendada_para <> v_quando or v.instalacao_turno is distinct from v_turno)) then
        update public.vendas set instalacao_agendada_para = v_quando, instalacao_turno = coalesce(v_turno, instalacao_turno) where id = v.id;
        insert into public.eventos_venda (venda_id, tipo, detalhe)
        values (v.id, 'os_agendamento', jsonb_strip_nulls(jsonb_build_object(
          'de', v.instalacao_agendada_para, 'para', v_quando, 'janela', f_janela, 'origem', p_origem, 'pedido', t,
          'turno_de', case when v_turno is distinct from v.instalacao_turno then v.instalacao_turno end,
          'turno_para', case when v_turno is distinct from v.instalacao_turno then v_turno end)));
        v_efeito := case when v.instalacao_agendada_para is null then 'agendamento gravado'
                         when (v.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date = f_data then 'período atualizado pela Nio'
                         else 'agendamento atualizado pela Nio' end;
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
$function$;

-- ───────────────────────── (2) a venda da Mari nasce com o número da conversa ─────────────────────────
create or replace function public._venda_numero_da_conversa() returns trigger
language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  if coalesce(new.origem_ref, '') ~ '^mari:[0-9a-f-]{36}$' then
    select c.lead_numero into n from public.mari_conversas c where c.id = substring(new.origem_ref from 6)::uuid;
    if n is not null then new.lead_numero := n; end if;
  end if;
  return new;
end $$;
drop trigger if exists vendas_numero_da_conversa on public.vendas;
create trigger vendas_numero_da_conversa before insert on public.vendas
  for each row execute function public._venda_numero_da_conversa();
comment on column public.vendas.lead_numero is '0296/0345: nº do lead. Venda da Mari = o da conversa (gatilho vendas_numero_da_conversa); sem conversa = número próprio da sequência.';

-- ───────────────────────── uma vez: os casos de hoje ─────────────────────────
alter table public.vendas disable trigger user;

-- as vendas da Mari com número diferente do da conversa
with alvo as (
  select v.id, v.lead_numero as de, c.lead_numero as para
    from public.vendas v join public.mari_conversas c on c.id = substring(v.origem_ref from 6)::uuid
   where coalesce(v.origem_ref, '') ~ '^mari:[0-9a-f-]{36}$' and v.lead_numero is distinct from c.lead_numero and c.lead_numero is not null),
upd as (update public.vendas v set lead_numero = a.para from alvo a where v.id = a.id returning v.id, a.de, a.para)
insert into public.eventos_venda (venda_id, tipo, detalhe)
select id, 'lead_numero', jsonb_build_object('de', de, 'para', para, 'origem', '0345 (o número da conversa)') from upd;

-- horário e turno da janela da Nio que ficaram para trás (mesmo dia, outro período) — hoje só a L-217, já instalada
with ult as (
  select distinct on (o.venda_id) o.venda_id, o.agendamento_data, o.janela,
         regexp_match(o.janela, '(\d{2}):(\d{2})\D+(\d{2}):(\d{2})') as m
    from public.os_leituras o where o.venda_id is not null and o.agendamento_data is not null and o.janela is not null
   order by o.venda_id, o.lido_em desc),
alvo as (
  select v.id, v.instalacao_agendada_para as de, v.instalacao_turno as turno_de, u.janela,
         ((u.agendamento_data::text || ' ' || u.m[1] || ':' || u.m[2])::timestamp at time zone 'America/Sao_Paulo') as para,
         case when u.m[1]::int < 12 then 'manha' else 'tarde' end as turno_para
    from public.vendas v join ult u on u.venda_id = v.id
   where u.m is not null and u.m[1]::int between 6 and 18 and u.m[3]::int > u.m[1]::int
     and v.instalacao_agendada_para is not null
     and (v.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date = u.agendamento_data),
alvo2 as (select * from alvo a where a.de <> a.para or a.turno_de is distinct from a.turno_para),
upd as (update public.vendas v set instalacao_agendada_para = a.para, instalacao_turno = a.turno_para from alvo2 a where v.id = a.id
        returning v.id, a.de, a.para, a.turno_de, a.turno_para, a.janela)
insert into public.eventos_venda (venda_id, tipo, detalhe)
select id, 'os_agendamento', jsonb_strip_nulls(jsonb_build_object('de', de, 'para', para, 'janela', janela, 'turno_de', turno_de,
       'turno_para', turno_para, 'origem', '0345 (janela da Nio, uma vez)')) from upd;

alter table public.vendas enable trigger user;

commit;
