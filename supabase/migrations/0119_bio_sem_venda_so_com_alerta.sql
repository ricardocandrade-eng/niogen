-- NIOGEN | supabase/migrations/0119_bio_sem_venda_so_com_alerta.sql | 10/11/2026 — Claude Code
-- Live: a 1ª carga real do GED360 (10/11 22h30) jogou 182 "Biometria sem venda" de uma vez (pedidos feitos direto no portal, sem venda no NIOGEN).
-- Só 10 tinham alerta (link expirado, risco, neutro). Passa a listar só biometria sem venda COM alerta; as demais seguem na tabela/contagem por resultado.
-- As 172 sem alerta ficam marcadas como vistas (alerta_visto_em) — não voltam se o filtro mudar.

update public.nio_biometria
   set alerta_visto_em = now()
 where venda_id is null and alerta is null and alerta_visto_em is null;

create or replace view public.v_andamento_pendencias with (security_invoker=true) as
 SELECT 'casar_pedido'::text AS tipo,
    p.pedido_nio AS chave,
    p.cliente_nome AS nome,
    p.status,
    COALESCE(c.rotulo, p.status) AS rotulo,
    p.oferta,
    p.data_pedido AS quando,
    p.primeira_leitura AS desde,
    p.alerta,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('venda_id', s.id, 'nome', s.cliente_nome, 'pedido', s.nio_pedido, 'cidade', s.cidade, 'etapa', s.etapa)) AS jsonb_agg
           FROM ( SELECT v.id,
                    v.cliente_nome,
                    v.nio_pedido,
                    v.cidade,
                    jornada_nome(jornada_etapa(v.status, v.nio_pedido, v.credito_resultado)) AS etapa
                   FROM vendas v
                  WHERE v.status <> 'saida'::text AND NOT (EXISTS ( SELECT 1
                           FROM portal_pedidos x
                          WHERE x.venda_id = v.id AND x.tipo = 'VENDA'::text)) AND (_nome_norm(v.cliente_nome) = _nome_norm(p.cliente_nome) OR split_part(_nome_norm(v.cliente_nome), ' '::text, 1) = split_part(_nome_norm(p.cliente_nome), ' '::text, 1) AND regexp_replace(_nome_norm(v.cliente_nome), '^.* '::text, ''::text) = regexp_replace(_nome_norm(p.cliente_nome), '^.* '::text, ''::text))
                  ORDER BY v.criado_em DESC
                 LIMIT 3) s), '[]'::jsonb) AS sugestoes
   FROM portal_pedidos p
     LEFT JOIN config_portal_status c ON c.parceiro_id = p.parceiro_id AND c.status = p.status
  WHERE p.venda_id IS NULL AND p.tipo = 'VENDA'::text
UNION ALL
 SELECT 'biometria_sem_venda'::text AS tipo,
    b.protocolo AS chave,
    NULL::text AS nome,
    b.resultado AS status,
    COALESCE(c.rotulo, b.resultado) AS rotulo,
    NULL::text AS oferta,
    b.data_envio AS quando,
    b.primeira_leitura AS desde,
    b.alerta,
    '[]'::jsonb AS sugestoes
   FROM nio_biometria b
     LEFT JOIN config_biometria_resultado c ON c.parceiro_id = b.parceiro_id AND c.resultado = b.resultado
  WHERE b.venda_id IS NULL AND b.data_envio > (now() - '30 days'::interval)
    AND b.alerta_visto_em IS NULL AND b.alerta IS NOT NULL;

-- Contador do Painel acompanha o mesmo critério.
create or replace view public.v_andamento_resumo with (security_invoker = true) as
select
  (select coalesce(jsonb_object_agg(coalesce(c.rotulo, x.status), x.n), '{}'::jsonb)
     from (select status, count(*) n from public.portal_pedidos where tipo = 'VENDA' group by 1) x
     left join public.config_portal_status c on c.parceiro_id = 'dharma' and c.status = x.status) as por_status_portal,
  (select coalesce(jsonb_object_agg(coalesce(c.rotulo, x.resultado), x.n), '{}'::jsonb)
     from (select resultado, count(*) n from public.nio_biometria where data_envio > now() - interval '30 days' group by 1) x
     left join public.config_biometria_resultado c on c.parceiro_id = 'dharma' and c.resultado = x.resultado) as por_resultado_bio,
  (select max(lida_em) from public.portal_leituras where completa) as portal_ultima_leitura,
  (select max(lida_em) from public.ged360_leituras where ok) as ged360_ultima_ok,
  (select count(*) from (select ok from public.ged360_leituras order by id desc limit 2) z where not z.ok) as ged360_falhas_seguidas,
  (select erro from public.ged360_leituras order by id desc limit 1) as ged360_ultimo_erro,
  (select max(lida_em) from public.ged360_leituras) as ged360_ultima_tentativa,
  (select count(*) from public.portal_pedidos where venda_id is null and tipo = 'VENDA') as casar_pedido,
  (select count(*) from public.nio_biometria where venda_id is null and alerta is not null and data_envio > now() - interval '30 days' and alerta_visto_em is null) as bio_sem_venda,
  (select count(*) from public.nio_biometria where desconhecido) as bio_desconhecidos;
grant select on public.v_andamento_resumo to authenticated;
