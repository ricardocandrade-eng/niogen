-- NIOGEN | supabase/migrations/0388_dfv_base_antiga_aposentada.sql | 23/11/2026 (escrita como 0368; renumerada em 24/11 — o 0368 já era da conferência) — Claude Code / Opus 5.5
-- Ricardo, 23/11: "Investiga também a diferença do DFV entre venda e conversa" → "Aposente essa base antiga. Registre isso no CLAUDE.md".
-- Causa (L-248): a conversa tinha o DFV da API do Power BI (desde 14/11 — viável, exato, 110 fachadas no CEP), guardado em
-- cobertura_detalhe. A venda, ao nascer, copiava o campo antigo dfv_resultado (vazio) e o gatilho vendas_antes_cobertura consultava a
-- BASE ANTIGA (nio_hp, foto de JF da carga de 03/11, sem o CEP 35500528) → "não encontrado" e a nota "DFV: conferir manualmente".
-- Em 30 dias: 6 vendas "não encontrado" onde a API dizia viável, 1 "sem viabilidade" onde a API dizia viável, 4 × "elegível".
-- O que muda:
--  1. dfv_consultar fica com a mesma assinatura e não lê mais nio_hp (devolve nenhuma linha). Quem a chamava — gatilho da venda,
--     mari_contexto, ficha_avisos, parceiro_consultar_endereco, o fallback da edge function dfv-consulta e o front — passa a "sem DFV".
--     A tabela nio_hp fica (sem carga nova; dfv_carga.py aposentado) só para a Fila Vero de JF (fila_vero_filtrar_jf), até decisão.
--  2. Venda nova sem DFV: leva o da API que a conversa já consultou (cobertura_detalhe.dfv, fonte ≠ base_congelada, mesmo CEP e número):
--     viavel → viável · elegivel/sem → não encontrado. Sem API: fica "não consultado".
--  3. Limpeza: o DFV da base antiga sai das conversas abertas (dfv_resultado/dfv_detalhe) e das vendas antes da instalação (refeito
--     pela API da conversa quando houver; senão "não consultado"). Venda instalada ou em Saída fica como está (histórico).
-- Regra 20: (1) nenhuma situação nova · (2) nenhuma trava lê dfv_viabilidade (só a criação, o carimbo e o evento) · (3) nada na fila
-- · (4) uma fonte só para o DFV: a API · (5) cenário X94. Desempenho: sem impacto (menos uma consulta por venda criada).
-- Medir em 7 dias: vendas novas com DFV "não encontrado" onde a conversa tem API viável → 0.

begin;

-- 1. a base antiga aposentada
create or replace function public.dfv_consultar(p_cep text, p_numero text, p_complemento text default null)
returns table(resultado text, hp_livre integer, hc_tot integer, hp_tot integer, tipo_edificacao text, faixa_credito text,
              classificacao text, classe_social text, bairro text, celula text, cod_survey text, particao date, opcoes jsonb)
language plpgsql stable set search_path = public as $$
begin
  -- 0388 (Ricardo, 23/11: "Aposente essa base antiga"): a base nio_hp (foto de JF, última carga 03/11) não responde mais.
  -- O DFV vale só pela API do Power BI (edge function dfv-consulta). Sem linhas = "sem DFV" para quem chama.
  return;
end $$;

-- 2. a venda nova leva o DFV da API que a conversa já tem
create or replace function public.vendas_antes_cobertura()
returns trigger language plpgsql set search_path = public as $$
declare
  c      public.mari_conversas;
  v_det  jsonb;
  v_mapa text;
begin
  -- Escolha manual na tela: vale como veio.
  if new.dfv_origem = 'manual' and (tg_op = 'INSERT' or old.dfv_origem is distinct from 'manual'
                                    or new.dfv_viabilidade is distinct from old.dfv_viabilidade) then
    new.dfv_resultado := null;
    new.dfv_particao := null;
    return new;
  end if;
  -- 0388: sem a base antiga, só a venda NOVA sem DFV ganha o da API da conversa (endereço mudou depois = consulta pela tela).
  if tg_op <> 'INSERT' or new.dfv_viabilidade <> 'nao_consultado' or new.status <> '0_qualificado' then return new; end if;
  if coalesce(new.origem_ref, '') !~ '^mari:[0-9a-fA-F-]{36}$' then return new; end if;
  select * into c from public.mari_conversas where id = substr(new.origem_ref, 6)::uuid;
  v_det := c.cobertura_detalhe;
  if v_det is null or coalesce(v_det ->> 'dfv_fonte', '') in ('', 'base_congelada') then return new; end if;
  if regexp_replace(coalesce(c.cep, ''), '\D', '', 'g') <> regexp_replace(coalesce(new.cep, ''), '\D', '', 'g')
     or upper(btrim(coalesce(c.numero, ''))) <> upper(btrim(coalesce(new.numero, ''))) then return new; end if;
  v_mapa := case v_det ->> 'dfv' when 'viavel' then 'viavel' when 'elegivel' then 'nao_encontrado' when 'sem' then 'nao_encontrado' end;
  if v_mapa is null then return new; end if;
  new.dfv_viabilidade   := v_mapa;
  new.dfv_resultado     := null;
  new.dfv_particao      := null;
  new.dfv_consultado_em := coalesce(c.cobertura_em, now());
  new.dfv_origem        := 'auto';
  return new;
end $$;

-- 3. limpeza do que veio da base antiga
update public.mari_conversas set dfv_resultado = null, dfv_detalhe = null
 where dfv_resultado is not null and venda_id is null and coalesce(status, '') not in ('encerrada');

update public.vendas v set
  dfv_viabilidade = coalesce(case c.cobertura_detalhe ->> 'dfv' when 'viavel' then 'viavel' when 'elegivel' then 'nao_encontrado'
                                                              when 'sem' then 'nao_encontrado' end, 'nao_consultado'),
  dfv_resultado = null, dfv_particao = null, dfv_hp_livre = null, dfv_hcs = null, dfv_faixa_credito = null, dfv_classificacao = null,
  dfv_consultado_em = case when c.cobertura_detalhe ->> 'dfv' in ('viavel', 'elegivel', 'sem') then c.cobertura_em end,
  dfv_origem = case when c.cobertura_detalhe ->> 'dfv' in ('viavel', 'elegivel', 'sem') then 'auto' end
  from public.vendas v0
  left join public.mari_conversas c on c.id = case when coalesce(v0.origem_ref, '') ~ '^mari:[0-9a-fA-F-]{36}$' then substr(v0.origem_ref, 6)::uuid end
       and coalesce(c.cobertura_detalhe ->> 'dfv_fonte', '') not in ('', 'base_congelada')
 where v.id = v0.id and v0.dfv_origem = 'auto' and v0.dfv_particao is not null
   and v0.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao');

commit;
