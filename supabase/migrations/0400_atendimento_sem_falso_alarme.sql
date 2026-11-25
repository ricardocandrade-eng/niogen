-- NIOGEN | supabase/migrations/0400_atendimento_sem_falso_alarme.sql | 25/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 25/11 ~11h50: "Essa leitura de 2 leads esperando retorno está errada" → "Esse problema tem se tornado crônico! Essa
-- leitura de que há sempre um problema no atendimento, quando na verdade não".
-- Os dois casos de 25/11 (conferidos mensagem a mensagem em mari_turnos):
--   Poços de Caldas: o time escreveu "A gente vai se falando", o cliente respondeu "Ta bom" (24/11 18h16) e às 21h41 o Ricardo
--     marcou o retorno combinado para 25/11 16h (retorno_marcar, 0379). A 0339 deu "esperando nós" por 17 h.
--   Contagem: o cliente escreveu 11h12 e o time respondeu 11h38 — este era real e curto (o retrato das 11h30 pegou 17 min).
-- Causa: a v_atendimento_fatos (0339/0363) chama de esperando_nos TODO lead cujo último turno é do cliente. Ela já respeitava o
-- "nada a responder" (dispensada_em, 0363) e o Não contatar; não respeitava:
--   (a) cortesia de encerramento: "ok", "tá bom", "obrigado", "valeu", 👍 — logo depois de uma fala nossa SEM pergunta.
--       Se a nossa última fala tem "?", o "ok" é resposta e continua contando (ex.: "posso consultar o seu CPF?" → "ok").
--       Padrão em _fala_de_cortesia(texto); trocável sem deploy em config_regras.atendimento_cortesia (chave "regex"). "Sim" e
--       saudação ("bom dia") ficam de fora de propósito: costumam pedir resposta.
--   (b) retorno combinado aberto (v_retornos agendado/agora, 0379) e ⏸ espera do time (espera_ate futura). Retorno que passou de
--       1 h sem contato vira "perdido" na v_retornos e o lead volta a contar — ninguém fica parado em silêncio.
-- Esses leads saem de esperando_nos e caem na caixa de sempre: conversa_viva (< 24 h) ou calado_com_toque ("retorno combinado").
-- atendimento_leitura: "esperando_nos" e a lista de falhas passam a contar só a espera acima de 15 min (o mesmo corte do Conferir,
-- item 27); o resumo ganha "esperando_nos_ate_15min" (respondendo agora, não é falha), "cliente_encerrou" e "retorno_combinado"
-- (quantos saíram da conta por cada motivo — para conferir que a regra não esconde nada).
-- Duas colunas novas no fim da view: cliente_encerrou, retorno_aberto (para conferir caso a caso).
-- Regra 20: (1) não cria estado — a caixa é leitura calculada; vez, prazo e situação não mudam; (2) ninguém parado: o retorno
--   perdido volta a contar, a cortesia cai em conversa viva/calado com toque, que já têm saída; (3) nada grava; (4) fonte única:
--   a conversa (mari_turnos) e a tabela retornos; (5) conferência: o item 27 do Conferir passa a contar certo (mesma view).
-- Cenário X130. Desempenho: 1 EXISTS por lead em v_retornos (tabela pequena) — medir antes e depois (linha do registro).
-- Medir em 7 dias: falhas de atendimento ditas pelo agente × falhas reais conferidas nas mensagens (meta: zero falso alarme).
begin;

-- (a) a fala de cortesia
create or replace function public._fala_de_cortesia(p_texto text) returns boolean
language sql stable set search_path to 'public' as $$
  select coalesce(
    length(btrim(p_texto)) between 1 and 60
    and p_texto !~ '\?'
    and lower(btrim(p_texto)) ~ coalesce(nullif((select valor ->> 'regex' from public.config_regras where chave = 'atendimento_cortesia'), ''),
      '^[^[:alnum:]]*((ok+|okay|okey|t[aá]|tudo (bem|certo|[oó]timo)|blz|beleza|certo|certinho|combinado|fechado|perfeito|[oó]timo|show|massa|joia|j[oó]ia|entendi|entendido|obrigad[oa]s?|obg|brigad[oa]|muito obrigad[oa]|vlw|valeu|agrade[cç]o|aguardo|fico no aguardo|vou aguardar|ent[aã]o t[aá]|bom|bem|tmj|abs|abra[cç]os?|am[eé]m|deus aben[cç]oe)[^[:alnum:]]*)+$|^[^[:alnum:]]+$'),
    false);
$$;
comment on function public._fala_de_cortesia(text) is
  '0400 — fala curta de cortesia/encerramento do cliente ("ok", "tá bom", "obrigado", 👍). Sem "?". Padrão trocável em config_regras.atendimento_cortesia.regex.';

-- (b) a view (= 0363, trocada só nos trechos descritos no cabeçalho)
create or replace view public.v_atendimento_fatos with (security_invoker = true) as
 WITH base AS (
         SELECT l.lead_id,
            l.conversa_id,
            l.nome,
            l.origem,
            l.cidade,
            l.destino,
            l.etapa_nome,
            l.status_nome,
            l.saida_motivo,
            l.venda_status,
            l.dono,
            l.criado_em,
            l.atrasado,
            l.prazo_em,
            c.cadencia_passo,
            c.cadencia_proximo_em,
            c.retomada_desde,
            c.retomada_passo,
            c.retomada_fim,
            c.espera_ate,
            c.nao_contatar,
            c.dispensada_em
           FROM v_leads l
             JOIN mari_conversas c ON c.id = l.conversa_id
          WHERE l.destino IS DISTINCT FROM 'teste_duplicada'::text
        ), turnos AS (
         SELECT t.conversa_id,
            t.id,
            t.papel,
            t.created_at,
            t.texto,
            COALESCE(t.pendente, false) AS pendente,
            lag(t.papel) OVER (PARTITION BY t.conversa_id ORDER BY t.created_at, t.id) AS antes,
            min(
                CASE
                    WHEN (t.papel = ANY (ARRAY['mari'::text, 'humano'::text])) AND NOT COALESCE(t.pendente, false) THEN t.created_at
                    ELSE NULL::timestamp with time zone
                END) OVER (PARTITION BY t.conversa_id ORDER BY t.created_at DESC, t.id DESC ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS nossa_depois
           FROM mari_turnos t
          WHERE t.papel = ANY (ARRAY['lead'::text, 'mari'::text, 'humano'::text])
        ), fala AS (
         SELECT turnos.conversa_id,
            max(turnos.created_at) FILTER (WHERE turnos.papel = 'lead'::text) AS ult_cliente_em,
            max(turnos.created_at) FILTER (WHERE turnos.papel = 'mari'::text AND NOT turnos.pendente) AS ult_mari_em,
            max(turnos.created_at) FILTER (WHERE turnos.papel = 'humano'::text AND NOT turnos.pendente) AS ult_time_em,
            count(*) FILTER (WHERE turnos.papel = 'lead'::text) AS n_cliente,
            count(*) FILTER (WHERE turnos.papel = 'mari'::text) AS n_mari,
            count(*) FILTER (WHERE turnos.papel = 'humano'::text) AS n_time,
            (array_agg(turnos.texto ORDER BY turnos.created_at DESC, turnos.id DESC) FILTER (WHERE turnos.papel = 'lead'::text))[1] AS ult_cliente_texto,
            (array_agg(turnos.texto ORDER BY turnos.created_at DESC, turnos.id DESC) FILTER (WHERE turnos.papel = ANY (ARRAY['mari'::text, 'humano'::text]) AND NOT turnos.pendente))[1] AS ult_nossa_texto
           FROM turnos
          GROUP BY turnos.conversa_id
        ), rajada AS (
         SELECT turnos.conversa_id,
            turnos.created_at,
            turnos.nossa_depois AS resposta_em
           FROM turnos
          WHERE turnos.papel = 'lead'::text AND turnos.antes IS DISTINCT FROM 'lead'::text
        ), tempo AS (
         SELECT rajada.conversa_id,
            count(*) FILTER (WHERE rajada.resposta_em IS NOT NULL) AS respostas_n,
            count(*) FILTER (WHERE (rajada.resposta_em - rajada.created_at) <= '00:15:00'::interval) AS respostas_15min_n,
            round(EXTRACT(epoch FROM (array_agg(rajada.resposta_em - rajada.created_at ORDER BY rajada.created_at))[1]) / 60::numeric)::integer AS primeira_resposta_min,
            round(EXTRACT(epoch FROM max(rajada.resposta_em - rajada.created_at) FILTER (WHERE (rajada.resposta_em - rajada.created_at) <= '24:00:00'::interval)) / 60::numeric)::integer AS pior_resposta_min
           FROM rajada
          GROUP BY rajada.conversa_id
        ), j AS (
         SELECT b.lead_id,
            b.conversa_id,
            b.nome,
            b.origem,
            b.cidade,
            b.destino,
            b.etapa_nome,
            b.status_nome,
            b.saida_motivo,
            b.venda_status,
            b.dono,
            b.criado_em,
            b.atrasado,
            b.prazo_em,
            b.cadencia_passo,
            b.cadencia_proximo_em,
            b.retomada_desde,
            b.retomada_passo,
            b.retomada_fim,
            b.espera_ate,
            b.nao_contatar,
            f.ult_cliente_em,
            f.ult_mari_em,
            f.ult_time_em,
            COALESCE(f.n_cliente, 0::bigint) AS n_cliente,
            COALESCE(f.n_mari, 0::bigint) AS n_mari,
            COALESCE(f.n_time, 0::bigint) AS n_time,
            GREATEST(f.ult_mari_em, f.ult_time_em) AS ult_nossa_em,
            COALESCE(t.respostas_n, 0::bigint) AS respostas_n,
            COALESCE(t.respostas_15min_n, 0::bigint) AS respostas_15min_n,
            t.primeira_resposta_min,
            t.pior_resposta_min,
            b.retomada_desde IS NOT NULL AND b.retomada_fim IS NULL AS retomada_aberta,
            b.dispensada_em,
            f.ult_cliente_texto,
            f.ult_nossa_texto,
            (EXISTS ( SELECT 1 FROM public.v_retornos r
                      WHERE r.conversa_id = b.conversa_id AND (r.situacao = ANY (ARRAY['agendado'::text, 'agora'::text])))) AS retorno_aberto,
            f.ult_cliente_em > COALESCE(GREATEST(f.ult_mari_em, f.ult_time_em), '-infinity'::timestamp with time zone)
              AND public._fala_de_cortesia(f.ult_cliente_texto) AND COALESCE(f.ult_nossa_texto, ''::text) !~ '\?'::text AS cliente_encerrou
           FROM base b
             LEFT JOIN fala f ON f.conversa_id = b.conversa_id
             LEFT JOIN tempo t ON t.conversa_id = b.conversa_id
        ), k AS (
         SELECT j.lead_id,
            j.conversa_id,
            j.nome,
            j.origem,
            j.cidade,
            j.destino,
            j.etapa_nome,
            j.status_nome,
            j.saida_motivo,
            j.venda_status,
            j.dono,
            j.criado_em,
            j.atrasado,
            j.prazo_em,
            j.cadencia_passo,
            j.cadencia_proximo_em,
            j.retomada_desde,
            j.retomada_passo,
            j.retomada_fim,
            j.espera_ate,
            j.nao_contatar,
            j.ult_cliente_em,
            j.ult_mari_em,
            j.ult_time_em,
            j.n_cliente,
            j.n_mari,
            j.n_time,
            j.ult_nossa_em,
            j.respostas_n,
            j.respostas_15min_n,
            j.primeira_resposta_min,
            j.pior_resposta_min,
            j.retomada_aberta,
            j.retorno_aberto,
            COALESCE(j.cliente_encerrou, false) AS cliente_encerrou,
                CASE
                    WHEN j.ult_cliente_em IS NULL AND j.ult_nossa_em IS NULL THEN NULL::text
                    WHEN j.ult_cliente_em > COALESCE(j.ult_nossa_em, '-infinity'::timestamp with time zone) THEN 'cliente'::text
                    WHEN j.ult_time_em >= COALESCE(j.ult_mari_em, '-infinity'::timestamp with time zone) THEN 'time'::text
                    ELSE 'mari'::text
                END AS ult_quem,
                CASE
                    WHEN j.destino = 'saida'::text THEN 'saida'::text
                    WHEN j.destino = 'instalada'::text THEN 'instalada'::text
                    WHEN j.destino = 'em_andamento'::text AND j.ult_cliente_em > COALESCE(j.ult_nossa_em, '-infinity'::timestamp with time zone) AND NOT COALESCE(j.nao_contatar, false) AND NOT COALESCE(j.dispensada_em >= j.ult_cliente_em, false) AND NOT COALESCE(j.cliente_encerrou, false) AND NOT j.retorno_aberto AND NOT COALESCE(j.espera_ate > now(), false) THEN 'esperando_nos'::text
                    WHEN j.destino = 'em_andamento'::text AND j.venda_status IS NOT NULL THEN
                    CASE
                        WHEN j.atrasado THEN 'venda_atrasada'::text
                        ELSE 'venda'::text
                    END
                    WHEN j.destino = 'em_andamento'::text AND j.ult_cliente_em > (now() - '24:00:00'::interval) THEN 'conversa_viva'::text
                    WHEN j.destino = 'em_andamento'::text AND (j.cadencia_proximo_em IS NOT NULL OR j.retomada_aberta OR j.retorno_aberto OR j.dono IS NOT NULL OR j.espera_ate > now() OR COALESCE(j.nao_contatar, false)) THEN 'calado_com_toque'::text
                    WHEN j.destino = 'em_andamento'::text THEN 'calado_esquecido'::text
                    ELSE COALESCE(j.destino, 'sem_destino'::text)
                END AS caixa
           FROM j
        )
 SELECT lead_id,
    conversa_id,
    nome,
    origem,
    cidade,
    destino,
    etapa_nome,
    status_nome,
    saida_motivo,
    venda_status,
    dono,
    criado_em,
    caixa,
    ult_quem,
    ult_cliente_em,
    ult_mari_em,
    ult_time_em,
    ult_nossa_em,
    n_cliente,
    n_mari,
    n_time,
        CASE
            WHEN caixa = 'esperando_nos'::text THEN round(EXTRACT(epoch FROM now() - ult_cliente_em) / 60::numeric)::integer
            ELSE NULL::integer
        END AS esperando_nos_min,
    round(EXTRACT(epoch FROM now() - GREATEST(ult_cliente_em, ult_nossa_em)) / 3600::numeric, 1) AS horas_sem_conversa,
    respostas_n,
    respostas_15min_n,
    primeira_resposta_min,
    pior_resposta_min,
        CASE
            WHEN caixa <> 'calado_com_toque'::text THEN NULL::text
            WHEN cadencia_proximo_em IS NOT NULL THEN format('cadência (%s) · próximo toque %s'::text, COALESCE(cadencia_passo, '?'::text), to_char((cadencia_proximo_em AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM HH24:MI'::text))
            WHEN retomada_aberta THEN format('Retomada (%s)'::text, COALESCE(retomada_passo, 'aberta'::text))
            WHEN retorno_aberto THEN 'retorno combinado'::text
            WHEN espera_ate > now() THEN format('em espera até %s'::text, to_char((espera_ate AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text))
            WHEN COALESCE(nao_contatar, false) THEN 'não contatar'::text
            ELSE format('com %s, esperando o cliente'::text, dono)
        END AS quem_cuida,
    cadencia_passo,
    cadencia_proximo_em,
    retomada_aberta,
    retomada_passo,
    prazo_em,
    atrasado,
    cliente_encerrou,
    retorno_aberto
   FROM k;

comment on view public.v_atendimento_fatos is
  '0339/0363/0400 — leitura do atendimento pelas MENSAGENS (mari_turnos). Falha de atendimento = caixa esperando_nos: o cliente falou por último, não foi cortesia de encerramento depois de fala nossa sem pergunta, e não há retorno combinado aberto, espera do time, nada a responder nem Não contatar.';

-- (c) o resumo
create or replace function public.atendimento_leitura(p_desde timestamptz default now() - interval '30 days', p_origem text default null)
returns jsonb language sql stable security invoker set search_path to 'public' as $$
  with f as (select * from public.v_atendimento_fatos where criado_em >= p_desde and (p_origem is null or origem = p_origem))
  select jsonb_build_object(
    'gerado_em', now(), 'desde', p_desde, 'origem', p_origem,
    'leads', (select count(*) from f),
    'caixas', coalesce((select jsonb_object_agg(caixa, n) from (select caixa, count(*) n from f group by caixa) x), '{}'::jsonb),
    'esperando_nos', (select count(*) from f where caixa = 'esperando_nos' and esperando_nos_min > 15),
    'esperando_nos_ate_15min', (select count(*) from f where caixa = 'esperando_nos' and esperando_nos_min <= 15),
    'cliente_encerrou', (select count(*) from f where destino = 'em_andamento' and cliente_encerrou),
    'retorno_combinado', (select count(*) from f where destino = 'em_andamento' and retorno_aberto),
    'tempo_resposta', jsonb_build_object(
       'respostas', (select coalesce(sum(respostas_n), 0) from f),
       'em_ate_15min', (select coalesce(sum(respostas_15min_n), 0) from f),
       'pct_ate_15min', (select round(100.0 * sum(respostas_15min_n) / nullif(sum(respostas_n), 0), 1) from f),
       'primeira_resposta_mediana_min', (select percentile_cont(0.5) within group (order by primeira_resposta_min)
                                           from f where primeira_resposta_min is not null)),
    'calados_com_toque', coalesce((select jsonb_object_agg(q, n) from (
        select split_part(quem_cuida, ' ', 1) q, count(*) n from f where caixa = 'calado_com_toque' group by 1) x), '{}'::jsonb),
    'saidas', coalesce((select jsonb_object_agg(coalesce(saida_motivo, '?'), n) from (
        select saida_motivo, count(*) n from f where caixa = 'saida' group by 1) x), '{}'::jsonb),
    'falhas', coalesce((select jsonb_agg(jsonb_build_object('lead_id', lead_id, 'nome', nome, 'cidade', cidade, 'caixa', caixa,
                  'etapa', etapa_nome, 'cliente_falou_em', ult_cliente_em, 'esperando_min', esperando_nos_min, 'prazo_em', prazo_em)
                  order by caixa, ult_cliente_em)
               from f where (caixa = 'esperando_nos' and esperando_nos_min > 15) or caixa in ('calado_esquecido', 'venda_atrasada')), '[]'::jsonb));
$$;

revoke all on public.v_atendimento_fatos from anon;
grant select on public.v_atendimento_fatos to authenticated;
revoke execute on function public._fala_de_cortesia(text) from public, anon;
grant execute on function public._fala_de_cortesia(text) to authenticated;
revoke execute on function public.atendimento_leitura(timestamptz, text) from public, anon;
grant execute on function public.atendimento_leitura(timestamptz, text) to authenticated;

commit;
