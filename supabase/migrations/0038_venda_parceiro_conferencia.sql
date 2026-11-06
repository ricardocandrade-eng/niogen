-- NIOGEN | supabase/migrations/0038_venda_parceiro_conferencia.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- Venda de parceiro: nova origem `parceiro_pap`, `parceiro_id` e a CONFERÊNCIA DE QUALIDADE (a Dharma liga, confirma
-- dados e checa fraude antes de ativar). Trava no banco: origem parceiro_pap só passa de 0 → 1 com conferência aprovada.
-- Nenhuma outra origem muda. Caminho único: depois de aprovada, a venda segue as mesmas travas de qualquer canal.
--
-- Decisões de implementação:
--  * A trava é um trigger PRÓPRIO (vendas_antes_conferencia), não uma edição de vendas_antes_status: aquela função foi
--    redefinida em 0009/0011/0023 e outra migration pode redefini-la de novo e apagar a trava sem ninguém perceber.
--    Por ordem alfabética roda antes de vendas_antes_status (a conferência é o 1º pré-requisito).
--  * Reprovar NÃO move a venda para Saída sozinho (a tela da etapa 2 decide); enquanto estiver em Qualificado,
--    o endereço continua "em atendimento" para a checagem de duplicidade.
--  * A tentativa de contato da conferência é registrada em contatos_cliente (já vira evento da venda e conta no
--    teto 2/dia · 15/mês); a função parceiro_conferencia_tentativa aplica horário e teto antes de gravar.

-- ─────────────────────── origem nova (preserva as 8 que já existem) ───────────────────────
alter table public.vendas drop constraint if exists vendas_origem_check;
alter table public.vendas add constraint vendas_origem_check
  check (origem in ('meta_ads', 'instagram', 'facebook', 'fila_vero', 'rua', 'indicacao', 'site', 'outro', 'parceiro_pap'));

-- ─────────────────────── colunas ───────────────────────
alter table public.vendas
  add column if not exists parceiro_id            uuid references public.parceiros (id),
  add column if not exists conferencia_status     text,
  add column if not exists conferencia_motivo     text,
  add column if not exists conferencia_obs        text,
  add column if not exists conferencia_em         timestamptz,
  add column if not exists conferencia_por        uuid references public.usuarios (id),
  add column if not exists conferencia_prazo_ate  timestamptz;

alter table public.vendas drop constraint if exists vendas_conferencia_status_check;
alter table public.vendas add constraint vendas_conferencia_status_check
  check (conferencia_status in ('pendente', 'aprovada', 'reprovada', 'devolvida'));
alter table public.vendas drop constraint if exists vendas_conferencia_motivo_check;
alter table public.vendas add constraint vendas_conferencia_motivo_check
  check (conferencia_motivo in ('cliente_nao_confirmou', 'cliente_nao_atende', 'dados_divergentes', 'sem_cobertura',
                                'fora_da_area', 'ja_cliente_nio', 'ja_tem_pedido_nio', 'cancelou_30d', 'suspeita_fraude', 'outro'));
-- origem parceiro_pap <=> tem parceiro; conferência só existe em venda de parceiro.
alter table public.vendas drop constraint if exists vendas_parceiro_origem_check;
alter table public.vendas add constraint vendas_parceiro_origem_check
  check ((origem = 'parceiro_pap') = (parceiro_id is not null));
alter table public.vendas drop constraint if exists vendas_conferencia_so_parceiro_check;
alter table public.vendas add constraint vendas_conferencia_so_parceiro_check
  check (origem = 'parceiro_pap' or (conferencia_status is null and conferencia_motivo is null));
create index if not exists vendas_parceiro_idx on public.vendas (parceiro_id) where parceiro_id is not null;

comment on column public.vendas.parceiro_id is 'Parceiro PAP que fechou a venda (origem parceiro_pap). Nulo nas demais origens.';
comment on column public.vendas.conferencia_status is
  'Conferência de qualidade da Dharma (só parceiro_pap): pendente | aprovada | reprovada | devolvida (volta ao parceiro com motivo).';
comment on column public.vendas.conferencia_motivo is 'Lista fechada, visível ao parceiro (F4). Obrigatório em reprovada/devolvida.';
comment on column public.vendas.conferencia_obs is 'Observação INTERNA da conferência — nunca exposta ao parceiro.';
comment on column public.vendas.conferencia_prazo_ate is 'Prazo da conferência (config_parceiros.sla_conferencia_horas, em horário de contato do contrato).';

-- ─────────────────────── prazo em horas dentro do horário de contato ───────────────────────
create or replace function public.parceiro_prazo_conferencia(p_inicio timestamptz, p_horas numeric, p_cidade text default null)
returns timestamptz language plpgsql stable set search_path = public as $$
declare
  l         timestamp;
  restante  interval := make_interval(secs => p_horas * 3600);
  j         record;
  disp      interval;
  i         int;
begin
  l := public.mari_proximo_horario(p_inicio, p_cidade) at time zone 'America/Sao_Paulo';
  if l is null then
    return p_inicio + make_interval(secs => p_horas * 3600);
  end if;
  for i in 0..40 loop
    select * into j from public.mari_janela_dia(l::date, p_cidade);
    if j.abre is not null then
      l := greatest(l, j.abre);
      disp := j.fecha - l;
      if disp > interval '0' then
        if restante <= disp then
          return (l + restante) at time zone 'America/Sao_Paulo';
        end if;
        restante := restante - disp;
      end if;
    end if;
    l := (l::date + 1)::timestamp;
  end loop;
  return p_inicio + make_interval(secs => p_horas * 3600);
end;
$$;
revoke execute on function public.parceiro_prazo_conferencia(timestamptz, numeric, text) from public, anon;
grant execute on function public.parceiro_prazo_conferencia(timestamptz, numeric, text) to authenticated;

-- ─────────────────────── trava e carimbos ───────────────────────
create or replace function public.vendas_antes_conferencia()
returns trigger language plpgsql set search_path = public as $$
declare
  par     public.parceiros%rowtype;
  v_horas int;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
begin
  if new.origem is distinct from 'parceiro_pap' then
    return new;       -- nenhuma outra origem muda
  end if;

  if tg_op = 'UPDATE' then
    if old.origem is distinct from 'parceiro_pap' or new.parceiro_id is distinct from old.parceiro_id then
      raise exception 'Origem e parceiro de uma venda não mudam.' using errcode = 'P0001';
    end if;
  else
    select * into par from public.parceiros where id = new.parceiro_id;
    if not found or par.status <> 'ativo' then
      raise exception 'Parceiro sem aprovação ou fora do programa (suspenso/desligado): não pode enviar venda nova.' using errcode = 'P0001';
    end if;
    new.conferencia_status := coalesce(new.conferencia_status, 'pendente');
  end if;

  -- Trava 0 → 1: conferência aprovada (vale também para voltar de Saída ou inserir já vendida).
  if vendida and (tg_op = 'INSERT' or old.status in ('0_qualificado', 'saida'))
     and new.conferencia_status is distinct from 'aprovada' then
    raise exception 'Venda de parceiro bloqueada: a conferência de qualidade precisa estar aprovada antes de passar de Qualificado.'
      using errcode = 'P0001';
  end if;

  -- Mudança de conferência: motivo obrigatório ao reprovar/devolver; carimbo de quem e quando; prazo ao (re)abrir.
  if tg_op = 'INSERT' or new.conferencia_status is distinct from old.conferencia_status then
    if new.conferencia_status in ('reprovada', 'devolvida') and new.conferencia_motivo is null then
      raise exception 'Reprovar ou devolver a conferência exige um motivo da lista.' using errcode = 'P0001';
    end if;
    if new.conferencia_status in ('pendente', 'aprovada') then
      new.conferencia_motivo := null;
    end if;
    if new.conferencia_status = 'pendente' then
      select sla_conferencia_horas into v_horas from public.config_parceiros;
      new.conferencia_prazo_ate := public.parceiro_prazo_conferencia(now(), coalesce(v_horas, 2), new.cidade);
      new.conferencia_em  := null;
      new.conferencia_por := null;
    else
      new.conferencia_em  := now();
      new.conferencia_por := coalesce(auth.uid(), new.conferencia_por);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.vendas_antes_conferencia() from public, anon, authenticated;

drop trigger if exists vendas_antes_conferencia on public.vendas;
create trigger vendas_antes_conferencia
  before insert or update of origem, parceiro_id, status, conferencia_status, conferencia_motivo on public.vendas
  for each row execute function public.vendas_antes_conferencia();

-- Evento da linha do tempo a cada mudança de conferência.
create or replace function public.vendas_registra_conferencia()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.origem = 'parceiro_pap'
     and (tg_op = 'INSERT' or new.conferencia_status is distinct from old.conferencia_status) then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'conferencia', jsonb_strip_nulls(jsonb_build_object(
      'de', case when tg_op = 'UPDATE' then old.conferencia_status end,
      'para', new.conferencia_status, 'motivo', new.conferencia_motivo, 'obs', new.conferencia_obs,
      'parceiro_id', new.parceiro_id)), auth.uid());
  end if;
  return null;
end;
$$;
revoke execute on function public.vendas_registra_conferencia() from public, anon, authenticated;
drop trigger if exists vendas_registra_conferencia on public.vendas;
create trigger vendas_registra_conferencia
  after insert or update of conferencia_status on public.vendas
  for each row execute function public.vendas_registra_conferencia();

-- ─────────────────────── tentativa de contato da conferência ───────────────────────
-- Horário do contrato + teto 2/dia · 15/mês por telefone ANTES de gravar. Sem resposta N vezes (config) → devolvida.
create or replace function public.parceiro_conferencia_tentativa(
  p_venda uuid, p_canal text, p_atendeu boolean, p_resumo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v       public.vendas%rowtype;
  tel     text;
  n_hoje  int;
  n_mes   int;
  n_sem   int;
  desde   timestamptz;
  v_max   int;
  devolvida boolean := false;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice registram a conferência.' using errcode = '42501';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found or v.origem <> 'parceiro_pap' then
    raise exception 'Venda de parceiro não encontrada.' using errcode = 'P0001';
  end if;
  if v.conferencia_status <> 'pendente' then
    raise exception 'A conferência desta venda não está pendente (%).', v.conferencia_status using errcode = 'P0001';
  end if;
  if p_canal not in ('whatsapp', 'ligacao') then
    raise exception 'Canal da conferência: whatsapp ou ligacao.' using errcode = 'P0001';
  end if;
  if not public.mari_no_horario(now(), v.cidade) then
    raise exception 'Fora do horário de contato do contrato (seg–sex 9–21, sáb 10–16, nunca domingo/feriado).' using errcode = 'P0001';
  end if;
  tel := public.tel_norm(v.cliente_whatsapp);
  if tel is null then
    raise exception 'A venda não tem telefone do cliente.' using errcode = 'P0001';
  end if;
  select t.hoje, t.mes into n_hoje, n_mes from public.mari_toques(tel) t;
  if n_hoje >= 2 or n_mes >= 15 then
    raise exception 'Teto de contato do contrato atingido para este cliente (2 por dia · 15 por mês): hoje %, mês %.', n_hoje, n_mes
      using errcode = 'P0001';
  end if;

  insert into public.contatos_cliente (venda_id, canal, direcao, por, resumo, toque, tipo)
  values (p_venda, p_canal, 'saida', 'vendedor', p_resumo,
          case when p_atendeu then 'CONF_ATENDEU' else 'CONF_SEM_RESPOSTA' end, 'ativo');

  -- Só conta desde a última (re)abertura da conferência (depois de devolvida, o parceiro reenvia e recomeça).
  select coalesce(max(criado_em), v.criado_em) into desde from public.eventos_venda
   where venda_id = p_venda and tipo = 'conferencia' and detalhe ->> 'para' = 'pendente';
  select count(*) into n_sem from public.contatos_cliente
   where venda_id = p_venda and toque = 'CONF_SEM_RESPOSTA' and em >= desde;
  select conferencia_max_tentativas into v_max from public.config_parceiros;
  if not p_atendeu and n_sem >= coalesce(v_max, 3) then
    update public.vendas set conferencia_status = 'devolvida', conferencia_motivo = 'cliente_nao_atende',
           conferencia_obs = coalesce(conferencia_obs || E'\n', '') || n_sem || ' tentativas sem resposta.'
     where id = p_venda;
    devolvida := true;
  end if;
  return jsonb_build_object('sem_resposta', n_sem, 'max', coalesce(v_max, 3), 'devolvida', devolvida,
                            'contatos_hoje', n_hoje + 1, 'contatos_mes', n_mes + 1);
end;
$$;
revoke execute on function public.parceiro_conferencia_tentativa(uuid, text, boolean, text) from public, anon;
grant execute on function public.parceiro_conferencia_tentativa(uuid, text, boolean, text) to authenticated;
