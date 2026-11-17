-- NIOGEN | supabase/migrations/0243_fila_vero_painel_na_mari.sql | 16/11/2026 — Claude Code / Opus 5.5
-- Tela Fila Vero: lista de quem falou com a Mari (Ricardo, 16/11: "Quem são esses clientes? Não estou vendo no Niogen").
-- fila_vero_painel() ganha na_mari_lista (nome, template, quando, etapa, destino, conversa) — a tela abre a conversa.
CREATE OR REPLACE FUNCTION public.fila_vero_painel()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with f as (select fv.*, c.funil_etapa, c.venda_id as cvenda from public.fila_vero fv left join public.mari_conversas c on c.id = fv.conversa_id),
  v as (select f.template1, f.faixa, vd.status, vd.comissao_prevista from f join public.vendas vd on vd.id = coalesce(f.venda_id, f.cvenda)),
  tp as (select template1 t, count(*) enviados, count(entregue_em) entregues, count(lido_em) lidos, count(clicou_em) cliques,
                count(conversa_id) na_mari, count(*) filter (where status = 'opt_out') opt_out,
                count(*) filter (where funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')) qualificados
           from f where template1 is not null group by 1),
  fx as (select faixa, count(*) filter (where status = 'apto') aptos, count(*) filter (where toques > 0) enviados, count(entregue_em) entregues,
                count(clicou_em) cliques, count(conversa_id) na_mari, count(*) filter (where status = 'opt_out' and toques > 0) opt_out
           from f where faixa is not null group by 1)
  select jsonb_build_object(
    'ativo', coalesce((public._fv_cfg('fila_vero_ativo') #>> '{}')::boolean, false),
    'dentro_horario', public.fila_vero_dentro_horario(),
    'ritmo', coalesce((public._fv_cfg('fila_vero_ritmo_dia') #>> '{}')::int, 100),
    'hoje', public._fv_enviados_hoje(),
    'rampa', public._fv_cfg('fila_vero_rampa'),
    'ab', public._fv_cfg('fila_vero_ab'),
    'qualidade', public._fv_cfg('fila_vero_qualidade'),
    'prioridade_b', public._fv_cfg('fila_vero_prioridade_b'),
    'hist', public._fv_cfg('fila_vero_ativo_hist'),
    'base', (select count(*) from f),
    'por_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from f group by 1) s),
    'enviados', (select count(*) from f where toques > 0),
    'segundo_toque', (select count(*) from f where toques >= 2),
    'entregues', (select count(entregue_em) from f),
    'lidos', (select count(lido_em) from f),
    'cliques', (select count(clicou_em) from f),
    'na_mari', (select count(conversa_id) from f),
    'qualificados', (select count(*) from f where funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')),
    'pedidos', (select count(*) from f where funil_etapa in ('pedido', 'biometria', 'agendada', 'instalada')),
    'instaladas', (select count(*) from v where status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')),
    'comissao', (select coalesce(sum(comissao_prevista), 0) from v where status <> 'saida'),
    'opt_out', (select count(*) from f where status = 'opt_out' and toques > 0),
    'por_template', (select coalesce(jsonb_object_agg(t, to_jsonb(tp) - 't'), '{}'::jsonb) from tp),
    'por_faixa', (select coalesce(jsonb_object_agg(faixa, to_jsonb(fx) - 'faixa'), '{}'::jsonb) from fx),
    'falhas', (select coalesce(jsonb_object_agg(coalesce(erro_codigo, '?'), n), '{}'::jsonb) from (select erro_codigo, count(*) n from f where erro_codigo is not null group by 1) e),
    'clicou_sem_mari', (select coalesce(jsonb_agg(x order by x ->> 'clicou_em' desc), '[]'::jsonb) from (
        select jsonb_build_object('id', id, 'nome', initcap(lower(split_part(btrim(coalesce(nome, '')), ' ', 1))), 'telefone', telefone,
                                  'template', template1, 'clicou_em', clicou_em, 'lugar', lugar) x
          from f where clicou_em is not null and conversa_id is null and clicou_em < now() - interval '2 hours'
           and status not in ('opt_out', 'ja_cliente_nio') order by clicou_em desc limit 30) c),
    'na_mari_lista', (select coalesce(jsonb_agg(x order by x ->> 'em' desc), '[]'::jsonb) from (
        select jsonb_build_object('conversa_id', f.conversa_id, 'nome', coalesce(nullif(split_part(btrim(c.nome_contato), ' ', 1), ''), initcap(lower(split_part(btrim(coalesce(f.nome, '')), ' ', 1)))),
                                  'template', f.template1, 'em', f.respondeu_em, 'etapa', c.funil_etapa, 'destino', c.funil_destino,
                                  'chatwoot', c.chatwoot_conversation_id, 'lugar', f.lugar) x
          from f join public.mari_conversas c on c.id = f.conversa_id order by f.respondeu_em desc nulls last limit 50) m),
    'em', now())
  where public.meu_perfil() in ('admin', 'backoffice') or session_user <> 'authenticator';
$function$;
