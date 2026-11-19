-- NIOGEN | supabase/migrations/0319_parceiro_incentivos_liga_desliga.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 19/11/2026: "Pode mostrar nos dois [cadastro e app], mas eu quero que tenha um botão para eu ativar/desativar tudo isso,
-- porque eu não quero entrar com esses programas ainda" — "isso" = degraus de pontos (ajuda de custo), Garantia Bronze e largada.
-- O que muda:
--  (1) config_parceiros.incentivos_ativos (boolean, DESLIGADO). Admin liga/desliga em Configurações › Programa Parceiro.
--  (2) parceiro_resumo devolve 'incentivos' (o Pocket esconde pontos, nível, garantia e largada quando falso).
--  (3) parceiro_programa(): pública (anon) — o Pocket mostra "Como você ganha" no cadastro (#seja) e no app; com a chave
--      desligada, devolve só {incentivos:false} (nenhum valor de degrau/garantia/largada sai).
--  (4) apurar_premios_parceiros: com a chave desligada, não gera ajuda de custo nem garantia; grava a apuração do mês como
--      "incentivos desligados" (o mês fica fechado: ligar depois não paga mês passado).
-- Não muda: comissão por plano (paga sempre); pontos continuam sendo lançados (1 R$ = 1 ponto) — só não viram prêmio;
-- largada já lançada pelo admin continua abatendo (o admin só lança se quiser).
-- Regra 20: (1) nenhum estado de lead; (2) nada fica parado: a apuração desligada fecha o mês; (3) a chave é config do admin
-- (RLS de config_parceiros), não status; (4) fonte única: config_parceiros; (5) sem número novo. Desempenho: sem impacto.
begin;

alter table public.config_parceiros add column if not exists incentivos_ativos boolean not null default false;
comment on column public.config_parceiros.incentivos_ativos is
  'Liga/desliga degraus de pontos (ajuda de custo), garantia e largada no Pocket e na apuração. Desligado = só comissão por plano. Ricardo, 19/11/2026.';

-- (3) o que o parceiro (e quem ainda vai se cadastrar) pode ver das regras de ganho
create or replace function public.parceiro_programa()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when not c.incentivos_ativos then jsonb_build_object('incentivos', false)
    else jsonb_build_object(
      'incentivos', true,
      'degraus', (select coalesce(jsonb_agg(jsonb_build_object('nome', e ->> 'nome', 'pontos', (e ->> 'pontos')::numeric, 'premio', (e ->> 'premio')::numeric)
                                            order by (e ->> 'pontos')::numeric), '[]'::jsonb)
                    from jsonb_array_elements(coalesce(c.degraus, '[]'::jsonb)) e),
      'garantia', case when coalesce(c.garantia_meses, 0) > 0 and coalesce(c.garantia_piso, 0) > 0 then jsonb_build_object(
                    'gatilho', c.garantia_gatilho_pontos, 'meses', c.garantia_meses, 'minimo', c.garantia_min_pontos, 'piso', c.garantia_piso) end,
      'largada', case when coalesce(c.largada_valor_padrao, 0) > 0 then jsonb_build_object(
                    'valor', c.largada_valor_padrao, 'abatimento', c.largada_abatimento_padrao) end)
    end
  from public.config_parceiros c
$$;
comment on function public.parceiro_programa() is 'Regras de ganho do Programa Parceiro para o Pocket (cadastro e app). Desligado → só {incentivos:false}.';
revoke execute on function public.parceiro_programa() from public;
grant execute on function public.parceiro_programa() to anon, authenticated;

-- (2) e (4): só acréscimos de texto nas funções atuais (recriadas a partir da definição em produção)
do $$
declare
  def text;
  novo text;
begin
  def := pg_get_functiondef('public.parceiro_resumo()'::regprocedure);
  if (length(def) - length(replace(def, '''contato_whatsapp'',', ''))) / length('''contato_whatsapp'',') <> 1 then
    raise exception '0319: parceiro_resumo mudou (contato_whatsapp não é único)';
  end if;
  novo := replace(def, '''contato_whatsapp'',',
    '''incentivos'', coalesce((select c.incentivos_ativos from public.config_parceiros c), false),' || E'\n    ' || '''contato_whatsapp'',');
  execute novo;

  def := pg_get_functiondef('public.apurar_premios_parceiros(date)'::regprocedure);
  if position('  select * into cfg from public.config_parceiros;' in def) = 0 then
    raise exception '0319: apurar_premios_parceiros mudou (select da config não encontrado)';
  end if;
  novo := replace(def, '  select * into cfg from public.config_parceiros;',
'  select * into cfg from public.config_parceiros;
  -- 0319: incentivos desligados → nenhuma ajuda de custo nem garantia; o mês fica apurado assim (ligar depois não paga atrás).
  if not coalesce(cfg.incentivos_ativos, false) then
    insert into public.parceiro_apuracoes (competencia, resumo)
    values (m, jsonb_build_object(''parceiros_com_pontos'', 0, ''premios_novos'', 0, ''incentivos'', ''desligados''))
    on conflict (competencia) do nothing;
    return jsonb_build_object(''competencia'', m, ''parceiros_com_pontos'', 0, ''premios_novos'', 0, ''incentivos'', ''desligados'',
                              ''mensagem'', ''Incentivos desligados em Configurações › Programa Parceiro: nenhuma ajuda de custo gerada.'');
  end if;');
  execute novo;
end;
$$;

commit;
