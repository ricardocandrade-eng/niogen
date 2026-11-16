-- NIOGEN | supabase/migrations/0230_vigia_n8n.sql | 16/11/2026 12h40 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (16/11 ~12h30, "Sim, cria o alarme"), depois da queda da VPS do n8n (45.32.161.130) por falta de pagamento,
-- ~10h45–12h16: Mari, cadência, Live e o próprio Pulso pararam juntos e ninguém foi avisado (o Pulso roda na mesma VPS).
-- Mensagem de cliente que chega com o n8n fora se perde: o Chatwoot não reenvia webhook (#108 e #109 nesse dia).
--
-- O quê: um vigia FORA da VPS. O pg_cron do Supabase chama a cada 2 min a edge function `vigia-n8n`, que lê o /healthz do n8n
-- e grava a leitura aqui. Com N falhas seguidas, abre um episódio e a função manda, direto pela API da Meta (sem n8n), o template
-- `alerta_mari_silencio` (UTILITY, já aprovado) ao celular do Ricardo (config_regras.resumo_destino_whatsapp). Lembra a cada
-- `lembrete_min` enquanto não volta e avisa quando volta (com a hora da queda, para conferir as mensagens perdidas no Chatwoot).
--   1. config_regras.vigia_n8n {ligado, url, falhas_para_alarme, lembrete_min, timeout_ms}
--   2. vigia_n8n_leituras (cada leitura; guarda 7 dias) e vigia_n8n_quedas (um episódio por queda)
--   3. vigia_n8n_registrar(ok, http, ms, erro) — só service_role: grava a leitura, abre/fecha o episódio e devolve o aviso a mandar
--      (marcado na mesma transação: o aviso não sai duas vezes). vigia_n8n_aviso_erro(id, erro) guarda falha de envio.
--   4. pg_cron (extensão nova) + job `vigia_n8n` a cada 2 min → net.http_post para a edge function (deploy --no-verify-jwt: a função
--      só lê o /healthz; chamada a mais não gera aviso, porque o aviso só sai na troca de estado).
-- Regra 15: tabelas de infraestrutura (não de operação de venda) — sem parceiro_id; nada fixo no código (URL e limites em config).
-- Regra 20: estado (queda aberta/fechada) muda só por vigia_n8n_registrar, com a leitura como motivo; o vigia É a conferência do n8n.
--   Quem vigia o vigia: o pg_cron do próprio banco — se o Supabase cair, o NIOGEN inteiro cai e a tela mostra.
begin;

insert into public.config_regras (chave, valor, descricao) values
  ('vigia_n8n',
   jsonb_build_object('ligado', true, 'url', 'https://n8n.ofertasverointernet.com.br/healthz',
                      'falhas_para_alarme', 2, 'lembrete_min', 30, 'timeout_ms', 10000),
   'Vigia do n8n de fora da VPS (0230): pg_cron a cada 2 min → edge vigia-n8n → /healthz. Falhas seguidas abrem a queda e avisam o Ricardo pelo WhatsApp (template alerta_mari_silencio). ligado=false desliga.')
on conflict (chave) do nothing;

create table if not exists public.vigia_n8n_leituras (
  id       bigint generated always as identity primary key,
  lido_em  timestamptz not null default now(),
  ok       boolean not null,
  http     int,
  ms       int,
  erro     text
);
create index if not exists vigia_n8n_leituras_lido_em on public.vigia_n8n_leituras (lido_em desc);

create table if not exists public.vigia_n8n_quedas (
  id               bigint generated always as identity primary key,
  desde            timestamptz not null,           -- 1ª leitura com falha da sequência
  ate              timestamptz,                    -- 1ª leitura ok depois (null = ainda fora)
  falhas           int not null default 0,
  ultimo_erro      text,
  avisado_em       timestamptz,
  lembrado_em      timestamptz,
  volta_avisada_em timestamptz,
  erro_envio       text
);
create unique index if not exists vigia_n8n_quedas_uma_aberta on public.vigia_n8n_quedas ((true)) where ate is null;

alter table public.vigia_n8n_leituras enable row level security;
alter table public.vigia_n8n_quedas enable row level security;
drop policy if exists vigia_n8n_leituras_ler on public.vigia_n8n_leituras;
create policy vigia_n8n_leituras_ler on public.vigia_n8n_leituras for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
drop policy if exists vigia_n8n_quedas_ler on public.vigia_n8n_quedas;
create policy vigia_n8n_quedas_ler on public.vigia_n8n_quedas for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));

-- Devolve {acao: null | 'fora' | 'lembrete' | 'volta', queda_id, minutos, desde, ate, erro, destino}.
create or replace function public.vigia_n8n_registrar(p_ok boolean, p_http int, p_ms int, p_erro text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg      jsonb := coalesce((select valor from public.config_regras where chave = 'vigia_n8n'), '{}'::jsonb);
  v_lim    int := greatest(coalesce((cfg ->> 'falhas_para_alarme')::int, 2), 1);
  v_lemb   int := greatest(coalesce((cfg ->> 'lembrete_min')::int, 30), 5);
  v_dest   text := (select valor #>> '{}' from public.config_regras where chave = 'resumo_destino_whatsapp');
  q        public.vigia_n8n_quedas;
  v_acao   text;
begin
  insert into public.vigia_n8n_leituras (ok, http, ms, erro) values (p_ok, p_http, p_ms, left(p_erro, 300));
  delete from public.vigia_n8n_leituras where lido_em < now() - interval '7 days';

  select * into q from public.vigia_n8n_quedas where ate is null for update;

  if p_ok then
    if q.id is null then return jsonb_build_object('acao', null); end if;
    update public.vigia_n8n_quedas set ate = now(),
           volta_avisada_em = case when avisado_em is not null then now() end
     where id = q.id returning * into q;
    -- queda curta (não chegou a avisar) fecha calada
    v_acao := case when q.avisado_em is not null then 'volta' end;
  else
    if q.id is null then
      insert into public.vigia_n8n_quedas (desde, falhas, ultimo_erro) values (now(), 1, left(p_erro, 300)) returning * into q;
    else
      update public.vigia_n8n_quedas set falhas = falhas + 1, ultimo_erro = left(p_erro, 300) where id = q.id returning * into q;
    end if;
    if q.avisado_em is null and q.falhas >= v_lim then
      update public.vigia_n8n_quedas set avisado_em = now() where id = q.id returning * into q;
      v_acao := 'fora';
    elsif q.avisado_em is not null and coalesce(q.lembrado_em, q.avisado_em) < now() - make_interval(mins => v_lemb) then
      update public.vigia_n8n_quedas set lembrado_em = now() where id = q.id returning * into q;
      v_acao := 'lembrete';
    end if;
  end if;

  return jsonb_build_object(
    'acao', v_acao, 'queda_id', q.id, 'destino', v_dest,
    'minutos', ceil(extract(epoch from (coalesce(q.ate, now()) - q.desde)) / 60)::int,
    'desde', to_char(q.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
    'ate', to_char(q.ate at time zone 'America/Sao_Paulo', 'HH24:MI'),
    'erro', q.ultimo_erro);
end $$;
revoke all on function public.vigia_n8n_registrar(boolean, int, int, text) from public, anon, authenticated;
grant execute on function public.vigia_n8n_registrar(boolean, int, int, text) to service_role;

create or replace function public.vigia_n8n_aviso_erro(p_queda bigint, p_erro text)
returns void language sql security definer set search_path = public as $$
  update public.vigia_n8n_quedas set erro_envio = left(p_erro, 500) where id = p_queda;
$$;
revoke all on function public.vigia_n8n_aviso_erro(bigint, text) from public, anon, authenticated;
grant execute on function public.vigia_n8n_aviso_erro(bigint, text) to service_role;

create extension if not exists pg_cron;

select cron.unschedule('vigia_n8n') where exists (select 1 from cron.job where jobname = 'vigia_n8n');
select cron.schedule('vigia_n8n', '*/2 * * * *', $cron$
  select net.http_post(
    url := 'https://zlrfwbkblytnokuexjti.supabase.co/functions/v1/vigia-n8n',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 25000)
  where coalesce((select (valor ->> 'ligado')::boolean from public.config_regras where chave = 'vigia_n8n'), true);
$cron$);

commit;
