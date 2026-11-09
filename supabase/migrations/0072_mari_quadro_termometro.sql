-- NIOGEN | supabase/migrations/0072_mari_quadro_termometro.sql | 09/11/2026 — Claude Code (docs/Prompt_mari_quadro_termometro_081126_2115.md)
-- Por quê: a tela Mari era uma lista com gaveta — não dava para ver de relance em que pé está cada conversa nem quanto falta
-- para virar venda. Agora ela ganha Lista | Quadro (colunas por etapa da Mari) e um TERMÔMETRO de dados por conversa.
-- O quê:
--   1. config_mari_colunas — colunas do Quadro e quais etapas do motor caem em cada uma (nada fixo no JS, regra 15).
--      Chaves do motor: as etapas de mari_conversas.etapa + 3 chaves derivadas pela view:
--      'handoff:dados_completos', 'humano' (handoff que não é dados completos, ou humano atribuído) e 'encerrada'.
--   2. config_mari_itens — itens do termômetro por segmento (fonte = caminho em mari_conversas; 'dados.x' = dados->>'x';
--      'a|b' = o primeiro preenchido; 'a&b' = os dois juntos) e a regra de "validado" (reaproveita mari_cpf_valido, dentro_area).
--   3. mari_cnpj_valido(text) — par do mari_cpf_valido para o segmento Empresas.
--   4. v_mari_quadro (security_invoker: mesma RLS de mari_conversas — admin/backoffice). Uma linha por conversa, SEM valor de
--      dado pessoal no termômetro (só vazio | coletado | validado por item).
--   5. mari_quadro_mover(conversa, destino, motivo) — os ÚNICOS dois arrastes do Quadro: 'humano' (assumir = o mesmo
--      mari_cadencia_parar(humano) que o sync do Chatwoot usa) e 'encerrada' (motivo da config; mari_cadencia_parar com
--      resolvida/nao_contatar + marca quadro_encerrada_*). A etapa da Mari NUNCA muda pela tela.
-- parceiro_id (regra 15) = o operador do NIOGEN ('dharma').

-- ───────────────────────── 0. marca de encerramento pelo Quadro ─────────────────────────
alter table public.mari_conversas
  add column if not exists quadro_encerrada_motivo text,
  add column if not exists quadro_encerrada_em     timestamptz,
  add column if not exists quadro_encerrada_por    uuid references public.usuarios (id);
comment on column public.mari_conversas.quadro_encerrada_em is
  '0072: conversa arrastada para Encerrada no Quadro da tela Mari. Se o cliente escrever depois, ela volta para a coluna da etapa.';

-- ───────────────────────── 1. colunas do Quadro ─────────────────────────
create table if not exists public.config_mari_colunas (
  codigo          text primary key,
  nome            text not null,
  descricao       text,
  ordem           int not null,
  etapas          text[] not null default '{}',
  cor             text not null default 'muted' check (cor in ('muted', 'info', 'warn', 'ok', 'bad')),
  recolhida       boolean not null default false,          -- faixa recolhida embaixo (como Saída em Vendas)
  aceita_arrastar boolean not null default false,          -- só Com humano e Encerrada
  motivos         jsonb,                                    -- Encerrada: [{codigo, nome, nao_contatar}]
  ativo           boolean not null default true,
  parceiro_id     text not null default 'dharma'
);
comment on table public.config_mari_colunas is 'Colunas do Quadro da tela Mari (0072). etapas = chaves do motor que caem na coluna.';

insert into public.config_mari_colunas (codigo, nome, descricao, ordem, etapas, cor, recolhida, aceita_arrastar, motivos) values
  ('novo',         'Novo',                'sem resposta ainda',                               10, '{abertura}',                 'muted', false, false, null),
  ('qualificando', 'Qualificando',        'CEP, cidade, já é cliente?',                       20, '{endereco,elegibilidade}',   'info',  false, false, null),
  ('planos',       'Planos apresentados', 'a Mari mostrou os planos',                         30, '{planos}',                   'info',  false, false, null),
  ('dados',        'Coletando dados',     'nome, CPF, endereço, pagamento…',                  40, '{coleta,resumo}',            'warn',  false, false, null),
  ('completo',     'Dados completos',     'handoff para o backoffice',                        50, '{handoff:dados_completos}',  'ok',    false, false, null),
  ('humano',       'Com humano',          'pediu humano, objeção, urgência ou alguém assumiu', 60, '{humano}',                   'bad',   false, true,  null),
  ('retomada',     'Em retomada',         'voltou depois do handoff / cadência',              70, '{retomada}',                 'muted', false, false, null),
  ('encerrada',    'Encerrada',           'venda · fora de área · já cliente · não contatar · perdida', 80, '{encerrada}', 'muted', true, true,
    '[{"codigo":"perdida","nome":"Perdida (sem interesse)","nao_contatar":false},
      {"codigo":"fora_area","nome":"Fora de área","nao_contatar":false},
      {"codigo":"ja_cliente","nome":"Já é cliente Nio","nao_contatar":false},
      {"codigo":"nao_contatar","nome":"Não contatar (pediu para não receber)","nao_contatar":true}]'::jsonb)
on conflict (codigo) do nothing;

alter table public.config_mari_colunas enable row level security;
drop policy if exists config_mari_colunas_ler on public.config_mari_colunas;
create policy config_mari_colunas_ler on public.config_mari_colunas for select to authenticated using (public.meu_perfil() is not null);
drop policy if exists config_mari_colunas_admin on public.config_mari_colunas;
create policy config_mari_colunas_admin on public.config_mari_colunas for all to authenticated
  using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
revoke all on public.config_mari_colunas from anon;
grant select, insert, update, delete on public.config_mari_colunas to authenticated;

-- ───────────────────────── 2. itens do termômetro ─────────────────────────
create table if not exists public.config_mari_itens (
  codigo          text primary key,
  nome            text not null,
  segmento        text not null check (segmento in ('varejo', 'empresas', 'ambos')),
  ordem           int not null,
  obrigatorio     boolean not null default true,
  fonte           text not null,
  regra_validado  text not null default 'nenhuma'
                  check (regra_validado in ('cpf_valido', 'cep_na_area', 'telefone_confirmado', 'cnpj_valido', 'nenhuma')),
  ativo           boolean not null default true,
  parceiro_id     text not null default 'dharma'
);
comment on table public.config_mari_itens is 'Itens do termômetro de dados da tela Mari (0072). fonte: coluna de mari_conversas, dados.x = dados->>x, a|b = o 1º preenchido, a&b = os dois.';

insert into public.config_mari_itens (codigo, nome, segmento, ordem, obrigatorio, fonte, regra_validado, ativo) values
  ('nome',       'Nome completo',                    'ambos',    10, true, 'dados.nome',                                'nenhuma',             true),
  ('cpf',        'CPF',                              'varejo',   20, true, 'dados.cpf',                                 'cpf_valido',          true),
  ('cnpj',       'CNPJ',                             'empresas', 20, true, 'dados.cnpj',                                'cnpj_valido',         true),
  ('mei',        'É MEI?',                           'empresas', 25, true, 'mei',                                       'nenhuma',             true),
  ('cep_numero', 'CEP + número',                     'ambos',    30, true, 'cep&numero',                                'cep_na_area',         true),
  ('referencia', 'Complemento / ponto de referência', 'ambos',   40, true, 'dados.referencia|complemento',              'nenhuma',             true),
  ('telefone',   'Telefone confirmado',              'ambos',    50, true, 'dados.telefone',                            'telefone_confirmado', true),
  ('email',      'E-mail',                           'ambos',    60, true, 'dados.email',                               'nenhuma',             true),
  ('plano',      'Plano',                            'ambos',    70, true, 'plano_escolhido',                           'nenhuma',             true),
  ('pagamento',  'Forma de pagamento',               'ambos',    80, true, 'forma_pagamento',                           'nenhuma',             true),
  ('periodo',    'Período preferido',                'ambos',    90, true, 'instalacao_preferencia|visita_preferencia', 'nenhuma',             true),
  ('nascimento', 'Data de nascimento',               'ambos',   100, true, 'dados.nascimento',                          'nenhuma',             false)
on conflict (codigo) do nothing;

alter table public.config_mari_itens enable row level security;
drop policy if exists config_mari_itens_ler on public.config_mari_itens;
create policy config_mari_itens_ler on public.config_mari_itens for select to authenticated using (public.meu_perfil() is not null);
drop policy if exists config_mari_itens_admin on public.config_mari_itens;
create policy config_mari_itens_admin on public.config_mari_itens for all to authenticated
  using (public.meu_perfil() = 'admin') with check (public.meu_perfil() = 'admin');
revoke all on public.config_mari_itens from anon;
grant select, insert, update, delete on public.config_mari_itens to authenticated;

-- ───────────────────────── 3. validações ─────────────────────────
create or replace function public.mari_cnpj_valido(p text)
returns boolean language plpgsql immutable set search_path = public as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  pesos1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  pesos2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s int; r int; i int;
begin
  if length(d) <> 14 or d ~ '^(\d)\1{13}$' then return false; end if;
  s := 0; for i in 1..12 loop s := s + substr(d, i, 1)::int * pesos1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> substr(d, 13, 1)::int then return false; end if;
  s := 0; for i in 1..13 loop s := s + substr(d, i, 1)::int * pesos2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = substr(d, 14, 1)::int;
end;
$$;

-- Valor de um item pela fonte da config (uso interno da view; o valor NUNCA sai da view).
create or replace function public._mari_item_valor(p_c jsonb, p_fonte text)
returns text language plpgsql immutable set search_path = public as $$
declare
  alt text; parte text; v text; acc text; ok boolean;
begin
  foreach alt in array string_to_array(coalesce(p_fonte, ''), '|') loop
    acc := null; ok := true;
    foreach parte in array string_to_array(btrim(alt), '&') loop
      parte := btrim(parte);
      v := case when parte like 'dados.%' then p_c -> 'dados' ->> substr(parte, 7) else p_c ->> parte end;
      v := nullif(btrim(coalesce(v, '')), '');
      if v is null then ok := false; exit; end if;
      acc := concat_ws(' ', acc, v);
    end loop;
    if ok and acc is not null then return acc; end if;
  end loop;
  return null;
end;
$$;

create or replace function public._mari_item_validado(p_regra text, p_valor text, p_c jsonb)
returns boolean language sql immutable set search_path = public as $$
  select case coalesce(p_regra, 'nenhuma')
    when 'nenhuma'             then p_valor is not null
    when 'cpf_valido'          then public.mari_cpf_valido(p_valor)
    when 'cnpj_valido'         then public.mari_cnpj_valido(p_valor)
    when 'cep_na_area'         then coalesce((p_c ->> 'dentro_area')::boolean, false)
    -- o motor só grava dados.telefone confirmado (o do WhatsApp, com o 9, ou o que o cliente confirmou)
    when 'telefone_confirmado' then length(regexp_replace(coalesce(p_valor, ''), '\D', '', 'g')) between 10 and 13
    else false end
$$;

-- ───────────────────────── 4. view do Quadro ─────────────────────────
create or replace view public.v_mari_quadro with (security_invoker = true) as
with base as (
  select c.*, to_jsonb(c) as j,
         v.status as venda_status, v.motivo_saida as venda_motivo_saida,
         (select max(t.created_at) from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano') as ult_humano
    from public.mari_conversas c
    left join public.vendas v on v.id = c.venda_id
),
ch as (
  select b.*,
    case
      when b.quadro_encerrada_em is not null
           and (b.ultima_msg_lead_at is null or b.ultima_msg_lead_at <= b.quadro_encerrada_em) then 'encerrada'
      when b.status in ('encerrado_humano', 'encerrado_ia') then 'encerrada'
      when b.nao_contatar then 'encerrada'
      when b.venda_status = 'saida' then 'encerrada'
      when b.status = 'handoff_realizado'
           and b.handoff_motivo in ('recusa_compra', 'sem_cobertura', 'fora_de_area', 'ja_cliente_nio', 'sem_contato') then 'encerrada'
      when b.status = 'handoff_realizado' and b.handoff_motivo = 'dados_completos' then 'handoff:dados_completos'
      when b.status = 'handoff_realizado' or b.humano_atribuido then 'humano'
      else coalesce(b.etapa, 'abertura')
    end as etapa_chave
  from base b
)
select
  ch.id,
  ch.created_at,
  ch.canal,
  (ch.canal = 'teste' or coalesce(ch.telefone, '') like '5500000000%') as teste,
  coalesce(nullif(btrim(ch.dados ->> 'nome'), ''), ch.nome_contato) as nome,
  ch.cidade,
  ch.cluster,
  coalesce(ch.segmento, 'varejo') as segmento,
  ch.origem,
  an.ad_nome, an.adset_nome, an.campanha_nome,
  ch.plano_escolhido,
  p.nome_curto as plano_nome,
  ch.status,
  ch.etapa,
  ch.etapa_chave,
  (select k.codigo from public.config_mari_colunas k
    where k.ativo and ch.etapa_chave = any (k.etapas) order by k.ordem limit 1) as coluna,
  case when ch.etapa_chave <> 'encerrada' then null
       when ch.quadro_encerrada_motivo is not null then ch.quadro_encerrada_motivo
       when ch.nao_contatar then 'nao_contatar'
       when ch.handoff_motivo = 'ja_cliente_nio' or ch.elegibilidade in ('ja_cliente', 'cancelou_30d') then 'ja_cliente'
       when ch.handoff_motivo in ('fora_de_area', 'sem_cobertura') or ch.dentro_area is false then 'fora_area'
       when ch.venda_id is not null and coalesce(ch.venda_status, '') <> 'saida' then 'venda'
       when ch.status = 'encerrado_humano' then 'zerada'
       else 'perdida' end as encerrada_motivo,
  ch.venda_motivo_saida,
  case when ch.etapa_chave <> 'encerrada' then null
       when ch.quadro_encerrada_motivo is not null then coalesce(
         (select m ->> 'nome' from public.config_mari_colunas k, jsonb_array_elements(coalesce(k.motivos, '[]'::jsonb)) m
           where k.codigo = 'encerrada' and m ->> 'codigo' = ch.quadro_encerrada_motivo limit 1), ch.quadro_encerrada_motivo)
       when ch.venda_status = 'saida' then 'Venda em Saída' || coalesce(' · ' || ch.venda_motivo_saida, '')
       when ch.nao_contatar then 'Não contatar'
       when ch.handoff_motivo = 'ja_cliente_nio' or ch.elegibilidade in ('ja_cliente', 'cancelou_30d') then 'Já é cliente Nio'
       when ch.handoff_motivo in ('fora_de_area', 'sem_cobertura') or ch.dentro_area is false then 'Fora de área'
       when ch.venda_id is not null then 'Venda criada'
       when ch.status = 'encerrado_humano' then 'Memória zerada (#zerar)'
       when ch.handoff_motivo = 'recusa_compra' then 'Perdida · recusou'
       when ch.handoff_motivo = 'sem_contato' then 'Perdida · sem contato'
       else 'Perdida' end as encerrada_txt,
  -- vez: de quem é a próxima fala
  case
    when ch.etapa_chave = 'encerrada' then null
    when ch.status = 'handoff_realizado' or ch.humano_atribuido then
      case when ch.ult_humano is not null and ch.ult_humano >= coalesce(ch.ultima_msg_lead_at, '-infinity'::timestamptz)
           then 'cliente' else 'humano' end
    when ch.ultima_msg_lead_at is not null and ch.ultima_msg_lead_at > coalesce(ch.ultima_msg_mari_at, '-infinity'::timestamptz) then 'mari'
    else 'cliente' end as vez,
  case
    when ch.status = 'handoff_realizado' or ch.humano_atribuido then greatest(ch.ultima_msg_lead_at, ch.handoff_em)
    else ch.ultima_msg_lead_at end as vez_desde,
  greatest(ch.ultima_msg_lead_at, ch.ultima_msg_mari_at, ch.ult_humano, ch.created_at) as ultima_em,
  case greatest(ch.ultima_msg_lead_at, ch.ultima_msg_mari_at, ch.ult_humano)
    when ch.ultima_msg_lead_at then 'cliente' when ch.ult_humano then 'humano' when ch.ultima_msg_mari_at then 'mari' end as ultima_quem,
  ch.ultima_msg_lead_at + interval '24 hours' as janela_24h_fecha_em,
  k.proximo_passo, k.proximo_em, k.pode_enviar, k.bloqueio,
  coalesce(k.toques_hoje, tq.hoje, 0) as contatos_hoje,
  coalesce(k.toques_mes,  tq.mes,  0) as contatos_mes,
  array_remove(array[
    case when ch.nao_contatar then 'nao_contatar' end,
    case when exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.papel = 'lead'
                       and t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)') then 'desconto' end,
    case when exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.papel = 'lead'
                       and t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)') then 'reclamacao_nio' end,
    case when exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.papel = 'lead'
                       and t.texto ~* '(n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))') then 'nao_pedi_contato' end,
    case when ch.handoff_motivo = 'urgencia_alta'
           or exists (select 1 from public.mari_turnos t where t.conversa_id = ch.id and t.tags ? 'sinal_urgencia') then 'urgencia' end
  ], null) as alertas,
  ch.venda_id,
  ch.venda_status,
  -- termômetro (só o estado de cada item — nunca o valor)
  coalesce(tm.itens_total, 0)     as itens_total,
  coalesce(tm.itens_coletados, 0) as itens_coletados,
  coalesce(tm.itens_validados, 0) as itens_validados,
  coalesce(tm.faltam, '{}')       as faltam,
  coalesce(tm.itens, '[]'::jsonb) as itens,
  tr.trava_cliente_nio, tr.trava_endereco_nio, tr.trava_viabilidade,
  ( coalesce(tm.itens_total, 0) > 0 and tm.itens_validados = tm.itens_total
    and tr.trava_cliente_nio = 'ok' and tr.trava_endereco_nio <> 'bloqueia' and tr.trava_viabilidade <> 'bloqueia'
    and ch.etapa_chave not in ('handoff:dados_completos', 'humano', 'encerrada') ) as pronto_handoff,
  ch.chatwoot_conversation_id,
  'dharma'::text as parceiro_id
from ch
left join public.config_planos p on p.codigo = ch.plano_escolhido
left join lateral (
  select a.ad_nome, a.adset_nome, a.campanha_nome from public.v_mari_conversa_anuncio a
   where a.conversa_id = ch.id order by a.referral_em desc nulls last limit 1
) an on true
left join public.v_mari_cadencia k on k.conversa_id = ch.id
left join lateral public.mari_toques(ch.telefone, now()) tq on true
left join lateral (
  select count(*) filter (where x.obrigatorio)                              as itens_total,
         count(*) filter (where x.obrigatorio and x.estado <> 'vazio')      as itens_coletados,
         count(*) filter (where x.obrigatorio and x.estado = 'validado')    as itens_validados,
         array_agg(x.nome order by x.ordem) filter (where x.obrigatorio and x.estado <> 'validado') as faltam,
         jsonb_agg(jsonb_build_object('codigo', x.codigo, 'nome', x.nome, 'estado', x.estado, 'obrigatorio', x.obrigatorio)
                   order by x.ordem) as itens
    from (
      select i.codigo, i.nome, i.ordem, i.obrigatorio,
             case when v.valor is null then 'vazio'
                  when public._mari_item_validado(i.regra_validado, v.valor, ch.j) then 'validado'
                  else 'coletado' end as estado
        from public.config_mari_itens i
        cross join lateral (select public._mari_item_valor(ch.j, i.fonte) as valor) v
       where i.ativo
         and i.segmento in ('ambos', case when ch.segmento = 'empresas' then 'empresas' else 'varejo' end)
    ) x
) tm on true
cross join lateral (
  select
    case when ch.elegibilidade in ('ja_cliente', 'cancelou_30d') or ch.handoff_motivo = 'ja_cliente_nio' then 'bloqueia'
         when ch.elegibilidade = 'ok' then 'ok' else 'pendente' end as trava_cliente_nio,
    case when ch.nio_viab_resultado = 'posse' or ch.dfv_resultado = 'endereco_ocupado' then 'bloqueia'
         when ch.nio_viab_resultado = 'viavel' or ch.dfv_resultado in ('viavel', 'viavel_predio') then 'ok' else 'pendente' end as trava_endereco_nio,
    case when ch.dentro_area is false or ch.handoff_motivo in ('fora_de_area', 'sem_cobertura') then 'bloqueia'
         when ch.nio_viab_resultado = 'viavel' or (ch.dentro_area and ch.dfv_resultado in ('viavel', 'viavel_predio')) then 'ok'
         else 'pendente' end as trava_viabilidade
) tr;

comment on view public.v_mari_quadro is
  '0072: uma linha por conversa da Mari para o Quadro/Lista da tela Mari — coluna (config_mari_colunas), vez, janela, cadência, '
  'alertas, termômetro (estado por item, sem valor) e travas do contrato. security_invoker: RLS de mari_conversas (admin/backoffice).';
revoke all on public.v_mari_quadro from anon;
grant select on public.v_mari_quadro to authenticated;

-- ───────────────────────── 5. os dois arrastes permitidos ─────────────────────────
create or replace function public.mari_quadro_mover(p_conversa uuid, p_destino text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c       public.mari_conversas;
  v_nome  text;
  v_col   public.config_mari_colunas;
  v_mot   jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin e backoffice mexem nas conversas da Mari.' using errcode = '42501';
  end if;
  select * into v_col from public.config_mari_colunas where codigo = p_destino and ativo;
  if not found or not v_col.aceita_arrastar then
    return jsonb_build_object('ok', false, 'erro', 'A etapa vem da Mari: só dá para arrastar para Com humano ou Encerrada.');
  end if;
  select * into c from public.mari_conversas where id = p_conversa;
  if not found then return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.'); end if;
  select nome into v_nome from public.usuarios where id = auth.uid();

  if p_destino = 'humano' then
    -- assumir = o mesmo caminho do takeover pelo Chatwoot (sync): humano atribuído para a cadência na hora.
    perform public.mari_cadencia_parar(p_conversa, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (p_conversa, 'sistema', '[assumida no NIOGEN por ' || coalesce(v_nome, '?') || ' — cadência parada]', false);
    return jsonb_build_object('ok', true, 'destino', 'humano', 'chatwoot_conversation_id', c.chatwoot_conversation_id);
  end if;

  -- encerrada: motivo da config
  select m into v_mot from jsonb_array_elements(coalesce(v_col.motivos, '[]'::jsonb)) m where m ->> 'codigo' = p_motivo;
  if v_mot is null then return jsonb_build_object('ok', false, 'erro', 'Escolha o motivo do encerramento.'); end if;
  perform public.mari_cadencia_parar(p_conversa, p_resolvida => true,
                                     p_nao_contatar => coalesce((v_mot ->> 'nao_contatar')::boolean, false));
  update public.mari_conversas
     set quadro_encerrada_motivo = p_motivo, quadro_encerrada_em = now(), quadro_encerrada_por = auth.uid(), processando_ate = null
   where id = p_conversa;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (p_conversa, 'sistema', '[encerrada no NIOGEN por ' || coalesce(v_nome, '?') || ' — ' || (v_mot ->> 'nome') || ']', false);
  return jsonb_build_object('ok', true, 'destino', 'encerrada', 'motivo', p_motivo,
                            'nao_contatar', coalesce((v_mot ->> 'nao_contatar')::boolean, false),
                            'chatwoot_conversation_id', c.chatwoot_conversation_id);
end;
$$;
revoke execute on function public.mari_quadro_mover(uuid, text, text) from public, anon;
grant execute on function public.mari_quadro_mover(uuid, text, text) to authenticated, service_role;
