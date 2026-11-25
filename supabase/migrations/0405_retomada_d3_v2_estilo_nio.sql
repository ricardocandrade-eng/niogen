-- NIOGEN | supabase/migrations/0405_retomada_d3_v2_estilo_nio.sql | 25/11/2026 19h13 — Claude Code (Opus 5.5)
-- Ricardo, 25/11/2026: mandou o follow-up que recebeu da própria Nio ("Vimos que você iniciou um pedido… preço fixo até jan/2030…
-- Me informa seu CEP… Exemplo: 11111-111") — "Talvez podemos usar pela Mari algo similar" → "Sim, cria e submete e lembre-se do
-- espaçamento entre os parágrafos".
-- O que muda: o D3 da Retomada/cadência ganha a versão v2 das 3 variantes da 0381 (endereço · planos · dados), no estilo da Nio:
--   (1) fala da tarefa que ficou pela metade; (2) uma linha de benefício da tabela vigente — preço fixo até jan/2030, sem reajuste
--   (o mesmo gancho da abertura desde a 0234); (3) um pedido só — no endereço, o CEP com exemplo, e o botão "Não sei o CEP" para quem
--   não sabe (a Mari pede rua e bairro, como já faz). Parágrafos separados por linha em branco.
--   Fora de propósito: "iniciou um pedido" para quem nem deu endereço (não é verdade) e "sem pegadinhas" (fora da tabela).
-- Como sai: _retomada_variante devolve <variante>_v2 quando ela está APPROVED na Meta e a chave retomada_d3_v2 = 'sim'; senão, a v1
-- da 0381, que segue com a mesma checagem de aprovação no _retomada_tick e no mari_cadencia_avaliar (sem mexer neles).
-- Volta sem deploy: config_mari_textos.retomada_d3_v2 = 'nao'. Submissão: n8n/waba_template_retomada_d3_v2.py.
-- Regra 20: (1)–(3) nenhum estado, evento ou gravação novos — só o nome do template de uma mensagem que já sai; (4) a etapa vem da
-- conversa, como na 0381; (5) sem número novo — a conferência da cadência já cobre os toques. Cenário X134.
-- Desempenho: um EXISTS por chave primária a mais na variante — sem impacto.
-- Resultado a medir em 7 dias: resposta ao D3 (cliente fala em até 24 h) v2 × v1 dos 7 dias anteriores, por variante.

begin;

insert into public.config_mari_textos (chave, texto) values ('retomada_d3_v2', 'sim')
on conflict (chave) do nothing;

insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, rodape, status, uso) values
('nio_retomada_d3_endereco_v2', 'MARKETING', 'pt_BR', $t$Oi, {{1}}! É a Mari, da Nio 😊

Você começou a ver a internet fibra da Nio, mas a gente não terminou. Te ajudo a concluir por aqui, rapidinho!

🔒 Preço fixo até jan/2030, sem reajuste na fatura

Me manda seu CEP pra gente continuar?
Exemplo: 00000-000$t$, '["Não sei o CEP", "Depois eu vejo"]'::jsonb, null, 'PENDING',
 'D3 v2 (estilo Nio) — lead que nunca deu endereço (0405)'),
('nio_retomada_d3_planos_v2', 'MARKETING', 'pt_BR', $t$Oi, {{1}}! É a Mari, da Nio 😊

Você já viu {{2}}, mas ainda não escolheu.

🔒 O preço fica fixo até jan/2030, sem reajuste

Qual faz mais sentido pra sua casa? Te ajudo a fechar por aqui.$t$, '["Quero seguir", "Depois eu vejo"]'::jsonb, null, 'PENDING',
 'D3 v2 (estilo Nio) — deu endereço e não escolheu plano; {{2}} = os planos da cidade dele (0405)'),
('nio_retomada_d3_dados_v2', 'MARKETING', 'pt_BR', $t$Oi, {{1}}! É a Mari, da Nio 😊

Seu pedido ficou pela metade: faltam só os seus dados pra eu concluir.

🔒 O preço fica travado até jan/2030 a partir do dia que você fechar

Quer seguir?$t$, '["Quero seguir", "Depois eu vejo"]'::jsonb, null, 'PENDING',
 'D3 v2 (estilo Nio) — escolheu o plano e não passou os dados (0405)')
on conflict (nome) do nothing;

create or replace function public._retomada_variante(c public.mari_conversas, p_nome text)
returns table (tpl text, params jsonb)
language sql stable set search_path to 'public' as $$
  with e as (
    select case
      when coalesce((select t.texto from public.config_mari_textos t where t.chave = 'retomada_variantes'), 'sim') = 'nao' then null
      when c.cep is null and coalesce(c.dados ->> 'rua_informada', '') = '' then 'endereco'
      when nullif(btrim(coalesce(c.plano_escolhido, '')), '') is not null or c.funil_etapa = 'qualificada' then 'dados'
      else 'planos' end as etapa
  ), p as (
    -- o "a partir de" só para quem VIU os planos, com o preço do cluster dele (Regular × BTU), da tabela vigente
    select min(cp.preco) as preco from public.config_planos cp
     where c.funil_etapa = 'viu_planos' and c.cluster is not null and cp.ativo and cp.cluster = c.cluster and cp.portfolio = 'varejo'
       and coalesce(cp.variante, '') not ilike '%nfid%' and (cp.vigencia_fim is null or cp.vigencia_fim >= current_date)
  ), b as (
    select case e.etapa when 'endereco' then 'nio_retomada_d3_endereco' when 'planos' then 'nio_retomada_d3_planos'
                        when 'dados' then 'nio_retomada_d3_dados' end as base, e.etapa
      from e
  )
  select case
           -- 0405: a v2 (estilo Nio) só com ela aprovada na Meta e a chave ligada; senão a v1 da 0381
           when coalesce((select t.texto from public.config_mari_textos t where t.chave = 'retomada_d3_v2'), 'sim') = 'sim'
            and exists (select 1 from public.config_templates_waba w where w.nome = b.base || '_v2' and w.status = 'APPROVED')
           then b.base || '_v2'
           else b.base end,
         case when b.etapa = 'planos' then jsonb_build_array(p_nome,
                case when c.cidade is null then 'os planos de fibra da Nio'
                     when p.preco is null then 'os planos de fibra em ' || c.cidade
                     else 'os planos de fibra em ' || c.cidade || ', a partir de R$ '
                          || case when p.preco = trunc(p.preco) then trunc(p.preco)::text else replace(p.preco::text, '.', ',') end || ' por mês' end)
              when b.etapa is not null then jsonb_build_array(p_nome) end
    from b cross join p
   where b.etapa is not null
$$;
revoke all on function public._retomada_variante(public.mari_conversas, text) from public, anon;
grant execute on function public._retomada_variante(public.mari_conversas, text) to authenticated;   -- 0384: a v_mari_quadro lê
comment on function public._retomada_variante(public.mari_conversas, text) is
  'Variante do D3 (Retomada e escada do n8n) pela etapa gravada: endereco · planos · dados. 0381 (B4, Parte 4); 0405: _v2 (estilo Nio) quando aprovada. Desliga: config_mari_textos.retomada_variantes = nao · só a v2: retomada_d3_v2 = nao.';

commit;
