-- NIOGEN | supabase/migrations/0134_mari_interativo_feriados.sql | 12/11/2026 — Claude Code
-- Ricardo, 12/11: a Mari pergunta a preferência de DATA da instalação em botões (D+1, D+2, D+3). Sem domingo e sem feriado:
-- mari_config_interativo() (nó 4c da Mari, já lido a cada turno) ganha 'feriados' dos próximos 30 dias (nacionais e municipais,
-- com a cidade — o 7 · Extrair filtra pela cidade da conversa).
create or replace function public.mari_config_interativo()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'cartoes', coalesce((select jsonb_agg(jsonb_build_object(
        'ordem', k.ordem, 'plano_codigo', k.plano_codigo, 'imagem_url', k.imagem_url, 'texto_card', k.texto_card,
        'texto_detalhes', k.texto_detalhes, 'titulo_quero', k.titulo_quero, 'titulo_detalhes', k.titulo_detalhes,
        'preco', p.preco, 'preco_cartao', p.preco_cartao, 'nome', p.nome, 'nome_curto', p.nome_curto) order by k.ordem)
      from public.config_mari_carrossel k join public.config_planos p on p.codigo = k.plano_codigo
      where k.ativo), '[]'::jsonb),
    'textos', coalesce((select jsonb_object_agg(chave, texto) from public.config_mari_textos), '{}'::jsonb),
    'feriados', coalesce((select jsonb_agg(jsonb_build_object('data', f.data, 'cidade', f.cidade) order by f.data)
      from public.config_feriados f
      where f.data between (now() at time zone 'America/Sao_Paulo')::date and (now() at time zone 'America/Sao_Paulo')::date + 30), '[]'::jsonb));
$$;
revoke all on function public.mari_config_interativo() from public, anon, authenticated;
grant execute on function public.mari_config_interativo() to service_role;
