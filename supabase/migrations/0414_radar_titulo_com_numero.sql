-- NIOGEN | supabase/migrations/0414_radar_titulo_com_numero.sql | 26/11/2026 — Claude Code / Opus 5.5
-- Resumo: conserto do Radar Nio (0413), achado na 1ª rodada real (26/11 ~05h50). O gráfico é achado pelo título, e o título de
-- alguns cartões traz o próprio número ("% Eficácia 100,0%"); por isso a 0413 aceitava "título + espaço + qualquer coisa". Só que
-- "VB - Mensal" também casava com "VB - Mensal DU" (vendas por dia útil) e o VB do mês podia sair 1 em vez de 7. Agora o que
-- vem depois do título só vale se for número ("100,0%"). Só _radar_indicadores muda (e ganha um índice por gráfico: com um ano de leituras são ~20 mil linhas e a
-- tela procura 26 gráficos — regra 19); tabela, tela e n8n ficam iguais.
begin;

create index if not exists nio_radar_leituras_visual on public.nio_radar_leituras (parceiro_id, aba, visual, dia desc);

create or replace function public._radar_indicadores(p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_de date := p_de; v_ate date := p_ate; m_de text := to_char(p_de, 'YYYYMM'); m_ate text := to_char(p_ate, 'YYYYMM'); v_ind jsonb;
begin
  -- série por ANOMES: série por ANOMES (dentro do período) ou pelos dias de leitura (texto)
  select coalesce(jsonb_agg(x order by (x ->> 'ordem')::int), '[]'::jsonb) into v_ind from (
    select jsonb_build_object('chave', c.chave, 'grupo', c.grupo, 'nome', c.nome, 'formato', c.formato, 'direcao', c.direcao,
             'peso_bko', c.peso_bko, 'alarme', c.alarme, 'ordem', c.ordem, 'ajuda', c.ajuda, 'aba', c.aba, 'visual', c.visual,
             'serie', s.serie, 'valor', s.serie -> -1 -> 'v', 'ref', s.serie -> -1 -> 'x', 'lido', s.lido) as x
      from public.config_radar_indicadores c
      cross join lateral (
        select case when c.coluna is not null then (
                 select jsonb_build_object('lido', u.dia, 'serie', coalesce((
                          select jsonb_agg(jsonb_build_object('x', l ->> im, 'v', (l ->> iv)::numeric) order by l ->> im)
                            from jsonb_array_elements(u.linhas) l
                           where (l ->> iv) ~ '^-?[\d.eE+-]+$'
                             and (im is null or (l ->> im) between m_de and m_ate)), '[]'::jsonb))
                   from (select r.dia, r.linhas,
                                (select (o - 1)::int from jsonb_array_elements_text(r.colunas) with ordinality k(v, o) where k.v = 'ANOMES') as im,
                                (select (o - 1)::int from jsonb_array_elements_text(r.colunas) with ordinality k(v, o) where k.v = c.coluna) as iv
                           from public.nio_radar_leituras r
                          where r.parceiro_id = 'dharma' and r.aba = c.aba and (r.visual = c.visual or (left(r.visual, length(c.visual) + 1) = c.visual || ' ' and substr(r.visual, length(c.visual) + 2) ~ '^[0-9.,% ]+$')) and r.dia <= v_ate and r.erro is null
                          order by r.dia desc limit 1) u
                  where u.iv is not null)
               else (
                 select jsonb_build_object('lido', max(r.dia), 'serie', coalesce(jsonb_agg(jsonb_build_object('x', to_char(r.dia, 'YYYY-MM-DD'),
                          'v', public._radar_num(substring(r.texto from c.padrao)) * c.fator) order by r.dia)
                          filter (where public._radar_num(substring(r.texto from c.padrao)) is not null), '[]'::jsonb))
                   from public.nio_radar_leituras r
                  where r.parceiro_id = 'dharma' and r.aba = c.aba and (r.visual = c.visual or (left(r.visual, length(c.visual) + 1) = c.visual || ' ' and substr(r.visual, length(c.visual) + 2) ~ '^[0-9.,% ]+$')) and r.dia between v_de and v_ate and r.erro is null)
               end as j) jj
      cross join lateral (select jj.j -> 'serie' as serie, jj.j -> 'lido' as lido) s
     where c.ativo and c.parceiro_id = 'dharma') q;

  return v_ind;
end $$;
revoke all on function public._radar_indicadores(date, date) from public, anon, authenticated;

commit;
