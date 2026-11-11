-- NIOGEN | supabase/migrations/0120_live_sem_bio_sem_venda.sql | 10/11/2026 — Claude Code
-- Live: "Biometria sem venda" sai da Live (sem nome nem venda, a única ação era "Visto"; a causa é pedido feito direto no portal, sem venda no NIOGEN).
-- A pendência real continua: "casar pedido" (pedido de Venda do portal sem venda). Biometria sem venda vira lista de Conciliação (v_bio_sem_venda_conciliar).

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
  WHERE p.venda_id IS NULL AND p.tipo = 'VENDA'::text;

-- v_andamento_resumo.bio_sem_venda (alerta + não visto) fica como está; o Painel deixou de exibi-lo (painel.html).

-- Conciliação: biometria do GED360 que não casou com venda do NIOGEN (venda feita direto no portal = possível comissão não conciliada).
create or replace view public.v_bio_sem_venda_conciliar with (security_invoker = true) as
select b.protocolo, b.cpf_cnpj, b.resultado, coalesce(c.rotulo, b.resultado) as rotulo,
       b.data_envio, b.data_conferencia, b.alerta
  from public.nio_biometria b
  left join public.config_biometria_resultado c on c.parceiro_id = b.parceiro_id and c.resultado = b.resultado
 where b.venda_id is null and b.data_envio > now() - interval '30 days';
grant select on public.v_bio_sem_venda_conciliar to authenticated;
