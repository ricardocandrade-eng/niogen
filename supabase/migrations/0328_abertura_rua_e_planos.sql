-- NIOGEN | supabase/migrations/0328_abertura_rua_e_planos.sql | 19/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 19/11 ~23h–0h, sobre a abertura B3 (0326): "o 'Ver os planos' tem um problema: a Mari não apresenta os planos… Eu, como
-- cliente, quero ver os planos quando me dá a opção" · "não gosto muito desse 'Ver minha rua'. Soa estranho" · "Não sei se seria melhor
-- perguntar a cidade e não o CEP (que nem sempre o lead sabe)" → "Sim, faz pela cidade".
--   · abertura_botao_rua: "📍 Ver minha rua" → "📍 Tem na minha rua?" (≤ 20 caracteres). O 5 · Motor segue reconhecendo o antigo.
--   · "💰 Ver os planos" antes do CEP → a Mari pergunta a CIDADE (abertura_resp_planos_cidade). A resposta que traz uma cidade atendida
--     (config_area) mostra os planos com o preço DELA: cidade regular → o carrossel (trava de preço de sempre); cidade BTU → a lista em
--     texto, preço único (config_planos, varejo, sem a variante "sem fidelidade", os 4 mais baratos — igual à lista do 7 · Extrair).
--     No fim, o pedido do CEP (a cobertura é da rua; abertura_planos_cidade_cep). Cidade não reconhecida → o Claude segue.
--     Desliga sem deploy: abertura_planos_cidade = 'nao' (volta a pedir o CEP, abertura_resp_planos).
--   · mari_config_interativo (nó 4c) passa a devolver 'cidades' (cidade + cluster de config_area) e 'planos_cidade' (varejo por cluster).
-- Código: n8n/mari/n05b_motor.js (mari_principal), publicado DEPOIS desta migration (o código lê as chaves novas; sem elas, cai no
-- pedido do CEP de antes). O título novo do botão também só é reconhecido pelo código novo — a migration e o deploy sobem juntos.
-- Regra 1: preço só da tabela vigente e da cidade que o cliente disse; cobertura nunca prometida (o CEP vem depois).
-- Regra 20: sem estado novo (dados.abertura_pediu_cidade e dados.planos_cidade são marcas da conversa, sem situação, vez ou prazo);
-- nenhuma gravação de status; fonte: config_area e config_planos; não cria número novo. Desempenho: +2 subconsultas pequenas no 4c
-- (38 cidades, ~8 planos), sem impacto em tela. Medir em 7 dias: das aberturas b3 com toque em "Ver os planos", % que diz a cidade,
-- % que vê os planos e % que dá o CEP depois (B2 com "Ver os planos" → CEP: 26/28).

begin;

-- antes: '📍 Ver minha rua'
update public.config_mari_textos set texto = '📍 Tem na minha rua?' where chave = 'abertura_botao_rua';

insert into public.config_mari_textos (chave, texto) values
('abertura_planos_cidade', 'sim'),
('abertura_resp_planos_cidade', $t$Claro! 😊 Me diz a sua cidade que eu já te mostro os planos com o preço certinho daí 👇$t$),
('abertura_planos_cidade_cep', $t$Pra ver se a fibra chega na sua rua, me manda o CEP (ou o nome da rua e o bairro) 😊$t$)
on conflict (chave) do update set texto = excluded.texto;

CREATE OR REPLACE FUNCTION public.mari_config_interativo()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      where f.data between (now() at time zone 'America/Sao_Paulo')::date and (now() at time zone 'America/Sao_Paulo')::date + 30), '[]'::jsonb),
    -- 0328: "💰 Ver os planos" pela cidade — as cidades atendidas e os planos de varejo de cada cluster (a lista do 7 · Extrair).
    'cidades', coalesce((select jsonb_agg(jsonb_build_object('cidade', x.cidade, 'cluster', x.cluster) order by x.cidade)
      from (select distinct a.cidade, a.cluster from public.config_area a where a.ativo and a.cluster is not null and coalesce(a.cidade, '') <> '') x), '[]'::jsonb),
    'planos_cidade', coalesce((select jsonb_object_agg(y.cluster, y.pls) from (
        select p.cluster, jsonb_agg(jsonb_build_object('codigo', p.codigo, 'nome', p.nome, 'nome_curto', p.nome_curto,
                 'preco', p.preco, 'preco_cartao', p.preco_cartao) order by p.preco) pls
          from public.config_planos p
         where p.ativo and p.portfolio = 'varejo' and coalesce(p.variante, '') not ilike '%nfid%'
           and (p.vigencia_fim is null or p.vigencia_fim >= current_date) and p.cluster is not null
         group by p.cluster) y), '{}'::jsonb));
$function$;
revoke all on function public.mari_config_interativo() from public, anon, authenticated;
grant execute on function public.mari_config_interativo() to service_role;

do $$
declare j jsonb := public.mari_config_interativo();
begin
  if jsonb_array_length(j -> 'cidades') < 10 then raise exception '0328: cidades não vieram (%)', jsonb_array_length(j -> 'cidades'); end if;
  if jsonb_array_length(coalesce(j -> 'planos_cidade' -> 'btu', '[]'::jsonb)) < 1 then raise exception '0328: planos BTU não vieram'; end if;
  if (select texto from public.config_mari_textos where chave = 'abertura_botao_rua') <> '📍 Tem na minha rua?' then
    raise exception '0328: título do botão não mudou';
  end if;
  if char_length('📍 Tem na minha rua?') > 20 then raise exception '0328: título do botão passa de 20 caracteres'; end if;
end $$;

commit;
