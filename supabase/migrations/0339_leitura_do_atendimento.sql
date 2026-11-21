-- NIOGEN | supabase/migrations/0339_leitura_do_atendimento.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 20/11 (~23h): "existe um desvio de leitura absurda entre o que você enxerga no atendimento e o que realmente acontece…
-- precisamos fechar esse portão… se preciso for, construir uma ferramenta" → "Sim, constrói".
-- Erro que motivou: o diagnóstico do agente de tráfego (18/11) disse "35 leads parados do nosso lado", lido da `vez` de v_leads,
-- que até a 0310 dava a vez ao time em todo lead com dono sem olhar quem falou. Conferido mensagem a mensagem (mari_turnos, 159 leads
-- meta_ads de 06 a 20/11): nos 41 em andamento a última fala era NOSSA em todos; 131 de 159 respondidos em até 1 h.
-- O que nasce (só leitura — nada grava, nada muda de estado):
--  (1) v_atendimento_fatos: uma linha por lead, com os FATOS das mensagens (mari_turnos, papéis lead/mari/humano; turno nosso
--      pendente não conta): quem falou por último e quando, quantas falas de cada lado, tempo da 1ª resposta e da pior resposta
--      (cada "rajada" do cliente até a nossa próxima fala; a pior só entre as respondidas em até 24 h, para o "Ok, obrigado"
--      seguido do D3 dias depois não virar demora) e a CAIXA, de uma lista fechada:
--        esperando_nos      em andamento, o cliente falou por último e ninguém respondeu (a ÚNICA falha de atendimento)
--        conversa_viva      em andamento, o cliente falou nas últimas 24 h e foi respondido
--        calado_com_toque   em andamento, cliente calado > 24 h e algo cuida dele: toque da cadência marcado, Retomada aberta,
--                           dono (pessoa/time), espera com data ou não contatar — `quem_cuida` diz qual
--        calado_esquecido   em andamento, cliente calado > 24 h e nada cuida dele (regra 20: não pode existir)
--        venda / venda_atrasada   em andamento com venda (atrasada = prazo da vez vencido)
--        saida / instalada
--  (2) atendimento_leitura(p_desde, p_origem): o resumo que o agente de tráfego e as telas usam — caixas, tempos de resposta e a
--      lista das falhas (esperando_nos, calado_esquecido, venda_atrasada). Regra do agente: falar de atendimento SÓ por aqui.
--  (3) conferencia_itens (= produção de 21/11 ~0h, pg_get_functiondef) + item 27 'esperando_nos' (falha, > 15 min) e
--      item 28 'calado_esquecido' (atenção). Nada mais muda na função.
-- Regra 20: (1) não cria estado: a caixa é leitura calculada das mensagens; situação, vez e prazo seguem os de sempre;
--   (2) nenhum evento, nenhuma gravação; (3) tela: nenhuma agora (a Live não muda sem debate); o Conferir das 7h10 ganha os 2 itens;
--   (4) fonte única: a conversa → mari_turnos (NIOGEN); (5) conferência: os próprios itens 27 e 28.
-- Cenário X65. Desempenho: o Conferir ganha 2 leituras da view (medido no ar antes e depois — linha do Diário).
begin;

create or replace view public.v_atendimento_fatos with (security_invoker = true) as
with base as (
  select l.lead_id, l.conversa_id, l.nome, l.origem, l.cidade, l.destino, l.etapa_nome, l.status_nome, l.saida_motivo,
         l.venda_status, l.dono, l.criado_em, l.atrasado, l.prazo_em,
         c.cadencia_passo, c.cadencia_proximo_em, c.retomada_desde, c.retomada_passo, c.retomada_fim, c.espera_ate, c.nao_contatar
    from public.v_leads l
    join public.mari_conversas c on c.id = l.conversa_id
   where l.destino is distinct from 'teste_duplicada'
),
turnos as (   -- uma passada por conversa: a fala anterior e a nossa próxima fala (sem subconsulta por linha)
  select t.conversa_id, t.id, t.papel, t.created_at, coalesce(t.pendente, false) as pendente,
         lag(t.papel) over (partition by t.conversa_id order by t.created_at, t.id) as antes,
         min(case when t.papel in ('mari', 'humano') and not coalesce(t.pendente, false) then t.created_at end)
           over (partition by t.conversa_id order by t.created_at desc, t.id desc rows between unbounded preceding and 1 preceding) as nossa_depois
    from public.mari_turnos t
   where t.papel in ('lead', 'mari', 'humano')
),
fala as (
  select conversa_id,
         max(created_at) filter (where papel = 'lead') as ult_cliente_em,
         max(created_at) filter (where papel = 'mari' and not pendente) as ult_mari_em,
         max(created_at) filter (where papel = 'humano' and not pendente) as ult_time_em,
         count(*) filter (where papel = 'lead') as n_cliente,
         count(*) filter (where papel = 'mari') as n_mari,
         count(*) filter (where papel = 'humano') as n_time
    from turnos group by conversa_id
),
rajada as (   -- 1ª mensagem de cada rajada do cliente e a nossa próxima fala
  select conversa_id, created_at, nossa_depois as resposta_em
    from turnos where papel = 'lead' and antes is distinct from 'lead'
),
tempo as (
  select conversa_id,
         count(*) filter (where resposta_em is not null) as respostas_n,
         count(*) filter (where resposta_em - created_at <= interval '15 minutes') as respostas_15min_n,
         round(extract(epoch from (array_agg(resposta_em - created_at order by created_at))[1]) / 60)::int as primeira_resposta_min,
         round(extract(epoch from max(resposta_em - created_at) filter (where resposta_em - created_at <= interval '24 hours')) / 60)::int
           as pior_resposta_min
    from rajada group by conversa_id
),
j as (
  select b.*, f.ult_cliente_em, f.ult_mari_em, f.ult_time_em,
         coalesce(f.n_cliente, 0) as n_cliente, coalesce(f.n_mari, 0) as n_mari, coalesce(f.n_time, 0) as n_time,
         greatest(f.ult_mari_em, f.ult_time_em) as ult_nossa_em,
         coalesce(t.respostas_n, 0) as respostas_n, coalesce(t.respostas_15min_n, 0) as respostas_15min_n,
         t.primeira_resposta_min, t.pior_resposta_min,
         (b.retomada_desde is not null and b.retomada_fim is null) as retomada_aberta
    from base b left join fala f on f.conversa_id = b.conversa_id left join tempo t on t.conversa_id = b.conversa_id
),
k as (
  select j.*,
         case when j.ult_cliente_em is null and j.ult_nossa_em is null then null
              when j.ult_cliente_em > coalesce(j.ult_nossa_em, '-infinity'::timestamptz) then 'cliente'
              when j.ult_time_em >= coalesce(j.ult_mari_em, '-infinity'::timestamptz) then 'time'
              else 'mari' end as ult_quem,
         case
           when j.destino = 'saida' then 'saida'
           when j.destino = 'instalada' then 'instalada'
           when j.destino = 'em_andamento' and j.ult_cliente_em > coalesce(j.ult_nossa_em, '-infinity'::timestamptz)
                and not coalesce(j.nao_contatar, false) then 'esperando_nos'
           when j.destino = 'em_andamento' and j.venda_status is not null then case when j.atrasado then 'venda_atrasada' else 'venda' end
           when j.destino = 'em_andamento' and j.ult_cliente_em > now() - interval '24 hours' then 'conversa_viva'
           when j.destino = 'em_andamento' and (j.cadencia_proximo_em is not null or j.retomada_aberta or j.dono is not null
                                                or j.espera_ate > now() or coalesce(j.nao_contatar, false)) then 'calado_com_toque'
           when j.destino = 'em_andamento' then 'calado_esquecido'
           else coalesce(j.destino, 'sem_destino') end as caixa
    from j
)
select k.lead_id, k.conversa_id, k.nome, k.origem, k.cidade, k.destino, k.etapa_nome, k.status_nome, k.saida_motivo, k.venda_status,
       k.dono, k.criado_em, k.caixa, k.ult_quem,
       k.ult_cliente_em, k.ult_mari_em, k.ult_time_em, k.ult_nossa_em, k.n_cliente, k.n_mari, k.n_time,
       case when k.caixa = 'esperando_nos' then round(extract(epoch from (now() - k.ult_cliente_em)) / 60)::int end as esperando_nos_min,
       round(extract(epoch from (now() - greatest(k.ult_cliente_em, k.ult_nossa_em))) / 3600, 1) as horas_sem_conversa,
       k.respostas_n, k.respostas_15min_n, k.primeira_resposta_min, k.pior_resposta_min,
       case when k.caixa <> 'calado_com_toque' then null
            when k.cadencia_proximo_em is not null then format('cadência (%s) · próximo toque %s', coalesce(k.cadencia_passo, '?'),
                 to_char(k.cadencia_proximo_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'))
            when k.retomada_aberta then format('Retomada (%s)', coalesce(k.retomada_passo, 'aberta'))
            when k.espera_ate > now() then format('em espera até %s', to_char(k.espera_ate at time zone 'America/Sao_Paulo', 'DD/MM'))
            when coalesce(k.nao_contatar, false) then 'não contatar'
            else format('com %s, esperando o cliente', k.dono) end as quem_cuida,
       k.cadencia_passo, k.cadencia_proximo_em, k.retomada_aberta, k.retomada_passo, k.prazo_em, k.atrasado
  from k;

comment on view public.v_atendimento_fatos is
  '0339 — leitura do atendimento pelas MENSAGENS (mari_turnos). Única fonte para dizer se há falha de atendimento: caixa esperando_nos.';

-- (2) o resumo
create or replace function public.atendimento_leitura(p_desde timestamptz default now() - interval '30 days', p_origem text default null)
returns jsonb language sql stable security invoker set search_path to 'public' as $$
  with f as (select * from public.v_atendimento_fatos where criado_em >= p_desde and (p_origem is null or origem = p_origem))
  select jsonb_build_object(
    'gerado_em', now(), 'desde', p_desde, 'origem', p_origem,
    'leads', (select count(*) from f),
    'caixas', coalesce((select jsonb_object_agg(caixa, n) from (select caixa, count(*) n from f group by caixa) x), '{}'::jsonb),
    'esperando_nos', (select count(*) from f where caixa = 'esperando_nos'),
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
               from f where caixa in ('esperando_nos', 'calado_esquecido', 'venda_atrasada')), '[]'::jsonb));
$$;

revoke all on public.v_atendimento_fatos from anon;
grant select on public.v_atendimento_fatos to authenticated;
revoke execute on function public.atendimento_leitura(timestamptz, text) from public, anon;
grant execute on function public.atendimento_leitura(timestamptz, text) to authenticated;

-- (3) conferencia_itens = produção (21/11 ~0h) + itens 27 e 28
CREATE OR REPLACE FUNCTION public.conferencia_itens(p_parceiro text DEFAULT 'dharma'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  it     jsonb := '[]'::jsonb;
  n      int;
  n2     int;
  ex     text;
  v_tot  int;
  v_soma int;
begin
  if not public._os_pode_gravar() then   -- admin, backoffice, chave de serviço ou CLI
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;

  -- 1. A soma dos destinos é o total de leads
  select count(*) into v_tot from public.v_leads;
  select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.v_leads where destino is not null group by destino) x;
  it := it || jsonb_build_object('codigo', 'soma_destinos', 'nome', 'Soma dos destinos = total de leads',
    'nivel', case when v_tot = v_soma then 'ok' else 'falha' end, 'n', v_tot - v_soma,
    'texto', format('%s leads; os destinos somam %s', v_tot, v_soma),
    'fazer', case when v_tot = v_soma then null else 'Há lead sem destino: avisar o Claude Code (é defeito da v_leads).' end);

  -- 2. Lead em andamento sem vez / sem status · saída sem motivo
  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'em_andamento' and (vez is null or status is null)) x;
  it := it || jsonb_build_object('codigo', 'lead_sem_vez', 'nome', 'Todo lead em andamento tem status e vez',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todos com status e de quem é a vez' else format('%s lead(s) sem status ou sem vez: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir cada um na Leads e registrar o que falta; se o sistema não deixar, avisar o Claude Code.' end);

  select count(*), string_agg(nome, ', ' order by ultima_em desc) filter (where rn <= 5) into n, ex
    from (select nome, ultima_em, row_number() over (order by ultima_em desc) rn from public.v_leads
           where destino = 'saida' and saida_motivo is null) x;
  it := it || jsonb_build_object('codigo', 'saida_sem_motivo', 'nome', 'Toda saída tem motivo',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as saídas com motivo da lista única' else format('%s saída(s) sem motivo: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha e registrar o motivo da Saída.' end);

  -- 3. Prazo vencido (ninguém parado em silêncio): fecha, mas é para olhar hoje
  select count(*) into n from public.v_leads where destino = 'em_andamento' and atrasado and not em_espera;
  it := it || jsonb_build_object('codigo', 'atrasados', 'nome', 'Leads com o prazo da vez vencido',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead com prazo vencido' else format('%s lead(s) com o prazo vencido', n) end,
    'fazer', case when n = 0 then null else 'Leads › aba Precisam de ação.' end);

  -- 4. NIOGEN × Nio — venda sem pedido
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select cliente_nome, row_number() over (order by criado_em desc) rn from public.vendas
           where status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio')
             and coalesce(nullif(btrim(nio_os), ''), nullif(btrim(nio_pedido), '')) is null) x;
  it := it || jsonb_build_object('codigo', 'venda_sem_pedido', 'nome', 'Toda venda tem o nº do pedido da Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as vendas com pedido' else format('%s venda(s) sem nº de pedido: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Gravar o nº do pedido do portal na ficha.' end);

  -- 5. NIOGEN × Nio — OS aberta que o Operador de OS nunca leu (há mais de 6 h)
  select count(*), string_agg(ped, ', ') filter (where rn <= 5) into n, ex
    from (select coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) as ped,
                 row_number() over (order by v.criado_em desc) rn
            from public.vendas v
           where v.status in ('1_vendido', '2_aguardando_instalacao')
             and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) ~ '^\d{8}$'
             and coalesce(v.nio_os_em, v.nio_pedido_em, v.vendido_em, v.criado_em) < now() - interval '6 hours'
             and not exists (select 1 from public.os_andamento a where a.parceiro_id = p_parceiro
                              and a.pedido = coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')))) x;
  it := it || jsonb_build_object('codigo', 'os_sem_leitura', 'nome', 'Toda OS aberta foi lida na Nio',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as OS abertas com leitura do Operador de OS' else format('%s OS sem nenhuma leitura: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Operações › ⟳ Varrer OS abertas. Se não ler, conferir o CPF e o nº da OS da venda.' end);

  -- 6. NIOGEN × Nio — a Nio enxerga pedido que o NIOGEN não tem
  select count(*) into n from public.portal_pedidos p
   where p.parceiro_id = p_parceiro and p.venda_id is null and upper(coalesce(p.tipo, '')) = 'VENDA'
     and p.ultima_leitura > now() - interval '30 days';
  select coalesce((i.resumo ->> 'sem_venda')::int, 0) into n2 from public.importacoes i
   where i.tipo = 'osab' and i.aplicado_em is not null order by i.aplicado_em desc limit 1;
  it := it || jsonb_build_object('codigo', 'pedido_sem_venda', 'nome', 'Pedido na Nio sem venda no NIOGEN',
    'nivel', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'ok' else 'atencao' end, 'n', coalesce(n, 0) + coalesce(n2, 0),
    'texto', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then 'nenhum pedido da Nio sem venda nossa'
                  else format('%s no Histórico do portal e %s no último OSAB', coalesce(n, 0), coalesce(n2, 0)) end,
    'fazer', case when coalesce(n, 0) + coalesce(n2, 0) = 0 then null else 'Live › Conferir › casar o pedido com a venda (ou registrar a venda que falta).' end);

  -- 7. NIOGEN × Nio — texto novo da Nio sem tradução e exceção de OS parada há mais de 1 dia
  select count(*), string_agg(texto, ' · ') into n, ex from public.config_os_estados where parceiro_id = p_parceiro and estado is null;
  it := it || jsonb_build_object('codigo', 'os_texto_novo', 'nome', 'Textos da Nio traduzidos',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todos os textos da OS conhecidos' else format('%s texto(s) sem tradução: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Ricardo para traduzir (config_os_estados). Enquanto isso a venda não muda sozinha.' end);

  select count(*) into n from public.os_andamento where parceiro_id = p_parceiro and excecao and excecao_desde < now() - interval '1 day';
  it := it || jsonb_build_object('codigo', 'os_excecao_parada', 'nome', 'Exceção de OS tratada no mesmo dia',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma exceção de OS aberta há mais de 1 dia' else format('%s exceção(ões) de OS aberta(s) há mais de 1 dia', n) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › linhas "OS … na Nio".' end);

  -- 8. NIOGEN × Chatwoot — conversa mexida fora e ação que o Chatwoot não obedeceu
  select count(*) into n from public.mari_conversas c
   where c.canal = 'whatsapp' and c.funil_alerta is not null and coalesce(c.telefone, '') not like '5500000000%';
  select count(*) into n2 from public.chatwoot_acoes a
   where a.status = 'erro' and a.criada_em > now() - interval '7 days'
     and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                       and b.status = 'feita' and b.criada_em > a.criada_em);
  it := it || jsonb_build_object('codigo', 'chatwoot', 'nome', 'NIOGEN e Chatwoot dizem a mesma coisa',
    'nivel', case when n + n2 = 0 then 'ok' else 'atencao' end, 'n', n + n2,
    'texto', case when n + n2 = 0 then 'nenhuma conversa mexida fora e nenhuma ação em erro'
                  else format('%s conversa(s) mexida(s) direto no Chatwoot · %s ação(ões) que o Chatwoot não obedeceu', n, n2) end,
    'fazer', case when n + n2 = 0 then null else 'Live › Conferir.' end);

  -- 9. Dinheiro — toda instalada tem a comissão prevista lançada
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') filter (where rn <= 5) into n, ex
    from (select v.cliente_nome, row_number() over (order by v.instalado_em desc) rn from public.vendas v
           where v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.instalado_em is not null
             and coalesce(v.comissao_prevista, 0) > 0
             and not exists (select 1 from public.comissao_lancamentos l where l.venda_id = v.id and l.tipo = 'prevista')) x;
  it := it || jsonb_build_object('codigo', 'instalada_sem_previsto', 'nome', 'Toda instalada tem a comissão prevista lançada',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todas as instaladas com o previsto na razão da comissão' else format('%s instalada(s) sem o previsto: %s', n, ex) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: a razão da comissão não lançou o previsto.' end);

  -- 10. Dinheiro — previsto × extrato (só quando houver Extrato importado e conciliado: etapa 5c)
  select count(*) into n from public.comissao_lancamentos where parceiro_id = p_parceiro and origem = 'extrato';
  it := it || jsonb_build_object('codigo', 'previsto_extrato', 'nome', 'Comissão prevista × Extrato da Nio',
    'nivel', case when n = 0 then 'sem_dado' else 'ok' end, 'n', n,
    'texto', case when n = 0 then 'o Extrato da Nio ainda não foi conciliado (etapa 5c do plano)' else format('%s lançamento(s) do extrato', n) end,
    'fazer', null);

  -- 11. 0182 — risco de recompra: venda em andamento com CPF ou endereço repetido e ainda sem o "Conferi" (só aviso)
  select count(*), string_agg(coalesce(nullif(btrim(cliente_nome), ''), 'sem nome'), ', ') into n, ex from public.v_venda_risco_recompra;
  it := it || jsonb_build_object('codigo', 'risco_recompra', 'nome', 'Venda em andamento sem risco de recompra',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma venda em andamento com CPF ou endereço repetido' else format('%s venda(s) com CPF ou endereço repetido: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Conferir no portal antes de gravar o pedido e marcar "Conferi" na ficha. Recompra = multa de R$ 500.' end);

  -- 12. 0183 — o vermelho do pulso tem dono: incidente "Mari parada" sem nenhum cliente esperando (últimas 24 h; sem crédito não conta)
  select count(*), string_agg(to_char(inicio_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), ', ' order by inicio_em) into n, ex
    from public.pulso_incidentes
   where parceiro_id = p_parceiro and elo = 'mari' and nivel = 'parado' and clientes_esperando_max = 0
     and inicio_em > now() - interval '24 hours' and coalesce(motivo, '') not ilike 'sem crédito%';
  it := it || jsonb_build_object('codigo', 'pulso_mari_sem_espera', 'nome', 'Alarme da Mari só com cliente esperando',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum alarme vermelho da Mari sem cliente esperando nas últimas 24 h'
                  else format('%s alarme(s) vermelho(s) da Mari sem cliente esperando: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o pulso acusou a Mari sem ninguém esperando (ver pulso_incidentes e Mari › Erros).' end);

  -- 13. 0186 — o caminho de volta para a Meta: evento na fila com erro, ou venda de anuncio cuja OS nao virou Purchase enviado
  select count(*), string_agg(distinct evento, ', ') into n, ex from public.meta_eventos
   where parceiro_id = p_parceiro and status = 'erro';
  -- só conta o que já passou de 1 h: a fila normal esvazia de 5 em 5 min
  select count(*) into n2 from public.v_venda_meta vm
   where vm.tem_os and vm.meta_status = 'sem_evento'
      or (vm.tem_os and vm.meta_status = 'pendente'
          and exists (select 1 from public.meta_eventos e where e.venda_id = vm.venda_id and e.evento = 'Purchase'
                        and e.criado_em < now() - interval '1 hour'));
  it := it || jsonb_build_object('codigo', 'meta_capi', 'nome', 'A Meta recebeu o que o NIOGEN gravou',
    'nivel', case when n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', n + n2,
    'texto', case when n > 0 then format('%s evento(s) com erro de envio (%s)', n, left(coalesce(ex, ''), 60))
                  when n2 > 0 then format('%s venda(s) de anuncio esperando o Purchase na fila', n2)
                  else 'nenhum erro de envio e nenhuma venda de anuncio parada na fila' end,
    'fazer', case when n > 0 then 'Avisar o Claude Code: ver meta_eventos (resposta e fbtrace_id) e o workflow meta_capi_envio. Nao reenviar a mao.'
                  when n2 > 0 then 'Se passar de 1 h, o workflow meta_capi_envio pode estar parado: avisar o Claude Code.'
                  else null end);


  -- 14. 0202 — conferir a rua: o portal consultou outra rua e ninguém conferiu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where rua_conferir_em is not null and rua_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_rua', 'nome', 'Rua conferida em até 4 h quando o portal consulta outra rua',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma conferência de rua parada há mais de 4 h' else format('%s conversa(s) com a rua por conferir há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Portal: outra rua": refazer na Cobertura escolhendo a rua do cliente e marcar "Conferi".' end);

  -- 15. 0202 — a DFV ao vivo sai pela API do Power BI (o operador da VPS é só reserva)
  select count(*), count(*) filter (where coalesce(detalhe ->> 'fonte', '') <> 'api') into n, n2
    from public.operador_consultas where tipo = 'dfv'
     and criado_em > greatest(now() - interval '24 hours', timestamptz '2026-11-14 20:10-03');   -- API no ar desde 14/11 20h10
  it := it || jsonb_build_object('codigo', 'dfv_pela_api', 'nome', 'DFV consultada pela API do Power BI',
    'nivel', case when n = 0 or n2 * 100 <= n * 5 then 'ok' else 'atencao' end, 'n', n2,
    'texto', case when n = 0 then 'nenhuma consulta DFV nas últimas 24 h' else format('%s de %s consulta(s) DFV nas últimas 24 h fora da API', n2, n) end,
    'fazer', case when n = 0 or n2 * 100 <= n * 5 then null else 'A Nio pode ter republicado o relatório (chave/modelId mudaram): avisar o Claude Code — config_regras.dfv_api.' end);

  -- 16. 0218 — ninguém parado em silêncio: vez da Mari, conversa ativa, sem próximo toque e sem prazo
  select count(*), string_agg(coalesce(nullif(btrim(l.nome), ''), 'sem nome'), ', ' order by l.ultima_em desc) into n, ex
    from public._lead_em_silencio() s join public.v_leads l on l.conversa_id = s.conversa_id;
  it := it || jsonb_build_object('codigo', 'lead_em_silencio', 'nome', 'Ninguém parado em silêncio (vez da Mari sem próximo toque)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todo lead com a vez da Mari tem o próximo toque marcado ou um prazo'
                  else format('%s lead(s) com a vez da Mari, sem próximo toque e sem prazo: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir na Live e dar saída, esquentar (🔥) ou assumir. Se a cadência deveria ter marcado o próximo toque, avisar o Claude Code.' end);

  -- 17. 0228 (revisão dos fluxos) — Saída com dono: lead em Saída cuja conversa segue aberta com pessoa ou time no Chatwoot
  -- há mais de 1 h (a Saída devolve para a Mari na hora; "já é cliente Nio" e "não contatar" ficam de fora).
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and (v.status = 'saida' or (c.venda_id is null and c.saida_em is not null and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')))
     and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente') and not coalesce(c.nao_contatar, false)
     and c.chatwoot_status in ('open', 'pending') and (c.chatwoot_agente is not null or c.chatwoot_time is not null)
     and coalesce(c.saida_em, c.funil_destino_em, c.created_at) < now() - interval '1 hour';
  it := it || jsonb_build_object('codigo', 'saida_com_dono', 'nome', 'Lead em Saída sem dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead em Saída com a conversa aberta e com dono' else format('%s lead(s) em Saída ainda com pessoa ou time no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha: se o cliente ainda quer seguir, Reabrir; senão "Devolver para a Mari". Se voltar a acontecer, avisar o Claude Code.' end);

  -- 18. 0228 — mensagem automática com a conversa assumida por uma pessoa (pela fila do NIOGEN, na voz da Mari, ou a Mari
  -- respondendo o cliente), nas últimas 24 h. "Assumida" = a última ação de pessoa feita pelo NIOGEN foi atribuir.
  select count(*), string_agg(distinct nome, ', ') into n, ex from (
    select c.nome_contato as nome from public.chatwoot_acoes a join public.mari_conversas c on c.id = a.conversa_id
     where a.tipo = 'mensagem' and a.status = 'feita' and a.criada_em > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')
       and coalesce(a.payload ->> 'como', '') <> 'humano' and coalesce(c.telefone, '') not like '5500000000%'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < a.criada_em order by b.criada_em desc limit 1) = 'atribuir'
    union all
    select c.nome_contato from public.mari_turnos t join public.mari_conversas c on c.id = t.conversa_id
     where t.papel = 'mari' and t.created_at > greatest(now() - interval '24 hours', timestamptz '2026-11-15 20:00-03')   -- correções no ar desde 15/11 ~20h and coalesce(c.telefone, '') not like '5500000000%'
       and (select p.papel from public.mari_turnos p where p.conversa_id = t.conversa_id and p.papel <> 'sistema' and p.created_at < t.created_at
              order by p.created_at desc limit 1) = 'lead'
       and (select b.tipo from public.chatwoot_acoes b where b.conversa_id = t.conversa_id and b.status = 'feita' and b.payload ? 'assignee_id'
              and b.tipo in ('atribuir', 'desatribuir') and b.criada_em < t.created_at order by b.criada_em desc limit 1) = 'atribuir') x;
  it := it || jsonb_build_object('codigo', 'msg_auto_assumida', 'nome', 'Nada automático fala por cima de quem assumiu',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma mensagem automática com a conversa assumida nas últimas 24 h' else format('%s mensagem(ns) automática(s) com a conversa assumida: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code (guard da Mari ou botão sem o "em nome da pessoa"). Ver a conversa e, se precisar, corrigir com o cliente.' end);

  -- 19. 0228 — o banco diz "pessoa/time atribuído" e o Chatwoot diz sem dono (a 0227 espelha; isto acha o que escapar)
  select count(*), string_agg(coalesce(c.nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas c
   where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%' and c.chatwoot_sync_em < now() - interval '10 minutes'
     and ((c.humano_atribuido and c.chatwoot_agente is null) or (c.time_atribuido and c.chatwoot_time is null and c.chatwoot_agente is null))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir' and a.status in ('pendente', 'executando'));
  it := it || jsonb_build_object('codigo', 'dono_banco_chatwoot', 'nome', 'Dono no NIOGEN = dono no Chatwoot',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todo dono no banco também está no Chatwoot' else format('%s conversa(s) com dono no banco e sem dono no Chatwoot: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o espelho do Chatwoot (0227) deixou passar. Enquanto isso a cadência dessas conversas fica parada.' end);

  -- 20. 0233 — unidade a confirmar: a unidade do cliente não está na lista da Nio e ninguém resolveu em 4 h
  select count(*), string_agg(coalesce(nullif(btrim(dados ->> 'nome'), ''), nome_contato, 'sem nome'), ', ') into n, ex
    from public.mari_conversas where unidade_conferir_em is not null and unidade_conferir_em < now() - interval '4 hours';
  it := it || jsonb_build_object('codigo', 'conferir_unidade', 'nome', 'Unidade confirmada em até 4 h quando não bate com a lista da Nio',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhuma unidade por confirmar há mais de 4 h' else format('%s conversa(s) com a unidade por confirmar há mais de 4 h: %s', n, left(ex, 120)) end,
    'fazer', case when n = 0 then null else 'Live › Conferir › "Unidade a confirmar": confirmar a unidade com o cliente ou pedir o cadastro à Nio e marcar "Conferi".' end);

  -- 21. 0239 — Fila Vero (módulo desligável): a conta da fila fecha
  if to_regclass('public.fila_vero') is not null then
    select count(*) into v_tot from public.fila_vero;
    select coalesce(sum(c), 0) into v_soma from (select count(*) c from public.fila_vero group by status) x;
    select count(*) into n from public.fila_vero
     where (status in ('ja_cliente_nio') and toques > 0)
        or (status = 'opt_out' and ultimo_toque_em > (select max(e.em) from public.fila_vero_eventos e
                                                       where e.fila_id = fila_vero.id and e.para = 'opt_out'));
    select count(*) into n2 from public.fila_vero
     where status = 'enviado' and coalesce(meta_status, 'accepted') = 'accepted' and ultimo_toque_em < now() - interval '24 hours';
    it := it || jsonb_build_object('codigo', 'fila_vero', 'nome', 'Fila Vero: soma por status = total · nenhum toque proibido · status da Meta em 24 h',
      'nivel', case when v_tot <> v_soma or n > 0 then 'falha' when n2 > 0 then 'atencao' else 'ok' end, 'n', (v_tot - v_soma) + n + n2,
      'texto', format('%s na fila (status somam %s) · %s toque(s) em já cliente/opt-out · %s enviado(s) sem status da Meta há mais de 24 h',
                      v_tot, v_soma, n, n2),
      'fazer', case when v_tot <> v_soma or n > 0 then 'Avisar o Claude Code: a fila da Vero tocou quem não podia ou perdeu linha.'
                    when n2 > 0 then 'Conferir o webhook do número do disparo (n8n fila_vero_webhook).' else null end);
    -- 0242: cota do dia e apto parado com o disparo ligado
    select count(*) into n from public.contatos_cliente where toque = 'fila_vero' and direcao = 'saida'
       and (em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
    n2 := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'fila_vero_ritmo_dia'), 100);
    it := it || jsonb_build_object('codigo', 'fila_vero_cota', 'nome', 'Fila Vero: envios de hoje dentro do ritmo do dia',
      'nivel', case when n <= n2 then 'ok' else 'falha' end, 'n', greatest(0, n - n2),
      'texto', format('%s envio(s) hoje · ritmo %s/dia', n, n2),
      'fazer', case when n <= n2 then null else 'Pausar a Fila Vero na tela e avisar o Claude Code.' end);
    select count(*) into n from public.fila_vero where status = 'apto' and atualizado_em < now() - interval '7 days'
       and coalesce((select (valor #>> '{}')::boolean from public.config_regras where chave = 'fila_vero_ativo'), false);
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_apto_parado', 'nome', 'Fila Vero: apto parado há mais de 7 dias com o disparo ligado',
        'nivel', 'atencao', 'n', n, 'texto', format('%s apto(s) esperando há mais de 7 dias', n),
        'fazer', 'Ver na tela Fila Vero se o ritmo está baixo ou se a faixa B está fora do disparo.');
    end if;
    select count(*) into n from public.fila_vero where status = 'respondeu' and conversa_id is null;
    if n > 0 then
      it := it || jsonb_build_object('codigo', 'fila_vero_sem_conversa', 'nome', 'Fila Vero: quem respondeu tem conversa na Mari',
        'nivel', 'falha', 'n', n, 'texto', format('%s resposta(s) sem conversa ligada', n),
        'fazer', 'Avisar o Claude Code (gatilho mari_turnos_fila_vero).');
    end if;
  end if;


  -- 22. 0302 — origem conhecida: lead das últimas 24 h com a origem desconhecida (dono: backoffice; sai quando a origem é corrigida)
  select count(*), string_agg(coalesce(nullif(btrim(c.dados ->> 'nome'), ''), c.nome_contato, 'sem nome'), ', ' order by c.created_at desc) into n, ex
    from public.mari_conversas c
   where c.origem = 'desconhecida' and c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
     and coalesce(c.funil_destino, '') <> 'teste_duplicada' and c.created_at > now() - interval '24 hours';
  it := it || jsonb_build_object('codigo', 'origem_desconhecida', 'nome', 'Todo lead novo tem a origem conhecida (últimas 24 h)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'nenhum lead das últimas 24 h com a origem desconhecida'
                  else format('%s lead(s) das últimas 24 h sem origem: %s', n, left(ex, 160)) end,
    'fazer', case when n = 0 then null else 'Backoffice: perguntar ao cliente por onde chegou e corrigir em Configurações › Canais › Origem a conferir.' end);

  -- 23. 0302 — o card "Canais" fecha com a v_margem_canal (vendas por origem, desde sempre)
  select count(*), string_agg(format('%s: card %s × margem %s', coalesce(m.origem, '(sem origem)'), coalesce(r.vendas, 0), m.vendas), ' · ') into n, ex
    from public.v_margem_canal m
    left join public.canais_resumo(3650) r on r.canal = m.origem
   where coalesce(r.vendas, 0) <> m.vendas;
  it := it || jsonb_build_object('codigo', 'canais_conta', 'nome', 'Card Canais = v_margem_canal (vendas por origem)',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'as vendas por canal do card batem com a margem por canal' else left(ex, 200) end,
    'fazer', case when n = 0 then null else 'Avisar o Claude Code: o card Canais e a v_margem_canal contam diferente (é defeito).' end);

  -- 24. 0303 — pedido de indicação: nenhum aberto além da validade (a rotina indicacao_rotina fecha)
  if to_regclass('public.indicacao_pedidos') is not null then
    select count(*) into n from public.indicacao_pedidos where estado = 'pediu' and pedido_em < now() - interval '8 days';
    select count(*) into n2 from public.indicacao_pedidos where pedido_em > now() - interval '7 days';
    select count(*) into v_tot from public.indicacoes where criado_em > now() - interval '7 days' and estado <> 'invalida';
    it := it || jsonb_build_object('codigo', 'indicacao_pedidos', 'nome', 'Pedido de indicação: nenhum aberto além da validade',
      'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
      'texto', format('%s pedido(s) de indicação em 7 dias · %s indicação(ões) recebida(s) · %s aberto(s) além da validade', n2, v_tot, n),
      'fazer', case when n = 0 then null else 'Avisar o Claude Code: a rotina indicacao_rotina não fechou os pedidos vencidos.' end);
  end if;

  -- 25. 0330 — crédito num lugar só: a venda diz o mesmo que a conversa (o espelho grava os dois; divergência = alguém precisa olhar:
  -- "aprovado" do botão sobre o "só cartão" lido pelo operador, venda com aviso de recompra esperando a conferência, erro do espelho)
  select count(*), string_agg(format('%s (venda %s × portal %s)', coalesce(nullif(btrim(v.cliente_nome), ''), 'sem nome'), v.credito_resultado,
           c.credito_resultado), ', ' order by v.criado_em desc) into n, ex
    from public.vendas v
    join lateral (select * from public.mari_conversas mc where mc.venda_id = v.id order by mc.created_at desc limit 1) c on true
   where v.status not in ('saida')
     and public._credito_categoria(c.credito_resultado) is not null
     and v.credito_resultado is distinct from public._credito_categoria(c.credito_resultado);
  it := it || jsonb_build_object('codigo', 'credito_um_lugar', 'nome', 'Crédito da venda = crédito lido do portal',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'toda venda em andamento com o mesmo crédito da conversa' else left(format('%s venda(s) com o crédito diferente: %s', n, ex), 240) end,
    'fazer', case when n = 0 then null else 'Abrir a ficha › Crédito: conferir no portal e Corrigir com o motivo (vale a leitura mais nova do portal).' end);

  -- 26. 0330 — correções do crédito à mão (7 dias): muitas "o robô leu errado" = conserto no robô, não mais cliques
  select count(*), count(*) filter (where e.detalhe ->> 'motivo' = 'robo_errou') into n, n2
    from public.eventos_venda e where e.tipo = 'credito_corrigido' and e.criado_em > now() - interval '7 days';
  it := it || jsonb_build_object('codigo', 'credito_corrigido', 'nome', 'Correções do crédito à mão (7 dias)',
    'nivel', case when n2 >= 2 then 'atencao' else 'ok' end, 'n', n2,
    'texto', format('%s correção(ões) em 7 dias · %s por "o robô leu errado"', n, n2),
    'fazer', case when n2 >= 2 then 'Avisar o Claude Code: o operador de crédito leu errado mais de uma vez na semana.' else null end);

  -- 27. 0339 — leitura do atendimento pelas mensagens (v_atendimento_fatos): o cliente escreveu por último e ninguém respondeu.
  -- É a ÚNICA prova de falha de atendimento. Conta só lead em andamento, há mais de 15 min (a Mari responde em segundos).
  select count(*), string_agg(format('%s (%s min)', coalesce(nullif(btrim(f.nome), ''), 'sem nome'), f.esperando_nos_min), ', ' order by f.esperando_nos_min desc)
    into n, ex
    from public.v_atendimento_fatos f where f.caixa = 'esperando_nos' and f.esperando_nos_min > 15;
  it := it || jsonb_build_object('codigo', 'esperando_nos', 'nome', 'Ninguém esperando resposta nossa (pelas mensagens)',
    'nivel', case when n = 0 then 'ok' else 'falha' end, 'n', n,
    'texto', case when n = 0 then 'todo cliente que escreveu foi respondido (mensagem a mensagem)'
                  else left(format('%s cliente(s) escreveram por último e estão sem resposta: %s', n, ex), 240) end,
    'fazer', case when n = 0 then null else 'Abrir a conversa e responder agora. Se a Mari deveria ter respondido, avisar o Claude Code.' end);

  -- 28. 0339 — calado e esquecido: em andamento, sem venda, cliente calado há mais de 24 h, sem toque marcado, sem Retomada,
  -- sem dono e sem espera. Pela regra 20 não pode existir. Complementa o 'lead_em_silencio' (que lê pela vez).
  select count(*), string_agg(coalesce(nullif(btrim(f.nome), ''), 'sem nome'), ', ' order by f.ult_cliente_em desc nulls last) into n, ex
    from public.v_atendimento_fatos f where f.caixa = 'calado_esquecido';
  it := it || jsonb_build_object('codigo', 'calado_esquecido', 'nome', 'Ninguém calado sem cadência (pelas mensagens)',
    'nivel', case when n = 0 then 'ok' else 'atencao' end, 'n', n,
    'texto', case when n = 0 then 'todo cliente calado tem cadência, Retomada, dono ou espera'
                  else left(format('%s lead(s) calado(s) sem nenhum próximo toque: %s', n, ex), 240) end,
    'fazer', case when n = 0 then null else 'Abrir na Live e dar saída, esquentar (🔥) ou assumir. Se a cadência deveria ter marcado o toque, avisar o Claude Code.' end);

  return it;
end;
$function$
;

commit;
