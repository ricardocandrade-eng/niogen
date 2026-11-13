-- NIOGEN | supabase/migrations/0157_saida_unica_2b.sql | 12/11/2026 — Claude Code (Fable 5.2)
-- Especificação: docs/Prompt_escada_unica_banco_121126_2210.md (Drive) · Plano: etapa 2, parte 2b. Continua aditiva.
-- O quê:
--   1. Saída única: lead_sair(conversa, venda, motivo, sub, volta, obs, cancelou_portal) e lead_reabrir(conversa, venda),
--      para conversa e para venda, com a lista única da config_lead. Os caminhos antigos seguem funcionando.
--   2. Saída com pedido ou OS aberta: grava a saída e deixa a linha "cancelar na Nio" na Live até alguém confirmar
--      (venda_cancelada_no_portal). Recompra = multa de R$ 500.
--   3. Quem sai por silêncio (D1): não há agendador no banco, então NÃO sai sozinho ainda — vira linha de um clique na Live
--      (config_regras.saida_silencio_dias = 15). Com pedido aberto, a linha pede "insistir ou cancelar na Nio". O automático
--      entra com a conferência diária (etapa 6).
--   4. Instalada que cancela depois: o OSAB grava vendas.cancelada_apos_instalar_em e o motivo; o status não volta.
--   5. funil_destino_de_motivo entende os nomes da lista única.
--   6. v_leads lê o motivo, o sub-motivo e a data de volta gravados pela saída única (+ 4 colunas no fim).
--   7. Retrato do Agente de Tráfego ganha a chave "escada"; as chaves antigas não mudam.

-- ───────────────────────── colunas ─────────────────────────
alter table public.mari_conversas
  add column if not exists saida_motivo   text,
  add column if not exists saida_sub      text,
  add column if not exists saida_volta_em date,
  add column if not exists saida_em       timestamptz;
alter table public.vendas
  add column if not exists saida_motivo   text,
  add column if not exists saida_sub      text,
  add column if not exists cancelada_apos_instalar_em     timestamptz,
  add column if not exists cancelada_apos_instalar_motivo text;
comment on column public.vendas.saida_motivo is 'Motivo de saída na lista única (config_lead tipo saida), gravado pela lead_sair. Outro caminho de saída zera. 0157.';
comment on column public.vendas.cancelada_apos_instalar_em is 'A Nio cancelou depois de instalar (OSAB). O status não volta; a trilha do dinheiro lê daqui. 0157.';

insert into public.config_regras (chave, valor, descricao) values
  ('saida_silencio_dias', '15'::jsonb,
   'Live › Conferir: lead qualificado em andamento sem fala do cliente há mais de N dias vira linha "retomar ou Saída · Sem resposta". 0157.')
on conflict (chave) do nothing;

-- O motivo da lista única só vale para a saída que o gravou: outro caminho de saída (OSAB, Mari, ficha antiga) zera.
create or replace function public._saida_limpa_venda()
returns trigger language plpgsql set search_path = public as $$
begin
  if (new.status is distinct from old.status or new.motivo_saida is distinct from old.motivo_saida)
     and new.saida_motivo is not distinct from old.saida_motivo then
    new.saida_motivo := null; new.saida_sub := null;
  end if;
  return new;
end;
$$;
drop trigger if exists vendas_saida_limpa on public.vendas;
create trigger vendas_saida_limpa before update on public.vendas for each row execute function public._saida_limpa_venda();

create or replace function public._saida_limpa_conversa()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.funil_destino is distinct from old.funil_destino and new.saida_em is not distinct from old.saida_em then
    new.saida_motivo := null; new.saida_sub := null; new.saida_volta_em := null; new.saida_em := null;
  end if;
  return new;
end;
$$;
-- nome depois de "mari_conversas_funil_antes" na ordem alfabética: roda com o destino já recalculado
drop trigger if exists mari_conversas_saida_limpa on public.mari_conversas;
create trigger mari_conversas_saida_limpa before update on public.mari_conversas for each row execute function public._saida_limpa_conversa();

-- ───────────────────────── 5. texto do motivo → destino antigo ─────────────────────────
create or replace function public.funil_destino_de_motivo(p_motivo text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_motivo is null or btrim(p_motivo) = '' then 'recusou'
    when lower(p_motivo) ~ 'biometria' then 'reprovado_biometria'
    when lower(p_motivo) ~ 'cr[eé]dito' then 'credito_negado'
    when lower(p_motivo) ~ '(cliente nio|pedido na nio|cancelou a nio)' then 'ja_cliente_nio'
    when lower(p_motivo) ~ '(fora d[ae] [aá]rea|cidade n[aã]o atendida)' then 'fora_area'              -- 0157: nomes da lista única
    when lower(p_motivo) ~ '(cobertura|fachada n[aã]o atendida)' then 'sem_cobertura'
    when lower(p_motivo) ~ '(sem contato|n[aã]o atende|sem resposta)' then 'sem_resposta'
    when lower(p_motivo) ~ '(duplic|teste)' then 'teste_duplicada'
    else 'recusou'   -- Recusou, Desistiu, Preço, Concorrente, Interesse futuro, Não contatar, Nio não instalou, Venda indevida ou fraude, outro
  end
$$;

-- ───────────────────────── 1 e 2. saída única ─────────────────────────
create or replace function public.lead_sair(p_conversa uuid, p_venda uuid, p_motivo text, p_sub text default null,
                                            p_volta date default null, p_obs text default null, p_cancelou_portal boolean default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  k       public.config_lead;
  c       public.mari_conversas;
  v       public.vendas;
  perfil  text := coalesce(public.meu_perfil(), '');
  sub     text := nullif(btrim(coalesce(p_sub, '')), '');
  antigo  text;
  aberto  boolean := false;
  feito   text[] := '{}';
begin
  if perfil not in ('admin', 'backoffice', 'vendedor') then raise exception 'Sem permissão.' using errcode = '42501'; end if;
  select * into k from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_motivo;
  if not found then raise exception 'Motivo de saída desconhecido: %', p_motivo; end if;
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa;
    if not found then raise exception 'Conversa não encontrada.'; end if;
  end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    if c.id is null then
      select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1;
    end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  if perfil = 'vendedor' and (v.id is null or auth.uid() not in (v.vendedor_id, v.criado_por)) then
    raise exception 'Vendedor só registra a saída da própria venda.' using errcode = '42501';
  end if;
  if p_motivo = 'recusou' and sub is null then raise exception 'Diga o porquê da recusa: preço, concorrente, momento, desistiu ou outro.'; end if;
  if p_volta is not null and p_volta <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data de volta precisa ser futura.'; end if;

  if v.id is not null then
    if v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
      raise exception 'Venda instalada não vai para Saída. Cancelamento depois de instalar vem do OSAB.';
    end if;
    aberto := nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null;
    if aberto and p_cancelou_portal is null then
      raise exception 'Esta venda tem pedido aberto na Nio. Diga se o pedido já foi cancelado no portal.';
    end if;
    update public.vendas
       set status = 'saida',
           motivo_saida = k.nome || coalesce(' · ' || sub, '') || coalesce(' — ' || nullif(btrim(p_obs), ''), ''),
           interesse_futuro_em = p_volta, saida_motivo = k.codigo, saida_sub = sub
     where id = v.id;
    feito := feito || ('Saída · ' || k.nome)::text;
    if aberto and p_cancelou_portal then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'cancelado_no_portal', jsonb_build_object('quando', 'na saída'), auth.uid());
      feito := feito || 'pedido cancelado no portal (confirmado)'::text;
    elsif aberto then
      feito := feito || 'falta cancelar o pedido na Nio — a linha fica na Live até confirmar'::text;
    end if;
  else
    -- conversa sem venda: passa pelo caminho de sempre (nota, etiqueta e resolve no Chatwoot)
    if p_motivo in ('reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude') then
      raise exception 'Esse motivo só vale para lead com venda.';
    end if;
    antigo := case p_motivo when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
                            when 'nao_contatar' then 'recusou' else p_motivo end;
    if p_motivo = 'nao_contatar' then perform public.conversa_nao_contatar(c.id, 'saída registrada no NIOGEN'); end if;
    perform public.backoffice_conversa_saida(c.id, antigo);
    feito := feito || ('Saída · ' || k.nome)::text;
  end if;

  if c.id is not null then
    update public.mari_conversas
       set saida_motivo = k.codigo, saida_sub = sub, saida_volta_em = p_volta, saida_em = now()
     where id = c.id;
  end if;
  if p_volta is not null then feito := feito || ('volta para a Live em ' || to_char(p_volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(p_cancelou_portal, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end;
$$;
revoke all on function public.lead_sair(uuid, uuid, text, text, date, text, boolean) from public, anon;
grant execute on function public.lead_sair(uuid, uuid, text, text, date, text, boolean) to authenticated;

create or replace function public.venda_cancelada_no_portal(p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  if not exists (select 1 from public.vendas where id = p_venda and status = 'saida') then raise exception 'A venda não está em Saída.'; end if;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'cancelado_no_portal', jsonb_build_object('quando', 'depois da saída'), auth.uid());
  return jsonb_build_object('ok', true, 'resumo', '✓ cancelamento no portal confirmado');
end;
$$;
revoke all on function public.venda_cancelada_no_portal(uuid) from public, anon;
grant execute on function public.venda_cancelada_no_portal(uuid) to authenticated;

create or replace function public.lead_reabrir(p_conversa uuid, p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas;
  v public.vendas;
  novo text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  if p_conversa is not null then select * into c from public.mari_conversas where id = p_conversa; end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if c.id is null then select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1; end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  if v.id is not null then
    if v.status <> 'saida' then raise exception 'A venda não está em Saída.'; end if;
    novo := case when nullif(btrim(v.nio_os), '') is null then '0_qualificado'
                 when v.instalacao_agendada_para is not null then '2_aguardando_instalacao' else '1_vendido' end;
    update public.vendas set status = novo, interesse_futuro_em = null where id = v.id;   -- as travas da venda (vendas_antes_status) valem
  end if;
  if c.id is not null then
    update public.mari_conversas
       set quadro_encerrada_motivo = null, quadro_encerrada_em = null, quadro_encerrada_por = null, funil_evento = 'reabrir'
     where id = c.id;
    if coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' and c.canal = 'whatsapp' then
      perform public._bo_enfileirar(gen_random_uuid(), 1, 'reabrir', c.venda_id, c, 'resolver', jsonb_build_object('status', 'open'));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'resumo', '✓ reaberto' || coalesce(' — venda de volta em ' || novo, ''));
end;
$$;
revoke all on function public.lead_reabrir(uuid, uuid) from public, anon;
grant execute on function public.lead_reabrir(uuid, uuid) to authenticated;

-- ───────────────────────── 4. OSAB ─────────────────────────
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
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
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
    v_concl  := r.situacao = 'Concluído' and r.venda_valida is true;
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

-- ───────────────────────── 6. v_leads ─────────────────────────
create or replace view public.v_leads with (security_invoker = true) as
with par as (
  select c.id as conversa_id, v.id as venda_id,
         row_number() over (partition by coalesce(v.id::text, c.id::text) order by c.ultima_msg_lead_at desc nulls last, c.created_at desc) as rn
    from (select * from public.mari_conversas where canal = 'whatsapp') c
    full join public.vendas v on v.id = c.venda_id
)
select
  coalesce(p.venda_id::text, 'c:' || p.conversa_id::text)                                             as lead_id,
  p.conversa_id, p.venda_id, 'dharma'::text                                                           as parceiro_id,
  coalesce(nullif(btrim(v.cliente_nome), ''), nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
  coalesce(c.telefone, v.cliente_whatsapp)                                                            as telefone,
  coalesce(nullif(btrim(v.cidade), ''), nullif(btrim(c.cidade), ''))                                  as cidade,
  coalesce(nullif(c.origem, ''), nullif(v.origem, ''))                                                as origem,
  coalesce(pl.nome_curto, pl.nome, nullif(c.plano_escolhido, ''))                                     as plano,
  v.valor_mensal, v.comissao_prevista,
  e.etapa, ce.ordem                                                                                   as etapa_ordem, ce.nome as etapa_nome,
  s.status, cs.nome                                                                                   as status_nome, cs.ajuda as status_ajuda,
  d.destino,
  case when d.destino <> 'em_andamento' then null
       when s.vez = 'mari' and (coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false)
                                or c.status = 'handoff_realizado' or c.chatwoot_agente is not null) then 'time'
       else s.vez end                                                                                 as vez,
  case when d.destino <> 'em_andamento' then null
       when s.status = 'aguardando_instalacao' then v.instalacao_agendada_para
       when s.base_em is not null and cs.prazo_horas is not null then s.base_em + make_interval(mins => (cs.prazo_horas * 60)::int)
       end                                                                                            as prazo_em,
  (d.destino = 'em_andamento' and s.status <> 'aguardando_instalacao' and s.base_em is not null and cs.prazo_horas is not null
     and s.base_em + make_interval(mins => (cs.prazo_horas * 60)::int) < now() and esp.motivo is null) as atrasado,
  (d.destino = 'em_andamento' and esp.motivo is not null)                                             as em_espera,
  esp.motivo as espera_motivo, esp.quem as espera_quem, esp.revisar_em as espera_revisar_em,
  case when d.destino = 'saida' then e.etapa end                                                      as etapa_parou,
  sm.saida_motivo, cm.nome as saida_nome, cm.ajuda as saida_ajuda,
  case when d.destino = 'saida' then coalesce(case when v.status = 'saida' then coalesce(v.saida_sub, nullif(btrim(v.motivo_saida), '')) end, c.saida_sub, c.funil_detalhe) end as saida_sub,
  case when d.destino = 'saida' then coalesce(v.interesse_futuro_em, c.saida_volta_em) end           as volta_em,
  coalesce(u.nome, c.chatwoot_agente, case when coalesce(c.time_atribuido, false) or coalesce(c.humano_atribuido, false) then 'time' end,
           case when d.destino = 'em_andamento' and c.id is not null then 'Mari' end)                 as dono,
  v.vendedor_id,
  coalesce(c.created_at, v.criado_em)                                                                 as criado_em,
  greatest(c.ultima_msg_lead_at, c.ultima_msg_mari_at, c.funil_destino_em, v.criado_em)               as ultima_em,
  c.funil_etapa as funil_etapa_antiga, c.funil_destino as funil_destino_antigo, v.status as venda_status,
  v.cancelada_apos_instalar_em, v.cancelada_apos_instalar_motivo,
  (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null) as tem_pedido_nio,
  c.ultima_msg_lead_at
from par p
left join public.mari_conversas c on c.id = p.conversa_id
left join public.vendas v on v.id = p.venda_id
left join public.config_planos pl on pl.id = v.plano_id
left join public.usuarios u on u.id = v.vendedor_id
-- sinais da venda
cross join lateral (select
    coalesce(v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme'), false) as instalada,
    coalesce(nullif(btrim(v.nio_os), '') is not null or v.status in ('1_vendido', '2_aguardando_instalacao'), false)       as tem_os,
    coalesce(v.credito_resultado in ('aprovado', 'so_cartao'), false) or coalesce(c.credito_resultado ~ '^(aprovado|cartao)', false) as credito_ok
  ) f
-- etapa: a mais alta entre o que a venda mostra e o que a conversa alcançou (só sobe)
cross join lateral (select case greatest(
      -- venda com conversa: quem diz se qualificou é a conversa (viável, não é cliente Nio, crédito não negado — regra da 0147)
      case when f.instalada then 6 when f.tem_os then 5 when v.id is not null and c.id is null then 4 else 0 end,
      case coalesce(c.funil_etapa, 'nova')
        when 'instalada' then 6 when 'agendada' then 5
        when 'qualificada' then 4 when 'pedido' then 4 when 'biometria' then 4
        when 'viu_planos' then 3
        when 'cep' then 2 when 'area_ok' then 2 when 'viavel' then 2
        else 1 end)
    when 6 then 'instalada' when 5 then 'instalacao' when 4 then 'qualificado' when 3 then 'pre_qualificado' when 2 then 'viabilidade' else 'atendimento' end as etapa
  ) e
-- destino: um só
cross join lateral (select case
    when c.funil_destino = 'teste_duplicada' then 'teste_duplicada'
    when f.instalada then 'instalada'
    when c.id is not null then case coalesce(c.funil_destino, 'em_andamento') when 'em_andamento' then 'em_andamento' when 'instalada' then 'instalada' else 'saida' end
    when v.status = 'saida' then 'saida'
    else 'em_andamento' end as destino
  ) d
-- status, a vez de partida e a hora em que o relógio começou
cross join lateral (select x.status, x.base_em, k.vez
    from (select
      case e.etapa
        when 'instalada' then 'instalada'
        when 'instalacao' then case when nullif(btrim(v.nio_pendencia_cod), '') is not null then 'pendencia_nio'
                                    when v.instalacao_agendada_para is null then 'agendar' else 'aguardando_instalacao' end
        when 'qualificado' then case when v.biometria_status = 'validada' then 'abrir_os'
                                     when v.biometria_status in ('pendente', 'com_risco') then 'aguarda_biometria'
                                     when f.credito_ok then 'fazer_pedido' else 'rodar_credito' end
        when 'pre_qualificado' then 'viu_planos'
        when 'viabilidade' then 'consultando_cep'
        else case when coalesce(c.funil_etapa, 'nova') = 'nova' then 'nova' else 'respondeu' end end as status,
      case e.etapa
        when 'instalacao' then case when nullif(btrim(v.nio_pendencia_cod), '') is not null then v.nio_osab_em
                                    when v.instalacao_agendada_para is null then greatest(v.biometria_validada_em, v.vendido_em, v.nio_os_em) end
        when 'qualificado' then case when v.biometria_status = 'validada' then v.biometria_validada_em
                                     when v.biometria_status in ('pendente', 'com_risco') then coalesce(v.biometria_link_enviado_em, v.credito_em)
                                     when f.credito_ok then coalesce(v.credito_em, c.credito_em, c.handoff_em)
                                     else coalesce(c.handoff_em, v.criado_em) end
        else case when c.status = 'handoff_realizado' then c.handoff_em end end as base_em) x
    left join public.config_lead k on k.parceiro_id = 'dharma' and k.tipo = 'status' and k.codigo = x.status
  ) s
-- em espera: atravessa a escada (pendência da venda ou ⏸ Aguardar da conversa)
left join lateral (
    select pe.motivo, pe.quem_destrava as quem, pe.revisar_em::timestamptz as revisar_em
      from public.venda_pendencias pe where pe.venda_id = v.id and pe.encerrada_em is null
    union all
    select coalesce(c.espera_motivo, 'aguardando'), 'cliente', c.espera_ate where c.espera_ate is not null and c.espera_ate > now()
    limit 1) esp on true
-- motivo de saída na lista única
cross join lateral (select case when d.destino = 'teste_duplicada' then 'teste_duplicada' when d.destino <> 'saida' then null
    when v.status = 'saida' and v.saida_motivo is not null then v.saida_motivo   -- 0157: o que a saída única gravou vale
    when c.saida_motivo is not null then c.saida_motivo
    when v.status = 'saida' and v.motivo_saida ilike 'Nio:%' then
      case when v.motivo_saida ~* '(indevida|errada|duplicad|j[aá] possui)' then 'venda_indevida_fraude'
           when v.motivo_saida ~* '(desist|concorr)' then 'recusou' else 'nio_nao_instalou' end
    when v.status = 'saida' and v.motivo_saida ~* 'fraude' then 'venda_indevida_fraude'
    else case coalesce(c.funil_destino, public.funil_destino_de_motivo(v.motivo_saida))
           when 'fora_area' then 'cidade_nao_atendida'
           when 'sem_cobertura' then 'fachada_nao_atendida'
           when 'recusou' then case when coalesce(c.nao_contatar, false) and c.funil_detalhe = 'não contatar' then 'nao_contatar' else 'recusou' end
           when 'teste_duplicada' then 'teste_duplicada'
           else coalesce(c.funil_destino, public.funil_destino_de_motivo(v.motivo_saida)) end end as saida_motivo
  ) sm
left join public.config_lead ce on ce.parceiro_id = 'dharma' and ce.tipo = 'etapa'  and ce.codigo = e.etapa
left join public.config_lead cs on cs.parceiro_id = 'dharma' and cs.tipo = 'status' and cs.codigo = s.status
left join public.config_lead cm on cm.parceiro_id = 'dharma' and cm.tipo = 'saida'  and cm.codigo = sm.saida_motivo
where p.rn = 1;

-- ───────────────────────── 7. resumo da escada para o retrato ─────────────────────────
create or replace function public._leads_resumo(p_de date)
returns jsonb language sql stable security definer set search_path = public as $$
  with l as (select * from public.v_leads
              where destino <> 'teste_duplicada' and (criado_em at time zone 'America/Sao_Paulo')::date >= p_de)
  select jsonb_build_object(
    'leads', (select count(*) from l),
    'chegaram_ate', (select jsonb_object_agg(k.codigo, (select count(*) from l where l.etapa_ordem >= k.ordem) order by k.ordem)
                       from public.config_lead k where k.tipo = 'etapa' and k.parceiro_id = 'dharma'),
    'por_destino', (select jsonb_object_agg(destino, n) from (select destino, count(*) n from l group by 1) x),
    'em_andamento_por_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from l where destino = 'em_andamento' group by 1) x),
    'em_andamento_por_vez', (select jsonb_object_agg(vez, n) from (select coalesce(vez, 'sem_vez') vez, count(*) n from l where destino = 'em_andamento' group by 1) x),
    'saidas_por_motivo', (select jsonb_object_agg(m, n) from (select coalesce(saida_motivo, 'sem_motivo') m, count(*) n from l where destino = 'saida' group by 1) x),
    'saidas_por_etapa', (select jsonb_object_agg(etapa_parou, n) from (select etapa_parou, count(*) n from l where destino = 'saida' group by 1) x),
    'qualificados', (select count(*) from l where etapa_ordem >= 4 and coalesce(saida_motivo, '') not in ('ja_cliente_nio', 'credito_negado')),
    'vendas_os', (select count(*) from l where etapa_ordem >= 5),          -- D3: venda = OS gravada
    'instaladas', (select count(*) from l where etapa_ordem >= 6),
    'instaladas_liquidas', (select count(*) from l where etapa_ordem >= 6 and cancelada_apos_instalar_em is null))
$$;
revoke all on function public._leads_resumo(date) from public, anon, authenticated;
grant execute on function public._leads_resumo(date) to service_role;

CREATE OR REPLACE FUNCTION public.agente_trafego_retrato(p_dias integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

  with

  par as (

    select greatest(1, least(coalesce(p_dias, 14), 90)) as dias,

           (now() at time zone 'America/Sao_Paulo')::date as ate

  ),

  jan as (select dias, ate, ate - (dias - 1) as de from par),

  base as (select * from public._agente_trafego_base((select dias from jan))),

  -- funil em vários recortes de uma vez; g_* diz qual recorte é a linha

  f as (

    select grouping(b.dia) = 0 as g_dia, grouping(b.ad_id) = 0 as g_ad, grouping(b.conjunto_id) = 0 as g_conj,

           grouping(b.cidade) = 0 as g_cid, grouping(b.origem) = 0 as g_ori,

           b.dia, b.ad_id, b.conjunto_id, b.cidade, b.origem,

           jsonb_build_object(

             'conversas', count(*), 'responderam', count(*) filter (where b.respondeu),

             'cep_informado', count(*) filter (where b.cep_informado), 'cep_valido_area', count(*) filter (where b.cep_valido_area),

             'fora_area', count(*) filter (where b.fora_area), 'ja_cliente_nio', count(*) filter (where b.ja_cliente_nio),

             'sem_cobertura', count(*) filter (where b.sem_cobertura), 'qualificadas', count(*) filter (where b.qualificada),

             'qualificadas_reais', count(*) filter (where b.qualificada_real),

             'por_destino', public._agente_trafego_contar(array_agg(b.destino)),

             'por_etapa', public._agente_trafego_contar(array_agg(b.etapa)),

             'pedidos_abertos', count(*) filter (where b.pedido_aberto), 'biometria_aprovada', count(*) filter (where b.biometria_aprovada),

             'instaladas', count(*) filter (where b.instalada),

             'saidas', public._agente_trafego_contar(array_agg(b.saida)),

             'plano_escolhido', public._agente_trafego_contar(array_agg(b.plano)),

             'forma_pagamento', public._agente_trafego_contar(array_agg(b.forma_pagamento))) as funil

      from base b

     group by grouping sets ((), (b.dia), (b.ad_id), (b.conjunto_id), (b.cidade), (b.origem))

  ),

  -- gasto da Meta nos mesmos recortes (dia, anúncio, conjunto, total)

  m as (

    select grouping(d.dia) = 0 as g_dia, grouping(d.ad_id) = 0 as g_ad, grouping(d.adset_id) = 0 as g_conj,

           d.dia, d.ad_id, d.adset_id,

           round(sum(d.gasto), 2) as gasto, sum(d.impressoes)::int as impressoes, sum(d.cliques)::int as cliques,

           sum(d.conversas)::int as conversas_meta

      from public.meta_ads_diario d, jan

     where d.dia between jan.de and jan.ate

     group by grouping sets ((), (d.dia), (d.ad_id), (d.adset_id))

  ),

  zero as (

    select jsonb_build_object('conversas', 0, 'responderam', 0, 'cep_informado', 0, 'cep_valido_area', 0, 'fora_area', 0,

                              'ja_cliente_nio', 0, 'sem_cobertura', 0, 'qualificadas', 0, 'qualificadas_reais', 0,

                              'por_destino', '{}'::jsonb, 'por_etapa', '{}'::jsonb, 'pedidos_abertos', 0,

                              'biometria_aprovada', 0, 'instaladas', 0, 'saidas', '{}'::jsonb,

                              'plano_escolhido', '{}'::jsonb, 'forma_pagamento', '{}'::jsonb) as z

  ),

  mt as (  -- total da Meta (sempre 1 linha)

    select coalesce((select gasto from m where not (g_dia or g_ad or g_conj)), 0) as gasto,

           coalesce((select impressoes from m where not (g_dia or g_ad or g_conj)), 0) as impressoes,

           coalesce((select cliques from m where not (g_dia or g_ad or g_conj)), 0) as cliques,

           coalesce((select conversas_meta from m where not (g_dia or g_ad or g_conj)), 0) as conversas_meta

  ),

  ft as (select coalesce((select funil from f where not (g_dia or g_ad or g_conj or g_cid or g_ori)), (select z from zero)) as funil),

  fm as (select coalesce((select funil from f where g_ori and origem = 'meta_ads'), (select z from zero)) as funil)

  select jsonb_build_object(

    'gerado_em', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"'),

    'parceiro_id', 'dharma',

    'janela_dias', jan.dias, 'de', jan.de, 'ate', jan.ate,

    'meta_coletado_em', (select to_char(max(d.atualizado_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS"-03:00"')

                           from public.meta_ads_diario d where d.dia between jan.de and jan.ate),

    'atribuicao_desde', (select to_char(min(r.recebido_em) at time zone 'America/Sao_Paulo', 'YYYY-MM-DD')

                           from public.meta_referrals r where r.ad_id is not null),

    'legenda', jsonb_build_object(

      'conversas_meta', 'conversas iniciadas no WhatsApp contadas pela Meta (meta_ads_diario, janela de 7 d da Meta)',

      'conversas', 'conversas que chegaram na Mari pelo WhatsApp, pelo dia em que nasceram (canal e telefones de teste fora desde 12/11, 0147)',

      'responderam', 'cliente mandou 2 ou mais mensagens',

      'cep_valido_area', 'CEP informado e dentro da área de atuação',

      'fora_area', 'fora da área de atuação (CEP ou elegibilidade)',

      'sem_cobertura', 'destino sem_cobertura (portal ou operador sem viabilidade, Saída Sem cobertura); fora_area e ja_cliente_nio também são o destino único desde 0147',

      'qualificadas', 'LEGADO: Mari passou para o time com dados completos (handoff dados_completos), sem olhar viabilidade nem cliente Nio',

      'qualificadas_reais', 'USE ESTA: etapa qualificada ou além (dados completos + viável + não é cliente Nio + crédito não negado), sem já cliente ou crédito negado depois (0147)',

      'por_destino', 'destino único de cada conversa, soma = conversas: em_andamento, instalada, reprovado_biometria, credito_negado, ja_cliente_nio, fora_area, sem_cobertura, recusou, sem_resposta',

      'por_etapa', 'etapa mais alta alcançada: nova, respondeu, cep, area_ok, viavel, viu_planos, qualificada, pedido, biometria, agendada, instalada. sem cidade em por_cidade = quem ainda não deu o CEP',

      'pedidos_abertos', 'venda com pedido no portal Nio ou status vendido em diante',

      'biometria_aprovada', 'venda com biometria validada = a venda que decide (custo_por.venda); até 12/11 procurava aprovada e dava sempre 0',

      'saidas', 'destino de saída → contagem, uma por conversa (pedido_humano e multiplos_decisores não são saída)',

      'por_anuncio', 'funil só das conversas com referral do anúncio (ad_id); antes de atribuicao_desde nenhuma conversa tinha anúncio, então anúncio com gasto e 0 conversas aqui pode ser só falta de atribuição',

      'custo_por', 'gasto da Meta na janela ÷ conversas_meta; os demais ÷ marcos das conversas com origem meta_ads (atribuídas ou não)',

      'cobertura_resumo', 'conversas novas desde max(janela, 05/11) e quantas tiveram destino sem_cobertura; meta: pct_sem_cobertura < 10 até 19/11 (era 21 % em 12/11). dfv_base = data da base do DFV usada (0149)',

      'cobertura_por_cidade', 'as 35 cidades da C2 no DFV da Nio: fachadas_viaveis (logradouro + número distintos), domicilios_viaveis (HPs), bairros_com_fachada e os 10 bairros com mais fachadas com lat/lon média (centro para anunciar por raio); conversas e sem_cobertura = conversas novas da cidade no mesmo período do cobertura_resumo. Atualiza quando roda dfv/cobertura_cidades.py cidades',

      'sem_cobertura_por_bairro', 'conversas com destino sem_cobertura por cidade + bairro (bairro do ViaCEP; sem CEP, rua ou nome). dfv_tem_fachada_no_bairro: o DFV tem fachada viável com o mesmo nome de bairro (null = cidade fora das 35 medidas). distancia_fachada_viavel: do ponto do CEP (não do número) até a fachada viável mais próxima do DFV — ate_200m (perto: conferir a regra dos 200 m e o portal), 200m_a_1km, mais_1km (raio do anúncio está pegando gente longe da rede); sem_medida = ainda não calculado (roda dfv/cobertura_cidades.py distancias)',

      'privacidade', 'só contagens; sem nome, CPF, telefone, endereço, CEP ou rua (bairro só em sem_cobertura_por_bairro e top_bairros, que é dado do DFV)'),

    'totais', jsonb_build_object('gasto', mt.gasto, 'impressoes', mt.impressoes, 'cliques', mt.cliques,

                                 'conversas_meta', mt.conversas_meta,

                                 'conversas_atribuidas', (select count(*) from base where ad_id is not null),

                                 'conversas_teste_excluidas', (select count(*) from public.mari_conversas x

                                                                where x.canal = 'whatsapp' and x.funil_destino = 'teste_duplicada'

                                                                  and (x.created_at at time zone 'America/Sao_Paulo')::date >= jan.de)) || ft.funil,

    'custo_por', jsonb_build_object(

      'conversa', case when mt.conversas_meta > 0 then round(mt.gasto / mt.conversas_meta, 2) end,

      'cep_valido', case when (fm.funil ->> 'cep_valido_area')::int > 0 then round(mt.gasto / (fm.funil ->> 'cep_valido_area')::int, 2) end,

      'qualificada', case when (fm.funil ->> 'qualificadas')::int > 0 then round(mt.gasto / (fm.funil ->> 'qualificadas')::int, 2) end,

      'qualificada_real', case when (fm.funil ->> 'qualificadas_reais')::int > 0 then round(mt.gasto / (fm.funil ->> 'qualificadas_reais')::int, 2) end,

      'venda', case when (fm.funil ->> 'biometria_aprovada')::int > 0 then round(mt.gasto / (fm.funil ->> 'biometria_aprovada')::int, 2) end),

    'por_dia', coalesce((

      select jsonb_agg(jsonb_build_object('dia', k.dia, 'gasto', coalesce(md.gasto, 0), 'conversas_meta', coalesce(md.conversas_meta, 0))

                       || coalesce(fd.funil, (select z from zero)) order by k.dia)

        from (select dia from m where g_dia union select dia from f where g_dia) k

        left join m md on md.g_dia and md.dia = k.dia

        left join f fd on fd.g_dia and fd.dia = k.dia), '[]'::jsonb),

    'por_anuncio', coalesce((

      select jsonb_agg(jsonb_build_object('ad_id', k.ad_id, 'ad_nome', a.ad_nome, 'conjunto_id', a.adset_id, 'conjunto', a.adset_nome,

                                          'campanha', a.campanha_nome, 'status', a.status_efetivo,

                                          'gasto', coalesce(ma.gasto, 0), 'impressoes', coalesce(ma.impressoes, 0),

                                          'conversas_meta', coalesce(ma.conversas_meta, 0),

                                          'custo_cep_valido', case when (fa.funil ->> 'cep_valido_area')::int > 0

                                                                   then round(ma.gasto / (fa.funil ->> 'cep_valido_area')::int, 2) end,

                                          'custo_venda', case when (fa.funil ->> 'biometria_aprovada')::int > 0

                                                              then round(ma.gasto / (fa.funil ->> 'biometria_aprovada')::int, 2) end)

                       || coalesce(fa.funil, (select z from zero))

                       order by coalesce(ma.gasto, 0) desc, k.ad_id)

        from (select ad_id from m where g_ad and ad_id is not null union select ad_id from f where g_ad and ad_id is not null) k

        left join public.meta_ads_anuncios a on a.ad_id = k.ad_id

        left join m ma on ma.g_ad and ma.ad_id = k.ad_id

        left join f fa on fa.g_ad and fa.ad_id = k.ad_id), '[]'::jsonb),

    'por_conjunto', coalesce((

      select jsonb_agg(jsonb_build_object('conjunto_id', k.adset_id, 'conjunto', c.adset_nome, 'campanha', c.campanha_nome,

                                          'gasto', coalesce(mc.gasto, 0), 'conversas_meta', coalesce(mc.conversas_meta, 0),

                                          'custo_cep_valido', case when (fc.funil ->> 'cep_valido_area')::int > 0

                                                                   then round(mc.gasto / (fc.funil ->> 'cep_valido_area')::int, 2) end,

                                          'custo_venda', case when (fc.funil ->> 'biometria_aprovada')::int > 0

                                                              then round(mc.gasto / (fc.funil ->> 'biometria_aprovada')::int, 2) end)

                       || coalesce(fc.funil, (select z from zero))

                       order by coalesce(mc.gasto, 0) desc, k.adset_id)

        from (select adset_id from m where g_conj and adset_id is not null

              union select conjunto_id from f where g_conj and conjunto_id is not null) k

        left join lateral (select a.adset_nome, a.campanha_nome from public.meta_ads_anuncios a

                            where a.adset_id = k.adset_id order by a.atualizado_em desc limit 1) c on true

        left join m mc on mc.g_conj and mc.adset_id = k.adset_id

        left join f fc on fc.g_conj and fc.conjunto_id = k.adset_id), '[]'::jsonb),

    'por_cidade', coalesce((

      select jsonb_agg(jsonb_build_object('cidade', x.cidade) || x.funil order by (x.funil ->> 'conversas')::int desc, x.cidade)

        from f x where x.g_cid), '[]'::jsonb),

    'por_origem', coalesce((

      select jsonb_agg(jsonb_build_object('origem', x.origem) || x.funil order by (x.funil ->> 'conversas')::int desc, x.origem)

        from f x where x.g_ori), '[]'::jsonb)

  )

  || public._agente_trafego_cobertura(jan.de)   -- 0149
  || jsonb_build_object('escada', public._leads_resumo(jan.de))   -- 0157: a escada única (as chaves antigas seguem valendo)

  from jan, mt, ft, fm

$function$;

-- ───────────────────────── 2 e 3. Live › Conferir ─────────────────────────
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
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;
