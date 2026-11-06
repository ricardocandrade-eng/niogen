-- NIOGEN | supabase/migrations/0044_parceiro_ajustes_revisao.sql | 06/11/2026 — Claude Code (prompt nº 24)
-- Ajustes da revisão de 06/11 ao commit 48807e3 (migrations 0035–0043, já aplicadas — não editadas).
--  1. vendas_antes_conferencia: venda de parceiro não muda de origem/parceiro por edição (a trava só olhava new.origem).
--  2. A venda de parceiro nasce SEMPRE com a conferência pendente (ignora o status que vier no INSERT).
--  3. parceiro_checar_endereco = critério do sistema (checar_duplicidade): CEP + número, sem complemento (decisão do
--     Ricardo, 06/11 14h40). Apto 101 em atendimento => apto 102 do mesmo CEP + número também.
--  4. apurar_premios_parceiros recusa degraus vazios (não marca o mês como apurado sem prêmio).
-- Grants e triggers das funções são preservados pelo CREATE OR REPLACE.

create or replace function public.vendas_antes_conferencia()
returns trigger language plpgsql set search_path = public as $$
declare
  par     public.parceiros%rowtype;
  v_horas int;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
begin
  -- Revisão 06/11 (0044): venda de parceiro não sai do programa por edição (limpar parceiro_id/origem pularia a conferência).
  if tg_op = 'UPDATE' and old.origem = 'parceiro_pap'
     and (new.origem is distinct from old.origem or new.parceiro_id is distinct from old.parceiro_id) then
    raise exception 'Origem e parceiro de uma venda de parceiro não mudam.' using errcode = 'P0001';
  end if;

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
    new.conferencia_status := 'pendente';   -- 0044: nasce sempre pendente; aprovar é UPDATE (deixa evento e carimbo)
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

create or replace function public.parceiro_checar_endereco(p_cep text, p_numero text, p_complemento text default null)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  cep_n text := regexp_replace(coalesce(p_cep, ''), '\D', '', 'g');
  num_n text := lower(btrim(coalesce(p_numero, '')));
begin
  if not (exists (select 1 from public.parceiros where auth_user_id = auth.uid() and status = 'ativo')
          or coalesce(public.meu_perfil(), '') in ('admin', 'backoffice')) then
    raise exception 'Acesso restrito a parceiros ativos.' using errcode = '42501';
  end if;
  if cep_n = '' or num_n = '' then
    raise exception 'Informe CEP e número.' using errcode = 'P0001';
  end if;

  -- Mesmo critério de checar_duplicidade (0001): status <> 'saida', mesmo CEP (só dígitos) e mesmo número, SEM olhar o
  -- complemento (decisão do Ricardo, 06/11 14h40). p_complemento fica na assinatura só para a página da etapa 3 não mudar.
  -- Não chama checar_duplicidade: ela devolve nada quando meu_perfil() é nulo, que é o caso do parceiro.
  if exists (
    select 1 from public.vendas v
     where v.status <> 'saida'
       and regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = cep_n
       and lower(btrim(coalesce(v.numero, ''))) = num_n
  ) then
    return 'em_atendimento';
  end if;
  return 'livre';
end;
$$;

create or replace function public.apurar_premios_parceiros(p_competencia date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m        date := date_trunc('month', p_competencia)::date;
  cfg      public.config_parceiros%rowtype;
  r        record;
  deg      record;
  venc     date;
  n        int;
  n_parc   int := 0;
  n_premio int := 0;
  detalhe  jsonb := '[]'::jsonb;
begin
  if coalesce(auth.role(), '') <> 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só o serviço ou admin/backoffice apuram prêmios.' using errcode = '42501';
  end if;
  if (m + interval '1 month') > (now() at time zone 'America/Sao_Paulo') then
    raise exception 'A competência % ainda não terminou.', to_char(m, 'MM/YYYY') using errcode = 'P0001';
  end if;

  select * into cfg from public.config_parceiros;
  -- 0044: sem degraus configurados a apuração não roda — senão o mês ficaria marcado como apurado sem prêmio
  -- e os pontos tardios iriam para o mês seguinte.
  if not exists (select 1 from jsonb_array_elements(cfg.degraus) e where (e ->> 'premio')::numeric > 0) then
    raise exception 'Degraus do programa não configurados: apuração não roda.' using errcode = 'P0001';
  end if;
  venc := ((m + interval '1 month')::date) + (cfg.dia_apuracao - 1);

  for r in
    select parceiro_id, sum(pontos) as pontos
      from public.pontos_lancamentos
     where competencia = m
     group by parceiro_id
    having sum(pontos) > 0
  loop
    n_parc := n_parc + 1;
    select (e ->> 'pontos')::numeric as pontos, (e ->> 'premio')::numeric as premio into deg
      from jsonb_array_elements(cfg.degraus) e
     where (e ->> 'pontos')::numeric <= r.pontos
     order by (e ->> 'pontos')::numeric desc
     limit 1;
    if found and coalesce(deg.premio, 0) > 0 then
      insert into public.parceiro_pagamentos (parceiro_id, tipo, competencia, valor, vence_em, obs)
      values (r.parceiro_id, 'premio_degrau', m, deg.premio, venc,
              'Degrau de ' || deg.pontos::text || ' pontos (' || r.pontos::text || ' no mês)')
      on conflict do nothing;
      get diagnostics n = row_count;
      n_premio := n_premio + n;
      detalhe := detalhe || jsonb_build_object('parceiro_id', r.parceiro_id, 'pontos', r.pontos,
                                               'degrau', deg.pontos, 'premio', deg.premio, 'novo', n = 1);
    end if;
  end loop;

  insert into public.parceiro_apuracoes (competencia, resumo)
  values (m, jsonb_build_object('parceiros_com_pontos', n_parc, 'premios_novos', n_premio))
  on conflict (competencia) do nothing;

  return jsonb_build_object('competencia', m, 'parceiros_com_pontos', n_parc, 'premios_novos', n_premio,
                            'vence_em', venc, 'detalhe', detalhe);
end;
$$;
