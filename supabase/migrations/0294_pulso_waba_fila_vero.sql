-- NIOGEN | supabase/migrations/0294_pulso_waba_fila_vero.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "No Pulso da tela Live, inclua a qualidade da Waba (green) e caso o disparo da Fila Vero esteja em andamento,
-- mantenha a bolinha pulsando, pra eu saber que está sendo enviado."
-- O que nasce: pulso_extra(), só leitura, chamada pela faixa do Pulso (assets/pulso.js) em paralelo com pulso_operacao()
-- (que não muda — 340 linhas que não precisam ser recriadas para isso). Devolve:
--   waba      — a última leitura de waba_qualidade (fluxo n8n waba_qualidade): quality_rating, tier, status, lida_em.
--   fila_vero — ligada?, dentro do horário?, enviados hoje / ritmo do dia, último envio, a leitura do número do disparo
--               (config fila_vero_qualidade, gravada pela fila_vero_guarda) e "enviando": ligada, no horário e com envio
--               nos últimos 12 min (a rodada do n8n é de 5 em 5 min; 12 min = duas rodadas sem envio → para de pulsar).
-- Regra 20: (1) não toca lead; (2) sem estado novo; (3) não grava nada; (4) cada número vem da fonte que já existe
-- (waba_qualidade, config_regras e _fv_enviados_hoje — os mesmos da tela Fila Vero); (5) sem número novo, sem conferência nova.
-- Desempenho: 1 chamada a mais por minuto, em paralelo com a do Pulso (mesma rodada).

begin;

create or replace function public.pulso_extra()
returns jsonb language sql stable security definer set search_path = public as $$
  with w as (select quality_rating, messaging_limit_tier, status, lida_em
               from public.waba_qualidade order by lida_em desc nulls last limit 1),
       f as (select coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false) ativo,
                    public.fila_vero_dentro_horario() dentro,
                    (select max(ultimo_toque_em) from public.fila_vero) ult)
  select jsonb_build_object(
    'waba', (select to_jsonb(w) from w),
    'fila_vero', (select jsonb_build_object(
        'ativo', f.ativo,
        'dentro_horario', f.dentro,
        'hoje', public._fv_enviados_hoje(),
        'ritmo', coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100),
        'ultimo_envio_em', f.ult,
        'enviando', f.ativo and f.dentro and f.ult > now() - interval '12 minutes',
        'numero', public._fv_cfg('fila_vero_qualidade'))
      from f),
    'em', now())
  where public.meu_perfil() in ('admin', 'backoffice') or session_user <> 'authenticator';
$$;

revoke all on function public.pulso_extra() from public, anon;
grant execute on function public.pulso_extra() to authenticated, service_role;

commit;
