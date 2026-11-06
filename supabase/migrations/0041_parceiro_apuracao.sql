-- NIOGEN | supabase/migrations/0041_parceiro_apuracao.sql | 06/11/2026 — Claude Code (prompt nº 22, etapa 1)
-- Apuração mensal dos prêmios de degrau (dia 5) + checagem de endereço para a página do parceiro (F1).

-- ─────────────────────── apurar_premios_parceiros ───────────────────────
-- Para cada parceiro com pontos na competência: só o MAIOR degrau atingido gera `premio_degrau`, com vencimento no
-- dia `dia_apuracao` do mês seguinte. Idempotente (rodar 2× não duplica). Competência ainda em andamento é recusada.
-- Marca o mês em parceiro_apuracoes: pontos tardios (confirmados depois) passam a valer no mês da confirmação.
-- Quem chama: n8n (service role) no dia 5, ou admin/backoffice.
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
revoke execute on function public.apurar_premios_parceiros(date) from public, anon;
grant execute on function public.apurar_premios_parceiros(date) to authenticated, service_role;

-- ─────────────────────── parceiro_checar_endereco ───────────────────────
-- Para o formulário do parceiro (F1, primeiro registro válido vale). Devolve SÓ 'livre' ou 'em_atendimento' —
-- nunca dados de ninguém. Endereço igual = mesmo CEP e número, e complemento compatível (um deles vazio, ou iguais),
-- para um prédio inteiro não aparecer "em atendimento" por causa de um apartamento. Venda em Saída libera o endereço.
create or replace function public.parceiro_checar_endereco(p_cep text, p_numero text, p_complemento text default null)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  cep_n  text := regexp_replace(coalesce(p_cep, ''), '\D', '', 'g');
  num_n  text := lower(btrim(coalesce(p_numero, '')));
  comp_n text := regexp_replace(lower(coalesce(p_complemento, '')), '[^a-z0-9]', '', 'g');
begin
  if not (exists (select 1 from public.parceiros where auth_user_id = auth.uid() and status = 'ativo')
          or coalesce(public.meu_perfil(), '') in ('admin', 'backoffice')) then
    raise exception 'Acesso restrito a parceiros ativos.' using errcode = '42501';
  end if;
  if cep_n = '' or num_n = '' then
    raise exception 'Informe CEP e número.' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.vendas v
     where v.status <> 'saida'
       and regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = cep_n
       and lower(btrim(coalesce(v.numero, ''))) = num_n
       and (comp_n = ''
            or regexp_replace(lower(coalesce(v.complemento, '')), '[^a-z0-9]', '', 'g') in ('', comp_n))
  ) then
    return 'em_atendimento';
  end if;
  return 'livre';
end;
$$;
revoke execute on function public.parceiro_checar_endereco(text, text, text) from public, anon;
grant execute on function public.parceiro_checar_endereco(text, text, text) to authenticated;
