-- id: X158
-- titulo: 0436 (Ricardo, 27/11: "Pode seguir com a oportunidades_abertas"): a lista de oportunidades 🔥 levava ~2 s porque a view lia o quadro da Mari COM a cadência (o motor avaliando todas as conversas) sem usar nenhuma coluna dela — passa a ler o quadro sem cadência (o da jornada, 0354); as colunas usadas são as mesmas nas duas views e a oportunidade continua aparecendo
-- tipo: atual

-- 1) a forma: a v_oportunidades não passa mais pela cadência
select sim.confere('a v_oportunidades lê a v_mari_quadro_jornada, não a v_mari_quadro',
  pg_get_viewdef('public.v_oportunidades'::regclass, true) ~ 'FROM v_mari_quadro_jornada q'
  and pg_get_viewdef('public.v_oportunidades'::regclass, true) !~ 'v_mari_quadro\M(?!_jornada)',
  'ainda lê a v_mari_quadro (com a cadência)');
select sim.confere('a v_oportunidades continua lendo como quem chama (security_invoker)',
  (select coalesce(c.reloptions::text, '') ~ 'security_invoker=true' from pg_class c where c.oid = 'public.v_oportunidades'::regclass),
  (select coalesce(c.reloptions::text, 'sem opções') from pg_class c where c.oid = 'public.v_oportunidades'::regclass));

-- 2) uma oportunidade de verdade continua aparecendo (o mesmo caso do X11: interesse caindo fica com a Mari e vira 🔥 O10)
select sim.lead_novo('Gil X158') as c \gset
select sim.mari_handoff(:'c', 'interesse_caindo');
select sim.fila_rodar();
select sim.mari_fala(:'c', 'Fico por aqui se precisar de algo 😊');
select sim.espera(:'c', '30 minutes');
select sim.como('backoffice');
select sim.confere('interesse caindo aparece como oportunidade 🔥 (O10)',
  exists (select 1 from public.oportunidades_abertas() o where o.conversa_id = :'c' and 'O10' = any (o.regras)),
  coalesce((select string_agg(o.codigo || ':' || o.motivo, ' | ') from public.oportunidades_abertas() o where o.conversa_id = :'c'), 'não apareceu'));

-- 3) a trava contra o afastamento: as colunas que a v_oportunidades usa do quadro são iguais nas duas views, linha a linha
--    (a v_mari_quadro_jornada é cópia da v_mari_quadro sem a cadência — quem mexer numa tem de mexer na outra)
select sim.confere('as 19 colunas usadas são idênticas na v_mari_quadro e na v_mari_quadro_jornada',
  not exists (
    (select id, alertas, cidade, cluster, coluna, itens_total, itens_validados, nome, plano_escolhido, plano_nome, segmento, teste,
            trava_cliente_nio, trava_endereco_nio, trava_viabilidade, ultima_em, ultima_quem, venda_id, vez from public.v_mari_quadro
     except
     select id, alertas, cidade, cluster, coluna, itens_total, itens_validados, nome, plano_escolhido, plano_nome, segmento, teste,
            trava_cliente_nio, trava_endereco_nio, trava_viabilidade, ultima_em, ultima_quem, venda_id, vez from public.v_mari_quadro_jornada)
    union all
    (select id, alertas, cidade, cluster, coluna, itens_total, itens_validados, nome, plano_escolhido, plano_nome, segmento, teste,
            trava_cliente_nio, trava_endereco_nio, trava_viabilidade, ultima_em, ultima_quem, venda_id, vez from public.v_mari_quadro_jornada
     except
     select id, alertas, cidade, cluster, coluna, itens_total, itens_validados, nome, plano_escolhido, plano_nome, segmento, teste,
            trava_cliente_nio, trava_endereco_nio, trava_viabilidade, ultima_em, ultima_quem, venda_id, vez from public.v_mari_quadro)),
  'as duas views do quadro se afastaram nas colunas que as oportunidades usam');
select sim.confere('e as duas têm as mesmas conversas',
  (select count(*) from public.v_mari_quadro) = (select count(*) from public.v_mari_quadro_jornada),
  (select count(*)::text from public.v_mari_quadro) || ' × ' || (select count(*)::text from public.v_mari_quadro_jornada));
