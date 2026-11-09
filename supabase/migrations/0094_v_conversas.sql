-- NIOGEN | supabase/migrations/0094_v_conversas.sql | 09/11/2026 — Claude Code
-- Ricardo (09/11 ~19h40): "abaixo de Minha vez precisa ter uma tela Conversas, listando todas as conversas, como se fosse o
-- Chatwoot. Tá difícil ter que ir atrás do cliente para falar com ele quando preciso."
-- v_conversas (security_invoker — só quem lê mari_conversas, admin/backoffice): uma linha por conversa do WhatsApp com a última
-- mensagem (de quem e o começo do texto), se o cliente está esperando resposta e há quantos minutos, janela de 24 h, dono (a mesma
-- ordem da v_jornada, 0091), etiquetas, etapa da jornada e se está encerrada. A tela conversas.html lê dela; a conversa aberta é o
-- mesmo componente da Minha vez (assets/conversa.js).

create or replace view public.v_conversas with (security_invoker = true) as
select c.id, c.venda_id,
       coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
       c.telefone, c.cidade, c.origem, c.chatwoot_conversation_id, c.chatwoot_status,
       coalesce(c.chatwoot_etiquetas, '{}') as etiquetas,
       case when coalesce(c.nao_contatar, false) then null
            when c.chatwoot_agente is not null then 'pessoa'
            when coalesce(c.humano_atribuido, false) then 'pessoa'
            when c.chatwoot_status = 'resolved' then null
            when c.chatwoot_time is not null then 'time'
            else 'mari' end as dono_tipo,
       case when coalesce(c.nao_contatar, false) then null
            when c.chatwoot_agente is not null then c.chatwoot_agente
            when coalesce(c.humano_atribuido, false) then 'time (assumida)'
            when c.chatwoot_status = 'resolved' then null
            when c.chatwoot_time is not null then 'time ' || c.chatwoot_time
            else 'Mari' end as dono_nome,
       coalesce(u.created_at, c.created_at) as ultima_em,
       u.papel as ultima_quem,
       left(regexp_replace(coalesce(u.texto, ''), '\s+', ' ', 'g'), 160) as ultima_txt,
       (l.ult_lead is not null and l.ult_lead > coalesce(l.ult_resp, '-infinity'::timestamptz) and l.ult_lead > now() - interval '7 days') as cliente_esperando,
       case when l.ult_lead is not null and l.ult_lead > coalesce(l.ult_resp, '-infinity'::timestamptz)
            then floor(extract(epoch from now() - l.ult_lead) / 60)::int end as esperando_min,
       l.ult_lead,
       (l.ult_lead is not null and l.ult_lead > now() - interval '23 hours') as janela_aberta,
       case when v.id is not null then public.jornada_etapa(v.status, v.nio_pedido) else 1 end as etapa,
       (coalesce(c.nao_contatar, false) or c.status in ('encerrado_humano', 'encerrado_ia') or coalesce(v.status, '') = 'saida') as encerrada,
       c.created_at,
       'dharma'::text as parceiro_id
  from public.mari_conversas c
  left join public.vendas v on v.id = c.venda_id
  cross join lateral (
    select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
           max(t.created_at) filter (where t.papel in ('mari', 'humano')) as ult_resp
      from public.mari_turnos t where t.conversa_id = c.id) l
  left join lateral (
    select t.papel, t.texto, t.created_at from public.mari_turnos t
     where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')
     order by t.created_at desc limit 1) u on true
 where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%';

comment on view public.v_conversas is '0094: lista de conversas do WhatsApp para a tela Conversas (última mensagem, cliente esperando, dono, etapa).';
grant select on public.v_conversas to authenticated;
